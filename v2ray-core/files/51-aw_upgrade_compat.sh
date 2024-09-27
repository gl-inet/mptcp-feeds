[ ! -f "/etc/config/mptun" ] && exit
aw_mark="$(uci -q get mptun.global.tcpmark)"
[ -z "$aw_mark" ] && exit

[ -n "$(uci -q get firewall.adguard_home)" ] && \
	[ -z "$(uci -q get firewall.adguard_home.mark)" ] && \
	uci set firewall.adguard_home.mark="!$aw_mark/$aw_mark"

[ -n "$(uci -q get firewall.adguard_home_guest)" ] && \
	[ -z "$(uci -q get firewall.adguard_home_guest.mark)" ] && \
	uci set firewall.adguard_home_guest.mark="!$aw_mark/$aw_mark"

uci commit firewall
