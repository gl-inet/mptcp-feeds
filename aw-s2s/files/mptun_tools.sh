#!/bin/sh

TABLE_NAME="mptun_tools"

use_fw4='0'
[ -n "$(which fw4)" ] && use_fw4='1'

usage() {
    echo "usage:
    mptun_tools option arg1 arg2 arg3 ..."
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

skip_mptun_policy_for_spec_dev() {
    local dev_mac="$1"
    [ -z "${dev_mac}" ] && return 1

    local comment="${dev_mac} skip policy"

    if [ "${use_fw4}" = '1' ] ;then
        nft add table inet ${TABLE_NAME}
        nft add chain inet ${TABLE_NAME} prerouting_skip_policy '{ type filter hook prerouting priority mangle+1; policy accept; }'
        nft add rule inet ${TABLE_NAME} prerouting_skip_policy meta mark and 0x2 == 0x2 ether saddr "${dev_mac}" meta mark set meta mark and 0xffff8fff or 0x00008000 comment "\"${comment}\""
        nft add rule inet ${TABLE_NAME} prerouting_skip_policy meta mark and 0x2 == 0x2 ether saddr "${dev_mac}" meta mark set meta mark and 0xfffffffd comment "\"${comment}\""
        nft add rule inet ${TABLE_NAME} prerouting_skip_policy meta mark and 0x8 == 0x8 ether saddr "${dev_mac}" meta mark set meta mark and 0xffff8fff or 0x00008000 comment "\"${comment}\""
        nft add rule inet ${TABLE_NAME} prerouting_skip_policy meta mark and 0x8 == 0x8 ether saddr "${dev_mac}" meta mark set meta mark and 0xfffffff7 comment "\"${comment}\""
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
    fi
}

skip_mptun_policy_for_all() {
    local comment="all device skip policy"
    if [ "${use_fw4}" = '1' ] ;then
        nft add table inet ${TABLE_NAME}
        nft add chain inet ${TABLE_NAME} prerouting_skip_policy '{ type filter hook prerouting priority mangle+1; policy accept; }'
        nft add rule inet ${TABLE_NAME} prerouting_skip_policy meta mark and 0x2 == 0x2 meta mark set meta mark and 0xffff8fff or 0x00008000 comment "\"${comment}\""
        nft add rule inet ${TABLE_NAME} prerouting_skip_policy meta mark and 0x2 == 0x2 meta mark set meta mark and 0xfffffffd comment "\"${comment}\""
        nft add rule inet ${TABLE_NAME} prerouting_skip_policy meta mark and 0x8 == 0x8 meta mark set meta mark and 0xffff8fff or 0x00008000 comment "\"${comment}\""
        nft add rule inet ${TABLE_NAME} prerouting_skip_policy meta mark and 0x8 == 0x8 meta mark set meta mark and 0xfffffff7 comment "\"${comment}\""
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
