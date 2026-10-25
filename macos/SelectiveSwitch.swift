import AppKit
import Carbon

if CommandLine.arguments.contains("--router") { exit(Int32(RunSelectiveRouter())) }
if CommandLine.arguments.contains("--recover-input") { exit(Int32(RecoverSelectiveMappings())) }

let app=NSApplication.shared
let home=FileManager.default.homeDirectoryForCurrentUser
let support=home.appendingPathComponent("Library/Application Support/MonitorSwitch")
let profile=home.appendingPathComponent("Library/Deskflow/display-profile")
let handoff=home.appendingPathComponent(".local/bin/display-handoff")

func readState(_ name:String) -> [String:Any] {
    guard let data=try? Data(contentsOf:support.appendingPathComponent(name)),let value=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] else{return [:]};return value
}
func requestMode(_ windows:Bool) throws -> String {
    try FileManager.default.createDirectory(at:support,withIntermediateDirectories:true)
    let id=UUID().uuidString
    let data=try JSONSerialization.data(withJSONObject:["target":windows ? "windows":"mac","id":id])
    try data.write(to:support.appendingPathComponent("selective-input-command.json"),options:.atomic)
    return id
}
func command(_ executable:String,_ arguments:[String],timeout:TimeInterval=15)->(Int32,String) {
    let file=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    FileManager.default.createFile(atPath:file.path,contents:nil);defer{try? FileManager.default.removeItem(at:file)}
    guard let output=try? FileHandle(forWritingTo:file) else{return(1,"无法创建临时日志")};defer{try? output.close()}
    let p=Process();p.executableURL=URL(fileURLWithPath:executable);p.arguments=arguments;p.standardOutput=output;p.standardError=output
    do{try p.run()}catch{return(1,error.localizedDescription)}
    let deadline=Date().addingTimeInterval(timeout)
    while p.isRunning&&Date()<deadline{Thread.sleep(forTimeInterval:0.1)}
    if p.isRunning{p.terminate();Thread.sleep(forTimeInterval:0.2);if p.isRunning{kill(p.processIdentifier,SIGKILL)};p.waitUntilExit();return(124,"操作超时")}
    p.waitUntilExit();return(p.terminationStatus,(try? String(contentsOf:file,encoding:.utf8)) ?? "")
}
func routerAlive()->Bool {guard let pid=readState("selective-input-state.json")["pid"] as? Int else{return false};return kill(Int32(pid),0)==0}

final class Controller:NSObject,NSApplicationDelegate {
    var window:NSWindow!
    let state=NSTextField(wrappingLabelWithString:"正在连接…")
    let details=NSTextField(wrappingLabelWithString:"内置键盘、触控板 → 始终控制 Mac")
    let display=NSTextField(wrappingLabelWithString:"显示布局：等待状态")
    var windowsButton:NSButton!
    var macButton:NSButton!
    var busy=false
    var operation=""
    var timer:Timer?
    var statusItem:NSStatusItem!
    var handler:EventHandlerRef?
    var hotkeys:[EventHotKeyRef?]=[]

    func applicationDidFinishLaunching(_ notification:Notification) {
        window=NSWindow(contentRect:NSRect(x:0,y:0,width:510,height:445),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
        window.title="双机切换";window.center();window.isReleasedWhenClosed=false
        let stack=NSStackView();stack.orientation = .vertical;stack.alignment = .leading;stack.spacing=16;stack.translatesAutoresizingMaskIntoConstraints=false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor,constant:25),stack.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor,constant:-25),stack.topAnchor.constraint(equalTo:window.contentView!.topAnchor,constant:25)])
        let title=NSTextField(labelWithString:"外接切换，内置留在 Mac");title.font = .systemFont(ofSize:23,weight:.semibold);stack.addArrangedSubview(title)
        let caption=NSTextField(wrappingLabelWithString:"只切换 Lofree 外接键盘和 X7 外接鼠标。\nMac 自带键盘和触控板始终可用，两个指针各自控制。")
        caption.textColor = .secondaryLabelColor;stack.addArrangedSubview(caption)
        state.font = .systemFont(ofSize:13);stack.addArrangedSubview(state)
        windowsButton=NSButton(title:"外接键鼠 → Windows",target:self,action:#selector(toWindows));windowsButton.bezelStyle = .rounded
        macButton=NSButton(title:"外接键鼠 → Mac",target:self,action:#selector(toMac));macButton.bezelStyle = .rounded
        let row=NSStackView(views:[windowsButton,macButton]);row.spacing=12;stack.addArrangedSubview(row)
        details.font = .systemFont(ofSize:13);stack.addArrangedSubview(details)
        let hotkey=NSTextField(wrappingLabelWithString:"Ctrl + Option + W：外接设备交给 Windows\nCtrl + Option + M：外接设备收回 Mac\n备用收回：Ctrl + Shift + Esc")
        hotkey.font = .systemFont(ofSize:12);stack.addArrangedSubview(hotkey)
        display.font = .systemFont(ofSize:12);stack.addArrangedSubview(display)
        let note=NSTextField(wrappingLabelWithString:"切到 Windows：恢复 DP，再停 Mac 外接输出。\n回到 Mac：停用 Windows DP，再恢复 HDMI 主屏。\n内置键盘与触控板始终留在 Mac。")
        note.font = .systemFont(ofSize:12);note.textColor = .secondaryLabelColor;stack.addArrangedSubview(note)
        let permissions=NSButton(title:"输入监控权限",target:self,action:#selector(permissions));permissions.bezelStyle = .rounded
        let reconnect=NSButton(title:"重新连接",target:self,action:#selector(connect));reconnect.bezelStyle = .rounded
        let stop=NSButton(title:"立即恢复本地",target:self,action:#selector(toMac));stop.bezelStyle = .rounded
        stack.addArrangedSubview(NSStackView(views:[permissions,reconnect,stop]))
        statusItem=NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength);statusItem.button?.image=NSImage(systemSymbolName:"keyboard",accessibilityDescription:"双机切换")
        let menu=NSMenu()
        for(title,selector) in [("外接键鼠 → Windows",#selector(toWindows)),("外接键鼠 → Mac",#selector(toMac)),("打开双机切换",#selector(show))] {let item=NSMenuItem(title:title,action:selector,keyEquivalent:"");item.target=self;menu.addItem(item)}
        menu.addItem(.separator());menu.addItem(withTitle:"退出并恢复本地",action:#selector(quit),keyEquivalent:"q").target=self;statusItem.menu=menu
        installHotkeys();timer=Timer.scheduledTimer(withTimeInterval:0.5,repeats:true){[weak self] _ in self?.refresh()}
        show();connect()
    }
    func installHotkeys() {
        var spec=EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(),{_,event,context in
            guard let event=event,let context=context else{return OSStatus(eventNotHandledErr)}
            var id=EventHotKeyID()
            GetEventParameter(event,EventParamName(kEventParamDirectObject),EventParamType(typeEventHotKeyID),nil,MemoryLayout<EventHotKeyID>.size,nil,&id)
            let c=Unmanaged<Controller>.fromOpaque(context).takeUnretainedValue();c.change(id.id==1);return noErr
        },1,&spec,Unmanaged.passUnretained(self).toOpaque(),&handler)
        for(code,modifiers,id) in [(13,controlKey|optionKey,1),(46,controlKey|optionKey,2),(53,controlKey|shiftKey,3)] {
            var ref:EventHotKeyRef?;RegisterEventHotKey(UInt32(code),UInt32(modifiers),EventHotKeyID(signature:0x44535754,id:UInt32(id)),GetApplicationEventTarget(),0,&ref);hotkeys.append(ref)
        }
    }
    @objc func show(){window.makeKeyAndOrderFront(nil);app.activate(ignoringOtherApps:true)}
    func setBusy(_ value:Bool,_ message:String){busy=value;windowsButton.isEnabled = !value;state.stringValue=message}
    @objc func permissions(){show();_ = RequestSelectiveInputAccess();NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)}
    @objc func connect(){
        guard !busy else{return};operation=UUID().uuidString;let token=operation;setBusy(true,"正在启动按设备转发服务…")
        DispatchQueue.global().async {
            let network=command("/usr/local/bin/tailscale",["up","--timeout=5s","--accept-routes"],timeout:8)
            if network.0 != 0{self.finish(token,"Tailscale 未连接，请打开后重试。");return}
            let remote=command("/usr/bin/ssh",["-o","BatchMode=yes","-o","ConnectTimeout=5","x-windows","powershell -NoProfile -Command \"Start-ScheduledTask -TaskName MonitorSwitch-SelectiveInput\""],timeout:12)
            if remote.0 != 0{self.finish(token,"Windows 暂时不可达，所有设备保持本地控制。");return}
            let started=command("/bin/launchctl",["kickstart","gui/\(getuid())/local.chilltong.selective-input"])
            if started.0 != 0{self.finish(token,"按设备转发服务未启动，请检查安装。");return}
            for _ in 0..<30{if routerAlive(){self.finish(token,"服务已就绪。内置键盘和触控板始终控制 Mac。");return};Thread.sleep(forTimeInterval:0.1)}
            self.finish(token,"本地转发服务尚未就绪。");
        }
    }
    func finish(_ token:String,_ message:String){DispatchQueue.main.async{guard self.operation==token else{return};self.setBusy(false,message);self.refresh()}}
    @objc func toWindows(){change(true)}
    @objc func toMac(){change(false)}
    func change(_ windows:Bool){
        if busy&&windows{return}
        if windows && !routerAlive(){state.stringValue="转发服务未运行，请点击重新连接。";return}
        operation=UUID().uuidString;let token=operation
        let commandID:String
        do{commandID = try requestMode(windows)}catch{state.stringValue="无法写入切换请求。";return}
        setBusy(true,windows ? "正在连接 Windows，只接管选中的外接设备…":"正在恢复外接设备到 Mac…")
        DispatchQueue.global().async {
            if !windows && !routerAlive(){_ = RecoverSelectiveMappings();let result=command(handoff.path,["mac"],timeout:50);self.finish(token,result.0 == 0 ? "外接键鼠与画面已恢复到 Mac。":"键鼠已恢复，画面切换未完成。");return}
            for _ in 0..<100 {
                let s=readState("selective-input-state.json");let mode=s["mode"] as? String ?? ""
                if s["command"] as? String != commandID {Thread.sleep(forTimeInterval:0.1);continue}
                if mode==(windows ? "windows":"mac") {
                    self.finish(token,windows ? "外接键鼠控制 Windows；Mac 内置键鼠保持本地。":"外接键鼠已收回 Mac。");return
                }
                if let error=s["error"] as? String,!error.isEmpty{self.finish(token,error);return}
                Thread.sleep(forTimeInterval:0.1)
            }
            self.finish(token,"切换未完成，请查看设备状态或重新连接。")
        }
    }
    func refresh(){
        let s=readState("selective-input-state.json")
        let mode=s["mode"] as? String ?? "mac"
        details.stringValue = "外接键鼠 → \(mode=="windows" ? "Windows":mode=="connecting" ? "连接中":"Mac")\n内置键盘、触控板 → 始终控制 Mac"
        if !busy {
            if let error=s["error"] as? String,!error.isEmpty{state.stringValue=error}
            else if routerAlive(){state.stringValue=mode=="windows" ? "外接键鼠控制 Windows；内置键鼠仍控制 Mac。":"外接键鼠在 Mac，内置设备也保持本地控制。"}
        }
        let d=readState("mac-display-state.json")
        if d["verified"] as? Bool == true{display.stringValue=d["target"] as? String=="windows" ? "显示布局：Mac 仅使用内置屏幕":"显示布局：LECOO 为 Mac 主屏幕"}
        else if let error=d["error"] as? String{display.stringValue="显示布局：\(error)"}
        let video=readState("last-video-handoff.json")
        if video["inProgress"] as? Bool == true{display.stringValue="正在依次切换两台电脑的视频输出…"}
        else if video["success"] as? Bool == false,let error=video["error"] as? String{display.stringValue="画面切换未完成：\(error)"}
    }
    @objc func quit(){
        let requestID = try? requestMode(false)
        for _ in 0..<30{if readState("selective-input-state.json")["mode"] as? String=="mac"{break};Thread.sleep(forTimeInterval:0.1)}
        if !routerAlive(){_ = RecoverSelectiveMappings()}
        let args = requestID.map{["mac","--request-id",$0]} ?? ["mac"]
        _ = command(handoff.path,args,timeout:50);app.terminate(nil)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool{false}
}

if CommandLine.arguments.contains("--check"){print("routerAlive=\(routerAlive())");print(readState("selective-input-state.json"));exit(0)}
if CommandLine.arguments.contains("--switch-windows")||CommandLine.arguments.contains("--switch-mac"){
    do{_ = try requestMode(CommandLine.arguments.contains("--switch-windows"));exit(0)}catch{fputs("\(error)\n",stderr);exit(1)}
}
let controller=Controller();app.delegate=controller;app.setActivationPolicy(.regular);app.run()
