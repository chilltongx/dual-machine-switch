# 按外设转发（v0.5）

目标：外接 Lofree 键盘和 X7 鼠标可以切到 Windows；Mac 内置键盘与触控板始终在 Mac 工作。两台电脑可以同时各自操作。

## 当前验证状态

- 已停止并禁用旧的全局 Deskflow 服务，避免它把内置设备一起转发。
- 设备隔离实测通过：外接键盘按 A 三次，原始 HID 收到 3 次，但 Mac 输入框没有 A；内置键盘输入 B 三次，Mac 正常收到 3 次 B。测试映射已恢复。
- Windows 接收通道实测收到 Shift 和鼠标移动，正常关闭连接后释放输入。
- 用户已确认：实体鼠标是西伯利亚 X7，接收器接在 Mac，已经能够转发控制 Windows；Windows 上另一个接收器对应独立的迈从鼠标。v0.5 正式后台已独立启动，用户确认应用按钮使画面和 X7 一起回到 Mac。

## X7 在 Windows 上的移动速度

按用户要求，X7 的网络转发移动倍率已设为 **0.5（原来的 50%）**。Windows 接收端保留每轴的小数余量，避免低速小幅移动因取整而丢失。滚轮、按键、Mac 触控板和 Windows 上直接连接的迈从鼠标不受这项倍率影响。

配置文件：`%LOCALAPPDATA%\MonitorSwitch\mouse-gain.txt`，当前内容为 `0.5`。接收端支持热更新，后续调整无需重启。有效范围为 0.05～4.0。Windows 自身的指针加速仍会作用于最终运动，因此该数值指转发移动量的倍率。

## 使用

打开 `~/Applications/双机切换.app`。

1. Lofree 保持连接 Mac 的蓝牙档位，X7 鼠标接收器保持插在 Mac。
2. 点击「外接键鼠 → Windows」。Mac 内置键盘、触控板仍控制 Mac。
3. 用 Mac 触控板点击「外接键鼠 → Mac」，或在内置键盘按 Ctrl + Option + M。
4. 备用收回：Ctrl + Shift + Esc。外接键盘转发时也识别这组返回快捷键。

Mac 上的两个设备始终原生可用；不需要先把整台 Mac 的输入控制权收回来。键盘不必切到 Windows 接收器。保持 Mac 开机且不休眠，Windows 已登录。

显示流程见项目 README：Windows 模式先恢复 DP、发送 DP 15，再停 Mac 外接输出；Mac 模式先停 Windows DP，再重新启用 HDMI 主屏，内置屏幕作为扩展副屏。双向画面已由用户确认，应用已接入该流程。

## 实现边界

- `Router.m` 使用 IOHID 只匹配这两件已识别外设，校验产品名、传输方式、VendorID、ProductID，并排除 Built-In。没有安装全局键鼠拦截器。
- Lofree（1452/591，Bluetooth Low Energy）通过原始 HID 读取；使用 Apple 的每设备 UserKeyMapping 临时阻止它同时输入 Mac。既有映射保存后才修改，切回时恢复。
- X7 Receiver 8K（14073/43552，USB）的鼠标接口使用独占读取。Mac 触控板从不独占、不停用、不转发。
- Windows 普通桌面接收端使用 SendInput，不能保证 UAC 安全桌面、登录界面或不接受合成输入的软件。
- 鼠标运动按约 8 ms 合并转发；普通键位支持键盘重复、左右修饰键、导航键、数字区及常用媒体键。锁定键 LED 不做跨机回传。
- 任一外设断开、SSH 断开、传输积压时，恢复 Mac 本地输入，但保留当前视频布局；Windows 心跳超时会释放保持的按键和鼠标按钮。
- 不记录输入内容；日志记录连接、错误、按键／鼠标事件计数。

## 网络与后台进程

Windows 接收端仅监听 `127.0.0.1:24811`。Mac 创建 SSH 本地端口转发，经现有 `x-windows` 的 SSH 身份和 Tailscale 连接访问；没有新增对局域网或公网开放的端口。连接还使用独立的随机配对密钥。密钥文件不在应用包和源码中，不应公开。

- Mac 后台项：`~/Library/LaunchAgents/local.chilltong.selective-input.plist`
- Mac 程序模式：`双机切换.app/Contents/MacOS/DualSwitch --router`
- Windows 按需任务：`MonitorSwitch-SelectiveInput`
- Windows 接收程序：`%LOCALAPPDATA%\MonitorSwitch\SelectiveInputReceiver.exe`
- 旧 `local.chilltong.keyboard-server` 已禁用；旧 Windows `MonitorSwitch-KeyboardClient` 已停止。

配置与状态目录：`~/Library/Application Support/MonitorSwitch/`。

- `selective-input-command.json`：请求的目标。
- `selective-input-state.json`：实际状态、错误与设备事件计数。
- `selective-mapping-backup.json`：临时映射的原值；正常恢复后移除。
- `selective-token.txt`：配对密钥，权限 0600，不分享。
- `selective-input.log`：连接与恢复日志，不包含文字输入。

Windows 密钥为接收程序目录下的 `selective-token.txt`；日志为 `receiver.log`。

## 恢复与排查

点击「立即恢复本地」。如果后台已退出，应用会恢复外接键盘的原映射。

也可以用 Mac 自带键盘在终端执行：

```sh
"~/Applications/双机切换.app/Contents/MacOS/DualSwitch" --recover-input
"~/Library/Deskflow/display-profile" mac
```

设备热插拔会清除对应设备上的系统临时键位映射。内置设备始终保留，因此即使转发失败也能在 Mac 上操作恢复。

系统权限是「双机切换」的输入监控。代码更新后若旧授权签名失效，需移除旧记录，再由当前前台应用重新请求；不要修改 TCC 数据库或关闭系统保护。

## 构建

Mac：`bash macos/build-keyboard.sh`。

Windows：使用系统 .NET Framework `csc.exe` 把 `WindowsReceiver.cs` 编译为 WinExe。`--self-test` 检查 HID 映射和 SendInput 结构尺寸，不发送输入。部署后需要运行在已登录用户的交互式会话中。

早期使用标准输入／命名管道的传输试验已经弃用，正式路径为 SSH 隧道内的回环 TCP 连接。
