return {
    -- Shared by every channel whose sms_mode is "verification".
    KEYWORD_FILTER = {
        mode = "any",
        content_patterns = {
            "验证码", "校验码", "动态码", "动态密码", "注册码", "确认码",
            "取货", "取件", "取件码", "自提码", "快递柜", "驿站", "包裹",
            "[Cc][Oo][Dd][Ee]",
        },
        sender_patterns = {},
    },

    -- DNS 服务器按顺序尝试；建议至少保留两个，避免单个 DNS 不可用。
    DNS_SERVERS = { "119.29.29.29", "223.5.5.5" },
    -- 是否启用蜂窝网络 IPv6；当前转发场景使用 IPv4 即可。
    IPV6_ENABLED = false,
    -- 开机等待网络就绪的最长时间，单位毫秒；此处为 5 分钟。
    NETWORK_READY_TIMEOUT = 5 * 60 * 1000,
    -- 单次 HTTP 请求超时时间，单位毫秒；超时任务会保留并自动重试。
    HTTP_TIMEOUT = 20 * 1000,
    -- 分层日志配置。ERROR/WARN 不受 operational 和 diagnostic 开关影响。
    LOGGING = {
        -- 全局日志级别，同时影响应用、扩展库及部分 SDK 日志：DEBUG、INFO、WARN、ERROR。
        level = "INFO",
        -- 是否输出应用运行日志：启动、短信到达、任务恢复和发送成功等。
        operational = true,
        -- 详细诊断日志总开关及组件开关；默认不记录短信正文、号码、URL 或密钥。
        diagnostic = {
            enabled = false,
            -- 调试专用：开启后串口日志会输出短信号码、时间和正文；排障结束后请关闭。
            sensitive_sms = false,
            startup = false,
            network = false,
            http = false,
            notify = false,
            call = false,
            button = false,
        },
        -- 周期健康快照，可独立关闭；时间单位均为毫秒。
        health = {
            enabled = false,
            -- 项目启动 10 分钟后输出第一次健康快照。
            first_delay = 10 * 60 * 1000,
            -- 第一次以后每隔 1 小时输出一次。
            interval = 60 * 60 * 1000,
        },
    },

    -- 是否发送开机网络就绪、短信就绪等系统通知。
    BOOT_NOTIFY = true,
    -- SIM 卡 PIN；SIM 未启用 PIN 时填空字符串 ""。
    PIN_CODE = "",
    -- 无法从 SIM/网络读取本机号码时显示的备用号码；不需要时填空字符串 ""。
    FALLBACK_LOCAL_NUMBER = "",

    -- 本地 Web 管理只应在受信任的局域网中启用。
    WEB = {
        enabled = true,
        port = 80,
        username = "admin",
        password = "admin123", -- 部署前请修改；接口不会返回此密码。
    },

    -- 数据网络配置。短信始终由蜂窝模块接收，本节只决定 HTTP 通知使用哪个数据出口。
    -- 短信 Wi-Fi 管理命令。首行关键词必须完全匹配；命令格式见 README。
    SMS_WIFI_COMMAND = {
        enabled = true,
        keyword = "XTX",
    },

    NETWORK = {
        -- true：允许4G；与 wifi.enabled 组合后可形成仅4G或 Wi-Fi 优先/4G兜底。
        -- false：禁止应用使用4G数据，但不影响 SIM 注册、短信和通话。
        cellular_data_enabled = false,
        cellular_flight_mode = false,
        cellular_auto_reselect = { enabled = true, delta = 8 },
        -- Air8000W 固定使用 adapter 1 作为 4G 数据网卡。
        cellular_adapter = 1,
        -- Air8000W 固定使用 adapter 2 作为 Wi-Fi STA 网卡。
        wifi_adapter = 2,
        wifi = {
            -- 是否启用 Wi-Fi STA；Air8000W 仅支持连接 2.4 GHz Wi-Fi。
            enabled = true,
            -- Wi-Fi 名称，区分大小写。
            ssid = "",
            -- Wi-Fi 密码；开放网络可填空字符串。
            password = "",
        },
    },

    -- VoLTE 通话事件通知。程序只监听状态，不会自动接听、拨号或挂断。
    CALL = {
        -- 总开关；需要固件底层提供 CC_IND 通话状态事件。
        enabled = true,
        -- 需要转发的 CC_IND 事件；READY 和 PLAY 仅记日志，不发送远程通知。
        events = {
            INCOMINGCALL = true,     -- 来电呼入
            CONNECTED = false,       -- 电话已接通
            SPEECH_START = false,    -- 语音通话开始
            DISCONNECTED = false,    -- 通话断开
            MAKE_CALL_OK = false,    -- 拨号请求成功
            MAKE_CALL_FAILED = false,-- 拨号请求失败
            ANSWER_CALL_DONE = false,-- 接听完成
            HANGUP_CALL_DONE = false,-- 挂断完成
        },
    },

    -- 通知渠道表。bark、archive 是渠道实例名称，可自定义，但同一表内必须唯一。
    CHANNELS = {
        bark = {
            -- 渠道实现类型：Bark 推送。
            type = "bark",
            -- false 时停用此渠道，不再为它创建新任务。
            enabled = false,
            -- 短信路由：all=全部，verification=使用全局关键词过滤；停用渠道请设 enabled=false。
            sms_mode = "all",
            -- 是否接收开机、测试、健康状态等系统通知。
            system_enabled = false,
            -- 是否接收来电、接通和挂断等通话事件。
            call_enabled = true,
            -- Bark 服务地址，程序会自动追加 /push。
            api = "https://api.day.app",
            -- Bark 设备密钥，请填写 Bark App 中生成的 key。
            key = "",
            -- Bark 通知分组名称。
            group = "AIR8000W",
            -- 短信模板；支持 {message_id}、{kind}、{sender}、{content}、{received_at}、{device_info}。
            sms_template = "短信通知\n内容: {content}\n时间: {received_at}",
            call_template = "电话通知\n状态: {call_status}\n时间: {received_at}",
            system_template = "时间: {received_at}\n内容: {content}\n{device_info}",
            sms_title_template = "{sender}",
            call_title_template = "{sender}",
            system_title_template = "【系统通知】",
        },
        dingtalk = {
            -- 渠道实现类型：钉钉自定义机器人。
            type = "dingtalk",
            -- false 时停用此渠道，不再为它创建新任务。
            enabled = false,
            -- all 表示归档全部短信，避免普通短信被遗漏。
            sms_mode = "all",
            -- 是否接收开机、测试、健康状态等系统通知。
            system_enabled = true,
            -- 是否接收来电、接通和挂断等通话事件。
            call_enabled = true,
            -- 钉钉机器人完整 Webhook，包含 access_token；属于敏感信息，请勿公开。
            webhook = "",
            -- 钉钉机器人加签密钥；属于敏感信息，请勿公开。
            secret = "",
            -- true 时强制要求 secret 非空；加签发送会等待 NTP 对时完成后再执行。
            require_signature = true,
            -- 短信模板；支持 {message_id}、{kind}、{sender}、{content}、{received_at}、{device_info}。
            sms_template = "短信通知\n内容: {content}\n时间: {received_at}",
            call_template = "电话通知\n状态: {call_status}\n时间: {received_at}",
            system_template = "时间: {received_at}\n内容: {content}\n{device_info}",
            sms_title_template = "{sender}",
            call_title_template = "{sender}",
            system_title_template = "【系统通知】",
        },
        feishu = {
            type = "feishu",
            enabled = false,
            sms_mode = "all",
            system_enabled = true,
            call_enabled = true,
            webhook = "",
            -- 飞书机器人签名密钥；属于敏感信息，请勿公开。
            secret = "",
            -- true 时强制要求 secret 非空；加签发送会等待 NTP 对时完成后再执行。
            require_signature = true,
            -- 短信模板；支持 {message_id}、{kind}、{sender}、{content}、{received_at}、{device_info}。
            sms_template = "短信通知\n内容: {content}\n时间: {received_at}",
            call_template = "电话通知\n状态: {call_status}\n时间: {received_at}",
            system_template = "时间: {received_at}\n内容: {content}\n{device_info}",
            sms_title_template = "{sender}",
            call_title_template = "{sender}",
            system_title_template = "【系统通知】",
        },
        webhook = {
            type = "webhook",
            enabled = false,
            sms_mode = "all",
            system_enabled = true,
            call_enabled = true,
            url = "",
            headers = {},
            -- 短信模板；会作为 JSON 的 content 字段发送。
            sms_template = "短信通知\n内容: {content}\n时间: {received_at}",
            call_template = "电话通知\n状态: {call_status}\n时间: {received_at}",
            system_template = "时间: {received_at}\n内容: {content}\n{device_info}",
            sms_title_template = "{sender}",
            call_title_template = "{sender}",
            system_title_template = "【系统通知】",
        },
    },

}
