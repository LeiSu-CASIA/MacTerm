import Cocoa
import Darwin

struct SessionArchive:Codable {let format:String;let version:Int;let sessions:[Session]}

extension Session {
 func validated()throws->Session {
  if connectionKind == .rdp {return try validatedRDP()}
  if connectionKind == .vnc {return try validatedVNC()}
  if connectionKind == .ftp {return try validatedFTP()}
  if connectionKind == .telnet {return try validatedTelnet()}
  if connectionKind == .serial {
   guard !name.isEmpty,name.count<=256,(group?.count ?? 0)<=128,[name,group ?? ""].allSatisfy({$0.utf8.count<=4096 && !$0.unicodeScalars.contains(where:{$0.value<32 || $0.value==127})}),telnet==nil,ftp==nil,vnc==nil,rdp==nil,let settings=serial,host==settings.device,user.isEmpty,port==0,key.isEmpty else{throw SFTPError.message("串口会话名称或设备设置无效")};_ = try settings.validated();return self
  }
  guard serial==nil,telnet==nil,ftp==nil,vnc==nil,rdp==nil else{throw SFTPError.message("SSH 会话不能包含其他协议配置")}
  let values=[name,host,user,key,jumpHost ?? "",group ?? ""]
  guard values.allSatisfy({$0.utf8.count<=4096 && !$0.unicodeScalars.contains(where:{$0.value<32 || $0.value==127})}),!name.isEmpty,name.count<=256,(group?.count ?? 0)<=128,!host.isEmpty,!host.hasPrefix("-"),!host.contains(where:{$0.isWhitespace}),!host.contains("/"),!user.hasPrefix("-"),!user.contains(where:{$0.isWhitespace || "@:/".contains($0)}),(0...65535).contains(port),keepAlive.map({(0...3600).contains($0)}) ?? true,connectionTimeout.map({(1...600).contains($0)}) ?? true else{throw SFTPError.message("会话名称、主机、用户名、端口或超时设置无效：\(name)")}
  if let command=remoteCommand {guard command.utf8.count<=4096,!command.unicodeScalars.contains(where:{$0.value<32 || $0.value==127}) else{throw SFTPError.message("登录后命令不能超过 4096 字节或包含换行 / 控制字符")}}
  if let jump=jumpHost,!jump.isEmpty {guard !jump.contains("/"),!jump.contains(where:{$0.isWhitespace}) else{throw SFTPError.message("跳板机格式不正确")};for item in jump.split(separator:",",omittingEmptySubsequences:false){_ = try QuickConnection.parse(String(item))}}
  try TunnelDefinition.validateList(tunnels ?? []);return self
 }
 var fingerprint:String {var copy=self;copy.id=nil;copy.lastUsed=nil;copy.group=nil;copy.favorite=nil;copy.tunnels=nil;let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys];return (try? encoder.encode(copy).base64EncodedString()) ?? ""}
}

enum SessionDiskRevision:Equatable {case missing;case contents(Data)}

struct SessionStore {
 let url:URL
 static func normalize(_ source:[Session])throws->[Session] {guard source.count<=10000 else{throw SFTPError.message("会话数量不能超过 10000")};var ids=Set<UUID>();return try source.map{value in var session=try value.validated();if session.id==nil || ids.contains(session.id!) {session.id=UUID()};ids.insert(session.id!);return session}}
 static func decode(_ data:Data)throws->[Session] {
  guard data.count<=8*1024*1024 else{throw SFTPError.message("会话文件超过 8 MB")}
  let decoder=JSONDecoder()
  if let array=try? decoder.decode([Session].self,from:data){return try normalize(array)}
  let archive=try decoder.decode(SessionArchive.self,from:data);guard archive.format=="MacTerm Sessions",archive.version==1 else{throw SFTPError.message("不支持的会话文件格式或版本")};return try normalize(archive.sessions)
 }
 private func diskRevision()throws->SessionDiskRevision {
  guard FileManager.default.fileExists(atPath:url.path) else{return .missing}
  let attrs=try FileManager.default.attributesOfItem(atPath:url.path)
  guard (attrs[.size] as? NSNumber)?.intValue ?? 0 <= 8*1024*1024 else{throw SFTPError.message("会话文件超过 8 MB")}
  let data=try Data(contentsOf:url)
  guard data.count<=8*1024*1024 else{throw SFTPError.message("会话文件超过 8 MB")}
  return .contents(data)
 }
 func loadWithRevision()throws->(sessions:[Session],revision:SessionDiskRevision) {
  let revision=try diskRevision()
  switch revision {case .missing:return ([],revision);case .contents(let data):return (try Self.decode(data),revision)}
 }
 func load()throws->[Session] {try loadWithRevision().sessions}
 @discardableResult func save(_ sessions:[Session],expected:SessionDiskRevision?=nil)throws->SessionDiskRevision {
  let normalized=try Self.normalize(sessions);let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys];let data=try encoder.encode(normalized);guard data.count<=8*1024*1024 else{throw SFTPError.message("会话文件超过 8 MB，未保存")}
  let manager=FileManager.default;try manager.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
  let lock=Darwin.open(url.appendingPathExtension("lock").path,O_CREAT|O_RDWR|O_NOFOLLOW|O_CLOEXEC,0o600)
  guard lock>=0 else{throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)}
  defer{Darwin.close(lock)}
  guard flock(lock,LOCK_EX|LOCK_NB)==0 else{throw SFTPError.message("另一实例正在保存会话，请稍后重试。")}
  defer{_ = flock(lock,LOCK_UN)}
  let revision=try diskRevision()
  if let expected=expected,expected != revision {throw SFTPError.message("会话文件已被其他实例或编辑器修改，未覆盖。请先在“会话”菜单选择“重新载入会话”，再重试修改。")}
  if case .contents(let current)=revision { _ = try Self.decode(current);let backup=url.appendingPathExtension("backup");try current.write(to:backup,options:.atomic);try manager.setAttributes([.posixPermissions:0o600],ofItemAtPath:backup.path)}
  try data.write(to:url,options:.atomic);try manager.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
  return .contents(data)
 }
 static func exported(_ sessions:[Session])throws->Data {let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys];let data=try encoder.encode(SessionArchive(format:"MacTerm Sessions",version:1,sessions:normalize(sessions)));guard data.count<=8*1024*1024 else{throw SFTPError.message("导出内容超过 8 MB")};return data}
 static func merge(_ incoming:[Session],into existing:[Session])throws->(sessions:[Session],added:Int,skipped:Int) {var output=try normalize(existing);var ids=Set(output.compactMap{$0.id});var fingerprints=Set(output.map{$0.fingerprint});var added=0;var skipped=0
  for item in try normalize(incoming) {if ids.contains(item.id!) || fingerprints.contains(item.fingerprint){skipped+=1;continue};output.append(item);ids.insert(item.id!);fingerprints.insert(item.fingerprint);added+=1};guard output.count<=10000 else{throw SFTPError.message("合并后会话数量超过 10000")};return(output,added,skipped)
 }
}

final class SessionNode {
 let key:String;let title:String;let index:Int?;let group:String?;var children:[SessionNode]
 init(key:String,title:String,index:Int?=nil,group:String?=nil,children:[SessionNode]=[]){self.key=key;self.title=title;self.index=index;self.group=group;self.children=children}
}
final class SessionOutline:NSOutlineView {
 override func menu(for event:NSEvent)->NSMenu? {let row=self.row(at:convert(event.locationInWindow,from:nil));if row>=0 {selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false)}else{deselectAll(nil)};return super.menu(for:event)}
}
final class SessionBrowser:NSView,NSOutlineViewDataSource,NSOutlineViewDelegate,NSSearchFieldDelegate {
 let outline=SessionOutline();let search=NSSearchField();let sectionTitle=NSTextField(labelWithString:"会话库");let sessionCount=NSTextField(labelWithString:"");let emptyState=SessionEmptyState();var source=[Session]();var roots=[SessionNode]();var onActivate:(()->Void)?;var expanded=Set<String>();var initialized=false;var previousQuery=""
 override init(frame:NSRect){super.init(frame:frame)
  let stack=NSStackView();stack.orientation = .vertical;stack.spacing=8;stack.edgeInsets=NSEdgeInsets(top:8,left:8,bottom:0,right:8);stack.translatesAutoresizingMaskIntoConstraints=false;addSubview(stack);NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:leadingAnchor),stack.trailingAnchor.constraint(equalTo:trailingAnchor),stack.topAnchor.constraint(equalTo:topAnchor),stack.bottomAnchor.constraint(equalTo:bottomAnchor)])
  let header=NSView();sectionTitle.font = .systemFont(ofSize:11,weight:.semibold);sectionTitle.textColor=AppTheme.muted;sessionCount.font = .monospacedDigitSystemFont(ofSize:10,weight:.medium);sessionCount.textColor=AppTheme.muted;sessionCount.alignment = .right
  for label in [sectionTitle,sessionCount] {label.translatesAutoresizingMaskIntoConstraints=false;header.addSubview(label)}
  stack.addArrangedSubview(header);NSLayoutConstraint.activate([header.widthAnchor.constraint(equalTo:stack.widthAnchor,constant:-16),header.heightAnchor.constraint(equalToConstant:22),sectionTitle.leadingAnchor.constraint(equalTo:header.leadingAnchor,constant:4),sectionTitle.centerYAnchor.constraint(equalTo:header.centerYAnchor),sessionCount.trailingAnchor.constraint(equalTo:header.trailingAnchor,constant:-4),sessionCount.centerYAnchor.constraint(equalTo:header.centerYAnchor)])
  search.placeholderString="搜索会话、主机、分组";search.delegate=self;AppTheme.field(search);search.font = .systemFont(ofSize:12);stack.addArrangedSubview(search);search.widthAnchor.constraint(equalTo:stack.widthAnchor,constant:-16).isActive=true;search.heightAnchor.constraint(equalToConstant:28).isActive=true
  let scroll=NSScrollView();scroll.hasVerticalScroller=true;scroll.borderType = .noBorder;scroll.scrollerStyle = .overlay;scroll.drawsBackground=false;outline.backgroundColor=AppTheme.sidebar;outline.headerView=nil;outline.style = .sourceList;outline.backgroundColor=AppTheme.sidebar;outline.usesAlternatingRowBackgroundColors=false;let col=NSTableColumn(identifier:NSUserInterfaceItemIdentifier("session"));col.title="User sessions";col.width=225;outline.addTableColumn(col);outline.outlineTableColumn=col;outline.dataSource=self;outline.delegate=self;outline.rowHeight=37;outline.indentationPerLevel=12;outline.target=self;outline.doubleAction = #selector(activate);scroll.documentView=outline;stack.addArrangedSubview(scroll);scroll.widthAnchor.constraint(equalTo:stack.widthAnchor,constant:-16).isActive=true;scroll.setContentHuggingPriority(.init(1),for:.vertical)
  emptyState.isHidden=true;addSubview(emptyState)
 }
 override func layout(){super.layout();let searchRect=convert(search.bounds,from:search);let top=max(4,min(bounds.height-4,searchRect.minY-18));let height=min(110,max(0,top-4));emptyState.frame=NSRect(x:12,y:top-height,width:max(0,bounds.width-24),height:height);emptyState.needsLayout=true}
 required init?(coder:NSCoder){fatalError()}
 var selectedIndex:Int? {(outline.item(atRow:outline.selectedRow) as? SessionNode)?.index}
 var selectedGroup:String? {(outline.item(atRow:outline.selectedRow) as? SessionNode)?.group}
 func matches(_ session:Session)->Bool {let query=search.stringValue.trimmingCharacters(in:.whitespacesAndNewlines);return query.isEmpty || [session.name,session.host,session.user,session.group ?? ""].contains{$0.range(of:query,options:[.caseInsensitive,.diacriticInsensitive]) != nil}}
 func reload(_ sessions:[Session]){
  let old=outline.item(atRow:outline.selectedRow) as? SessionNode;let selectedKey=old?.key;let selectedID=old?.index.flatMap{source.indices.contains($0) ? source[$0].id : nil}
  let oldKeys=Set(roots.map{$0.key})
  if initialized,previousQuery.isEmpty {expanded=Set(roots.filter{outline.isItemExpanded($0)}.map{$0.key})}
  previousQuery=search.stringValue;source=sessions;sessionCount.stringValue="\(sessions.count) 个会话";roots=[];let indices=source.indices.filter{matches(source[$0])}
  func node(_ index:Int,_ key:String)->SessionNode {SessionNode(key:key+"/"+(source[index].id?.uuidString ?? String(index)),title:source[index].name,index:index,group:source[index].group)}
  let favorites=indices.filter{source[$0].favorite == true};if !favorites.isEmpty {roots.append(SessionNode(key:"favorites",title:"收藏",children:favorites.map{node($0,"favorites")}))}
  let recent=indices.filter{source[$0].lastUsed != nil}.sorted{source[$0].lastUsed!>source[$1].lastUsed!}.prefix(10);if !recent.isEmpty {roots.append(SessionNode(key:"recent",title:"最近连接",children:recent.map{node($0,"recent")}))}
  let groups=Dictionary(grouping:indices,by:{source[$0].group ?? ""});for group in groups.keys.sorted(by:{$0.localizedStandardCompare($1) == .orderedAscending}) {let key="group/"+group;let children=groups[group]!.sorted{source[$0].name.localizedStandardCompare(source[$1].name) == .orderedAscending}.map{node($0,key)};roots.append(SessionNode(key:key,title:group.isEmpty ? "我的会话" : group,group:group.isEmpty ? nil : group,children:children))}
  emptyState.isHidden = !roots.isEmpty;emptyState.update(filtered: !search.stringValue.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
  outline.reloadData();for root in roots {if !initialized || !search.stringValue.isEmpty || expanded.contains(root.key) || !oldKeys.contains(root.key){outline.expandItem(root)}};initialized=true
  for row in 0..<outline.numberOfRows {guard let node=outline.item(atRow:row) as? SessionNode else{continue};if node.key==selectedKey || (selectedKey==nil && selectedID != nil && node.index.map{source[$0].id==selectedID} == true) {outline.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false);return}};if let selectedID=selectedID {for row in 0..<outline.numberOfRows {if let node=outline.item(atRow:row) as? SessionNode,let index=node.index,source[index].id==selectedID {outline.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false);return}}};outline.deselectAll(nil)
 }
 func controlTextDidChange(_ obj:Notification){reload(source)}
 func outlineView(_ outlineView:NSOutlineView,numberOfChildrenOfItem item:Any?)->Int {(item as? SessionNode)?.children.count ?? roots.count}
 func outlineView(_ outlineView:NSOutlineView,child index:Int,ofItem item:Any?)->Any {(item as? SessionNode)?.children[index] ?? roots[index]}
 func outlineView(_ outlineView:NSOutlineView,isItemExpandable item:Any)->Bool {!(item as! SessionNode).children.isEmpty}
 func outlineView(_ outlineView:NSOutlineView,rowViewForItem item:Any)->NSTableRowView? {SessionSelectionRow()}
 func outlineView(_ outlineView:NSOutlineView,viewFor tableColumn:NSTableColumn?,item:Any)->NSView? {let node=item as! SessionNode
  let label=NSTextField(labelWithString:"")
  if let index=node.index {let s=source[index];let title=NSMutableAttributedString(string:s.name+"\n",attributes:[.font:NSFont.systemFont(ofSize:12,weight:.semibold),.foregroundColor:AppTheme.text]);title.append(NSAttributedString(string:s.connectionSummary,attributes:[.font:NSFont.monospacedSystemFont(ofSize:10,weight:.regular),.foregroundColor:AppTheme.muted]));label.attributedStringValue=title;label.toolTip="\(s.name)\n\(s.host)"}
  else {label.stringValue=node.title+"  ·  \(node.children.count)";label.font = .systemFont(ofSize:11,weight:.semibold);label.textColor=AppTheme.muted};label.lineBreakMode = .byTruncatingTail
  let row=NSView();let icon=NSImageView();icon.image=AppTheme.symbol(node.index.map{(source[$0].connectionKind == .vnc || source[$0].connectionKind == .rdp) ? "desktopcomputer" : source[$0].connectionKind == .serial ? "cable.connector" : "network"} ?? (node.key=="favorites" ? "star.fill" : node.key=="recent" ? "clock" : "folder"));icon.contentTintColor=node.index == nil ? AppTheme.muted : AppTheme.accent
  if let index=node.index {let kind=source[index].connectionKind;let symbol=kind == .ftp ? "folder" : kind == .ssh ? "server.rack" : kind == .telnet ? "network" : kind == .serial ? "cable.connector" : "desktopcomputer";let tint=kind == .ftp ? AppTheme.color(0xe6ba79) : (kind == .rdp || kind == .vnc) ? AppTheme.color(0xa9a1ee) : AppTheme.accent;icon.image=AppTheme.symbol(symbol);icon.contentTintColor=tint;AppTheme.surface(icon,tint.withAlphaComponent(0.10),radius:7);icon.imageScaling = .scaleNone;icon.image=icon.image?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize:13,weight:.medium))}
  for view in [icon,label] as [NSView] {view.translatesAutoresizingMaskIntoConstraints=false;row.addSubview(view)}
  NSLayoutConstraint.activate([icon.leadingAnchor.constraint(equalTo:row.leadingAnchor,constant:2),icon.centerYAnchor.constraint(equalTo:row.centerYAnchor),icon.widthAnchor.constraint(equalToConstant:28),icon.heightAnchor.constraint(equalToConstant:28),label.leadingAnchor.constraint(equalTo:icon.trailingAnchor,constant:9),label.trailingAnchor.constraint(equalTo:row.trailingAnchor,constant:-4),label.centerYAnchor.constraint(equalTo:row.centerYAnchor)])
  return row
 }
 func outlineView(_ outlineView:NSOutlineView,heightOfRowByItem item:Any)->CGFloat {(item as? SessionNode)?.index == nil ? 30 : 46}

 @objc func activate(){guard let node=outline.item(atRow:outline.clickedRow) as? SessionNode else{return};if node.index != nil {onActivate?()}else if outline.isItemExpanded(node){outline.collapseItem(node)}else{outline.expandItem(node)}}
}

extension AppDelegate {
 @objc func reloadSessions(){
  do {let loaded=try SessionStore(url:storage).loadWithRevision();sessions=loaded.sessions;sessionRevision=loaded.revision;sessionsLoadFailed=false;sessionBrowser.reload(sessions)}
  catch{alert("重新载入失败，当前列表已保留：\(error.localizedDescription)")}
 }
 func sessionMenu()->NSMenu {let menu=NSMenu(title:"会话");for(title,action) in [("连接",#selector(connect)),("新建 SSH 会话…",#selector(newSession)),("新建 VNC 远程桌面…",#selector(newVNCSession)),("新建 RDP 远程桌面…",#selector(newRDPSession)),("新建 Telnet 会话…",#selector(newTelnetSession)),("新建 FTP / FTPS 会话…",#selector(newFTPSession)),("新建串口会话…",#selector(newSerialSession)),("编辑…",#selector(editSession)),("复制会话",#selector(duplicateSession)),("收藏 / 取消收藏",#selector(toggleFavorite)),("移动到分组…",#selector(moveSession)),("导入会话…",#selector(importSessions)),("导入 ~/.ssh/config 别名…",#selector(importSSHConfig)),("导出全部会话…",#selector(exportSessions)),("重新载入会话",#selector(reloadSessions)),("删除会话…",#selector(deleteSession))] {let item=menu.addItem(withTitle:title,action:action,keyEquivalent:"");item.target=self};return menu}
 func installSessionMenu(_ menu:NSMenu){let item=NSMenuItem();item.submenu=sessionMenu();menu.addItem(item)}
 func mutateSessions(_ change:()->Void){let before=sessions;change();if !persist(){sessions=before;sessionBrowser.reload(sessions)}}
 @objc func duplicateSession(){guard var session=selected else{alert("请选择一个会话");return};session.id=UUID();session.name += " 副本";session.lastUsed=nil;mutateSessions{sessions.append(session)}}
 @objc func toggleFavorite(){guard let index=sessionBrowser.selectedIndex,sessions.indices.contains(index) else{return};mutateSessions{sessions[index].favorite = sessions[index].favorite != true}}
 @objc func moveSession(){guard let index=sessionBrowser.selectedIndex,sessions.indices.contains(index) else{return};let a=NSAlert();a.messageText="移动会话到分组";a.informativeText="留空移到 User sessions";a.addButton(withTitle:"移动");a.addButton(withTitle:"取消");let field=NSTextField(frame:NSRect(x:0,y:0,width:300,height:24));field.stringValue=sessions[index].group ?? "";a.accessoryView=field;guard a.runModal() == .alertFirstButtonReturn else{return};let value=field.stringValue.trimmingCharacters(in:.whitespacesAndNewlines);mutateSessions{sessions[index].group=value.isEmpty ? nil : value}}
 func recordRecent(_ session:Session)->Session {guard !sessionsLoadFailed else{return session};let before=sessions;let index:Int
  if let found=sessions.firstIndex(where:{(session.id != nil && $0.id==session.id) || $0.fingerprint==session.fingerprint}) {index=found;sessions[index].lastUsed=Date()}
  else {var recent=session;recent.id=UUID();recent.lastUsed=Date();sessions.append(recent);index=sessions.count-1}
  if !persist(){sessions=before;sessionBrowser.reload(sessions);return session};return sessions[index]
 }
 @objc func importSessions(){let panel=NSOpenPanel();panel.canChooseDirectories=false;guard panel.runModal() == .OK,let url=panel.url else{return};do {let attrs=try FileManager.default.attributesOfItem(atPath:url.path);guard (attrs[.size] as? NSNumber)?.intValue ?? 0 <= 8*1024*1024 else{throw SFTPError.message("会话文件超过 8 MB")};let incoming=try SessionStore.decode(Data(contentsOf:url));let merged=try SessionStore.merge(incoming,into:sessions);if merged.added==0 {alert("没有新增会话，跳过重复项 \(merged.skipped) 个");return};let before=sessions;sessions=merged.sessions;if persist(){alert("已导入 \(merged.added) 个会话，跳过重复项 \(merged.skipped) 个")}else{sessions=before;sessionBrowser.reload(sessions)}}catch{alert("导入失败，现有会话未更改：\(error.localizedDescription)")}}
 @objc func exportSessions(){let panel=NSSavePanel();panel.nameFieldStringValue="MacTerm-sessions.json";guard panel.runModal() == .OK,let url=panel.url else{return};do {try SessionStore.exported(sessions).write(to:url,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)}catch{alert("导出失败：\(error.localizedDescription)")}}
}
