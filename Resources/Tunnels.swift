import Cocoa

struct TunnelDefinition:Codable,Equatable {
 enum Kind:String,Codable,CaseIterable {case local,remote,dynamic;var title:String {switch self {case .local:return "本地转发";case .remote:return "远程转发";case .dynamic:return "SOCKS 动态转发"}}}
 var id=UUID();var name:String;var kind:Kind;var listenHost:String="127.0.0.1";var listenPort:Int;var targetHost:String="127.0.0.1";var targetPort:Int=22;var autoStart=false
 static func checkedHost(_ value:String,listen:Bool)throws->String {guard !value.isEmpty,!value.hasPrefix("-"),!value.unicodeScalars.contains(where:{$0.value<33 || $0.value==127}),!value.contains(where:{"[]/@\\".contains($0)}) else{throw SFTPError.message("地址格式不正确")}
  if value.contains(":") {var address=in6_addr();let base=String(value.split(separator:"%",maxSplits:1)[0]);guard inet_pton(AF_INET6,base,&address)==1 else{throw SFTPError.message("IPv6 地址不正确")};return "[\(value)]"}
  guard value.allSatisfy({$0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0))}) else{throw SFTPError.message("地址只能填写 IP 或主机名")}
  if listen && value != "localhost" {var address=in_addr();guard inet_pton(AF_INET,value,&address)==1 else{throw SFTPError.message("监听地址请填写 IP 或 localhost")}}
  return value
 }
 func validated()throws->TunnelDefinition {guard !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,name.count<=120,!name.unicodeScalars.contains(where:{$0.value<32 || $0.value==127}),(1...65535).contains(listenPort),kind == .dynamic || (1...65535).contains(targetPort) else{throw SFTPError.message("名称不能为空，端口范围为 1–65535")};_ = try Self.checkedHost(listenHost,listen:true);if kind != .dynamic {_ = try Self.checkedHost(targetHost,listen:false)};return self}
 var bindingKey:String {"\(kind == .remote ? "remote" : "local"):\(listenPort)"}
 var summary:String {kind == .dynamic ? "\(listenHost):\(listenPort) · SOCKS5" : "\(listenHost):\(listenPort) → \(targetHost):\(targetPort)"}
 func forwardingArguments()throws->[String] {_ = try validated();let listen=try Self.checkedHost(listenHost,listen:true)+":\(listenPort)";if kind == .dynamic{return ["-D",listen]};let target=try Self.checkedHost(targetHost,listen:false)+":\(targetPort)";return [kind == .local ? "-L" : "-R",listen+":"+target]}
 static func validateList(_ values:[TunnelDefinition])throws {guard values.count<=100 else{throw SFTPError.message("每个会话最多保存 100 条隧道")};var ids=Set<UUID>(),ports=Set<String>();for value in values {_ = try value.validated();guard ids.insert(value.id).inserted,ports.insert(value.bindingKey).inserted else{throw SFTPError.message("同一会话同一侧的监听端口不能重复")}}}
}

enum TunnelCommandError:Error,LocalizedError {case uncertain;var errorDescription:String? {"操作被中断，监听状态未确认。请尝试停止或重连 SSH。"}}

struct TunnelCommand {
 enum Operation:String {case forward,cancel}
 static func arguments(_ definition:TunnelDefinition,operation:Operation,host:String,socket:String)throws->[String] {guard !host.isEmpty,!host.hasPrefix("-"),!host.unicodeScalars.contains(where:{$0.value<33 || $0.value==127}),!socket.contains("\0") else{throw SFTPError.message("SSH 控制连接参数无效")};return ["-F","/dev/null","-S",socket,"-o","BatchMode=yes","-o","ProxyCommand=/usr/bin/false","-O",operation.rawValue]+(try definition.forwardingArguments())+["--",host]}
 static func run(_ definition:TunnelDefinition,operation:Operation,host:String,socket:String)throws {let process=Process(),pipe=Pipe();process.executableURL=URL(fileURLWithPath:"/usr/bin/ssh");process.arguments=try arguments(definition,operation:operation,host:host,socket:socket);process.standardInput=FileHandle.nullDevice;process.standardOutput=pipe;process.standardError=pipe
  try process.run();let timeout=DispatchWorkItem {if process.isRunning {process.terminate()}};DispatchQueue.global().asyncAfter(deadline:.now()+20,execute:timeout);defer{timeout.cancel()}
  let data=pipe.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit();if process.terminationReason == .uncaughtSignal {throw TunnelCommandError.uncertain};guard process.terminationStatus==0 else{let message=String(decoding:data.prefix(4096),as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines);throw SFTPError.message(message.isEmpty ? "SSH 隧道操作失败（\(process.terminationStatus)）" : message)}
 }
}

enum TunnelState:Equatable {case stopped,starting,running,stopping,failed(String),uncertain(String)
 var label:String {switch self {case .stopped:return "已停止";case .starting:return "启动中…";case .running:return "监听已建立";case .stopping:return "停止中…";case .failed(let error):return "失败："+error;case .uncertain(let error):return "状态未确认："+error}}
 var active:Bool {{if case .uncertain=self {return true};return self == .running || self == .starting || self == .stopping}()}
}
final class TunnelManager {
 typealias Executor=(TunnelDefinition,TunnelCommand.Operation,String,String)throws->Void
 let executor:Executor;let host:String,socket:String;var definitions:[TunnelDefinition];private(set) var states=[UUID:TunnelState]();var onChange:(()->Void)?;private(set) var closed=false
 init(host:String,socket:String,definitions:[TunnelDefinition],executor:@escaping Executor={d,o,h,s in try TunnelCommand.run(d,operation:o,host:h,socket:s)}){self.host=host;self.socket=socket;self.definitions=definitions;self.executor=executor}
 func state(_ id:UUID)->TunnelState {states[id] ?? .stopped}
 func replace(_ definitions:[TunnelDefinition])throws {try TunnelDefinition.validateList(definitions);for old in self.definitions where state(old.id).active {guard definitions.contains(old) else{throw SFTPError.message("请先停止正在运行的隧道，再修改或删除")}};self.definitions=definitions;onChange?()}
 func start(_ id:UUID){if closed {states[id] = .failed("SSH 连接已结束，请重新连接");onChange?();return};guard let definition=definitions.first(where:{$0.id==id}),!state(id).active else{return};states[id] = .starting;onChange?();execute(definition,operation:.forward)}
 func stop(_ id:UUID){guard !closed,let definition=definitions.first(where:{$0.id==id}),(state(id) == .running || {if case .uncertain=state(id){return true};return false}()) else{return};states[id] = .stopping;onChange?();execute(definition,operation:.cancel)}
 private func execute(_ definition:TunnelDefinition,operation:TunnelCommand.Operation){DispatchQueue.global().async {[weak self] in guard let self=self else{return};let result:Result<Void,Error>=Result{try self.executor(definition,operation,self.host,self.socket)};DispatchQueue.main.async {guard !self.closed else{return};switch result {case .success:self.states[definition.id] = operation == .forward ? .running : .stopped;case .failure(let error):self.states[definition.id] = (operation == .cancel || error is TunnelCommandError) ? .uncertain(error.localizedDescription) : .failed(error.localizedDescription)};self.onChange?()}}}
 func startAutomatic(){for definition in definitions where definition.autoStart {start(definition.id)}}
 /// The owning SSH process closes all listeners when its connection ends.
 func connectionClosed(){closed=true;for item in definitions {states[item.id] = .stopped};onChange?()}
}

final class TunnelEditor:NSWindowController,NSWindowDelegate {
 let original:TunnelDefinition;let kind=NSPopUpButton();let fields:[NSTextField];let automatic=NSButton(checkboxWithTitle:"SSH 登录后自动启动",target:nil,action:nil);let explanation=NSTextField(wrappingLabelWithString:"");let error=NSTextField(wrappingLabelWithString:"");var result:TunnelDefinition?
 init(definition:TunnelDefinition){original=definition;fields=[definition.name,definition.listenHost,String(definition.listenPort),definition.targetHost,String(definition.targetPort)].map{NSTextField(string:$0)}
  let panel=NSPanel(contentRect:NSRect(x:0,y:0,width:620,height:460),styleMask:[.titled,.closable],backing:.buffered,defer:false);super.init(window:panel);panel.title="SSH 隧道配置";panel.appearance=NSAppearance(named:.darkAqua);panel.delegate=self;panel.center()
  let view=NSView(frame:NSRect(x:0,y:0,width:620,height:460));view.wantsLayer=true;view.layer?.backgroundColor=NSColor(calibratedWhite:0.13,alpha:1).cgColor;panel.contentView=view
  func caption(_ text:String,_ x:CGFloat,_ y:CGFloat,_ width:CGFloat){let label=NSTextField(labelWithString:text);label.font = .systemFont(ofSize:12);label.textColor = .secondaryLabelColor;label.frame=NSRect(x:x,y:y,width:width,height:18);view.addSubview(label)}
  caption("名称",24,416,260);fields[0].frame=NSRect(x:24,y:382,width:280,height:28);caption("转发类型",324,416,270);kind.frame=NSRect(x:324,y:382,width:272,height:28);kind.addItems(withTitles:TunnelDefinition.Kind.allCases.map{$0.title});kind.selectItem(at:TunnelDefinition.Kind.allCases.firstIndex(of:definition.kind)!);kind.target=self;kind.action = #selector(kindChanged);view.addSubview(kind)
  for(index,title,x,y,width) in [(1,"监听地址",CGFloat(24),CGFloat(346),CGFloat(280)),(2,"监听端口",324,346,272),(3,"目标地址",24,276,280),(4,"目标端口",324,276,272)] {caption(title,x,y,width);fields[index].frame=NSRect(x:x,y:y-34,width:width,height:28)}
  for field in fields {field.font = .systemFont(ofSize:13);field.bezelStyle = .roundedBezel;view.addSubview(field)}
  automatic.state=definition.autoStart ? .on : .off;automatic.frame=NSRect(x:24,y:195,width:560,height:24);view.addSubview(automatic)
  explanation.frame=NSRect(x:24,y:105,width:572,height:78);explanation.font = .systemFont(ofSize:12);explanation.textColor = .secondaryLabelColor;view.addSubview(explanation)
  error.frame=NSRect(x:24,y:22,width:350,height:64);error.font = .systemFont(ofSize:11);error.textColor = .systemOrange;view.addSubview(error)
  let cancel=NSButton(title:"取消",target:self,action:#selector(cancel));cancel.frame=NSRect(x:388,y:28,width:90,height:32);cancel.bezelStyle = .rounded;cancel.keyEquivalent="\u{1b}";view.addSubview(cancel)
  let save=NSButton(title:"保存配置",target:self,action:#selector(save));save.frame=NSRect(x:486,y:28,width:110,height:32);save.bezelStyle = .rounded;save.keyEquivalent="\r";view.addSubview(save);kindChanged()
 }
 required init?(coder:NSCoder){fatalError()}
 func run()->TunnelDefinition? {guard let window=window else{return nil};window.makeKeyAndOrderFront(nil);window.makeFirstResponder(fields[0]);NSApp.runModal(for:window);window.delegate=nil;window.close();return result}
 @objc func kindChanged(){let selected=TunnelDefinition.Kind.allCases[kind.indexOfSelectedItem];fields[3].isEnabled=selected != .dynamic;fields[4].isEnabled=selected != .dynamic
  let direction:String;switch selected {case .local:direction="本地端口 → SSH 服务器可访问的目标地址";case .remote:direction="服务器端口 → 本机可访问的目标地址；服务器需允许远程转发";case .dynamic:direction="本地 SOCKS4/5 代理，目标由使用代理的应用指定"}
  explanation.stringValue=direction+"。\n127.0.0.1 仅本机可用；0.0.0.0 允许其他设备访问。远程监听地址还受服务器 GatewayPorts 设置影响。"
 }
 @objc func save(){do {guard let listen=Int(fields[2].stringValue.trimmingCharacters(in:.whitespaces)) else{throw SFTPError.message("端口必须是数字")};let target=Int(fields[4].stringValue.trimmingCharacters(in:.whitespaces)) ?? 0;result=try TunnelDefinition(id:original.id,name:fields[0].stringValue.trimmingCharacters(in:.whitespacesAndNewlines),kind:TunnelDefinition.Kind.allCases[kind.indexOfSelectedItem],listenHost:fields[1].stringValue.trimmingCharacters(in:.whitespacesAndNewlines),listenPort:listen,targetHost:fields[3].stringValue.trimmingCharacters(in:.whitespacesAndNewlines),targetPort:target,autoStart:automatic.state == .on).validated();NSApp.stopModal(withCode:.OK)}catch{self.error.stringValue=error.localizedDescription}}
 @objc func cancel(){result=nil;NSApp.stopModal(withCode:.cancel)}
 func windowShouldClose(_ sender:NSWindow)->Bool {cancel();return false}
}

final class TunnelWindow:NSWindowController,NSTableViewDataSource,NSTableViewDelegate {
 let manager:TunnelManager;let table=NSTableView();let detail=NSTextField(wrappingLabelWithString:"");let saveDefinitions:([TunnelDefinition])->Bool
 init(manager:TunnelManager,save:@escaping([TunnelDefinition])->Bool){self.manager=manager;saveDefinitions=save;let window=NSWindow(contentRect:NSRect(x:0,y:0,width:900,height:500),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false);super.init(window:window);window.title="SSH 隧道 · "+manager.host;window.appearance=NSAppearance(named:.darkAqua);window.minSize=NSSize(width:700,height:380);window.center()
  let stack=NSStackView();stack.orientation = .vertical;stack.spacing=10;stack.edgeInsets=NSEdgeInsets(top:16,left:16,bottom:16,right:16);stack.translatesAutoresizingMaskIntoConstraints=false;window.contentView!.addSubview(stack);NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor),stack.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor),stack.topAnchor.constraint(equalTo:window.contentView!.topAnchor),stack.bottomAnchor.constraint(equalTo:window.contentView!.bottomAnchor)])
  let actions=NSStackView();for(title,action) in [("＋ 新建",#selector(add)),("编辑",#selector(edit)),("删除",#selector(remove)),("▶ 启动",#selector(start)),("■ 停止",#selector(stop))] {actions.addArrangedSubview(NSButton(title:title,target:self,action:action))};stack.addArrangedSubview(actions)
  let scroll=NSScrollView();scroll.hasVerticalScroller=true;scroll.borderType = .bezelBorder;scroll.setContentHuggingPriority(.init(1),for:.vertical);for(key,title,width) in [("name","名称",CGFloat(160)),("kind","类型",140),("address","监听 → 目标",340),("status","状态",210)] {let column=NSTableColumn(identifier:NSUserInterfaceItemIdentifier(key));column.title=title;column.width=width;table.addTableColumn(column)};table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle;for column in table.tableColumns {column.minWidth=column.identifier.rawValue == "address" ? 200 : 100;column.resizingMask=[.autoresizingMask,.userResizingMask]};table.dataSource=self;table.delegate=self;table.rowHeight=30;scroll.documentView=table;stack.addArrangedSubview(scroll);scroll.widthAnchor.constraint(equalTo:stack.widthAnchor,constant:-32).isActive=true;scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:180).isActive=true
  detail.maximumNumberOfLines=3;detail.lineBreakMode = .byTruncatingTail;detail.font = .systemFont(ofSize:12);detail.textColor = .secondaryLabelColor;stack.addArrangedSubview(detail);detail.widthAnchor.constraint(equalTo:stack.widthAnchor,constant:-32).isActive=true
  manager.onChange = {[weak self] in self?.reload()};reload()
 }
 required init?(coder:NSCoder){fatalError()}
 func reload(){let selected=selectedDefinition?.id;table.reloadData();if let selected=selected,let row=manager.definitions.firstIndex(where:{$0.id==selected}){table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false)};tableViewSelectionDidChange(Notification(name:NSTableView.selectionDidChangeNotification))}
 var selectedDefinition:TunnelDefinition? {manager.definitions.indices.contains(table.selectedRow) ? manager.definitions[table.selectedRow] : nil}
 func numberOfRows(in tableView:NSTableView)->Int {manager.definitions.count}
 func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int)->NSView? {let definition=manager.definitions[row];let text:String;switch tableColumn?.identifier.rawValue {case "name":text=definition.name;case "kind":text=definition.kind.title;case "address":text=definition.summary;default:text=manager.state(definition.id).label};let label=NSTextField(labelWithString:text);label.lineBreakMode = .byTruncatingMiddle;label.toolTip=text;return label}
 func tableViewSelectionDidChange(_ notification:Notification){if manager.closed {detail.stringValue="SSH 已断开。重连后可管理新连接的隧道。";return};if let definition=selectedDefinition{detail.stringValue=manager.state(definition.id).label+"\n"+definition.summary}else{detail.stringValue="使用当前 SSH 连接。监听建立不代表目标服务一定可达；关闭 SSH 标签会停止其全部隧道。"}}
 func update(_ definitions:[TunnelDefinition]){do {try TunnelDefinition.validateList(definitions);for existing in manager.definitions where manager.state(existing.id).active {guard definitions.contains(existing) else{throw SFTPError.message("请先停止正在运行的隧道")}};guard saveDefinitions(definitions) else{return};try manager.replace(definitions)}catch{let alert=NSAlert();alert.messageText=error.localizedDescription;alert.runModal()}}
 @objc func add(){let definition=TunnelDefinition(name:"新建隧道",kind:.local,listenPort:8080,targetPort:80);if let edited=TunnelEditor(definition:definition).run(){update(manager.definitions+[edited])}}
 @objc func edit(){guard let selected=selectedDefinition,let index=manager.definitions.firstIndex(where:{$0.id==selected.id}) else{return};guard !manager.state(selected.id).active else{return};if let edited=TunnelEditor(definition:selected).run(){var definitions=manager.definitions;definitions[index]=edited;update(definitions)}}
 @objc func remove(){guard let selected=selectedDefinition,!manager.state(selected.id).active else{return};update(manager.definitions.filter{$0.id != selected.id})}
 @objc func start(){if let definition=selectedDefinition{manager.start(definition.id)}}
 @objc func stop(){if let definition=selectedDefinition{manager.stop(definition.id)}}
}

extension AppDelegate {
 @objc func openTunnels(){guard let workspace=tabs.selectedTabViewItem?.view as? SSHWorkspace else{alert("先打开一个 SSH 会话，再管理它的隧道。");return};if workspace.tunnelWindow==nil {workspace.tunnelWindow=TunnelWindow(manager:workspace.tunnels,save:{[weak self,weak workspace] definitions in guard let self=self,let workspace=workspace,let index=self.sessions.firstIndex(where:{$0.id != nil && $0.id==workspace.session.id}) else{return false};let previous=self.sessions;self.sessions[index].tunnels=definitions;if !self.persist(){self.sessions=previous;self.sessionBrowser.reload(self.sessions);return false};return true})};workspace.tunnelWindow?.showWindow(nil);workspace.tunnelWindow?.window?.makeKeyAndOrderFront(nil)}
}
