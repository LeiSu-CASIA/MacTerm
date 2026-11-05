import Cocoa
import Darwin
import UniformTypeIdentifiers

// AppKit retains the provider; userInfo keeps its weak delegate alive until use.
class DownloadFilePromise:NSObject,NSFilePromiseProviderDelegate {
 let name:String,directory:Bool;private var requested=false
 init(name:String,directory:Bool){self.name=name;self.directory=directory;super.init()}
 func provider()->NSFilePromiseProvider {let inferred=UTType(filenameExtension:(name as NSString).pathExtension);let type=directory ? UTType.folder : (inferred?.conforms(to:.data)==true ? inferred! : .data);let provider=NSFilePromiseProvider(fileType:type.identifier,delegate:self);provider.userInfo=self;return provider}
 func filePromiseProvider(_ filePromiseProvider:NSFilePromiseProvider,fileNameForType fileType:String)->String {name}
 func operationQueue(for filePromiseProvider:NSFilePromiseProvider)->OperationQueue {.main}
 func filePromiseProvider(_ filePromiseProvider:NSFilePromiseProvider,writePromiseTo url:URL,completionHandler:@escaping(Error?)->Void){DispatchQueue.main.async {[self] in
  guard !requested else{completionHandler(SFTPError.message("此拖出请求已处理，请重新拖出"));return};requested=true
  do{try SFTPDownloadPublication.validate(url)}catch{completionHandler(error);return};submit(to:url,completion:completionHandler)
 }}
 func submit(to url:URL,completion:@escaping(Error?)->Void){completion(SFTPError.message("此文件承诺没有可用的连接"))}
}
// A promise keeps the original source, even if its workspace changes directories.
final class RemoteFilePromise:DownloadFilePromise {
 weak var workspace:SSHWorkspace?;let source:String,pid:pid_t;let cancellationGeneration:UUID
 init(workspace:SSHWorkspace,entry:RemoteFile){self.workspace=workspace;source=workspace.remote(entry.name);pid=workspace.terminal.pid;cancellationGeneration=workspace.transferQueue.cancellationGeneration;super.init(name:entry.name,directory:entry.directory)}
 override func submit(to url:URL,completion:@escaping(Error?)->Void){
  guard let owner=workspace,!owner.stopped,owner.masterAuthenticated,owner.terminal.pid==pid,owner.terminal.acceptsInput,!owner.transferQueue.closed,owner.transferQueue.cancellationGeneration==cancellationGeneration else{completion(SFTPError.message("原 SSH 连接或传输状态已变化，请重新拖出"));return}
  guard !owner.busy || owner.transferQueue.active != nil,owner.transferQueue.jobs.count<1000 else{completion(SFTPError.message("文件操作正在进行或队列已满，请稍后重新拖出"));return}
  let job=TransferJob(local:url,remote:source,uploading:false,isDirectory:directory);job.expectedDirectory=directory;job.onFinish=completion
  job.publishDownload = {[weak owner] staged,destination in
   guard let owner=owner else{throw SFTPError.message("原连接已关闭")};owner.clientLock.lock();defer{owner.clientLock.unlock()}
   guard !owner.stopped,!owner.cancelRequested else{throw SFTPError.message("拖出下载已取消，未发布目标")};try SFTPDownloadPublication.publish(staged,to:destination)
  };owner.transferQueue.enqueue([job])
 }
}
final class FTPFilePromise:DownloadFilePromise {
 weak var workspace:FTPWorkspace?;let source:String,generation:UUID,cancellationGeneration:UUID
 init(workspace:FTPWorkspace,entry:RemoteFile)throws {self.workspace=workspace;source=try FTPPath.child(entry.name,in:workspace.remotePath);generation=workspace.connectionGeneration;cancellationGeneration=workspace.transferQueue.cancellationGeneration;super.init(name:entry.name,directory:entry.directory)}
 override func submit(to url:URL,completion:@escaping(Error?)->Void){
  guard let owner=workspace,!owner.stopped,owner.hasAuthenticated,owner.connectionGeneration==generation,!owner.transferQueue.closed,owner.transferQueue.cancellationGeneration==cancellationGeneration else{completion(SFTPError.message("原 FTP 登录或传输状态已变化，请重新拖出"));return}
  guard !owner.hasPendingFTPUpload,(!owner.busy || owner.transferQueue.active != nil),owner.transferQueue.jobs.count<1000 else{completion(SFTPError.message("文件操作或上传确认正在进行，或队列已满，请稍后重新拖出"));return}
  let job=TransferJob(local:url,remote:source,uploading:false,isDirectory:directory);job.onFinish=completion;owner.transferQueue.enqueue([job])
 }
}
extension FTPWorkspace {
 func tableView(_ tableView:NSTableView,pasteboardWriterForRow row:Int)->NSPasteboardWriting? {
  guard tableView === table,canManageFTPFiles,hasAuthenticated,directoryHistory.current != nil,transferQueue.jobs.count<1000,entries.indices.contains(row) else{return nil}
  let rows=table.selectedRowIndexes.contains(row) ? table.selectedRowIndexes : IndexSet(integer:row)
  guard rows.count<=200,rows.allSatisfy({entries.indices.contains($0) && FTPBatch.canDownload(entries[$0]) && (try? FTPPath.child(entries[$0].name,in:remotePath)) != nil}) else{return nil}
  return try? FTPFilePromise(workspace:self,entry:entries[row]).provider()
 }
}

enum SFTPDownloadPublication {
 static func validate(_ destination:URL)throws {
  guard destination.absoluteString.utf8.count<=65536,let parts=URLComponents(url:destination,resolvingAgainstBaseURL:false),let decodedPath=parts.percentEncodedPath.removingPercentEncoding,!decodedPath.contains("\0"),destination.user==nil,destination.password==nil,destination.port==nil,destination.isFileURL,["","localhost"].contains(destination.host?.lowercased() ?? ""),destination.query==nil,destination.fragment==nil,destination.path.hasPrefix("/"),!destination.path.contains("\0"),!destination.lastPathComponent.isEmpty,destination.path != "/",![".",".."].contains(destination.lastPathComponent) else{throw SFTPError.message("下载目标必须是有效的本机文件地址")}
 }
 static func publish(_ staged:URL,to destination:URL)throws {
  guard Darwin.renamex_np(staged.path,destination.path,UInt32(RENAME_EXCL))==0 else{throw SFTPError.message("下载完成但无法发布（可能已有同名项目），原目标未覆盖")}
 }
}
extension SFTPClient {
 func downloadExclusive(_ remote:String,to destination:URL,expectedDirectory:Bool?=nil,publish:((URL,URL)throws->Void)?=nil)throws {
  try SFTPDownloadPublication.validate(destination)
  var info=stat();if lstat(destination.path,&info)==0{throw SFTPError.message("本机已有同名项目，未覆盖")};guard errno==ENOENT else{throw SFTPError.message("无法检查下载目标")}
  let attributes=try self.attributes(remote,followLinks:false),directory=attributes.1&0o170000==0o040000
  guard directory || attributes.1&0o170000==0o100000,expectedDirectory==nil || expectedDirectory==directory else{throw SFTPError.message("远程项目类型已变化，或是链接 / 特殊文件，请刷新后重新下载")}
  let staging=destination.deletingLastPathComponent().appendingPathComponent(".macterm-promise-"+UUID().uuidString)
  try FileManager.default.createDirectory(at:staging,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);defer{try? FileManager.default.removeItem(at:staging)}
  let payload=staging.appendingPathComponent("payload");try downloadItem(remote,to:payload)
  let values=try payload.resourceValues(forKeys:[.isDirectoryKey,.isRegularFileKey,.isSymbolicLinkKey]);guard values.isSymbolicLink != true,(directory ? values.isDirectory==true : values.isRegularFile==true) else{throw SFTPError.message("远程项目类型在传输期间变化，未发布目标")}
  try (publish ?? SFTPDownloadPublication.publish)(payload,destination)
 }
}
extension SSHWorkspace {
 func tableView(_ tableView:NSTableView,pasteboardWriterForRow row:Int)->NSPasteboardWriting? {
  guard tableView === files,!busy,!stopped,masterAuthenticated,terminal.acceptsInput,transferQueue.active==nil,transferQueue.jobs.count<1000,directoryHistory.current != nil,entries.indices.contains(row) else{return nil}
  let rows=files.selectedRowIndexes.contains(row) ? files.selectedRowIndexes : IndexSet(integer:row)
  guard rows.count<=200,rows.allSatisfy({entries.indices.contains($0) && (try? RemoteFileName.validated(entries[$0].name)) != nil && (entries[$0].directory ? entries[$0].mode&0o170000==0o040000 : entries[$0].mode&0o170000==0o100000)}) else{return nil}
  return RemoteFilePromise(workspace:self,entry:entries[row]).provider()
 }
}
