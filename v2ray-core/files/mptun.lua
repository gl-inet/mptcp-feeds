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
        ngx.pipe.spawn({"/etc/init.d/mpifd", "restart"}):wait()
        ngx.pipe.spawn({"/etc/init.d/mptun", "restart"}):wait()
        ngx.pipe.spawn({"/etc/init.d/kmwan", "restart"}):wait()
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
    @out-example: {"jsonrpc": "2.0", "id": 1, "result": {}}
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

local function build_virtual_ret()
    local node = {}
    local nodes = {}

    local self = {}
    self.name = "my_node"
    self.status = 1
    self.type = 0
    self.acl_type = 0
    self.bond = 1
    node.self = self
    self = {}
    self.acl_type = 0
    self.bond = 1
    node.peer = self

    nodes[#nodes+1] = node
    return nodes
end

--[[
    @method-type: call
    @method-name: get_status
    @method-desc: get mptun network status

    @out string name name of the device in the network
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
    @out-example: {"jsonrpc": "2.0", "id": 1, "result": {}}
]]
function M.get_status()
    local c = uci.cursor()
    local conf = cjson.decode(utils.readfile("/etc/mptun/mpnet_conf") or "{}")

    local i
    local nodes = {}
    local node = {}
    for i = 1, #conf.peer do
        local self = {}
        local peer = {}
        self.name = conf.peer[i].name
        self.type = conf.peer[i].nodeType == "CLOUD_GATEWAY" and 1 or 0

        --这里状态总共有4种，未激活状态是否需要处理?
        if conf.peer[i].status == "offline" then
            self.status = 0
        elseif conf.peer[i].status == "online" then
            self.status = 1
        else
            self.status = 2
        end

        if conf.peer[i].connectionType == "aggregation" then
            self.bond = 0
            self.acl_type = 0
            peer.acl_type = 1
            peer.bond = 0
        else
            if conf.peer[i].fromAllowAccessLanAndWan and
               conf.peer[i].fromAllowAccessLanAndWan == 1 then
                self.acl_type = 1
            elseif conf.peer[i].toAllowAccessLanAndWan and
                conf.peer[i].toAllowAccessLanAndWan == 1 then
                self.acl_type = 2
            else
                self.acl_type = 0
            end
            self.bond = 2
            peer.acl_type = self.acl_type
            peer.bond = peer.bond
        end
        node.self = self
        node.peer = peer
        nodes[#nodes+1] = node
    end

--[[
    return {
        network_name = "mpdevice",
        name = "test",
        --name = node_name,
        type = 0
        --nodes = node_info or {}
    }
--]]
    return {
        network_name = conf.network_name,
        name = conf.name,
        type = conf.type,
        nodes = nodes
    }
end

--[[
    @method-type: call
    @method-name: get_traffic
    @method-desc: get traffic information

    @out number tx The amount of traffic the device sends per second on the network
    @out number rx The amount of traffic the device receive per second on the network
    @out array paths Traffic information for each subflow
    @out string paths.name Name of the path
    @out number paths.tx The subflow sends per second on the network
    @out number paths.rx The subflow receive per second on the network

    @in-example:  {"jsonrpc":"2.0","id":1,"method":"call","params":["NsPHdkXtENoaotxVZWLqJorU52O7J0OI", "mptun", "get_traffic"]}
    @out-example: {"jsonrpc": "2.0", "id": 1, "result": {}}
]]
function M.get_traffic()
    --脚本实现，读取脚本数据,脚本需增加:1.判断聚合是否启用逻辑2.参与聚合的接口
    return nil
end

return M

