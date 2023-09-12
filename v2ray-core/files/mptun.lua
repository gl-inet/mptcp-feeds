--[[
    @object-name: mptun
    @object-desc: mptun
--]]

local ubus = require "oui.ubus"
local uci = require "uci"
local fs = require "oui.fs"

local M = {}

--[[
    @method-type: call
    @method-name: get_config
    @method-desc: get the current configuration

    @out bool enable  whether to enable

    @in-example: {"jsonrpc":"2.0","id":1,"method":"call","params":["","mptun","get_config"]}
    @out-example: {"jsonrpc": "2.0", "id": 1, "result": {"enable": true}}
 --]]
 M.get_config = function()
    local c = uci.cursor()

    local enable = c:get("mptun", "global", "enable")

    return {
			enable = enable == "1" and true or false,
	}
end

--[[
    @method-type: call
    @method-name: set_config
    @method-desc: modify the configuration file

    @in bool enable       whether to enable
    @out number ?err_code  error code
    @out number ?err_msg   error message

    @in-example: {"jsonrpc":"2.0","id":1,"method":"call","params":["","mptun","set_config", {"enable": true}]}
    @out-example: {"jsonrpc": "2.0", "id": 1, "result": null}
 --]]
 M.set_config = function(params)
    local c = uci.cursor()
    local enable = params.enable

    c:set("mptun", "global", "enable", enable and 1 or 0)
    c:commit("mptun")

    ngx.timer.at(2.0, function()
        ngx.pipe.spawn({"/etc/init.d/mpifd", "stop"}):wait()
        ngx.pipe.spawn({"/etc/init.d/mptun", "stop"}):wait()
        ngx.pipe.spawn({"/etc/init.d/kmwan", "stop"}):wait()
        if enable then
            ngx.pipe.spawn({"/etc/init.d/mpifd", "start"}):wait()
            ngx.pipe.spawn({"/etc/init.d/mptun", "start"}):wait()
            ngx.pipe.spawn({"/etc/init.d/kmwan", "start"}):wait()
        end
    end)
end

return M
