import Cocoa

private func u32(_ n:UInt32)->Data {var v=n.bigEndian;return Data(bytes:&v,count:4)}
private func u64(_ n:UInt64)->Data {var v=n.bigEndian;return Data(bytes:&v,count:8)}
private func str(_ s:Data)->Data {u32(UInt32(s.count))+s}
private func str(_ s:String)->Data {str(Data(s.utf8))}
private struct Packet {
 var data:Data;var offset=0
 mutating func take(_ n:Int)throws->Data {guard n>=0,offset+n<=data.count else{throw SFTPError.message("服务器返回了无效数据")};defer{offset+=n};return data.subdata(in:offset..<offset+n)}
 mutating func byte()throws->UInt8 {try take(1)[0]}
 mutating func int()throws->UInt32 {try take(4).reduce(0){($0<<8)|UInt32($1)}}
 mutating func long()throws->UInt64 {try take(8).reduce(0){($0<<8)|UInt64($1)}}
 mutating func string()throws->Data {try take(Int(try int()))}
 mutating func text()throws->String {String(decoding:try string(),as:UTF8.self)}
 mutating func attrs()throws->(UInt64,UInt32) {let value=try detailedAttrs();return(value.size,value.mode)}
 mutating func detailedAttrs()throws->RemoteAttributes {
  let flags=try int();var value=RemoteAttributes();value.sizeAvailable=false
  if flags&1 != 0 {value.size=try long();value.sizeAvailable=true}
  if flags&2 != 0 {value.uid=try int();value.gid=try int()}
  if flags&4 != 0 {value.mode=try int()}
  if flags&8 != 0 {value.accessed=Date(timeIntervalSince1970:TimeInterval(try int()));value.modified=Date(timeIntervalSince1970:TimeInterval(try int()))}
  if flags&0x80000000 != 0 {let count=try int();guard count<10000 else{throw SFTPError.message("属性过多")};for _ in 0..<count {_ = try string();_ = try string()}}
  return value
 }
}
enum SFTPError:Error,LocalizedError {case message(String);var errorDescription:String? {switch self {case .message(let s):return s}}}
struct RemoteAttributes {
 var size:UInt64=0;var sizeAvailable=true;var mode:UInt32=0;var uid:UInt32?;var gid:UInt32?;var accessed:Date?;var modified:Date?
 var symbolicLink:Bool {mode&0o170000 == 0o120000}
 var permissionEditable:Bool {mode&0o170000 == 0o100000 || mode&0o170000 == 0o040000}
 func samePermissionRevision(as other:RemoteAttributes)->Bool {mode==other.mode && sizeAvailable==other.sizeAvailable && size==other.size && modified==other.modified && uid==other.uid && gid==other.gid}
 var kind:String {switch mode&0o170000 {case 0o040000:return "文件夹";case 0o100000:return "普通文件";case 0o120000:return "符号链接";case 0:return "服务器未提供类型";default:return "特殊文件"}}
 var permissions:String {mode == 0 ? "服务器未提供" : String(format:"%04o",mode&0o7777)}
}
struct RemoteFile {let name:String;let size:UInt64;let directory:Bool;var mode:UInt32=0;var modified:Date?;var sizeAvailable:Bool=true;var symbolicLink:Bool {mode&0o170000 == 0o120000}}
enum RemoteFileSort:Int {case name,reverseName,size,modified}
enum RemoteFileBrowser {
 static func visible(_ entries:[RemoteFile],query:String,showHidden:Bool,sort:RemoteFileSort)->[RemoteFile] {
  entries.filter{(showHidden || !$0.name.hasPrefix(".")) && (query.isEmpty || $0.name.range(of:query,options:[.caseInsensitive,.diacriticInsensitive]) != nil)}.sorted{a,b in
   if a.directory != b.directory {return a.directory}
   switch sort {
   case .size:if a.size != b.size {return a.size>b.size}
   case .modified:if a.modified != b.modified {return (a.modified ?? .distantPast)>(b.modified ?? .distantPast)}
   case .reverseName:return a.name.localizedStandardCompare(b.name) == .orderedDescending
   case .name:break
   }
   return a.name.localizedStandardCompare(b.name) == .orderedAscending
  }
 }
}
enum RemoteEntryOpenMode {case automatic,directory,text}
enum RemoteEntryContent {case directory(String,[RemoteFile]),text(String,RemoteText)}
final class SFTPClient {
 let process=Process();let input=Pipe();let output=Pipe();var sequence:UInt32=0;var deadline:DispatchWorkItem?;var progress:((UInt64,UInt64?)->Void)?;var extensionVersions=[String:Set<String>]()
 init(command:String="/usr/bin/ssh",arguments:[String],onStart:((SFTPClient)->Void)?=nil)throws {
  signal(SIGPIPE,SIG_IGN)
  process.executableURL=URL(fileURLWithPath:command);process.arguments=arguments;process.standardInput=input;process.standardOutput=output;process.standardError=FileHandle.nullDevice
  try process.run();onStart?(self)
  do {try send(Data([1])+u32(3));var response=try receive();guard try response.byte()==2,try response.int()==3 else{throw SFTPError.message("服务器不支持 SFTP v3")};while response.offset<response.data.count {let name=try response.text();let version=try response.text();extensionVersions[name,default:[]].insert(version)}}catch{close();throw error}
 }
 func supportsExtension(_ name:String,version:String="1")->Bool {extensionVersions[name]?.contains(version) == true}
 func close(){deadline?.cancel();try? input.fileHandleForWriting.close();try? output.fileHandleForReading.close();if process.isRunning {process.terminate()}}
 deinit {close()}
 private func send(_ data:Data)throws{deadline?.cancel();let p=process;let timeout=DispatchWorkItem {if p.isRunning {p.terminate()}};deadline=timeout;DispatchQueue.global().asyncAfter(deadline:.now()+60,execute:timeout);try input.fileHandleForWriting.write(contentsOf:u32(UInt32(data.count))+data)}
 private func read(_ count:Int)throws->Data {var result=Data();while result.count<count {guard let d=try output.fileHandleForReading.read(upToCount:count-result.count),!d.isEmpty else{throw SFTPError.message("SFTP 连接中断或超时，请检查 SSH 是否已登录")};result.append(d)};return result}
 private func receive()throws->Packet {var header=Packet(data:try read(4));let n=try header.int();guard n>0,n<=16*1024*1024 else{throw SFTPError.message("无效的 SFTP 数据包")};return Packet(data:try read(Int(n)))}
 private func request(_ type:UInt8,_ body:Data)throws->(UInt8,Packet){sequence+=1;try send(Data([type])+u32(sequence)+body);var packet=try receive();let kind=try packet.byte();guard try packet.int()==sequence else{throw SFTPError.message("SFTP 请求序号不匹配")};return(kind,packet)}
 private func status(_ packet:inout Packet,allowEOF:Bool=false)throws->Bool {let code=try packet.int();let message=try packet.text();if code==0{return true};if code==1 && allowEOF{return false};throw SFTPError.message("SFTP \(code)：\(message)")}
 private func handle(_ type:UInt8,_ body:Data)throws->Data {let(kind,p)=try request(type,body);var packet=p;if kind==101 {_ = try status(&packet)};guard kind==102 else{throw SFTPError.message("无法打开远程文件或目录")};return try packet.string()}
 private func closeHandle(_ h:Data)throws{let(kind,p)=try request(4,str(h));var packet=p;guard kind==101 else{throw SFTPError.message("关闭文件失败")};_ = try status(&packet)}
 func canonical(_ path:String)throws->String {let(kind,p)=try request(16,str(path));var packet=p;if kind==101 {_ = try status(&packet)};guard kind==104,try packet.int()>0 else{throw SFTPError.message("无法解析远程路径")};let raw=try packet.string();guard raw.count<=65536,let path=String(data:raw,encoding:.utf8),!path.isEmpty,!path.contains("\0") else{throw SFTPError.message("服务器返回了无效的规范路径")};return path}
 func readLink(_ path:String)throws->String {
  let(kind,p)=try request(19,str(path));var packet=p;if kind==101 {_ = try status(&packet)}
  guard kind==104,try packet.int()==1 else{throw SFTPError.message("服务器返回了无效的链接目标")}
  let raw=try packet.string();guard raw.count<=65536,let target=String(data:raw,encoding:.utf8),!target.isEmpty,!target.contains("\0") else{throw SFTPError.message("链接目标为空、编码无效或过长")}
  _ = try packet.string();_ = try packet.detailedAttrs();guard packet.offset==packet.data.count else{throw SFTPError.message("链接目标响应包含多余数据")};return target
 }
 func openEntry(_ path:String,mode:RemoteEntryOpenMode = .automatic)throws->RemoteEntryContent {
  let destination=try canonical(path);let attributes=try fileAttributes(destination,followLinks:false)
  switch attributes.mode&0o170000 {
  case 0o040000:guard mode != .text else{throw SFTPError.message("目标是文件夹，请使用打开目录")};return .directory(destination,try list(destination))
  case 0o100000:guard mode != .directory else{throw SFTPError.message("链接目标不是文件夹，可使用编辑文本打开普通文本文件")};let data=try readFile(destination,limit:RemoteText.maximumBytes);return .text(destination,try RemoteText(data:data))
  default:throw SFTPError.message("目标不是可浏览的文件夹或普通文本文件，可能是无效链接或特殊设备")
  }
 }
 func list(_ path:String)throws->[RemoteFile] {let h=try handle(11,str(path));defer{try? closeHandle(h)};var entries=[RemoteFile]();while true {let(kind,p)=try request(12,str(h));var packet=p;if kind==101 {if try !status(&packet,allowEOF:true){break}};guard kind==104 else{throw SFTPError.message("无法读取目录")};let count=try packet.int();guard count<100000 else{throw SFTPError.message("目录条目过多")};for _ in 0..<count {let rawName=try packet.string();guard let name=String(data:rawName,encoding:.utf8),!name.isEmpty,!name.contains("/"),!name.contains("\0") else{throw SFTPError.message("服务器返回了无效或不支持编码的文件名")};_ = try packet.string();let attributes=try packet.detailedAttrs();if name != "." && name != ".." {entries.append(RemoteFile(name:name,size:attributes.size,directory:attributes.mode&0o170000 == 0o040000,mode:attributes.mode,modified:attributes.modified))}}};return entries.sorted{if $0.directory != $1.directory{return $0.directory};return $0.name.localizedStandardCompare($1.name) == .orderedAscending}}
 func download(_ remote:String,to local:URL)throws {let h=try handle(3,str(remote)+u32(1)+u32(0));defer{try? closeHandle(h)};let temporary=local.deletingLastPathComponent().appendingPathComponent(".macterm-"+UUID().uuidString);guard FileManager.default.createFile(atPath:temporary.path,contents:nil,attributes:[.posixPermissions:0o600]) else{throw SFTPError.message("无法创建下载暂存文件")};defer{try? FileManager.default.removeItem(at:temporary)};let file=try FileHandle(forWritingTo:temporary);defer{try? file.close()};var offset:UInt64=0
  while true {let(kind,p)=try request(5,str(h)+u64(offset)+u32(32768));var packet=p;if kind==101 {if try !status(&packet,allowEOF:true){break}};guard kind==103 else{throw SFTPError.message("下载失败")};let chunk=try packet.string();guard !chunk.isEmpty else{throw SFTPError.message("服务器返回了空文件块")};try file.write(contentsOf:chunk);offset+=UInt64(chunk.count);progress?(offset,nil)}
  try file.close();if FileManager.default.fileExists(atPath:local.path){_ = try FileManager.default.replaceItemAt(local,withItemAt:temporary)}else{try FileManager.default.moveItem(at:temporary,to:local)}
 }
 func attributes(_ path:String,followLinks:Bool=true)throws->(UInt64,UInt32) {let value=try fileAttributes(path,followLinks:followLinks);return(value.size,value.mode)}
 func fileAttributes(_ path:String,followLinks:Bool=false)throws->RemoteAttributes {let(kind,p)=try request(followLinks ? 17 : 7,str(path));var packet=p;if kind==101 {_ = try status(&packet)};guard kind==105 else{throw SFTPError.message("读取文件属性失败")};return try packet.detailedAttrs()}
 func readFile(_ path:String,limit:Int)throws->Data {
  let(size,mode)=try attributes(path);guard mode&0o170000 == 0o100000,size<=UInt64(limit) else{throw SFTPError.message("只能编辑不超过 \(limit/1024/1024) MB 的普通文本文件")}
  let h=try handle(3,str(path)+u32(1)+u32(0));defer{try? closeHandle(h)};var result=Data()
  while true {let(kind,p)=try request(5,str(h)+u64(UInt64(result.count))+u32(UInt32(min(32768,limit-result.count+1))));var packet=p;if kind==101 {if try !status(&packet,allowEOF:true){break}};guard kind==103 else{throw SFTPError.message("读取文本文件失败")};let chunk=try packet.string();guard !chunk.isEmpty,result.count+chunk.count<=limit else{throw SFTPError.message("文件在读取时超过大小限制")};result.append(chunk)}
  return result
 }
 func saveText(_ data:Data,to path:String,expected:Data)throws {
  guard data.count<=RemoteText.maximumBytes else{throw SFTPError.message("保存内容超过 4 MB 限制")}
  let temporary=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("macterm-editor-"+UUID().uuidString)
  try data.write(to:temporary,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:temporary.path);defer{try? FileManager.default.removeItem(at:temporary)}
  try upload(temporary,to:path,replacing:expected)
 }

 func setPermissions(_ path:String,to mode:UInt32,expected:RemoteAttributes)throws {
  guard mode<=0o7777 else{throw SFTPError.message("权限超出 0000–7777 范围")}
  guard supportsExtension("lsetstat@openssh.com") else{throw SFTPError.message("此服务器不支持安全修改权限")}
  let current=try fileAttributes(path)
  guard current.permissionEditable else{throw SFTPError.message("只能修改普通文件或文件夹权限，符号链接和特殊文件不会修改")}
  guard current.samePermissionRevision(as:expected) else{throw SFTPError.message("远程属性已变化，请重新打开属性窗口后再修改")}
  try command(200,str("lsetstat@openssh.com")+str(path)+u32(4)+u32(mode))
  let after=try fileAttributes(path);var desired=current;desired.mode=(current.mode & ~UInt32(0o7777))|mode
  guard after.samePermissionRevision(as:desired) else{throw SFTPError.message("操作后的属性与预期不符，项目可能被替换或权限未被完整应用；请重新查看当前属性")}

 }
 private func command(_ type:UInt8,_ body:Data)throws {let(kind,p)=try request(type,body);var packet=p;guard kind==101 else{throw SFTPError.message("服务器返回了无效操作结果")};_ = try status(&packet)}
 // SFTP v3 OPEN: WRITE | CREAT | EXCL, deliberately without TRUNC.
 // Do not unlink on failure: a path may have been replaced by another client.
 func createFile(_ path:String)throws {
  guard !path.isEmpty,path.utf8.count<=65536,!path.contains("\0") else{throw SFTPError.message("远程文件路径无效")}
  let h:Data
  do{h=try handle(3,str(path)+u32(2|8|32)+u32(4)+u32(0o600))}catch{throw SFTPError.message("无法创建文件（可能存在同名项目、权限不足或服务器限制）：\(error.localizedDescription)")}
  do{try closeHandle(h)}catch{throw SFTPError.message("文件可能已创建，但关闭确认失败，请刷新目录确认：\(error.localizedDescription)")}
 }
 func mkdir(_ path:String)throws{try command(14,str(path)+u32(4)+u32(0o755))}
 func rename(_ from:String,to:String)throws{try command(18,str(from)+str(to))}
 func remove(_ path:String,directory:Bool=false)throws{try command(directory ? 15 : 13,str(path))}
 func upload(_ local:URL,to remote:String,replacing expected:Data?=nil)throws {
  if expected != nil && !supportsExtension("posix-rename@openssh.com") {throw SFTPError.message("服务器不支持原子替换，无法安全保存编辑内容") }
  let attrs=expected == nil ? (UInt64(0),UInt32(0o100600)) : try attributes(remote,followLinks:false);guard attrs.1&0o170000 == 0o100000 else{throw SFTPError.message("远程目标已变成目录或符号链接，无法保存")};let mode=attrs.1 & 0o777
  let file=try FileHandle(forReadingFrom:local);defer{try? file.close()}
  let size=try file.seekToEnd();try file.seek(toOffset:0)
  let parent=(remote as NSString).deletingLastPathComponent
  let temporary=(parent.isEmpty ? "." : parent)+"/.macterm-upload-"+UUID().uuidString
  let h=try handle(3,str(temporary)+u32(2|8|32)+u32(4)+u32(mode));var closed=false;var committed=false
  defer{if !closed {try? closeHandle(h)};if !committed {try? remove(temporary)}}
  var offset:UInt64=0;progress?(0,size)
  while let chunk=try file.read(upToCount:32768),!chunk.isEmpty {try command(6,str(h)+u64(offset)+str(chunk));offset+=UInt64(chunk.count);progress?(offset,size)}
  try closeHandle(h);closed=true
  if let expected=expected {guard try readFile(remote,limit:RemoteText.maximumBytes)==expected else{throw SFTPError.message("远程文件已被其他程序修改。请重新打开并合并修改，再保存。")};try command(200,str("posix-rename@openssh.com")+str(temporary)+str(remote))}
  else {try rename(temporary,to:remote)}
  committed=true
 }

}

final class RemoteFileTable:NSTableView {
 override func menu(for event:NSEvent)->NSMenu? {let row=self.row(at:convert(event.locationInWindow,from:nil));if row>=0 && !selectedRowIndexes.contains(row) {selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false)}else if row<0 {deselectAll(nil)};return super.menu(for:event)}
}

final class SSHWorkspace:NSView,NSTableViewDataSource,NSTableViewDelegate,NSMenuItemValidation {
 let masterProbe=SSHMasterProbe();private(set) var masterAuthenticated=false;var onConnectionChanged:(()->Void)?;let terminal:TerminalPane;let socket:String;let session:Session;let bookmarkStore:DirectoryBookmarkStore;let baseArgs:[String];let files=RemoteFileTable();let path=NSTextField(string:"");let status=NSTextField(labelWithString:"等待 SSH 登录…");var entries=[RemoteFile]();var remotePath=".";var timer:Timer?;var busy=false;var stopped=false;var current:SFTPClient?;let clientLock=NSLock();var fileSidebar:NSView!;var filesVisible=true;var cancelRequested=false;var editors=[RemoteEditor]();let tunnels:TunnelManager;var tunnelWindow:TunnelWindow?;let transferQueue=TransferQueue();var pendingTransferRefresh=false;var transferWindow:TransferQueueWindow?;var allEntries=[RemoteFile]();let fileFilter=NSSearchField();let hiddenFiles=NSButton(checkboxWithTitle:"隐藏文件",target:nil,action:nil);let fileSort=NSPopUpButton();var directoryHistory=RemoteDirectoryHistory();var directoryViews=[Data:RemoteDirectoryView]();var directoryRequest=UUID();let backDirectoryButton=NSButton(),forwardDirectoryButton=NSButton(),historyDirectoryButton=NSButton()
 init(session:Session,args:[String],socket:String,preferences:TerminalPreferences?=nil,bookmarkStore:DirectoryBookmarkStore=DirectoryBookmarkStore()){self.session=session;self.baseArgs=args;self.socket=socket;self.bookmarkStore=bookmarkStore
  tunnels=TunnelManager(host:session.host,socket:socket,definitions:session.tunnels ?? [])
  terminal=TerminalPane(path:"/usr/bin/ssh",args:["-M","-S",socket,"-o","ControlPersist=no"]+args,preferences:preferences)
  super.init(frame:.zero)
  terminal.frame=bounds;terminal.autoresizingMask=[.width,.height];addSubview(terminal)
  let sidebar=NSStackView();sidebar.appearance=NSAppearance(named:.darkAqua);sidebar.wantsLayer=true;sidebar.layer?.backgroundColor=AppTheme.sidebar.cgColor;sidebar.orientation = .vertical;sidebar.spacing=4;sidebar.edgeInsets=NSEdgeInsets(top:8,left:8,bottom:8,right:8);sidebar.widthAnchor.constraint(greaterThanOrEqualToConstant:200).isActive=true
  let heading=NSStackView();heading.spacing=4
  for (button,symbol,title,action) in [(backDirectoryButton,"chevron.left","后退",#selector(backDirectory)),(forwardDirectoryButton,"chevron.right","前进",#selector(forwardDirectory))] {button.title="";button.image=AppTheme.symbol(symbol);button.imagePosition = .imageOnly;button.isBordered=false;button.contentTintColor=AppTheme.muted;button.target=self;button.action=action;button.toolTip=title;button.setAccessibilityLabel(title);button.widthAnchor.constraint(equalToConstant:22).isActive=true;button.heightAnchor.constraint(equalToConstant:22).isActive=true;heading.addArrangedSubview(button)}
  let caption=NSTextField(labelWithString:"SFTP 文件");caption.font = .systemFont(ofSize:12,weight:.semibold);heading.addArrangedSubview(caption);let spacer=NSView();spacer.setContentHuggingPriority(.init(1),for:.horizontal);heading.addArrangedSubview(spacer)
  historyDirectoryButton.title="";historyDirectoryButton.image=AppTheme.symbol("clock");historyDirectoryButton.imagePosition = .imageOnly;historyDirectoryButton.isBordered=false;historyDirectoryButton.contentTintColor=AppTheme.muted;historyDirectoryButton.target=self;historyDirectoryButton.action = #selector(showDirectoryHistory(_:));historyDirectoryButton.toolTip="本标签的路径历史（最多 100 条）";historyDirectoryButton.setAccessibilityLabel("路径历史");historyDirectoryButton.widthAnchor.constraint(equalToConstant:22).isActive=true;heading.addArrangedSubview(historyDirectoryButton)
  let bookmarkButton=AppActionButton(title:"",target:self,action:#selector(showDirectoryBookmarks(_:)));bookmarkButton.image=AppTheme.symbol("star");bookmarkButton.isBordered=false;bookmarkButton.contentTintColor=AppTheme.accent;bookmarkButton.toolTip="此连接的目录书签";bookmarkButton.setAccessibilityLabel("目录书签");bookmarkButton.widthAnchor.constraint(equalToConstant:24).isActive=true;bookmarkButton.heightAnchor.constraint(equalToConstant:24).isActive=true;heading.addArrangedSubview(bookmarkButton);sidebar.addArrangedSubview(heading);heading.widthAnchor.constraint(equalTo:sidebar.widthAnchor,constant:-16).isActive=true
AppTheme.field(path);path.target=self;path.action = #selector(go);path.placeholderString="远程路径，回车打开";sidebar.addArrangedSubview(path);path.widthAnchor.constraint(equalTo:sidebar.widthAnchor,constant:-16).isActive=true
  let buttons=NSStackView();for(title,action) in [("上级",#selector(up)),("刷新",#selector(refresh)),("上传",#selector(upload)),("下载",#selector(download))] {buttons.addArrangedSubview(NSButton(title:title,target:self,action:action))};sidebar.addArrangedSubview(buttons)
  let actions=NSStackView();actions.spacing=4;for(title,action) in [("新建目录",#selector(newFolder)),("更多…",#selector(showFileMenu)),("队列",#selector(showTransfers)),("取消",#selector(cancelTransfer))] {let button=NSButton(title:title,target:self,action:action);button.controlSize = .small;button.font = .systemFont(ofSize:11);actions.addArrangedSubview(button)};sidebar.addArrangedSubview(actions)
  fileFilter.placeholderString="筛选当前目录";fileFilter.target=self;fileFilter.action = #selector(filterFiles);fileFilter.sendsSearchStringImmediately=true;sidebar.addArrangedSubview(fileFilter);fileFilter.widthAnchor.constraint(equalTo:sidebar.widthAnchor,constant:-16).isActive=true
  let options=NSStackView();options.spacing=4;hiddenFiles.target=self;hiddenFiles.action = #selector(filterFiles);hiddenFiles.state=UserDefaults.standard.object(forKey:"sftpShowHidden") as? Bool == false ? .off : .on;hiddenFiles.font = .systemFont(ofSize:11);options.addArrangedSubview(hiddenFiles)
  fileSort.addItems(withTitles:["名称 ↑","名称 ↓","大小 ↓","修改时间 ↓"]);fileSort.target=self;fileSort.action = #selector(filterFiles);fileSort.controlSize = .small;options.addArrangedSubview(fileSort);sidebar.addArrangedSubview(options)
  let scroll=NSScrollView();scroll.setContentHuggingPriority(NSLayoutConstraint.Priority(1),for:.vertical);scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:80).isActive=true;scroll.hasVerticalScroller=true;scroll.borderType = .noBorder;scroll.scrollerStyle = .overlay;scroll.drawsBackground=false;let col=NSTableColumn(identifier:NSUserInterfaceItemIdentifier("file"));col.title="名称";col.width=235;files.addTableColumn(col);files.delegate=self;files.dataSource=self;files.target=self;files.doubleAction = #selector(openEntry);files.rowHeight=28;files.backgroundColor=AppTheme.sidebar;files.allowsMultipleSelection=true;files.setDraggingSourceOperationMask(.copy,forLocal:false);files.setDraggingSourceOperationMask(.copy,forLocal:true);files.toolTip="可拖入本机文件上传，也可将远程普通文件 / 文件夹拖到 Finder 下载。拖出不覆盖已有项目。";files.registerForDraggedTypes([.fileURL]);files.menu=fileMenu();scroll.documentView=files;sidebar.addArrangedSubview(scroll);scroll.widthAnchor.constraint(equalTo:sidebar.widthAnchor,constant:-16).isActive=true
  status.font = .systemFont(ofSize:10);status.textColor=AppTheme.muted;status.lineBreakMode = .byTruncatingTail;status.setContentCompressionResistancePriority(.init(1),for:.horizontal);sidebar.addArrangedSubview(status);status.widthAnchor.constraint(equalTo:sidebar.widthAnchor,constant:-16).isActive=true
  fileSidebar=sidebar
  transferQueue.changed = {[weak self] in self?.transferWindow?.reload();self?.updateNavigationControls()}
  transferQueue.cancelActive = {[weak self] in self?.cancelCurrentOperation()}
  transferQueue.execute = {[weak self] job,done in
   guard let self=self,!self.stopped else{done(SFTPError.message("SSH 会话已关闭"));return}
   self.run((job.uploading ? "上传 " : "下载 ")+job.local.lastPathComponent,completion:{[weak self] error in
    DispatchQueue.main.async {if job.uploading{self?.pendingTransferRefresh=true};done(error);if let self=self,!self.stopped,self.transferQueue.active == nil,self.pendingTransferRefresh{self.pendingTransferRefresh=false;self.refresh()}}
   }){try job.perform($0)}
  }
  updateNavigationControls()
  terminal.onExit = {[weak self] code in self?.directoryRequest=UUID();self?.path.stringValue=self?.remotePath ?? "";self?.updateNavigationControls();self?.timer?.invalidate();self?.masterProbe.stop();self?.masterAuthenticated=false;self?.onConnectionChanged?();self?.transferQueue.close();self?.tunnels.connectionClosed();self?.status.stringValue="SSH 已断开（\(code)）"}
  timer=Timer.scheduledTimer(withTimeInterval:1,repeats:true){[weak self] timer in guard let self=self else{timer.invalidate();return};self.checkMasterConnection()}

 }
 func checkMasterConnection(){guard !stopped,!terminal.stopped,!masterAuthenticated,terminal.pid>0,!terminal.receivedEOF,FileManager.default.fileExists(atPath:socket) else{return};let expected=terminal.pid
  masterProbe.check(host:session.host,socket:socket,pid:expected){[weak self] ready in guard let self=self,ready,!self.stopped,!self.terminal.stopped,self.terminal.pid==expected,!self.terminal.receivedEOF else{return};self.masterAuthenticated=true;self.timer?.invalidate();self.terminal.onAvailabilityChanged?();self.onConnectionChanged?();self.tunnels.startAutomatic();self.refresh()}
 }
 static func fileChannelArguments(host:String,socket:String)->[String] {["-F","/dev/null","-S",socket,"-o","BatchMode=yes","-o","ProxyCommand=/usr/bin/false","-o","ClearAllForwardings=yes","-s","--",host,"sftp"]}
 required init?(coder:NSCoder){fatalError()}
 func numberOfRows(in tableView:NSTableView)->Int{entries.count}
 func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int)->NSView?{let e=entries[row];let label=NSTextField(labelWithString:(e.symbolicLink ? "↗ " : e.directory ? "📁 " : "📄 ")+e.name);label.lineBreakMode = .byTruncatingTail;label.toolTip=e.directory ? e.name : "\(e.name) · \(e.size) 字节";return label}
 func run(_ title:String,completion:((Error?)->Void)?=nil,work:@escaping(SFTPClient)throws->Void){guard !busy,!stopped else{completion?(SFTPError.message("文件操作忙或会话已关闭"));return};busy=true;cancelRequested=false;status.stringValue=title;updateNavigationControls()
  DispatchQueue.global().async {[weak self] in guard let self=self else{return};do {let args=Self.fileChannelArguments(host:self.session.host,socket:self.socket);let client=try SFTPClient(arguments:args,onStart:{client in self.clientLock.lock();self.current=client;let stopped=self.stopped || self.cancelRequested;self.clientLock.unlock();if stopped && client.process.isRunning {client.process.terminate()}});var last=Date.distantPast;client.progress = {[weak self] done,total in guard Date().timeIntervalSince(last)>0.1 || done==total else{return};last=Date();DispatchQueue.main.async {guard let self=self,!self.stopped else{return};self.transferQueue.updateProgress(ByteCountFormatter.string(fromByteCount:Int64(done),countStyle:.file)+(total.map{" / "+ByteCountFormatter.string(fromByteCount:Int64($0),countStyle:.file)} ?? ""));self.status.stringValue=title+" "+ByteCountFormatter.string(fromByteCount:Int64(done),countStyle:.file)+(total.map{" / "+ByteCountFormatter.string(fromByteCount:Int64($0),countStyle:.file)} ?? "")}};defer{client.close();self.clientLock.lock();self.current=nil;self.clientLock.unlock()};try work(client);DispatchQueue.main.async{self.finishFileOperation(nil,completion:completion)}}catch{self.clientLock.lock();self.current=nil;self.clientLock.unlock();DispatchQueue.main.async {self.finishFileOperation(error,completion:completion)}}}
 }

 func renderFiles(preserveSelection:Bool=true){let selected=preserveSelection ? Set(files.selectedRowIndexes.compactMap{entries.indices.contains($0) ? RemoteFileIdentity.key(entries[$0].name) : nil}) : Set<Data>();entries=RemoteFileBrowser.visible(allEntries,query:fileFilter.stringValue,showHidden:hiddenFiles.state == .on,sort:RemoteFileSort(rawValue:fileSort.indexOfSelectedItem) ?? .name);files.reloadData();files.selectRowIndexes(IndexSet(entries.indices.filter{selected.contains(RemoteFileIdentity.key(entries[$0].name))}),byExtendingSelection:false)}
 @objc func filterFiles(){UserDefaults.standard.set(hiddenFiles.state == .on,forKey:"sftpShowHidden");renderFiles()}
 @objc func showProperties(){guard !busy,let entry=chosen() else{return};let source=remote(entry.name);var attributes:RemoteAttributes?;var canEdit=false;var linkTarget:String?
  run("读取属性…",completion:{[weak self] error in guard let self=self,!self.stopped,error==nil,let value=attributes else{return};let panel=RemoteProperties(path:source,attributes:value,canEditPermissions:canEdit,linkTarget:linkTarget);guard let mode=panel.runModal() else{return}
   DispatchQueue.main.async {[weak self] in self?.applyPermissions(source,mode:mode,expected:value)}
  }){client in attributes=try client.fileAttributes(source);canEdit=client.supportsExtension("lsetstat@openssh.com");if attributes?.symbolicLink == true {do{linkTarget=try client.readLink(source)}catch{linkTarget="无法读取："+error.localizedDescription}}}
 }
 func applyPermissions(_ source:String,mode:UInt32,expected:RemoteAttributes){run("修改权限…",completion:{[weak self] error in DispatchQueue.main.async {guard let self=self,!self.stopped else{return};if let error=error {let alert=NSAlert();alert.messageText="权限更新未确认";alert.informativeText=error.localizedDescription;alert.runModal()}else{self.refresh()}}}){try $0.setPermissions(source,to:mode,expected:expected)}}
 @objc func refresh(){load(remotePath)}
 @objc func go(){load(path.stringValue)}
 @objc func up(){load((remotePath as NSString).deletingLastPathComponent.isEmpty ? "/" : (remotePath as NSString).deletingLastPathComponent)}
 func remote(_ name:String)->String{(remotePath=="/" ? "/" : remotePath+"/")+name}
 @objc func openEntry(){let r=files.clickedRow;guard entries.indices.contains(r) else{return};openRemoteEntry(entries[r])}
 @objc func download(){guard !busy else{return};let selected=files.selectedRowIndexes.compactMap{entries.indices.contains($0) ? entries[$0] : nil};guard !selected.isEmpty else{return}
  if selected.count==1,!selected[0].directory {let entry=selected[0];let panel=NSSavePanel();panel.nameFieldStringValue=entry.name;guard panel.runModal() == .OK,let url=panel.url else{return};let source=remote(entry.name);enqueueTransfers([TransferJob(local:url,remote:source,uploading:false,allowOverwrite:true)]);return}
  let panel=NSOpenPanel();panel.canChooseFiles=false;panel.canChooseDirectories=true;panel.message="选择下载保存位置（同名项目不覆盖）";guard panel.runModal() == .OK,let parent=panel.url else{return};let source=remotePath
  enqueueTransfers(selected.map{TransferJob(local:parent.appendingPathComponent($0.name),remote:(source=="/" ? "/" : source+"/")+$0.name,uploading:false)})
 }
 @objc func upload(){guard !busy else{return};let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.allowsMultipleSelection=true;guard panel.runModal() == .OK else{return};uploadURLs(panel.urls)}
 func uploadURLs(_ urls:[URL]){guard !busy,!urls.isEmpty else{return};let directory=remotePath;enqueueTransfers(urls.map{TransferJob(local:$0,remote:(directory=="/" ? "/" : directory+"/")+$0.lastPathComponent,uploading:true)})}
 func enqueueTransfers(_ jobs:[TransferJob]){guard !stopped else{return};transferQueue.enqueue(jobs);showTransfers()}
 @objc func showTransfers(){if transferWindow == nil {transferWindow=TransferQueueWindow(queue:transferQueue);transferWindow?.window?.title="SFTP 传输队列 · \(session.name)"};transferWindow?.showWindow(nil);transferWindow?.window?.makeKeyAndOrderFront(nil)}
 func tableView(_ tableView:NSTableView,validateDrop info:NSDraggingInfo,proposedRow row:Int,proposedDropOperation operation:NSTableView.DropOperation)->NSDragOperation {guard tableView === files,!busy,!stopped,!(info.draggingSource is RemoteFileTable),info.draggingSourceOperationMask.contains(.copy),info.draggingPasteboard.canReadObject(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) else{return []};tableView.setDropRow(-1,dropOperation:.on);return .copy}
 func tableView(_ tableView:NSTableView,acceptDrop info:NSDraggingInfo,row:Int,dropOperation:NSTableView.DropOperation)->Bool {guard tableView === files,!busy,!stopped,!(info.draggingSource is RemoteFileTable),info.draggingSourceOperationMask.contains(.copy),let urls=info.draggingPasteboard.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL],!urls.isEmpty else{return false};uploadURLs(urls);return true}
 @objc func editRemote(){guard let entry=chosen(),!entry.directory else{return};openRemoteEntry(entry,mode:.text)}
 @objc func openDirectory(){guard let entry=chosen(),entry.directory || entry.symbolicLink else{return};openRemoteEntry(entry,mode:.directory)}
 func openRemoteEntry(_ entry:RemoteFile,mode:RemoteEntryOpenMode = .automatic){
  guard !busy,!stopped,terminal.pid>0,transferQueue.active==nil else{return};let source=remote(entry.name);let request=UUID();directoryRequest=request;var content:RemoteEntryContent?
  run("打开远程项目…",completion:{[weak self] error in guard let self=self,!self.stopped,self.terminal.pid>0,!self.cancelRequested,error==nil,self.directoryRequest==request,let content=content else{return};self.presentRemoteEntry(content)}){client in content=try client.openEntry(source,mode:mode)}
 }
 func presentRemoteEntry(_ content:RemoteEntryContent){switch content {
  case .directory(let destination,let entries):_ = commitDirectory(destination,entries:entries)
  case .text(let source,let text):
   let editor=RemoteEditor(path:source,text:text,save:{[weak self] data,expected,done in
    guard let self=self,!self.stopped else{done(.failure(SFTPError.message("SSH 会话已关闭")));return}
    guard !self.busy,self.transferQueue.active==nil else{done(.failure(SFTPError.message("文件操作正在进行，请稍后保存")));return}
    self.run("保存远程文件…",completion:{error in if let error=error {done(.failure(error))}else{done(.success(()))}}){client in try client.saveText(data,to:source,expected:expected)}
   });editors.append(editor);editor.onClose = {[weak self,weak editor] in self?.editors.removeAll{$0 === editor}};editor.showWindow(nil);editor.window?.makeKeyAndOrderFront(nil)
  }
 }
 func validateMenuItem(_ item:NSMenuItem)->Bool {
  let idle = !busy && !stopped && terminal.acceptsInput && transferQueue.active==nil;let entry=chosen()
  switch item.action {
  case #selector(openDirectory):return idle && entry.map{$0.directory || $0.symbolicLink} == true
  case #selector(editRemote):return idle && entry.map{!$0.directory} == true && files.selectedRowIndexes.count==1
  case #selector(showProperties),#selector(renameEntry),#selector(deleteEntry):return idle && entry != nil && files.selectedRowIndexes.count==1
  case #selector(download):return idle && !files.selectedRowIndexes.isEmpty
  case #selector(newFolder),#selector(newFile):return idle
  case #selector(copyRemotePath):return entry != nil
  default:return true
  }
 }

 func confirmEditorClose()->Bool {editors.allSatisfy{$0.confirmDiscard()}}
 func fileMenu()->NSMenu {let menu=NSMenu();for(title,action) in [("打开目录 / 链接目标",#selector(openDirectory)),("属性…",#selector(showProperties)),("编辑文本…",#selector(editRemote)),("下载",#selector(download)),("新建文件…",#selector(newFile)),("新建文件夹…",#selector(newFolder)),("重命名…",#selector(renameEntry)),("删除文件 / 空目录…",#selector(deleteEntry)),("复制远程路径",#selector(copyRemotePath))] {let item=menu.addItem(withTitle:title,action:action,keyEquivalent:"");item.target=self};return menu}
 @objc func showFileMenu(_ sender:NSButton){fileMenu().popUp(positioning:nil,at:NSPoint(x:0,y:sender.bounds.height),in:sender)}
 func chosen()->RemoteFile? {let row=files.selectedRow;return entries.indices.contains(row) ? entries[row] : nil}
 func askName(_ title:String,value:String="")->String? {let alert=NSAlert();alert.messageText=title;alert.addButton(withTitle:"确定");alert.addButton(withTitle:"取消");let field=NSTextField(frame:NSRect(x:0,y:0,width:280,height:24));field.stringValue=value;alert.accessoryView=field;guard alert.runModal() == .alertFirstButtonReturn else{return nil};let name=field.stringValue;guard !name.isEmpty,name != ".",name != "..",!name.contains("/"),!name.contains("\0"),!name.contains("\n"),!name.contains("\r") else{let error=NSAlert();error.messageText="名称不能为空，不能含斜杠或换行，也不能使用 . 或 ..";error.runModal();return nil};return name}
 func mutate(_ title:String,work:@escaping(SFTPClient)throws->Void){let directory=remotePath;run(title){client in try work(client);let entries=try client.list(directory);DispatchQueue.main.async {[weak self] in guard let self=self,!self.stopped else{return};self.allEntries=entries;self.renderFiles(preserveSelection:true)}}}
 @objc func newFile(){
  guard !busy,!stopped,terminal.acceptsInput,transferQueue.active==nil else{return}
  let alert=NSAlert();alert.messageText="新建远程文件";alert.informativeText="在当前目录创建空文件。同名项目不会被覆盖。";alert.window.appearance=NSAppearance(named:.darkAqua);alert.addButton(withTitle:"创建");alert.addButton(withTitle:"取消")
  let form=RemoteFileCreationForm();alert.accessoryView=form;alert.window.initialFirstResponder=form.name
  while alert.runModal() == .alertFirstButtonReturn {
   do{let name=try RemoteFileName.validated(form.name.stringValue);createRemoteFile(name:name,openAfterCreation:form.openEditor.state == .on);return}
   catch{alert.informativeText=error.localizedDescription;alert.window.initialFirstResponder=form.name}
  }
 }
 func createRemoteFile(name rawName:String,openAfterCreation:Bool){
  guard !busy,!stopped,terminal.acceptsInput,transferQueue.active==nil else{return}
  let name:String
  do{name=try RemoteFileName.validated(rawName)}catch{status.stringValue=error.localizedDescription;return}
  let directory=remotePath,request=UUID();directoryRequest=request
  var createdPath:String?;var listing:[RemoteFile]?;var listingError:Error?
  run("创建远程文件…",completion:{[weak self] error in
   guard let self=self,!self.stopped,!self.cancelRequested,self.terminal.acceptsInput,self.directoryRequest==request,error==nil,let destination=createdPath else{return}
   if RemoteFileIdentity.key(self.remotePath)==RemoteFileIdentity.key(directory),let listing=listing {
    self.allEntries=listing;self.renderFiles(preserveSelection:true)
    if let index=self.entries.firstIndex(where:{RemoteFileIdentity.key($0.name)==RemoteFileIdentity.key(name)}){self.files.selectRowIndexes(IndexSet(integer:index),byExtendingSelection:false);self.files.scrollRowToVisible(index)}
   }
   self.status.stringValue=listingError.map{"文件已创建，目录刷新失败："+$0.localizedDescription} ?? "已创建："+name+(self.entries.contains{RemoteFileIdentity.key($0.name)==RemoteFileIdentity.key(name)} ? "" : "（当前筛选未显示）")
   self.status.toolTip=destination
   if openAfterCreation,let empty=try? RemoteText(data:Data()){self.presentRemoteEntry(.text(destination,empty))}
  }){client in
   let parent=try client.canonical(directory);let destination=RemoteDirectoryHistory.resolve(name,relativeTo:parent)
   try client.createFile(destination);createdPath=destination
   do{listing=try client.list(parent)}catch{listingError=error}
  }
 }
 @objc func newFolder(){guard !busy,let name=askName("新建远程文件夹") else{return};let dest=remote(name);mutate("创建目录…"){try $0.mkdir(dest)}}
 @objc func renameEntry(){guard !busy,let entry=chosen(),let name=askName("重命名",value:entry.name),name != entry.name else{return};let from=remote(entry.name),to=remote(name);mutate("重命名…"){try $0.rename(from,to:to)}}
 @objc func deleteEntry(){guard !busy,let entry=chosen() else{return};let alert=NSAlert();alert.messageText="永久删除 \(entry.name)？";alert.informativeText="远程删除无法撤销。文件夹必须为空。";alert.addButton(withTitle:"删除");alert.addButton(withTitle:"取消");guard alert.runModal() == .alertFirstButtonReturn else{return};let dest=remote(entry.name);mutate("删除…"){try $0.remove(dest,directory:entry.directory)}}
 @objc func copyRemotePath(){guard let entry=chosen() else{return};NSPasteboard.general.clearContents();NSPasteboard.general.setString(remote(entry.name),forType:.string)}
 @objc func cancelTransfer(){if transferQueue.active != nil {transferQueue.cancel()}else{cancelCurrentOperation()}}
 func cancelCurrentOperation(){guard busy else{return};clientLock.lock();cancelRequested=true;if let p=current?.process,p.isRunning{p.terminate()};clientLock.unlock();status.stringValue="正在取消…"}
 func toggleFiles(){filesVisible.toggle()}
 func stop(){masterProbe.stop();masterAuthenticated=false;directoryRequest=UUID();transferQueue.close();transferWindow?.close();tunnels.connectionClosed();tunnelWindow?.close();for editor in editors {editor.window?.close()};editors=[];clientLock.lock();stopped=true;if let process=current?.process,process.isRunning {process.terminate()};clientLock.unlock();updateNavigationControls();timer?.invalidate();terminal.stop();try? FileManager.default.removeItem(atPath:socket)}
}

enum RemotePermissions {
 static func parse(_ text:String)throws->UInt32 {let value=text.trimmingCharacters(in:.whitespacesAndNewlines);guard (3...4).contains(value.utf8.count),value.utf8.allSatisfy({$0>=48 && $0<=55}),let mode=UInt32(value,radix:8),mode<=0o7777 else{throw SFTPError.message("请输入 3 或 4 位八进制权限，例如 644、0755")};return mode}
}

final class RemoteProperties:NSObject,NSTextFieldDelegate {
 let alert=NSAlert();let permissionField=NSTextField();let validation=NSTextField(labelWithString:"");let original:RemoteAttributes;let canEditPermissions:Bool
 init(path:String,attributes:RemoteAttributes,canEditPermissions:Bool=false,linkTarget:String?=nil){
  original=attributes;self.canEditPermissions=canEditPermissions && attributes.permissionEditable;super.init()
  alert.messageText=(path as NSString).lastPathComponent+" · 属性"
  alert.informativeText=self.canEditPermissions ? "权限修改只作用于当前项目，不递归修改子目录。" : attributes.symbolicLink ? "符号链接显示自身属性，权限不会修改。" : "仅查看属性；此服务器或文件类型不支持安全修改权限。"
  alert.addButton(withTitle:self.canEditPermissions ? "应用权限" : "关闭");if self.canEditPermissions {alert.addButton(withTitle:"取消")};alert.window.appearance=NSAppearance(named:.darkAqua)
  permissionField.stringValue=attributes.permissions;permissionField.bezelStyle = .roundedBezel;permissionField.font = .monospacedSystemFont(ofSize:12,weight:.regular);permissionField.delegate=self;permissionField.setAccessibilityLabel("权限（八进制）")
  let formatter=DateFormatter();formatter.dateStyle = .medium;formatter.timeStyle = .medium
  var values:[(String,String)]=[("远程路径",path),("类型",attributes.kind),("大小",attributes.sizeAvailable ? ByteCountFormatter.string(fromByteCount:Int64(clamping:attributes.size),countStyle:.file)+"（\(attributes.size) 字节）" : "服务器未提供"),("权限（八进制）",attributes.permissions),("所有者 UID",attributes.uid.map{String($0)} ?? "服务器未提供"),("所属组 GID",attributes.gid.map{String($0)} ?? "服务器未提供"),("修改时间",attributes.modified.map{formatter.string(from:$0)} ?? "服务器未提供"),("访问时间",attributes.accessed.map{formatter.string(from:$0)} ?? "服务器未提供")]
  if attributes.symbolicLink {values.insert(("链接目标",linkTarget ?? "服务器未提供"),at:2)}
  var rows=values.map{title,value->[NSView] in let key=NSTextField(labelWithString:title);key.textColor = .secondaryLabelColor
   if title=="权限（八进制）",self.canEditPermissions {permissionField.widthAnchor.constraint(equalToConstant:330).isActive=true;return [key,permissionField]}
   let field=NSTextField(wrappingLabelWithString:value);field.isSelectable=true;field.maximumNumberOfLines=3;field.lineBreakMode = .byTruncatingMiddle;field.toolTip=value;field.font = .systemFont(ofSize:12);field.widthAnchor.constraint(equalToConstant:330).isActive=true;return [key,field]
  }
  if self.canEditPermissions {validation.font = .systemFont(ofSize:11);validation.widthAnchor.constraint(equalToConstant:330).isActive=true;rows.append([NSTextField(labelWithString:""),validation])}
  let grid=NSGridView(views:rows);grid.rowSpacing=10;grid.columnSpacing=14;grid.column(at:0).xPlacement = .trailing;grid.layoutSubtreeIfNeeded();grid.frame=NSRect(origin:.zero,size:grid.fittingSize);alert.accessoryView=grid
  updatePermissionState()
 }
 func updatePermissionState(){guard canEditPermissions else{return};do{let mode=try RemotePermissions.parse(permissionField.stringValue);alert.buttons[0].isEnabled=mode != original.mode&0o7777;validation.textColor = .secondaryLabelColor;validation.stringValue="4 位形式首位为特殊位（setuid / setgid / sticky）。"}catch{alert.buttons[0].isEnabled=false;validation.textColor = .systemOrange;validation.stringValue=error.localizedDescription}}
 func controlTextDidChange(_ notification:Notification){updatePermissionState()}
 @discardableResult func runModal()->UInt32? {guard alert.runModal() == .alertFirstButtonReturn,canEditPermissions,let mode=try? RemotePermissions.parse(permissionField.stringValue),mode != original.mode&0o7777 else{return nil};return mode}
}

enum RemoteFileName {
 static func validated(_ name:String)throws->String {
  guard !name.isEmpty,name.utf8.count<=1024,name != ".",name != "..",!name.contains("/"),!name.unicodeScalars.contains(where:{$0.value<32 || $0.value==127}) else{throw SFTPError.message("名称不能为空或超过 1024 字节，不能含斜杠、换行或控制字符，也不能使用 . 或 ..")}
  return name
 }
}
final class RemoteFileCreationForm:NSView {
 let name=NSTextField(string:"")
 let openEditor=NSButton(checkboxWithTitle:"创建后打开文本编辑器",target:nil,action:nil)
 override init(frame:NSRect){super.init(frame:NSRect(x:0,y:0,width:320,height:76));AppTheme.field(name);name.placeholderString="例如：notes.txt";name.setAccessibilityLabel("新文件名称");openEditor.state = .on;name.frame=NSRect(x:0,y:42,width:320,height:28);openEditor.frame=NSRect(x:0,y:6,width:320,height:24);addSubview(name);addSubview(openEditor)}
 convenience init(){self.init(frame:.zero)}
 required init?(coder:NSCoder){fatalError()}
}
