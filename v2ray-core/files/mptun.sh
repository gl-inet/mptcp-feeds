set_tcptun() {
    local port host key
    local cfg="$1"
    host="$(jsonfilter -i $cfg -q -e  '@.tcpTun.address')"
    port="$(jsonfilter -i $cfg -q -e  '@.tcpTun.port')"
    key="$(jsonfilter -i $cfg -q -e  '@.tcpTun.users[0].key')"
    [ -z $host -o -z $port -o -z $key ] && return 1
cat >/var/run/mpnode.json <<EOF
{
  "outbounds": [
    {
      "tag": "mptunout",
      "settings": {
        "vnext": [
          {
            "address": "$host",
            "port": $port,
            "users": [
              {
                "id": "$key"
              }
            ]
          }
        ]
      }
    }
  ]
}
EOF
    return 0
}



format_udp_cfg() {
    local FILE="$2"
    local interface="$(jsonfilter -q -i $1 -e  '@.interface')"
    local peers="$(jsonfilter -q -i $1 -e  '@.peers')"
    [ -z "$interface" -o -z "$peers" ] && return 1

    eval $(echo $interface|jsonfilter -q -e 'Address=@.Address' -e 'PrivateKey=@.PrivateKey')
cat >$FILE <<EOF
[Interface]
PrivateKey=$PrivateKey
EOF
    local i=0
    while true;do
        local peer=$(echo $peers|jsonfilter -q -e "@[$i]")
        [ -z "$peer" ] &&  break
        let i=i+1;
        eval $(echo $peer|jsonfilter -q -e 'Endpoint=@.Endpoint' -e 'AllowedIPs=@.AllowedIPs' \
         -e 'PersistentKeepalive=@.PersistentKeepalive' -e 'PublicKey=@.PublicKey')
cat >>$FILE <<EOF

[peer]
Endpoint=$Endpoint
AllowedIPs=$AllowedIPs
PersistentKeepalive=$PersistentKeepalive
PublicKey=$PublicKey
EOF
    done
    return 0

}

set_udptun() {
    local TMPFILE="/var/run/mpudp.cfg"
    local MTU="$(jsonfilter -q -i $1 -e  '@.interface.MTU')"
    local Address="$(jsonfilter -q -i $1 -e  '@.interface.Address')"
    local DEV=$2
    local MARK=$3

    format_udp_cfg "$1" "${TMPFILE}" || return 1
    ip link del dev "${DEV}" 2>/dev/null                                                
    ip link add dev "${DEV}" type wireguard
    [ -n "$MTU" ] && ip link set mtu "$MTU" "${DEV}" 
    wg setconf "${DEV}" "${TMPFILE}" || return 1
    ip address add dev "${DEV}" "${Address}" || return 1
    ip link set up dev "${DEV}" || return 1

    [ -z "$(uci -q get network.mpudptun_rule)" ] && {
        uci set network.mpudptun_rule=rule
        uci set network.mpudptun_rule.mark="$MARK"
        uci set network.mpudptun_rule.lookup='30'
        uci set network.mpudptun_rule.priority='30'
        uci commit network
        /etc/init.d/network reload
    }
    
}

set_firewall()
{
    local cfg="$1"
    local DEV="$2"
    local srcips destips localips
    local i=0

    localips=$(jsonfilter -i $cfg -q -e "@.udpTun.interface.allowedSrc")

    while true;do
            local client=$(jsonfilter -i $cfg -q -e "@.udpTun.clients[$i]")
            [ -z "$client" ] &&  break
            local resource=$(jsonfilter -i $cfg -q -e "@.udpTun.clients[$i].resource")
            local allowedsrc=$(jsonfilter -i $cfg -q -e "@.udpTun.clients[$i].allowedSrc")
            srcips=${srcips}${allowedsrc:+,$allowedsrc}
            destips=${destips}${resource:+,$resource}
            let i=i+1;
    done

    localips="$(echo "$localips"|sed 's/,/ /g')"
    srcips="$(echo "$srcips"|sed 's/,/ /g')"
    destips="$(echo "$destips"|sed 's/,/ /g')"

    [ -z "$(uci -q get firewall.mptun)" ] && {
        uci set firewall.mptun=zone
        uci set firewall.mptun.name='mptun'
        uci set firewall.mptun.device="${DEV:=mptun}"
        uci set firewall.mptun.input='DROP'
        uci set firewall.mptun.output='ACCEPT'
        uci set firewall.mptun.forward='DROP'
        uci set firewall.mptun.masq='1'
        uci set firewall.mptun.mtu_fix='1'
        uci set firewall.lan2mptun=forwarding
        uci set firewall.lan2mptun.src='lan'
        uci set firewall.lan2mptun.dest='mptun'
    }

    [ -z "$(uci -q get firewall.mptun_subnet_rule)" ] && {
        uci set firewall.mptun_subnet_rule=rule
        uci set firewall.mptun_subnet_rule.name='mptun subnet rule'
        uci set firewall.mptun_subnet_rule.src="mptun"
        uci set firewall.mptun_subnet_rule.dest='*'
        uci add_list firewall.mptun_subnet_rule.proto='all'
        uci set firewall.mptun_subnet_rule.target='ACCEPT'
    }

    [ -z "$(uci -q get firewall.mptun_local_rule)" ] && {
        uci set firewall.mptun_local_rule=rule
        uci set firewall.mptun_local_rule.name='mptun local rule'
        uci set firewall.mptun_local_rule.src="mptun"
        uci add_list firewall.mptun_local_rule.proto='all'
        uci set firewall.mptun_local_rule.target='ACCEPT'
    }

    uci delete firewall.mptun_subnet_rule.src_ip
    for i in $srcips;do
        uci add_list firewall.mptun_subnet_rule.src_ip="$i"
    done
    uci delete firewall.mptun_subnet_rule.dest_ip
    for i in $destips;do
        uci add_list firewall.mptun_subnet_rule.dest_ip="$i"
    done

    uci delete firewall.mptun_local_rule.src_ip
    for i in $localips;do
        uci add_list firewall.mptun_local_rule.src_ip="$i"
    done

    uci commit firewall
    /etc/init.d/firewall reload 
}

set_proxy() {
    local servers port host tcp_route_ips udp_route_ips
    local cfg="$1"
    host="$(jsonfilter -i $cfg -q -e  '@.tcpTun.address')"
    servers=${servers}${host:+,$host}
    port="$(jsonfilter -i $cfg -q -e  '@.tcpTun.port')"
    tcp_route_ips="0.0.0.0/0"

    local i=0
    while true;do
            local peer=$(jsonfilter -i $cfg -q -e "@.udpTun.peers[$i]")
            [ -z "$peer" ] &&  break
            local endpoint=$(jsonfilter -i $cfg -q -e "@.udpTun.peers[$i].Endpoint")
            local allowedips=$(jsonfilter -i $cfg -q -e "@.udpTun.peers[$i].AllowedIps")
            endpoint=${endpoint%:*}
            servers=${servers}${endpoint:+,$endpoint}
            udp_route_ips=${udp_route_ips}${allowedips:+,$allowedips}

            #如果对端地址与tcp地址相同，则为udp聚合peer,仅对udp和icmp协议做全局代理
            [ -n $host ] && [ "$host" = "$endpoint" ] && [ -n "$(echo $allowedips|grep 0.0.0.0/0)" ] && {
                    udp_global_proto="udp,icmp"
            }         
            let i=i+1;
    done
                         
    servers=${servers#*,}            
    tcp_route_ips=${tcp_route_ips#*,}
    udp_route_ips=${udp_route_ips#*,}
    #全局代理仅对udp和icmp协议生效，从代理路由中剔除0.0.0.0
    [ -n "$udp_global_proto" ] && {
        udp_route_ips="$(echo "$udp_route_ips"|sed 's/,0.0.0.0\/0//g'|sed 's/0.0.0.0\/0,//g')"
    }
                             
cat > /var/run/tmp.nft << EOF
#!/usr/sbin/nft -f        
define SERVER = {$servers}   
define TCP_PROXY_PORT = $port          
define UDP_ROUTE_IPS = {$udp_route_ips}
define TCP_ROUTE_IPS = {$tcp_route_ips}
define UDPMARK = "$3"
define TCPMARK = "$2"                        
define UDP_GOLBAL_PROTO = {$udp_global_proto}

define BYPASS_IP = {127.0.0.1/32, 224.0.0.0/4, 255.255.255.255/32, \$SERVER}
define TCPPROTO = {tcp}

table inet mproxy {}
flush table inet mproxy
table inet mproxy {
    chain prerouting {
        type filter hook prerouting priority 0;
        ip daddr \$BYPASS_IP return
        #将所有对端子网设置好udp隧道标记，后续路由规则将使用
        ip daddr \$UDP_ROUTE_IPS  mark set \$UDPMARK accept
        #如果存在udp聚合peer，则应用这条规则
        ${udp_global_proto:+meta l4proto \$UDP_GOLBAL_PROTO mark set \$UDPMARK accept}
        #tcp代理规则
        ip daddr \$TCP_ROUTE_IPS meta l4proto \$TCPPROTO mark set \$TCPMARK tproxy ip to 127.0.0.1:\$TCP_PROXY_PORT accept
    }
}

table inet mpass {}
flush table inet mpass
table inet mpass {
    chain divert {
        type filter hook prerouting priority -150;
        #允许tcp代理数据通过防火墙
        meta l4proto tcp socket transparent 1 meta mark set \$TCPMARK accept
    }
}
EOF
 
    nft -f /var/run/tmp.nft
    /usr/bin/proxy-route.sh "set"
}



mptun_init() {
    local cfg=$1
    local dev=$2
    local udpmark=$3
    local tcpmark=$4

    set_udptun "$cfg" "$dev" "$udpmark"
    set_tcptun "$cfg"
    set_firewall "$cfg" "$dev"
    set_proxy "$cfg" "$tcpmark" "$udpmark" 
}

clean_proxy() {
	#rm  /etc/nftables.d/mptcp-proxy.nft 2>/dev/null
	/usr/bin/proxy-route.sh "clean" 2>/dev/null
	nft delete table inet mpass 2>/dev/null
    nft delete table inet mproxy 2>/dev/null
    rm /var/run/mpnode.json
}

clean_udptun() {
	[ -n "$(uci -q get firewall.mptun)" ] && {
		uci del firewall.mptun
		uci del firewall.lan2mptun
        uci del firewall.mptun_subnet_rule
        uci del firewall.mptun_local_rule
		uci commit firewall
		/etc/init.d/firewall reload
	}

	[ -n "$(uci -q get network.mpudptun_rule)" ] && {
		uci del network.mpudptun_rule
		uci commit network
		/etc/init.d/network reload
	}
	config_load "$CONF"
	local DEV
	config_get DEV "global" "mptun" "mptun0"
	ip link del dev "${DEV}" 2>/dev/null
}

mptun_clean() {
    clean_proxy
    clean_udptun
}