#!/bin/ash
# 设置策略路由
set_route() {
    ip rule del pref 10
    ip rule add fwmark 1 table 10 pref 10
    ip route add local 0.0.0.0/0 dev lo table 10
}


#清除
clean_route() {
    ip rule del pref 10
    ip route flush table 10
}

case $1 in
    "set")
        set_route
    ;;
    "clean")
        clean_route
    ;;
esac