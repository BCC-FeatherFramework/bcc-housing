-- bcc-housing's shared Feather boundary: result envelopes and debug output.
-- Replaces bcc-utils' debugger.

Housing = Housing or {}

function Housing.Ok(value) return { ok = true, value = value } end
function Housing.Err(code, message, details)
    return { ok = false, code = code, message = message, details = details }
end

-- Debug output in dev mode: DBG:Info / DBG:Success / DBG:Warning / DBG:Error(...)
-- (DBG.Info(...) works too). Tables are JSON-encoded. Every line gets a colored
-- label and ends with ^0, so a color never carries over to the next line.
local function debugPrinter(color, label)
    return function(first, ...)
        if not Config.DevMode then return end
        local values = first == DBG and table.pack(...) or table.pack(first, ...)
        local parts = {}
        for i = 1, values.n do
            local value = values[i]
            if type(value) == 'table' then
                local ok, encoded = pcall(json.encode, value)
                parts[i] = ok and encoded or tostring(value)
            else
                parts[i] = tostring(value)
            end
        end
        for line in (table.concat(parts, ' ') .. '\n'):gmatch('(.-)\n') do
            print(('^%d[bcc-housing %s]^0 %s^0'):format(color, label, line))
        end
    end
end

DBG = {
    Info = debugPrinter(4, 'info'),
    Success = debugPrinter(2, 'ok'),
    Warning = debugPrinter(3, 'warn'),
    Error = debugPrinter(1, 'error')
}
