local M = {}

function M.IPRB_status()
    local mod = dofile('/usr/lib/oui-httpd/rpc/mptun')
    return mod.get_IPRB_status()
end

function M.AW_global_summary()
    local mod = dofile('/usr/lib/oui-httpd/rpc/mptun')
    return mod.AW_get_global_summary()
end
return M
