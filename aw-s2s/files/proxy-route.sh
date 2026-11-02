#!/bin/ash
# 设置策略路由
set_route() {
    local service_mode="$(uci -q get mptun.global.service_mode)"
    local proxy_private_net='0'
    if [ "$service_mode" = 'IPRB' ]; then
        proxy_private_net="$(uci -q get mptun.IPRB.proxy_private_net)"
    fi
    [ "$proxy_private_net" = '1' ] || proxy_private_net='0'

    local tcpmark="$(uci -q get mptun.global.tcpmark || echo 0x1)"
    ip rule del pref 10 2>/dev/null
    ip rule add fwmark ${tcpmark}/${tcpmark} table 10 pref 10
    ip route add local 0.0.0.0/0 dev lo table 10
    ip rule del pref 9 2>/dev/null
    if [ "$proxy_private_net" = '0' ]; then
        # Prefer specific main-table routes only when private networks bypass the tunnel.
        ip rule add from all lookup main suppress_prefixlength 1 pref 9
    fi
}


#清除
clean_route() {
    ip rule del pref 10
    ip route flush table 10
    ip rule del pref 9
}

case $1 in
    "set")
        set_route
    ;;
    "clean")
        clean_route
    ;;
esac
