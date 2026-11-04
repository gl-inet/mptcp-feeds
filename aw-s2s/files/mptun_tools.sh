#!/bin/sh

get_IPRB_identity() {
    local model
    model="$(cat /proc/gl-hw-info/model 2>/dev/null)" || {
        echo "Failed to read IPRB device model" >&2
        return 1
    }

    # Remove leading and trailing whitespace, preserving the model itself.
    model="${model#"${model%%[![:space:]]*}"}"
    model="${model%"${model##*[![:space:]]}"}"
    case "$model" in
        mt6000|be9300|be14000|x3000|xe3000|x2000|be6500|mt5000|ax1800|fn7200be) echo primary ;;
        *) echo secondary ;;
    esac
}

# Identity lookup exits before UCI and firewall policy initialization.
if [ "$1" = 'get_IPRB_identity' ]; then
    get_IPRB_identity
    exit $?
fi

TABLE_NAME="mptun_tools"
IPT_CHAIN_NAME="MPTUN_SKIP_POLICY"
IPTW="iptables -w 5"

use_fw4='0'
[ -n "$(which fw4)" ] && use_fw4='1'

UDP_MARK="$(uci -q get mptun.global.udpmark || echo 0x2)"
DNS_MARK="$(uci -q get mptun.global.dnsmark || echo 0x8)"
SKIP_POLICY_MARK='0x8000'
SKIP_POLICY_MARK_MASK='0xf000'
SKIP_POLICY_MARK_MASK_REVERSE="$(printf "0x%x" $((~0xf000 & 0xffffffff)))"
UDP_MARK_MASK_REVERSE="$(printf '0x%x' $((~UDP_MARK & 0xffffffff)))"
DNS_MARK_MASK_REVERSE="$(printf '0x%x' $((~DNS_MARK & 0xffffffff)))"

usage() {
    echo "Usage: mptun_tools <command> [arguments]
Commands:
    get_IPRB_identity          Print primary for designated models, secondary otherwise
    mac_skip_policy <mac>      Skip mptun policy for the specified device
    mac_restore_policy <mac>   Restore mptun policy for the specified device
    skip_policy               Skip mptun policy for all devices
    restore_policy            Restore mptun policy for all devices
    help, -h, --help           Show this help"
}

# If the table is empty, delete the table.
sort_out_table() {
    local num="$(nft -a list table inet ${TABLE_NAME} | grep "# handle" | wc -l)"
    [ -z "${num}" -o ${num} -gt 1 ] && return 0
    nft delete table inet ${TABLE_NAME} 2>/dev/null
}

# If there are no rules within the chain, then delete the chain.
sort_out_chain() {
    local chain_name="$1"
    [ -z "${chain_name}" ] && return 1
    local num="$(nft -a list chain inet ${TABLE_NAME} ${chain_name} | grep "# handle" | wc -l)"
    [ -z "${num}" -o ${num} -gt 1 ] && return 0
    nft delete chain inet ${TABLE_NAME} "${chain_name}" 2>/dev/null
}

get_ipt_prerouting_jump_line() {
    local chain_name="$1"
    $IPTW -t mangle -L PREROUTING --line-numbers -n 2>/dev/null | awk -v chain="${chain_name}" '$2 == chain { print $1; exit }'
}

delete_ipt_prerouting_jump() {
    local chain_name="$1"
    while $IPTW -t mangle -C PREROUTING -j "${chain_name}" 2>/dev/null ;do
        $IPTW -t mangle -D PREROUTING -j "${chain_name}" 2>/dev/null
    done
}

setup_ipt_chain() {
    local mproxy_line

    $IPTW -t mangle -N "${IPT_CHAIN_NAME}" 2>/dev/null
    delete_ipt_prerouting_jump "${IPT_CHAIN_NAME}"

    mproxy_line="$(get_ipt_prerouting_jump_line "MPROXY_PREROUTING")"
    if [ -n "${mproxy_line}" ] ;then
        $IPTW -t mangle -I PREROUTING "$((mproxy_line + 1))" -j "${IPT_CHAIN_NAME}"
    else
        $IPTW -t mangle -A PREROUTING -j "${IPT_CHAIN_NAME}"
    fi
}

sort_out_ipt_chain() {
    local num="$($IPTW -t mangle -S "${IPT_CHAIN_NAME}" 2>/dev/null | grep '^-A ' | wc -l)"
    [ -z "${num}" ] && return 0
    [ "${num}" -gt 0 ] && {
        setup_ipt_chain
        return 0
    }

    delete_ipt_prerouting_jump "${IPT_CHAIN_NAME}"
    $IPTW -t mangle -F "${IPT_CHAIN_NAME}" 2>/dev/null
    $IPTW -t mangle -X "${IPT_CHAIN_NAME}" 2>/dev/null
}

add_ipt_mark_rules() {
    local mark="$1"
    local dev_mac="$2"

    if [ -n "${dev_mac}" ] ;then
        $IPTW -t mangle -A "${IPT_CHAIN_NAME}" -m mark --mark "${mark}/${mark}" -m mac --mac-source "${dev_mac}" -j MARK --set-xmark "${SKIP_POLICY_MARK}/${SKIP_POLICY_MARK_MASK}"
        $IPTW -t mangle -A "${IPT_CHAIN_NAME}" -m mark --mark "${mark}/${mark}" -m mac --mac-source "${dev_mac}" -j MARK --set-xmark "0/${mark}"
    else
        $IPTW -t mangle -A "${IPT_CHAIN_NAME}" -m mark --mark "${mark}/${mark}" -j MARK --set-xmark "${SKIP_POLICY_MARK}/${SKIP_POLICY_MARK_MASK}"
        $IPTW -t mangle -A "${IPT_CHAIN_NAME}" -m mark --mark "${mark}/${mark}" -j MARK --set-xmark "0/${mark}"
    fi
}

delete_ipt_mark_rules() {
    local mark="$1"
    local dev_mac="$2"

    if [ -n "${dev_mac}" ] ;then
        while $IPTW -t mangle -D "${IPT_CHAIN_NAME}" -m mark --mark "${mark}/${mark}" -m mac --mac-source "${dev_mac}" -j MARK --set-xmark "${SKIP_POLICY_MARK}/${SKIP_POLICY_MARK_MASK}" 2>/dev/null ;do :; done
        while $IPTW -t mangle -D "${IPT_CHAIN_NAME}" -m mark --mark "${mark}/${mark}" -m mac --mac-source "${dev_mac}" -j MARK --set-xmark "0/${mark}" 2>/dev/null ;do :; done
    else
        while $IPTW -t mangle -D "${IPT_CHAIN_NAME}" -m mark --mark "${mark}/${mark}" -j MARK --set-xmark "${SKIP_POLICY_MARK}/${SKIP_POLICY_MARK_MASK}" 2>/dev/null ;do :; done
        while $IPTW -t mangle -D "${IPT_CHAIN_NAME}" -m mark --mark "${mark}/${mark}" -j MARK --set-xmark "0/${mark}" 2>/dev/null ;do :; done
    fi
}

skip_mptun_policy_for_spec_dev() {
    local dev_mac="$1"
    [ -z "${dev_mac}" ] && return 1

    local comment="${dev_mac} skip policy"

    if [ "${use_fw4}" = '1' ] ;then
        nft add table inet ${TABLE_NAME}
        nft add chain inet ${TABLE_NAME} prerouting_skip_policy '{ type filter hook prerouting priority mangle+1; policy accept; }'
        nft add rule inet ${TABLE_NAME} prerouting_skip_policy meta mark and ${UDP_MARK} == ${UDP_MARK} ether saddr "${dev_mac}" meta mark set meta mark and ${SKIP_POLICY_MARK_MASK_REVERSE} or ${SKIP_POLICY_MARK} comment "\"${comment}\""
        nft add rule inet ${TABLE_NAME} prerouting_skip_policy meta mark and ${UDP_MARK} == ${UDP_MARK} ether saddr "${dev_mac}" meta mark set meta mark and ${UDP_MARK_MASK_REVERSE} comment "\"${comment}\""
        nft add rule inet ${TABLE_NAME} prerouting_skip_policy meta mark and ${DNS_MARK} == ${DNS_MARK} ether saddr "${dev_mac}" meta mark set meta mark and ${SKIP_POLICY_MARK_MASK_REVERSE} or ${SKIP_POLICY_MARK} comment "\"${comment}\""
        nft add rule inet ${TABLE_NAME} prerouting_skip_policy meta mark and ${DNS_MARK} == ${DNS_MARK} ether saddr "${dev_mac}" meta mark set meta mark and ${DNS_MARK_MASK_REVERSE} comment "\"${comment}\""
    else
        setup_ipt_chain
        add_ipt_mark_rules "${UDP_MARK}" "${dev_mac}"
        add_ipt_mark_rules "${DNS_MARK}" "${dev_mac}"
        sort_out_ipt_chain
    fi
}

restore_mptun_policy_for_spec_dev() {
    local dev_mac="$1"
    [ -z "${dev_mac}" ] && return 1

    local comment="${dev_mac} skip policy"

    if [ "${use_fw4}" = '1' ] ;then
        local handle_num="$(nft -a list chain inet ${TABLE_NAME} prerouting_skip_policy | grep "${comment}" | awk -F ' ' '{print $NF}' | head -n 1)"
        while [ -n "${handle_num}" ] ;do
                nft delete rule inet ${TABLE_NAME} prerouting_skip_policy handle ${handle_num}
                handle_num="$(nft -a list chain inet ${TABLE_NAME} prerouting_skip_policy | grep "${comment}" | awk -F ' ' '{print $NF}' | head -n 1)"
        done
        sort_out_chain prerouting_skip_policy
    else
        delete_ipt_mark_rules "${UDP_MARK}" "${dev_mac}"
        delete_ipt_mark_rules "${DNS_MARK}" "${dev_mac}"
        sort_out_ipt_chain
    fi
}

skip_mptun_policy_for_all() {
    local comment="all device skip policy"
    if [ "${use_fw4}" = '1' ] ;then
        nft add table inet ${TABLE_NAME}
        nft add chain inet ${TABLE_NAME} prerouting_skip_policy '{ type filter hook prerouting priority mangle+1; policy accept; }'
        nft add rule inet ${TABLE_NAME} prerouting_skip_policy meta mark and ${UDP_MARK} == ${UDP_MARK} meta mark set meta mark and ${SKIP_POLICY_MARK_MASK_REVERSE} or ${SKIP_POLICY_MARK} comment "\"${comment}\""
        nft add rule inet ${TABLE_NAME} prerouting_skip_policy meta mark and ${UDP_MARK} == ${UDP_MARK} meta mark set meta mark and ${UDP_MARK_MASK_REVERSE} comment "\"${comment}\""
        nft add rule inet ${TABLE_NAME} prerouting_skip_policy meta mark and ${DNS_MARK} == ${DNS_MARK} meta mark set meta mark and ${SKIP_POLICY_MARK_MASK_REVERSE} or ${SKIP_POLICY_MARK} comment "\"${comment}\""
        nft add rule inet ${TABLE_NAME} prerouting_skip_policy meta mark and ${DNS_MARK} == ${DNS_MARK} meta mark set meta mark and ${DNS_MARK_MASK_REVERSE} comment "\"${comment}\""
    else
        setup_ipt_chain
        add_ipt_mark_rules "${UDP_MARK}"
        add_ipt_mark_rules "${DNS_MARK}"
        sort_out_ipt_chain
    fi
}


restore_mptun_policy_for_all() {
    local comment="all device skip policy"

    if [ "${use_fw4}" = '1' ] ;then
        local handle_num="$(nft -a list chain inet ${TABLE_NAME} prerouting_skip_policy | grep "${comment}" | awk -F ' ' '{print $NF}' | head -n 1)"
        while [ -n "${handle_num}" ] ;do
                nft delete rule inet ${TABLE_NAME} prerouting_skip_policy handle ${handle_num}
                handle_num="$(nft -a list chain inet ${TABLE_NAME} prerouting_skip_policy | grep "${comment}" | awk -F ' ' '{print $NF}' | head -n 1)"
        done
        sort_out_chain prerouting_skip_policy
    else
        delete_ipt_mark_rules "${UDP_MARK}"
        delete_ipt_mark_rules "${DNS_MARK}"
        sort_out_ipt_chain
    fi
}

main() {
    [ $# -ge 1 ] || {
        usage
        exit 1
    }

    cmd="$1";shift

    case "$cmd" in
        mac_skip_policy)
            skip_mptun_policy_for_spec_dev "$@"
            ;;
        mac_restore_policy)
            restore_mptun_policy_for_spec_dev "$@"
            ;;
        skip_policy)
            skip_mptun_policy_for_all "$@"
            ;;
        restore_policy)
            restore_mptun_policy_for_all "$@"
            ;;
        help|-h|--help)
            usage
            ;;
        *)
        echo "unknown command: $cmd"
        usage
            ;;
    esac

    if [ "${use_fw4}" = '1' ] ;then
        sort_out_table
    fi
}

main "$@"
