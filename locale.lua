-- Translations are owned by feather-core. Core's locale table is shared by every
-- resource and the first registration of a key wins, so bcc-housing registers
-- each key as "bcc-housing.<key>". Call sites keep using _("key") / _U("key").
Feather = Feather or {}
Feather.Locale = Feather.Locale or {}

local PREFIX = 'bcc-housing.'

function Feather.Locale.register(locale, translations)
    local prefixed = {}
    for key, value in pairs(translations) do prefixed[PREFIX .. key] = value end
    local result = exports['feather-core']:RegisterLocale(locale, prefixed)
    if type(result) ~= 'table' or result.ok ~= true then
        error(('[bcc-housing] locale registration failed for %s: %s'):format(
            tostring(locale), tostring(type(result) == 'table' and result.code or 'invalid_result')))
    end
    return result
end

function Feather.Locale.translate(key, ...)
    local result = exports['feather-core']:TranslateLocale(0, PREFIX .. key, ...)
    if type(result) == 'table' and result.ok == true and type(result.value) == 'string' then
        return result.value
    end
    return tostring(key)
end

function _(str, ...) -- Translate string
    return Feather.Locale.translate(str, ...)
end

function _U(str, ...) -- Translate string first char uppercase
    local translation = _(str, ...)
    return translation:sub(1, 1):upper() .. translation:sub(2)
end
