#!/usr/bin/env eco
local file = require 'eco.file'
local ubus = require 'eco.ubus'
local cjson = require 'cjson'
local log = require 'eco.log'
local sys = require 'eco.sys'
local uci = require 'uci'
local mp_device = {}

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
	local valid_topic1, valid_topic2, valid_topic3
	local pub_topic

	valid_topic1 = string.format('/sdwan/edge/cloud/%s/request/publish_net_config', mac)
	valid_topic2 = string.format('/sdwan/edge/cloud/%s/request/stop_sdwan_net', mac)
	valid_topic3 = string.format('/sdwan/edge/cloud/%s/request/enable_echo_server', mac)

	if topic == valid_topic1 then
		pub_topic = string.format('/sdwan/cloud/edge/%s/response/publish_net_config', mac)
	elseif topic == valid_topic2 then
		pub_topic = string.format('/sdwan/cloud/edge/%s/response/ctrl_sdwan_net_status', mac)
	elseif topic == valid_topic3 then
		pub_topic = string.format('/sdwan/cloud/edge/%s/response/enable_echo_server', mac)
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

local function handle_recv_net_config(msg)
	local node = {}
	msg = cjson.decode(msg)
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
		type = edgeType == "EDGE" and 0 or 1,
		peer = peer_info
	}
	file.writefile('/etc/mptun/mpnet_conf', cjson.encode(net_conf))
end

function mp_device.handle_recv_msg(topic, mac, msg)
	local valid_topic1, valid_topic2, valid_topic3, valid_topic4, valid_topic5
	local is_requset_msg = true

	valid_topic1 = string.format('/sdwan/edge/cloud/%s/request/publish_net_config', mac)
	valid_topic2 = string.format('/sdwan/edge/cloud/%s/request/stop_sdwan_net', mac)
	valid_topic3 = string.format('/sdwan/edge/cloud/%s/request/enable_echo_server', mac)
	valid_topic4 = string.format('/sdwan/edge/cloud/%s/request/publish_hosts_config', mac)
	valid_topic5 = string.format('/sdwan/edge/cloud/%s/response/publish_device_net_topology', mac)
	valid_topic6 = string.format('/sdwan/edge/cloud/%s/request/publish_hosts_config', mac)
	valid_topic7 = string.format('/sdwan/edge/cloud/%s/response/get_client_net_config', mac)

	if topic ~= valid_topic1 and topic ~= valid_topic2
	   and topic ~= valid_topic3 and topic ~= valid_topic4
	   and topic ~= valid_topic5 and topic ~= valid_topic6
	   and topic ~= valid_topic7 then
		return
	end

	if topic == valid_topic1 or topic == valid_topic7 then
		handle_recv_net_config(msg)
		start_sdwan()
	elseif topic == valid_topic2 then
		stop_sdwan()
	elseif topic == valid_topic5 then
		is_requset_msg = false
		handle_recv_net_topology(msg)
	end

	if is_requset_msg then
		local msg, pub_topic = build_response_msg(topic, mac)
		return msg, pub_topic
	end
end

return mp_device

