#!/bin/sh

. /usr/share/libubox/jshn.sh
FILE_PATH="/tmp/mplinks"

flag=""
ipaddr=""
ipaddr6=""
res=""

add_linkinfo_by_json()
{
	json_add_object "$2"	
	json_add_string "link" "$1"

	if [ -n "$ipaddr" ]; then
		json_add_string "ipv4" $ipaddr
	else
		json_add_string "ipv4" ""
	fi

	if [ -n "$ipaddr6" ]; then
		json_add_string "ipv6" $ipaddr6
	else
		json_add_string "ipv6" ""
	fi

	json_close_object "$2"
}

build_nullinfo_by_json()
{
	json_init
	json_add_array 'data'
	json_close_array

	res="$(json_dump)"
	json_cleanup
	echo "$res" > $FILE_PATH
}

get_link_info()
{
	local ifaces=$(ubus list|grep interface.|grep -v -E 'loopback|lan|4|6')
	local i=0

	for item in $ifaces; do
		local online_dev=""
		local up

		up="$(ubus call $item status|jsonfilter -e "@.up")"
		[ $up = true ] && online_dev="$(ubus call $item status|jsonfilter -e "@.l3_device")"
		[ -n "$online_dev" ] || continue

		ipaddr=$(curl --connect-timeout 2 --max-time 4 --interface $online_dev -s ip.sb -4)
		ipaddr6=$(curl --connect-timeout 2 --max-time 4 --interface $online_dev -s ip.sb -6)

		if [ -z "$flag" ]; then
			flag=1
			json_init
			json_add_array 'data'
			add_linkinfo_by_json "$online_dev" "$i"
		else
			add_linkinfo_by_json "$online_dev" "$(expr $i + 1)"
		fi
	done

	[ -z "$flag" ] && return

	json_close_array
	res="$(json_dump)"
	json_cleanup
	echo "$res" > $FILE_PATH
}

get_link_info
[ -z "$flag" ] && build_nullinfo_by_json

