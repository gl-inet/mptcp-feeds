--[[
    @object-name: mptun
    @object-desc: mptun settings
--]]

local uci = require "uci"
local fs = require "oui.fs"
local ubus = require "oui.ubus"
-- local kmwan = require "gl.kmwan"
local utils = require "oui.utils"
local cjson = require "cjson"

local M = {}

local ERR_PARAMETER_TYPE = 1

--[[
    @method-type: call
    @method-name: set_config
    @method-desc: set mprouter config

    @in array   interfaces Interfaces information that participate in aggregation network.
    @in string   interfaces.name Name of the interface.
    @in bool   interfaces.enable Indicates whether the interface is enabled.
    @in-example:  {"jsonrpc":"2.0","id":1,"method":"call","params":["NsPHdkXtENoaotxVZWLqJorU52O7J0OI", "mptun", "set_config"]}
    @out-example: {"jsonrpc": "2.0", "id": 1, "result": {}}
--]]
function M.set_config(params)
    local c = uci.cursor()
    local enable = params.enable
    local mode = params.mode or tonumber(c:get("mptun", "global", "mode"))
    local node_name = params.node_name or c:get("mptun", "global", "node") or "unknown"
    local interfaces = params.mptun_interfaces or {}

    if enable == nil then
        enable = c:get("mptun", "global", "enable") == "1"
    end

    if type(enable) ~="boolean" or type(node_name) ~= "string" or type(mode) ~= "number" then
        return {
            err_code = -ERR_PARAMETER_TYPE,
            err_msg = 'Parameter type error.'
        }
    end

    c:set("mptun", "global", "enable", enable and 1 or 0)
    c:set("mptun", "global", "mode", mode)

    for _, info in pairs(interfaces) do
        local interface = info.interface
        local metric = info.metric
        local mp_iface = interface
        if string.find(interface, "modem") and not string.find(interface, "_4") then
            mp_iface = interface .. "_4"
        end

--[[
        if kmwan.get_ifstatus(interface) == "online" then
            c:set("mptun", mp_iface, "mptcp_flags", {"subflow"})
        else
            if c:get("mptun", mp_iface, "mptcp_flags") then
                c:delete("mptun", mp_iface, "mptcp_flags")
            end
        end
--]]
        c:set("mptun", mp_iface, "metric", metric)
        c:commit("mptun")
    end

    c:set("mptun", "global", "node", node_name)

    c:commit("mptun")
    fs.sync()

    if enable then
        ngx.timer.at(2.0, function()
            ngx.pipe.spawn({"/usr/bin/parse_mpcfg", node_name}):wait()
            ngx.pipe.spawn({"/etc/init.d/mpifd", "stop"}):wait()
            ngx.pipe.spawn({"/etc/init.d/mptun", "stop"}):wait()
            ngx.pipe.spawn({"/etc/init.d/kmwan", "stop"}):wait()
            ngx.pipe.spawn({"/etc/init.d/mptun", "start"}):wait()
            ngx.pipe.spawn({"/etc/init.d/kmwan", "start"}):wait()
            ngx.pipe.spawn({"/etc/init.d/mpifd", "start"}):wait()
        end)
    else
        ngx.timer.at(2.0, function()
            ngx.pipe.spawn({"/etc/init.d/mpifd", "stop"}):wait()
            ngx.pipe.spawn({"/etc/init.d/mptun", "stop"}):wait()
            ngx.pipe.spawn({"/etc/init.d/kmwan", "restart"}):wait()
        end)
    end
end

--[[
    @method-type: call
    @method-name: get_config
    @method-desc: get mprouter config

    @out array   interfaces Interfaces information that participate in aggregation network.
    @out string   interfaces.name Name of the interface.
    @out bool   interfaces.enable Indicates whether the interface is enabled.

    @in-example:  {"jsonrpc":"2.0","id":1,"method":"call","params":["NsPHdkXtENoaotxVZWLqJorU52O7J0OI", "mptun", "get_config"]}
    @out-example: {"jsonrpc": "2.0", "id": 1, "result": {}}
--]]
function M.get_config()
    local c = uci.cursor()
    local enable = c:get("mptun", "global", "enable") == "1" and true or false
    --Drop the starting '/etc/mptun/' and the ending '.cfg'
    --local node_name = c:get("mptun", "config", "profile"):sub(12, -5)
    local node_name = c:get("mptun", "global", "node") or "default"
    local mptun_interfaces = {}
    local mode = c:get("mptun", "global", "mode") or "0"


    c:foreach("mptun", "interface", function(s)
        local array = {}
        local metric = c:get("mptun", s[".name"], "metric")
        if c:get("kmwan", s[".name"], "interface") then
            array.interface = s[".name"]
        else
            array.interface = s[".name"]:sub(1,-3)
        end
        array.metric = tonumber(metric)
        mptun_interfaces[#mptun_interfaces+1] = array
    end)

    return {
        enable = enable,
        mode = tonumber(mode),
        node_name = node_name,
        mptun_interfaces = mptun_interfaces
    }
end

--[[
    @method-type: call
    @method-name: get_status
    @method-desc: get mprouter network status

    @out string name name of the device in the network
    @out string type type of the device in the network
    @out array ?nodes Information about connections to other nodes, If the object does not exist, means the current device does not belong to any network
    @out object nodes.self information of the node
    @out string nodes.self.name Name of the node
    @out bool nodes.self.status Indicates whether the node is online.
    @out number nodes.self.type Type of the node(0:edge, 1:gateway)
    @out number nodes.self.acl_type Type of the access policy(0:none, 1:allow to local 2:allow to subnet)
    @out bool  nodes.self.bond Indicates whether the connection is bonding.
    @out object nodes.peer information of the peer(device self)
    @out number nodes.peer.acl_type Type of the access policy(0:none, 1:allow to local 2:allow to subnet)
    @out bool  nodes.peer.bond Indicates whether the connection is bonding.

    @in-example:  {"jsonrpc":"2.0","id":1,"method":"call","params":["NsPHdkXtENoaotxVZWLqJorU52O7J0OI", "mptun", "get_status"]}
    @out-example: {"jsonrpc": "2.0", "id": 1, "result": {}}
]]
function M.get_status()

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

end

function M.get_node_list()
    ubus.call("gl-cloud", "mpnodes")
    local data = {}

    if fs.access('/etc/mptun/nodelist') then
        data = utils.readfile("/etc/mptun/nodelist")
        data = cjson.decode(data)
    end

    return {nodes = data}
end

return M
