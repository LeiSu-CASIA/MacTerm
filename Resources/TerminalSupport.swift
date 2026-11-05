import Cocoa

enum TerminalOutputRead {case data(Data);case retry;case closed}

/// Reads one available PTY chunk. Owned descriptors prevent reuse after a tab closes.
final class TerminalOutput {
 private let lock=NSLock()
 private var fd:Int32
 init(fd:Int32){self.fd=dup(fd)}
 func readAvailable()->TerminalOutputRead {
  lock.lock();let target=fd>=0 ? dup(fd) : -1;lock.unlock()
  guard target>=0 else{return .closed};defer{close(target)}
  var bytes=[UInt8](repeating:0,count:65536)
  let count=Darwin.read(target,&bytes,bytes.count)
  if count>0{return .data(Data(bytes.prefix(count)))}
  if count<0 && (errno==EINTR || errno==EAGAIN){return .retry}
  return .closed
 }
 func stop(){lock.lock();if fd>=0 {close(fd);fd = -1};lock.unlock()}
 deinit{stop()}
}

/// Serializes PTY input off the UI thread. Each write owns a descriptor so closing
/// a tab cannot accidentally redirect pending input to a newly opened session.
final class TerminalInput {
 private let queue=DispatchQueue(label:"local.macterm.terminal-input")
 private let lock=NSLock()
 private var fd:Int32
 init(fd:Int32){self.fd=dup(fd)}
 func send(_ data:Data){queue.async {[self] in lock.lock();let target=fd>=0 ? dup(fd) : -1;lock.unlock();guard target>=0 else{return};defer{close(target)}
  data.withUnsafeBytes {bytes in guard let base=bytes.baseAddress else{return};var offset=0
   while offset<data.count {lock.lock();let active=fd>=0;lock.unlock();guard active else{return};let count=Darwin.write(target,base.advanced(by:offset),min(32768,data.count-offset));if count<0 {if errno==EINTR {continue};return};if count==0{return};offset+=count}
  }
 }}
 func stop(){lock.lock();if fd>=0 {close(fd);fd = -1};lock.unlock()}
 deinit{stop()}
}

struct QuickConnection {
 static func parse(_ input:String)throws->Session {
  let value=input.trimmingCharacters(in:.whitespacesAndNewlines)
  guard !value.isEmpty,!value.contains(where:{$0.isWhitespace || $0.isNewline || $0.asciiValue==0}),!value.hasPrefix("-") else{throw SFTPError.message("输入 user@host[:port]、[IPv6]:port 或 SSH 主机别名")}
  var authority=value
  if value.hasPrefix("ssh://") {authority=String(value.dropFirst(6));guard !authority.contains("/"),!authority.contains("?"),!authority.contains("#") else{throw SFTPError.message("SSH 地址不能包含路径或查询参数")}}
  let pieces=authority.split(separator:"@",omittingEmptySubsequences:false);guard pieces.count<=2,!pieces.contains(where:{$0.isEmpty}) else{throw SFTPError.message("用户名和主机格式不正确")}
  let user=pieces.count==2 ? String(pieces[0]) : "";var host=String(pieces.last!);var port=0
  if host.hasPrefix("[") {guard let end=host.firstIndex(of:"]") else{throw SFTPError.message("IPv6 地址缺少 ]")};let address=String(host[host.index(after:host.startIndex)..<end]);let suffix=String(host[host.index(after:end)...]);guard address.contains(":") else{throw SFTPError.message("方括号仅用于 IPv6 地址")};host=address;if !suffix.isEmpty {guard suffix.hasPrefix(":"),let parsed=Int(suffix.dropFirst()),(1...65535).contains(parsed) else{throw SFTPError.message("端口必须在 1–65535 之间")};port=parsed}}
  else if host.filter({$0==":"}).count==1 {let pair=host.split(separator:":",omittingEmptySubsequences:false);guard let parsed=Int(pair[1]),(1...65535).contains(parsed) else{throw SFTPError.message("端口必须在 1–65535 之间")};host=String(pair[0]);port=parsed}
  guard !user.contains(where:{":/[]?#\\".contains($0)}),!authority.unicodeScalars.contains(where:{$0.value<32 || $0.value==127}) else{throw SFTPError.message("不支持带密码或控制字符的 SSH 地址")}
  if host.contains(":") {var address=in6_addr();let raw=host.split(separator:"%",maxSplits:1).first.map(String.init) ?? "";guard inet_pton(AF_INET6,raw,&address)==1 else{throw SFTPError.message("IPv6 地址不正确")}}
  guard !host.isEmpty,!host.hasPrefix("-"),!user.hasPrefix("-"),!host.contains("/"),!host.contains("["),!host.contains("]") else{throw SFTPError.message("主机或用户名格式不正确")}
  return Session(name:value,host:host,user:user,port:port,key:"")
 }
}

extension AppDelegate {
 var activeTerminal:TerminalPane? {if let pane=tabs.selectedTabViewItem?.view as? TerminalPane{return pane};return (tabs.selectedTabViewItem?.view as? SSHWorkspace)?.terminal}
 var allTerminals:[TerminalPane] {tabs.tabViewItems.compactMap {($0.view as? TerminalPane) ?? ($0.view as? SSHWorkspace)?.terminal}}
 func installTerminalMenu(_ menu:NSMenu){let item=NSMenuItem();let terminal=NSMenu(title:"终端");item.submenu=terminal;menu.addItem(item)
  for(title,action,key) in [("新建本地终端",#selector(local),"t"),("关闭标签",#selector(closeTab),"w"),("重新连接",#selector(reconnect),"r"),("搜索终端…",#selector(findInTerminal),"f"),("导出终端文本…",#selector(exportTerminal),""),("开始输出日志…",#selector(startOutputLog),""),("停止输出日志",#selector(stopOutputLog),""),("在 Finder 显示日志",#selector(revealOutputLog),""),("SSH 隧道…",#selector(openTunnels),""),("命令宏…",#selector(openMacros),""),("停止输入录制",#selector(stopInputRecording),""),("多终端命令广播…",#selector(openBroadcast),""),("实时输入同步…",#selector(openInputSynchronization),""),("停止实时输入同步",#selector(stopInputSynchronization),""),("清除滚动记录",#selector(clearTerminal),"k"),("放大字体",#selector(largerFont),"+"),("缩小字体",#selector(smallerFont),"-"),("恢复字体大小",#selector(resetFont),"0"),("下一个标签",#selector(nextTab),"]"),("上一个标签",#selector(previousTab),"[")] {let entry=terminal.addItem(withTitle:title,action:action,keyEquivalent:key);entry.target=self}
 }
 @objc func findInTerminal(){guard NSApp.keyWindow === window else{return};activeTerminal?.web.evaluateJavaScript("showSearch()",completionHandler:nil)}
 @objc func clearTerminal(){guard NSApp.keyWindow === window else{return};activeTerminal?.web.evaluateJavaScript("terminal.clear()",completionHandler:nil)}
 func changeFont(_ size:Int){let loaded=preferencesStore.load();guard loaded.issue==nil else{alert("终端设置无法读取，请先打开“终端设置”确认并保存。");return};var value=loaded.settings;value.fontSize=min(32,max(9,size));do{try saveTerminalPreferences(value)}catch{alert(error.localizedDescription)}}
 @objc func largerFont(){guard NSApp.keyWindow === window else{return};changeFont(savedTerminalPreferences.fontSize+1)}
 @objc func smallerFont(){guard NSApp.keyWindow === window else{return};changeFont(savedTerminalPreferences.fontSize-1)}
 @objc func resetFont(){guard NSApp.keyWindow === window else{return};changeFont(14)}
 @objc func nextTab(){cycleTab(1)}
 @objc func previousTab(){cycleTab(-1)}
 func cycleTab(_ direction:Int){guard let current=tabs.selectedTabViewItem,!tabs.tabViewItems.isEmpty else{return};let index=tabs.indexOfTabViewItem(current);tabs.selectTabViewItem(at:(index+direction+tabs.tabViewItems.count)%tabs.tabViewItems.count);updateTabStrip();activeTerminal?.web.evaluateJavaScript("focusTerminal()",completionHandler:nil);(tabs.selectedTabViewItem?.view as? VNCWorkspace)?.focusDesktop();(tabs.selectedTabViewItem?.view as? RDPWorkspace)?.focusDesktop()}
 @objc func reconnect(){guard NSApp.keyWindow === window,let item=tabs.selectedTabViewItem else{return};if let rdp=item.view as? RDPWorkspace{reconnectRDP(item,rdp);return};if let vnc=item.view as? VNCWorkspace{vnc.stop();item.view=VNCWorkspace(session:vnc.session);updateTabStrip();return};if let ftp=item.view as? FTPWorkspace{ftp.login();return};if let workspace=item.view as? SSHWorkspace {guard workspace.confirmEditorClose() else{return};var session=workspace.session;session.tunnels=workspace.tunnels.definitions;workspace.stop();let socket=NSTemporaryDirectory()+"mt-"+UUID().uuidString.replacingOccurrences(of:"-",with:"").prefix(16);item.view=SSHWorkspace(session:session,args:arguments(session,sftp:false),socket:String(socket),preferences:savedTerminalPreferences)}
  else if let pane=item.view as? TerminalPane {let path=pane.launchPath,args=pane.launchArgs,serial=pane.serialSettings,telnet=pane.telnetSettings,destination=pane.telnetDestination;pane.stop();let replacement=TerminalPane(path:path,args:args,preferences:savedTerminalPreferences);replacement.serialSettings=serial;replacement.telnetSettings=telnet;replacement.telnetDestination=destination;item.view=replacement};if let pane=activeTerminal {watchLogging(pane)};updateTabStrip()
 }
 @objc func exportTerminal(){guard NSApp.keyWindow === window,let pane=activeTerminal else{return};let panel=NSSavePanel();panel.nameFieldStringValue="terminal-\(Int(Date().timeIntervalSince1970)).txt";guard panel.runModal() == .OK,let url=panel.url else{return};pane.web.evaluateJavaScript("exportText()") {[weak self] result,error in do {if let error=error {throw error};guard let text=result as? String else{throw SFTPError.message("无法读取终端记录")};try Data(text.utf8).write(to:url,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)}catch{self?.alert("导出失败：\(error.localizedDescription)")}}
 }
}

func terminalWelcome(version:String)->Data {
 Data("\r\n\u{1b}[38;2;112;222;203m  MacTerm\u{1b}[0m  \u{1b}[38;2;155;170;190m\(version)\r\n  本地终端已就绪 · ⌘T 新建标签 · ⌘F 搜索\u{1b}[0m\r\n\r\n".utf8)
}

enum AppTheme {
 static func color(_ value:UInt32)->NSColor {NSColor(srgbRed:CGFloat((value>>16)&255)/255,green:CGFloat((value>>8)&255)/255,blue:CGFloat(value&255)/255,alpha:1)}
 static let background=color(0x10141c),sidebar=color(0x171e29),terminal=color(0x10151f),surface=color(0x242f40),accent=color(0x78ddca),text=color(0xe8eef5),muted=color(0x97a8be),border=color(0x303e51),input=color(0x111823)
 static func surface(_ view:NSView,_ color:NSColor,radius:CGFloat=0){view.wantsLayer=true;view.layer?.backgroundColor=color.cgColor;view.layer?.cornerRadius=radius}
 static func field(_ field:NSTextField){field.bezelStyle = .roundedBezel;field.backgroundColor=input;field.textColor=text;field.font = .systemFont(ofSize:12);field.wantsLayer=true;field.layer?.cornerRadius=7;field.layer?.borderWidth=1;field.layer?.borderColor=border.withAlphaComponent(0.65).cgColor}
 static func action(_ button:AppActionButton,primary:Bool=false){button.isBordered=false;button.restingColor=primary ? accent : surface;button.contentTintColor=primary ? background : text;button.font = .systemFont(ofSize:12,weight:primary ? .semibold : .medium);button.heightAnchor.constraint(greaterThanOrEqualToConstant:28).isActive=true}
 static func symbol(_ name:String)->NSImage? {NSImage(systemSymbolName:name,accessibilityDescription:nil)}
}

// Opaque chrome keeps contrast predictable in both active and inactive windows.
final class AppChromeStack:NSStackView {
 override func draw(_ dirtyRect:NSRect){super.draw(dirtyRect);AppTheme.border.withAlphaComponent(0.5).setFill();NSRect(x:0,y:0,width:bounds.width,height:1).fill()}
}
final class WorkspaceBrand:NSView {
 let icon=NSImageView(),title=NSTextField(labelWithString:"MacTerm"),subtitle=NSTextField(labelWithString:"你的远程工作台")
 override init(frame:NSRect){super.init(frame:frame)
  AppTheme.surface(icon,AppTheme.accent.withAlphaComponent(0.12),radius:10);icon.image=AppTheme.symbol("terminal")?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize:19,weight:.medium));icon.contentTintColor=AppTheme.accent;icon.imageScaling = .scaleNone
  title.font = .systemFont(ofSize:19,weight:.bold);title.textColor=AppTheme.text;subtitle.font = .systemFont(ofSize:11);subtitle.textColor=AppTheme.muted
  for view in [icon,title,subtitle] as [NSView] {addSubview(view)}
 }
 required init?(coder:NSCoder){fatalError()}
 override func layout(){super.layout();icon.frame=NSRect(x:0,y:5,width:36,height:36);title.frame=NSRect(x:48,y:25,width:max(0,bounds.width-48),height:22);subtitle.frame=NSRect(x:48,y:7,width:max(0,bounds.width-48),height:17)}
}
final class SessionEmptyState:NSView {
 let icon=NSImageView(),title=NSTextField(labelWithString:""),detail=NSTextField(wrappingLabelWithString:"")
 override init(frame:NSRect){super.init(frame:frame);icon.image=AppTheme.symbol("rectangle.stack.badge.plus");icon.contentTintColor=AppTheme.muted;title.font = .systemFont(ofSize:12,weight:.semibold);title.textColor=AppTheme.text;title.alignment = .center;detail.font = .systemFont(ofSize:11);detail.textColor=AppTheme.muted;detail.alignment = .center;for view in [icon,title,detail] as [NSView] {addSubview(view)}}
 required init?(coder:NSCoder){fatalError()}
 override func hitTest(_ point:NSPoint)->NSView? {nil}
 override func layout(){super.layout();let compact=bounds.height<95;icon.isHidden=compact;detail.isHidden=bounds.height<45;icon.frame=NSRect(x:(bounds.width-26)/2,y:bounds.height-30,width:26,height:26);title.frame=NSRect(x:4,y:max(0,bounds.height-(compact ? 22 : 58)),width:bounds.width-8,height:18);detail.frame=NSRect(x:8,y:0,width:bounds.width-16,height:max(0,bounds.height-(compact ? 30 : 68)))}
 func update(filtered:Bool){title.stringValue=filtered ? "没有匹配的会话" : "还没有保存的会话";detail.stringValue=filtered ? "试试其他名称、主机或分组。" : "点击顶部「新建会话」\n或输入地址快速连接。"}
}

// Native controls retain keyboard focus and accessibility while sharing the app palette.
final class AppActionButton:NSButton {
 var restingColor:NSColor = .clear {didSet{refreshAppearance()}}
 private var hoverArea:NSTrackingArea?
 private var hovering=false
 override func updateTrackingAreas(){if let area=hoverArea {removeTrackingArea(area)};let area=NSTrackingArea(rect:.zero,options:[.mouseEnteredAndExited,.activeInKeyWindow,.inVisibleRect],owner:self,userInfo:nil);addTrackingArea(area);hoverArea=area;super.updateTrackingAreas()}
 override func mouseEntered(with event:NSEvent){hovering=true;refreshAppearance()}
 override func mouseExited(with event:NSEvent){hovering=false;refreshAppearance()}
 override var isHighlighted:Bool {didSet{refreshAppearance()}}
 override var isEnabled:Bool {didSet{refreshAppearance()}}
 private func refreshAppearance(){alphaValue=isEnabled ? 1 : 0.4;AppTheme.surface(self,isHighlighted ? (restingColor == AppTheme.accent ? AppTheme.accent.withAlphaComponent(0.7) : AppTheme.border) : hovering ? (restingColor == AppTheme.accent ? AppTheme.accent.blended(withFraction:0.12,of:.white) ?? AppTheme.accent : AppTheme.surface) : restingColor,radius:7)}
}
final class SidebarPlaceholder:NSView {
 let icon=NSImageView(),heading=NSTextField(labelWithString:""),detail=NSTextField(wrappingLabelWithString:"")
 init(rdp:Bool=false,vnc:Bool=false,ftp:Bool=false,serial:Bool,telnet:Bool=false){super.init(frame:.zero);AppTheme.surface(self,AppTheme.sidebar)
  icon.image=AppTheme.symbol((rdp || vnc) ? "desktopcomputer" : ftp ? "folder.badge.gearshape" : serial ? "cable.connector" : telnet ? "network" : "folder.badge.gearshape");icon.contentTintColor=AppTheme.accent
  heading.stringValue=rdp ? "RDP 远程桌面" : vnc ? "VNC 远程桌面" : ftp ? "FTP 文件工作区" : serial ? "串口工作区" : telnet ? "Telnet 工作区" : "远程文件";heading.font = .systemFont(ofSize:14,weight:.semibold);heading.textColor=AppTheme.text
  detail.stringValue=rdp ? "在右侧操作 Windows 等远程桌面。\n文件传输请使用 SSH 标签。" : vnc ? "在右侧操作远程桌面。\n⌘R 重新连接；文件传输使用 SSH。" : ftp ? "在右侧浏览与传输文件，\n连接时手动输入密码。" : serial ? "串口支持日志、搜索与命令宏。" : telnet ? "Telnet 支持日志、搜索与命令宏，\n不提供 SFTP 文件浏览。" : "连接 SSH 后浏览远程目录，\n也可以拖入文件上传。";detail.font = .systemFont(ofSize:12);detail.textColor=AppTheme.muted
  for view in [icon,heading,detail] as [NSView] {addSubview(view)}
 }
 required init?(coder:NSCoder){fatalError()}
 override func layout(){super.layout();let y=bounds.height-48;icon.frame=NSRect(x:18,y:y,width:26,height:26);heading.frame=NSRect(x:54,y:y+3,width:max(0,bounds.width-72),height:20);detail.frame=NSRect(x:18,y:y-64,width:max(0,bounds.width-36),height:48)}
}

// Keep source-list selection legible even when focus moves into the terminal.
final class SessionSelectionRow:NSTableRowView {
 override func drawSelection(in dirtyRect:NSRect){
  guard selectionHighlightStyle != .none else{return}
  let rect=bounds.insetBy(dx:3,dy:2)
  AppTheme.accent.withAlphaComponent(isEmphasized ? 0.16 : 0.10).setFill()
  NSBezierPath(roundedRect:rect,xRadius:7,yRadius:7).fill()
  AppTheme.accent.withAlphaComponent(0.8).setFill()
  NSBezierPath(roundedRect:NSRect(x:rect.minX,y:rect.minY+8,width:3,height:max(0,rect.height-16)),xRadius:1.5,yRadius:1.5).fill()
 }
}
