local source = debug.getinfo(1, "S").source:sub(2):gsub("\\", "/")
local test_dir = source:match("^(.*[/])") or "tests/"
package.path = test_dir .. "../script/?.lua;" .. test_dir .. "?.lua;" .. (package.path or "")
package.loaded.httpdns = nil

local support = dofile(test_dir .. "test_support.lua")
local requests = {}
local ali_code, ali_body = 200, "[\"203.0.113.10\"]"
local tx_code, tx_body = 200, "203.0.113.11,203.0.113.12"

log = { debug = function() end }
json = {
    decode = function(value)
        if value == ali_body then return { "203.0.113.10" } end
        error("unexpected JSON body")
    end,
}
if not string.split then
    function string.split(value, separator)
        local result = {}
        for item in (value .. separator):gmatch("(.-)" .. separator) do
            table.insert(result, item)
        end
        return result
    end
end
http = {
    request = function(method, url, headers, body, opts)
        table.insert(requests, { method = method, url = url, headers = headers, body = body, opts = opts })
        local code, response = url:find("223.5.5.5", 1, true) and ali_code or tx_code,
            url:find("223.5.5.5", 1, true) and ali_body or tx_body
        return { wait = function() return code, {}, response end }
    end,
}

local httpdns = require "httpdns"
support.assertEqual(httpdns.version(), "202607021200", "HTTP DNS version")
support.assertEqual(httpdns.ali(nil), nil, "nil Ali domain is ignored")
support.assertEqual(#requests, 0, "nil Ali domain does not issue request")

local ali_opts = { adapter = 2 }
support.assertEqual(httpdns.ali("example.test", ali_opts), "203.0.113.10", "Ali result")
support.assertEqual(ali_opts.timeout, 3000, "Ali default timeout")
support.assertEqual(requests[1].method, "GET", "Ali method")
support.assertContains(requests[1].url, "223.5.5.5/resolve", "Ali endpoint")
support.assertEqual(requests[1].opts.adapter, 2, "Ali adapter passed through")

local tx_opts = { timeout = 1200, adapter = 1 }
support.assertEqual(httpdns.tx("example.test", tx_opts), "203.0.113.11", "Tencent result")
support.assertEqual(tx_opts.timeout, 1200, "existing timeout preserved")
support.assertContains(requests[2].url, "119.29.29.29/d?dn=", "Tencent endpoint")

ali_code, ali_body = 500, "error"
support.assertEqual(httpdns.ali("example.test"), nil, "Ali HTTP failure")
ali_code, ali_body = 200, "[]"
support.assertEqual(httpdns.ali("example.test"), nil, "Ali empty result")
tx_code, tx_body = 200, ""
support.assertEqual(httpdns.tx("example.test"), nil, "Tencent empty result")

print("httpdns tests passed")
