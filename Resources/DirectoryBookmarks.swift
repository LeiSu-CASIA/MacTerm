import Cocoa
import Darwin

struct DirectoryBookmark:Codable {
 let id:UUID;var title:String;let path:String
 func validated()throws->DirectoryBookmark {
  guard !title.isEmpty,title.count<=80,!title.unicodeScalars.contains(where:{$0.value<32 || $0.value==127}),path.hasPrefix("/"),path.utf8.count<=65536,!path.contains("\0") else{throw SFTPError.message("目录书签的名称或绝对路径无效")};return self
 }
 func same(as other:DirectoryBookmark)->Bool {id==other.id && Data(title.utf8)==Data(other.title.utf8) && Data(path.utf8)==Data(other.path.utf8)}
}
struct DirectoryBookmarkArchive:Codable {let format:String;let version:Int;var scopes:[String:[DirectoryBookmark]]}
struct DirectoryBookmarkStore {
 let url:URL
 static let maximumBytes=4*1024*1024
 init(url:URL?=nil){self.url=url ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MacTerm/directory-bookmarks.json")}
 static func scope(_ session:Session)->String {
  // ASCII identity preserves endpoint bytes, including canonically equivalent aliases.
  var values=[session.id?.uuidString ?? "",session.host,session.user,String(session.port),session.jumpHost ?? ""]
  if session.connectionKind == .ftp{values += ["ftp",session.ftp?.security.rawValue ?? "plain"]}
  return (try! JSONEncoder().encode(values)).base64EncodedString()
 }
 static func decode(_ data:Data)throws->DirectoryBookmarkArchive {
  guard data.count<=maximumBytes else{throw SFTPError.message("目录书签文件超过 4 MB")}
  let archive=try JSONDecoder().decode(DirectoryBookmarkArchive.self,from:data)
  guard archive.format=="MacTerm Directory Bookmarks",archive.version==1,archive.scopes.count<=1000 else{throw SFTPError.message("目录书签格式、版本或数量无效")}
  var ids=Set<UUID>(),total=0
  for (scope,bookmarks) in archive.scopes {
   guard !scope.isEmpty,scope.utf8.count<=32768,bookmarks.count<=200 else{throw SFTPError.message("每个连接最多 200 个目录书签")}
   total+=bookmarks.count;guard total<=2000 else{throw SFTPError.message("目录书签总数不能超过 2000")}
   var paths=Set<Data>();for bookmark in bookmarks {_ = try bookmark.validated();guard ids.insert(bookmark.id).inserted,paths.insert(Data(bookmark.path.utf8)).inserted else{throw SFTPError.message("目录书签包含重复 ID 或路径")}}
  };return archive
 }
 private func data()throws->Data? {
  let fd=Darwin.open(url.path,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC)
  guard fd>=0 else{if errno==ENOENT{return nil};throw SFTPError.message("无法读取目录书签（不接受符号链接）")};defer{Darwin.close(fd)}
  var info=stat();guard fstat(fd,&info)==0,UInt32(info.st_mode)&UInt32(S_IFMT)==UInt32(S_IFREG),info.st_size>=0,info.st_size<=Self.maximumBytes else{throw SFTPError.message("目录书签文件类型无效或超过 4 MB")}
  var result=Data(),buffer=[UInt8](repeating:0,count:16384)
  while true {let count=Darwin.read(fd,&buffer,buffer.count);if count<0 && errno==EINTR {continue};guard count>=0,count<=Self.maximumBytes-result.count else{throw SFTPError.message("目录书签读取失败或超过 4 MB")};if count==0{break};result.append(contentsOf:buffer.prefix(count))};return result
 }
 func bookmarks(for scope:String)throws->[DirectoryBookmark] {guard let data=try data() else{return []};return try Self.decode(data).scopes[scope] ?? []}
 private func publish(_ data:Data,to target:URL)throws {
  let temporary=target.deletingLastPathComponent().appendingPathComponent(".macterm-bookmarks-"+UUID().uuidString)
  let fd=Darwin.open(temporary.path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600);guard fd>=0 else{throw SFTPError.message("无法创建目录书签暂存文件")};defer{Darwin.close(fd);try? FileManager.default.removeItem(at:temporary)}
  try data.withUnsafeBytes{(bytes:UnsafeRawBufferPointer) in var offset=0;while offset<bytes.count {let count=Darwin.write(fd,bytes.baseAddress!.advanced(by:offset),bytes.count-offset);if count<0 && errno==EINTR {continue};guard count>0 else{throw SFTPError.message("目录书签写入失败")};offset+=count}}
  guard fchmod(fd,0o600)==0,fsync(fd)==0,Darwin.rename(temporary.path,target.path)==0 else{throw SFTPError.message("目录书签保存失败")}
 }
 private func update(_ mutation:(inout DirectoryBookmarkArchive)throws->Void)throws {
  try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
  let fd=Darwin.open(url.appendingPathExtension("lock").path,O_CREAT|O_RDWR|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC,0o600);guard fd>=0 else{throw SFTPError.message("无法锁定目录书签文件")};defer{Darwin.close(fd)}
  var info=stat();guard fstat(fd,&info)==0,UInt32(info.st_mode)&UInt32(S_IFMT)==UInt32(S_IFREG) else{throw SFTPError.message("目录书签锁文件类型无效")}
  guard flock(fd,LOCK_EX|LOCK_NB)==0 else{throw SFTPError.message("其他实例正在保存目录书签，请稍后重试")};defer{_ = flock(fd,LOCK_UN)}
  let previous=try data();var archive=try previous.map{try Self.decode($0)} ?? DirectoryBookmarkArchive(format:"MacTerm Directory Bookmarks",version:1,scopes:[:]);try mutation(&archive)
  let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys];let encoded=try encoder.encode(archive);_ = try Self.decode(encoded)
  guard try data()==previous else{throw SFTPError.message("目录书签已被外部程序修改，请重新打开菜单后重试")}
  if let previous=previous {try publish(previous,to:url.appendingPathExtension("backup"))};try publish(encoded,to:url)
 }
 @discardableResult func add(title:String,path:String,scope:String)throws->DirectoryBookmark {
  let value=try DirectoryBookmark(id:UUID(),title:title,path:path).validated()
  try update{archive in guard !(archive.scopes[scope] ?? []).contains(where:{Data($0.path.utf8)==Data(path.utf8)}) else{throw SFTPError.message("此目录已在书签中")};archive.scopes[scope,default:[]].append(value)};return value
 }
 func rename(_ expected:DirectoryBookmark,title:String,scope:String)throws {
  var value=expected;value.title=title;_ = try value.validated()
  try update{archive in guard let index=archive.scopes[scope]?.firstIndex(where:{$0.same(as:expected)}) else{throw SFTPError.message("目录书签已变化，请重新打开书签菜单")};archive.scopes[scope]![index]=value}
 }
 func remove(_ expected:DirectoryBookmark,scope:String)throws {
  try update{archive in guard let index=archive.scopes[scope]?.firstIndex(where:{$0.same(as:expected)}) else{throw SFTPError.message("目录书签已变化，请重新打开书签菜单")};archive.scopes[scope]!.remove(at:index);if archive.scopes[scope]!.isEmpty{archive.scopes.removeValue(forKey:scope)}}
 }
}

extension SSHWorkspace {
 var bookmarkScope:String {DirectoryBookmarkStore.scope(session)}
 var canUseDirectoryBookmarks:Bool {!busy && !stopped && terminal.acceptsInput && transferQueue.active==nil}
 func bookmarkMenu()->NSMenu {
  let menu=NSMenu();menu.autoenablesItems=false
  do {
   let bookmarks=try bookmarkStore.bookmarks(for:bookmarkScope)
   let current=bookmarks.first{Data($0.path.utf8)==Data(remotePath.utf8)}
   let add=menu.addItem(withTitle:"将当前目录加入书签…",action:#selector(addDirectoryBookmark),keyEquivalent:"");add.target=self;add.isEnabled=canUseDirectoryBookmarks && directoryHistory.current != nil && current==nil
   menu.addItem(.separator())
   for bookmark in bookmarks.sorted(by:{$0.title.localizedStandardCompare($1.title) == .orderedAscending}) {
    let entry=menu.addItem(withTitle:bookmark.title,action:#selector(jumpToBookmark(_:)),keyEquivalent:"");entry.target=self;entry.representedObject=bookmark;entry.toolTip=bookmark.path;entry.state=bookmark.id==current?.id ? .on : .off;entry.isEnabled=canUseDirectoryBookmarks
   }
   if bookmarks.isEmpty {let empty=menu.addItem(withTitle:"尚无目录书签",action:nil,keyEquivalent:"");empty.isEnabled=false}
   else {menu.addItem(.separator());let manage=NSMenu();manage.autoenablesItems=false;let parent=menu.addItem(withTitle:"管理书签",action:nil,keyEquivalent:"");parent.submenu=manage
    for bookmark in bookmarks {let item=manage.addItem(withTitle:bookmark.title,action:nil,keyEquivalent:"");item.toolTip=bookmark.path;let actions=NSMenu();actions.autoenablesItems=false;item.submenu=actions
     for(title,selector) in [("重命名…",#selector(renameDirectoryBookmark(_:))),("移除书签",#selector(removeDirectoryBookmark(_:)))] {let action=actions.addItem(withTitle:title,action:selector,keyEquivalent:"");action.target=self;action.representedObject=bookmark;action.isEnabled = !stopped}
    }
   }
   DirectoryBookmarkTransfer.addMenu(to:menu,target:self,enabled:!stopped,hasBookmarks:!bookmarks.isEmpty,importAction:#selector(SSHWorkspace.importDirectoryBookmarks),exportAction:#selector(SSHWorkspace.exportDirectoryBookmarks))
  }catch{let failed=menu.addItem(withTitle:"书签读取失败，原文件已保留",action:nil,keyEquivalent:"");failed.isEnabled=false;failed.toolTip=error.localizedDescription;status.stringValue=error.localizedDescription;status.toolTip=error.localizedDescription}
  return menu
 }
 @objc func showDirectoryBookmarks(_ sender:NSButton){bookmarkMenu().popUp(positioning:nil,at:NSPoint(x:0,y:sender.bounds.height),in:sender)}
 func requestBookmarkTitle(_ heading:String,initial:String)->String? {
  let alert=NSAlert();alert.messageText=heading;alert.informativeText="书签只保存目录位置，打开时不会执行终端命令。";alert.window.appearance=NSAppearance(named:.darkAqua);alert.addButton(withTitle:"保存");alert.addButton(withTitle:"取消")
  let field=NSTextField(frame:NSRect(x:0,y:0,width:300,height:28));AppTheme.field(field);field.stringValue=initial;field.setAccessibilityLabel("目录书签名称");alert.accessoryView=field;alert.window.initialFirstResponder=field
  while alert.runModal() == .alertFirstButtonReturn {let title=field.stringValue.trimmingCharacters(in:.whitespacesAndNewlines);if !title.isEmpty,title.count<=80,!title.unicodeScalars.contains(where:{$0.value<32 || $0.value==127}){return title};alert.informativeText="名称需为 1–80 个字符，不能包含控制字符。"};return nil
 }
 @objc func addDirectoryBookmark(){
  guard canUseDirectoryBookmarks,let current=directoryHistory.current else{return}
  let name=(current as NSString).lastPathComponent;let initial=String((name.isEmpty ? "/" : name).unicodeScalars.map{$0.value<32 || $0.value==127 ? "_" : String($0)}.joined().prefix(80))
  guard let title=requestBookmarkTitle("添加目录书签",initial:initial),!stopped else{return}
  do{_ = try bookmarkStore.add(title:title,path:current,scope:bookmarkScope);status.stringValue="已添加目录书签："+title}catch{status.stringValue=error.localizedDescription};status.toolTip=status.stringValue
 }
 @objc func jumpToBookmark(_ sender:NSMenuItem){
  guard canUseDirectoryBookmarks,let bookmark=sender.representedObject as? DirectoryBookmark else{return}
  do{guard try bookmarkStore.bookmarks(for:bookmarkScope).contains(where:{$0.same(as:bookmark)}) else{throw SFTPError.message("目录书签已变化，请重新打开书签菜单")};load(bookmark.path)}catch{status.stringValue=error.localizedDescription;status.toolTip=status.stringValue}
 }
 @objc func renameDirectoryBookmark(_ sender:NSMenuItem){guard !stopped,let bookmark=sender.representedObject as? DirectoryBookmark,let title=requestBookmarkTitle("重命名目录书签",initial:bookmark.title),!stopped else{return};do{try bookmarkStore.rename(bookmark,title:title,scope:bookmarkScope);status.stringValue="目录书签已重命名"}catch{status.stringValue=error.localizedDescription};status.toolTip=status.stringValue}
 @objc func removeDirectoryBookmark(_ sender:NSMenuItem){guard !stopped,let bookmark=sender.representedObject as? DirectoryBookmark else{return};do{try bookmarkStore.remove(bookmark,scope:bookmarkScope);status.stringValue="已移除目录书签，远程目录保留"}catch{status.stringValue=error.localizedDescription};status.toolTip=status.stringValue}
}

struct PortableDirectoryBookmark:Codable {let title:String,path:String}
struct PortableDirectoryBookmarks:Codable {
 let format:String,version:Int,bookmarks:[PortableDirectoryBookmark]
 static func decode(_ data:Data)throws->[PortableDirectoryBookmark] {
  guard data.count<=DirectoryBookmarkStore.maximumBytes else{throw SFTPError.message("目录书签文件超过 4 MB")}
  let archive=try JSONDecoder().decode(Self.self,from:data)
  guard archive.format=="MacTerm Portable Directory Bookmarks",archive.version==1,archive.bookmarks.count<=200 else{throw SFTPError.message("不支持的目录书签格式、版本或数量")}
  var paths=Set<Data>()
  for value in archive.bookmarks {_ = try DirectoryBookmark(id:UUID(),title:value.title,path:value.path).validated();guard paths.insert(Data(value.path.utf8)).inserted else{throw SFTPError.message("导入文件包含重复目录")}}
  return archive.bookmarks
 }
 static func encode(_ bookmarks:[PortableDirectoryBookmark])throws->Data {
  let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
  let data=try encoder.encode(Self(format:"MacTerm Portable Directory Bookmarks",version:1,bookmarks:bookmarks));_ = try decode(data);return data
 }
}
struct DirectoryBookmarkImportResult {let added:Int,skipped:Int}
extension DirectoryBookmarkStore {
 static func readPortable(from source:URL)throws->[PortableDirectoryBookmark] {
  guard source.isFileURL,source.host==nil || source.host=="" || source.host=="localhost",source.user==nil,source.password==nil,source.query==nil,source.fragment==nil else{throw SFTPError.message("请选择本机目录书签文件")}
  guard let bytes=try DirectoryBookmarkStore(url:source).data() else{throw SFTPError.message("所选目录书签文件不存在")}
  return try PortableDirectoryBookmarks.decode(bytes)
 }
 @discardableResult func importPortable(_ bookmarks:[PortableDirectoryBookmark],scope:String,ftp:Bool=false)throws->DirectoryBookmarkImportResult {
  _ = try PortableDirectoryBookmarks.encode(bookmarks)
  if ftp {for bookmark in bookmarks {_ = try FTPPath.normalize(bookmark.path)}}
  var added=0,skipped=0
  try update{archive in
   var paths=Set((archive.scopes[scope] ?? []).map{Data($0.path.utf8)}),ids=Set(archive.scopes.values.flatMap{$0}.map{$0.id})
   for value in bookmarks {
    guard paths.insert(Data(value.path.utf8)).inserted else{skipped+=1;continue}
    var id=UUID();while ids.contains(id){id=UUID()};ids.insert(id)
    archive.scopes[scope,default:[]].append(DirectoryBookmark(id:id,title:value.title,path:value.path));added+=1
   }
  };return DirectoryBookmarkImportResult(added:added,skipped:skipped)
 }
 func exportPortable(scope:String,to destination:URL)throws {
  guard destination.isFileURL,destination.host==nil || destination.host=="" || destination.host=="localhost",destination.user==nil,destination.password==nil,destination.query==nil,destination.fragment==nil else{throw SFTPError.message("请选择本机导出位置")}
  let resolved=destination.standardizedFileURL.resolvingSymlinksInPath()
  for protected in [url,url.appendingPathExtension("lock"),url.appendingPathExtension("backup")] {
   let path=protected.standardizedFileURL.resolvingSymlinksInPath();var first=stat(),second=stat()
   guard path != resolved,!(lstat(path.path,&first)==0 && lstat(resolved.path,&second)==0 && first.st_dev==second.st_dev && first.st_ino==second.st_ino) else{throw SFTPError.message("请选择书签工作文件、锁和备份以外的位置")}
  }
  var info=stat();let existing=lstat(destination.path,&info)
  guard existing==0 ? UInt32(info.st_mode)&UInt32(S_IFMT)==UInt32(S_IFREG) : errno==ENOENT else{throw SFTPError.message("导出目标必须为普通文件，不接受符号链接或特殊文件")}
  let values=try bookmarks(for:scope).map{PortableDirectoryBookmark(title:$0.title,path:$0.path)}
  try publish(PortableDirectoryBookmarks.encode(values),to:destination)
 }
}
