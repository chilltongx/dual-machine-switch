# 配置与部署

这是源码级部署说明。仓库没有收录开发机器的地址、密钥、显示器 UUID、登录账户或现成的个人安装状态。请先在本机完成可恢复的手动验证，再把流程接入日常使用。

## 1. 网络与会话

两台电脑安装并登录 Tailscale；Windows 启用 OpenSSH Server。Mac 的 SSH 配置需要一个 `x-windows` 别名，指向你的 Windows Tailscale 地址，使用密钥认证，并核对保存服务器主机密钥。

确认 `ssh x-windows` 可用。不要为了连接方便关闭 SSH 主机密钥校验。SSH 登录账户应与 Windows 正在使用的桌面账户一致。

当前应用通过 `/usr/local/bin/tailscale` 启动 Tailscale，并使用开发环境的 `--accept-routes` 参数；部署前按自己的安装位置和网络偏好调整 `macos/SelectiveSwitch.swift`。`display-handoff` 使用系统 Python 3。

## 2. 显示器配置

构建后，先用只读命令列出 Mac 显示器：

```sh
"dist/双机切换.app/Contents/Resources/display-profile" status
cp config.example.json config.json
cp windows/config.example.json windows/config.json
```

填写 Mac 配置中的 `displayUUID` 和 `displayID`。后者可使用 `uuid=<同一 UUID>`。Windows 配置的 `monitorHardwareId` 来自设备管理器的监视器硬件 ID；示例 `LEC2772` 仅适用于对应型号。

输入编号必须目视校准：从当前显示的电脑发送切换请求，看显示器实际画面，不能仅凭 API 成功或数值回读确认。`macInput` 为保留的校准字段；当前返回 Mac 流程主要通过视频输出启停完成。

复制配置到：

- Mac：`~/Library/Application Support/MonitorSwitch/config.json`
- Windows：`%LOCALAPPDATA%\MonitorSwitch\config.json`

Mac 布局偏好可写入 `mac-display-preferences.json`：

```json
{"mirrored": false}
```

表示 Mac 模式使用扩展桌面，外接为主屏，内置为副屏。

## 3. 安装运行文件

Mac 侧复制：

- `dist/双机切换.app` → `~/Applications/双机切换.app`
- 应用资源中的 `display-profile`、`m1ddc` 与 `m1ddc-LICENSE` → `~/Library/Application Support/MonitorSwitch/bin/`
- 仓库 `display-handoff` → `~/.local/bin/display-handoff`，保留可执行权限。

Windows 侧把 `scripts/build-windows.ps1` 生成的文件复制到 `%LOCALAPPDATA%\MonitorSwitch\`，包括 `SelectiveInputReceiver.exe`、`DisplayOutput.exe` 和 `VideoCommand.ps1`。

## 4. 配对密钥

生成一次随机密钥：32 个随机字节，写成 64 个十六进制字符。把同一内容保存为：

- Mac：`~/Library/Application Support/MonitorSwitch/selective-token.txt`，权限 `0600`。
- Windows：`%LOCALAPPDATA%\MonitorSwitch\selective-token.txt`，限制为该登录用户和系统可访问。

通过已核对主机密钥的 SSH/SCP 复制；不要写进源码、日志、命令行参数或提交到 GitHub。接收端仅绑定 `127.0.0.1:24811`，不需要对公网开放该端口。

## 5. Windows 后台任务

在 Windows 登录用户下创建两个按需任务，均使用 `Interactive` 登录类型、普通权限，无计划触发器：

| 任务名 | 启动内容 |
|---|---|
| `MonitorSwitch-SelectiveInput` | `%LOCALAPPDATA%\MonitorSwitch\SelectiveInputReceiver.exe` |
| `MonitorSwitch-VideoCommand` | `powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "<实际路径>\VideoCommand.ps1"` |

设置工作目录为 `%LOCALAPPDATA%\MonitorSwitch`；输入接收任务不设执行时限，并设置重复启动时忽略新实例。可用任务计划程序创建，也可使用 `New-ScheduledTaskAction`、`New-ScheduledTaskPrincipal -LogonType Interactive` 和 `Register-ScheduledTask`。

不要把显示管理或 SendInput 接收端直接跑在 SSH 的 Session 0 中：它们需要登录用户的交互式桌面。

## 6. Mac 后台项与权限

创建 `~/Library/LaunchAgents/local.chilltong.selective-input.plist`，把下面的 `MAC_USER` 替换为自己的用户名：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>local.chilltong.selective-input</string>
  <key>ProgramArguments</key><array>
    <string>/Users/MAC_USER/Applications/双机切换.app/Contents/MacOS/DualSwitch</string>
    <string>--router</string>
  </array>
  <key>RunAtLoad</key><false/>
  <key>KeepAlive</key><dict><key>Crashed</key><true/></dict>
  <key>ProcessType</key><string>Interactive</string>
</dict></plist>
```

用 `launchctl bootstrap gui/$(id -u) <plist路径>` 注册，应用会按需 `kickstart` 后台。打开应用，通过前台的「输入监控权限」按钮请求授权，在系统设置里允许当前构建。

首次测试时保留内置屏幕可用：先确认内置键鼠始终操作 Mac，再验证外接键鼠、显示切换、返回快捷键和断线释放。不要同时运行会全局捕获键鼠的旧版 Deskflow 服务。

## 7. 恢复入口

```sh
# 恢复外接键盘的原始映射
"$HOME/Applications/双机切换.app/Contents/MacOS/DualSwitch" --recover-input

# 只恢复 Mac 显示布局
"$HOME/Library/Application Support/MonitorSwitch/bin/display-profile" mac

# 恢复 Windows DP 输出
"$HOME/.local/bin/display-handoff" restore-dp
```

退出应用会主动收回外接输入并尝试恢复 Mac 视频模式。输入断线本身只释放输入，不自动改变视频模式。
