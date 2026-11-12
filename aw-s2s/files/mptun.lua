--[[
    @object-name: mptun
    @object-desc: mptun settings
--]]

local uci = require "uci"
local fs = require "oui.fs"
local ubus = require "oui.ubus"
local utils = require "oui.utils"
local cjson = require "cjson"
local http = require "resty.http"

local M = {}

local ERROR_CODES = {
    operation_failed = 10,
    invalid_params = 11,
    busy = 12,
    state_not_allowed = 13,
    state_changed = 14,
    invalid_cloud_response = 15,
    plan_expired = 200,
    device_limit_exceeded = 201,
    access_locked = 202,
    access_verification_failed = 203,
    kicked_out_cleanup_required = 204,
    startup_conditions_not_met = 210,
    upgrade_sync_pending = 211,
    wifi_fetch_required = 220,
    speedtest_target_unavailable = 230
}

local function get_error_code(name)
    local DEFAULT_error_code = 10
    return ERROR_CODES[name] or DEFAULT_error_code
end

local ERR_PARAMETER = 1
local SPEEDTEST_INTERFACE = "mptun0"
local DEFAULT_SPEEDTEST_ENABLE = "1"
local DEFAULT_SPEEDTEST_TYPE = "tunspeed"
local DEFAULT_SPEEDTEST_PORT = 7890
local SPEEDTEST_CLIENT_INFO_FILE = "/etc/mp_connection_info"
local SPEEDTEST_CLIENT_UBUS_OBJECT = "mpifd.speedtest_client"
local SPEEDTEST_CLIENT_WS_NAME = "mptun.speedtest_client_result"
local SPEEDTEST_CLIENT_ERROR = "speedtest_failed"
local MAX_SPEEDTEST_BITS_PER_SECOND = 1000 * 1000 * 1000 * 1000

local req_path = {
    ["req_get_identity"] = "/sdwan/sdk-iprb/v1/my/network/simple",
    ["req_get_seconds_list"] = "/sdwan/sdk-iprb/v1/secondary/list",
    ["req_add_access_code"] = "/sdwan/sdk-iprb/v1/device/access/dynamic-code/generate",
    ["req_get_access_code_list"] = "/sdwan/sdk-iprb/v1/device/access/dynamic-code/list",
    ["req_delete_access_code"] = "/sdwan/sdk-iprb/v1/device/access/dynamic-code",
    ["req_set_access_code_alias"] = "/sdwan/sdk-iprb/v1/device/access/dynamic-code/clientAlias",
    ["req_clear_invalid_access_code"] = "/sdwan/sdk-iprb/v1/device/access/dynamic-code/expired",
    ["req_get_bind_code"] = "/sdwan/sdk-iprb/v1/device/bind/dynamic-code",
    ["req_remove_second"] = "/sdwan/sdk-iprb/v1/device/client/remove",
    ["req_get_bind_info"] = "/sdwan/sdk-iprb/v1/bindInfo",
    ["req_net_ctrl"] = "/sdwan/sdk-iprb/v1/network/status/ctrl",
    ["req_access_by_code"] = "/sdwan/sdk-iprb/v1/device/dynamic-code/access",
    ["req_second_rename"] = "/sdwan/sdk-iprb/v1/network/secondary/rename",
    ["req_use_exit"] = "/sdwan/sdk-iprb/v1/device/useInternetExit",
    ["req_get_pay_url"] = "/sdwan/sdk-iprb/v1/pay/url",
    ["req_reset"] = "/sdwan/sdk-iprb/v1/device/network/reset",
}
local valid_req_path = {
    [req_path["req_get_identity"]] = true,
    [req_path["req_get_seconds_list"]] = true,
    [req_path["req_add_access_code"]] = true,
    [req_path["req_get_access_code_list"]] = true,
    [req_path["req_delete_access_code"]] = true,
    [req_path["req_set_access_code_alias"]] = true,
    [req_path["req_clear_invalid_access_code"]] = true,
    [req_path["req_get_bind_code"]] = true,
    [req_path["req_remove_second"]] = true,
    [req_path["req_get_bind_info"]] = true,
    [req_path["req_net_ctrl"]] = true,
    [req_path["req_access_by_code"]] = true,
    [req_path["req_second_rename"]] = true,
    [req_path["req_use_exit"]] = true,
    [req_path["req_get_pay_url"]] = true,
    [req_path["req_reset"]] = true,
}

local valid_req_header = {
    ["content-type"] = true
}

local valid_req_header_value = {
    ["application/json"] = true
}

local valid_req_method = {
    ["GET"] = true,
    ["POST"] = true,
    ["PUT"] = true,
    ["DELETE"] = true
}

local valid_query_and_body_params = {
    ["dynamicCode"] = "^[%w%_%-]+$",
    ["accessCode"] = "^[%w%_%-]+$",
    ["code"] = "^[%w%_%-]+$",
    ["networkId"] = "^%w+$",
    ["clientAlias"] = "^.*$", -- 名称原样透传；标准 RPC 单独限制 128 字节。
    ["aliasName"] = "^.*$",   -- raw_request 不额外限制名称长度或字符。
    ["sort"] = "^[%w%_%-%,]+$",
    ["gatewayIp"] = "^[%d%.]+$",
    ["interfaceName"] = "^[%w%_%-%.]+$",
    ["network"] = "^[%d%./]+$",
    ["type"] = "^[%w%_%-]+$",

    ["DEFAULT"] = "^[%w%_%-]+$"
}

local function is_valid_ipv4(ip)
    if type(ip) ~= 'string' then
        return false
    end

    local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if a == nil then
        return false
    end

    for _, octet in ipairs({ a, b, c, d }) do
        local value = tonumber(octet)
        if value == nil or value < 0 or value > 255 or #octet > 3 or
            (#octet > 1 and octet:sub(1, 1) == '0') then
            return false
        end
    end

    return true
end

local function is_valid_canonical_ipv4(ip)
    if not is_valid_ipv4(ip) or #ip < 7 or #ip > 15 then
        return false
    end

    for octet in ip:gmatch("[^.]+") do
        if #octet > 3 or (#octet > 1 and octet:sub(1, 1) == "0") then
            return false
        end
    end

    return true
end

local function is_valid_positive_integer(value)
    return type(value) == "number" and value == value and
        value > 0 and value < math.huge and value == math.floor(value)
end

local function speedtest_client_service_unavailable()
    return {
        err_code = -3,
        err_msg = "speedtest client service is unavailable"
    }
end

local function normalize_speedtest_client_start_result(result)
    -- An empty, nil or future successful response still means accepted. Do not
    -- expose fields added by the local ubus service.
    if type(result) ~= "table" or result.err_code == nil then
        return {}
    end

    if result.err_code == -1 then
        return {
            err_code = get_error_code('operation_failed'),
            err_msg = "invalid speedtest client target"
        }
    end

    if result.err_code == -2 then
        return {
            err_code = get_error_code('busy'),
            err_msg = "speedtest client is running"
        }
    end

    return { err_code = get_error_code('operation_failed'), err_msg = 'speedtest client service is unavailable' }
end

-- The backend owns the snapshot. Rebuild the public shape and preserve []
-- across ubus, which can represent an empty Lua array as an empty object.
local function speedtest_client_snapshot(notify)
    local result, err = ubus.call(SPEEDTEST_CLIENT_UBUS_OBJECT, "status", {}, 500)
    if err or type(result) ~= "table" then return nil end
    if result.status ~= "pending" and result.status ~= "testing" and
        result.status ~= "finished" then return nil end
    if type(result.data) ~= "table" then return nil end

    local data = setmetatable({}, cjson.array_mt)
    local count = 0
    for key in pairs(result.data) do
        if not is_valid_positive_integer(key) then return nil end
        count = count + 1
    end
    for i = 1, count do
        local point = result.data[i]
        if type(point) ~= "table" or point.second ~= i or
            type(point.value) ~= "number" or point.value ~= point.value or
            point.value < 0 or point.value > MAX_SPEEDTEST_BITS_PER_SECOND or
            point.value ~= math.floor(point.value) then return nil end
        data[i] = { second = i, value = point.value }
    end
    if result.status == "pending" and count ~= 0 then return nil end
    local snapshot = { status = result.status, data = data }
    if result.latency_ms ~= nil then
        local latency = result.latency_ms
        if result.status == "pending" or type(latency) ~= "number" or
            latency ~= latency or latency < 0 or latency >= math.huge then return nil end
        snapshot.latency_ms = latency
    end
    if result.status == "finished" then
        if count == 0 or not is_valid_positive_integer(result.finished_at) then return nil end
        snapshot.finished_at = result.finished_at
    elseif notify and result.status == "pending" and result.error == SPEEDTEST_CLIENT_ERROR then
        snapshot.error = SPEEDTEST_CLIENT_ERROR
    end
    return snapshot
end

-- Non-function exports are not registered as HTTP RPCs by oui.rpc.
-- WebSocket subscription uses this internal reader; there is no public GET.
M._speedtest_client = {
    snapshot = function()
        return speedtest_client_snapshot(false) or
            { status = "pending", data = setmetatable({}, cjson.array_mt) }
    end
}

local function is_valid_ipv4_cidr(network)
    if type(network) ~= 'string' then
        return false
    end

    local ip, prefix = network:match("^([^/]+)/(%d+)$")
    if ip == nil or prefix == nil then
        return false
    end

    local prefix_num = tonumber(prefix)
    if prefix_num == nil or prefix_num < 0 or prefix_num > 32 then
        return false
    end

    return is_valid_ipv4(ip)
end

local function speedtest_items(value)
    return (value:gsub("，", ",")):gmatch("[^,%s]+")
end

local function get_speedtest_ip(c)
    local profile = c:get("mptun", "config", "profile")
    if type(profile) ~= "string" or profile == "" then
        return nil
    end

    local data = utils.readfile(profile)
    if type(data) ~= "string" or data == "" then
        return nil
    end

    local ok, config = pcall(cjson.decode, data)
    if not ok or type(config) ~= "table" or
        type(config.udpTun) ~= "table" or
        type(config.udpTun.interface) ~= "table" then
        return nil
    end

    local interface = config.udpTun.interface
    local address = interface.address
    local allowed_src = interface.allowedSrc
    if type(address) ~= "string" or type(allowed_src) ~= "string" then
        return nil
    end

    local has_source = false
    for source in speedtest_items(allowed_src) do
        if is_valid_ipv4(source) or is_valid_ipv4_cidr(source) then
            has_source = true
            break
        end
    end
    if not has_source then
        return nil
    end

    for item in speedtest_items(address) do
        if is_valid_ipv4(item) then
            return item
        end

        if is_valid_ipv4_cidr(item) then
            return item:match("^([^/]+)/")
        end
    end

    return nil
end

local function get_speedtest_options(c)
    local enabled = c:get("mptun", "global", "enable_speedtest")
    if enabled ~= "0" and enabled ~= "1" then
        enabled = DEFAULT_SPEEDTEST_ENABLE
    end

    local activator_type = c:get("mptun", "global", "speedtest_type")
    if activator_type == nil or activator_type == "" then
        activator_type = DEFAULT_SPEEDTEST_TYPE
    elseif activator_type ~= DEFAULT_SPEEDTEST_TYPE then
        -- Never advertise HTTP under an explicitly configured old/unknown type.
        -- The upgrade script migrates the old iperf selection once.
        enabled = "0"
    end

    local port_value = c:get("mptun", "global", "speedtest_port")
    local port
    if type(port_value) == "string" and port_value:match("^%d+$") then
        port = tonumber(port_value)
    end
    if not port or port < 1 or port > 65535 then
        port = DEFAULT_SPEEDTEST_PORT
    end

    return enabled, activator_type, port
end

local function get_speedtest_client_target(c)
    if c:get("mptun", "global", "service_mode") ~= "IPRB" or
        c:get("mptun", "IPRB", "identity") ~= "secondary" or
        c:get("mptun", "global", "enable") ~= "1" or
        c:get("mptun", "global", "mptun") ~= SPEEDTEST_INTERFACE then
        return nil
    end

    local enabled, _, port = get_speedtest_options(c)
    if enabled ~= "1" or not fs.access("/sys/class/net/" .. SPEEDTEST_INTERFACE) then
        return nil
    end

    local data = utils.readfile(SPEEDTEST_CLIENT_INFO_FILE)
    if type(data) ~= "string" or data == "" then
        return nil
    end

    local ok, info = pcall(cjson.decode, data)
    if not ok or type(info) ~= "table" or type(info.connection) ~= "table" then
        return nil
    end

    for _, connection in ipairs(info.connection) do
        local target = type(connection) == "table" and connection.target or nil
        if is_valid_canonical_ipv4(target) and target ~= "0.0.0.0" then
            return target, port
        end
    end

    return nil
end
local function vpn_is_tap_s2s()
    local rpc_ret = ubus.call("gl-session", "call", { module = "vpn-client", func = "get_status", params = {} })
    if rpc_ret ~= nil and rpc_ret.result ~= nil and type(rpc_ret.result) == 'table' and rpc_ret.result.status_list ~= nil and type(rpc_ret.result.status_list) == 'table' then
        for _, v in pairs(rpc_ret.result.status_list) do
            if v ~= nil and v.type ~= nil and type(v.type) == 'string' and v.type == 'tap-s2s' then
                if v.enabled ~= nil and type(v.enabled) == 'boolean' and v.enabled == true then
                    return true
                end
            end
        end
    end
    return false
end

local function is_valid_netmode()
    local c = uci.cursor()
    return c:get("glconfig", "general", "mode") == 'router' or c:get("glconfig", "general", "mode") == 'agent'
end

local function __is_meet_startup_conditions()
    if vpn_is_tap_s2s() == true then
        return false
    end
    if is_valid_netmode() == false then
        return false
    end
    return true
end
local function check_req_header(k, v)
    if not k and not v then
        return true
    end
    if v and v ~= '' and not valid_req_header_value[v] then
        return false
    end
    if not k or not valid_req_header[string.lower(tostring(k))] then
        return false
    end
    return true
end

local function check_payload_header(key, value)
    if key == nil then
        return true
    end
    if type(key) ~= 'string' then
        return false
    end
    local clean_k = key:match("^%s*(.-)%s*$")
    if string.match(clean_k, valid_query_and_body_params["DEFAULT"]) ~= clean_k then
        return false
    end
    if value and value ~= '' then
        local clean_v = value:match("^%s*(.-)%s*$")
        local pattern = valid_query_and_body_params[key] or valid_query_and_body_params["DEFAULT"]
        return string.match(clean_v, pattern) == clean_v
    end
    return true
end

-- validate_func: check query params and body params
local function check_params_valid(params, checkfunc)
    local function check(key, value)
        if value == nil then
            return true
        end
        local t = type(value)
        if t == "string" then
            return checkfunc(key, value)
        elseif t == "table" then
            for k, v in pairs(value) do
                if type(k) ~= 'number' and not checkfunc(k, nil) then
                    return false
                end
                local real_k = k
                if type(k) == 'number' then
                    real_k = key
                end
                if check(real_k, v) == false then
                    return false
                end
            end
        end
        return true
    end
    if params == nil then
        return true
    end
    if checkfunc == nil then
        return false
    end
    return check(nil, params)
end

local function notify_gl_cloud_module_detached()
    return ubus.call('gl-session', 'call', {
        module = 'cloud',
        func = 'notify_module_detached',
        params = { module = 'mptun' }
    })
end

local function net_topology_is_exist()
    for _ = 1, 15 do
        if fs.access('/etc/mptun/mpnet_conf') then
            return true
        end
        ngx.sleep(1)
    end
    return false
end

-- Best-effort local snapshot; each observation is collected independently.
-- Missing mpifd_pid means stopped or unavailable. Missing interfaces means
-- unavailable; an empty interfaces/addresses list means a successful empty result.
local function collect_runtime_status()
    -- Returns a running mpifd PID, or nil if unavailable.
    local function collect_mpifd_pid()
        -- oui.ubus may yield, so do not wrap it in Lua 5.1 pcall.
        local services, err = ubus.call("service", "list", { name = "mpifd" })
        if err or type(services) ~= "table" then return nil end

        local service = services.mpifd
        if type(service) ~= "table" or type(service.instances) ~= "table" then return nil end
        for _, instance in pairs(service.instances) do
            if type(instance) == "table" and instance.running == true and
                type(instance.pid) == "number" and instance.pid > 0 then
                return instance.pid
            end
        end
        return nil
    end

    -- Returns the configured tunnel's actual kernel state, or nil if unavailable.
    local function collect_runtime_interfaces()
        local c = uci.cursor()
        local name = c:get("mptun", "global", "mptun")
        if c.close then c:close() end
        if name == nil or name == "" then name = "mptun0" end
        -- Linux interface names are at most 15 bytes; accept simple device names only.
        if type(name) ~= "string" or #name > 15 or
            not name:match("^[%w_][%w_.%-]*$") then
            return nil
        end

        -- Pass the interface name as one argument, without shell interpolation.
        local process = ngx.pipe.spawn({ "ip", "-j", "address", "show", "dev", name }, {
            merge_stderr = true, stdout_read_timeout = 2000, wait_timeout = 2000
        })
        if not process then return nil end
        local output = process:stdout_read_all()
        if not output and process.kill then process:kill(9) end
        local ok, reason, status = process:wait()
        if not ok and reason ~= "exit" and reason ~= "signal" and process.kill then
            process:kill(9)
            process:wait()
        end
        -- Firmware's command proxy returns output from wait(), not an exit tuple.
        -- Its stdout_read_timeout also bounds the command's execution.
        if not output or not ok or
            (type(ok) ~= "string" and (reason ~= "exit" or status ~= 0)) then
            return nil
        end

        local decoded, devices = pcall(cjson.decode, output)
        if not decoded or type(devices) ~= "table" or not output:match("^%s*%[") then
            return nil
        end
        local interfaces = {}
        for _, device in ipairs(devices) do
            if type(device) ~= "table" or type(device.ifname) ~= "string" or
                type(device.flags) ~= "table" or type(device.addr_info) ~= "table" then
                return nil
            end
            local interface = { name = device.ifname, up = false, addresses = {} }
            for _, flag in ipairs(device.flags) do
                if flag == "UP" then interface.up = true end
            end
            for _, address in ipairs(device.addr_info) do
                if type(address) ~= "table" then return nil end
                if address.family == "inet" or address.family == "inet6" then
                    if type(address["local"]) ~= "string" or type(address.prefixlen) ~= "number" then
                        return nil
                    end
                    interface.addresses[#interface.addresses + 1] = {
                        family = address.family,
                        address = address["local"],
                        prefixlen = address.prefixlen
                    }
                end
            end
            interfaces[#interfaces + 1] = interface
        end
        return interfaces
    end

    local result = {}
    local pid = collect_mpifd_pid()
    if type(pid) == "number" and pid > 0 and pid % 1 == 0 then
        result.mpifd_pid = pid
    end

    local interfaces = collect_runtime_interfaces()
    if type(interfaces) == "table" then
        result.interfaces = interfaces
    end
    return result
end

-- Checks local readiness only, not peer connectivity. Missing observations
-- return false; callers must account for queries failing or startup in progress.
local function is_mptun_running()
    local c = uci.cursor()
    local enabled = c:get("mptun", "global", "enable")
    local interface_name = c:get("mptun", "global", "mptun")
    if c.close then c:close() end
    if enabled ~= "1" then return false end
    if interface_name == nil or interface_name == "" then interface_name = "mptun0" end
    local status = collect_runtime_status()
    if not status.mpifd_pid or not status.interfaces then
        return false
    end

    for _, interface in ipairs(status.interfaces) do
        if interface.name == interface_name and interface.up then
            for _, address in ipairs(interface.addresses) do
                if address.family == "inet" then
                    local a, b, c, d = address.address:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
                    if a and tonumber(a) <= 255 and tonumber(b) <= 255 and
                        tonumber(c) <= 255 and tonumber(d) <= 255 and
                        address.prefixlen >= 0 and address.prefixlen <= 32 and
                        address.prefixlen % 1 == 0 then
                        return true
                    end
                end
            end
        end
    end
    return false
end

--[[
    @method-type: call
    @method-name: set_config
    @method-desc: set mptun config

    @in array   interfaces Interfaces information that participate in aggregation network.
    @in string  interfaces.name Name of the interface.
    @in bool    interfaces.enable Indicates whether the interface is enabled.
    @in-example:  {"jsonrpc":"2.0","id":1,"method":"call","params":["","mptun","set_config",{"interfaces":[{"name":"wan","enable":true},{"name":"secondwan","enable":true}, {"name":"wwan","enable":true},{"name":"tethering","enable":true},{"name":"modem_0000_4","enable":false}]}]}
    @out-example: {"jsonrpc": "2.0", "id": 1, "result": []}
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

    for i = 1, #interfaces do
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
        ngx.pipe.spawn({ "/etc/init.d/mptun", "restart" }):wait()
        ngx.pipe.spawn({ "/etc/init.d/mpifd", "restart" }):wait()
        ngx.pipe.spawn({ "/etc/init.d/kmwan", "restart" }):wait()
        ngx.pipe.spawn({ "/etc/init.d/mpflow", "restart" })
    end)

    -- This function updates /etc/config/mptun, so subsequent processes may require reloading it.
end

--[[
    @method-type: call
    @method-name: get_config
    @method-desc: get mptun config

    @out array   interfaces Interfaces information that participate in aggregation network.
    @out string  interfaces.name Name of the interface.
    @out bool    interfaces.enable Indicates whether the interface is enabled.

    @in-example:  {"jsonrpc":"2.0","id":1,"method":"call","params":["", "mptun", "get_config"]}
    @out-example: {"jsonrpc": "2.0", "id": 1, "result": {"interfaces":[{"name":"wan","enable":true},{"name":"secondwan","enable":true},{"name":"wwan","enable":false},{"name":"tethering","enable":false}]}}
--]]
function M.get_config()
    local c = uci.cursor()
    local ifaces = {}

    c:foreach("mptun", "interface", function(s)
        local array = {}
        local enable = tonumber(c:get("mptun", s[".name"], "enable") or "0")
        array.name = s[".name"]
        array.enable = enable == 1
        ifaces[#ifaces + 1] = array
    end)

    return { interfaces = ifaces }
end

--[[
    @method-type: call
    @method-name: get_speedtest_info_list
    @method-desc: get the single speed-test endpoint owned by aw-s2s

    @out array   endpoint Speed-test endpoint list; empty when no endpoint is available.
    @out string  endpoint.interface Interface that owns the endpoint.
    @out string  endpoint.ip_address IPv4 address of the endpoint.
    @out string  endpoint.activator_type Speed-test activator type.
    @out number  endpoint.port TCP port of the endpoint.

    @in-example:  {"jsonrpc":"2.0","id":1,"method":"call","params":["","mptun","get_speedtest_info_list",{}]}
    @out-example: {"jsonrpc":"2.0","id":1,"result":[{"interface":"mptun0","ip_address":"10.10.227.2","activator_type":"tunspeed","port":7890}]}

    An empty result means that aw-s2s currently publishes no speed-test
    configuration. This read-only method consumes no input parameters and does not
    verify firewall, NFQUEUE, mpifd or tunspeed runtime state.
--]]
function M.get_speedtest_info_list()
    local c = uci.cursor()

    if c:get("mptun", "global", "service_mode") ~= "IPRB" or
        c:get("mptun", "IPRB", "identity") ~= "primary" then
        return {}
    end

    local enabled, activator_type, port = get_speedtest_options(c)
    if enabled ~= "1" or c:get("mptun", "global", "enable") ~= "1" or
        c:get("mptun", "global", "mptun") ~= SPEEDTEST_INTERFACE then
        return {}
    end

    if not fs.access("/sys/class/net/" .. SPEEDTEST_INTERFACE) then
        return {}
    end

    local ip = get_speedtest_ip(c)
    if not ip then
        return {}
    end

    return {{
        interface = SPEEDTEST_INTERFACE,
        ip_address = ip,
        activator_type = activator_type,
        port = port
    }}
end

--[[
    @method-type: call
    @method-name: start_speedtest_client
    @method-desc: start one asynchronous ping followed by a tunspeed HTTP upload test

    @out number  ?err_code Error code when the request cannot be accepted.
    @out string  ?err_msg Error message when the request cannot be accepted.

    @in-example:  {"jsonrpc":"2.0","id":1,"method":"call","params":["","mptun","start_speedtest_client",{}]}
    @out-example: {"jsonrpc":"2.0","id":1,"result":[]}
--]]
function M.start_speedtest_client()
    local address, port = get_speedtest_client_target(uci.cursor())
    if not address then
        return {
            err_code = get_error_code('speedtest_target_unavailable'),
            err_msg = "speedtest client target is unavailable"
        }
    end

    local result, err = ubus.call(SPEEDTEST_CLIENT_UBUS_OBJECT, "run", {
        address = address,
        port = port
    })
    if err ~= nil then
        return { err_code = get_error_code('operation_failed'), err_msg = 'speedtest client service is unavailable' }
    end

    -- ngx-ubus-proxy may decode an empty successful ubus reply as nil or
    -- cjson.null. The absence of an accompanying error still means that
    -- mpifd accepted the request. Never expose the local ubus response table.
    return normalize_speedtest_client_start_result(result)
end

--[[
    @method-type: call
    @method-name: push_speedtest_client_result_to_wb
    @method-desc: read the backend snapshot and notify speed-test subscribers
    @out string ?status Status successfully submitted to gl-session.notify.
    @out number ?err_code Notification or snapshot failure.
    @out string ?err_msg Failure description.
    @in-example: {"jsonrpc":"2.0","id":1,"method":"call","params":["","mptun","push_speedtest_client_result_to_wb",{}]}
    @out-example: {"jsonrpc":"2.0","id":1,"result":{"status":"testing"}}
--]]
function M.push_speedtest_client_result_to_wb()
    local snapshot = speedtest_client_snapshot(true)
    if not snapshot then return speedtest_client_service_unavailable() end
    local _, err = ubus.call("gl-session", "notify", {
        name = SPEEDTEST_CLIENT_WS_NAME, data = snapshot
    }, 500)
    if err then return { err_code = -3, err_msg = "speedtest notification failed" } end
    -- The publisher uses the status actually sent, including completion that
    -- occurred while this RPC was querying mpifd, to avoid a second final push.
    return { status = snapshot.status }
end
--[[
    @method-type: call
    @method-name: get_status
    @method-desc: get mptun network status

    @out string name Name of the device in the network
    @out number status Whether the device is in an aggregated network (0:offline 1:online 2:disable)
    @out string network_name The network name field obtained from the cloud platform
    @out number type Native information(0: edge 1:cloud gateway 2: local gateway)
    @out array ?nodes Information about connections to other nodes, If the object does not exist, means the current device does not belong to any network
    @out object nodes.self information of the node
    @out string nodes.self.name Name of the node
    @out number nodes.self.status Indicates whether the node is online.(0:offline 1:online 2:warning)
    @out number nodes.self.type Type of the node(0:edge, 1:cloud gateway 2 local gateway)
    @out number nodes.self.acl_type Type of the access policy(0:none, 1:allow to local 2:allow to subnet)
    @out number nodes.self.bond Indicates whether the connection is bonding.(0:none 1:aggregation 2:s2s 3:aggregation+s2s)
    @out object nodes.peer Information of the peer(device self)
    @out number nodes.peer.acl_type Type of the access policy(0:none, 1:allow to local 2:allow to subnet)
    @out number nodes.peer.bond Indicates whether the connection is bonding.(0:none 1:aggregation 2:s2s 3:aggregation+s2s)
    @out bool nodes.peer.connect Whether the node is connected to other nodes

    @in-example:  {"jsonrpc":"2.0","id":1,"method":"call","params":["", "mptun", "get_status"]}
    @out-example: {"jsonrpc": "2.0", "id": 1, "result": {"network_name":"test","type":0,"name":"mt6000","nodes":[{"self":{"acl_type":2,"type":1,"name":"test","status":1,"bond":1},"peer":{"acl_type":0,"bond":0,"connect":true}}],"status":1}}
]]
function M.get_status()
    local c = uci.cursor()
    local cloud_enable = c:get("gl-cloud", "@cloud[0]", "enable") or "0"
    local conf = {}

    if cloud_enable ~= "0" then
        ubus.call('gl-cloud', 'notify', { type = 'astrowarp/get_device_net_topology' })
        local aw_enable = c:get('mptun', 'global', 'enable') or "0"
        if aw_enable == "0" then
            if fs.access('/etc/mptun/mpnet_conf') then
                conf = cjson.decode(utils.readfile("/etc/mptun/mpnet_conf") or "{}")
            else
                return {}
            end
        else
            if net_topology_is_exist() then
                conf = cjson.decode(utils.readfile("/etc/mptun/mpnet_conf") or "{}")
            else
                return {}
            end
        end
    end

    local status = 1
    local loop_cnt = 0

    if not conf.peer or #conf.peer == 0 then
        status = 0
    else
        loop_cnt = #conf.peer
    end

    if conf.dev_status == "offline" then
        status = 0
    elseif conf.dev_status == "disable" then
        status = 2
    end

    local nodes = {}
    local network_name
    local network_status = conf.networkStatus or "disable"
    for i = 1, loop_cnt do
        local node = {}
        local self = {}
        local peer = {}
        self.name = conf.peer[i].name

        self.status = 0
        if conf.peer[i].nodeType == "CLOUD_GATEWAY" then
            self.type = 1
            -- cloud gateway status should be 'enable/disable',
            -- but the old version users 'online'
            if conf.peer[i].status == "enable" or conf.peer[i].status == "online" then
                self.status = network_status ~= "disable" and 1 or 0
            end
        elseif conf.peer[i].edgeType and conf.peer[i].edgeType == "LOCAL_GATEWAY" then
            self.type = 2
            if conf.peer[i].status == "online" then
                self.status = 1
            end
        else
            self.type = 0
            if conf.peer[i].status == "online" then
                self.status = 1
            elseif conf.peer[i].status == "disable" then
                self.status = 2
            end
        end

        peer.acl_type = 0
        self.acl_type = 0
        self.bond = 0
        peer.bond = 0
        peer.connect = true
        if conf.peer[i].connectionType == "aggregation" then
            network_name = conf.peer[i].name
            self.bond = 1
            self.acl_type = 1
        elseif conf.peer[i].connectionType == "none" then
            peer.connect = false
        else
            if conf.peer[i].fromAllowAccess and
                conf.peer[i].fromAllowAccess == 1 then
                peer.acl_type = 2
            end
            if conf.peer[i].toAllowAccess and
                conf.peer[i].toAllowAccess == 1 then
                self.acl_type = 2
            end

            if conf.peer[i].nodeType and conf.peer[i].nodeType ~= "EDGE" then
                peer.bond = 1
            end

            if conf.peer[i].toAsInternetExit and conf.peer[i].toAsInternetExit == 1 then
                self.bond = 1
                if self.acl_type ~= 2 then
                    self.acl_type = 1
                end
            end

            if conf.peer[i].fromAsInternetExit and conf.peer[i].fromAsInternetExit == 1 then
                peer.bond = 1
                if peer.acl_type ~= 2 then
                    peer.acl_type = 1
                end
            end
        end
        node.self = self
        node.peer = peer
        nodes[#nodes + 1] = node
    end

    return {
        network_name = conf.networkName or network_name,
        name = conf.name,
        type = conf.type == 0 and 0 or 2,
        status = status,
        nodes = nodes
    }
end

--[[
    @method-type: call
    @method-name: get_traffic
    @method-desc: get traffic information

    @out object path An object that stores all aggregated interface traffic information.
    @out object path.$iface An object that stores traffic information about an aggregate interface. iface:[wan|wwan|secondwan|tethering|modem]
    @out array  ?path.$iface.tx Interface upload traffic
    @out array  ?path.$iface.rx Interface download traffic

    @in-example:  {"jsonrpc":"2.0","id":1,"method":"call","params":["", "mptun", "get_traffic"]}
    @out-example: {"jsonrpc": "2.0", "id": 1, "result": {"path":{"wan":{"rx":[13373,15484,13626],"tx":[16677,18612,12387]},"secondwan":{"rx":[19838,20956,11762],"tx":[11486,12092,6762]}}}}
]]
function M.get_traffic()
    ngx.pipe.spawn({ "/usr/bin/get_mpflow.sh" }):wait()
    local data = cjson.decode(utils.readfile("/tmp/mpflow.json") or "{}")
    if data.path then
        return { path = data.path }
    else
        return { path = {} }
    end
end

local function wait_token_update()
    for _ = 1, 15 do
        if fs.access('/etc/mptun/mp_token') then
            local data = cjson.decode(utils.readfile('/etc/mptun/mp_token') or "{}")
            if data.awDeviceToken then
                return data.awDeviceToken
            end
        end
        ngx.sleep(1)
    end
end

--[[
    @method-type: call
    @method-name: get_token
    @method-desc: get astrowarp http token

    @out string token  http token.

    @in-example:  {"jsonrpc":"2.0","id":1,"method":"call","params":["", "mptun", "get_token"]}
    @out-example: {"jsonrpc": "2.0", "id": 1, "result": {"token":"0ff048cecf3c49b6806b1432e64c8c8a"}}
--]]
function M.get_token()
    local msg = {
        data = {},
        type = 'astrowarp/get_aw_device_token'
    }
    os.remove('/etc/mptun/mp_token')
    ubus.call('gl-cloud', 'notify', msg)
    local res = wait_token_update() or ''

    if res == '' then
        return { err_code = -2, err_msg = 'Failed to obtain.' }
    end

    return { token = res }
end

local function __raw_request(params)
    local c = uci.cursor()
    local base_url = c:get("mptun", "global", "base_url") or 'https://goodpas-api.gl-inet.com'

    local cloud_token = c:get("gl-cloud", "@cloud[0]", "token") or nil
    if not cloud_token then
        return { err_code = -1, err_msg = 'invalid device token.' }
    end

    local req_path = params.req_path or nil
    local req_method = string.upper(tostring(params.req_method)) or nil
    local req_body = params.req_body or {}
    local query_params = params.query_params or {}
    local append_header = params.append_header or {}
    if not req_path or not req_method then
        return { err_code = -2, err_msg = 'invalid params.' }
    end
    -- parames safety check.
    local params_invalid = false
    if not valid_req_path[req_path] then
        params_invalid = true
    end
    if not valid_req_method[req_method] then
        params_invalid = true
    end
    if not check_params_valid(query_params, check_payload_header) then
        params_invalid = true
    end
    if not check_params_valid(req_body, check_payload_header) then
        params_invalid = true
    end
    if not check_params_valid(append_header, check_req_header) then
        params_invalid = true
    end
    if params_invalid then
        return { err_code = -2, err_msg = 'invalid params.' }
    end

    local timestamp = os.time() .. '000'
    local mac_file = io.open('/proc/gl-hw-info/device_mac', "r") or nil
    local mac = ''
    if mac_file then
        mac = mac_file:read("*a") or ''
        mac_file:close()
    end
    mac = mac:match("^%s*(.-)%s*$")
    if mac ~= '' then
        mac = mac:gsub(':', '')
    else
        return { err_code = -3, err_msg = 'invalid device mac' }
    end

    local url = string.format('%s%s', base_url, req_path)
    local sign = utils.sha256(tostring(cloud_token) .. tostring(timestamp) .. tostring(req_method) .. tostring(req_path))

    local req_header = {
        mac = mac,
        timestamp = timestamp,
        sign = sign,
        ["content-type"] = 'application/json'
    }
    -- check and set custom headers
    if append_header and type(append_header) == 'table' and #append_header > 0 then
        for k, v in pairs(append_header) do
            if k and type(k) == 'string' and valid_req_header[string.lower(tostring(k))] and v and valid_req_header_value[v] then
                req_header[k] = v
            end
        end
    end

    local opt = {
        headers = req_header,
        ssl_verify = true
    }
    if req_method == 'GET' then
        -- set custom query_params
        local append_url = ''
        if type(query_params) == 'table' then
            for k, v in pairs(query_params) do
                if k and v then
                    if type(v) == 'table' then
                        for per_k, per_v in pairs(v) do
                            if type(per_k) ~= 'number' then
                                return { err_code = -6, err_msg = 'method GET invalid param array.' }
                            end
                            append_url = string.format('%s&%s=%s', append_url,
                                ngx.escape_uri(tostring(k)), ngx.escape_uri(tostring(per_v)))
                        end
                    else
                        append_url = string.format('%s&%s=%s', append_url,
                            ngx.escape_uri(tostring(k)), ngx.escape_uri(tostring(v)))
                    end
                end
            end
        end
        if append_url ~= '' then
            url = string.format('%s?%s', url, append_url)
        end
        opt.method = "GET"
    else
        -- set custom body
        local body = {}
        if type(req_body) == 'table' then
            for k, v in pairs(req_body) do
                if v ~= nil and type(k) == 'string' then
                    body[k] = v
                end
            end
        end
        opt.method = req_method
        -- DELETE without fields has no body; POST/PUT retain JSON object bodies.
        if req_method ~= 'DELETE' or next(body) ~= nil then
            -- oui-rpc 将空 table 默认编码为 []；云端请求体在这里明确保持对象。
            opt.body = next(body) == nil and '{}' or cjson.encode(body)
        end
    end

    local httpc = http.new()
    httpc:set_timeout(15000)

    local resp, err = httpc:request_uri(url, opt)
    local need_debug = c:get("mptun", "global", "debug") == '1'
    if need_debug == true then
        local debug_info = {
            url = url,
            req_body = opt.body,
            req_header = req_header
        }
        local f_deb = io.open("/tmp/http_debug_info.log", "a")
        if resp ~= nil then
            if resp.status ~= nil and resp.body ~= nil then
                debug_info.resp_status = resp.status
                debug_info.resp_body = resp.body
            end
        end
        if f_deb ~= nil then
            f_deb:write(cjson.encode(debug_info) .. '\n')
            f_deb:close()
        end
    end
    if err ~= nil then
        return { err_code = -4, err_msg = tostring(err) }
    end
    if resp == nil or resp.status == nil or resp.body == nil then
        return { err_code = -5, err_msg = 'invalid HTTP response' }
    end
    return { err_code = 0, status_code = resp.status, body = resp.body }
end

--[[
    @method-type: call
    @method-name: raw_request
    @method-desc: The front-end interacts with the cloud through this interface.
    @out number     status_code         http status code
    @out string     body                http response body
    @out number     ?err_code           Error Code
    @out string     ?err_msg            Error Message
    @in-example:  {"jsonrpc":"2.0","id":1,"method":"call","params":["", "mptun", "raw_request",{"req_method":"POST","req_path":"/sdwan/sdk-iprb/v1/my/network/simple","query_params": {},"req_body":{}}]}
    @out-example: {"id":1,"jsonrpc":"2.0","result":{"status_code":200,"body":"{\"code\":0,\"msg\":\"Success\",\"info\":{\"networkId\":\"e594229d6ed40a19cc23b81c6da999cb\",\"networkPlan\":\"IPRB_PLUS\",\"planCode\":\"008\",\"primaryDevice\":false,\"networkStatus\":1,\"enableStatus\":true,\"useInternetExit\":true,\"latestAccessTime\":1769677787124}}"}}
--]]
function M.raw_request(raw_params)
    local res = __raw_request(raw_params)
    if res.err_code ~= 0 then
        return res
    else
        return { status_code = res.status_code, body = res.body }
    end
end

-- 后台状态入口：公开查询和通知复用此结果，不通过查询触发云端同步。
local function iprb_backend_call(method, timeout, params)
    -- oui.ubus yields through nginx sockets: do not wrap this in Lua 5.1 pcall.
    local result, err = ubus.call('mpifd.iprb', method, params or {}, timeout)
    if err ~= nil or type(result) ~= 'table' then
        return { err_code = -1, err_msg = 'iprb_backend_unavailable' }
    end
    return result
end

-- 基础查询只透传 mpifd 状态，查询失败时返回空表。
local function __get_status()
    local result = iprb_backend_call('status')
    if result.err_code then return {} end
    return result
end

-- 整理 IPRB 对外结构，供 RPC、WebSocket 和通知复用。
local function __get_IPRB_status()
    local result = __get_status()
    if type(result.status) ~= 'table' then return {} end
    -- ubus 可能省略空表，恢复主站/未初始化状态的 data 对象。
    local status = result.status
    if status.identity == 'secondary' and type(status.data) ~= 'table' then return {} end
    if status.identity ~= 'secondary' then
        status.data = {}
    elseif status.enabled ~= '1' then
        status.data.state = 'disconnected'
    elseif status.data.state ~= 'connected' then
        -- 仅映射本次对外返回，不改变后台运行状态。
        status.data.state = 'connecting'
    end
    return { status = status }
end

local function is_finite_number(value)
    return type(value) == 'number' and value == value and value > -math.huge and value < math.huge
end

--[[
    @method-type: call
    @method-name: IPRB_get_secondary_list
    @method-desc: Query secondary devices and return available fields in camelCase.
    @out array result Secondary devices; an empty list is returned as [].
    @in-example: {"jsonrpc":"2.0","id":1,"method":"call","params":["","mptun","IPRB_get_secondary_list",{}]}
--]]
function M.IPRB_get_secondary_list()
    -- 1. 无业务入参；请求方法、路径和请求体由接口固定。
    local request = {
        req_method = 'POST',
        req_path = req_path.req_get_seconds_list,
        req_body = {}
    }

    -- 2. 检查通信结果，错误由本接口处理，不透传底层返回表。
    local response = __raw_request(request)
    if type(response) ~= 'table' or response.err_code ~= 0 then
        return { err_code = get_error_code('operation_failed'), err_msg = 'cloud_request_failed' }
    end
    if response.status_code ~= 200 then
        return { err_code = get_error_code('operation_failed'), err_msg = 'cloud_http_failed' }
    end
    if type(response.body) ~= 'string' then
        return { err_code = get_error_code('invalid_cloud_response'), err_msg = 'invalid_cloud_response' }
    end

    -- 3. 解析响应外层；使用独立解码器，保留数组类型且不改变全局设置。
    local json = cjson.new()
    json.decode_array_with_array_mt(true)
    json.decode_invalid_numbers(false)
    local ok, body = pcall(json.decode, response.body)
    if not ok or type(body) ~= 'table' or getmetatable(body) == cjson.array_mt or
        not is_finite_number(body.code) then
        return { err_code = get_error_code('invalid_cloud_response'), err_msg = 'invalid_cloud_response' }
    end
    if body.code ~= 0 then
        return { err_code = get_error_code('operation_failed'), err_msg = 'cloud_business_failed' }
    end
    local info = body.info
    if type(info) ~= 'table' or getmetatable(info) ~= cjson.array_mt then
        return { err_code = get_error_code('invalid_cloud_response'), err_msg = 'invalid_cloud_response' }
    end

    -- 4. 逐条重建公开字段；优先使用有效的驼峰字段，再兼容下划线命名。
    local string_fields = {
        name = 'name',
        secondaryId = 'secondary_id',
        secondaryType = 'secondary_type',
        clientType = 'clientType',
        connectStatus = 'connect_status',
        channelIp = 'channel_ip',
        model = 'model',
        version = 'version'
    }
    local result = setmetatable({}, cjson.array_mt)
    for _, entry in ipairs(info) do
        if type(entry) == 'table' and getmetatable(entry) ~= cjson.array_mt then
            local device = {}
            for field, source in pairs(string_fields) do
                local value = entry[field]
                if type(value) ~= 'string' then value = entry[source] end
                if type(value) == 'string' then device[field] = value end
            end
            local timestamp = entry.latestAccessTime
            if not is_finite_number(timestamp) then timestamp = entry.latest_access_time end
            if is_finite_number(timestamp) then device.latestAccessTime = timestamp end

            -- 异常字段仅省略，不丢弃其他有效信息；无有效字段的条目跳过。
            if next(device) ~= nil then result[#result + 1] = device end
        end
    end

    -- 5. RPC 层编码新数组；即使没有可用条目，也保持 []。
    return result
end

--[[
    @method-type: call
    @method-name: IPRB_req_secondary_rename
    @method-desc: Rename a secondary device in the cloud.
    @in string secondaryId Device identifier returned by the secondary list.
    @in string aliasName New device name.
    @out number ?err_code Error Code
    @out string ?err_msg Error Message
    @in-example: {"jsonrpc":"2.0","id":1,"method":"call","params":["","mptun","IPRB_req_secondary_rename",{"secondaryId":"9483c42c8d90","aliasName":"sub2"}]}
    @out-example: {"jsonrpc":"2.0","id":1,"result":{}}
--]]
function M.IPRB_req_secondary_rename(params)
    -- 1. 校验入参；目标 ID 不允许为空，名称最多 128 字节，允许空串，按原文提交。
    if type(params) ~= 'table' or type(params.secondaryId) ~= 'string' or
        not params.secondaryId:match('^[%w_%-]+$') or type(params.aliasName) ~= 'string' or
        #params.aliasName > 128 then
        return { err_code = get_error_code('invalid_params'), err_msg = 'invalid_params' }
    end
    local request = {
        req_method = 'POST',
        req_path = req_path.req_second_rename,
        req_body = { secondaryId = params.secondaryId, aliasName = params.aliasName }
    }

    -- 2. 检查通信结果，错误由本接口处理，不透传底层返回表。
    local response = __raw_request(request)
    if type(response) ~= 'table' or response.err_code ~= 0 then
        return { err_code = get_error_code('operation_failed'), err_msg = 'cloud_request_failed' }
    end
    if response.status_code ~= 200 then
        return { err_code = get_error_code('operation_failed'), err_msg = 'cloud_http_failed' }
    end
    if type(response.body) ~= 'string' then
        return { err_code = get_error_code('invalid_cloud_response'), err_msg = 'invalid_cloud_response' }
    end

    -- 3. 解析响应外层；成功依赖 code 和执行结果，不依赖 msg 文本。
    local json = cjson.new()
    json.decode_array_with_array_mt(true)
    json.decode_invalid_numbers(false)
    local ok, body = pcall(json.decode, response.body)
    if not ok or type(body) ~= 'table' or getmetatable(body) == cjson.array_mt or
        not is_finite_number(body.code) then
        return { err_code = get_error_code('invalid_cloud_response'), err_msg = 'invalid_cloud_response' }
    end
    if body.code ~= 0 then
        return { err_code = get_error_code('operation_failed'), err_msg = 'cloud_business_failed' }
    end

    -- 4. 设置接口必须明确成功；缺失、null、字符串和数字都不能代替布尔结果。
    local info = body.info
    if type(info) ~= 'boolean' then
        return { err_code = get_error_code('invalid_cloud_response'), err_msg = 'invalid_cloud_response' }
    end
    if not info then
        return { err_code = get_error_code('operation_failed'), err_msg = 'secondary_rename_failed' }
    end

    -- 5. 不修改本地状态；调用方可重新查询从站列表获取新名称。
    return {}
end

--[[
    @method-type: call
    @method-name: IPRB_req_remove_secondary
    @method-desc: Remove a secondary device in the cloud.
    @in string secondaryId Device identifier returned by the secondary list.
    @in string secondaryType Device type returned by the secondary list.
    @out-example: {"jsonrpc":"2.0","id":1,"result":{}}
--]]
function M.IPRB_req_remove_secondary(params)
    -- 1. 使用列表返回的目标标识和类型，只提交这两个字段。
    if type(params) ~= 'table' or type(params.secondaryId) ~= 'string' or
        not params.secondaryId:match('^[%w_%-]+$') or type(params.secondaryType) ~= 'string' or
        not params.secondaryType:match('^[%w_%-]+$') then
        return { err_code = get_error_code('invalid_params'), err_msg = 'invalid_params' }
    end
    local request = {
        req_method = 'POST',
        req_path = req_path.req_remove_second,
        req_body = { secondaryId = params.secondaryId, secondaryType = params.secondaryType }
    }

    -- 2. 检查通信结果，错误由本接口处理，不透传底层返回表。
    local response = __raw_request(request)
    if type(response) ~= 'table' or response.err_code ~= 0 then
        return { err_code = get_error_code('operation_failed'), err_msg = 'cloud_request_failed' }
    end
    if response.status_code ~= 200 then
        return { err_code = get_error_code('operation_failed'), err_msg = 'cloud_http_failed' }
    end
    if type(response.body) ~= 'string' then
        return { err_code = get_error_code('invalid_cloud_response'), err_msg = 'invalid_cloud_response' }
    end

    -- 3. 解析响应外层；成功依赖 code 和执行结果，不依赖 msg 文本。
    local json = cjson.new()
    json.decode_array_with_array_mt(true)
    json.decode_invalid_numbers(false)
    local ok, body = pcall(json.decode, response.body)
    if not ok or type(body) ~= 'table' or getmetatable(body) == cjson.array_mt or
        not is_finite_number(body.code) then
        return { err_code = get_error_code('invalid_cloud_response'), err_msg = 'invalid_cloud_response' }
    end
    if body.code ~= 0 then
        return { err_code = get_error_code('operation_failed'), err_msg = 'cloud_business_failed' }
    end

    -- 4. 设置接口必须收到布尔 true，不能把缺失或异常结果当作成功。
    local info = body.info
    if type(info) ~= 'boolean' then
        return { err_code = get_error_code('invalid_cloud_response'), err_msg = 'invalid_cloud_response' }
    end
    if not info then
        return { err_code = get_error_code('operation_failed'), err_msg = 'secondary_remove_failed' }
    end

    -- 5. 只返回公开结果，不更新本机状态。
    return {}
end

--[[
    @method-type: call
    @method-name: IPRB_get_access_code_list
    @method-desc: query active and expired access codes from the cloud
    @out array activeAccessCodes Active access codes with dynamicCode, expirationRemainder (seconds), clientAlias.
    @out array expiredAccessCodes Expired access codes with dynamicCode and clientAlias.
--]]
function M.IPRB_get_access_code_list()
    -- 1. 无业务入参；请求方法和路径由接口固定。
    local request = {
        req_method = 'GET',
        req_path = req_path.req_get_access_code_list,
        req_body = {}
    }

    -- 2. 检查通信结果，错误由本接口处理，不透传底层返回表。
    local response = __raw_request(request)
    if type(response) ~= 'table' or response.err_code ~= 0 then
        return { err_code = get_error_code('operation_failed'), err_msg = 'cloud_request_failed' }
    end
    if response.status_code ~= 200 then
        return { err_code = get_error_code('operation_failed'), err_msg = 'cloud_http_failed' }
    end
    if type(response.body) ~= 'string' then
        return { err_code = get_error_code('invalid_cloud_response'), err_msg = 'invalid_cloud_response' }
    end

    -- 3. 解析响应外层；成功依赖 code 和执行结果，不依赖 msg 文本。
    local json = cjson.new()
    json.decode_array_with_array_mt(true)
    json.decode_invalid_numbers(false)
    local ok, body = pcall(json.decode, response.body)
    if not ok or type(body) ~= 'table' or getmetatable(body) == cjson.array_mt or
        not is_finite_number(body.code) then
        return { err_code = get_error_code('invalid_cloud_response'), err_msg = 'invalid_cloud_response' }
    end
    if body.code ~= 0 then
        return { err_code = get_error_code('operation_failed'), err_msg = 'cloud_business_failed' }
    end

    -- 4. 两组列表必须有效；逐条重建公开字段，兼容下划线命名。
    local info = body.info
    if type(info) ~= 'table' or getmetatable(info) == cjson.array_mt then
        return { err_code = get_error_code('invalid_cloud_response'), err_msg = 'invalid_cloud_response' }
    end
    local result = {}
    local groups = { activeAccessCodes = 'active_access_codes', expiredAccessCodes = 'expired_access_codes' }
    for field, source in pairs(groups) do
        local list = info[field]
        if type(list) ~= 'table' or getmetatable(list) ~= cjson.array_mt then list = info[source] end
        if type(list) ~= 'table' or getmetatable(list) ~= cjson.array_mt then
            return { err_code = get_error_code('invalid_cloud_response'), err_msg = 'invalid_cloud_response' }
        end
        local entries = setmetatable({}, cjson.array_mt)
        for _, entry in ipairs(list) do
            if type(entry) == 'table' and getmetatable(entry) ~= cjson.array_mt then
                local item = {}
                local code = entry.dynamicCode
                if type(code) ~= 'string' then code = entry.dynamic_code end
                if type(code) == 'string' then item.dynamicCode = code end
                local alias = entry.clientAlias
                if type(alias) ~= 'string' then alias = entry.client_alias end
                if type(alias) == 'string' then item.clientAlias = alias end
                if field == 'activeAccessCodes' then
                    local duration = entry.expirationRemainder
                    if not is_finite_number(duration) then duration = entry.expiration_remainder end
                    if is_finite_number(duration) then item.expirationRemainder = duration end
                end
                -- 坏字段省略，其他有效字段继续交付；无可用字段的条目跳过。
                if next(item) ~= nil then entries[#entries + 1] = item end
            end
        end
        result[field] = entries
    end

    -- 5. 两组列表始终编码为数组；不透传云端额外字段。
    return result
end

--[[
    @method-type: call
    @method-name: IPRB_add_access_code
    @method-desc: create a new access code in the cloud
    @out string dynamicCode New access code.
    @out number expirationRemainder Validity duration in seconds.
--]]
function M.IPRB_add_access_code()
    -- 1. 无业务入参；请求方法和路径由接口固定。
    local request = {
        req_method = 'POST',
        req_path = req_path.req_add_access_code,
        req_body = {}
    }

    -- 2. 检查通信结果，错误由本接口处理，不透传底层返回表。
    local response = __raw_request(request)
    if type(response) ~= 'table' or response.err_code ~= 0 then
        return { err_code = get_error_code('operation_failed'), err_msg = 'cloud_request_failed' }
    end
    if response.status_code ~= 200 then
        return { err_code = get_error_code('operation_failed'), err_msg = 'cloud_http_failed' }
    end
    if type(response.body) ~= 'string' then
        return { err_code = get_error_code('invalid_cloud_response'), err_msg = 'invalid_cloud_response' }
    end

    -- 3. 解析响应外层；成功依赖 code 和执行结果，不依赖 msg 文本。
    local json = cjson.new()
    json.decode_array_with_array_mt(true)
    json.decode_invalid_numbers(false)
    local ok, body = pcall(json.decode, response.body)
    if not ok or type(body) ~= 'table' or getmetatable(body) == cjson.array_mt or
        not is_finite_number(body.code) then
        return { err_code = get_error_code('invalid_cloud_response'), err_msg = 'invalid_cloud_response' }
    end
    if body.code ~= 0 then
        return { err_code = get_error_code('operation_failed'), err_msg = 'cloud_business_failed' }
    end

    -- 4. 新增操作必须取得有效访问码及有效期，不返回残缺的成功结果。
    local info = body.info
    if type(info) ~= 'table' or getmetatable(info) == cjson.array_mt then
        return { err_code = get_error_code('invalid_cloud_response'), err_msg = 'invalid_cloud_response' }
    end
    local code = info.dynamicCode
    if type(code) ~= 'string' or not code:match('^[%w_%-]+$') then code = info.dynamic_code end
    local duration = info.expirationRemainder
    if not is_finite_number(duration) then duration = info.expiration_remainder end
    if type(code) ~= 'string' or not code:match('^[%w_%-]+$') or not is_finite_number(duration) then
        return { err_code = get_error_code('invalid_cloud_response'), err_msg = 'invalid_cloud_response' }
    end

    -- 5. 仅重建公开字段，有效期保持云端秒数，不做转换或补默认值。
    return { dynamicCode = code, expirationRemainder = duration }
end

--[[
    @method-type: call
    @method-name: IPRB_set_access_code_alias
    @method-desc: set the alias of an access code in the cloud
    @in string dynamicCode Access code.
    @in string alias Alias to set.
    @out-example: {"jsonrpc":"2.0","id":1,"result":{}}
--]]
function M.IPRB_set_access_code_alias(params)
    -- 1. 访问码非空；别名最多 128 字节（非字符数），空串也原样提交云端。
    if type(params) ~= 'table' or type(params.dynamicCode) ~= 'string' or
        not params.dynamicCode:match('^[%w_%-]+$') or type(params.alias) ~= 'string' or
        #params.alias > 128 then
        return { err_code = get_error_code('invalid_params'), err_msg = 'invalid_params' }
    end
    local request = {
        req_method = 'PUT',
        req_path = req_path.req_set_access_code_alias,
        req_body = { accessCode = params.dynamicCode, clientAlias = params.alias }
    }

    -- 2. 检查通信结果，错误由本接口处理，不透传底层返回表。
    local response = __raw_request(request)
    if type(response) ~= 'table' or response.err_code ~= 0 then
        return { err_code = get_error_code('operation_failed'), err_msg = 'cloud_request_failed' }
    end
    if response.status_code ~= 200 then
        return { err_code = get_error_code('operation_failed'), err_msg = 'cloud_http_failed' }
    end
    if type(response.body) ~= 'string' then
        return { err_code = get_error_code('invalid_cloud_response'), err_msg = 'invalid_cloud_response' }
    end

    -- 3. 解析响应外层；成功依赖 code 和执行结果，不依赖 msg 文本。
    local json = cjson.new()
    json.decode_array_with_array_mt(true)
    json.decode_invalid_numbers(false)
    local ok, body = pcall(json.decode, response.body)
    if not ok or type(body) ~= 'table' or getmetatable(body) == cjson.array_mt or
        not is_finite_number(body.code) then
        return { err_code = get_error_code('invalid_cloud_response'), err_msg = 'invalid_cloud_response' }
    end
    if body.code ~= 0 then
        return { err_code = get_error_code('operation_failed'), err_msg = 'cloud_business_failed' }
    end

    -- 4. 设置接口必须收到布尔 true，不能把缺失或异常结果当作成功。
    local info = body.info
    if type(info) ~= 'boolean' then
        return { err_code = get_error_code('invalid_cloud_response'), err_msg = 'invalid_cloud_response' }
    end
    if not info then
        return { err_code = get_error_code('operation_failed'), err_msg = 'access_code_alias_failed' }
    end

    -- 5. 只返回公开结果，不更新本机状态。
    return {}
end

--[[
    @method-type: call
    @method-name: IPRB_delete_access_code
    @method-desc: delete an access code in the cloud
    @in string dynamicCode Access code.
    @out-example: {"jsonrpc":"2.0","id":1,"result":{}}
--]]
function M.IPRB_delete_access_code(params)
    -- 1. 校验目标访问码，只提交云端要求的 code 字段。
    if type(params) ~= 'table' or type(params.dynamicCode) ~= 'string' or
        not params.dynamicCode:match('^[%w_%-]+$') then
        return { err_code = get_error_code('invalid_params'), err_msg = 'invalid_params' }
    end
    local request = {
        req_method = 'DELETE',
        req_path = req_path.req_delete_access_code,
        req_body = { code = params.dynamicCode }
    }

    -- 2. 检查通信结果，错误由本接口处理，不透传底层返回表。
    local response = __raw_request(request)
    if type(response) ~= 'table' or response.err_code ~= 0 then
        return { err_code = get_error_code('operation_failed'), err_msg = 'cloud_request_failed' }
    end
    if response.status_code ~= 200 then
        return { err_code = get_error_code('operation_failed'), err_msg = 'cloud_http_failed' }
    end
    if type(response.body) ~= 'string' then
        return { err_code = get_error_code('invalid_cloud_response'), err_msg = 'invalid_cloud_response' }
    end

    -- 3. 解析响应外层；成功依赖 code 和执行结果，不依赖 msg 文本。
    local json = cjson.new()
    json.decode_array_with_array_mt(true)
    json.decode_invalid_numbers(false)
    local ok, body = pcall(json.decode, response.body)
    if not ok or type(body) ~= 'table' or getmetatable(body) == cjson.array_mt or
        not is_finite_number(body.code) then
        return { err_code = get_error_code('invalid_cloud_response'), err_msg = 'invalid_cloud_response' }
    end
    if body.code ~= 0 then
        return { err_code = get_error_code('operation_failed'), err_msg = 'cloud_business_failed' }
    end

    -- 4. 设置接口必须收到布尔 true，不能把缺失或异常结果当作成功。
    local info = body.info
    if type(info) ~= 'boolean' then
        return { err_code = get_error_code('invalid_cloud_response'), err_msg = 'invalid_cloud_response' }
    end
    if not info then
        return { err_code = get_error_code('operation_failed'), err_msg = 'access_code_delete_failed' }
    end

    -- 5. 只返回公开结果，不更新本机状态。
    return {}
end

--[[
    @method-type: call
    @method-name: IPRB_clear_invalid_access_code
    @method-desc: ask the cloud to delete expired access codes
    @out-example: {"jsonrpc":"2.0","id":1,"result":{}}
--]]
function M.IPRB_clear_invalid_access_code()
    -- 1. 无业务入参；请求方法和路径由接口固定。
    local request = {
        req_method = 'DELETE',
        req_path = req_path.req_clear_invalid_access_code,
        req_body = {}
    }

    -- 2. 检查通信结果，错误由本接口处理，不透传底层返回表。
    local response = __raw_request(request)
    if type(response) ~= 'table' or response.err_code ~= 0 then
        return { err_code = get_error_code('operation_failed'), err_msg = 'cloud_request_failed' }
    end
    if response.status_code ~= 200 then
        return { err_code = get_error_code('operation_failed'), err_msg = 'cloud_http_failed' }
    end
    if type(response.body) ~= 'string' then
        return { err_code = get_error_code('invalid_cloud_response'), err_msg = 'invalid_cloud_response' }
    end

    -- 3. 解析响应外层；成功依赖 code 和执行结果，不依赖 msg 文本。
    local json = cjson.new()
    json.decode_array_with_array_mt(true)
    json.decode_invalid_numbers(false)
    local ok, body = pcall(json.decode, response.body)
    if not ok or type(body) ~= 'table' or getmetatable(body) == cjson.array_mt or
        not is_finite_number(body.code) then
        return { err_code = get_error_code('invalid_cloud_response'), err_msg = 'invalid_cloud_response' }
    end
    if body.code ~= 0 then
        return { err_code = get_error_code('operation_failed'), err_msg = 'cloud_business_failed' }
    end

    -- 4. 设置接口必须收到布尔 true，不能把缺失或异常结果当作成功。
    local info = body.info
    if type(info) ~= 'boolean' then
        return { err_code = get_error_code('invalid_cloud_response'), err_msg = 'invalid_cloud_response' }
    end
    if not info then
        return { err_code = get_error_code('operation_failed'), err_msg = 'access_code_clear_failed' }
    end

    -- 5. 只返回公开结果，不更新本机状态。
    return {}
end
--[[
    @method-type: call
    @method-name: is_IPRB_actual_running
    @method-desc: Check whether enabled IPRB has a running mpifd and an UP tunnel with IPv4; does not check peer connectivity.
    @out bool running True when local IPRB runtime conditions are met; false when disabled, stopped, or observations are unavailable.
    @in-example: {"jsonrpc":"2.0","id":1,"method":"call","params":["","mptun","is_IPRB_actual_running",{}]}
    @out-example: {"jsonrpc":"2.0","id":1,"result":{"running":true}}
--]]
function M.is_IPRB_actual_running()
    -- 启用状态由后台维护；查询失败或未启用时不再尝试云端同步。
    local result = __get_status()
    if result.err_code or result.mode ~= 'IPRB' or type(result.status) ~= 'table' or
        result.status.enabled ~= '1' then
        return { running = false }
    end

    return { running = is_mptun_running() }
end

-- 查询与推送读取相同后台快照，不触发云端请求或配置写入。
local function push_status_to_wb()
    local status = __get_IPRB_status()
    if next(status) == nil then return {} end
    local _, err = ubus.call('gl-session', 'notify', { name = "mptun.IPRB_status", data = status })
    if err then return { err_code = -1, err_msg = 'notify_failed' } end
    return {}
end
--[[
    @method-type: call
    @method-name: push_IPRB_status_to_wb
    @method-desc: push IPRB status to websocket.
    @in-example:  {"jsonrpc":"2.0","id":1,"method":"call","params":["", "mptun", "push_IPRB_status_to_wb",{}]}
    @out-example: {"jsonrpc": "2.0", "id": 1, "result": { }}
--]]
function M.push_IPRB_status_to_wb(params)
    return push_status_to_wb()
end

-- RPC、WebSocket 和主动通知使用相同的状态结构。
function M.get_IPRB_status()
    return __get_IPRB_status()
end

-- 本地配置查询，供功能冲突检查和身份识别使用，不依赖 mpifd 或云端。
-- 连接运行时仍通过 get_IPRB_status 查询。
function M.get_AW_status()
    local result = { enabled = false, mode = '', status = {} }
    local ok, c = pcall(uci.cursor)
    if not ok or not c then return result end

    -- UCI 不会 yield；逐字段保护，避免后续读取失败丢掉已知状态。
    local mode_ok, mode = pcall(c.get, c, 'mptun', 'global', 'service_mode')
    if not mode_ok then mode = '' end
    if mode == 'classic' then
        local enable_ok, enable = pcall(c.get, c, 'mptun', 'global', 'enable')
        local global_enabled = enable_ok and enable == '1'
        result = { enabled = global_enabled, mode = 'classic', status = { enable = global_enabled } }
    elseif mode == 'IPRB' then
        local identity_ok, identity = pcall(c.get, c, 'mptun', 'IPRB', 'identity')
        if not identity_ok or (identity ~= 'primary' and identity ~= 'secondary') then identity = '' end
        local disabled_ok, disabled = pcall(c.get, c, 'mptun', 'IPRB', 'disabled')
        -- 缺省 disabled 仍表示启用，读取异常则不能判为启用。
        local enabled = identity ~= '' and disabled_ok and
            (disabled == nil or type(disabled) == 'string') and disabled ~= '1'
        local network_ok, network_id = pcall(c.get, c, 'mptun', 'IPRB', 'net_id')
        if not network_ok or type(network_id) ~= 'string' then network_id = '' end
        result = {
            enabled = enabled,
            mode = 'IPRB',
            status = {
                enabled = enabled and '1' or '0',
                identity = identity,
                network_id = network_id,
                data = {}
            }
        }
    end
    pcall(c.close, c)
    return result
end

-- 摘要复用本地配置查询，不依赖 mpifd 或云端。
function M.AW_get_global_summary()
    -- 本地 UCI 查询不会 yield；异常或无效返回不影响其他字段的获取。
    local ok, result = pcall(M.get_AW_status)
    if not ok or type(result) ~= 'table' then result = {} end
    local mode = result.mode
    if mode ~= 'IPRB' and mode ~= 'classic' then mode = '' end
    local identity = result.mode == 'IPRB' and type(result.status) == 'table' and result.status.identity
    if result.err_code or (identity ~= 'primary' and identity ~= 'secondary') then
        -- mptun_tools.sh 安装为 /usr/bin/mptun_tools；失败不影响模式和启用状态。
        identity = ''
        -- 命令代理会 yield，直接处理其失败返回，不套 Lua 5.1 pcall。
        if ngx and ngx.pipe and type(ngx.pipe.spawn) == 'function' then
            local process = ngx.pipe.spawn({ '/usr/bin/mptun_tools', 'get_IPRB_identity' },
                { stdout_read_timeout = 5000 })
            if process then
                -- 固件代理读取后关闭 socket；wait 仅返回相同缓存，无需调用。
                local output, err = process:stdout_read_all()
                if not err and type(output) == 'string' then
                    local value = output:match('^%s*(.-)%s*$')
                    if value == 'primary' or value == 'secondary' then identity = value end
                end
            end
        end
    end
    return { enabled = result.enabled == true, mode = mode, IPRB_model_sidentity = identity }
end

local function __push_global_summary_to_wb()
    local result = M.AW_get_global_summary()
    if result.err_code then return result end
    local _, err = ubus.call('gl-session', 'notify', { name = "mptun.AW_global_summary", data = result })
    if err then return { err_code = -1, err_msg = 'notify_failed' } end
    return {}
end

function M.push_global_summary_to_wb()
    return __push_global_summary_to_wb()
end
-- Map only recognized backend reasons; never expose arbitrary backend messages.
local IPRB_ERROR_NAMES = {
    ['invalid_params'] = 'invalid_params',
    ['busy'] = 'busy',
    ['invalid identity'] = 'state_not_allowed',
    ['not_initialized'] = 'state_not_allowed',
    ['network_mismatch'] = 'state_changed',
    ['net_version_mismatch'] = 'state_changed',
    ['invalid_cloud_response'] = 'invalid_cloud_response',
    ['invalid_access_response'] = 'invalid_cloud_response',
    ['plan_expired'] = 'plan_expired',
    ['device_limit_exceeded'] = 'device_limit_exceeded',
    ['access_locked'] = 'access_locked',
    ['access_verification_failed'] = 'access_verification_failed',
    ['kicked_out_cleanup_required'] = 'kicked_out_cleanup_required'
}

local function iprb_error_name(reason)
    return IPRB_ERROR_NAMES[reason] or 'operation_failed'
end

-- The backend owns persistence and cloud/local application. Notify only after
-- it returns; a cloud failure does not undo an already saved local setting.
local function control_secondary(method, params)
    if params ~= nil and (type(params) ~= 'table' or next(params) ~= nil) then
        return { err_code = get_error_code('invalid_params'), err_msg = 'invalid_params' }
    end
    if method == 'start_connect' and not __is_meet_startup_conditions() then
        return { err_code = get_error_code('startup_conditions_not_met'), err_msg = 'Startup conditions not met !' }
    end
    local result = iprb_backend_call(method, 60000)
    local changed = result.changed
    result.changed = nil
    if changed or result.err_msg == 'iprb_backend_unavailable' then
        -- On timeout the operation may already have committed; query current state.
        push_status_to_wb()
    end
    if result.err_code ~= nil and result.err_code ~= 0 then
        local name = iprb_error_name(result.err_msg)
        return { err_code = get_error_code(name), err_msg = name }
    end
    return result
end

--[[
    @method-type: call
    @method-name: clear_IPRB_optional_data
    @method-desc: Best-effort clearing of optional speedtest and Wi-Fi sync data.
--]]
function M.clear_IPRB_optional_data(params)
    if params ~= nil and (type(params) ~= 'table' or next(params) ~= nil) then
        return { err_code = ERR_PARAMETER, err_msg = 'invalid_params' }
    end
    for _, object in ipairs({ 'mpifd.speedtest_client', 'mpifd.wifi_sync' }) do
        -- oui.ubus yields on Lua 5.1; handle returned errors without pcall.
        local result, err = ubus.call(object, 'clear', {}, 3000)
        -- An optional module (or an older clear method) may be absent.
        if err ~= nil then
            if err ~= 3 and err ~= 4 and err ~= 'Method not found' and err ~= 'Not found' then
                ngx.log(ngx.ERR, 'IPRB optional clear failed: ', object, ': ', tostring(err))
            end
        elseif type(result) == 'table' and (result.error or
            (result.err_code ~= nil and result.err_code ~= 0)) then
            ngx.log(ngx.ERR, 'IPRB optional clear failed: ', object, ': ',
                tostring(result.err_msg or result.err_code or 'RPC error'))
        end
    end
    return {}
end

--[[
    @method-type: call
    @method-name: IPRB_req_access_by_code
    @method-desc: Join an IPRB network using an access code.
    @in string dynamicCode Access code.
    @out number ?err_code Error Code
    @out string ?err_msg Error Message
    @in-example: {"jsonrpc":"2.0","id":1,"method":"call","params":["","mptun","IPRB_req_access_by_code",{"dynamicCode":"IGPMNDOE"}]}
    @out-example: {"jsonrpc":"2.0","id":1,"result":{}}
--]]
function M.IPRB_req_access_by_code(params)
    if type(params) ~= 'table' or type(params.dynamicCode) ~= 'string' or
        params.dynamicCode == '' then
        return { err_code = get_error_code('invalid_params'), err_msg = 'invalid_params' }
    end
    -- 后台完成云端验证、状态保存及通知；成功只表示入网请求已处理。
    -- Joining may also check startup conditions and pause before publishing status.
    local result = iprb_backend_call('access_by_code', 90000, { dynamicCode = params.dynamicCode })
    if result.err_code ~= nil and result.err_code ~= 0 then
        local name = iprb_error_name(result.err_msg)
        if name == 'access_locked' then
            if not is_valid_positive_integer(result.lockTime) then
                return { err_code = get_error_code('operation_failed'), err_msg = 'invalid_access_result' }
            end
            return { err_code = get_error_code(name), err_msg = name, lockTime = result.lockTime }
        end
        return { err_code = get_error_code(name), err_msg = name }
    end
    return result
end

function M.IPRB_secondary_start_connect(params)
    return control_secondary('start_connect', params)
end

function M.IPRB_secondary_pause_connect(params)
    return control_secondary('pause_connect', params)
end

--[[
    @method-type: call
    @method-name: IPRB_set_primary_alias
    @method-desc: Save the primary alias locally on a secondary device.
    @in string networkId Network ID; empty skips membership comparison.
    @in string alias Local alias; empty clears it.
    @out number ?err_code Error Code
    @out string ?err_msg Error Message
    @in-example: {"jsonrpc":"2.0","id":1,"method":"call","params":["","mptun","IPRB_set_primary_alias",{"networkId":"","alias":"primary1"}]}
    @out-example: {"jsonrpc":"2.0","id":1,"result":{}}
--]]
function M.IPRB_set_primary_alias(params)
    if type(params) ~= 'table' or type(params.networkId) ~= 'string' or type(params.alias) ~= 'string' or
        #params.alias > 128 then
        return { err_code = get_error_code('invalid_params'), err_msg = 'invalid_params' }
    end
    local result = iprb_backend_call('set_primary_alias', 60000, { networkId = params.networkId, alias = params.alias })
    if result.err_code ~= nil and result.err_code ~= 0 then
        local name = iprb_error_name(result.err_msg)
        return { err_code = get_error_code(name), err_msg = name }
    end
    return result
end

--[[
    @method-type: call
    @method-name: set_IPRB_proxy_private_net
    @method-desc: Set private-network proxying on an IPRB secondary device.
    @in bool        enabled     Whether private networks participate in tunnel routing.
    @out number     ?err_code   Error Code
    @out string     ?err_msg    Error Message
    @in-example: {"jsonrpc":"2.0","id":1,"method":"call","params":["","mptun","set_IPRB_proxy_private_net",{"enabled":true}]}
    @out-example: {"jsonrpc":"2.0","id":1,"result":{}}
    Backend saves configuration and waits for a bounded mptun restart when enabled.
--]]
function M.set_IPRB_proxy_private_net(params)
    if type(params) ~= 'table' or type(params.enabled) ~= 'boolean' then
        return { err_code = get_error_code('invalid_params'), err_msg = 'invalid_params' }
    end
    local result = iprb_backend_call('set_proxy_private_net', 60000, { enabled = params.enabled })
    if result.err_code ~= nil and result.err_code ~= 0 then
        local name = iprb_error_name(result.err_msg)
        return { err_code = get_error_code(name), err_msg = name }
    end
    return result
end
--[[
    @method-type: call
    @method-name: reset
    @method-desc: reset configuration.
    @out number     ?err_code   Error Code
    @out string     ?err_msg    Error Message
    @in-example:  {"jsonrpc":"2.0","id":1,"method":"call","params":["", "mptun", "reset",{}]}
    @out-example: {"jsonrpc": "2.0", "id": 1, "result": {}}
--]]
function M.reset(params)
    if params ~= nil and (type(params) ~= 'table' or next(params) ~= nil) then
        return { err_code = get_error_code('invalid_params'), err_msg = 'invalid_params' }
    end
    -- 后台负责云端重置、本地清理、限时停止及通知；不以本地归属作为前置条件。
    local result = iprb_backend_call('reset', 60000)
    if result.err_code ~= nil and result.err_code ~= 0 then
        local name = iprb_error_name(result.err_msg)
        return { err_code = get_error_code(name), err_msg = name }
    end
    return result
end

--[[
    @method-type: call
    @method-name: clean_kicked_out
    @method-desc: Clear the secondary kicked-out flag before joining again.
    @out number ?err_code Error Code
    @out string ?err_msg Error Message
    @in-example: {"jsonrpc":"2.0","id":1,"method":"call","params":["","mptun","clean_kicked_out",{}]}
    @out-example: {"jsonrpc":"2.0","id":1,"result":{}}
--]]
function M.clean_kicked_out(params)
    if params ~= nil and (type(params) ~= 'table' or next(params) ~= nil) then
        return { err_code = get_error_code('invalid_params'), err_msg = 'invalid_params' }
    end
    local result = iprb_backend_call('clean_kicked_out', 60000)
    if result.err_code ~= nil and result.err_code ~= 0 then
        local name = iprb_error_name(result.err_msg)
        return { err_code = get_error_code(name), err_msg = name }
    end
    return result
end

-- This function updates /etc/config/mptun, so subsequent processes may require reloading it.
--[[
    @method-type: call
    @method-name: get_started
    @method-desc: Initialize IPRB locally and restart mpifd to load the configuration.
    @out number     ?err_code   Error Code
    @out string     ?err_msg    Error Message
    @in-example:  {"jsonrpc":"2.0","id":1,"method":"call","params":["", "mptun", "get_started",{}]}
    @out-example: {"jsonrpc": "2.0", "id": 1, "result": {}}
--]]
function M.get_started(params)
    if params ~= nil and (type(params) ~= 'table' or next(params) ~= nil) then
        return { err_code = get_error_code('invalid_params'), err_msg = 'invalid_params' }
    end

    local c = uci.cursor()
    if not c:load('mptun') then
        c:close()
        return { err_code = get_error_code('operation_failed'), err_msg = 'config_load_failed' }
    end
    -- 每秒重新读取升级恢复标记，最多等待 10 秒。
    for _ = 1, 10 do
        if c:get('mptun', 'global', 'need_sync') ~= '1' then break end
        c:close()
        ngx.sleep(1)
        c = uci.cursor()
        if not c:load('mptun') then
            c:close()
            return { err_code = get_error_code('operation_failed'), err_msg = 'config_load_failed' }
        end
    end
    if c:get('mptun', 'global', 'need_sync') == '1' then
        c:close()
        return { err_code = get_error_code('upgrade_sync_pending'), err_msg = 'upgrade_sync_pending' }
    end
    local service_mode = c:get('mptun', 'global', 'service_mode') or ''
    if service_mode ~= '' and service_mode ~= 'IPRB' then
        c:close()
        return { err_code = get_error_code('state_not_allowed'), err_msg = 'invalid_service_mode' }
    end
    local net_id = c:get('mptun', 'IPRB', 'net_id') or ''
    if net_id ~= '' then
        c:close()
        return { err_code = get_error_code('state_not_allowed'), err_msg = 'already_initialized' }
    end

    -- inited 表示配置已提交，不代表重启成功；重试时跳过已完成的配置阶段。
    if service_mode ~= 'IPRB' or c:get('mptun', 'IPRB', 'inited') ~= '1' then
        -- mptun_tools.sh 安装为 /usr/bin/mptun_tools，身份由脚本输出。
        local process = ngx.pipe.spawn({ '/usr/bin/mptun_tools', 'get_IPRB_identity' },
            { stdout_read_timeout = 5000, wait_timeout = 5000 })
        if not process then
            c:close()
            return { err_code = get_error_code('operation_failed'), err_msg = 'get_identity_failed' }
        end
        local output = process:stdout_read_all()
        if not output and process.kill then process:kill(9) end
        process:wait()
        local identity = output and output:match('^%s*(.-)%s*$')
        if identity ~= 'primary' and identity ~= 'secondary' then
            c:close()
            return { err_code = get_error_code('operation_failed'), err_msg = 'get_identity_failed' }
        end

        -- 身份和初始化标志一起提交，其他已有配置保留。
        if not c:get('mptun', 'IPRB') and not c:set('mptun', 'IPRB', 'service_instance') then
            c:close()
            return { err_code = get_error_code('operation_failed'), err_msg = 'config_write_failed' }
        end
        if not c:set('mptun', 'global', 'service_mode', 'IPRB') or
            not c:set('mptun', 'IPRB', 'identity', identity) or
            not c:set('mptun', 'IPRB', 'inited', '1') then
            c:close()
            return { err_code = get_error_code('operation_failed'), err_msg = 'config_write_failed' }
        end
        if not c:commit('mptun') then
            c:close()
            return { err_code = get_error_code('operation_failed'), err_msg = 'config_commit_failed' }
        end
    end
    c:close()

    -- inited 只在 state.start() 读取，必须重启；失败保留已提交配置。
    -- 固件的命令代理不返回退出码，因此仅以 restart 成功后输出的标记判定成功。
    local process = ngx.pipe.spawn({ 'sh', '-c',
        "/etc/init.d/mpifd restart >/dev/null 2>&1 && printf 'mpifd_restarted\\n'"
    }, { stdout_read_timeout = 30000, wait_timeout = 30000 })
    if not process then
        return { err_code = get_error_code('operation_failed'), err_msg = 'mpifd_restart_failed' }
    end
    local output = process:stdout_read_all()
    if not output and process.kill then process:kill(9) end
    process:wait()
    if output ~= 'mpifd_restarted\n' then
        return { err_code = get_error_code('operation_failed'), err_msg = 'mpifd_restart_failed' }
    end
    return {}
end

-- 配置已落盘后尽力重启 mpifd、重连 cloud，单个动作失败不影响另一个。
local function restart_after_IPRB_sync(premature)
    if premature then return end
    local process, err = ngx.pipe.spawn({ '/etc/init.d/mpifd', 'restart' },
        { wait_timeout = 3000 })
    if process then
        local ok
        ok, err = process:wait()
        if not ok then
            ngx.log(ngx.ERR, 'IPRB sync: failed to restart mpifd: ', err)
        end
    else
        ngx.log(ngx.ERR, 'IPRB sync: failed to spawn mpifd restart: ', err)
    end

    -- oui.ubus 会让出协程，不套 pcall；超时或调用失败只记录日志。
    local _, reconnect_err = ubus.call('gl-cloud', 'reconnect', {}, 3000)
    if reconnect_err ~= nil then
        ngx.log(ngx.ERR, 'IPRB sync: failed to reconnect cloud: ', reconnect_err)
    end
end

--[[
    @method-type: call
    @method-name: sync_IPRB_config
    @method-desc: Restore IPRB configuration from cloud after an upgrade.
    @out number ?err_code Error Code
    @out string ?err_msg Error Message
--]]
function M.sync_IPRB_config()
    -- need_sync 由 cloud 检查；这里独立查询，不调用 mpifd。
    local response = __raw_request({
        req_method = 'POST', req_path = req_path.req_get_identity, req_body = {}
    })
    if response.err_code ~= 0 or response.status_code ~= 200 then
        return { err_code = -1, err_msg = 'cloud_request_failed' }
    end
    local ok, body = pcall(cjson.decode, response.body)
    if not ok or type(body) ~= 'table' or body.code ~= 0 then
        return { err_code = -1, err_msg = 'invalid_cloud_response' }
    end

    local info = body.info
    -- 只有显式 null 表示无网络；无法确定归属时保留标记。
    if info ~= cjson.null and (type(info) ~= 'table' or
        type(info.networkPlan) ~= 'string' or info.networkPlan == '') then
        return { err_code = -1, err_msg = 'invalid_simple_info' }
    end
    local is_iprb = info ~= cjson.null and info.networkPlan:sub(1, 4) == 'IPRB'
    local c = uci.cursor()
    if not c:load('mptun') then
        c:close()
        return { err_code = -1, err_msg = 'config_load_failed' }
    end
    if is_iprb then
        if not c:get('mptun', 'IPRB') then c:set('mptun', 'IPRB', 'service_instance') end
        c:set('mptun', 'global', 'service_mode', 'IPRB')
        -- 已确定归属后尽力写入，不因可选/缺失字段阻断迁移。
        if info.networkId ~= nil and info.networkId ~= cjson.null then
            c:set('mptun', 'IPRB', 'net_id', info.networkId)
        end
        if info.primaryDevice ~= nil and info.primaryDevice ~= cjson.null then
            c:set('mptun', 'IPRB', 'identity', info.primaryDevice and 'primary' or 'secondary')
        end
        if info.enableStatus ~= nil and info.enableStatus ~= cjson.null then
            c:set('mptun', 'IPRB', 'disabled', info.enableStatus and '0' or '1')
        end
        c:set('mptun', 'IPRB', 'inited', '1')
    end
    c:delete('mptun', 'global', 'need_sync')
    local committed = c:commit('mptun')
    c:close()
    if not committed then
        return { err_code = -1, err_msg = 'config_commit_failed' }
    end

    if is_iprb then
        local scheduled, err = ngx.timer.at(1, restart_after_IPRB_sync)
        if not scheduled then ngx.log(ngx.ERR, 'IPRB sync: restart timer failed: ', err) end
    end
    return {}
end

-- 独立查询云端 simple，保留旧返回结构；不依赖 mpifd，不维护本地状态。
--[[
    @method-type: call
    @method-name: get_node_info
    @method-desc: get device identity for cloud.
    @out string     info.mode           currently service_mode
    @out string     info.identity       currently identity
    @out string     info.active         cloud allow enabling or not
    @out string     info.use_exit       for secondary, use exit node or not
    @out string     ?info.net_id        id of this network
    @out number     info.err_code       parse result code inside info, 0 means success
    @out number     ?err_code   Error Code: -1 means communication error
    @out string     ?err_msg    Error Message
    @in-example:  {"jsonrpc":"2.0","id":1,"method":"call","params":["", "mptun", "get_node_info",{}]}
    @out-example: {"id":15,"jsonrpc":"2.0","result":{"info":{"mode":"IPRB","use_exit":"0","active":"1","err_code":0,"identity":"primary","net_id":"7c3e7da5dc2413e8e8ff7f6bdde31cab"}}}
--]]
function M.get_node_info(params)
    local response = __raw_request({
        req_method = 'POST', req_path = req_path.req_get_identity, req_body = {}
    })
    if type(response) ~= 'table' or response.err_code ~= 0 then
        return { err_code = -1, err_msg = 'cloud_request_failed' }
    end
    if response.status_code ~= 200 then
        return { err_code = -1, err_msg = 'cloud_http_failed' }
    end
    if type(response.body) ~= 'string' then
        return { err_code = -2, err_msg = 'invalid_cloud_response' }
    end

    local json = cjson.new()
    json.decode_array_with_array_mt(true)
    json.decode_invalid_numbers(false)
    local ok, body = pcall(json.decode, response.body)
    if not ok or type(body) ~= 'table' or getmetatable(body) == cjson.array_mt or
        not is_finite_number(body.code) then
        return { err_code = -2, err_msg = 'invalid_cloud_response' }
    end
    if body.code ~= 0 then
        return { err_code = -1, err_msg = 'cloud_business_failed' }
    end
    local info = body.info
    if type(info) ~= 'table' or getmetatable(info) == cjson.array_mt then
        return { err_code = -2, err_msg = 'invalid_simple_info' }
    end

    local result = { err_code = 0, mode = '', identity = '', active = '', net_id = '', use_exit = '' }
    if type(info.networkId) == 'string' then
        local net_id = info.networkId:match('^%s*(.-)%s*$')
        if net_id:match('^%w+$') then result.net_id = net_id end
    end
    -- 仅按 networkPlan 前缀识别 IPRB，不再依赖 planCode 或 creationChannel。
    if type(info.networkPlan) == 'string' and info.networkPlan ~= '' then
        result.mode = info.networkPlan:sub(1, 4) == 'IPRB' and 'IPRB' or 'classic'
    end
    if result.mode == 'IPRB' then
        if result.net_id == '' or type(info.primaryDevice) ~= 'boolean' or
            type(info.enableStatus) ~= 'boolean' then
            return { err_code = -2, err_msg = 'invalid_simple_info' }
        end
        result.identity = info.primaryDevice and 'primary' or 'secondary'
        result.active = info.enableStatus and '1' or '0'
        if not info.primaryDevice then result.use_exit = info.useInternetExit == true and '1' or '0' end
    end
    return { info = result }
end

-- This function updates /etc/config/mptun, so subsequent processes may require reloading it.
--[[
    @method-type: call
    @method-name: notify_event
    @method-desc: The mptun module is notified that certain events have occurred.
    @in string      class       Event Type (cloud, mesh)
    @in string      msg         Brief description of the event
    @in object      info        Detailed event information; mesh event_code=10 indicates Mesh Node mode is enabled
    @out number     ?err_code   Error Code
    @out string     ?err_msg    Error Message
    @in-example:  {"jsonrpc":"2.0","id":1,"method":"call","params":["", "mptun", "notify_event",{"class":"cloud","msg":"cloud service closed","info":{"event_code":11}}]}
    @out-example: {"jsonrpc": "2.0", "id": 1, "result": {} }
--]]
-- 保留事件入口兼容旧调用；cloud 启停事件不再控制 IPRB。
function M.notify_event(params)
    if params.class == nil or params.info == nil then
        return {}
    end
    local event_class = params.class
    local event_info = params.info
    if event_class == 'cloud' then
        local code = event_info.event_code
        if code == nil or type(code) ~= 'number' then
            return {}
        end
        if code == 10 or code == 11 then
            return {}
        end
    elseif event_class == 'mesh' then
        local code = event_info.event_code
        if code == 10 then
            -- Mesh Node 模式已开启，直接关闭本地 IPRB 和 mptun。
            iprb_backend_call('force_disable_mptun', 2000)
            return {}
        end
    end
    return {}
end

-- 兼容旧 RPC 名称，与 notify_event 共用同一实现。
M.report_event_to_mptun = M.notify_event

-- 脚本运行状态增量只转发，字段校验、更新及变动通知由后台处理。
function M.report_IPRB_runtime(params)
    return iprb_backend_call('update_runtime', 5000, params)
end

-- IPRB 配置接收事件仅转发，网络归属校验及保存由后台处理。
function M.AW_net_config_received(params)
    return iprb_backend_call('cloud_configured', 5000, params)
end

-- 有效 IPRB 交由后台处理；后台不可用或归属已清空时，仅回读 classic 模式。
function M.AW_net_stoped_by_cloud(params)
    -- 只读状态查询最多等待 5 秒；超时后回读本地模式。oui.ubus 单位为毫秒。
    local result = iprb_backend_call('status', 5000)
    if (result.err_code == nil or result.err_code == 0) and not result.error and
        result.mode == 'IPRB' and type(result.status) == 'table' and
        (result.status.identity == 'primary' or result.status.identity == 'secondary') then
        -- 暂停或未连接仍是有效 IPRB，不以 enabled/connected 作为转发条件。
        -- cloud_stopped 由后台负责查询 simple、更新状态及通知。
        -- 缺失或类型错误的 ID 不补填；后台会忽略无有效归属的停止通知。
        local network_id = type(params) == 'table' and params.network_id or nil
        return iprb_backend_call('cloud_stopped', 60000, {
            network_id = type(network_id) == 'string' and network_id or nil
        })
    end

    local c = uci.cursor()
    local service_mode = c:get('mptun', 'global', 'service_mode')
    if service_mode ~= 'classic' then
        c:close()
        return {}
    end

    -- classic 沿用原有清理；其余情况直接忽略，不借查询恢复模式或推断被踢。
    c:delete('mptun', 'global', 'service_mode')
    c:commit('mptun')
    c:close()
    notify_gl_cloud_module_detached()
    return {}
end

--[[
    @method-type: call
    @method-name: is_meet_startup_conditions
    @method-desc: Check if the startup conditions are met..
    @out number     ?err_code   Error Code
    @out string     ?err_msg    Error Message
    @in-example:  {"jsonrpc":"2.0","id":1,"method":"call","params":["", "mptun", "is_meet_startup_conditions"]}
    @out-example: {"jsonrpc": "2.0", "id": 1, "result": {} }
--]]
function M.is_meet_startup_conditions()
    local ret = __is_meet_startup_conditions()
    if ret == true then
        return {}
    else
        return { err_code = -1 }
    end
end

-- Wi-Fi sync has no local cache or task state here. mpifd owns both.
local function is_wifi_sync_array(value)
    if type(value) ~= "table" then return false end
    local count, max_index = 0, 0
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then return false end
        count = count + 1
        if key > max_index then max_index = key end
    end
    return count == max_index
end

-- Rebuild public preview fields for both fetch and the cached status query.
local function wifi_sync_preview(networks)
    if not is_wifi_sync_array(networks) then return nil end
    local preview = setmetatable({}, cjson.array_mt)
    for _, group in ipairs(networks) do
        if type(group) ~= "table" or type(group.network) ~= "string" or group.network == "" or
            not is_wifi_sync_array(group.ifaces) then
            return nil
        end
        local view = { network = group.network, ifaces = setmetatable({}, cjson.array_mt) }
        for _, iface in ipairs(group.ifaces) do
            if type(iface) ~= "table" or type(iface.band) ~= "string" or iface.band == "" or
                type(iface.ssid) ~= "string" or type(iface.encryption) ~= "string" or
                iface.encryption == "" or
                (iface.key ~= nil and type(iface.key) ~= "string") or
                (iface.encryption ~= "none" and type(iface.key) ~= "string") then
                return nil
            end
            view.ifaces[#view.ifaces + 1] = {
                band = iface.band, ssid = iface.ssid,
                encryption = iface.encryption, key = iface.key
            }
        end
        preview[#preview + 1] = view
    end
    return preview
end

--[[
    @method-type: call
    @method-name: fetch_wifi_config
    @method-desc: fetch the primary's last successfully cached Wi-Fi configuration for preview without applying it
    @out string version Version of the fetched snapshot, required when submitting a selection; empty when fetching fails.
    @out array networks Network groups included in the preview.
    @out string networks[].network Network name: lan, guest, or iot.
    @out array networks[].ifaces Wi-Fi interfaces in this network.
    @out string networks[].ifaces[].band Wi-Fi band: 2g, 5g, or 6g.
    @out string networks[].ifaces[].ssid Wi-Fi network name.
    @out string networks[].ifaces[].encryption Wi-Fi encryption mode.
    @out string ?networks[].ifaces[].key Wi-Fi password; omitted for open networks.
    @out number ?err_code Error code when the request fails.
    @out string ?err_msg Error message when the request fails.
    @in-example: {"jsonrpc":"2.0","id":1,"method":"call","params":["","mptun","fetch_wifi_config",{}]}
    @out-example: {"jsonrpc":"2.0","id":1,"result":{"version":"0123456789abcdef0123456789abcdef:1","networks":[{"network":"lan","ifaces":[{"band":"5g","ssid":"home","encryption":"psk2","key":"example-password"}]}]}}
--]]
function M.fetch_wifi_config()
    -- oui.ubus uses yielding nginx sockets; Lua 5.1 cannot yield through pcall.
    local result, err = ubus.call("mpifd.wifi_sync", "fetch", {})
    if err ~= nil or type(result) ~= "table" then
        return { err_code = get_error_code('operation_failed'), err_msg = "wifi_sync_unavailable" }
    end
    if result.err_code ~= nil then
        -- 部分机型不支持 Wi-Fi 同步，未开放对端接口；获取失败统一返回空预览，避免前端报错。
        -- fetch_failed 也包含网络异常；此处仅转换响应，不清除后台缓存，其他错误仍正常返回。
        if result.err_code == -1 and result.err_msg == 'fetch_failed' then
            return { version = '', networks = setmetatable({}, cjson.array_mt) }
        end
        local messages = {
            busy = -2,
            stopped = -1, request_failed = -1
        }
        local code = messages[result.err_msg]
        if code and result.err_code == code then
            local name = 'operation_failed'
            if result.err_msg == 'busy' then name = 'busy' end
            return { err_code = get_error_code(name), err_msg = result.err_msg }
        end
        return { err_code = get_error_code('operation_failed'), err_msg = "wifi_sync_unavailable" }
    end
    if type(result.version) ~= "string" or result.version == "" or
        not is_wifi_sync_array(result.networks) then
        return { err_code = get_error_code('operation_failed'), err_msg = "wifi_sync_unavailable" }
    end

    local preview = wifi_sync_preview(result.networks)
    if not preview then return { err_code = get_error_code('operation_failed'), err_msg = "wifi_sync_unavailable" } end
    return { version = result.version, networks = preview }
end

--[[
    @method-type: call
    @method-name: get_wifi_sync_status
    @method-desc: read the cached Wi-Fi preview and selections from wholly successful apply requests
    @out string version Cached preview version; empty before the first successful fetch.
    @out array networks Cached preview, with the same fields as fetch_wifi_config.
    @out array applied Applied selections, containing only network and ifaces[].band.
    @in-example: {"jsonrpc":"2.0","id":1,"method":"call","params":["","mptun","get_wifi_sync_status",{}]}
    @out-example: {"jsonrpc":"2.0","id":1,"result":{"version":"","networks":[],"applied":[]}}
--]]
function M.get_wifi_sync_status()
    local result, err = ubus.call("mpifd.wifi_sync", "status", {})
    if err ~= nil or type(result) ~= "table" then
        return { err_code = get_error_code('operation_failed'), err_msg = "wifi_sync_unavailable" }
    end
    if result.err_code ~= nil then
        if result.err_code == -1 and (result.err_msg == "stopped" or result.err_msg == "request_failed") then
            return { err_code = get_error_code('operation_failed'), err_msg = result.err_msg }
        end
        return { err_code = get_error_code('operation_failed'), err_msg = "wifi_sync_unavailable" }
    end
    if type(result.version) ~= "string" or not is_wifi_sync_array(result.applied) then
        return { err_code = get_error_code('operation_failed'), err_msg = "wifi_sync_unavailable" }
    end
    local preview = wifi_sync_preview(result.networks)
    if not preview then return { err_code = get_error_code('operation_failed'), err_msg = "wifi_sync_unavailable" } end
    local applied = setmetatable({}, cjson.array_mt)
    for _, group in ipairs(result.applied) do
        if type(group) ~= "table" or type(group.network) ~= "string" or group.network == "" or
            not is_wifi_sync_array(group.ifaces) or #group.ifaces == 0 then
            return { err_code = get_error_code('operation_failed'), err_msg = "wifi_sync_unavailable" }
        end
        local selected = { network = group.network, ifaces = setmetatable({}, cjson.array_mt) }
        for _, iface in ipairs(group.ifaces) do
            if type(iface) ~= "table" or type(iface.band) ~= "string" or iface.band == "" then
                return { err_code = get_error_code('operation_failed'), err_msg = "wifi_sync_unavailable" }
            end
            selected.ifaces[#selected.ifaces + 1] = { band = iface.band }
        end
        applied[#applied + 1] = selected
    end
    if result.version == "" and (#preview > 0 or #applied > 0) then
        return { err_code = get_error_code('operation_failed'), err_msg = "wifi_sync_unavailable" }
    end
    return { version = result.version, networks = preview, applied = applied }
end

--[[
    @method-type: call
    @method-name: apply_wifi_config
    @method-desc: apply selected preview entries to existing local Wi-Fi interfaces
    @in string version Version returned by the fetch_wifi_config call used for this selection.
    @in array networks Selected network groups with band entries from that preview; SSID and security settings come from the backend cache.
    @in-example: {"jsonrpc":"2.0","id":1,"method":"call","params":["","mptun","apply_wifi_config",{"version":"0123456789abcdef0123456789abcdef:1","networks":[{"network":"lan","ifaces":[{"band":"5g"}]}]}]}
    @out number ?err_code Error code when the selection or application fails.
    @out string ?err_msg Error message when the selection or application fails.
    @out-example: {"jsonrpc":"2.0","id":1,"result":{}}
--]]
function M.apply_wifi_config(params)
    if type(params) ~= "table" or type(params.version) ~= "string" or
        params.version == "" or type(params.networks) ~= "table" then
        return { err_code = get_error_code('invalid_params'), err_msg = "invalid_selection" }
    end
    -- oui.ubus uses yielding nginx sockets; Lua 5.1 cannot yield through pcall.
    local result, err = ubus.call("mpifd.wifi_sync", "apply", {
        version = params.version,
        networks = params.networks
    })
    if err ~= nil or type(result) ~= "table" then
        return { err_code = get_error_code('operation_failed'), err_msg = "wifi_sync_unavailable" }
    end
    if result.err_code ~= nil then
        local messages = {
            busy = -2, fetch_required = 1, version_mismatch = 1, invalid_selection = 1,
            apply_failed = -1, stopped = -1, request_failed = -1
        }
        local code = messages[result.err_msg]
        if code and result.err_code == code then
            local name = 'operation_failed'
            if result.err_msg == 'busy' then name = 'busy'
            elseif result.err_msg == 'fetch_required' or result.err_msg == 'version_mismatch' then
                name = 'wifi_fetch_required'
            elseif result.err_msg == 'invalid_selection' then name = 'invalid_params' end
            return { err_code = get_error_code(name), err_msg = result.err_msg }
        end
        return { err_code = get_error_code('operation_failed'), err_msg = "wifi_sync_unavailable" }
    end
    if next(result) == nil then return result end
    return { err_code = get_error_code('operation_failed'), err_msg = "wifi_sync_unavailable" }
end

return M
