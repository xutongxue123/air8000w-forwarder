# air8000w-forwarder

Air8000W 的短信和通话事件转发项目。设备接收短信或通话状态后，可以通过 Wi-Fi/4G 将消息转发到 Bark、钉钉、飞书或自定义 Webhook。

## 功能概览

- 短信接收、筛选和远程回复
- 来电、接通、挂断等通话事件通知
- Wi-Fi 与 4G 网络配置
- Web 管理后台
- 通知失败重试和本地历史记录

## 快速开始

### 准备

- Air8000W 开发板
- 已开通短信功能的 Nano-SIM 卡
- USB Type-C 数据线
- Luatools 烧录工具
- 2.4GHz Wi-Fi（设备不支持 5GHz）

### 1. 修改配置

打开 [`script/config.lua`](script/config.lua)，按实际环境修改：

- Wi-Fi SSID 和密码
- SIM PIN（未启用 PIN 时留空）
- Web 管理端口和登录凭据
- 需要使用的通知渠道及其密钥

完整配置项和默认值以该文件为准。公开项目时不要在其中填写真实 Wi-Fi 密码、手机号、Webhook、Token 或密钥。

### 2. 使用 Luatools 烧录

1. 选择与设备匹配的 LuatOS 固件。
2. 添加 `core/` 中的 SoC 固件文件。
3. 添加 `script/` 目录下的 Lua 文件。
4. 连接设备并开始烧录。

烧录完成后，观察串口日志，确认项目启动并且 SIM 卡已就绪。

### 3. 进入 Web 后台

设备连接 Wi-Fi 后，在串口日志或路由器 DHCP 列表中找到设备 IP，然后访问：

```text
http://设备IP
```

当前默认登录凭据为 `admin` / `admin123`，部署到实际网络前请修改密码，并且只在可信局域网中使用。

如果尚未配置 Wi-Fi，也可以向设备 SIM 卡发送短信：

```text
XTX,W,Wi-Fi名称,Wi-Fi密码
```

设备保存配置后会自动重启并尝试连接 Wi-Fi。

## 项目目录

| 路径 | 用途 |
|------|------|
| `core/` | SoC 固件资源 |
| `script/` | 需要烧录到设备的 Lua 文件和配置 |
| `tests/` | 本地 Lua 测试脚本 |
| `pic/` | 项目图片资源 |

## 注意事项

- Air8000W 的 Wi-Fi 仅支持 2.4GHz。
- Web 后台使用 HTTP Basic Auth，只建议在可信局域网中开启。
- 钉钉、飞书等通知渠道的 Webhook 和密钥属于敏感信息，不要提交到公开仓库。
- Web 后台保存网络相关配置后需要重启设备才能生效。

## 测试

安装 Lua 5.5 后，在项目根目录执行：

```text
lua tests/run_all_tests.lua
```

## 更多信息

- 详细配置：[`script/config.lua`](script/config.lua)
- 具体功能实现：[`script/`](script/)
- 测试和行为示例：[`tests/`](tests/)
- 许可证：[`LICENSE`](LICENSE)
