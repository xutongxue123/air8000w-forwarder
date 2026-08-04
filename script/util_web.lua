local M = {}
local util_history = require "util_history"
local util_router = require "util_router"
local KEY = "web-config-overrides-v1"
local started = false
local status_provider

local function clone(v)
    if type(v) ~= "table" then return v end
    local r = {}; for k, x in pairs(v) do r[k] = clone(x) end; return r
end
local function merge(to, from)
    for k, v in pairs(from) do
        if type(v) == "table" and type(to[k]) == "table" then merge(to[k], v) else to[k] = clone(v) end
    end
end

local function validateConfigPolicies(value)
    if type(value) ~= "table" or type(value.CHANNELS) ~= "table" then return true end
    for channel_name, channel_config in pairs(value.CHANNELS) do
        if type(channel_config) == "table" and channel_config.enabled ~= false then
            local valid, detail = util_router.validatePolicy(channel_name, channel_config, value)
            if not valid then
                return false, tostring(channel_name) .. ": " .. tostring(detail or "channel policy is invalid")
            end
        end
    end
    return true
end
local TEMPLATE_FIELDS = {
    "sms_template", "call_template", "system_template",
    "sms_title_template", "call_title_template", "system_title_template",
}
local DEFAULT_TEMPLATES = {}
for _, channel in pairs(type(config.CHANNELS) == "table" and config.CHANNELS or {}) do
    if type(channel) == "table" and type(channel.type) == "string" then
        local templates = {}
        for _, field in ipairs(TEMPLATE_FIELDS) do templates[field] = channel[field] end
        DEFAULT_TEMPLATES[channel.type] = templates
    end
end
function M.applySavedConfig()
    local saved = fskv.get(KEY)
    if type(saved) == "table" then
        local default_channels = type(config.CHANNELS) == "table" and config.CHANNELS or {}
        local legacy_templates = {
            sms_template = {
                "{content}\n\n发件号码: {sender}\n发件时间: {received_at}\n#SMS",
                "Air8000W 短信归档\n消息ID: {message_id}\n类型: {kind}\n发送方: {sender}\n时间: {received_at}\n内容: {content}",
                "📩 {sender}\n{content}\n{received_at}",
                "短信来自: {sender}\n时间: {received_at}\n内容: {content}",
            },
            call_template = {
                "📞 {sender}\n{content}\n事件时间: {received_at}\n#CALL",
                "Air8000W 通话通知\n消息ID: {message_id}\n电话号码: {sender}\n时间: {received_at}\n内容: {content}",
                "📞 {sender}\n{content}\n{received_at}",
                "通话号码: {sender}\n时间: {received_at}\n事件: {content}",
            },
            system_template = {
                "⚙️ {content}\n时间: {received_at}\n{device_info}",
                "Air8000W 系统通知\n消息ID: {message_id}\n时间: {received_at}\n内容: {content}\n{device_info}",
            },
        }
        local function migrateTemplate(channel_name, channel, field)
            local default_channel = default_channels[channel_name]
            local value = channel[field]
            if type(default_channel) ~= "table" or type(value) ~= "string" then return end
            for _, legacy in ipairs(legacy_templates[field] or {}) do
                if value == legacy then
                    channel[field] = default_channel[field]
                    return
                end
            end
        end
        for channel_name, channel in pairs(type(saved.CHANNELS) == "table" and saved.CHANNELS or {}) do
            if type(channel) == "table" and channel.sms_mode == "off" then
                channel.sms_mode = "all"
                channel.enabled = false
            end
            if type(channel) == "table" then
                if channel.sms_mode == "全部" then channel.sms_mode = "all" end
                if channel.sms_mode == "过滤" or channel.sms_mode == "仅匹配关键词" then
                    channel.sms_mode = "verification"
                end
                if channel.sms_mode == "不接收短信" then
                    channel.sms_mode = "all"
                    channel.enabled = false
                end
                if channel.sms_mode ~= "all" and channel.sms_mode ~= "verification" then
                    channel.sms_mode = "all"
                end
            end
            if type(channel) == "table" then
                migrateTemplate(channel_name, channel, "sms_template")
                migrateTemplate(channel_name, channel, "call_template")
                migrateTemplate(channel_name, channel, "system_template")
                if type(channel.title_template) == "string" and channel.title_template ~= ""
                    and channel.title_template ~= "{sender}" then
                    channel.sms_title_template = channel.sms_title_template or channel.title_template
                    channel.call_title_template = channel.call_title_template or channel.title_template
                    channel.system_title_template = channel.system_title_template or channel.title_template
                end
                channel.title_template = nil
            end
        end
        merge(config, saved)
    end
end

function M.applyWifiSmsCommand(action, ssid, password)
    local next_config = clone(config)
    local network = type(next_config.NETWORK) == "table" and next_config.NETWORK or {}
    local wifi = type(network.wifi) == "table" and network.wifi or {}
    next_config.NETWORK = network
    network.wifi = wifi
    if action == "on" then
        wifi.enabled = true
    elseif action == "off" then
        wifi.enabled = false
    elseif action == "set" and type(ssid) == "string" and ssid ~= "" and type(password) == "string" then
        wifi.enabled = true
        wifi.ssid = ssid
        wifi.password = password
    else
        return false
    end
    next_config.WEB = nil
    local ok, encoded = pcall(json.encode, next_config)
    if not ok or type(encoded) ~= "string" or #encoded > 3800 or fskv.set(KEY, next_config) ~= true then
        return false
    end
    sys.timerStart(rtos.reboot, 300)
    return true
end
function M.setStatusProvider(provider)
    status_provider = type(provider) == "function" and provider or nil
    _G.WEB_STATUS_PROVIDER = status_provider
end
local function formatUptime()
    local total = math.floor(mcu.ticks() / 1000)
    local days = math.floor(total / 86400)
    total = total % 86400
    local hours = math.floor(total / 3600)
    total = total % 3600
    local minutes = math.floor(total / 60)
    local seconds = total % 60
    return string.format("%d天%d小时%d分%d秒", days, hours, minutes, seconds)
end

local function fallbackStatus()
    local network = (require "util_network").getStatus()
    local raw_notify = (require "util_notify").getStatus()
    local lua_total, lua_used = rtos.meminfo("lua")
    local sys_total, sys_used = rtos.meminfo("sys")
    local function number(value, fallback)
        value = tonumber(value)
        return value or fallback or 0
    end
    local function text(value, fallback)
        if type(value) == "string" or type(value) == "number" or type(value) == "boolean" then return value end
        return fallback or "unknown"
    end
    local enabled_channels = 0
    for _, channel in pairs(type(config.CHANNELS) == "table" and config.CHANNELS or {}) do
        if type(channel) == "table" and channel.enabled ~= false then
            enabled_channels = enabled_channels + 1
        end
    end
    local operator_ok, operator = pcall(function()
        return (require "util_mobile").operator()
    end)
    if not operator_ok or operator == "unknown" then
        operator = network.ready and "运营商未识别" or "等待蜂窝网络注册"
    end
    local number_ok, local_number = pcall(function()
        return (require "util_mobile").localNumber()
    end)
    if not number_ok or type(local_number) ~= "string" or local_number == "" then
        local_number = "未知"
    end
    return {
        uptime = formatUptime(),
        sim_ready = mobile.simPin(mobile.simid()) == true,
        data_ready = network.ready,
        data_type = text(network.network_type, "none"),
        data_adapter = number(network.adapter, -1),
        cellular_flight_mode = network.cellular_flight_mode == true,
        wifi_local_ip = text(network.wifi_local_ip, "none"),
        wifi_rssi = text(network.wifi_rssi, "unknown"),
        operator = text(operator, "运营商未识别"),
        local_number = local_number,
        rsrp = number(mobile.rsrp(), 0), rsrq = number(mobile.rsrq(), 0), snr = number(mobile.snr(), 0),
        notify = {
            queue_length = number(raw_notify.queue_length),
            retrying_count = number(raw_notify.retrying_count),
            bark_enabled = raw_notify.bark_enabled == true,
            enabled_channels = enabled_channels,
        },
        lua_mem = string.format("%d/%dKB", math.floor(lua_used / 1024), math.floor(lua_total / 1024)),
        sys_mem = string.format("%d/%dKB", math.floor(sys_used / 1024), math.floor(sys_total / 1024)),
    }
end

local ABC = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local function b64(s)
    s = tostring(s or ""):gsub("[^" .. ABC .. "=]", "")
    local bits = s:gsub(".", function(c)
        if c == "=" then return "" end
        local n = (ABC:find(c, 1, true) or 1) - 1; local out = ""
        for i = 6, 1, -1 do out = out .. (n % 2 ^ i - n % 2 ^ (i - 1) > 0 and "1" or "0") end
        return out
    end)
    return (bits:gsub("%d%d%d?%d?%d?%d?%d?%d?", function(x)
        if #x ~= 8 then return "" end
        local n = 0; for i = 1, 8 do if x:sub(i, i) == "1" then n = n + 2 ^ (8 - i) end end
        return string.char(n)
    end))
end
local function auth(headers)
    local value; for k, v in pairs(headers or {}) do if tostring(k):lower() == "authorization" then value = v end end
    local code = type(value) == "string" and value:match("^[Bb]asic%s+(.+)$")
    local user, pass = b64(code):match("^([^:]*):(.*)$")
    return user == config.WEB.username and pass == config.WEB.password
end
local function reply(code, body, typ)
    return code, { ["Content-Type"] = typ or "text/plain; charset=utf-8", ["Cache-Control"] = "no-store" }, body or ""
end
local function jsonReply(value)
    local ok, encoded = pcall(json.encode, value)
    if ok and type(encoded) == "string" then return reply(200, encoded, "application/json; charset=utf-8") end
    log.error("web", "JSON encode failed", tostring(encoded))
    return reply(500, '{"ok":false,"error":"status_encode_failed"}', "application/json; charset=utf-8")
end

local function splitUri(uri)
    local path, query = tostring(uri or ""):match("^([^?]*)%?(.*)$")
    return path or tostring(uri or ""), query or ""
end

local function pageQuery(query)
    local values = {}
    for item in tostring(query or ""):gmatch("[^&]+") do
        local key, value = item:match("^([^=]+)=(.*)$")
        if key and value then values[key] = value end
    end
    return tonumber(values.limit), tonumber(values.before)
end
local DASHBOARD = [[<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Air8000W 控制台</title><style>*{box-sizing:border-box}body{margin:0;background:#f5f7fb;color:#172033;font:14px -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}.app{min-height:100vh;display:grid;grid-template-columns:245px 1fr}.side{background:#102f61;color:#e7efff;padding:28px 16px;display:flex;flex-direction:column}.brand{font-size:17px;font-weight:750;padding:2px 12px 30px}.brand small{display:block;color:#a8bfdf;font-size:12px;font-weight:400;margin-top:5px}.nav{display:grid;gap:7px}.nav button{border:0;background:transparent;color:#c2d2ee;text-align:left;border-radius:11px;padding:14px;font:inherit;cursor:pointer;transition:.18s}.nav button:hover,.nav button.active{background:#fff;color:#102f61;font-weight:700}.foot{margin-top:auto;color:#abc3e5;border-top:1px solid #315384;padding:18px 12px 0;font-size:12px}.dot{display:inline-block;width:8px;height:8px;border-radius:50%;background:#13c99a;margin-right:6px}.top{height:72px;background:#fff;border-bottom:1px solid #e2e8f0;padding:0 40px;display:flex;align-items:center;justify-content:space-between}.badge{color:#047857;background:#ecfdf5;border:1px solid #a7f3d0;padding:8px 12px;border-radius:20px}.main{padding:34px 40px;max-width:1420px}.page{display:none}.page.active{display:block}.hero{display:flex;justify-content:space-between;align-items:start;margin-bottom:24px}.hero h1{font-size:28px;margin:0 0 7px}.hero p,.muted{color:#64748b;margin:0}.btn{border:0;background:#2563eb;color:#fff;border-radius:9px;padding:10px 15px;font-weight:650;cursor:pointer}.btn:hover{background:#1d4ed8}.cards{display:grid;grid-template-columns:repeat(4,1fr);gap:15px}.card,.panel{background:#fff;border:1px solid #e2e8f0;border-radius:15px;box-shadow:0 3px 13px #18315a08}.card{padding:19px}.label{color:#718096;font-size:12px;margin-bottom:12px}.value{font-size:25px;font-weight:750}.sub{color:#718096;font-size:12px;margin-top:9px}.grid{display:grid;grid-template-columns:2.2fr 1fr;gap:16px;margin-top:16px}.panel{padding:22px}.panel h2{font-size:16px;margin:0 0 6px}.signal{background:#eff8ff;border:1px solid #dbeafe;border-radius:13px;padding:18px;margin:16px 0}.signal b{font-size:30px}.meter{height:7px;background:#dbeafe;border-radius:9px;overflow:hidden;margin:14px 0}.meter i{display:block;background:#2563eb;height:100%;width:0}.kv{display:grid;grid-template-columns:1fr 1fr;gap:0 22px}.kv div,.status li{padding:11px 0;border-bottom:1px solid #edf1f5}.kv span{display:block;color:#718096;font-size:12px;margin-bottom:5px}.status{padding:0;margin:0}.status li{list-style:none;display:flex;justify-content:space-between}.ok{color:#059669}.channels{display:grid;grid-template-columns:255px 1fr;gap:16px}.channel button{width:100%;border:1px solid transparent;background:#fff;text-align:left;border-radius:10px;padding:13px;margin:3px 0;cursor:pointer}.channel button.active,.channel button:hover{background:#eff6ff;border-color:#bfdbfe}.channel small{display:block;color:#718096;margin-top:4px}.form{display:grid;grid-template-columns:1fr 1fr;gap:14px}.field label{display:block;font-size:12px;color:#475569;font-weight:650;margin-bottom:6px}.field input,.field select{width:100%;border:1px solid #cbd5e1;border-radius:8px;padding:10px;font:inherit}.field input:focus,.field select:focus{outline:3px solid #bfdbfe;border-color:#2563eb}.wide{grid-column:1/-1}.check{display:flex;align-items:center;gap:8px}.toast{position:fixed;right:20px;bottom:20px;background:#172033;color:#fff;padding:12px 15px;border-radius:9px;opacity:0;transition:.2s}.toast.show{opacity:1}@media(max-width:850px){.app{grid-template-columns:1fr}.side{padding:14px}.brand{padding:2px 4px 12px}.nav{grid-template-columns:1fr 1fr}.foot{display:none}.top{height:58px;padding:0 18px}.main{padding:25px 18px}.cards{grid-template-columns:1fr 1fr}.grid,.channels{grid-template-columns:1fr}}@media(max-width:430px){.cards,.form,.nav{grid-template-columns:1fr}.hero h1{font-size:24px}}</style><body><div class="app"><aside class="side"><div class="brand">Air8000W 短信转发器<small>设备控制台</small></div><nav class="nav"><button class="active" data-page="overview">设备概览</button><button data-page="channels">通知渠道</button></nav><div class="foot"><span class="dot"></span>设备运行中<br><span id="sideip">等待网络地址</span></div></aside><section><header class="top"><span id="crumb" class="muted">控制中心 / 设备概览</span><span class="badge"><span class="dot"></span><span id="link">检查中</span></span></header><main class="main"><section id="overview" class="page active"><div class="hero"><div><h1>设备概览</h1><p>查看通信链路、蜂窝网络与通知服务的实时状态。</p></div><button class="btn" id="refresh">刷新状态</button></div><div class="cards"><div class="card"><div class="label">连接状态</div><div class="value" id="online">--</div><div class="sub" id="network">--</div></div><div class="card"><div class="label">Wi-Fi 信号</div><div class="value" id="rssi">--</div><div class="sub">RSSI dBm</div></div><div class="card"><div class="label">待发通知</div><div class="value" id="queue">--</div><div class="sub" id="retry">重试任务 --</div></div><div class="card"><div class="label">运行时长</div><div class="value" id="uptime">--</div><div class="sub" id="memory">内存 --</div></div></div><div class="grid"><article class="panel"><h2>移动网络与设备</h2><p class="muted" id="operator">正在读取运营商信息</p><div class="signal"><span class="label">实时信号</span><br><b id="rsrp">--</b> dBm<div class="meter"><i id="bar"></i></div><div class="kv"><div><span>RSRP</span><b id="rsrp2">--</b></div><div><span>RSRQ / SNR</span><b id="quality">--</b></div></div></div><div class="kv"><div><span>SIM 卡</span><b id="sim">--</b></div><div><span>Wi-Fi 局域网 IP</span><b id="ip">--</b></div><div><span>数据出口</span><b id="data">--</b></div><div><span>系统内存</span><b id="mem2">--</b></div></div></article><article class="panel"><h2>服务状态</h2><p class="muted">短信转发服务实时检查</p><ul class="status"><li>网络连接 <b id="snet">--</b></li><li>SIM 卡状态 <b id="ssim">--</b></li><li>通知队列 <b id="snotify">--</b></li><li>Bark 渠道 <b id="sbark">--</b></li></ul></article></div></section><section id="channels" class="page"><div class="hero"><div><h1>通知渠道</h1><p>配置短信和设备事件的第三方推送渠道。保存并重启后配置生效。</p></div><button class="btn" id="save">保存并重启</button></div><div class="channels"><article class="panel"><h2>渠道列表</h2><p class="muted">选择渠道后编辑其配置。</p><div class="channel" id="channelList"></div></article><article class="panel"><h2 id="channelTitle">选择通知渠道</h2><p class="muted" id="channelHint">渠道配置保存在设备中。</p><div class="form" id="form"></div><p class="muted" style="margin-top:16px">保存后设备会重启；敏感凭据仅在已登录的局域网管理页显示。</p></article></div></section></main></section></div><div class="toast" id="toast"></div><script>let cfg={},active='',timer;const $=x=>document.getElementById(x),esc=x=>String(x??'').replace(/[&<>"]/g,x=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[x]));function set(x,v){$(x).textContent=v??'--'}function note(x){$('toast').textContent=x;$('toast').classList.add('show');clearTimeout(timer);timer=setTimeout(()=>$('toast').classList.remove('show'),2600)}function stat(s){let ip=s.wifi_local_ip||'未获取',on=s.data_ready;set('online',on?'在线':'离线');set('network',(s.network_type||'无网络')+' / '+ip);set('rssi',s.wifi_rssi==='unknown'?'--':s.wifi_rssi);set('queue',s.notify?.queue_length??0);set('retry','重试任务 '+(s.notify?.retrying_count??0));set('uptime',s.uptime);set('memory','Lua '+(s.lua_mem||'--'));set('operator',s.operator||'未知运营商');set('rsrp',s.rsrp);set('rsrp2',s.rsrp);set('quality',(s.rsrq??'--')+' / '+(s.snr??'--'));set('sim',s.sim_ready?'已就绪':'未就绪');set('ip',ip);set('data',(s.data_type||'无')+' / '+(s.data_adapter??'--'));set('mem2',s.sys_mem);$('bar').style.width=Math.max(5,Math.min(100,((Number(s.rsrp)||-120)+120)*1.5))+'%';set('sideip',ip);set('link',on?'链路正常':'链路未就绪');$('snet').innerHTML=on?'<span class="ok">● 正常</span>':'离线';$('ssim').innerHTML=s.sim_ready?'<span class="ok">● 正常</span>':'未就绪';set('snotify','队列 '+(s.notify?.queue_length??0));$('sbark').innerHTML=s.notify?.bark_enabled?'<span class="ok">● 正常</span>':'已关闭'}async function loadStatus(){try{let r=await fetch('/api/status');if(!r.ok)throw 0;stat(await r.json())}catch(e){set('link','读取失败')}}async function loadCfg(){let r=await fetch('/api/config');if(!r.ok)throw Error('无法读取配置');cfg=await r.json();channels()}function page(x){document.querySelectorAll('.page').forEach(e=>e.classList.toggle('active',e.id===x));document.querySelectorAll('.nav button').forEach(e=>e.classList.toggle('active',e.dataset.page===x));set('crumb','控制中心 / '+(x==='overview'?'设备概览':'通知渠道'));if(x==='channels')loadCfg().catch(e=>note(e.message))}document.querySelectorAll('.nav button').forEach(e=>e.onclick=()=>page(e.dataset.page));function channels(){let keys=Object.keys(cfg.CHANNELS||{}),list=$('channelList');if(!keys.length){list.textContent='尚未配置渠道';return}if(!keys.includes(active))active=keys[0];list.innerHTML=keys.map(k=>{let c=cfg.CHANNELS[k];return `<button class="${k===active?'active':''}" data-k="${esc(k)}"><b>${esc(k)}</b><small>${esc(c.type||'custom')} · ${c.enabled?'已启用':'未启用'}</small></button>`}).join('');list.querySelectorAll('button').forEach(e=>e.onclick=()=>{active=e.dataset.k;channels()});form()}function form(){let c=cfg.CHANNELS?.[active];if(!c)return;set('channelTitle',active);set('channelHint',(c.type||'custom')+' 通知渠道');$('form').innerHTML=Object.entries(c).filter(([k,v])=>k!=='match'&&typeof v!=='object').map(([k,v])=>typeof v==='boolean'?`<div class="field check"><input id="x${esc(k)}" data-k="${esc(k)}" type="checkbox" ${v?'checked':''}><label for="x${esc(k)}">${esc(k)}</label></div>`:k==='sms_mode'?`<div class="field"><label>${esc(k)}</label><select data-k="${esc(k)}"><option ${v==='all'?'selected':''}>all</option><option ${v==='verification'?'selected':''}>verification</option><option ${v==='off'?'selected':''}>off</option></select></div>`:`<div class="field ${/webhook|url|api/.test(k)?'wide':''}"><label>${esc(k)}</label><input data-k="${esc(k)}" value="${esc(v)}"></div>`).join('');$('form').querySelectorAll('[data-k]').forEach(e=>e.oninput=()=>c[e.dataset.k]=e.type==='checkbox'?e.checked:e.value)}$('refresh').onclick=loadStatus;$('save').onclick=async()=>{try{let r=await fetch('/api/config',{method:'PUT',headers:{'Content-Type':'application/json'},body:JSON.stringify(cfg)});if(!r.ok)throw Error(await r.text());note('已保存，设备正在重启…')}catch(e){note(e.message)}};loadStatus();setInterval(loadStatus,15000)</script></body></html>]]
local function replaceLiteral(source, needle, replacement)
    local first, last = source:find(needle, 1, true)
    if not first then return source end
    return source:sub(1, first - 1) .. replacement .. source:sub(last + 1)
end

DASHBOARD = replaceLiteral(DASHBOARD,
    '<p class="muted" id="operator">正在读取运营商信息</p>',
    '<p class="muted">运营商：<span id="operator">正在读取</span> · 本机号码：<span id="localNumber">未知</span></p>')
DASHBOARD = replaceLiteral(DASHBOARD,
    "set('operator',s.operator||'未知运营商');",
    "set('operator',s.operator||'未知运营商');set('localNumber',s.local_number||'未知');")
DASHBOARD = replaceLiteral(DASHBOARD,
    '<button class="btn" id="save">保存并重启</button>',
    '<button class="btn" id="save">保存配置</button>')
DASHBOARD = replaceLiteral(DASHBOARD,
    "$('save').onclick=async()=>{try{let r=await fetch('/api/config',{method:'PUT',headers:{'Content-Type':'application/json'},body:JSON.stringify(cfg)});if(!r.ok)throw Error(await r.text());note('已保存，设备正在重启…')}catch(e){note(e.message)}};",
    "async function saveConfig(){try{let r=await fetch('/api/config',{method:'PUT',headers:{'Content-Type':'application/json'},body:JSON.stringify(cfg)});if(!r.ok)throw Error(await r.text());note('配置已保存');return true}catch(e){note(e.message);return false}}async function restart(){if(!await saveConfig())return;try{let r=await fetch('/api/reboot',{method:'POST'});if(!r.ok)throw Error(await r.text());note('配置已保存，设备正在重启…')}catch(e){note(e.message)}}$('save').onclick=saveConfig;")
DASHBOARD = replaceLiteral(DASHBOARD,
    "保存后设备会重启；敏感凭据仅在已登录的局域网管理页显示。",
    "配置保存后立即生效；敏感凭据仅在已登录的局域网管理页显示。")
DASHBOARD = replaceLiteral(DASHBOARD,
    "配置短信和设备事件的第三方推送渠道。保存并重启后配置生效。",
    "配置短信和设备事件的第三方推送渠道。渠道保存后立即生效。")

DASHBOARD = replaceLiteral(DASHBOARD,
    "<option ${v==='verification'?'selected':''}>verification</option><option ${v==='off'?'selected':''}>off</option>",
    "<option ${v==='verification'?'selected':''}>verification</option>")
DASHBOARD = replaceLiteral(DASHBOARD, ",off:'不接收短信'", "")

DASHBOARD = replaceLiteral(DASHBOARD,
    "<option ${v==='all'?'selected':''}>all</option><option ${v==='verification'?'selected':''}>verification</option>",
    "<option value='all' ${v==='all'?'selected':''}>all</option><option value='verification' ${v==='verification'?'selected':''}>verification</option>")

DASHBOARD = replaceLiteral(DASHBOARD,
    "<b>${esc(k)}</b><small>${esc(c.type||'custom')}",
    "<b>${esc(k==='dingtalk'?'钉钉':k)}</b><small>${esc(c.type||'custom')}")
DASHBOARD = replaceLiteral(DASHBOARD,
    "function form(){let c=cfg.CHANNELS?.[active];if(!c)return;",
    "function form(){let c=cfg.CHANNELS?.[active];if(!c)return;c.sms_mode=c.sms_mode==='verification'?'verification':'all';")
DASHBOARD = replaceLiteral(DASHBOARD,
    "e.oninput=()=>c[e.dataset.k]=e.type==='checkbox'?e.checked:e.value",
    "e.oninput=e.onchange=()=>c[e.dataset.k]=e.type==='checkbox'?e.checked:e.value")
DASHBOARD = replaceLiteral(DASHBOARD, "function stat(s){",
    "function grade(v,type){let n=Number(v);if(!Number.isFinite(n))return '--';let good=type==='wifi'?-60:-85,fair=type==='wifi'?-75:-100;return n+' · '+(n>=good?'好':n>=fair?'良':'差')}function stat(s){")
DASHBOARD = replaceLiteral(DASHBOARD,
    '<div class="sub" id="memory">内存 --</div>',
    '<div class="sub" id="memory">Lua --</div>')
DASHBOARD = DASHBOARD:gsub('<div><span>[^<]*</span><b id="mem2">--</b></div>', '')
DASHBOARD = replaceLiteral(DASHBOARD, '<div><span>系统内存</span><b id="mem2">--</b></div>', '')
DASHBOARD = replaceLiteral(DASHBOARD,
    "set('memory','Lua '+(s.lua_mem||'--'));",
    "set('memory','Lua '+(s.lua_mem||'--'));window.__dashboardStatus=s;window.renderRuntimeSpace?.(s);")
DASHBOARD = replaceLiteral(DASHBOARD, "set('mem2',s.sys_mem);", '')
DASHBOARD = replaceLiteral(DASHBOARD, "set('rssi',s.wifi_rssi==='unknown'?'--':s.wifi_rssi);",
    "set('rssi',grade(s.wifi_rssi,'wifi'));")
DASHBOARD = replaceLiteral(DASHBOARD, "set('rsrp',s.rsrp);set('rsrp2',s.rsrp);",
    "set('rsrp',grade(s.rsrp,'cell'));set('rsrp2',grade(s.rsrp,'cell'));")
DASHBOARD = replaceLiteral(DASHBOARD,
    '<article class="panel"><h2>移动网络与设备</h2>',
    '<article class="panel network-panel"><div class="network-panel-heading"><div class="network-panel-copy"><h2>移动网络与设备</h2>')
DASHBOARD = replaceLiteral(DASHBOARD,
    '</span></p><div class="signal">',
    '</span></p></div><div class="flight-mode-card-status" id="cellularFlightModeStatusWrap" aria-live="polite"><span>飞行模式</span><b id="cellularFlightModeStatus">--</b></div></div><div class="signal">')
DASHBOARD = replaceLiteral(DASHBOARD,
    "set('data',(s.data_type||'无')+' / '+(s.data_adapter??'--'));",
    "set('cellularFlightModeStatus',s.cellular_flight_mode===true?'已开启':'未开启');let flightStatus=$('cellularFlightModeStatusWrap');if(flightStatus)flightStatus.classList.toggle('enabled',s.cellular_flight_mode===true);set('data',(s.data_type||'无')+' / '+(s.data_adapter??'--'));" )
DASHBOARD = replaceLiteral(DASHBOARD,
    "set('cellularFlightModeStatus',s.cellular_flight_mode===true?'已开启':'未开启');",
    "set('cellularFlightModeStatus',s.cellular_flight_mode===true?'已开启':'未开启');let systemMemory=$('mem2');if(systemMemory&&systemMemory.parentElement)systemMemory.parentElement.remove();")
DASHBOARD = replaceLiteral(DASHBOARD, "</style>",
    ".network-panel-heading{display:flex;align-items:flex-start;justify-content:space-between;gap:16px;margin-bottom:18px}.network-panel-copy{min-width:0}.network-panel-heading h2{margin:0 0 7px}.network-panel-heading .muted{line-height:1.5}.network-panel{display:block!important;min-width:0}.network-panel>.signal{display:block;min-width:0;margin:0 0 18px}.network-panel>.kv{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));min-width:0}.flight-mode-card-status{display:flex;align-items:center;gap:6px;flex:0 0 auto;white-space:nowrap;padding:6px 9px;border:1px solid #cbd5e1;border-radius:999px;background:#f8fafc;color:#64748b;font-size:12px}.flight-mode-card-status b{font-weight:700}.flight-mode-card-status.enabled{border-color:#93c5fd;background:#eff6ff;color:#1d4ed8}@media(max-width:600px){.network-panel-heading{gap:10px;margin-bottom:16px}.flight-mode-card-status{padding:5px 7px}.network-panel>.kv{grid-template-columns:1fr}}</style>")
DASHBOARD = replaceLiteral(DASHBOARD, "</style>",
    "@media(min-width:851px){html,body{height:100%;overflow:hidden}.app{height:100vh;min-height:0;overflow:hidden;grid-template-columns:245px minmax(0,1fr)}.side{height:100vh;overflow-y:auto;position:sticky;top:0}.app>section{height:100vh;min-width:0;overflow-y:auto;overflow-x:hidden}.top{position:sticky;top:0;z-index:10}.main{min-height:calc(100vh - 72px)}}.check{display:flex;grid-column:1/-1;flex-direction:row-reverse;justify-content:space-between;min-height:43px;padding:9px 11px;border:1px solid #cbd5e1;border-radius:8px}.check label{margin:0!important;cursor:pointer}.check input{width:18px;height:18px;margin:0;cursor:pointer}</style>")
DASHBOARD = replaceLiteral(DASHBOARD, "</style>",
    ".network-panel>.signal{padding:20px}.network-panel>.signal .label{display:inline-block;margin-bottom:10px}.network-panel>.signal .kv{margin-top:2px}.network-panel>.kv{gap:0 22px}</style>")
DASHBOARD = replaceLiteral(DASHBOARD, "class=\"field check\"",
    "class=\"field check wide\"")
DASHBOARD = replaceLiteral(DASHBOARD, "/webhook|url|api/.test(k)",
    "/webhook|url|api|key|secret/.test(k)")
DASHBOARD = replaceLiteral(DASHBOARD, "k!=='match'&&typeof v!=='object'",
    "k!=='match'&&k!=='type'&&typeof v!=='object'")
DASHBOARD = replaceLiteral(DASHBOARD, "k!=='match'&&k!=='type'&&typeof v!=='object'",
    "k!=='match'&&k!=='type'&&k!=='enabled'&&k!=='title_template'&&typeof v!=='object'")
DASHBOARD = replaceLiteral(DASHBOARD,
    "<option ${v==='all'?'selected':''}>all</option><option ${v==='verification'?'selected':''}>verification</option><option ${v==='off'?'selected':''}>off</option>",
    "<option value='all' ${v==='all'?'selected':''}>all</option><option value='verification' ${v==='verification'?'selected':''}>verification</option><option value='off' ${v==='off'?'selected':''}>off</option>")
DASHBOARD = replaceLiteral(DASHBOARD,
    ":`<div class=\"field ${/webhook|url|api|key|secret/.test(k)?'wide':''}\"><label>${esc(k)}</label><input data-k=\"${esc(k)}\" value=\"${esc(v)}\"></div>`",
    ":(k==='sms_template'||k==='call_template'||k==='system_template')?`<div class=\"field wide\"><label>${k==='sms_template'?'短信模版':k==='call_template'?'电话模版':'系统通知模版'}</label><textarea data-k=\"${esc(k)}\" rows=\"6\" placeholder=\"{sender} {content} {received_at}\">${esc(v)}</textarea><p class=\"help\">支持 {message_id}、{kind}、{sender}、{content}、{received_at}、{device_info}</p></div>`:(k==='sms_title_template'||k==='call_title_template'||k==='system_title_template')?`<div class=\"field wide\"><label>${k==='sms_title_template'?'短信标题模版':k==='call_title_template'?'电话标题模版':'系统通知标题模版'}</label><input data-k=\"${esc(k)}\" value=\"${esc(v)}\" placeholder=\"{sender}\"><p class=\"help\">支持 {message_id}、{kind}、{sender}、{content}、{received_at}、{device_info}</p></div>`:`<div class=\"field ${/webhook|url|api|key|secret/.test(k)?'wide':''}\"><label>${esc(k)}</label><input data-k=\"${esc(k)}\" value=\"${esc(v)}\"></div>`")
DASHBOARD = replaceLiteral(DASHBOARD,
    '<p class="help">支持 {message_id}、{kind}、{sender}、{content}、{received_at}、{device_info}</p>', '')
DASHBOARD = replaceLiteral(DASHBOARD,
    '<p class="help">支持 {message_id}、{kind}、{sender}、{content}、{received_at}、{device_info}</p>', '')
DASHBOARD = replaceLiteral(DASHBOARD,
    '<li>通知队列 <b id="snotify">--</b></li><li>Bark 渠道 <b id="sbark">--</b></li>',
    '<li>通知渠道 <b id="sbark">--</b></li>')
DASHBOARD = replaceLiteral(DASHBOARD,
    "set('snotify','队列 '+(s.notify?.queue_length??0));$('sbark').innerHTML=s.notify?.bark_enabled?'<span class=\"ok\">● 正常</span>':'已关闭'",
    "$('sbark').innerHTML=(s.notify?.enabled_channels??0)>0?'<span class=\"ok\">● 正常（'+(s.notify?.enabled_channels??0)+'个已启用）</span>':'未启用'")

DASHBOARD = replaceLiteral(DASHBOARD,
    "function set(x,v){$(x).textContent=v??'--'}",
    "function set(x,v){let e=$(x);if(e)e.textContent=v??'--'}function html(x,v){let e=$(x);if(e)e.innerHTML=v}function width(x,v){let e=$(x);if(e)e.style.width=v}")
DASHBOARD = replaceLiteral(DASHBOARD, "$('bar').style.width=", "width('bar',")
DASHBOARD = replaceLiteral(DASHBOARD, "+'%';set('sideip'", "+'%');set('sideip'")
DASHBOARD = replaceLiteral(DASHBOARD, "$('snet').innerHTML=", "html('snet',")
DASHBOARD = replaceLiteral(DASHBOARD, ":'离线';$('ssim').innerHTML=", ":'离线');html('ssim',")
DASHBOARD = replaceLiteral(DASHBOARD, ":'未就绪';$('sbark').innerHTML=", ":'未就绪');$('sbark').innerHTML=")
DASHBOARD = replaceLiteral(DASHBOARD, "$('sbark').innerHTML=", "html('sbark',")
DASHBOARD = replaceLiteral(DASHBOARD, ":'已关闭'}", ":'已关闭')}")
DASHBOARD = replaceLiteral(DASHBOARD, ":'未启用'}", ":'未启用')}")
DASHBOARD = replaceLiteral(DASHBOARD,
    ".grid{display:grid;grid-template-columns:2.2fr 1fr;gap:16px;margin-top:16px}",
    ".grid{display:grid;grid-template-columns:minmax(0,2.2fr) minmax(280px,1fr);gap:16px;margin-top:16px}")

local BASE_DASHBOARD = DASHBOARD
DASHBOARD = "" -- The burn build serves extensions separately; avoid assembling an unused full-page copy.

local CONTROL_EXTENSION = [=[<style>.channel-card{display:flex;align-items:center;gap:8px;border:1px solid transparent;border-radius:10px;margin:4px 0;padding:4px 10px 4px 4px}.channel-card:has(button.active){background:#eff6ff;border-color:#bfdbfe}.channel-card button{flex:1;margin:0}.switch{position:relative;display:inline-flex;width:40px;height:23px;flex:0 0 auto}.switch input{opacity:0;width:0;height:0}.switch i{position:absolute;inset:0;background:#dce2ea;border-radius:999px;cursor:pointer;transition:.18s}.switch i:before{content:"";position:absolute;width:17px;height:17px;left:3px;top:3px;background:#fff;border-radius:50%;box-shadow:0 1px 3px #0003;transition:.18s}.switch input:checked+i{background:#2563eb}.switch input:checked+i:before{transform:translateX(17px)}.settings-grid{max-width:760px}.help{color:#64748b;font-size:12px;margin:5px 0 0}.keyword-area{width:100%;min-height:220px;resize:vertical;border:1px solid #cbd5e1;border-radius:8px;padding:11px;font:inherit;line-height:1.65}.keyword-area:focus{outline:3px solid #bfdbfe;border-color:#2563eb}</style><script>(function(){const nav=document.querySelector('.nav'),main=document.querySelector('.main');nav.insertAdjacentHTML('beforeend','<button data-page="filters">关键词过滤</button><button data-page="settings">设备设置</button>');main.insertAdjacentHTML('beforeend','<section id="filters" class="page"><div class="hero"><div><h1>关键词过滤</h1><p>设置验证短信的正文关键词；每行一个，支持 Lua 模式语法。保存并重启后配置生效。</p></div><button class="btn" id="saveFilters">保存并重启</button></div><article class="panel settings-grid"><div class="field"><label for="filterChannel">配置渠道</label><select id="filterChannel"></select></div><div class="field" style="margin-top:16px"><label for="keywords">短信正文关键词</label><textarea class="keyword-area" id="keywords" placeholder="验证码&#10;取件码&#10;[Cc][Oo][Dd][Ee]"></textarea><p class="help">仅 sms_mode 为 verification 的渠道会按这些规则过滤；all 表示全部短信都发送。</p></div></article></section><section id="settings" class="page"><div class="hero"><div><h1>设备设置</h1><p>配置 Wi-Fi 连接与 SIM PIN。保存后设备会重启并重新联网。</p></div><button class="btn" id="saveSettings">保存并重启</button></div><article class="panel settings-grid"><div class="form"><div class="field check wide"><label for="wifiEnabled">启用 Wi-Fi</label><input id="wifiEnabled" type="checkbox"></div><div class="field wide"><label for="wifiSsid">Wi-Fi 名称（SSID）</label><input id="wifiSsid" autocomplete="username"></div><div class="field wide"><label for="wifiPassword">Wi-Fi 密码</label><input id="wifiPassword" type="password" autocomplete="current-password"></div><div class="field wide"><label for="pinCode">SIM PIN</label><input id="pinCode" inputmode="numeric" maxlength="8" autocomplete="off"><p class="help">未启用 PIN 的 SIM 卡请保持为空。</p></div></div></article></section>');let filterChannel='';function saveConfig(){return fetch('/api/config',{method:'PUT',headers:{'Content-Type':'application/json'},body:JSON.stringify(cfg)}).then(r=>{if(!r.ok)return r.text().then(t=>Promise.reject(Error(t)));note('已保存，设备正在重启…')}).catch(e=>note(e.message))}function title(k){return ({bark:'Bark',archive:'钉钉',feishu:'飞书',webhook:'Webhook'})[k]||k}function show(name){document.querySelectorAll('.page').forEach(x=>x.classList.toggle('active',x.id===name));document.querySelectorAll('.nav button').forEach(x=>x.classList.toggle('active',x.dataset.page===name));set('crumb','控制中心 / '+(name==='filters'?'关键词过滤':'设备设置'));loadCfg().then(()=>name==='filters'?renderFilters():renderSettings()).catch(e=>note(e.message))}nav.querySelectorAll('button[data-page="filters"],button[data-page="settings"]').forEach(b=>b.onclick=()=>show(b.dataset.page));channels=function(){let list=$('channelList'),items=Object.keys(cfg.CHANNELS||{});if(!items.length){list.textContent='尚未配置渠道';return}if(!items.includes(active))active=items[0];list.innerHTML=items.map(k=>{let c=cfg.CHANNELS[k];return `<div class="channel-card"><button class="${k===active?'active':''}" data-choose="${esc(k)}"><b>${title(k)}</b><small>${esc(c.type||'custom')} · ${c.enabled?'已启用':'未启用'}</small></button><label class="switch" title="启用/停用 ${title(k)}"><input data-toggle="${esc(k)}" type="checkbox" ${c.enabled?'checked':''}><i></i></label></div>`}).join('');list.querySelectorAll('[data-choose]').forEach(b=>b.onclick=()=>{active=b.dataset.choose;channels()});list.querySelectorAll('[data-toggle]').forEach(x=>x.onchange=()=>{cfg.CHANNELS[x.dataset.toggle].enabled=x.checked;channels()});form()};function renderFilters(){let names=Object.keys(cfg.CHANNELS||{});if(!names.length)return;if(!names.includes(filterChannel))filterChannel=names[0];let select=$('filterChannel');select.innerHTML=names.map(k=>`<option value="${esc(k)}" ${k===filterChannel?'selected':''}>${title(k)}</option>`).join('');let c=cfg.CHANNELS[filterChannel];let match=c.match||{mode:'any',content_patterns:[],sender_patterns:[]};c.match=match;$('keywords').value=(match.content_patterns||[]).join('\n');select.onchange=()=>{filterChannel=select.value;renderFilters()};$('keywords').oninput=()=>{match.content_patterns=$('keywords').value.split(/\r?\n/).map(x=>x.trim()).filter(Boolean)}}function renderSettings(){let net=cfg.NETWORK||(cfg.NETWORK={}),wifi=net.wifi||(net.wifi={});$('wifiEnabled').checked=wifi.enabled!==false;$('wifiSsid').value=wifi.ssid||'';$('wifiPassword').value=wifi.password||'';$('pinCode').value=cfg.PIN_CODE||'';$('wifiEnabled').onchange=()=>wifi.enabled=$('wifiEnabled').checked;$('wifiSsid').oninput=()=>wifi.ssid=$('wifiSsid').value;$('wifiPassword').oninput=()=>wifi.password=$('wifiPassword').value;$('pinCode').oninput=()=>cfg.PIN_CODE=$('pinCode').value}$('save').onclick=saveConfig;$('saveFilters').onclick=saveConfig;$('saveSettings').onclick=saveConfig})()</script>]=]

CONTROL_EXTENSION = replaceLiteral(CONTROL_EXTENSION,
    "loadCfg().then(()=>name==='filters'?renderFilters():renderSettings())",
    "loadCfg().then(()=>name==='filters'?window.renderFilters():window.renderSettings())")
CONTROL_EXTENSION = CONTROL_EXTENSION:gsub(
    '(<button class="btn" id="saveFilters">)[^<]*(</button>)',
    "%1保存并生效%2")
CONTROL_EXTENSION = CONTROL_EXTENSION:gsub("note%('[^']*'%)", "note('配置已保存')", 1)
CONTROL_EXTENSION = replaceLiteral(CONTROL_EXTENSION,
    '<button class="btn" id="saveSettings">保存并重启</button>',
    '<div><button class="btn" id="saveSettings">保存配置</button><button class="btn" id="restartSettings" style="margin-left:8px">立即重启</button></div>')
CONTROL_EXTENSION = replaceLiteral(CONTROL_EXTENSION,
    "$('saveSettings').onclick=saveConfig})()",
    "$('saveSettings').onclick=saveConfig;$('restartSettings').onclick=restart})()")

local SETTINGS_EXTENSION = [=[<style>.settings-stack{max-width:760px;display:grid;gap:16px}.settings-block{border:1px solid #e2e8f0;border-radius:12px;padding:20px}.settings-block h2{font-size:16px;margin:0 0 5px}.settings-block>p{color:#64748b;margin:0 0 17px}.settings-block.pin{border-color:#fde68a;background:#fffbeb}.settings-block.pin h2{color:#92400e}</style><script>(function(){renderSettings=function(){let net=cfg.NETWORK||(cfg.NETWORK={}),wifi=net.wifi||(net.wifi={}),panel=document.querySelector('#settings .settings-grid');document.querySelector('#settings .hero p').textContent='Wi-Fi 与 SIM PIN 分开设置；保存后设备会重启。';panel.className='settings-stack';panel.innerHTML='<section class="settings-block"><h2>Wi-Fi 连接设置</h2><p>修改后设备会重新连接指定的 2.4 GHz Wi-Fi，局域网 IP 可能改变。</p><div class="form"><div class="field check wide"><label for="wifiEnabled">启用 Wi-Fi</label><input id="wifiEnabled" type="checkbox"></div><div class="field wide"><label for="wifiSsid">Wi-Fi 名称（SSID）</label><input id="wifiSsid" autocomplete="username"></div><div class="field wide"><label for="wifiPassword">Wi-Fi 密码</label><input id="wifiPassword" type="password" autocomplete="current-password"></div></div></section><section class="settings-block pin"><h2>SIM PIN 设置</h2><p>仅当 SIM 卡已启用 PIN 验证时填写；填写错误可能导致 SIM 被锁定。</p><div class="field"><label for="pinCode">SIM PIN</label><input id="pinCode" inputmode="numeric" maxlength="8" autocomplete="off"></div></section>';$('wifiEnabled').checked=wifi.enabled!==false;$('wifiSsid').value=wifi.ssid||'';$('wifiPassword').value=wifi.password||'';$('pinCode').value=cfg.PIN_CODE||'';$('wifiEnabled').onchange=()=>wifi.enabled=$('wifiEnabled').checked;$('wifiSsid').oninput=()=>wifi.ssid=$('wifiSsid').value;$('wifiPassword').oninput=()=>wifi.password=$('wifiPassword').value;$('pinCode').oninput=()=>cfg.PIN_CODE=$('pinCode').value}})()</script>]=]

SETTINGS_EXTENSION = replaceLiteral(SETTINGS_EXTENSION,
    "$('pinCode').value=cfg.PIN_CODE||'';",
    "$('pinCode').value=cfg.PIN_CODE||'';$('localNumber').value=cfg.FALLBACK_LOCAL_NUMBER||'';")
SETTINGS_EXTENSION = replaceLiteral(SETTINGS_EXTENSION,
    "$('pinCode').oninput=()=>cfg.PIN_CODE=$('pinCode').value",
    "$('pinCode').oninput=()=>cfg.PIN_CODE=$('pinCode').value;$('localNumber').oninput=()=>cfg.FALLBACK_LOCAL_NUMBER=$('localNumber').value")
SETTINGS_EXTENSION = replaceLiteral(SETTINGS_EXTENSION,
    '<div class="field"><label for="pinCode">SIM PIN</label><input id="pinCode" inputmode="numeric" maxlength="8" autocomplete="off"></div></section>',
    '<div class="field"><label for="pinCode">SIM PIN</label><input id="pinCode" inputmode="numeric" maxlength="8" autocomplete="off"></div><div class="field" style="margin-top:16px"><label for="localNumber">本机号码</label><input id="localNumber" inputmode="tel" autocomplete="tel"><p class="help">设备无法从 SIM 读取号码时使用此号码。</p></div></section>')
SETTINGS_EXTENSION = replaceLiteral(SETTINGS_EXTENSION,
    "document.querySelector('#settings .settings-grid')",
    "document.querySelector('#settings .settings-grid, #settings .settings-stack')")
local SETTINGS_LAYOUT_EXTENSION = [=[<style>.settings-stack{max-width:760px;display:grid;gap:10px}.settings-block{background:#fff;border:1px solid #e2e8f0;border-radius:12px;padding:20px;box-shadow:0 8px 20px rgba(15,23,42,.04)}.settings-block h2{font-size:16px;margin:0 0 5px}.settings-block>p{color:#64748b;margin:0 0 17px}.settings-block.pin{border-color:#fde68a;background:#fffbeb}.settings-block.pin h2{color:#92400e}</style>]=]


local TEST_EXTENSION = [=[<style>.test-action{display:flex;align-items:center;gap:10px;margin:12px 0 4px}.test-result{color:#64748b;font-size:12px}.test-result.success{color:#059669}.test-result.failed{color:#dc2626}</style><script>(function(){const drawForm=form;form=function(){drawForm();let old=$('channelTestAction');if(old)old.remove();$('channelHint').insertAdjacentHTML('afterend','<div class="test-action" id="channelTestAction"></div>')}})()</script>]=]




local FILTER_LAYOUT_EXTENSION = [=[<script>(function(){let priorLoadCfg=loadCfg;function renderGlobalFilter(){let page=$('filters'),panel=document.querySelector('#filters .settings-grid');if(!page||!page.classList.contains('active')||!panel)return;let filter=cfg.KEYWORD_FILTER||(cfg.KEYWORD_FILTER={mode:'any',content_patterns:[],sender_patterns:[]});page.querySelector('.hero p').textContent='设置设备的全局短信关键词；每行一个，支持 Lua 模式语法。保存并重启后配置生效。';panel.innerHTML='<select id="filterChannel" hidden aria-hidden="true"></select><div class="field"><label for="keywords">短信正文关键词</label><textarea class="keyword-area" id="keywords" placeholder="验证码&#10;取件码&#10;[Cc][Oo][Dd][Ee]"></textarea><p class="help">通知渠道中选择“仅匹配关键词”时，才会使用这份全局关键词；“全部短信”不会过滤。</p></div>';$('keywords').value=(filter.content_patterns||[]).join('\n');$('keywords').oninput=()=>{filter.content_patterns=$('keywords').value.split(/\r?\n/).map(x=>x.trim()).filter(Boolean)}}renderFilters=renderGlobalFilter;loadCfg=async function(){let value=await priorLoadCfg();if($('filters')&&$('filters').classList.contains('active')){renderGlobalFilter();setTimeout(renderGlobalFilter,0)}return value}})()</script>]=]

local CHANNEL_LAYOUT_EXTENSION = [=[<style>.channel-form-cards{display:grid;gap:10px;max-width:760px}.channel-form-card{background:#f8fafc;border:1px solid #dbe3ef;border-radius:12px;padding:18px}.channel-form-card h3{font-size:16px;margin:0 0 5px}.channel-form-card>p{color:#64748b;margin:0 0 16px}.channel-form-card .form{margin:0}.channel-form-card.policy{background:#f8fbff;border-color:#bfdbfe}.channel-form-card.message{background:#fffdf5;border-color:#f6d98b}.channel-form-card.message .help{margin-top:6px}</style><script>(function(){let drawChannelForm=form;form=function(){drawChannelForm();let root=$('form');if(!root)return;let fields=Array.from(root.children).filter(x=>x.classList&&x.classList.contains('field')),policyKeys={sms_mode:true,system_enabled:true,call_enabled:true},messageKeys={sms_template:true,call_template:true,system_template:true},labels={api:'Bark 服务地址',key:'Bark Key',group:'消息分组',webhook:'Webhook 地址',url:'Webhook 地址',secret:'签名密钥',require_signature:'启用签名',sms_mode:'短信转发范围',system_enabled:'接收系统通知',call_enabled:'接收通话通知'};root.className='channel-form-cards';root.innerHTML='<section class="channel-form-card"><h3>渠道配置信息</h3><p>设置推送地址、密钥和分组等连接参数。</p><div class="form" id="channelConnectionFields"></div></section><section class="channel-form-card policy"><h3>短信与通知规则</h3><p>选择转发哪些短信，以及是否使用全局关键词过滤。</p><div class="form" id="channelPolicyFields"></div></section><section class="channel-form-card message"><h3>消息格式管理</h3><p>分别设置短信、通话和系统通知在本渠道中的显示格式。</p><div class="form" id="channelMessageFields"></div></section>';let connection=$('channelConnectionFields'),policy=$('channelPolicyFields'),message=$('channelMessageFields');fields.forEach(field=>{let input=field.querySelector('[data-k]'),key=input&&input.dataset.k,label=field.querySelector('label');if(label&&labels[key])label.textContent=labels[key];(policyKeys[key]?policy:messageKeys[key]?message:connection).appendChild(field)});if(!connection.children.length)connection.innerHTML='<p class="muted">此渠道没有额外连接参数。</p>';if(!message.children.length)message.innerHTML='<p class="muted">此渠道没有消息格式配置。</p>';let test=$('channelTestAction');if(test)connection.appendChild(test)}})()</script>]=]
CHANNEL_LAYOUT_EXTENSION = replaceLiteral(CHANNEL_LAYOUT_EXTENSION,
    ".channel-form-card.message .help{margin-top:6px}",
    ".channel-form-card.message .message-section{padding-top:4px}.channel-form-card.message .message-section+h4{margin-top:14px}.channel-form-card.message h4{font-size:13px;color:#475569;margin:0 0 10px}.channel-form-card.message textarea{width:100%;min-height:132px;resize:vertical;border:1px solid #cbd5e1;border-radius:8px;padding:10px;font:inherit;line-height:1.5;white-space:pre-wrap;overflow-wrap:anywhere}.channel-form-card.message .help{margin-top:6px}")
CHANNEL_LAYOUT_EXTENSION = replaceLiteral(CHANNEL_LAYOUT_EXTENSION,
    "messageKeys={sms_template:true,call_template:true,system_template:true}",
    "messageKeys={sms_template:true,call_template:true,system_template:true,sms_title_template:true,call_title_template:true,system_title_template:true}")
CHANNEL_LAYOUT_EXTENSION = replaceLiteral(CHANNEL_LAYOUT_EXTENSION,
    '<div class="form" id="channelMessageFields"></div></section>',
    '<div class="form" id="channelMessageFields"></div><p class="help message-template-help">支持 {message_id}、{kind}、{sender}、{content}、{call_status}、{received_at}、{device_info}</p></section>')
CHANNEL_LAYOUT_EXTENSION = replaceLiteral(CHANNEL_LAYOUT_EXTENSION,
    "});if(!connection.children.length)",
    "});['sms_title_template','sms_template','call_title_template','call_template','system_title_template','system_template'].forEach(key=>{let field=fields.find(x=>x.querySelector('[data-k='+key+']'));if(field)message.appendChild(field)});if(!connection.children.length)")

local SIGNAL_REFERENCE_EXTENSION = [=[<style>.signal-reference{margin-top:16px}.signal-reference h2{margin-bottom:6px}.signal-reference>p{color:#64748b;margin:0}.signal-table-wrap{overflow-x:auto;margin-top:16px}.signal-reference table{width:100%;min-width:720px;border-collapse:separate;border-spacing:0;border:1px solid #e2e8f0;border-radius:10px;overflow:hidden}.signal-reference th,.signal-reference td{padding:12px 14px;text-align:left;border-bottom:1px solid #e2e8f0;vertical-align:top}.signal-reference th{background:#f8fafc;color:#475569;font-size:12px}.signal-reference tr:last-child td{border-bottom:0}.signal-reference td:first-child{font-weight:700;color:#172033;white-space:nowrap}.signal-reference .excellent{color:#047857;font-weight:700}.signal-reference .good{color:#1d4ed8;font-weight:700}.signal-reference .poor{color:#b45309;font-weight:700}.signal-reference-note{font-size:12px;margin-top:12px!important}@media(max-width:620px){.signal-reference th,.signal-reference td{padding:10px 12px}.signal-table-wrap{margin-left:-4px;margin-right:-4px;padding:0 4px}}</style><script>(function(){let overview=$('overview');if(!overview)return;overview.insertAdjacentHTML('beforeend','<article class="panel signal-reference"><h2>信号指标说明</h2><p>以下为日常部署的经验区间，用于快速判断链路状态；实际网速还会受频段、干扰、基站负载和环境影响。</p><div class="signal-table-wrap"><table><thead><tr><th>指标</th><th>含义与方向</th><th>优秀</th><th>良好</th><th>差</th></tr></thead><tbody><tr><td>Wi-Fi RSSI<br><small>dBm</small></td><td>Wi-Fi 接收信号强度；数值越接近 0，信号越强。</td><td class="excellent">≥ -60</td><td class="good">-60 ～ -75</td><td class="poor">&lt; -75</td></tr><tr><td>RSRP<br><small>dBm</small></td><td>4G/LTE 参考信号接收功率，反映蜂窝信号强度；越接近 0 越强。</td><td class="excellent">≥ -85</td><td class="good">-85 ～ -100</td><td class="poor">&lt; -100</td></tr><tr><td>RSRQ<br><small>dB</small></td><td>4G/LTE 参考信号质量，能反映干扰和小区负载；越接近 0 越好。</td><td class="excellent">≥ -10</td><td class="good">-10 ～ -15</td><td class="poor">&lt; -15</td></tr><tr><td>SNR<br><small>dB</small></td><td>信号与噪声的比值，反映信号“干净”程度；数值越高越好。</td><td class="excellent">≥ 20</td><td class="good">5 ～ 20</td><td class="poor">&lt; 5</td></tr></tbody></table></div><p class="signal-reference-note">提示：RSSI / RSRP / RSRQ 为负值时，不是绝对值越大越好，而是越接近 0 越好；SNR 则相反，越高越好。</p></article>')})()</script>]=]

local TEST_MODE_EXTENSION = [=[<style>.test-action.test-modes{display:flex;align-items:flex-start;justify-content:space-between;gap:12px;flex-wrap:wrap;margin:16px 0 0;padding:12px;background:#fff;border:1px solid #dbeafe;border-radius:10px}.test-mode-copy{display:grid;gap:3px}.test-mode-copy b{font-size:13px}.test-mode-copy span{color:#64748b;font-size:12px}.test-mode-buttons{display:flex;gap:8px;flex-wrap:wrap}.test-mode-button{border:1px solid #2563eb;background:#2563eb;color:#fff;border-radius:8px;padding:8px 11px;font:inherit;font-weight:650;cursor:pointer}.test-mode-button:disabled{opacity:.6;cursor:wait}.test-modes .test-result{width:100%;margin:0}</style><script>(function(){let previousForm=form;function currentChannel(){return typeof active!=='undefined'&&active?active:(typeof activeChannel!=='undefined'?activeChannel:'')}function syncCurrent(channel){let draft=cfg.CHANNELS&&cfg.CHANNELS[channel];if(!draft)return null;document.querySelectorAll('#form [data-k]').forEach(input=>{draft[input.dataset.k]=input.type==='checkbox'?input.checked:input.value});return draft}function validationError(item){let required={bark:[['api','Bark 服务地址'],['key','Bark Key']],dingtalk:[['webhook','Webhook 地址']],feishu:[['webhook','Webhook 地址']],webhook:[['url','Webhook 地址']]}[item.type]||[];if(item.type==='dingtalk'&&item.require_signature===true)required.push(['secret','签名密钥']);for(let [key,label] of required)if(String(item[key]??'').trim()==='')return '请填写'+label;return ''}function renderResult(text,kind){let result=$('testResult');if(!result)return;result.textContent=text;result.className='test-result '+(kind||'')}form=function(){previousForm();let action=$('channelTestAction');if(!action)return;action.className='test-action test-modes';action.innerHTML='<div class="test-mode-copy"><b>渠道连通性测试</b><span>校验并保存当前配置后发送测试。</span></div><div class="test-mode-buttons"><button class="test-mode-button" id="testChannel" type="button">渠道测试</button></div><span class="test-result" id="testResult"></span>';let button=$('testChannel');button.onclick=async()=>{let channel=currentChannel(),item=syncCurrent(channel),error=item&&validationError(item);if(!channel||!item){renderResult('请选择通知渠道','failed');return}if(error){renderResult(error,'failed');return}button.disabled=true;renderResult('正在校验并保存配置…');try{let response=await fetch('/api/channels/test',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({channel:channel,config:cfg})}),value=await response.json();if(!value.ok){renderResult(value.detail||'配置保存失败','failed');button.disabled=false;return}renderResult('配置已保存，已加入测试队列…');let attempts=0,poll=async()=>{try{let result=await fetch('/api/channels/test/'+encodeURIComponent(channel)),state=await result.json();if(state.state==='success'){renderResult('渠道测试成功，设备已发送。','success');button.disabled=false;return}if(state.state==='failed'){renderResult('渠道测试失败：'+(state.detail||'发送失败'),'failed');button.disabled=false;return}renderResult(state.state==='retrying'?'发送失败，设备正在重试…':'配置已保存，已加入测试队列…');if(attempts++<20)setTimeout(poll,2000);else{renderResult('等待设备发送结果，请稍后再次查看');button.disabled=false}}catch(e){renderResult('读取设备测试状态失败','failed');button.disabled=false}};setTimeout(poll,700)}catch(e){renderResult('渠道测试请求失败','failed');button.disabled=false}}}})()</script>]=]


local CHANNEL_TYPE_LAYOUT_EXTENSION = [=[<style>.channel-card-head{display:flex;align-items:flex-start;justify-content:space-between;gap:16px;margin-bottom:16px}.channel-card-head h3{margin:0 0 5px}.channel-card-head p{margin:0;color:#64748b}.channel-card-head .test-modes{margin:0;padding:0;border:0;background:transparent;display:block}.channel-card-head .test-mode-copy{display:none}.channel-card-head .test-mode-buttons{justify-content:flex-end}.channel-card-head .test-result{display:block;width:auto;max-width:300px;margin-top:6px;white-space:normal}.bark-config .form{grid-template-columns:repeat(3,minmax(0,1fr))}.bark-config .field{grid-column:auto!important}.dingtalk-config .sign-option{grid-column:1/-1!important;margin-top:4px}@media(max-width:700px){.channel-card-head{flex-direction:column}.channel-card-head .test-mode-buttons{justify-content:flex-start}.bark-config .form{grid-template-columns:1fr}.test-mode-button{min-height:44px}}</style><script>(function(){let renderChannelDetails=form;function currentChannel(){return typeof active!=='undefined'&&active?active:(typeof activeChannel!=='undefined'?activeChannel:'')}function fieldFor(container,key){let input=container&&container.querySelector('[data-k="'+key+'"]');return input&&input.closest('.field')}form=function(){renderChannelDetails();let root=$('form'),channel=currentChannel(),item=cfg.CHANNELS&&cfg.CHANNELS[channel];if(!root||!item)return;let configCard=root.querySelector('.channel-form-card'),connection=$('channelConnectionFields');if(!configCard||!connection)return;let title=configCard.querySelector('h3'),description=configCard.querySelector('p'),head=document.createElement('div'),copy=document.createElement('div');head.className='channel-card-head';copy.className='channel-card-copy';if(title)copy.appendChild(title);if(description)copy.appendChild(description);head.appendChild(copy);let action=$('channelTestAction');if(action)head.appendChild(action);configCard.insertBefore(head,connection);let names={bark:'Bark',dingtalk:'钉钉',feishu:'飞书',webhook:'Webhook'},display=names[item.type];if(display){$('channelTitle').textContent=display;$('channelHint').textContent=display+' 通知渠道'}if(item.type==='bark'){configCard.classList.add('bark-config');['api','key','group'].forEach(key=>{let field=fieldFor(connection,key);if(field)connection.appendChild(field)})}if(item.type==='dingtalk'){configCard.classList.add('dingtalk-config');let signing=fieldFor(connection,'require_signature');if(signing){signing.classList.add('sign-option');connection.appendChild(signing)}}}})()</script>]=]

CHANNEL_TYPE_LAYOUT_EXTENSION = replaceLiteral(CHANNEL_TYPE_LAYOUT_EXTENSION,
    ".channel-card-head .test-result{display:block;width:auto;max-width:300px;margin-top:6px;white-space:normal}.bark-config",
    ".channel-card-head .test-result{display:block;width:auto;max-width:300px;margin-top:6px;white-space:normal}.channel-head-actions{display:flex;align-items:flex-start;justify-content:flex-end;gap:12px;margin-left:auto}.channel-doc{color:#2563eb;font-size:12px;font-weight:650;text-decoration:none;white-space:nowrap;padding-top:5px}.channel-doc:hover{text-decoration:underline}.bark-config")
CHANNEL_TYPE_LAYOUT_EXTENSION = replaceLiteral(CHANNEL_TYPE_LAYOUT_EXTENSION,
    "head.appendChild(copy);let action=$('channelTestAction');if(action)head.appendChild(action);",
    [=[head.appendChild(copy);let action=$('channelTestAction'),actions=document.createElement('div'),doc=document.createElement('a');actions.className='channel-head-actions';doc.className='channel-doc';doc.textContent='配置文档';doc.target='_blank';doc.rel='noopener noreferrer';let docs={dingtalk:'https://open.dingtalk.com/document/robots/custom-robot-access',bark:'https://bark.day.app/#/tutorial',feishu:'https://www.feishu.cn/hc/zh-CN/articles/360024984973-在群组中使用机器人'};if(docs[item.type]){doc.href=docs[item.type];actions.appendChild(doc)}if(action)actions.appendChild(action);if(actions.children.length)head.appendChild(actions);]=])
CHANNEL_TYPE_LAYOUT_EXTENSION = CHANNEL_TYPE_LAYOUT_EXTENSION:gsub(
    "https://www%.feishu%.cn/hc/zh%-CN/articles/360024984973%-[^']*",
    "https://open.feishu.cn/document/client-docs/bot-v3/add-custom-bot?lang=zh-CN")
CHANNEL_TYPE_LAYOUT_EXTENSION = replaceLiteral(CHANNEL_TYPE_LAYOUT_EXTENSION,
    ".dingtalk-config .sign-option{grid-column:1/-1!important;margin-top:4px}",
    ".dingtalk-config .sign-option,.feishu-config .sign-option{grid-column:1/-1!important;margin-top:4px}")
CONTROL_EXTENSION = replaceLiteral(CONTROL_EXTENSION,
    "bark:'Bark',archive:'钉钉',feishu:'飞书',webhook:'Webhook'",
    "bark:'Bark',dingtalk:'钉钉',archive:'钉钉',feishu:'飞书',webhook:'Webhook'")
CHANNEL_TYPE_LAYOUT_EXTENSION = replaceLiteral(CHANNEL_TYPE_LAYOUT_EXTENSION,
    "if(item.type==='dingtalk'){configCard.classList.add('dingtalk-config');let signing=fieldFor(connection,'require_signature');if(signing){signing.classList.add('sign-option');connection.appendChild(signing)}}",
    "if(item.type==='dingtalk'||item.type==='feishu'){configCard.classList.add(item.type+'-config');['webhook','secret','require_signature'].forEach(key=>{let field=fieldFor(connection,key);if(field)connection.appendChild(field)});let signing=fieldFor(connection,'require_signature');if(signing)signing.classList.add('sign-option')}")
local CHANNEL_LIST_LABEL_EXTENSION = [=[<script>(function(){let renderChannelListLabels=form;form=function(){renderChannelListLabels();document.querySelectorAll('#channelList button').forEach(button=>{if(button.dataset.k==='dingtalk'){let title=button.querySelector('b');if(title)title.textContent='\u9489\u9489'}})}})()</script>]=]

local CHANNEL_POLICY_HELP_EXTENSION = [=[<script>(function(){let renderChannelPolicy=form;form=function(){renderChannelPolicy();let hint=$('channelHint');if(hint)hint.style.display='none';let help={system_enabled:'开启后，此渠道会接收设备启动、短信服务就绪、健康状态和网页测试等系统事件；关闭后仅接收符合短信规则的短信。',call_enabled:'开启后，此渠道会接收来电和通话事件通知；关闭后不推送任何通话事件。'};Object.keys(help).forEach(key=>{let input=document.querySelector('#channelPolicyFields [data-k="'+key+'"]'),field=input&&input.closest('.field');if(field&&!field.querySelector('.help'))field.insertAdjacentHTML('beforeend','<p class="help">'+help[key]+'</p>')})}})()</script>]=]

local TEMPLATE_RESET_EXTENSION = [=[<style>.template-card-head{display:flex;align-items:flex-start;justify-content:space-between;gap:14px}.template-card-head h3{margin:0}.template-reset{border:1px solid #cbd5e1;background:#fff;color:#334155;border-radius:8px;padding:8px 11px;font:inherit;font-weight:650;cursor:pointer;white-space:nowrap}.template-reset:hover{background:#f8fafc;border-color:#94a3b8}.template-reset:disabled{opacity:.6;cursor:wait}</style><script>(function(){let renderTemplateFields=form,defaults;async function getDefaults(){if(defaults)return defaults;let response=await fetch('/api/config/default-templates');if(!response.ok)throw Error('无法读取默认模板');defaults=await response.json();return defaults}form=function(){renderTemplateFields();let fields=$('channelMessageFields'),channel=typeof active!=='undefined'?active:'',item=cfg.CHANNELS&&cfg.CHANNELS[channel];if(!fields||!item||$('resetTemplates'))return;let card=fields.closest('.channel-form-card'),heading=card&&card.querySelector('h3');if(!card||!heading)return;let head=document.createElement('div');head.className='template-card-head';heading.parentNode.insertBefore(head,heading);head.appendChild(heading);head.insertAdjacentHTML('beforeend','<button class="template-reset" id="resetTemplates" type="button">恢复默认模板</button>');let button=$('resetTemplates');button.onclick=async()=>{button.disabled=true;try{let values=(await getDefaults())[item.type];if(!values)throw Error('该渠道没有默认模板');Object.keys(values).forEach(key=>item[key]=values[key]);form();note('已恢复默认模板，请点击“保存配置”生效')}catch(e){note(e.message);button.disabled=false}}}})()</script>]=]


local SMS_CENTER_EXTENSION = [=[<style>.sms-feed{display:grid;gap:12px}.sms-row{border:1px solid #e2e8f0;border-radius:12px;padding:13px 15px}.sms-row.outgoing{background:#eff6ff;border-color:#bfdbfe}.sms-meta{display:flex;justify-content:space-between;color:#64748b;font-size:12px}.sms-meta b{color:#172033}.sms-text{white-space:pre-wrap;word-break:break-word;margin-top:8px;line-height:1.6}.sms-empty{color:#64748b;text-align:center;padding:60px 20px}.sms-mask{position:fixed;inset:0;background:#0f172a99;display:none;align-items:center;justify-content:center;padding:20px;z-index:20}.sms-mask.open{display:flex}.sms-dialog{width:min(100%,540px);background:#fff;border-radius:16px;padding:24px;box-shadow:0 20px 60px #0f172a33}.sms-dialog-head{display:flex;justify-content:space-between}.sms-dialog h2{margin:0 0 6px}.sms-dialog p{color:#64748b;margin:0 0 18px}.sms-dialog .field{margin-top:14px}.sms-dialog textarea{min-height:140px}.sms-close{border:0;background:transparent;font-size:24px;cursor:pointer}.sms-error{color:#b4233e;background:#fff1f2;border:1px solid #fecdd3;padding:9px;border-radius:8px;margin-top:12px}.sms-actions{display:flex;justify-content:flex-end;gap:10px;margin-top:18px}.sms-cancel{border:1px solid #cbd5e1;background:#fff;border-radius:9px;padding:10px 15px;cursor:pointer}</style><script>(function(){const nav=document.querySelector('.nav'),main=document.querySelector('.main'),old=nav.querySelector('button[data-page="history"]'),oldPage=document.querySelector('#history');if(old)old.remove();if(oldPage)oldPage.remove();nav.insertAdjacentHTML('beforeend','<button data-page="sms">短信中心</button><button data-page="calls">通话记录</button>');main.insertAdjacentHTML('beforeend','<section id="sms" class="page"><div class="hero"><div><h1>短信中心</h1><p>查看收发短信并手动发送新短信。</p></div><button class="button btn" id="newSms">＋ 新建短信</button></div><article class="panel"><div class="sms-feed" id="smsFeed"></div></article></section><section id="calls" class="page"><div class="hero"><div><h1>通话记录</h1><p>设备本地保留最近 100 条通话事件。</p></div><button class="button btn" id="refreshCalls">刷新记录</button></div><article class="panel"><div id="callFeed"></div></article></section><div class="sms-mask" id="smsMask"><div class="sms-dialog" role="dialog" aria-modal="true" aria-labelledby="smsTitle"><div class="sms-dialog-head"><div><h2 id="smsTitle">新建短信</h2><p>输入目标号码和短信内容。</p></div><button class="sms-close" id="closeSms" aria-label="关闭">×</button></div><div class="field"><label for="smsNumber">目标手机号</label><input id="smsNumber" type="tel" inputmode="tel" autocomplete="tel" placeholder="请输入手机号"></div><div class="field"><label for="smsText">短信内容</label><textarea id="smsText" maxlength="1000" placeholder="请输入短信内容"></textarea></div><div class="sms-error" id="smsError" hidden></div><div class="sms-actions"><button class="sms-cancel" id="cancelSms">取消</button><button class="button btn" id="sendSms">发送短信</button></div></div></div>');const tip=typeof toast==='function'?toast:note;function smsRows(a){if(!a.length)return '<div class="sms-empty">暂无短信记录</div>';return a.map(x=>{const out=x.direction==='outgoing';return '<article class="sms-row '+(out?'outgoing':'')+'"><div class="sms-meta"><b>'+(out?'发送至 ':'来自 ')+esc(x.sender||'未知号码')+'</b><span>'+esc(x.received_at||'--')+'</span></div><div class="sms-text">'+esc(x.content||'')+'</div></article>'}).join('')}function callRows(a){if(!a.length)return '<p class="history-empty">暂无记录</p>';return '<table class="history-table"><thead><tr><th>时间</th><th>手机号码</th><th>事件</th></tr></thead><tbody>'+a.map(x=>'<tr><td>'+esc(x.received_at||'--')+'</td><td>'+esc(x.number||'未知')+'</td><td>'+esc(x.call_state||'未知')+'</td></tr>').join('')+'</tbody></table>'}async function load(){try{const r=await fetch('/api/history');if(!r.ok)throw Error('无法读取历史记录');const v=await r.json();$('smsFeed').innerHTML=smsRows(v.sms||[]);$('callFeed').innerHTML=callRows(v.calls||[])}catch(e){tip(e.message)}}function show(id,title){document.querySelectorAll('.page').forEach(x=>x.classList.toggle('active',x.id===id));nav.querySelectorAll('button').forEach(x=>x.classList.toggle('active',x.dataset.page===id));if($('crumb'))$('crumb').textContent='控制中心 / '+title;load()}function close(){ $('smsMask').classList.remove('open')}nav.querySelector('[data-page="sms"]').onclick=()=>show('sms','短信中心');nav.querySelector('[data-page="calls"]').onclick=()=>show('calls','通话记录');$('newSms').onclick=()=>$('smsMask').classList.add('open');$('closeSms').onclick=close;$('cancelSms').onclick=close;$('refreshCalls').onclick=load;$('sendSms').onclick=async()=>{const e=$('smsError'),b=$('sendSms'),number=$('smsNumber').value.trim(),content=$('smsText').value.trim();if(!number||!content){e.textContent='请填写目标手机号和短信内容。';e.hidden=false;return}b.disabled=true;e.hidden=true;try{const r=await fetch('/api/sms/send',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({number,content})}),v=await r.json();if(!r.ok||!v.ok)throw Error(v.detail||'短信发送失败');close();$('smsNumber').value='';$('smsText').value='';tip('短信已发送');load()}catch(x){e.textContent=x.message;e.hidden=false}finally{b.disabled=false}}})()</script>]=]

SMS_CENTER_EXTENSION = replaceLiteral(SMS_CENTER_EXTENSION, "$('smsFeed').innerHTML=smsRows(v.sms||[]);$('callFeed').innerHTML=callRows(v.calls||[])", "let smsFeed=$('smsFeed'),callFeed=$('callFeed');if(smsFeed)smsFeed.innerHTML=smsRows(v.sms||[]);if(callFeed)callFeed.innerHTML=callRows(v.calls||[])")
SMS_CENTER_EXTENSION = replaceLiteral(SMS_CENTER_EXTENSION, ".sms-dialog textarea{min-height:140px}", ".sms-dialog textarea{width:100%;min-height:140px;resize:vertical;line-height:1.5}")
SMS_CENTER_EXTENSION = replaceLiteral(SMS_CENTER_EXTENSION, "</style>", ".history-table th{text-align:left}</style>")
SMS_CENTER_EXTENSION = replaceLiteral(SMS_CENTER_EXTENSION, "设备本地保留最近 100 条通话事件。", "当前页仅显示最新的100条通话记录。")
SMS_CENTER_EXTENSION = replaceLiteral(SMS_CENTER_EXTENSION,
    "function show(id,title){document.querySelectorAll('.page').forEach(x=>x.classList.toggle('active',x.id===id));nav.querySelectorAll('button').forEach(x=>x.classList.toggle('active',x.dataset.page===id));if($('crumb'))$('crumb').textContent='控制中心 / '+title;load()}",
    "async function loadCalls(){try{const r=await fetch('/api/calls');if(!r.ok)throw Error('无法读取通话记录');const v=await r.json(),callFeed=$('callFeed');if(callFeed)callFeed.innerHTML=callRows(v.calls||[])}catch(e){tip(e.message)}}function show(id,title){document.querySelectorAll('.page').forEach(x=>x.classList.toggle('active',x.id===id));nav.querySelectorAll('button').forEach(x=>x.classList.toggle('active',x.dataset.page===id));if($('crumb'))$('crumb').textContent='控制中心 / '+title;id==='calls'?loadCalls():load()}")

SMS_CENTER_EXTENSION = replaceLiteral(SMS_CENTER_EXTENSION,
    "}function show(id,title){",
    "}function loadSms(){let refresh=$('refreshSms');if(refresh){refresh.click();return}load()}function show(id,title){")
SMS_CENTER_EXTENSION = replaceLiteral(SMS_CENTER_EXTENSION,
    "id==='calls'?loadCalls():load()}",
    "id==='calls'?loadCalls():id==='sms'?loadSms():load()}")

local SMS_CONVERSATION_EXTENSION = [=[<style>.sms-conversations{display:grid;grid-template-columns:300px minmax(0,1fr);min-height:520px}.sms-contacts{border-right:1px solid #e2e8f0;padding:10px}.sms-contact{width:100%;border:0;border-radius:10px;background:transparent;text-align:left;padding:13px 12px;cursor:pointer;font:inherit}.sms-contact:hover,.sms-contact.active{background:#eff6ff}.sms-contact b,.sms-contact small{display:block}.sms-contact small{color:#64748b;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;margin-top:5px}.sms-contact time{float:right;color:#94a3b8;font-size:12px}.sms-detail{display:flex;flex-direction:column;min-width:0}.sms-detail-head{padding:15px 20px;border-bottom:1px solid #e2e8f0}.sms-detail-head h2{margin:0;font-size:16px}.sms-detail-head p{margin:5px 0 0;color:#64748b;font-size:12px}.sms-messages{display:flex;flex-direction:column;gap:10px;padding:20px;overflow:auto;flex:1;max-height:520px}.sms-bubble{max-width:min(72%,520px);padding:10px 13px;border-radius:12px;line-height:1.6;word-break:break-word}.sms-bubble.incoming{align-self:flex-start;background:#f1f5f9}.sms-bubble.outgoing{align-self:flex-end;background:#dbeafe}.sms-bubble time{display:block;color:#64748b;font-size:11px;margin-top:4px;text-align:right}.sms-empty{text-align:center;color:#64748b;padding:60px 20px}@media(max-width:760px){.sms-conversations{grid-template-columns:1fr}.sms-contacts{border-right:0;border-bottom:1px solid #e2e8f0;max-height:220px;overflow:auto}.sms-detail{min-height:380px}}</style><script>(function(){const page=$('sms'),panel=page&&page.querySelector('.panel');if(!page||!panel)return;panel.innerHTML='<div class="sms-conversations"><div class="sms-contacts" id="smsContacts"></div><div class="sms-detail" id="smsDetail"><div class="sms-empty">点击左侧手机号查看对话</div></div></div>'})()</script>]=]
SMS_CENTER_EXTENSION = replaceLiteral(SMS_CENTER_EXTENSION, "</style>", ".history-table{min-width:620px;border-collapse:separate;border-spacing:0 8px}.history-table th,.history-table td{padding:12px 18px;white-space:nowrap}.history-table th{font-size:13px;color:#64748b}.history-table td{font-size:14px}.history-table th:first-child,.history-table td:first-child{padding-left:22px}.history-table th:last-child,.history-table td:last-child{padding-right:22px}.sms-feed{padding:4px 2px}@media(max-width:700px){#callFeed{overflow-x:auto}.history-table{min-width:560px}.history-table th,.history-table td{padding:10px 12px}}</style>")
local CALL_HISTORY_TABLE_REFRESH_EXTENSION = [=[<script>(function(){let button=$('refreshCalls');if(!button)return;button.onclick=async()=>{try{let response=await fetch('/api/calls');if(!response.ok)throw Error('无法读取通话记录');let value=await response.json(),items=value.calls||[],map={INCOMINGCALL:'呼入',CONNECTED:'接通',SPEECH_START:'通话',DISCONNECTED:'挂断',MAKE_CALL_OK:'拨号成功',MAKE_CALL_FAILED:'拨号失败',ANSWER_CALL_DONE:'接听完成',HANGUP_CALL_DONE:'挂断完成'};$('callFeed').innerHTML=items.length?'<table class="history-table"><thead><tr><th>时间</th><th>手机号码</th><th>事件</th></tr></thead><tbody>'+items.map(x=>'<tr><td>'+esc(x.received_at||'--')+'</td><td>'+esc(x.number||'未知')+'</td><td>'+esc(map[x.call_state]||x.call_state||'未知')+'</td></tr>').join('')+'</tbody></table>':'<p class="history-empty">暂无记录</p>'}catch(error){if(typeof toast==='function')toast(error.message);else if(typeof note==='function')note(error.message)}}})()</script>]=]

local SMS_HISTORY_REFRESH_FIX_EXTENSION = [=[<script>(function(){let button=$('refreshSms');if(!button)return;let records=[],active='';function render(){let groups={};records.forEach(x=>{let phone=x.sender||'';if(phone){if(!groups[phone])groups[phone]=[];groups[phone].push(x)}});let phones=Object.keys(groups);if(!phones.length){$('smsContacts').innerHTML='<div class="sms-empty">暂无短信记录</div>';$('smsDetail').innerHTML='<div class="sms-empty">暂无短信记录</div>';return}if(!active||!groups[active])active=phones[0];$('smsContacts').innerHTML=phones.map(phone=>{let last=groups[phone][0]||{};return '<button class="sms-contact '+(phone===active?'active':'')+'" data-phone="'+esc(phone)+'"><time>'+esc(last.received_at||'--')+'</time><b>'+esc(phone)+'</b><small>'+esc(last.content||'暂无内容')+'</small></button>'}).join('');$('smsContacts').querySelectorAll('[data-phone]').forEach(item=>item.onclick=()=>{active=item.dataset.phone;render()});let items=groups[active]||[];$('smsDetail').innerHTML='<div class="sms-detail-head"><h2>'+esc(active)+'</h2><p>'+items.length+' 条短信</p></div><div class="sms-messages">'+items.slice().reverse().map(x=>'<div class="sms-bubble '+(x.direction==='outgoing'?'outgoing':'incoming')+'">'+esc(x.content||'')+'<time>'+esc(x.received_at||'--')+'</time></div>').join('')+'</div>'}button.onclick=async()=>{try{let response=await fetch('/api/sms/history');if(!response.ok)throw Error('无法读取短信记录');records=(await response.json()).sms||[];render()}catch(error){if(typeof toast==='function')toast(error.message);else if(typeof note==='function')note(error.message)}}})()</script>]=]

local REFRESH_ENDPOINTS_EXTENSION = [=[<script>(()=>{let n=$('newSms');if(n&&!$('refreshSms'))n.insertAdjacentHTML('afterend','<button class="button btn" id="refreshSms" style="margin-left:4px">刷新短信</button>');let f=(id,url)=>{let b=$(id);if(b)b.onclick=()=>fetch(url).catch(e=>note(e.message))};f('refreshCalls','/api/calls');f('refreshSms','/api/sms/history')})()</script>]=]
REFRESH_ENDPOINTS_EXTENSION = replaceLiteral(REFRESH_ENDPOINTS_EXTENSION, "let f=", "let s=$('refreshSms');if(n&&s){let g=document.createElement('div');g.className='sms-hero-actions';g.style.cssText='display:flex;gap:8px;align-items:center';n.parentNode.insertBefore(g,n);g.appendChild(n);g.appendChild(s)}let f=")
REFRESH_ENDPOINTS_EXTENSION = replaceLiteral(REFRESH_ENDPOINTS_EXTENSION, "let n=", "let send=$('sendSms');if(send)send.textContent='发送';let n=")
REFRESH_ENDPOINTS_EXTENSION = replaceLiteral(REFRESH_ENDPOINTS_EXTENSION, "let n=", "let info=document.querySelector('#sms .hero p');if(info)info.textContent='短信和通话共用256KB历史空间，最多保留500条，短信正文最多保存512字节。';let n=")
REFRESH_ENDPOINTS_EXTENSION = replaceLiteral(REFRESH_ENDPOINTS_EXTENSION, "let s=$('refreshSms');", "let s=$('refreshSms');if(s)s.textContent='刷新';")
SMS_CENTER_EXTENSION = replaceLiteral(SMS_CENTER_EXTENSION, "esc(x.call_state||'未知')", "esc(({INCOMINGCALL:'呼入',CONNECTED:'接通',SPEECH_START:'通话',DISCONNECTED:'挂断',MAKE_CALL_OK:'拨号成功',MAKE_CALL_FAILED:'拨号失败',ANSWER_CALL_DONE:'接听完成',HANGUP_CALL_DONE:'挂断完成'})[x.call_state]||x.call_state||'未知')")

local SMS_MODE_LABEL_EXTENSION = [=[<script>(function(){let renderSmsMode=form;form=function(){renderSmsMode();let select=document.querySelector('#channelPolicyFields select[data-k="sms_mode"]');if(!select)return;let label=select.closest('.field').querySelector('label');if(label)label.textContent='短信转发范围';let names={all:'全部',verification:'过滤'};Array.from(select.options).forEach(option=>option.textContent=names[option.value]||option.value)}})()</script>]=]


local POLICY_SWITCH_ALIGNMENT_EXTENSION = [=[<style>#channelPolicyFields .field.check{display:grid;grid-template-columns:minmax(0,1fr) auto 18px;align-items:center;column-gap:14px}#channelPolicyFields .field.check .help{grid-column:1;grid-row:1;margin:0}#channelPolicyFields .field.check label{grid-column:2;grid-row:1;margin:0!important;white-space:nowrap}#channelPolicyFields .field.check input{grid-column:3;grid-row:1;margin:0;width:18px;height:18px}</style>]=]


local AUTO_REFRESH_NOTE_EXTENSION = [=[<style>.refresh-note{position:absolute;right:0;top:43px;color:#64748b;font-size:12px}</style><script>(function(){let refresh=$('refresh');if(!refresh)return;let hero=refresh.closest('.hero');hero.style.position='relative';hero.style.paddingBottom='17px';refresh.insertAdjacentHTML('afterend','<span class="refresh-note">每 30 秒自动刷新一次</span>')})()</script>]=]


local WIFI_SWITCH_LABEL_EXTENSION = [=[<script>(function(){let renderWifiSettings=renderSettings;renderSettings=function(){renderWifiSettings();let toggle=$('wifiEnabled'),label=document.querySelector('label[for="wifiEnabled"]');if(!toggle||!label)return;let update=()=>label.textContent=(toggle.checked?'已启用':'未启用')+' Wi-Fi（重启后生效）';let previous=toggle.onchange;toggle.onchange=()=>{if(previous)previous();update()};update()};if($('settings')&&$('settings').classList.contains('active'))renderSettings()})()</script>]=]



local CELLULAR_DATA_SETTINGS_EXTENSION = [=[<script>(function(){let renderNetworkSettings=renderSettings;renderSettings=function(){renderNetworkSettings();let panel=document.querySelector('#settings .settings-stack');if(!panel||$('cellularDataEnabled'))return;let network=cfg.NETWORK||(cfg.NETWORK={}),wifiCard=panel.querySelector('.settings-block');wifiCard.insertAdjacentHTML('afterend','<section class="settings-block" id="cellularDataSettings"><h2>蜂窝数据设置</h2><p>Wi-Fi 与蜂窝数据均启用时，Wi-Fi 优先、4G 备用；仅启用其中之一时只使用该网络；两者均关闭时不使用数据网络。</p><div class="field check wide"><label for="cellularDataEnabled"></label><input id="cellularDataEnabled" type="checkbox"></div></section>');let toggle=$('cellularDataEnabled'),label=document.querySelector('label[for="cellularDataEnabled"]'),update=()=>label.textContent=(toggle.checked?'已启用':'未启用')+'蜂窝数据（重启后生效）';toggle.checked=network.cellular_data_enabled===true;toggle.onchange=()=>{network.cellular_data_enabled=toggle.checked;update()};update()};if($('settings')&&$('settings').classList.contains('active'))renderSettings()})()</script>]=]


local CELLULAR_FLIGHT_MODE_EXTENSION = [=[<style>.settings-action-row{display:flex;align-items:center;justify-content:flex-end;gap:8px;flex-wrap:wrap}.flight-mode-button{color:#1d4ed8;background:#fff;border:1px solid #93c5fd}.flight-mode-button:hover{background:#eff6ff}.flight-mode-button.active{color:#fff;background:#2563eb}.flight-mode-button:disabled{opacity:.65}@media(max-width:700px){#settings .hero{flex-wrap:wrap;gap:12px}#settings .hero>div:last-child{width:100%;justify-content:flex-start}.settings-action-row .btn{flex:1;min-width:0}}</style><script>(function(){let r=renderSettings;renderSettings=function(){r();let a=$('settings')?.querySelector('.hero')?.children[1];if(!a||$('cellularFlightModeButton'))return;a.classList.add('settings-action-row');a.insertAdjacentHTML('beforeend','<button class="btn flight-mode-button" id="cellularFlightModeButton" type="button" aria-pressed="false">&#x98de;&#x884c;&#x6a21;&#x5f0f;</button>');let n=cfg.NETWORK||(cfg.NETWORK={}),b=$('cellularFlightModeButton'),u=()=>{let e=n.cellular_flight_mode===true;b.classList.toggle('active',e);b.setAttribute('aria-pressed',e);b.title=e?'\u5df2\u5f00\u542f\uff1a4G \u6a21\u5757\u4e0d\u53ef\u63a5\u6536\u77ed\u4fe1\u548c\u7535\u8bdd':'\u672a\u5f00\u542f\uff1a4G \u6a21\u5757\u4e0d\u53ef\u63a5\u6536\u77ed\u4fe1\u548c\u7535\u8bdd'};b.onclick=async()=>{let p=n.cellular_flight_mode===true,e=!p;b.disabled=true;n.cellular_flight_mode=e;u();try{let r=await fetch('/api/cellular/flight-mode',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({enabled:e})}),v=await r.json();if(!r.ok||v.ok!==true)throw Error(v.detail||'\u98de\u884c\u6a21\u5f0f\u8bbe\u7f6e\u5931\u8d25');n.cellular_flight_mode=v.cellular_flight_mode===true;note(e?'\u98de\u884c\u6a21\u5f0f\u5df2\u5f00\u542f':'\u98de\u884c\u6a21\u5f0f\u5df2\u5173\u95ed')}catch(x){n.cellular_flight_mode=p;note(x.message)}finally{b.disabled=false;u()}};u()};if($('settings')?.classList.contains('active'))renderSettings()})()</script>]=]

local ACTIVE_PAGE_REFRESH_EXTENSION = [=[<script>(function(){let activePage=document.querySelector('.page.active');if(!activePage)return;let name=activePage.id;if(name==='overview'){loadStatus();return}if(name==='channels'){loadCfg().catch(e=>note(e.message));return}if(name==='filters'||name==='settings'){loadCfg().then(()=>name==='filters'?renderFilters():renderSettings()).catch(e=>note(e.message))}})()</script>]=]

local LOCAL_NUMBER_EXTENSION = [=[<script>(function(){let priorRenderSettings=renderSettings;renderSettings=function(){priorRenderSettings();let panel=document.querySelector('#settings .settings-stack'),pin=panel&&panel.querySelector('.settings-block.pin');if(!panel||!pin||$('localNumber'))return;pin.insertAdjacentHTML('beforeend','<div class="field" style="margin-top:16px"><label for="localNumber">本机号码</label><input id="localNumber" inputmode="tel" autocomplete="tel"><p class="help">设备无法从 SIM 读取号码时使用此号码。</p></div>');$('localNumber').value=cfg.FALLBACK_LOCAL_NUMBER||'';$('localNumber').oninput=()=>cfg.FALLBACK_LOCAL_NUMBER=$('localNumber').value}})()</script>]=]

BASE_DASHBOARD = replaceLiteral(BASE_DASHBOARD, "setInterval(loadStatus,15000)", "setInterval(loadStatus,30000)")
BASE_DASHBOARD = replaceLiteral(BASE_DASHBOARD, "(s.network_type||'无网络')+' / '+ip", "(s.data_type||'无网络')+' / '+ip")

local SMS_CENTER_REFERENCE_EXTENSION = [=[<style>#sms .sms-conversations{grid-template-rows:1fr auto}#sms .sms-sidebar{grid-column:1;grid-row:1;border-right:1px solid #e2e8f0}#sms .sms-contacts{border:0;height:calc(100% - 60px);overflow:auto}#sms .sms-contact{display:grid;grid-template-columns:minmax(0,1fr) auto;grid-template-rows:22px 22px;column-gap:8px;row-gap:4px;min-height:78px;height:78px;align-items:center}#sms .sms-contact b{grid-column:1;grid-row:1;min-width:0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}#sms .sms-contact time{grid-column:2;grid-row:1;float:none;white-space:nowrap}#sms .sms-contact small{grid-column:1/-1;grid-row:2;margin-top:0;line-height:22px}#sms .sms-search{padding:12px;border-bottom:1px solid #e2e8f0}#sms .sms-search input{width:100%;padding:10px;border:0;border-radius:9px;background:#f8fafc;font:inherit}#sms #smsDetail{grid-column:2;grid-row:1}#sms .sms-reply{grid-column:2;grid-row:2}@media(max-width:760px){#sms .sms-sidebar,#sms #smsDetail,#sms .sms-reply{grid-column:1;grid-row:auto}#sms .sms-contacts{height:auto;max-height:220px}}</style><script>(function(){let p=$('sms'),l=p&&p.querySelector('.sms-conversations'),c=$('smsContacts');if(!l||!c)return;let s=document.createElement('div');s.className='sms-sidebar';c.parentNode.insertBefore(s,c);s.appendChild(c);s.insertAdjacentHTML('afterbegin','<div class="sms-search"><input id="smsSearch" placeholder="搜索联系人或内容..."></div>');let q=$('smsSearch'),f=()=>{let v=q.value.toLowerCase();c.querySelectorAll('.sms-contact').forEach(x=>x.hidden=v&&!x.textContent.toLowerCase().includes(v))};q.oninput=f;new MutationObserver(f).observe(c,{childList:true});let h=p.querySelector('.hero p');if(h)h.textContent='查看短信会话、搜索历史记录，或向任意号码发送新短信。'})()</script>]=]
REFRESH_ENDPOINTS_EXTENSION = replaceLiteral(REFRESH_ENDPOINTS_EXTENSION, "刷新短信", "刷新")
local SMS_REPLY_EXTENSION = [=[<style>.sms-reply{grid-column:2;display:flex;gap:8px;padding:10px 16px;border-top:1px solid #e2e8f0}.sms-reply textarea{flex:1;height:42px;min-height:42px;resize:none;border:1px solid #cbd5e1;border-radius:8px;padding:9px;font:inherit}.sms-reply button{align-self:flex-end;height:42px}@media(max-width:760px){.sms-reply{grid-column:1}}</style><script>(function(){let d=$('smsDetail');if(!d)return;d.parentNode.insertAdjacentHTML('beforeend','<div class="sms-reply"><textarea id="smsReplyText" rows="2" placeholder="输入短信内容"></textarea><button class="button btn" id="smsReplySend">发送</button></div>');let t=$('smsReplyText'),b=$('smsReplySend');b.onclick=async()=>{let a=document.querySelector('#smsContacts .sms-contact.active'),n=a&&a.dataset.phone,c=t.value.trim();if(!n||!c){note('请选择号码并输入短信内容');return}b.disabled=true;try{let r=await fetch('/api/sms/send',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({number:n,content:c})}),v=await r.json();if(!r.ok||!v.ok)throw Error(v.detail||'短信发送失败');let m=d.querySelector('.sms-messages');if(m)m.insertAdjacentHTML('beforeend','<div class="sms-bubble outgoing">'+esc(c)+'<time>刚刚</time></div>');t.value=''}catch(e){note(e.message)}finally{b.disabled=false}}})()</script>]=]
local SMS_STORAGE_SPACE_EXTENSION = [=[<style>.sms-space-card{margin:0 0 18px;padding:16px 20px}.sms-space-card h2{margin:0 0 12px;font-size:16px}.sms-space-grid{display:grid;grid-template-columns:1fr 1fr;gap:12px}.sms-space-item{display:flex;justify-content:space-between;gap:12px;padding:10px 12px;background:#f8fafc;border-radius:9px}.sms-space-item span{color:#64748b}.sms-space-item b{white-space:nowrap}.sms-space-card p{margin:10px 0 0}@media(max-width:600px){.sms-space-grid{grid-template-columns:1fr}}</style><script>(function(){let page=$('sms');if(!page||page.querySelector('.sms-space-card'))return;let hero=page.querySelector('.hero');if(!hero)return;hero.insertAdjacentHTML('afterend','<article class="panel sms-space-card"><h2>空间使用情况</h2><div class="sms-space-grid"><div class="sms-space-item"><span>短信/电话历史</span><b id="smsHistorySpace">--</b></div><div class="sms-space-item"><span>LittleFS 已用</span><b id="smsFsSpace">--</b></div><div class="sms-space-item"><span>Lua</span><b id="smsLuaMemory">--</b></div><div class="sms-space-item"><span>系统内存</span><b id="smsSysMemory">--</b></div></div></article>');let history=$('smsHistorySpace'),fs=$('smsFsSpace'),lua=$('smsLuaMemory'),sys=$('smsSysMemory');function size(value){let bytes=Number(value)||0;if(bytes<1024)return bytes+' B';return (bytes/1024).toFixed(bytes%1024?'1':'0')+' KB'}function render(s){let used=Number(s.history_bytes)||0,budget=Number(s.history_budget)||0;history.textContent=size(used)+' / '+size(budget);fs.textContent=(s.fs_mem||'--')+' 已用';lua.textContent=s.lua_mem||'--';sys.textContent=s.sys_mem||'--'}async function load(){if(!page.classList.contains('active'))return;try{let response=await fetch('/api/status');if(!response.ok)throw Error();render(await response.json())}catch(error){}}let button=document.querySelector('.nav button[data-page="overview"]');if(button)button.addEventListener('click',load);if(page.classList.contains('active'))load();setInterval(load,30000)})()</script>]=]

SMS_STORAGE_SPACE_EXTENSION = replaceLiteral(SMS_STORAGE_SPACE_EXTENSION,
    ".sms-space-card{margin:0 0 18px;padding:16px 20px}",
    ".sms-space-card{margin:0;padding:22px;min-width:0;align-self:start;grid-column:2;grid-row:1}.grid>.panel:first-child{grid-column:1;grid-row:1 / span 2}.grid>.panel:nth-child(3){grid-column:2;grid-row:2}.sms-space-card h2{font-size:18px;line-height:1.4}.sms-space-card .sms-space-subtitle{margin:8px 0 18px;line-height:1.5}.sms-space-card .sms-space-grid{grid-template-columns:repeat(2,minmax(0,1fr));gap:14px}.sms-space-item{min-width:0;flex-direction:column;align-items:flex-start;gap:6px;padding:14px 16px}.sms-space-item span{font-size:13px}.sms-space-item b{font-size:16px;line-height:1.35;white-space:normal;overflow-wrap:anywhere}@media(max-width:850px){.grid>.panel:first-child,.sms-space-card,.grid>.panel:nth-child(3){grid-column:1;grid-row:auto}}@media(max-width:600px){.sms-space-card .sms-space-grid{grid-template-columns:1fr}}")
SMS_STORAGE_SPACE_EXTENSION = replaceLiteral(SMS_STORAGE_SPACE_EXTENSION,
    "let hero=page.querySelector('.hero');if(!hero)return;hero.insertAdjacentHTML('afterend',",
    "let grid=page.querySelector('.grid');if(!grid)return;grid.firstElementChild.insertAdjacentHTML('afterend',")

SMS_STORAGE_SPACE_EXTENSION = replaceLiteral(SMS_STORAGE_SPACE_EXTENSION,
    "let button=document.querySelector('.nav button[data-page=\"sms\"]');if(button)button.addEventListener('click',load);load();setInterval(load,30000)",
    "let button=document.querySelector('.nav button[data-page=\"overview\"]');if(button)button.addEventListener('click',load);if(page.classList.contains('active'))load();setInterval(load,30000)")

SMS_STORAGE_SPACE_EXTENSION = replaceLiteral(SMS_STORAGE_SPACE_EXTENSION,
    "async function load(){try{let response=await fetch('/api/status');",
    "async function load(){if(!page.classList.contains('active'))return;try{let response=await fetch('/api/status');")
SMS_STORAGE_SPACE_EXTENSION = replaceLiteral(SMS_STORAGE_SPACE_EXTENSION,
    "async function load(){if(!page.classList.contains('active'))return;try{let response=await fetch('/api/status');if(!response.ok)throw Error();render(await response.json())}catch(error){}}let button=document.querySelector('.nav button[data-page=\"overview\"]');if(button)button.addEventListener('click',load);if(page.classList.contains('active'))load();setInterval(load,30000)",
    "window.renderRuntimeSpace=render;if(window.__dashboardStatus)render(window.__dashboardStatus)")

SMS_STORAGE_SPACE_EXTENSION = replaceLiteral(SMS_STORAGE_SPACE_EXTENSION,
    "<h2>空间使用情况</h2>",
    "<h2>空间使用情况</h2><p class=\"muted sms-space-subtitle\">系统运行空间监控</p>")
SMS_STORAGE_SPACE_EXTENSION = replaceLiteral(SMS_STORAGE_SPACE_EXTENSION,
    '<div class="sms-space-grid"><div class="sms-space-item"><span>短信/电话历史</span><b id="smsHistorySpace">--</b></div><div class="sms-space-item"><span>LittleFS 已用</span><b id="smsFsSpace">--</b></div><div class="sms-space-item"><span>Lua</span><b id="smsLuaMemory">--</b></div><div class="sms-space-item"><span>系统内存</span><b id="smsSysMemory">--</b></div></div>',
    '<div class="sms-space-grid"><div class="sms-space-item"><span>系统内存</span><b id="smsSysMemory">--</b></div><div class="sms-space-item"><span>Lua</span><b id="smsLuaMemory">--</b></div><div class="sms-space-item"><span>LittleFS 已用</span><b id="smsFsSpace">--</b></div><div class="sms-space-item"><span>短信/电话占用</span><b id="smsHistorySpace">--</b></div></div>')

CONTROL_EXTENSION = replaceLiteral(CONTROL_EXTENSION, "已保存，设备正在重启…", "配置已保存")
SETTINGS_EXTENSION = replaceLiteral(SETTINGS_EXTENSION,
    "Wi-Fi 与 SIM PIN 分开设置；保存后设备会重启。", "Wi-Fi 与 SIM PIN 设置；保存后设备会重启。")
SETTINGS_LAYOUT_EXTENSION = replaceLiteral(SETTINGS_LAYOUT_EXTENSION,
    "Wi-Fi 与 SIM PIN 分开设置；保存后设备会重启。", "Wi-Fi 与 SIM PIN 设置；保存后设备会重启。")
SMS_CENTER_EXTENSION = replaceLiteral(SMS_CENTER_EXTENSION,
    "fetch('/api/history')", "fetch('/api/sms/history?limit=500')")
SMS_HISTORY_REFRESH_FIX_EXTENSION = replaceLiteral(SMS_HISTORY_REFRESH_FIX_EXTENSION,
    "'/api/sms/history'", "'/api/sms/history?limit=500'")
SMS_STORAGE_SPACE_EXTENSION = replaceLiteral(SMS_STORAGE_SPACE_EXTENSION,
    "let page=$('sms')", "let page=$('overview')")

local CHANNEL_DOC_LAYOUT_EXTENSION = [=[<style>.channel-panel-head{display:flex;align-items:flex-start;justify-content:space-between;gap:16px;margin-bottom:16px}.channel-panel-head h2{margin:0 0 6px}.channel-panel-head p{margin:0;color:#64748b}.channel-panel-head .channel-head-actions{margin-left:auto}@media(max-width:700px){.channel-panel-head{flex-direction:column}.channel-panel-head .channel-head-actions{margin-left:0;justify-content:flex-start}}</style><script>(function(){let renderChannelDoc=form;form=function(){renderChannelDoc();let root=$('form'),title=$('channelTitle'),hint=$('channelHint'),panel=root&&root.parentElement;if(!root||!title||!hint||!panel)return;let panelHead=panel.querySelector('.channel-panel-head');if(!panelHead){panelHead=document.createElement('div');panelHead.className='channel-panel-head';let copy=document.createElement('div'),actions=document.createElement('div');copy.className='channel-panel-copy';actions.className='channel-head-actions';panelHead.appendChild(copy);panelHead.appendChild(actions);panel.insertBefore(panelHead,root);copy.appendChild(title);copy.appendChild(hint)}let actions=panelHead.querySelector('.channel-head-actions'),doc=root.querySelector('.channel-doc'),old=actions&&actions.querySelector('.channel-panel-doc');if(old)old.remove();if(doc&&actions){doc.classList.add('channel-panel-doc');actions.appendChild(doc)}}})()</script>]=]

TEST_MODE_EXTENSION = replaceLiteral(TEST_MODE_EXTENSION,
    "if(item.type==='dingtalk'&&item.require_signature===true)",
    "if((item.type==='dingtalk'||item.type==='feishu')&&item.require_signature===true)")
FILTER_LAYOUT_EXTENSION = FILTER_LAYOUT_EXTENSION:gsub("保存并重启后配置生效", "保存后立即生效")
FILTER_LAYOUT_EXTENSION = FILTER_LAYOUT_EXTENSION:gsub("保存并重启", "保存并生效")
TEST_MODE_EXTENSION = replaceLiteral(TEST_MODE_EXTENSION,
    "renderResult(state.state==='retrying'?'发送失败，设备正在重试…':'配置已保存，已加入测试队列…');",
    "renderResult(state.state==='retrying'?'发送失败：'+(state.detail||'设备正在重试')+'；设备正在重试…':'配置已保存，已加入测试队列…');")

local DASHBOARD_EXTENSIONS = {
    CONTROL_EXTENSION, SETTINGS_EXTENSION, SETTINGS_LAYOUT_EXTENSION,
    WIFI_SWITCH_LABEL_EXTENSION, CELLULAR_DATA_SETTINGS_EXTENSION,
    CELLULAR_FLIGHT_MODE_EXTENSION,
    FILTER_LAYOUT_EXTENSION,
    TEST_EXTENSION, CHANNEL_LAYOUT_EXTENSION, TEST_MODE_EXTENSION,
    CHANNEL_TYPE_LAYOUT_EXTENSION, CHANNEL_DOC_LAYOUT_EXTENSION, CHANNEL_LIST_LABEL_EXTENSION, CHANNEL_POLICY_HELP_EXTENSION, SMS_MODE_LABEL_EXTENSION,
    POLICY_SWITCH_ALIGNMENT_EXTENSION, SIGNAL_REFERENCE_EXTENSION, AUTO_REFRESH_NOTE_EXTENSION,
    LOCAL_NUMBER_EXTENSION, ACTIVE_PAGE_REFRESH_EXTENSION, SMS_CENTER_EXTENSION, SMS_CONVERSATION_EXTENSION,
    SMS_REPLY_EXTENSION, SMS_CENTER_REFERENCE_EXTENSION, REFRESH_ENDPOINTS_EXTENSION,
    CALL_HISTORY_TABLE_REFRESH_EXTENSION, SMS_HISTORY_REFRESH_FIX_EXTENSION,
    TEMPLATE_RESET_EXTENSION,
    SMS_STORAGE_SPACE_EXTENSION,
}

local DASHBOARD_ASSETS = table.concat(DASHBOARD_EXTENSIONS, "\n")
local DASHBOARD_ASSET_CHUNKS = {}
local DASHBOARD_ASSET_CHUNK_SIZE = 16000
for offset = 1, #DASHBOARD_ASSETS, DASHBOARD_ASSET_CHUNK_SIZE do
    table.insert(DASHBOARD_ASSET_CHUNKS, DASHBOARD_ASSETS:sub(offset, offset + DASHBOARD_ASSET_CHUNK_SIZE - 1))
end

local DASHBOARD_CHUNK_COUNT_LOADER = [=[<script>(async()=>{let nav=document.querySelector('.nav');if(nav){nav.inert=true;nav.setAttribute('aria-busy','true');nav.style.opacity='.65'}let parts=[];for(let i=1;i<=__CHUNK_COUNT__;i++){let r=await fetch('/assets/dashboard/'+i);if(!r.ok)throw Error('页面资源加载失败');parts.push(await r.text())}let t=document.createElement('template');t.innerHTML=parts.join('');t.content.querySelectorAll('style').forEach(x=>document.head.appendChild(x));for(let x of t.content.querySelectorAll('script')){let s=document.createElement('script');s.text=x.text;document.body.appendChild(s)}if(nav){nav.inert=false;nav.removeAttribute('aria-busy');nav.style.opacity=''}})().catch(e=>{document.body.innerHTML='<p style="padding:24px;font:16px system-ui">'+e.message+'</p>'})</script>]=]
local DASHBOARD_LOADER = replaceLiteral(DASHBOARD_CHUNK_COUNT_LOADER, "__CHUNK_COUNT__", tostring(#DASHBOARD_ASSET_CHUNKS))
local LIGHTWEIGHT_DASHBOARD = replaceLiteral(BASE_DASHBOARD, "</body>", DASHBOARD_LOADER .. "</body>")

local function saveConfigValue(value)
    if type(value) ~= "table" then return false, "Invalid JSON object" end
    local policy_valid, policy_detail = validateConfigPolicies(value)
    if not policy_valid then return false, "Invalid channel policy: " .. tostring(policy_detail) end
    value.WEB = nil
    local text = json.encode(value)
    if not text or #text > 3800 then return false, "Config is too large to persist" end
    if not fskv.set(KEY, value) then return false, "Failed to persist config" end
    -- 让后续页面切换和连续保存继续看到本次已保存的配置；网络模块等
    -- 需要重启初始化的部分仍由“保存并重启”统一生效。
    merge(config, value)
    local current_bark = type(config.CHANNELS) == "table" and config.CHANNELS.bark or nil
    if type(current_bark) == "table" and type(current_bark.enabled) == "boolean" then
        local notify_ok, notify = pcall(require, "util_notify")
        if notify_ok and type(notify) == "table"
            and type(notify.setBarkEnabled) == "function" then
            notify.setBarkEnabled(current_bark.enabled)
        end
    end
    return true
end

local function validateChannelConfig(channel, value)
    if type(channel) ~= "string" or type(config.CHANNELS) ~= "table"
        or type(config.CHANNELS[channel]) ~= "table"
        or type(value) ~= "table" or type(value.CHANNELS) ~= "table"
        or type(value.CHANNELS[channel]) ~= "table" then
        return false, "channel_not_configured"
    end
    -- 渠道实现类型由设备内置配置决定，不能由网页请求修改。
    value.CHANNELS[channel].type = config.CHANNELS[channel].type
    local policy_valid, policy_detail = util_router.validatePolicy(
        channel, value.CHANNELS[channel], value)
    if not policy_valid then
        return false, "Invalid channel policy: " .. tostring(policy_detail or "channel policy is invalid")
    end
    local valid, detail = (require "util_notify_channel").validate(channel, value)
    if not valid then return false, "配置无效：" .. tostring(detail or "channel_invalid") end
    return true
end

local function flightModeNotification(enabled, network_status)
    local sim_ok, sim_ready = pcall(function()
        return mobile.simPin(mobile.simid())
    end)
    local sim_text = not sim_ok and "SIM卡状态未知"
        or sim_ready == true and "SIM卡已就绪" or "SIM卡未就绪"
    local mode_text = enabled
        and "已进入飞行模式"
        or "已退出飞行模式"
    local wifi_adapter = type(network_status) == "table"
        and network_status.wifi_connected == true
        and tonumber(network_status.wifi_adapter) or nil
    return mode_text .. "，" .. sim_text .. "。", wifi_adapter
end

local function handler(_, method, uri, headers, body)
    if not auth(headers) then return 401, { ["WWW-Authenticate"] = 'Basic realm="Air8000W"' }, "Authentication required" end
    local path, query = splitUri(uri)
    if method == "GET" and path == "/" then return reply(200, LIGHTWEIGHT_DASHBOARD, "text/html; charset=utf-8") end
    if method == "GET" and path == "/assets/dashboard" then
        return reply(200, DASHBOARD_ASSETS, "text/plain; charset=utf-8")
    end
    local asset_index = path:match("^/assets/dashboard/(%d+)$")
    if method == "GET" and asset_index then
        local chunk = DASHBOARD_ASSET_CHUNKS[tonumber(asset_index)]
        if not chunk then return reply(404, "Not found") end
        return reply(200, chunk, "text/plain; charset=utf-8")
    end
    if method == "GET" and path == "/api/ping" then
        return jsonReply({ ok = true, service = "air8000w-web-admin", version = 2 })
    end
    if method == "GET" and path == "/api/status" then
        local provider = status_provider or fallbackStatus
        local ok, value = pcall(provider)
        if not ok then
            log.error("web", "Status collection failed", tostring(value))
            return jsonReply({ ok = false, error = "status_collection_failed" })
        end
        return jsonReply(value)
    end
    if method == "GET" and path == "/api/history" then
        return jsonReply(util_history.getAll())
    end
    if method == "POST" and path == "/api/cellular/flight-mode" then
        local request = json.decode(body or "")
        if type(request) ~= "table" or type(request.enabled) ~= "boolean" then
            return jsonReply({ ok = false, detail = "cellular_flight_mode_required" })
        end

        local network_api = require "util_network"
        local previous = network_api.isFlightMode()
        local pin_verified = false
        if previous ~= request.enabled then
            local applied, apply_detail, verified = network_api.setFlightMode(request.enabled)
            if not applied then
                return jsonReply({ ok = false, detail = apply_detail or "4G flight mode failed" })
            end
            pin_verified = verified == true
        end

        local next_config = clone(config)
        local network = type(next_config.NETWORK) == "table" and next_config.NETWORK or {}
        next_config.NETWORK = network
        network.cellular_flight_mode = request.enabled
        local saved, save_detail = saveConfigValue(next_config)
        if not saved then
            if previous ~= request.enabled then network_api.setFlightMode(previous) end
            return jsonReply({ ok = false, detail = save_detail or "4G flight mode persistence failed" })
        end
        local notification, wifi_adapter = flightModeNotification(request.enabled, network_api.getStatus())
        if type(wifi_adapter) == "number" then
            local notify_ok, queued = pcall(require("util_notify").addSystem,
                notification, true, true, wifi_adapter)
            if not notify_ok or queued ~= true then
                log.warn("web", "4G flight mode notification was not queued")
            end
        else
            log.warn("web", "4G flight mode notification skipped because Wi-Fi is unavailable")
        end
        return jsonReply({ ok = true, cellular_flight_mode = request.enabled, wifi_preserved = true, pin_verified = pin_verified })
    end
    if method == "GET" and path == "/api/calls" then
        local limit, before = pageQuery(query)
        return jsonReply({ calls = util_history.getCalls(limit, before) })
    end
    if method == "GET" and path == "/api/sms/history" then
        local limit, before = pageQuery(query)
        return jsonReply({ sms = util_history.getSms(limit, before) })
    end
    if method == "POST" and path == "/api/sms/send" then
        if require("util_network").isFlightMode() then
            return jsonReply({ ok = false, detail = "4G module is in flight mode" })
        end
        local request = json.decode(body or "")
        local number = type(request) == "table" and tostring(request.number or "") or ""
        local content = type(request) == "table" and tostring(request.content or "") or ""
        if number == "" or content == "" then return jsonReply({ ok = false, detail = "number_and_content_required" }) end
        local ok, sent = pcall(sms.send, number, content)
        if not ok or sent ~= true then return jsonReply({ ok = false, detail = "sms_send_failed" }) end
        local saved = util_history.addSms(number, content, os.date("%Y-%m-%d %H:%M:%S"), "outgoing")
        return jsonReply({ ok = true, history_saved = saved == true })
    end
    if (method == "GET" or method == "POST") and path == "/api/channels/config/log" then
        local ok, count = (require "util_notify").logChannelConfig()
        return jsonReply({ ok = ok == true, channels = count or 0 })
    end
    local test_channel = path:match("^/api/channels/test/([%w_%-]+)$")
    if method == "GET" and test_channel then
        return jsonReply((require "util_notify").getChannelTest(test_channel))
    end
    if method == "POST" and path == "/api/channels/test" then
        local request = json.decode(body or "")
        local channel = type(request) == "table" and request.channel or nil
        local value = type(request) == "table" and request.config or nil
        if type(value) ~= "table" then
            return jsonReply({ ok = false, detail = "请先填写并提交当前页面配置" })
        end
        value = clone(value)
        local valid, validation_detail = validateChannelConfig(channel, value)
        if not valid then
            return jsonReply({ ok = false, detail = validation_detail or "配置无效" })
        end
        local saved, save_detail = saveConfigValue(value)
        if not saved then return jsonReply({ ok = false, detail = save_detail or "配置保存失败" }) end
        local ok, detail = (require "util_notify").addChannelTest(channel)
        return jsonReply({ ok = ok == true, detail = detail or "" })
    end
    if method == "GET" and path == "/api/config/default-templates" then
        return jsonReply(DEFAULT_TEMPLATES)
    end
    if method == "GET" and path == "/api/config" then
        local out = clone(config); out.WEB.password = nil; return reply(200, json.encode(out), "application/json; charset=utf-8")
    end
    if method == "PUT" and path == "/api/config" then
        local value = json.decode(body or "")
        local saved, detail = saveConfigValue(value)
        if not saved then
            local code = detail == "Failed to persist config" and 500 or 400
            return reply(code, detail or "Failed to persist config")
        end
        return reply(200, "Saved.")
    end
    if method == "POST" and path == "/api/reboot" then
        sys.timerStart(rtos.reboot, 300)
        return reply(200, "Rebooting.")
    end
    return reply(404, "Not found")
end
function M.init()
    local web = type(config.WEB) == "table" and config.WEB or {}; local net = type(config.NETWORK) == "table" and config.NETWORK or {}
    if started or web.enabled ~= true or type(web.username) ~= "string" or web.username == "" or type(web.password) ~= "string" or web.password == "" then return false end
    started = httpsrv.start(tonumber(web.port) or 80, handler, tonumber(net.wifi_adapter) or 2) == true
    return started
end
return M
