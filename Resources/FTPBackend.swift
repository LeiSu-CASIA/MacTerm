import Cocoa
import Darwin

enum FTPSecurity:String,Codable,CaseIterable {case plain,explicitTLS,implicitTLS
 var title:String {switch self{case .plain:return "FTP（明文）";case .explicitTLS:return "FTPS（显式 TLS）";case .implicitTLS:return "FTPS（隐式 TLS）"}}
}
struct FTPSettings:Codable,Equatable {
 var security:FTPSecurity = .explicitTLS;var initialPath="/"
 func validated()throws->FTPSettings {_ = try FTPPath.normalize(initialPath);return self}
}
enum FTPPath {
 static func normalize(_ value:String,relativeTo parent:String="/")throws->String {
  guard !value.isEmpty,value.utf8.count<=65536,!value.unicodeScalars.contains(where:{$0.value<32 || $0.value==127}) else{throw SFTPError.message("FTP 路径不能为空、超过 64 KB 或包含控制字符")}
  let path=value.hasPrefix("/") ? value : parent+"/"+value;var pieces=[Substring]()
  for part in path.split(separator:"/"){if part=="."{continue};if part==".."{if !pieces.isEmpty{pieces.removeLast()}}else{pieces.append(part)}};return "/"+pieces.joined(separator:"/")
 }
 static func child(_ name:String,in parent:String)throws->String {_ = try RemoteFileName.validated(name);return try normalize((parent=="/" ? "/" : parent+"/")+name)}
 static func url(session:Session,path:String,directory:Bool)throws->String {
  let normalized=try normalize(path),allowed=CharacterSet(charactersIn:"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
  let encoded=normalized.split(separator:"/").map{String($0).addingPercentEncoding(withAllowedCharacters:allowed)!}.joined(separator:"/")
  var components=URLComponents();components.scheme=session.ftp?.security == .implicitTLS ? "ftps" : "ftp";components.host=session.host;components.port=session.port
  guard let base=components.url?.absoluteString else{throw SFTPError.message("FTP 主机地址无效")}
  // An extra slash selects an absolute server path instead of login-relative paths.
  return base+"//"+encoded+(directory && !encoded.isEmpty ? "/" : "")
 }
}
extension Session {
 func validatedFTP()throws->Session {
  guard connectionKind == .ftp,!name.isEmpty,name.count<=256,(group?.count ?? 0)<=128,[name,host,user,group ?? ""].allSatisfy({$0.utf8.count<=4096 && !$0.unicodeScalars.contains(where:{$0.value<32 || $0.value==127})}),!host.isEmpty,host.utf8.count<=255,!host.hasPrefix("-"),!host.contains(where:{$0.isWhitespace || "/\\@[]?#%".contains($0)}),!user.isEmpty,!user.contains(":"),(1...65535).contains(port),(1...600).contains(connectionTimeout ?? 15),key.isEmpty,jumpHost==nil,keepAlive==nil,x11==nil,(tunnels ?? []).isEmpty,compression==nil,forwardAgent==nil,remoteCommand==nil,commandTTY==nil,rdp==nil,vnc==nil,serial==nil,telnet==nil,let settings=ftp else{throw SFTPError.message("FTP 会话名称、主机、用户、端口或配置无效，不能混入 SSH 等设置")}
  if host.contains(":"){var address=in6_addr();guard inet_pton(AF_INET6,host,&address)==1 else{throw SFTPError.message("FTP IPv6 地址无效")}};_ = try settings.validated();return self
 }
}
enum FTPListing {
 static func decode(_ data:Data)throws->[RemoteFile] {
  guard data.count<=16*1024*1024,let text=String(data:data,encoding:.utf8) else{throw SFTPError.message("FTP 目录不是 UTF-8 或超过 16 MB")}
  let format=DateFormatter();format.locale=Locale(identifier:"en_US_POSIX");format.timeZone=TimeZone(secondsFromGMT:0);format.dateFormat="yyyyMMddHHmmss";format.isLenient=false
  var result=[RemoteFile](),seen=Set<Data>()
  for line in text.replacingOccurrences(of:"\r\n",with:"\n").split(separator:"\n",omittingEmptySubsequences:true) {
   let raw=String(line)
   guard let separator=raw.firstIndex(of:" ") else{throw SFTPError.message("服务器未返回标准 MLSD 目录格式")}
   let factsText=raw[..<separator],name=String(raw[raw.index(after:separator)...]);var facts=[String:String]()
   guard factsText.hasSuffix(";") else{throw SFTPError.message("无效的 MLSD 属性")}
   for fact in factsText.split(separator:";") {guard let equals=fact.firstIndex(of:"=") else{throw SFTPError.message("无效的 MLSD 属性")};let key=String(fact[..<equals]).lowercased();guard facts[key]==nil else{throw SFTPError.message("重复的 MLSD 属性")};facts[key]=String(fact[fact.index(after:equals)...])}
   let type=facts["type"]?.lowercased();if type=="cdir" || type=="pdir" {continue}
   _ = try RemoteFileName.validated(name);guard seen.insert(Data(name.utf8)).inserted,result.count<50000 else{throw SFTPError.message("FTP 目录存在重复文件名或超过 50000 项")}
   let size:UInt64;if let rawSize=facts["size"]{guard let value=UInt64(rawSize) else{throw SFTPError.message("无效的 FTP 文件大小")};size=value}else{size=0}
   let reportedLink=(type?.hasPrefix("os.unix=slink") ?? false) || type=="slink" || facts["unix.slink"] != nil
   let mode:UInt32=reportedLink ? 0o120000 : type=="dir" ? 0o040000 : type=="file" ? 0o100000 : 0
   var modified:Date?;if let date=facts["modify"],date.count>=14 {modified=format.date(from:String(date.prefix(14)))}
   result.append(RemoteFile(name:name,size:size,directory:mode==0o040000,mode:mode,modified:modified,sizeAvailable:facts["size"] != nil))
  };return result
 }
}
// One operation at a time per instance. Credentials are supplied to curl over an anonymous
// pipe, never in argv, a persistent config, the session archive or a shell.
final class FTPClient {
 private(set) var didAuthenticate=false
 let session:Session;private let password:String;private let lock=NSLock();private var process:Process?;private var cancelled=false;private var localStagingDirectory:URL?
 let maximumTime:Double;let caFile:URL?
 init(session:Session,password:String,maximumTime:Double=3600,caFile:URL?=nil)throws {_ = try session.validatedFTP();signal(SIGPIPE,SIG_IGN);guard password.utf8.count<=4096,!password.unicodeScalars.contains(where:{$0.value<32 || $0.value==127}),maximumTime>0,maximumTime<=3600 else{throw SFTPError.message("FTP 密码或超时参数无效")};self.session=session;self.password=password;self.maximumTime=maximumTime;self.caFile=caFile}
 func cancel(){lock.lock();cancelled=true;let running=process,staging=localStagingDirectory;lock.unlock();if let running=running,running.isRunning{running.terminate()};if let staging=staging{try? FileManager.default.removeItem(at:staging)}}
 static func quoted(_ value:String)->String {"\""+value.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\"",with:"\\\"").replacingOccurrences(of:"\r",with:"\\r").replacingOccurrences(of:"\n",with:"\\n").replacingOccurrences(of:"\t",with:"\\t")+"\""}
 private func run(url:String,options:[String],outputLimit:Int=16*1024*1024)throws->Data {
  lock.lock();let stopped=cancelled;lock.unlock();guard !stopped else{throw SFTPError.message("FTP 操作已取消")}
  var config=["silent","show-error","globoff","ftp-pasv","ftp-skip-pasv-ip","proxy = \"\"","noproxy = \"*\"","proto = \"=ftp,ftps\"","speed-limit = 1","speed-time = 60","connect-timeout = \(session.connectionTimeout ?? 15)","max-time = \(maximumTime)","quote = \"*OPTS UTF8 ON\"","user = "+Self.quoted(session.user+":"+password),"url = "+Self.quoted(url)]
  if session.ftp?.security != .plain{config.append("ssl-reqd")};if let caFile=caFile{config.append("cacert = "+Self.quoted(caFile.path))};config += options
  let task=Process(),input=Pipe(),output=Pipe(),errors=Pipe();task.executableURL=URL(fileURLWithPath:"/usr/bin/curl");task.arguments=["--disable","--config","-"];task.standardInput=input;task.standardOutput=output;task.standardError=errors
  lock.lock();guard !cancelled else{lock.unlock();throw SFTPError.message("FTP 操作已取消")};do{try task.run();process=task;lock.unlock()}catch{lock.unlock();throw error}
  let group=DispatchGroup(),bufferLock=NSLock();var result=Data(),diagnostic=Data(),overflow=false
  func drain(_ file:FileHandle,limit:Int,isError:Bool){group.enter();DispatchQueue.global().async{defer{group.leave()};while let bytes=try? file.read(upToCount:16384),!bytes.isEmpty{bufferLock.lock();let count=isError ? diagnostic.count : result.count;if bytes.count>limit-count{overflow=true;bufferLock.unlock();if task.isRunning{task.terminate()};continue};if isError{diagnostic.append(bytes)}else{result.append(bytes)};bufferLock.unlock()}}}
  drain(output.fileHandleForReading,limit:outputLimit,isError:false);drain(errors.fileHandleForReading,limit:65536,isError:true)
  do{try input.fileHandleForWriting.write(contentsOf:Data((config.joined(separator:"\n")+"\n").utf8));try input.fileHandleForWriting.close()}catch{try? input.fileHandleForWriting.close();if task.isRunning{task.terminate()}}
  task.waitUntilExit();group.wait();lock.lock();process=nil;let wasCancelled=cancelled;lock.unlock()
  if wasCancelled{throw SFTPError.message("FTP 操作已取消；已完成的远程更改可能保留，请刷新确认")};guard !overflow else{throw SFTPError.message("FTP 响应超过大小限制")}
  guard task.terminationStatus==0 else{var text=String(decoding:diagnostic,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines);if !password.isEmpty{text=text.replacingOccurrences(of:password,with:"••••")};throw SFTPError.message("FTP 失败（\(task.terminationStatus)）："+String(text.prefix(2000)))};didAuthenticate=true;return result
 }
 func list(_ directory:String)throws->[RemoteFile] {try FTPListing.decode(run(url:FTPPath.url(session:session,path:directory,directory:true),options:["request = \"MLSD\""]))}
 // Bounded RETR is kept in memory; editor text never uses an unrestricted download.
 func readText(_ remote:String)throws->RemoteText {
  let path=try mutablePath(remote),parent=(path as NSString).deletingLastPathComponent,name=(path as NSString).lastPathComponent
  func entry()throws->RemoteFile {guard let entry=try list(parent).first(where:{Data($0.name.utf8)==Data(name.utf8)}),entry.mode&0o170000==0o100000,!entry.directory,entry.size<=UInt64(RemoteText.maximumBytes) else{throw SFTPError.message("只能编辑 MLSD 报告的普通文本文件，最大 4 MiB；请刷新或下载后打开。")};return entry}
  let before=try entry();let data=try run(url:FTPPath.url(session:session,path:path,directory:false),options:["max-filesize = \(RemoteText.maximumBytes)"],outputLimit:RemoteText.maximumBytes)
  let after=try entry();guard before.size==after.size,before.modified==after.modified else{throw SFTPError.message("读取期间远程文件已变化，请重新打开。")};return try RemoteText(data:data)
 }
 func saveText(_ data:Data,to remote:String,expected:Data)throws {
  guard data.count<=RemoteText.maximumBytes,expected.count<=RemoteText.maximumBytes else{throw SFTPError.message("编辑文件不能超过 4 MiB")};_ = try RemoteText(data:data);_ = try RemoteText(data:expected)
  let path=try mutablePath(remote),parent=(path as NSString).deletingLastPathComponent
  guard try readText(path).original==expected else{throw SFTPError.message("远程文件已被其他程序修改，未保存。请重新打开并合并修改。")}
  let local=try createUploadStaging();defer{releaseUploadStaging(local)};let snapshot=local.appendingPathComponent("text")
  let fd=Darwin.open(snapshot.path,O_CREAT|O_WRONLY|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600);guard fd>=0 else{throw SFTPError.message("无法创建私有编辑暂存文件")};defer{Darwin.close(fd)}
  try data.withUnsafeBytes{(bytes:UnsafeRawBufferPointer) in var offset=0;while offset<bytes.count {let count=Darwin.write(fd,bytes.baseAddress!.advanced(by:offset),bytes.count-offset);if count<0&&errno==EINTR{continue};guard count>0 else{throw SFTPError.message("编辑暂存写入失败")};offset+=count}}
  guard fsync(fd)==0 else{throw SFTPError.message("编辑暂存同步失败")};try checkUploadCancellation()
  let temporary=try FTPPath.child(".macterm-editor-"+UUID().uuidString,in:parent)
  guard !(try list(parent)).contains(where:{Data($0.name.utf8)==Data((temporary as NSString).lastPathComponent.utf8)}) else{throw SFTPError.message("FTP 临时名称冲突，未保存")}
  var publishing=false
  do {
   _ = try run(url:FTPPath.url(session:session,path:temporary,directory:false),options:["upload-file = "+Self.quoted(snapshot.path)],outputLimit:65536)
   guard try readText(temporary).original==data else{throw SFTPError.message("服务器暂存内容与本次编辑不一致，未发布替换。")}
   guard try readText(path).original==expected else{throw SFTPError.message("上传期间远程文件已被其他程序修改，未发布替换。")}
   try checkUploadCancellation();publishing=true;try fileCommand(["RNFR "+temporary,"RNTO "+path])
  }catch{throw SFTPError.message((publishing ? "FTP 保存发布结果未获确认，请先刷新核对目标。" : "FTP 保存未完成，未请求替换原文件。")+"临时文件可能保留："+temporary+"。未自动删除远端项目。"+error.localizedDescription)}
 }
 private func fileCommand(_ commands:[String])throws {
  do{_ = try run(url:FTPPath.url(session:session,path:"/",directory:true),options:["head"]+commands.map{"quote = "+Self.quoted($0)},outputLimit:65536)}
  catch{throw SFTPError.message("FTP 文件操作未获成功确认；服务器可能已完成部分更改，请刷新核对。"+error.localizedDescription)}
 }
 private func mutablePath(_ path:String)throws->String {let value=try FTPPath.normalize(path);guard value != "/" else{throw SFTPError.message("不能修改 FTP 根目录")};return value}
 func mkdir(_ path:String)throws {try fileCommand(["MKD "+mutablePath(path)])}
 func rename(_ from:String,to destination:String)throws {let source=try mutablePath(from),target=try mutablePath(destination);guard Data(source.utf8) != Data(target.utf8) else{throw SFTPError.message("名称未改变")};try fileCommand(["RNFR "+source,"RNTO "+target])}
 func remove(_ path:String,directory:Bool=false)throws {try fileCommand([(directory ? "RMD " : "DELE ")+mutablePath(path)])}
 func download(_ remote:String,to destination:URL,allowOverwrite:Bool=true)throws {
  guard destination.isFileURL else{throw SFTPError.message("下载位置必须是本机文件")}
  let directory=destination.deletingLastPathComponent().appendingPathComponent(".macterm-ftp-download-"+UUID().uuidString)
  let stagingFile=directory.appendingPathComponent("data")
  lock.lock();guard !cancelled else{lock.unlock();throw SFTPError.message("下载已取消")}
  do{try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])}catch{lock.unlock();throw error}
  let descriptor=Darwin.open(stagingFile.path,O_CREAT|O_WRONLY|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
  guard descriptor>=0 else{lock.unlock();try? FileManager.default.removeItem(at:directory);throw SFTPError.message("无法创建下载暂存文件")};Darwin.close(descriptor);localStagingDirectory=directory;lock.unlock()
  defer{lock.lock();localStagingDirectory=nil;lock.unlock();try? FileManager.default.removeItem(at:directory)}
  _ = try run(url:FTPPath.url(session:session,path:remote,directory:false),options:["output = "+Self.quoted(stagingFile.path)],outputLimit:65536)
  lock.lock();let stopped=cancelled;let published = !stopped && (allowOverwrite ? Darwin.rename(stagingFile.path,destination.path) : Darwin.renamex_np(stagingFile.path,destination.path,UInt32(RENAME_EXCL)))==0;lock.unlock()
  guard !stopped else{throw SFTPError.message("下载已取消，未替换本机文件")};guard published else{throw SFTPError.message("下载完成但无法发布本机文件（可能已有同名项目），未替换目标")}
 }
 // The private sibling staging tree is never merged with an existing target.
 // RENAME_EXCL also protects against targets created during the transfer.
 func downloadDirectory(_ remote:String,to destination:URL,progress:((String)->Void)?=nil)throws {
  guard destination.isFileURL,destination.path != "/" else{throw SFTPError.message("下载位置必须是本机目录")}
  _ = try RemoteFileName.validated(destination.lastPathComponent)
  var existing=stat()
  guard lstat(destination.path,&existing) != 0,errno==ENOENT else{throw SFTPError.message("本机已有同名项目或无法检查目标，未覆盖")}
  func check()throws {lock.lock();let stopped=cancelled;lock.unlock();guard !stopped else{throw SFTPError.message("FTP 目录下载已取消，未发布目录")}}
  try check();progress?("正在扫描目录…")
  let plan=try FTPDirectoryPlan.scan(remote,check:check,list:{path in try check();progress?("正在扫描："+path);return try list(path)})
  let total=plan.fileCount
  let directory=destination.deletingLastPathComponent().appendingPathComponent(".macterm-ftp-directory-"+UUID().uuidString),tree=directory.appendingPathComponent("tree")
  lock.lock();guard !cancelled else{lock.unlock();throw SFTPError.message("FTP 目录下载已取消")}
  guard Darwin.mkdir(directory.path,0o700)==0 else{lock.unlock();throw SFTPError.message("无法创建 FTP 目录下载暂存区")};localStagingDirectory=directory;lock.unlock()
  defer{lock.lock();localStagingDirectory=nil;lock.unlock();try? FileManager.default.removeItem(at:directory)}
  try check();guard Darwin.mkdir(tree.path,0o700)==0 else{throw SFTPError.message("无法创建 FTP 下载目录")}
  var completed=0,bytes:UInt64=0
  progress?("已下载 0/\(total) 个文件")
  for node in plan.nodes {
   try check();let target=tree.appendingPathComponent(node.relative)
   if node.directory {guard Darwin.mkdir(target.path,0o700)==0 else{throw SFTPError.message("本机目录名冲突或无法创建目录："+node.relative)};continue}
   let fd=Darwin.open(target.path,O_CREAT|O_WRONLY|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
   guard fd>=0 else{throw SFTPError.message("本机文件名冲突或无法创建文件："+node.relative)};Darwin.close(fd)
   _ = try run(url:FTPPath.url(session:session,path:node.remote,directory:false),options:["output = "+Self.quoted(target.path)],outputLimit:65536)
   try check();let size=(try FileManager.default.attributesOfItem(atPath:target.path)[.size] as? NSNumber)?.uint64Value ?? 0
   let sum=bytes.addingReportingOverflow(size);bytes=sum.overflow ? UInt64.max : sum.partialValue;completed+=1
   let description=ByteCountFormatter.string(fromByteCount:Int64(min(bytes,UInt64(Int64.max))),countStyle:.file)
   progress?("已下载 \(completed)/\(total) 个文件 · \(description) · \(node.relative)")
  }
  lock.lock();let stopped=cancelled;let published = !stopped && Darwin.renamex_np(tree.path,destination.path,UInt32(RENAME_EXCL))==0;lock.unlock()
  guard !stopped else{throw SFTPError.message("FTP 目录下载已取消，未发布目录")}
  guard published else{throw SFTPError.message("目录下载完成但无法发布（可能已有同名项目），未替换目标")}
  progress?("已完成 · \(completed) 个文件")
 }
 private func checkUploadCancellation()throws {lock.lock();let stopped=cancelled;lock.unlock();guard !stopped else{throw SFTPError.message("FTP 上传已取消")}}
 private func createUploadStaging()throws->URL {
  let directory=FileManager.default.temporaryDirectory.appendingPathComponent("macterm-ftp-upload-"+UUID().uuidString)
  lock.lock();guard !cancelled else{lock.unlock();throw SFTPError.message("FTP 上传已取消")}
  guard Darwin.mkdir(directory.path,0o700)==0 else{lock.unlock();throw SFTPError.message("无法创建本机上传暂存区")};localStagingDirectory=directory;lock.unlock();return directory
 }
 private func releaseUploadStaging(_ directory:URL){lock.lock();localStagingDirectory=nil;lock.unlock();try? FileManager.default.removeItem(at:directory)}
 private func requireAbsentDirectoryTarget(_ final:String)throws {
  let parent=(final as NSString).deletingLastPathComponent,name=(final as NSString).lastPathComponent
  let entries=try list(parent)
  guard !entries.contains(where:{$0.name.compare(name,options:[.caseInsensitive],locale:Locale(identifier:"en_US_POSIX")) == .orderedSame}) else{throw SFTPError.message("远端已有同名项目（含大小写 / 规范化等价名称），不合并或替换目录："+final)}
 }
 private func uploadPath(_ relative:String,in directory:String)throws->String {
  var result=directory;for part in relative.split(separator:"/",omittingEmptySubsequences:false){result=try FTPPath.child(String(part),in:result)};return result
 }
 private func verifyUploadedDirectory(_ source:FTPUploadSource,at remote:String,progress:((String)->Void)?)throws {
  var expected=[Data:[FTPUploadSource.Node]]();for node in source.nodes {let parent=node.components.dropLast().joined(separator:"/");expected[Data(parent.utf8),default:[]].append(node)}
  let directories=[""]+source.nodes.filter{$0.directory}.map{$0.relative}
  for relative in directories {
   try checkUploadCancellation();let path=relative.isEmpty ? remote : try uploadPath(relative,in:remote);progress?("正在核对远端目录："+(relative.isEmpty ? "/" : relative))
   let actual=try list(path),children=expected[Data(relative.utf8)] ?? []
   guard actual.count==children.count else{throw SFTPError.message("上传后的远端目录项目不匹配，未发布："+relative)}
   let byName=Dictionary(uniqueKeysWithValues:actual.map{(Data($0.name.utf8),$0)})
   for node in children {let name=node.components.last!;guard let entry=byName[Data(name.utf8)],FTPBatch.canDownload(entry),entry.directory==node.directory else{throw SFTPError.message("远端文件名或类型改变（可能存在名称冲突），未发布："+node.relative)}}
  }
 }
 /// Delete only exact paths created/attempted by this operation, never traverse
 /// server-supplied contents. Cleanup has its own short total time budget.
 private func cleanUploadedDirectory(_ directory:String,owned:[(String,Bool)])->Bool {
  let deadline=Date().addingTimeInterval(8);var index=owned.count
  while index>0,deadline.timeIntervalSinceNow>0.5 {
   var commands=[String](),bytes=0
   while index>0,commands.count<64 {
    let item=owned[index-1],command="*"+(item.1 ? "RMD " : "DELE ")+item.0,cost=command.utf8.count
    if !commands.isEmpty && cost>32768-bytes {break};index-=1;bytes+=cost;commands.append(command)
   }
   do {let cleaner=try FTPClient(session:session,password:password,maximumTime:min(3,max(0.1,deadline.timeIntervalSinceNow)),caFile:caFile);try cleaner.fileCommand(commands)}catch{break}
  }
  guard deadline.timeIntervalSinceNow>0 else{return false}
  do {let cleaner=try FTPClient(session:session,password:password,maximumTime:min(3,max(0.1,deadline.timeIntervalSinceNow)),caFile:caFile),parent=(directory as NSString).deletingLastPathComponent,name=(directory as NSString).lastPathComponent
   return try !cleaner.list(parent).contains{Data($0.name.utf8)==Data(name.utf8)}
  }catch{return false}
 }
 func uploadDirectory(_ source:URL,to remote:String,progress:((String)->Void)?=nil)throws {
  try checkUploadCancellation();progress?("正在扫描本机目录…")
  let plan=try FTPUploadSource(source,expectDirectory:true,check:checkUploadCancellation),final=try mutablePath(remote)
  try requireAbsentDirectoryTarget(final)
  let temporary=try FTPPath.child(".macterm-directory-"+UUID().uuidString,in:(final as NSString).deletingLastPathComponent)
  // Validate every remote path before the first remote change.
  var remotePathBytes=temporary.utf8.count
  for node in plan.nodes {let path=try uploadPath(node.relative,in:temporary),cost=path.utf8.count;guard cost<=32*1024*1024-remotePathBytes else{throw SFTPError.message("FTP 上传目录累计远端路径超过 32 MB")};remotePathBytes+=cost}
  let local=try createUploadStaging();defer{releaseUploadStaging(local)}
  var owned=[(String,Bool)](),rootConfirmed=false,publishing=false
  do {
   try mkdir(temporary);rootConfirmed=true;owned.append((temporary,true));var completed=0,bytes:UInt64=0;let total=plan.fileCount
   progress?("已上传 0/\(total) 个文件")
   for node in plan.nodes {
    try checkUploadCancellation();let target=try uploadPath(node.relative,in:temporary)
    if node.directory {try mkdir(target);owned.append((target,true));continue}
    progress?("已上传 \(completed)/\(total) 个文件 · 正在准备："+node.relative)
    let snapshot=local.appendingPathComponent("file");defer{try? FileManager.default.removeItem(at:snapshot)}
    let size=try plan.snapshot(node,to:snapshot,check:checkUploadCancellation)
    try checkUploadCancellation();owned.append((target,false)) // STOR can leave a partial file on failure.
    _ = try run(url:FTPPath.url(session:session,path:target,directory:false),options:["upload-file = "+Self.quoted(snapshot.path)],outputLimit:65536)
    completed+=1;let sum=bytes.addingReportingOverflow(size);bytes=sum.overflow ? UInt64.max : sum.partialValue
    progress?("已上传 \(completed)/\(total) 个文件 · "+ByteCountFormatter.string(fromByteCount:Int64(min(bytes,UInt64(Int64.max))),countStyle:.file)+" · "+node.relative)
   }
   try plan.verifyUnchanged(check:checkUploadCancellation);try verifyUploadedDirectory(plan,at:temporary,progress:progress)
   try requireAbsentDirectoryTarget(final);try checkUploadCancellation();publishing=true
   // FTP has no universal atomic no-replace RNTO. Both checks reduce but cannot
   // eliminate concurrent target creation; the upload UI explains this limit.
   try rename(temporary,to:final);progress?("已完成 · \(completed) 个文件")
  }catch {
   progress?("正在清理本次上传暂存目录…")
   let cleaned=rootConfirmed && cleanUploadedDirectory(temporary,owned:owned)
   let cleanup=cleaned ? "暂存路径已不存在。" : "暂存目录可能保留："+temporary+"。"
   let outcome=publishing ? "发布结果未确认，请刷新核对目标；未自动删除目标。" : "未发送目录发布重命名。"
   throw SFTPError.message(error.localizedDescription+"\n"+cleanup+outcome)
  }
 }
 func upload(_ source:URL,to remote:String)throws {
  try checkUploadCancellation();let plan=try FTPUploadSource(source,expectDirectory:false,check:checkUploadCancellation)
  let local=try createUploadStaging();defer{releaseUploadStaging(local)}
  let snapshot=local.appendingPathComponent("file");_ = try plan.snapshot(plan.nodes[0],to:snapshot,check:checkUploadCancellation)
  let final=try FTPPath.normalize(remote),parent=(final as NSString).deletingLastPathComponent,temporary=try FTPPath.child(".macterm-upload-"+UUID().uuidString,in:parent)
  // Post-transfer rename publishes only after STOR succeeds. FTP RNTO may replace
  // a concurrent same-name target; the UI requires an explicit overwrite notice.
  _ = try run(url:FTPPath.url(session:session,path:temporary,directory:false),options:["upload-file = "+Self.quoted(snapshot.path),"quote = "+Self.quoted("-RNFR "+temporary),"quote = "+Self.quoted("-RNTO "+final)],outputLimit:65536)
 }
}
