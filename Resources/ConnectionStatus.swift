import Cocoa

struct WorkspaceConnectionStatus:Equatable {
 enum Phase {case preparing,connecting,working,ready,ended,failed,closed,unknown}
 let phase:Phase;let text:String;let detail:String
 var color:NSColor {switch phase {case .ready:return AppTheme.accent;case .preparing,.connecting,.working:return AppTheme.color(0xe6ba79);case .failed:return .systemOrange;default:return AppTheme.muted}}
 static func terminal(_ pane:TerminalPane,ssh:Bool=false,authenticated:Bool=false)->Self {
  let kind=ssh ? "SSH" : pane.serialSettings != nil ? "串口" : pane.telnetSettings != nil ? "Telnet" : "本地终端"
  if pane.stopped{return Self(phase:.closed,text:kind+" 已关闭",detail:"此工作区已停止，不再接受输入。")}
  if let code=pane.exitCode{return Self(phase:code==0 ? .ended : .failed,text:kind+(code==0 ? " 已结束" : " 退出异常"),detail:"进程退出码 \(code)。终端保留输出，可按 ⌘R 重新连接或启动。")}
  if pane.receivedEOF{return Self(phase:.ended,text:kind+" 输出已关闭",detail:"正在等待所属进程退出；终端保留输出。")}
  if pane.fd<0 || pane.pid<=0{return Self(phase:.failed,text:kind+" 启动失败",detail:"无法启动所属终端进程，可按 ⌘R 重试。")}
  if pane.rendererFailed{return Self(phase:.failed,text:"终端视图不可用",detail:"终端页面加载失败或内容进程退出；连接进程可能仍在运行，可按 ⌘R 重启。")}
  if ssh && !authenticated{return Self(phase:.connecting,text:"SSH 连接 / 认证中",detail:"尚未确认本工作区的 SSH 复用主连接，请在终端完成认证或查看连接提示。")}
  if pane.serialSettings != nil && !pane.serialConnected{return Self(phase:.connecting,text:"串口正在打开",detail:pane.serialSettings!.summary)}
  if pane.telnetSettings != nil && !pane.telnetConnected{return Self(phase:.connecting,text:"Telnet 连接中",detail:pane.telnetDestination ?? "正在建立 TCP 连接。")}
  if !pane.ready{return Self(phase:.preparing,text:"终端视图加载中",detail:"所属进程正在运行，等待终端页面就绪。")}
  if pane.telnetSettings != nil{return Self(phase:.ready,text:"Telnet TCP 已连接",detail:"已建立传输连接；是否完成远端登录，请查看终端。")}
  return Self(phase:.ready,text:kind+(ssh ? " 已连接" : pane.serialSettings != nil ? " 已打开" : " 运行中"),detail:ssh ? "已确认本工作区 SSH 复用主进程；⌘R 可重新连接。" : "可在终端输入；⌘R 可重新连接或启动。")
 }
 static func workspace(_ view:NSView?)->Self {
  if let ssh=view as? SSHWorkspace{return terminal(ssh.terminal,ssh:true,authenticated:ssh.masterAuthenticated)}
  if let pane=view as? TerminalPane{return terminal(pane)}
  if let ftp=view as? FTPWorkspace {
   if ftp.stopped{return Self(phase:.closed,text:"FTP 工作区已关闭",detail:ftp.status.stringValue)}
   if ftp.hasPendingFTPUpload{return Self(phase:.preparing,text:"等待上传确认",detail:"确认目标与项目后才开始传输。")}
   if ftp.busy{return Self(phase:.working,text:"FTP 正在处理",detail:ftp.status.stringValue)}
   if ftp.lastOperationFailed{return Self(phase:.failed,text:"FTP 操作失败 / 取消",detail:ftp.status.stringValue)}
   return Self(phase:ftp.hasAuthenticated ? .ready : .preparing,text:ftp.hasAuthenticated ? "FTP 已认证 · 空闲" : "FTP 等待连接",detail:ftp.hasAuthenticated ? "最近一次操作已成功认证；FTP 按操作建立连接。" : ftp.status.stringValue)
  }
  if let vnc=view as? VNCWorkspace {let phase:Phase;switch vnc.state{case .loading:phase = .preparing;case .connecting,.authenticating:phase = .connecting;case .connected:phase = .ready;case .failed:phase = .failed;case .disconnected:phase = .ended;case .closed:phase = .closed};return Self(phase:phase,text:"VNC · "+vnc.status.stringValue,detail:vnc.status.stringValue)}
  if let rdp=view as? RDPWorkspace {let phase:Phase;switch rdp.state{case .launching:phase = .preparing;case .connecting,.verifying:phase = .connecting;case .connected:phase = .ready;case .failed:phase = .failed;case .disconnected:phase = .ended;case .closed:phase = .closed};return Self(phase:phase,text:"RDP · "+rdp.status.stringValue,detail:rdp.status.stringValue)}
  return Self(phase:.unknown,text:"工作区",detail:"")
 }
}
final class ConnectionStatusBar:NSView {
 let label=NSTextField(labelWithString:""),reconnect=AppActionButton(title:"重新连接 ⌘R",target:nil,action:nil)
 var value=WorkspaceConnectionStatus(phase:.unknown,text:"",detail:""){didSet{label.stringValue=value.text;label.textColor=value.color;toolTip=value.detail;label.toolTip=value.detail;needsDisplay=true}}
 override init(frame:NSRect){super.init(frame:frame);AppTheme.surface(self,AppTheme.background);label.font = .systemFont(ofSize:11,weight:.medium);label.lineBreakMode = .byTruncatingMiddle;addSubview(label);reconnect.isBordered=false;reconnect.font = .systemFont(ofSize:11);reconnect.contentTintColor=AppTheme.muted;reconnect.image=AppTheme.symbol("arrow.clockwise");reconnect.imagePosition = .imageLeading;reconnect.toolTip="重新连接当前标签，或重新启动本地终端（⌘R）";addSubview(reconnect)}
 required init?(coder:NSCoder){fatalError()}
 override func layout(){super.layout();label.frame=NSRect(x:25,y:6,width:max(0,bounds.width-164),height:16);reconnect.frame=NSRect(x:max(0,bounds.width-131),y:3,width:119,height:23)}
 override func draw(_ dirtyRect:NSRect){super.draw(dirtyRect);AppTheme.border.withAlphaComponent(0.5).setFill();NSRect(x:0,y:bounds.height-1,width:bounds.width,height:1).fill();value.color.setFill();NSBezierPath(ovalIn:NSRect(x:12,y:(bounds.height-6)/2,width:6,height:6)).fill()}
}
extension AppDelegate {
 func observeConnection(_ item:NSTabViewItem){let view=item.view
  let changed:()->Void = {[weak self,weak item,weak view] in guard let self=self,let item=item,item.view === view,self.tabs.indexOfTabViewItem(item) != NSNotFound else{return};self.refreshConnectionIndicators()}
  if let pane=view as? TerminalPane{pane.onConnectionChanged=changed}
  if let ssh=view as? SSHWorkspace{ssh.onConnectionChanged=changed;ssh.terminal.onConnectionChanged=changed}
  (view as? FTPWorkspace)?.onConnectionChanged=changed;(view as? VNCWorkspace)?.onConnectionChanged=changed;(view as? RDPWorkspace)?.onConnectionChanged=changed
 }
 func refreshConnectionIndicators(){
  for button in tabStrip.tabButtons {guard let item=button.tabItem else{continue};let value=WorkspaceConnectionStatus.workspace(item.view);((item.view as? TerminalPane) ?? (item.view as? SSHWorkspace)?.terminal)?.interaction.update();button.connectionStatus=value;button.toolTip=button.baseTooltip+"\n"+value.text+(value.detail.isEmpty ? "" : "\n"+value.detail);button.setAccessibilityValue(value.text)}
  if let local=tabs.selectedTabViewItem?.view as? TerminalPane,local.serialSettings==nil,local.telnetSettings==nil{connectionStatusBar.reconnect.title="重新启动 ⌘R"}else{connectionStatusBar.reconnect.title="重新连接 ⌘R"};connectionStatusBar.value=WorkspaceConnectionStatus.workspace(tabs.selectedTabViewItem?.view);connectionStatusBar.reconnect.isEnabled=tabs.selectedTabViewItem != nil && connectionStatusBar.value.phase != .unknown
 }
}
