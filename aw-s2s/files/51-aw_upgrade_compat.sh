[ ! -f "/etc/config/mptun" ] && exit

set_IPRB_sub_mode() {
    local service_mode="$(uci -q get mptun.global.service_mode)"
    local global_enable="$(uci -q get mptun.global.enable)"
    local has_IPRB="$(uci -q get mptun.IPRB)"
    local sub_mode="$(uci -q get mptun.IPRB.sub_mode)"

    if [ -n "$has_IPRB" -a -z "$sub_mode" ]; then
        uci -q set mptun.IPRB.sub_mode='classic'
    fi

    if [ -z "$service_mode" -a "$global_enable" = '1' ]; then
        uci -q set mptun.global.service_mode='classic'
    fi

    uci commit mptun
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

[ -z "$(uci -q get mptun.global.base_url)" ] && uci -q set mptun.global.base_url='https://api.astrowarp.net'
uci commit mptun

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

set_IPRB_sub_mode

clear_resource_reported

uci commit firewall

rm -f /usr/share/nftables.d/ruleset-post/accept_br_to_mptun.nft
