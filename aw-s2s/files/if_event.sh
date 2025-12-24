#!/bin/sh
# shellcheck disable=SC3037
# shellcheck disable=SC3003

. /lib/functions/gl_util.sh
. /lib/functions/mptun.sh

LOCKFILE=/tmp/run/iprb_wg_event.lock

service_mode="$(uci -q get mptun.global.service_mode)"
#IPRB_disabled="$(uci -q get mptun.IPRB.disabled)"
IPRB_identity="$(uci -q get mptun.IPRB.identity)"
[ "${service_mode}" != "IPRB" ] && return 0
#["${IPRB_identity}" != "secondary" ] && return 0

peerpubkey_safe="$(echo "$peerpubkey" | sed 's/[^A-Za-z0-9._-]//g')"

if [ "${ACTION}" = "KEYPAIR-CREATED" -a -n "$(echo "${ifname}" | grep "^mptun")" ]; then
    mkdir -p /tmp/wireguard/"${ifname}"/peers

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

    [ "${active_num}" -ne 0 ] && return

    con_time="$(date +%s)"
    uci -q set mptun.IPRB.state="connected"
    uci -q set mptun.IPRB.lastConnectedTime="$con_time"
    uci commit mptun
    notify_IPRB_status
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

    [ "${active_num}" -ne 0 ] && return

    uci -q set mptun.IPRB.state="connecting"
    uci -q delete mptun.IPRB.lastConnectedTime
    uci commit mptun
    notify_IPRB_status

    # Try switching ports to reconnect and avoid disconnections caused by network changes.
    awg set "${ifname}" listen-port 0
fi



