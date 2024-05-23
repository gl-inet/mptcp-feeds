#!/usr/bin/env eco
local file = require 'eco.file'
local ubus = require 'eco.ubus'
local cjson = require 'cjson'
local log = require 'eco.log'
local sys = require 'eco.sys'
local uci = require 'uci'
local mp_device = {}

local access_hosts = "/etc/mphosts"
local con_hosts = "/etc/mpcon_hosts"
local access_conf = "/tmp/dnsmasq.d/mpaccess_conf"
local connet_conf = "/tmp/dnsmasq.d/mpcon_conf"
local tmp_access_hostsdir = "/tmp/dnsmasq.d/mpaccess"
local tmp_con_hostsdir = "/tmp/dnsmasq.d/mpcon"
local tmp_access_hostsname = tmp_access_hostsdir .. "/" .. "mphosts"
local tmp_con_hostsname = tmp_con_hostsdir .. "/" .. "mpcon_hosts"

local function stop_sdwan()
	local c = uci.cursor()
	sys.exec('/etc/init.d/mptun', 'stop'):wait()
	sys.exec('/etc/init.d/mpifd', 'stop'):wait()
	c:set("mptun", "global", "enable", "0")
	c:commit("mptun")
end

local function start_sdwan()
	local c = uci.cursor()
	stop_sdwan()
	c:set("mptun", "global", "enable", "1")
	c:commit("mptun")
	sys.exec('/etc/init.d/mptun', 'start'):wait()
	sys.exec('/etc/init.d/mpifd', 'start'):wait()
	sys.exec('/etc/init.d/mpflow', 'restart'):wait()
end

local function get_uuid()
    return string.sub(file.readfile('/proc/sys/kernel/random/uuid'), 1, -2)
end

local function build_response_msg(topic, mac)
	local valid_topic1, valid_topic2, valid_topic3, valid_topic4
	local pub_topic

	valid_topic1 = string.format('/sdwan/edge/cloud/%s/request/publish_net_config', mac)
	valid_topic2 = string.format('/sdwan/edge/cloud/%s/request/stop_sdwan_net', mac)
	valid_topic3 = string.format('/sdwan/edge/cloud/%s/request/enable_echo_server', mac)
	valid_topic4 = string.format('/sdwan/edge/cloud/%s/request/publish_virtual_ip_info', mac)

	if topic == valid_topic1 then
		pub_topic = string.format('/sdwan/cloud/edge/%s/response/publish_net_config', mac)
	elseif topic == valid_topic2 then
		pub_topic = string.format('/sdwan/cloud/edge/%s/response/ctrl_sdwan_net_status', mac)
	elseif topic == valid_topic3 then
		pub_topic = string.format('/sdwan/cloud/edge/%s/response/enable_echo_server', mac)
	elseif topic == valid_topic4 then
		pub_topic = string.format('/sdwan/cloud/edge/%s/response/publish_virtual_ip_info', mac)
	else
		pub_topic = string.format('/sdwan/cloud/edge/%s/response/publish_hosts_config', mac)
	end

	local msg = {}
	local data = {}

    msg.msgId = get_uuid()
    msg.ts = os.time()
	data.code = 0
	msg.data = data

	return msg, pub_topic
end

local function need_parse_domain(peers)
	if not peers or type(peers) ~= "table" or #peers == 0 then return 0 end

	local ret = 0
	for i = 1, #peers do
		local endPoint = peers[i]['endPoint']
		if file.access(tmp_con_hostsname) then
			return 1
		end
		if endPoint and string.match(endPoint, "([%a]+):") then
			return 1
		end
	end
	return ret
end

local function handle_recv_net_config(msg)
	local node = {}
	msg = cjson.decode(msg)
	if not msg or not msg.data or type(msg.data) ~= "table" then
		log.info("No aggregation and the device is not connected to the device", cjson.encode(msg))
		return
	end

	local type = msg.data['type']

	if not type then
		return
	end

	local tcpTun
	local udpTun
	local users = {}
	local tmp_arr = {}

	if msg.data['tcpTun'] then
		tmp_arr.key = msg.data['tcpTun']['users'][1]['key']
		users[#users+1] = tmp_arr
		tcpTun = {
			address = msg.data['tcpTun']['address'],
			port = msg.data['tcpTun']['port'],
			users = users
		}
	end

	udpTun = {
		interface = {
			address = msg.data['udpTun']['interface']['address'],
			privateKey = msg.data['udpTun']['interface']['privateKey'],
			allowedSrc = msg.data['udpTun']['interface']['allowedSrc'],
			listenPort = msg.data['udpTun']['interface']['listenPort'],
			exitNode =  msg.data['udpTun']['interface']['exitNode']
		},
		peers = msg.data['udpTun']['peers'],
		clients = msg.data['udpTun']['clients']
	}

	node = {
		data = {
			type = type,
			tcpTun = tcpTun,
			udpTun = udpTun,
		}
	}

	file.writefile('/etc/mptun/mpnet.json', cjson.encode(node.data))
	return need_parse_domain(udpTun.peers)
end

local function create_and_copy_hosts(conf, hostdir, sname, dname)
	if not conf or not hostdir or not sname or not dname then
		log.err('<hosts information err.>')
	end

	if not file.access(conf) then
		file.writefile(conf, 'hostsdir=' .. hostdir)
	end

	if not file.access(hostdir) then
		sys.exec('mkdir', hostdir):wait()
	end

	local restart_flag
	if not file.access(dname) then
		restart_flag = true
	end
	sys.exec('cp', sname, dname):wait()

	if restart_flag then
		sys.exec('/etc/init.d/dnsmasq', 'restart')
	end
end

--处理组网权限相关的host信息,
local function handle_recv_hosts(msg)
	msg = cjson.decode(msg)
	if not msg or not msg.data or #msg.data == 0 then
		log.err('no about access host info.')
	end

	local append = false
	for i=1, #msg.data do
		local ip = msg['data'][i]['ip']
		local domain = msg['data'][i]['domain']
		if ip and domain then
			file.writefile(access_hosts, ip .. ' ' .. domain .. '\n', append)
			append = true
		end
	end

	create_and_copy_hosts(access_conf, tmp_access_hostsdir, access_hosts, tmp_access_hostsname)
end

local function clear_host()
	if file.access(tmp_access_hostsname) then
		file.writefile(tmp_access_hostsname, '')
	end

	if file.access(tmp_con_hostsname) then
		sys.exec('rm', tmp_con_hostsname)
	end
end

--处理云端解析的域名
local function handle_domain_parse(msg)
	msg = cjson.decode(msg)
	if not msg or not msg.data
	   or type(msg.data) ~= "table"
	   or #msg.data == 0 then
		log.err('err data:' .. cjson.encode(msg))
		return
	end

	local append = false
	for i = 1, #msg.data do
		local domain = msg['data'][i]['domain']
		local ips = msg['data'][i]['ip']
		for j = 1, #ips do
			local ip = ips[j]
			if ip and domain then
				file.writefile(con_hosts, ip .. ' ' .. domain .. '\n', append)
				append = false
			end
		end
	end
	create_and_copy_hosts(connet_conf, tmp_con_hostsdir, con_hosts, tmp_con_hostsname)
	start_sdwan()
end

--处理云端下发私有IP映射关系至设备端
local function handle_publish_virtual_ip_info(msg)
	msg = cjson.decode(msg)
	if not msg or not msg.data or #msg.data == 0 then
		log.err('no about virtual ip info.')
	end

	-- Get mac and virtual IP and then config the firewall
	for i=1, #msg.data do
		local mac = msg['data'][i]['mac']
		local virtualIp = msg['data'][i]['virtualIp']
		if mac and virtualIp then
			log.info('mac:',mac," virtualIp:",virtualIp)

		end
	end

end


--上报本地资源信息
function mp_device.report_dev_resource(mac)
	sys.exec('get_mplinkip.sh', 'local'):wait()
    local wlan_resource = cjson.decode(file.readfile('/tmp/local_resource'))
    local topic = string.format('/sdwan/cloud/edge/%s/publish/publish_net_resource', mac)

    local msg = {
        ts = os.time(),
        msgId = get_uuid(),
        data = wlan_resource.data
    }

    log.debug(cjson.encode(msg))
	return topic, msg
end

function mp_device.report_link_resource(mac)
	sys.exec('get_mplinkip.sh', 'link'):wait()
	local link_resource = cjson.decode(file.readfile('/tmp/mplinks'))
	local topic = string.format('/sdwan/cloud/edge/%s/publish/upload_edge_device_interface', mac)

	local msg = {
		ts = os.time(),
        msgId = get_uuid(),
        data = link_resource.data
	}
	log.debug(cjson.encode(msg))
	return topic, msg
end

--请求应用层拓扑数据
function mp_device.get_net_topology(mac)
	local topic = string.format('/sdwan/cloud/edge/%s/request/get_device_net_topology', mac)

	local msg = {
		ts = os.time(),
		msgId = get_uuid(),
		data = {}
	}

	return topic, msg
end

function mp_device.get_client_net_config(mac)
	local topic = string.format('/sdwan/cloud/edge/%s/request/get_client_net_config', mac)

	local msg = {
		ts = os.time(),
		msgId = get_uuid(),
		data = {}
	}

	return topic, msg
end

function mp_device.get_clinet_hosts(mac)
	local topic = string.format('/sdwan/cloud/edge/%s/request/get_hosts_config', mac)

	local msg = {
		ts = os.time(),
		msgId = get_uuid(),
		data = {}
	}

	return topic, msg
end

--上报聚合链路信息
function mp_device.report_link_info(mac)
	sys.exec('get_mplinkip.sh'):wait()
	local mplink_info = cjson.decode(file.readfile('/tmp/mplinks'))
	local topic = string.format('/sdwan/cloud/edge/%s/publish/upload_edge_device_links', mac)
	local msg = {
		ts = os.time(),
		msgId = get_uuid(),
		data = mplink_info.data
	}
	return topic, msg
end

--处理应用层拓扑
local function handle_recv_net_topology(msg)
	msg = cjson.decode(msg)
	local name = msg.data['name']
	local edgeType = msg.data['edgeType']
	local networkName = msg.data['networkName']

	local peer_info = {}
	for i = 1, #msg.data['pointList'] do
		local tmp_peer = {}
		tmp_peer.name = msg.data['pointList'][i]['name']
		tmp_peer.nodeType = msg.data['pointList'][i]['nodeType']
		tmp_peer.edgeType = msg.data['pointList'][i]['edgeType']
		tmp_peer.connectionType = msg.data['pointList'][i]['connectionType']
		tmp_peer.fromAllowAccess = msg.data['pointList'][i]['fromAllowAccess']
		tmp_peer.toAllowAccess = msg.data['pointList'][i]['toAllowAccess']
		tmp_peer.fromAllowAccessLanAndWan = msg.data['pointList'][i]['fromAllowAccessLanAndWan']
		tmp_peer.toAllowAccessLanAndWan = msg.data['pointList'][i]['toAllowAccessLanAndWan']
		tmp_peer.status = msg.data['pointList'][i]['status']
		peer_info[#peer_info+1] = tmp_peer
	end

	local net_conf = {
		name = name,
		networkName = networkName,
		type = edgeType == "EDGE" and 0 or 1,
		peer = peer_info
	}
	file.writefile('/etc/mptun/mpnet_conf', cjson.encode(net_conf))
end

--向云端查询域名对应的公网ip
local function request_parse_domain(mac)
	if not file.access('/etc/mptun/mpnet.json') then return end
	local idata = cjson.decode(file.readfile('/etc/mptun/mpnet.json'))

	if type(idata) ~= "table" or not idata['udpTun']
	   or type(idata['udpTun']) ~= "table" then
		log.err('No udpTun information')
		return
	   end

	local peers = idata['udpTun']['peers']
	if not peers or type(peers) ~= "table" or #peers == 0 then
		log.debug('No peers information.')
		return
	end

	local domain = {}
	for i = 1, #peers do
		local str
		local is_domain
		if peers[i]['endPoint'] then
			str = string.match(peers[i]['endPoint'], "([_%w-%.]+):")
			is_domain = str and string.match(str, "([%a_-]+)") or false
		end
		if is_domain then
			domain[#domain+1] = str
		end
	end

	if #domain == 0 then return end

	local topic = string.format('/sdwan/cloud/edge/%s/request/query_domain_ip', mac)
	local data = {}
	data.domain = domain

	local msg = {
		ts = os.time(),
		msgId = get_uuid(),
		data = data
	}

	return msg, topic
end


--设备端主动上报LAN/WAN侧设备信息到平台
local function run_arp_scan()
    local handle = io.popen("arp-scan -l -x -F '${ip}\\t${mac}' -I eth1")
    local result = handle:read("*a")
    handle:close()
    return result
end

local function parse_arp_scan_output(output)
    local ip_mac_list = {}
    for line in output:gmatch("[^\r\n]+") do
        local ip, mac = line:match("(%d+%.%d+%.%d+%.%d+)%s+([%x:]+)")
        if ip and mac then
            table.insert(ip_mac_list, {ip = ip, mac = mac})
        end
    end
    return ip_mac_list
end

-- report_terminal_info method impl
function mp_device.report_terminal_info(mac)
	-- running the script and get the data
    local topic = string.format('/sdwan/cloud/edge/%s/publish/report_terminal_info', mac)
	local output = run_arp_scan()
	-- client list
	local clients = {}
	-- get wan devcie information
	local ip_mac_list = parse_arp_scan_output(output)
	for _, entry in ipairs(ip_mac_list) do
		if entry.ip == "0.0.0.0" then entry.ip = '' end
		table.insert(clients, {ip = entry.ip, mac = entry.mac:lower():gsub(":", ""), accessMode = "wan", hostname = "", online = "online" }) 
	end

	-- Get lan devcie information
	local r = ubus.call("gl-clients", "list", {}) or {}
	for mac, info in pairs(r.clients or {}) do
		if info.ip == "0.0.0.0" then info.ip = '' end
		table.insert(clients, {ip = info.ip, mac = info.mac:lower():gsub(":", ""), accessMode = "lan", hostname = info.name, online = info.online and "online" or "offline" })
	end

	-- build msg and send to cloud
    local msg = {
        ts = os.time(),
        msgId = get_uuid(),
        data = clients
    }
    log.debug(cjson.encode(msg))
	return topic, msg
end




function mp_device.handle_recv_msg(topic, mac, msg)
	local valid_topic1, valid_topic2, valid_topic3, valid_topic4, valid_topic5, valid_topic6, valid_topic7, valid_topic8, valid_topic9
	local is_requset_msg = true

	valid_topic1 = string.format('/sdwan/edge/cloud/%s/request/publish_net_config', mac)
	valid_topic2 = string.format('/sdwan/edge/cloud/%s/request/stop_sdwan_net', mac)
	valid_topic3 = string.format('/sdwan/edge/cloud/%s/request/enable_echo_server', mac)
	valid_topic4 = string.format('/sdwan/edge/cloud/%s/request/publish_hosts_config', mac)
	valid_topic5 = string.format('/sdwan/edge/cloud/%s/response/publish_device_net_topology', mac)
	valid_topic6 = string.format('/sdwan/edge/cloud/%s/response/get_client_net_config', mac)
	valid_topic7 = string.format('/sdwan/edge/cloud/%s/response/get_hosts_config', mac)
	valid_topic8 = string.format('/sdwan/edge/cloud/%s/response/query_domain_ip', mac)
	valid_topic9 = string.format('/sdwan/edge/cloud/%s/request/publish_virtual_ip_info', mac)

	if topic ~= valid_topic1 and topic ~= valid_topic2
	   and topic ~= valid_topic3 and topic ~= valid_topic4
	   and topic ~= valid_topic5 and topic ~= valid_topic6
	   and topic ~= valid_topic7 and topic ~= valid_topic8
	   and topic ~= valid_topic9 then
		return
	end

	if topic == valid_topic1 or topic == valid_topic6 then
		local ret = handle_recv_net_config(msg)
		if not ret then return end
		if ret == 1 then 
			return request_parse_domain(mac)
		end
		start_sdwan()
	elseif topic == valid_topic2 then
		stop_sdwan()
		clear_host()
	elseif topic == valid_topic5 then
		is_requset_msg = false
		handle_recv_net_topology(msg)
	elseif topic == valid_topic4 or topic == valid_topic7 then
		handle_recv_hosts(msg)
	elseif topic == valid_topic8 then
		handle_domain_parse(msg)
	elseif topic == valid_topic9 then
		handle_publish_virtual_ip_info(msg)
	end

	if is_requset_msg then
		local msg, pub_topic = build_response_msg(topic, mac)
		return msg, pub_topic
	end
end

return mp_device

