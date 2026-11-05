import Cocoa
import Darwin

struct VNCSettings:Codable,Equatable {var viewOnly=false}
extension Session {
 func validatedVNC()throws->Session {
  guard connectionKind == .vnc,rdp==nil,let _=vnc,serial==nil,telnet==nil,ftp==nil,!name.isEmpty,name.count<=256,(group?.count ?? 0)<=128,[name,host,user,group ?? ""].allSatisfy({$0.utf8.count<=4096 && !$0.unicodeScalars.contains(where:{$0.value<32 || $0.value==127})}),!host.isEmpty,host.utf8.count<=255,!host.hasPrefix("-"),!host.contains(where:{$0.isWhitespace || "/\\@[]?#%".contains($0)}),(1...65535).contains(port),(1...600).contains(connectionTimeout ?? 15),key.isEmpty,jumpHost==nil,keepAlive==nil,x11==nil,(tunnels ?? []).isEmpty,compression==nil,forwardAgent==nil,remoteCommand==nil,commandTTY==nil else{throw SFTPError.message("VNC 会话名称、主机、端口或配置无效，不能混入 SSH 等设置")}
  if host.contains(":"){var address=in6_addr();guard inet_pton(AF_INET6,host,&address)==1 else{throw SFTPError.message("VNC IPv6 地址无效")}}
  return self
 }
 var vncDestination:String {(host.contains(":") ? "["+host+"]" : host)+":"+String(port)}
 static func quickVNC(_ input:String)throws->Session {
  guard input.hasPrefix("vnc://") else{throw SFTPError.message("输入 vnc://host:5900，不在地址中携带密码")}
  let authority=String(input.dropFirst(6));guard !authority.contains("@"),!authority.contains("/"),!authority.contains("?"),!authority.contains("#") else{throw SFTPError.message("VNC 快速地址只接受主机和端口，不接受用户名、密码或路径")}
  let parsed=try QuickConnection.parse(authority);return try Session(name:parsed.host,host:parsed.host,user:"",port:parsed.port==0 ? 5900 : parsed.port,key:"",connectionTimeout:15,kind:.vnc,vnc:VNCSettings()).validatedVNC()
 }
}
final class VNCEditor:NSWindowController,NSWindowDelegate {
 let original:Session;var result:Session?
 let name=NSTextField(),host=NSTextField(),user=NSTextField(),port=NSTextField(),group=NSTextField(),timeout=NSTextField();let viewOnly=NSButton(checkboxWithTitle:"只读模式（禁止发送键盘与鼠标输入）",target:nil,action:nil);let error=NSTextField(wrappingLabelWithString:"")
 init(session:Session){original=session;let panel=NSPanel(contentRect:NSRect(x:0,y:0,width:580,height:540),styleMask:[.titled,.closable],backing:.buffered,defer:false);super.init(window:panel);panel.title="MacTerm · VNC 远程桌面";panel.appearance=NSAppearance(named:.darkAqua);panel.backgroundColor=AppTheme.background;panel.titlebarAppearsTransparent=true;panel.delegate=self;panel.center()
  let root=NSStackView();root.orientation = .vertical;root.alignment = .leading;root.spacing=14;root.edgeInsets=NSEdgeInsets(top:24,left:26,bottom:24,right:26);root.translatesAutoresizingMaskIntoConstraints=false;panel.contentView!.addSubview(root);NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:panel.contentView!.leadingAnchor),root.trailingAnchor.constraint(equalTo:panel.contentView!.trailingAnchor),root.topAnchor.constraint(equalTo:panel.contentView!.topAnchor),root.bottomAnchor.constraint(equalTo:panel.contentView!.bottomAnchor)])
  let heading=NSTextField(labelWithString:"VNC 远程桌面");heading.font = .systemFont(ofSize:22,weight:.semibold);root.addArrangedSubview(heading)
  let hint=NSTextField(wrappingLabelWithString:"在标签页中控制远程桌面。密码在连接时输入，不写入会话文件。\n传统 VNC 不加密画面，请使用可信网络或已建立的 SSH 隧道。");hint.font = .systemFont(ofSize:12);hint.textColor=AppTheme.muted;root.addArrangedSubview(hint);hint.widthAnchor.constraint(equalTo:root.widthAnchor,constant:-52).isActive=true
  let fields=[name,host,port,user,group,timeout],values=[session.name,session.host,String(session.port),session.user,session.group ?? "",String(session.connectionTimeout ?? 15)]
  for (field,value) in zip(fields,values){field.stringValue=value;AppTheme.field(field);field.heightAnchor.constraint(equalToConstant:28).isActive=true}
  host.placeholderString="IP 地址或主机名";user.placeholderString="可选，按服务器要求输入";group.placeholderString="我的会话"
  let grid=NSGridView(views:zip(["会话名称","主机","端口","用户名","分组","连接超时（秒）"],fields).map{title,field in let label=NSTextField(labelWithString:title);label.font = .systemFont(ofSize:12);label.textColor=AppTheme.muted;return [label,field]});grid.rowSpacing=10;grid.columnSpacing=16;grid.column(at:0).width=100;grid.column(at:1).xPlacement = .fill;root.addArrangedSubview(grid);grid.widthAnchor.constraint(equalTo:root.widthAnchor,constant:-52).isActive=true
  viewOnly.state=session.vnc?.viewOnly == true ? .on : .off;root.addArrangedSubview(viewOnly);error.font = .systemFont(ofSize:11);error.textColor = .systemOrange;root.addArrangedSubview(error);error.widthAnchor.constraint(equalTo:root.widthAnchor,constant:-52).isActive=true
  let cancel=AppActionButton(title:"取消",target:self,action:#selector(cancel)),save=AppActionButton(title:"保存会话",target:self,action:#selector(save));for button in [cancel,save]{button.isBordered=false;button.widthAnchor.constraint(equalToConstant:100).isActive=true;button.heightAnchor.constraint(equalToConstant:32).isActive=true};save.restingColor=AppTheme.accent;save.contentTintColor=AppTheme.background;save.keyEquivalent="\r";cancel.keyEquivalent="\u{1b}";let spacer=NSView();spacer.setContentHuggingPriority(.init(1),for:.horizontal);let actions=NSStackView(views:[spacer,cancel,save]);actions.spacing=10;root.addArrangedSubview(actions);actions.widthAnchor.constraint(equalTo:root.widthAnchor,constant:-52).isActive=true
 }
 required init?(coder:NSCoder){fatalError()}
 func edited()throws->Session {guard let p=Int(port.stringValue),let t=Int(timeout.stringValue) else{throw SFTPError.message("端口和超时必须填写整数")};let h=host.stringValue.trimmingCharacters(in:.whitespacesAndNewlines);return try Session(name:name.stringValue.isEmpty ? h : name.stringValue,host:h,user:user.stringValue,port:p,key:"",connectionTimeout:t,id:original.id ?? UUID(),group:group.stringValue.isEmpty ? nil : group.stringValue,favorite:original.favorite,lastUsed:original.lastUsed,kind:.vnc,vnc:VNCSettings(viewOnly:viewOnly.state == .on)).validatedVNC()}
 @objc func save(){do{result=try edited();NSApp.stopModal(withCode:.OK)}catch{self.error.stringValue=error.localizedDescription}}
 @objc func cancel(){NSApp.stopModal(withCode:.cancel)}
 func run()->Session? {guard let window=window else{return nil};window.makeKeyAndOrderFront(nil);window.makeFirstResponder(name);NSApp.runModal(for:window);window.delegate=nil;close();return result}
 func windowShouldClose(_ sender:NSWindow)->Bool{cancel();return false}
}
extension AppDelegate {
 @objc func newVNCSession(){vncForm(index:nil)}
 func vncForm(index:Int?){let old=index.map{sessions[$0]} ?? Session(name:"",host:"",user:"",port:5900,key:"",connectionTimeout:15,id:UUID(),group:sessionBrowser.selectedGroup,kind:.vnc,vnc:VNCSettings());guard let value=VNCEditor(session:old).run() else{return};let before=sessions;if let index=index{sessions[index]=value}else{sessions.append(value)};if !persist(){sessions=before;sessionBrowser.reload(sessions)}}
 func openVNC(_ input:Session){do{let valid=try input.validatedVNC();let session=recordRecent(valid);let item=NSTabViewItem(identifier:UUID().uuidString);item.label=session.name;item.view=VNCWorkspace(session:session);tabs.addTabViewItem(item);tabs.selectTabViewItem(item);updateTabStrip()}catch{alert(error.localizedDescription)}}
}
