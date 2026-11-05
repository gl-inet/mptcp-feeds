[ ! -f "/etc/config/mptun" ] && exit

migrate_IPRB_sub_mode() {
    # 字段存在即为新版配置；空值或 0 不作为旧版本处理。
    uci -q get mptun.IPRB.inited >/dev/null && return 0

    uci -q delete mptun.global.service_mode
    uci -q delete mptun.IPRB
    uci -q set mptun.global.need_sync='1'
    uci commit mptun
}

migrate_speedtest_type() {
    local old_type="$(uci -q get mptun.global.speedtest_type)"
    case "$old_type" in
        iperf)
            uci -q set mptun.global.speedtest_type='tunspeed'
            uci -q set mptun.global.speedtest_port='7890'
            uci commit mptun
            ;;
        *) return 0 ;;
    esac
}

clear_resource_reported() {
    uci -q delete mptun.IPRB.resource_reported
    uci commit mptun
}

dns_mark="$(uci -q get mptun.global.dnsmark)"
[ -z "$dns_mark" ] && {
    uci -q set mptun.global.dnsmark='0x8'
    uci commit mptun
    dns_mark='0x8'
}

[ "$(uci -q get mptun.global.base_url)" = 'https://api.astrowarp.net' ] && {
    uci -q delete mptun.global.base_url
    uci commit mptun
}

[ -n "$(uci -q get firewall.adguard_home)" ] && \
    [ -z "$(uci -q get firewall.adguard_home.mark)" ] && \
    uci set firewall.adguard_home.mark="!$dns_mark/$dns_mark"

[ -n "$(uci -q get firewall.adguard_home_guest)" ] && \
    [ -z "$(uci -q get firewall.adguard_home_guest.mark)" ] && \
    uci set firewall.adguard_home_guest.mark="!$dns_mark/$dns_mark"

[ -n "$(uci -q get firewall.dns_over_lan)" ] && \
    [ -z "$(uci -q get firewall.dns_over_lan.mark)" ] && \
    uci set firewall.dns_over_lan.mark="!$dns_mark/$dns_mark"

[ -n "$(uci -q get firewall.dns_over_guest)" ] && \
    [ -z "$(uci -q get firewall.dns_over_guest.mark)" ] && \
    uci set firewall.dns_over_guest.mark="!$dns_mark/$dns_mark"

migrate_IPRB_sub_mode
migrate_speedtest_type

clear_resource_reported

uci commit firewall

rm -f /usr/share/nftables.d/ruleset-post/accept_br_to_mptun.nft
exit 0
