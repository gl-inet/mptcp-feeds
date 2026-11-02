#!/bin/sh
# shellcheck disable=SC3037
# shellcheck disable=SC3003

. /lib/functions/gl_util.sh
. /lib/functions/mptun.sh || exit 1

[ -n "$(echo "${ifname}" | grep "^mptun")" ] || exit 0
[ "$service_mode" = 'IPRB' ] || exit 0
load_IPRB_config || exit 1
[ "${IPRB_identity}" != "secondary" ] && return 0

MPTUN_CONFIG="/etc/mptun/mpnet.json"

LOCKFILE=/tmp/run/iprb_wg_event.lock

mkdir -p /tmp/wireguard/"${ifname}"/peers
WG_BIN='awg'

IPRB_safe_pubkey() {
    printf "%s\n" "$1" | sed 's/[^A-Za-z0-9._-]//g'
}

peerpubkey_safe="$(IPRB_safe_pubkey "$peerpubkey")"

IPRB_update_p2p_status() {
    get_default_pub() {
        local q="0.0.0.0/0"
        jsonfilter -i "$MPTUN_CONFIG" \
            -e '@.udpTun.peers[*].allowedIps' \
            -e '@.udpTun.peers[*].publicKey' |
        while read ips; do
            read pub || break
            IFS=','
            for cidr in $ips; do
                [ "$cidr" = "$q" ] && echo "$pub"
            done
        done
    }
    get_current_pub() {
        local q="0.0.0.0/0"
        local cur_pub=""

        $WG_BIN show "${ifname}" | while read line; do
            case "$line" in
                peer:*)
                    cur_pub="${line#peer: }"
                    ;;
                *"allowed ips:"*)
                    ips="${line#*allowed ips: }"
                    IFS=','
                    for cidr in $ips; do
                        cidr="$(echo "$cidr" | xargs)"
                        [ "$cidr" = "$q" ] && echo "$cur_pub"
                    done
                    ;;
            esac
        done
    }

    local default_pub="$(get_default_pub)"
    local current_pub="$(get_current_pub)"
    local status="$(ubus -t 5 call gl-session call '{"module":"mptun","func":"get_IPRB_status","params":{}}' 2>/dev/null)"
    local old_p2p_status="$(jsonfilter -s "$status" -e '@.result.status.data.is_p2p' 2>/dev/null)"
    [ -z "$old_p2p_status" ] && old_p2p_status='false'
    local current_p2p_status="$old_p2p_status"

    if [ -n "$default_pub" -a -n "$current_pub" -a "$default_pub" != "$current_pub" ] ;then
        if [ "$peerpubkey" = "$current_pub" ] ;then
            if [ "${ACTION}" = "KEYPAIR-CREATED" ] ;then
                current_p2p_status='true'
            else
                current_p2p_status='false'
            fi
        fi
    else
        current_p2p_status='false'
    fi

    [ "$old_p2p_status" != "$current_p2p_status" ] && {
        IPRB_report_runtime "\"is_p2p\":${current_p2p_status}"
    }
}

# 字段由本脚本固定构造；失败只记录，不阻断 peer 清理或端口切换。
IPRB_report_runtime() {
    local changes="$1"
    local response result err_code
    [ -n "$changes" ] || return 0
    response="$(ubus -t 5 call gl-session call \
        "{\"module\":\"mptun\",\"func\":\"report_IPRB_runtime\",\"params\":{${changes}}}" 2>/dev/null)"
    result="$(jsonfilter -s "$response" -e '@.result' 2>/dev/null)"
    err_code="$(jsonfilter -s "$response" -e '@.result.err_code' 2>/dev/null)"
    if [ -z "$result" ] || [ -n "$err_code" -a "$err_code" != '0' ]; then
        logger -t mptun 'failed to report IPRB runtime'
    fi
    return 0
}

IPRB_has_remaining_remote_peer() {
    local current_peer_safe
    local peers
    local self_pub
    local self_pub_safe
    local peer
    local peer_safe

    current_peer_safe="$1"

    # An external peer manager prunes inactive peers from awg, so the remaining
    # peers reported here are treated as active remote connections.
    peers="$($WG_BIN show "${ifname}" peers 2>/dev/null)"
    [ "$?" -ne 0 ] && return 0

    self_pub="$($WG_BIN show "${ifname}" public-key 2>/dev/null)"
    self_pub_safe="$(IPRB_safe_pubkey "$self_pub")"

    for peer in $peers; do
        [ -z "$peer" ] && continue
        peer_safe="$(IPRB_safe_pubkey "$peer")"
        [ -z "$peer_safe" ] && continue
        if [ -n "$self_pub_safe" ]; then
            [ "$peer_safe" = "$self_pub_safe" ] && continue
        fi
        if [ -n "$current_peer_safe" ]; then
            [ "$peer_safe" = "$current_peer_safe" ] && continue
        fi
        return 0
    done

    return 1
}

[ "${IPRB_identity}" = "secondary" ] && IPRB_update_p2p_status

if [ "${ACTION}" = "KEYPAIR-CREATED" -a -n "$(echo "${ifname}" | grep "^mptun")" ]; then
    # lock
    count=1
    while [ -f "${LOCKFILE}" ] && [ $count -le 3 ]; do
        sleep 1
        count=$(($count+1))
    done
    rm -f "$LOCKFILE"
    echo $$ > ${LOCKFILE}
    trap 'rm -f "$LOCKFILE"; exit' EXIT INT TERM

    active_num="$(ls /tmp/wireguard/"${ifname}"/peers | wc -l)"
    [ -f /tmp/wireguard/"${ifname}"/peers/"${peerpubkey_safe}" ] || touch /tmp/wireguard/"${ifname}"/peers/"${peerpubkey_safe}"
    # unlock
    rm -f $LOCKFILE

    status="$(ubus -t 5 call gl-session call '{"module":"mptun","func":"get_IPRB_status","params":{}}' 2>/dev/null)"
    current_state="$(jsonfilter -s "$status" -e '@.result.status.data.state' 2>/dev/null)"
    [ "${active_num}" -ne 0 -a "$current_state" = 'connected' ] && return

    con_time="$(date +%s)"
    IPRB_report_runtime "\"state\":\"connected\",\"lastConnectedTime\":\"${con_time}\""
fi

if [ "${ACTION}" = "REKEY-TIMEOUT"  -a -n "$(echo "${ifname}" | grep "^mptun")" ]; then
     # lock
    count=1
    while [ -f "${LOCKFILE}" ] && [ $count -le 3 ]; do
        sleep 1
        count=$(($count+1))
    done
    rm -f "$LOCKFILE"
    echo $$ > ${LOCKFILE}
    trap 'rm -f "$LOCKFILE"; exit' EXIT INT TERM

    rm -f /tmp/wireguard/"${ifname}"/peers/"${peerpubkey_safe}"
    active_num="$(ls /tmp/wireguard/"${ifname}"/peers | wc -l)"

    # unlock
    rm -f $LOCKFILE

    if [ "${active_num}" -ne 0 ]; then
        if IPRB_has_remaining_remote_peer "$peerpubkey_safe"; then
            return
        fi
    fi

    IPRB_report_runtime '"state":"connecting","lastConnectedTime":""'

    # Try switching ports to reconnect and avoid disconnections caused by network changes.
    $WG_BIN set "${ifname}" listen-port 0
fi
