local util_network = require "util_network"

local util_http = {}

local function diag(event, ...)
    if type(USER_DIAG) ~= "function" then return end
    if type(config.LOGGING) ~= "table" and config.DIAGNOSTIC_LOGS ~= true then return end
    USER_DIAG("http", event, ...)
end

function util_http.fetch(timeout, method, url, headers, body)
    collectgarbage("collect")
    local adapter = util_network.currentAdapter()
    if type(adapter) ~= "number" then
        diag("skip", "reason", "no_network")
        return -1, nil, nil
    end
    local opts = {
        timeout = timeout or config.HTTP_TIMEOUT or 20000,
        adapter = adapter,
        debug = false,
    }
    local started = mcu.ticks()
    diag("start", "method", tostring(method or ""), "request_bytes",
        type(body) == "string" and #body or 0, "timeout_ms", opts.timeout,
        "adapter", adapter)
    local code, response_headers, response_body = http.request(method, url, headers, body, opts).wait()
    local elapsed = mcu.ticks() - started
    if elapsed < 0 then elapsed = elapsed + 4294967296 end
    diag("finish", "code", code or "nil", "response_bytes",
        type(response_body) == "string" and #response_body or 0, "elapsed_ms", elapsed,
        "adapter", adapter)
    if type(code) ~= "number" or code < 0 then
        util_network.reportFailure()
    end
    collectgarbage("collect")
    return code, response_headers, response_body
end

return util_http
