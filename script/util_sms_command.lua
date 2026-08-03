local util_web = require "util_web"

local util_sms_command = {}

local function trim(value)
    return (tostring(value or ""):match("^%s*(.-)%s*$") or "")
end

local function splitFields(content)
    local result = {}
    for field in (content .. ","):gmatch("(.-),") do table.insert(result, field) end
    return result
end

local function normalizeToken(value)
    return trim(value):lower()
end

function util_sms_command.handle(content)
    local command = type(config.SMS_WIFI_COMMAND) == "table" and config.SMS_WIFI_COMMAND or {}
    local keyword = normalizeToken(command.keyword)
    if command.enabled ~= true or keyword == "" then return false end
    content = tostring(content or ""):gsub("[，、]", ",")
    local fields = splitFields(content)
    if normalizeToken(fields[1]) ~= keyword then return false end

    local mode = normalizeToken(fields[2])
    if mode ~= "w" then return false end

    local action, ok
    if mode == "w" and #fields == 4 then
        action, fields[4], fields[5] = "set", fields[3], fields[4]
    else
        action = normalizeToken(fields[3])
    end
    if (action == "on" or action == "开启") and #fields == 3 then
        ok = util_web.applyWifiSmsCommand("on")
    elseif (action == "off" or action == "关闭") and #fields == 3 then
        ok = util_web.applyWifiSmsCommand("off")
    elseif (action == "set" or action == "s" or action == "设置")
        and #fields == 5 and trim(fields[4]) ~= "" then
        ok = util_web.applyWifiSmsCommand("set", trim(fields[4]), trim(fields[5]))
    end
    log.info("smscmd", "wifi command", action or "invalid", "success", ok == true)
    return true, ok
end

return util_sms_command
