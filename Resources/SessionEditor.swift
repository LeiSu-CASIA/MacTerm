import Cocoa

final class SessionFormBody:NSView {
 override var isFlipped:Bool {true}
 let fields:[NSTextField]
 let captions:[NSTextField]
 let sections=[NSTextField(labelWithString:"连接信息"),NSTextField(labelWithString:"连接设置"),NSTextField(labelWithString:"SSH 高级选项")]
 let x11=NSButton(checkboxWithTitle:"启用 X11 转发",target:nil,action:nil)
 let x11Hint=NSTextField(labelWithString:"需本机已安装 X Server")
 let compression=NSPopUpButton();let agent=NSPopUpButton()
 let compressionCaption=NSTextField(labelWithString:"连接压缩");let agentCaption=NSTextField(labelWithString:"Agent 转发")
 let commandTTY=NSButton(checkboxWithTitle:"为登录后命令分配终端（交互命令需要）",target:nil,action:nil)
 let commandHint=NSTextField(labelWithString:"留空沿用 SSH 配置；命令结束后该连接会关闭。")
 let browse=NSButton(title:"选择…",target:nil,action:nil)
 init(session:Session){
  let values=[session.name,session.host,session.user,session.port==0 ? "" : String(session.port),session.key,session.jumpHost ?? "",String(session.keepAlive ?? 30),String(session.connectionTimeout ?? 15),session.group ?? "",session.remoteCommand ?? ""]
  fields=values.map{NSTextField(string:$0)}
  captions=["会话名称","主机 / SSH 别名","用户名","端口","私钥文件（可选）","跳板机（可选）","保活间隔（秒，0 关闭）","连接超时（秒）","分组","登录后命令（可选）"].map{NSTextField(labelWithString:$0)}
  super.init(frame:NSRect(x:0,y:0,width:640,height:668));autoresizingMask=[.width]
  for caption in captions {caption.font = .systemFont(ofSize:12);caption.textColor = .secondaryLabelColor;addSubview(caption)}
  for field in fields {AppTheme.field(field);field.font = .systemFont(ofSize:13);field.bezelStyle = .roundedBezel;field.focusRingType = .default;field.backgroundColor=AppTheme.input;field.textColor=AppTheme.text;addSubview(field)}
  fields[0].placeholderString="例如：生产服务器";fields[1].placeholderString="IP 地址或 SSH 配置别名";fields[2].placeholderString="留空使用 SSH 配置";fields[3].placeholderString="留空使用 SSH 配置";fields[4].placeholderString="~/.ssh/id_ed25519";fields[5].placeholderString="user@gateway:22";fields[8].placeholderString="User sessions"
  for section in sections {section.font = .systemFont(ofSize:13,weight:.semibold);section.textColor=AppTheme.accent;addSubview(section)}
  x11.allowsMixedState=true;x11.state=session.x11.map{$0 ? .on : .off} ?? .mixed;x11.toolTip="横线表示沿用 SSH 配置";addSubview(x11);x11Hint.font = .systemFont(ofSize:11);x11Hint.textColor = .secondaryLabelColor;addSubview(x11Hint);addSubview(browse)
  for (control,value) in [(compression,session.compression),(agent,session.forwardAgent)] {control.addItems(withTitles:["沿用 SSH 配置","开启","关闭"]);control.selectItem(at:value.map{$0 ? 1 : 2} ?? 0);addSubview(control)}
  agent.toolTip="开启后，远端可借助本机 SSH Agent 进行认证。默认沿用 SSH 配置。"
  for label in [compressionCaption,agentCaption] {label.font = .systemFont(ofSize:12);label.textColor = .secondaryLabelColor;addSubview(label)}
  commandTTY.state=session.commandTTY == false ? .off : .on;addSubview(commandTTY);commandHint.font = .systemFont(ofSize:11);commandHint.textColor = .secondaryLabelColor;addSubview(commandHint);fields[9].placeholderString="例如：tmux new-session -A -s main"
 }
 required init?(coder:NSCoder){fatalError()}
 override func draw(_ dirtyRect:NSRect){
  for rect in [NSRect(x:0,y:0,width:bounds.width,height:226),NSRect(x:0,y:236,width:bounds.width,height:194),NSRect(x:0,y:440,width:bounds.width,height:224)] {let card=NSBezierPath(roundedRect:rect.insetBy(dx:0.5,dy:0.5),xRadius:12,yRadius:12);AppTheme.sidebar.setFill();card.fill();AppTheme.border.withAlphaComponent(0.4).setStroke();card.lineWidth=1;card.stroke()}
 }
 override func layout(){super.layout();let width=bounds.width-28;let gap:CGFloat=20;let col=(width-gap)/2;let left:CGFloat=14
  sections[0].frame=NSRect(x:left,y:12,width:width,height:20);sections[1].frame=NSRect(x:left,y:244,width:width,height:20);sections[2].frame=NSRect(x:left,y:448,width:width,height:20)
  let placements:[(Int,CGFloat,CGFloat)]=[(0,0,44),(8,col+gap,44),(1,0,108),(3,col+gap,108),(2,0,172),(4,col+gap,172),(5,0,288),(7,col+gap,288),(6,0,352),(9,0,552)]
  for(index,x,y) in placements {captions[index].frame=NSRect(x:left+x,y:y,width:col,height:18);fields[index].frame=NSRect(x:left+x,y:y+23,width:index==9 ? width : index==4 ? col-66 : col,height:28)}
  browse.frame=NSRect(x:left+width-62,y:195,width:62,height:28);x11.frame=NSRect(x:left+col+gap,y:373,width:col,height:24);x11Hint.frame=NSRect(x:left+col+gap+18,y:399,width:col-18,height:18)
  compressionCaption.frame=NSRect(x:left,y:492,width:col,height:18);compression.frame=NSRect(x:left,y:513,width:col,height:28);agentCaption.frame=NSRect(x:left+col+gap,y:492,width:col,height:18);agent.frame=NSRect(x:left+col+gap,y:513,width:col,height:28)
  commandTTY.frame=NSRect(x:left,y:611,width:width,height:24);commandHint.frame=NSRect(x:left,y:639,width:width,height:18)
 }

}
final class SessionPanelContent:NSView {
 let emblem=NSImageView();let footerLine=NSView();let heading=NSTextField(labelWithString:"");let subtitle=NSTextField(labelWithString:"保存连接信息，密码在连接时输入。")
 let scroll=NSScrollView();let error=NSTextField(wrappingLabelWithString:"")
 let save=AppActionButton(title:"保存会话",target:nil,action:nil);let cancel=AppActionButton(title:"取消",target:nil,action:nil)
 let body:SessionFormBody
 init(session:Session,isNew:Bool){body=SessionFormBody(session:session);super.init(frame:.zero);wantsLayer=true;layer?.backgroundColor=AppTheme.background.cgColor
  heading.stringValue=isNew ? "新建 SSH 会话" : "编辑 SSH 会话";heading.font = .systemFont(ofSize:22,weight:.semibold);heading.textColor=AppTheme.text;subtitle.font = .systemFont(ofSize:12);subtitle.textColor = .secondaryLabelColor
  AppTheme.surface(emblem,AppTheme.accent.withAlphaComponent(0.12),radius:13);emblem.image=AppTheme.symbol("server.rack")?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize:25,weight:.medium));emblem.contentTintColor=AppTheme.accent;emblem.imageScaling = .scaleNone;AppTheme.surface(footerLine,AppTheme.border.withAlphaComponent(0.5))
  scroll.drawsBackground=false;scroll.scrollerStyle = .overlay;scroll.contentView.drawsBackground=false;scroll.hasVerticalScroller=true;scroll.autohidesScrollers=true;scroll.documentView=body
  error.font = .systemFont(ofSize:11);error.textColor = .systemOrange
  save.isBordered=false;save.restingColor=AppTheme.accent;save.font = .systemFont(ofSize:13,weight:.semibold);save.keyEquivalent="\r";save.bezelColor = AppTheme.accent;save.contentTintColor = AppTheme.background;cancel.isBordered=false;cancel.restingColor=AppTheme.surface;cancel.contentTintColor=AppTheme.text;cancel.font = .systemFont(ofSize:13,weight:.medium);cancel.keyEquivalent="\u{1b}"
  for view in [emblem,heading,subtitle,scroll,error,footerLine,save,cancel] as [NSView] {addSubview(view)}
 }
 required init?(coder:NSCoder){fatalError()}
 override func layout(){super.layout();let width=bounds.width,height=bounds.height
  emblem.frame=NSRect(x:26,y:height-83,width:52,height:52);heading.frame=NSRect(x:94,y:height-56,width:width-120,height:30);subtitle.frame=NSRect(x:94,y:height-80,width:width-120,height:18);footerLine.frame=NSRect(x:26,y:76,width:width-52,height:1)
  scroll.frame=NSRect(x:26,y:85,width:width-52,height:max(80,height-187));body.setFrameSize(NSSize(width:scroll.contentSize.width,height:668));body.needsLayout=true
  error.frame=NSRect(x:26,y:28,width:max(150,width-270),height:42);cancel.frame=NSRect(x:width-232,y:32,width:90,height:32);save.frame=NSRect(x:width-134,y:32,width:108,height:32)
 }
}
final class SessionEditor:NSWindowController,NSWindowDelegate {
 let original:Session;let form:SessionPanelContent;var result:Session?
 init(session:Session,isNew:Bool){original=session;form=SessionPanelContent(session:session,isNew:isNew)
  let available=NSScreen.main?.visibleFrame.size ?? NSSize(width:1200,height:800)
  let panel=NSPanel(contentRect:NSRect(x:0,y:0,width:700,height:min(720,available.height-80)),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
  super.init(window:panel);panel.title="MacTerm · SSH 会话";panel.titlebarAppearsTransparent=true;panel.backgroundColor=AppTheme.background;panel.appearance=NSAppearance(named:.darkAqua);panel.minSize=NSSize(width:620,height:440);panel.contentView=form;panel.delegate=self;panel.center();form.save.target=self;form.save.action = #selector(save);form.cancel.target=self;form.cancel.action = #selector(cancel);form.body.browse.target=self;form.body.browse.action = #selector(browse)
 }
 required init?(coder:NSCoder){fatalError()}
 func run()->Session? {guard let window=window else{return nil};window.makeKeyAndOrderFront(nil);window.layoutIfNeeded();window.makeFirstResponder(form.body.fields[0]);NSApp.runModal(for:window);window.delegate=nil;window.close();return result}
 func editedSession()throws->Session {let values=form.body.fields.map{$0.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)}
  guard let keep=Int(values[6]),let timeout=Int(values[7]),values[3].isEmpty || Int(values[3]) != nil else{throw SFTPError.message("端口和时间必须填写数字")}
   return try Session(name:values[0].isEmpty ? values[1] : values[0],host:values[1],user:values[2],port:Int(values[3]) ?? 0,key:values[4],jumpHost:values[5].isEmpty ? nil : values[5],keepAlive:keep,connectionTimeout:timeout,x11:form.body.x11.state == .mixed ? nil : form.body.x11.state == .on,id:original.id ?? UUID(),group:values[8].isEmpty ? nil : values[8],favorite:original.favorite,lastUsed:original.lastUsed,tunnels:original.tunnels,compression:Self.option(form.body.compression),forwardAgent:Self.option(form.body.agent),remoteCommand:values[9].isEmpty ? nil : values[9],commandTTY:values[9].isEmpty ? nil : form.body.commandTTY.state == .on).validated()
 }
 @objc func save(){do{result=try editedSession();NSApp.stopModal(withCode:.OK)}catch{form.error.stringValue=error.localizedDescription}}
 static func option(_ control:NSPopUpButton)->Bool? {control.indexOfSelectedItem==0 ? nil : control.indexOfSelectedItem==1}
 @objc func cancel(){result=nil;NSApp.stopModal(withCode:.cancel)}
 func windowShouldClose(_ sender:NSWindow)->Bool {cancel();return false}
 @objc func browse(){guard let window=window else{return};let picker=NSOpenPanel();picker.canChooseDirectories=false;picker.message="选择 SSH 私钥文件";picker.beginSheetModal(for:window){[weak self] response in if response == .OK,let url=picker.url {self?.form.body.fields[4].stringValue=url.path}}}
}
