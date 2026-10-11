-- bcc-housing's boundary to the Feather Framework (client side).
-- Keeps the call shapes the existing menus use (an RPC object with
-- Register/Call/CallAsync/Notify) on top of feather-core, and resolves key names
-- through feather-toolkit (replaces BccUtils.Keys).

HousingRPC = {}

-- Returns every value the server handler passed to cb(...), or nil on a
-- transport failure (the second value then holds the error).
function HousingRPC:CallAsync(name, params)
    return exports['feather-core']:CallRPCAsync(name, params or {})
end

function HousingRPC:Call(name, params, callback)
    CreateThread(function()
        local results = table.pack(self:CallAsync(name, params))
        if callback then callback(table.unpack(results, 1, results.n)) end
    end)
end

-- Fire-and-forget call to the server.
function HousingRPC:Notify(name, params)
    return exports['feather-core']:NotifyRPC(name, params or {})
end

-- Server-to-client procedures. Handler shape as before: function(params, cb).
function HousingRPC:Register(name, handler)
    exports['feather-core']:RegisterRPC(name, function(params, respond)
        local called, problem = xpcall(handler, debug.traceback, params or {}, respond)
        if not called then
            print(('[bcc-housing] client rpc %s failed: %s'):format(name, tostring(problem)))
        end
    end)
end

-- Control hash for a key name ('G', 'UP', 'BACKSPACE'), or the value itself when
-- it is already a hash.
HousingKeys = setmetatable({}, {
    __index = function(cache, key)
        if type(key) == 'number' then return key end
        local resolved = exports['feather-toolkit']:ResolveControl(key)
        local value = type(resolved) == 'table' and resolved.ok and resolved.value or resolved
        if type(value) == 'table' then value = value.hash or value.control end
        rawset(cache, key, value)
        return value
    end
})
