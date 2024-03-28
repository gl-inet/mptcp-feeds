--[[
    @object-name: mptun
    @object-desc: mptun settings
--]]

local uci = require "uci"
local fs = require "oui.fs"
local ubus = require "oui.ubus"
local utils = require "oui.utils"
local cjson = require "cjson"

local M = {}

local ERR_PARAMETER = 1

--[[
    @method-type: call
    @method-name: set_config
    @method-desc: set mptun config

    @in array   interfaces Interfaces information that participate in aggregation network.
    @in string  interfaces.name Name of the interface.
    @in bool    interfaces.enable Indicates whether the interface is enabled.
    @in-example:  {"jsonrpc":"2.0","id":1,"method":"call","params":["NsPHdkXtENoaotxVZWLqJorU52O7J0OI", "mptun", "set_config"]}
    @out-example: {"jsonrpc": "2.0", "id": 1, "result": {}}
--]]
function M.set_config(params)
    local c = uci.cursor()
    local interfaces = params.interfaces
    if not interfaces or type(interfaces) ~= "table" then
        return {
            err_code = -ERR_PARAMETER,
            err_msg = "Input parameter error"
        }
    end

    for i=1, #interfaces do
        local iface = interfaces[i].name
        local enable = interfaces[i].enable
        if string.find(iface, "modem") and not string.find(iface, "_4") then
            iface = iface .. "_4"
        end

        local metric = tonumber(c:get("kmwan", iface, "metric") or -1)
        if metric ~= -1 then
            if enable then
                metric = metric < 100 and metric or metric - 100
            else
                metric = metric < 100 and metric + 100 or metric
            end
            c:set("kmwan", iface, "metric", metric)
        end
        c:set("mptun", iface, "enable", enable and 1 or 0)
    end

    c:commit("kmwan")
    c:commit("mptun")
    fs.sync()

    ngx.timer.at(2.0, function()
        ngx.pipe.spawn({"/etc/init.d/mptun", "restart"}):wait()
        ngx.pipe.spawn({"/etc/init.d/mpifd", "restart"}):wait()
        ngx.pipe.spawn({"/etc/init.d/kmwan", "restart"}):wait()
        ngx.pipe.spawn({"/etc/init.d/mpflow", "restart"})
    end)

end

--[[
    @method-type: call
    @method-name: get_config
    @method-desc: get mptun config

    @out array   interfaces Interfaces information that participate in aggregation network.
    @out string  interfaces.name Name of the interface.
    @out bool    interfaces.enable Indicates whether the interface is enabled.

    @in-example:  {"jsonrpc":"2.0","id":1,"method":"call","params":["NsPHdkXtENoaotxVZWLqJorU52O7J0OI", "mptun", "get_config"]}
    @out-example: {"jsonrpc": "2.0", "id": 1, "result": {"interfaces":[{"name":"wan","enable":true},{"name":"secondwan","enable":true},{"name":"wwan","enable":false},{"name":"tethering","enable":false}]}}
--]]
function M.get_config()
    local c = uci.cursor()
    local ifaces = {}

    c:foreach("mptun", "interface", function(s)
        local array = {}
        local enable = tonumber(c:get("mptun", s[".name"], "enable") or "0" )
        array.name = s[".name"]
        array.enable = enable == 1
        ifaces[#ifaces+1] = array
    end)

    return {interfaces = ifaces}
end

--[[
    @method-type: call
    @method-name: get_status
    @method-desc: get mptun network status

    @out string name name of the device in the network
    @out bool  online Whether the device is in an aggregated network
    @out string network_name The network name field obtained from the cloud platform
    @out array ?nodes Information about connections to other nodes, If the object does not exist, means the current device does not belong to any network
    @out object nodes.self information of the node
    @out string nodes.self.name Name of the node
    @out number nodes.self.status Indicates whether the node is online.(0:offline 1:online 2:warning)
    @out number nodes.self.type Type of the node(0:edge, 1:gateway)
    @out number nodes.self.acl_type Type of the access policy(0:none, 1:allow to local 2:allow to subnet)
    @out number nodes.self.bond Indicates whether the connection is bonding.(0:none 1:aggregation 2:s2s 3:aggregation+s2s)
    @out object nodes.peer information of the peer(device self)
    @out number nodes.peer.acl_type Type of the access policy(0:none, 1:allow to local 2:allow to subnet)
    @out number nodes.peer.bond Indicates whether the connection is bonding.(0:none 1:aggregation 2:s2s 3:aggregation+s2s)

    @in-example:  {"jsonrpc":"2.0","id":1,"method":"call","params":["NsPHdkXtENoaotxVZWLqJorU52O7J0OI", "mptun", "get_status"]}
    @out-example: {"jsonrpc": "2.0", "id": 1, "result": {"network_name":"test","type":0,"name":"mt6000","nodes":[{"self":{"acl_type":2,"type":1,"name":"test","status":1,"bond":1},"peer":{"acl_type":0,"bond":0}}],"online":true}}
]]
function M.get_status()
    local c = uci.cursor()
    local cloud_enable = c:get("gl-cloud", "@cloud[0]", "enable") or "0"
    local conf = {}
    local enable

    if cloud_enable ~= "0" then
        ubus.call('gl-cloud', 'mpdevice_net_topology')
        if fs.access('/etc/mptun/mpnet_conf') then
            conf = cjson.decode(utils.readfile("/etc/mptun/mpnet_conf") or "{}")
        end
        enable = c:get("mptun", "global", "enable") or "0"
    end

    local online = true
    local loop_cnt = 0

    if not conf.peer or #conf.peer == 0
       or enable == "0" then
        online = false
    else
        loop_cnt = #conf.peer
    end

    local i
    local nodes = {}
    local network_name
    for i = 1, loop_cnt do
        local node = {}
        local self = {}
        local peer = {}
        self.name = conf.peer[i].name
        self.type = conf.peer[i].nodeType == "CLOUD_GATEWAY" and 1 or 0

        if conf.peer[i].status == "offline" or conf.peer[i].status == "not_active" then
            self.status = 0
        elseif conf.peer[i].status == "online" then
            self.status = 1
        else
            self.status = 2
        end

        peer.acl_type = 0
        self.acl_type = 0

        if conf.peer[i].connectionType == "aggregation" then
            network_name = conf.peer[i].name
            self.bond = 1
            self.acl_type = 1
            peer.bond = 0
        else
            if conf.peer[i].fromAllowAccess and
               conf.peer[i].fromAllowAccess == 1 then
                if conf.peer[i].fromAllowAccessLanAndWan and
                   conf.peer[i].fromAllowAccessLanAndWan == 1 then
                    peer.acl_type = 2
                else
                    peer.acl_type = 1
                end
            end
            if conf.peer[i].toAllowAccess and
               conf.peer[i].toAllowAccess == 1 then
                if conf.peer[i].toAllowAccessLanAndWan and
                   conf.peer[i].toAllowAccessLanAndWan == 1 then
                    self.acl_type = 2
                else
                    self.acl_type = 1
                end
            end

            if conf.peer[i].nodeType and conf.peer[i].nodeType == "EDGE" then
                peer.bond = 0
            else
                peer.bond = 1
            end
            if conf.peer[i].edgeType then
                if conf.peer[i].edgeType == "EDGE" then
                    self.bond = 0
                end
                if conf.peer[i].edgeType == "LOCAL_GATEWAY" then
                    self.type = 1
                end
            end
        end
        node.self = self
        node.peer = peer
        nodes[#nodes+1] = node
    end

    return {
        network_name = network_name,
        name = conf.name,
        type = conf.type,
        online = online,
        nodes = nodes
    }
end

--[[
    @method-type: call
    @method-name: get_traffic
    @method-desc: get traffic information

    @out number tx The amount of traffic the device sends per second on the network
    @out number rx The amount of traffic the device receive per second on the network
    @out array  ?path.$iface.tx iface:[wan|wwan|secondwan|tethering|modem] Number of bytes received by the interface.
    @out array  ?path.$iface.rx iface:[wan|wwan|secondwan|tethering|modem] Number of bytes sent by the interface

    @in-example:  {"jsonrpc":"2.0","id":1,"method":"call","params":["NsPHdkXtENoaotxVZWLqJorU52O7J0OI", "mptun", "get_traffic"]}
    @out-example: {"jsonrpc": "2.0", "id": 1, "result": {"path":{"wan":{"rx":[13373,15484,13626],"tx":[16677,18612,12387]},"secondwan":{"rx":[19838,20956,11762],"tx":[11486,12092,6762]}}}}
]]
function M.get_traffic()
    ngx.pipe.spawn({"/usr/bin/get_mpflow.sh"}):wait()
    local data = cjson.decode(utils.readfile("/tmp/mpflow.json") or "{}")
    if data.path then
        return {path = data.path}
    else
        return {path = {}}
    end
end

return M

