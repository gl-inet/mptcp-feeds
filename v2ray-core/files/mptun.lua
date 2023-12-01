--[[
    @object-name: mprouter
    @object-desc: mprouter settings
--]]

local uci = require "uci"
local fs = require "oui.fs"
local ubus = require "oui.ubus"
local kmwan = require "gl.kmwan"
local utils = require "oui.utils"
local cjson = require "cjson"

local M = {}

local ERR_PARAMETER_TYPE = 1

--[[
    @method-type: call
    @method-name: set_config
    @method-desc: set mprouter config

    @in boolean ?enable                  mptun enable
    @in number  ?mode                    mptun mode [0: main-subflow 1: main-backup]
    @in string  ?node_name               mptun connected node name
    @in array   ?mptun_interfaces        mptun interface info
    @in string  ?interfaces.interface 
    @in string  ?interfaces.metric

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

        if kmwan.get_ifstatus(interface) == "online" then
            c:set("mptun", mp_iface, "mptcp_flags", {"subflow"})
        else
            if c:get("mptun", mp_iface, "mptcp_flags") then
                c:delete("mptun", mp_iface, "mptcp_flags")
            end
        end

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
            ngx.pipe.spawn({"/etc/init.d/mpifd", "start"}):wait()
            ngx.pipe.spawn({"/etc/init.d/mptun", "start"}):wait()
            ngx.pipe.spawn({"/etc/init.d/kmwan", "start"}):wait()
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

    @out boolean enable :mptun enable
    @out number  mode   :mptun mode [0: main-subflow 1: main-backup]
    @out string  node_name
    @out table   mptun_interfaces
    @out string  mptun_interfaces.interface      the network interface participating in the aggregation
    @out table   mptun_interfaces.mptun_flags    mptun_flags flag used by the interface[main: main network interface; subflow: Subdata flow interface;
                                                fullmesh: for full mesh structure; backup:backup network interface,is forbidden by the main interface.]
    @out string  ?signal                         signal received by the interface
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
    @method-name: get_config
    @method-desc: get mprouter status

    @out array nodes: "node list",
]]
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
