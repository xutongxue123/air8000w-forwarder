local util_mobile = {}

local function info(...)
    if type(USER_LOG_INFO) == "function" then
        USER_LOG_INFO("mobile", ...)
    else
        log.info("mobile", ...)
    end
end

local operators = {
    ["46000"] = "中国移动", ["46002"] = "中国移动", ["46004"] = "中国移动", ["46007"] = "中国移动",
    ["46008"] = "中国移动", ["46013"] = "中国移动", ["46020"] = "中国移动",
    ["46001"] = "中国联通", ["46006"] = "中国联通", ["46009"] = "中国联通", ["46010"] = "中国联通",
    ["46003"] = "中国电信", ["46005"] = "中国电信", ["46011"] = "中国电信", ["46012"] = "中国电信",
    ["46015"] = "中国广电",
}

function util_mobile.pinVerify(pin_code)
    pin_code = tostring(pin_code or "")
    if #pin_code < 4 or #pin_code > 8 then
        log.warn("mobile", "PIN 长度无效")
        return false
    end
    local sim_id = mobile.simid()
    if mobile.simPin(sim_id) then return true end
    local result = mobile.simPin(sim_id, mobile.PIN_VERIFY, pin_code)
    info("PIN 验证", result and "成功" or "失败")
    return result
end

function util_mobile.status()
    local codes = {
        [0] = "网络未注册", [1] = "网络已注册", [2] = "网络搜索中", [3] = "网络注册被拒绝",
        [4] = "网络状态未知", [5] = "网络已注册,漫游", [6] = "网络已注册,仅SMS",
        [7] = "网络已注册,漫游,仅SMS", [8] = "网络已注册,紧急服务",
        [9] = "网络已注册,非主要服务", [10] = "网络已注册,非主要服务,漫游",
    }
    return codes[mobile.status()] or "未知网络状态"
end

function util_mobile.operator()
    local sim_id = mobile.simid()
    local ok, imsi = pcall(mobile.imsi, sim_id)
    imsi = ok and imsi or ""
    if #imsi < 5 then return "unknown" end
    return operators[imsi:sub(1, 5)] or "unknown"
end

local function validNumber(number)
    return type(number) == "string" and number ~= "" and number ~= "00000000000"
end

function util_mobile.localNumber()
    local sim_id = mobile.simid()
    local ok, number = pcall(mobile.number, sim_id)
    if ok and validNumber(number) then return number end

    local fallback = config.FALLBACK_LOCAL_NUMBER
    if validNumber(fallback) then return fallback end
    return "未知"
end

local function uptime()
    local total = math.max(0, math.floor((tonumber(mcu.ticks()) or 0) / 1000))
    local hours = math.floor(total / 3600)
    local minutes = math.floor(total / 60) % 60
    local seconds = total % 60
    return string.format("%02d:%02d:%02d", hours, minutes, seconds)
end

function util_mobile.deviceInfo()
    local ok, rsrp = pcall(mobile.rsrp)
    local signal = "获取失败"
    if ok and type(rsrp) == "number" and rsrp ~= 0 then
        signal = tostring(rsrp) .. "dBm"
    end
    return table.concat({
        "本机号码: " .. util_mobile.localNumber(),
        "开机时长: " .. uptime(),
        "运营商: " .. util_mobile.operator(),
        "信号: " .. signal,
    }, "\n")
end

return util_mobile
