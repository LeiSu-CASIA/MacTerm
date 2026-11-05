import Foundation

extension SFTPClient {
 private func validateName(_ name:String)throws {guard !name.isEmpty,name != ".",name != "..",!name.contains("/"),!name.contains("\0") else{throw SFTPError.message("服务器返回了不安全的文件名")}}
 private func join(_ path:String,_ name:String)throws->String {try validateName(name);return (path=="/" ? "/" : path+"/")+name}
 private func copyLocalTree(_ local:URL,to remote:String,depth:Int)throws {
  guard depth<64 else{throw SFTPError.message("目录层级超过 64 层")}
  let values=try local.resourceValues(forKeys:[.isSymbolicLinkKey,.isDirectoryKey,.isRegularFileKey])
  guard values.isSymbolicLink != true else{throw SFTPError.message("暂不上传符号链接：\(local.lastPathComponent)")}
  if values.isDirectory == true {try mkdir(remote);for child in try FileManager.default.contentsOfDirectory(at:local,includingPropertiesForKeys:nil){try copyLocalTree(child,to:join(remote,child.lastPathComponent),depth:depth+1)}}
  else if values.isRegularFile == true {try upload(local,to:remote)}
  else {throw SFTPError.message("不支持的文件类型：\(local.lastPathComponent)")}
 }
 private func removeStagingTree(_ path:String,depth:Int=0)throws {
  guard depth<64 else{return}
  let mode=try attributes(path,followLinks:false).1
  if mode&0o170000 == 0o040000 {for child in try list(path){try removeStagingTree(join(path,child.name),depth:depth+1)};try remove(path,directory:true)}else{try remove(path)}
 }
 func uploadItem(_ local:URL,to remote:String)throws {
  let values=try local.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
  guard values.isSymbolicLink != true else{throw SFTPError.message("暂不上传符号链接")}
  guard values.isDirectory == true else{try upload(local,to:remote);return}
  let parent=(remote as NSString).deletingLastPathComponent
  let staging=try join(parent.isEmpty ? "." : parent,".macterm-directory-"+UUID().uuidString)
  var committed=false;defer{if !committed {try? removeStagingTree(staging)}}
  try copyLocalTree(local,to:staging,depth:0);try rename(staging,to:remote);committed=true
 }
 private func copyRemoteTree(_ remote:String,to local:URL,depth:Int)throws {
  guard depth<64 else{throw SFTPError.message("目录层级超过 64 层")}
  guard !FileManager.default.fileExists(atPath:local.path) else{throw SFTPError.message("下载目录存在文件名冲突，未覆盖：\(local.lastPathComponent)")}
  let mode=try attributes(remote,followLinks:false).1
  if mode&0o170000 == 0o040000 {try FileManager.default.createDirectory(at:local,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);for entry in try list(remote){try validateName(entry.name);try copyRemoteTree(join(remote,entry.name),to:local.appendingPathComponent(entry.name),depth:depth+1)}}
  else if mode&0o170000 == 0o100000 {try download(remote,to:local)}
  else {throw SFTPError.message("目录中含有符号链接或不支持的特殊文件，未发布下载目录")}
 }
 func downloadItem(_ remote:String,to local:URL)throws {
  let mode=try attributes(remote,followLinks:false).1
  guard mode&0o170000 == 0o040000 else {guard mode&0o170000 == 0o100000 else{throw SFTPError.message("暂不下载符号链接或特殊文件")};try download(remote,to:local);return}
  guard !FileManager.default.fileExists(atPath:local.path) else{throw SFTPError.message("本地已有同名目录，未覆盖")}
  let staging=local.deletingLastPathComponent().appendingPathComponent(".macterm-directory-"+UUID().uuidString);defer{try? FileManager.default.removeItem(at:staging)}
  try copyRemoteTree(remote,to:staging,depth:0);try FileManager.default.moveItem(at:staging,to:local)
 }
}

// Owned by one workspace; all state transitions happen on the main thread.
enum TransferState:Equatable {
 case waiting,running,succeeded,failed(String),cancelled
 var text:String {switch self {case .waiting:return "等待中";case .running:return "传输中";case .succeeded:return "已完成";case .failed(let message):return "失败："+message;case .cancelled:return "已取消"}}
 var retryable:Bool {switch self {case .failed,.cancelled:return true;default:return false}}
}
final class TransferJob {
 let id=UUID();let local:URL;let remote:String;let uploading:Bool;let allowOverwrite:Bool;let isDirectory:Bool
 var onFinish:((Error?)->Void)?;var expectedDirectory:Bool?;var publishDownload:((URL,URL)throws->Void)?
 func deliver(_ error:Error?){let callback=onFinish;onFinish=nil;callback?(error)}
 var state:TransferState = .waiting;var progress=""
 init(local:URL,remote:String,uploading:Bool,allowOverwrite:Bool=false,isDirectory:Bool=false){self.local=local;self.remote=remote;self.uploading=uploading;self.allowOverwrite=allowOverwrite;self.isDirectory=isDirectory}
 func perform(_ client:SFTPClient)throws {
  if uploading {try client.uploadItem(local,to:remote)}
  else if allowOverwrite{try client.downloadItem(remote,to:local)}
  else{try client.downloadExclusive(remote,to:local,expectedDirectory:expectedDirectory,publish:publishDownload)}
 }
}
final class TransferQueue {
 var jobs=[TransferJob]();private(set) var active:TransferJob?;private(set) var closed=false;private(set) var cancellationGeneration=UUID()
 var changed:(()->Void)?;var execute:((TransferJob,@escaping(Error?)->Void)->Void)?;var cancelActive:(()->Void)?
 private var cancelling=false
 func enqueue(_ items:[TransferJob]){guard !closed else{return};jobs+=items;changed?();pump()}
 private func pump(){guard !closed,active==nil,let job=jobs.first(where:{$0.state == .waiting}),let execute=execute else{return};active=job;cancelling=false;job.state = .running;changed?();execute(job){[weak self,weak job] error in guard let self=self,let job=job,self.active === job else{return};job.state=self.cancelling ? .cancelled : error.map{.failed($0.localizedDescription)} ?? .succeeded;let outcome:Error?=self.cancelling ? SFTPError.message("下载已取消；已完成的项目可能保留") : error;self.active=nil;self.cancelling=false;job.deliver(outcome);self.changed?();self.pump()}}
 func updateProgress(_ value:String){active?.progress=value;changed?()}
 func cancel(){cancellationGeneration=UUID();let waiting=jobs.filter{$0.state == .waiting};for job in waiting {job.state = .cancelled};for job in waiting{job.deliver(SFTPError.message("排队下载已取消"))};if active != nil {cancelling=true;cancelActive?()};changed?()}
 func retry(){guard !closed,active==nil else{return};for job in jobs where job.state.retryable {job.state = .waiting;job.progress=""};changed?();pump()}
 func clearFinished(){jobs.removeAll{$0.state == .succeeded};changed?()}
 func close(){guard !closed else{return};closed=true;cancel()}
}

import Cocoa
final class TransferQueueWindow:NSWindowController,NSTableViewDataSource,NSTableViewDelegate {
 let queue:TransferQueue;let table=NSTableView();let summary=NSTextField(labelWithString:"");var retryControl:NSButton?;var retryAllowed:(()->Bool)?
 init(queue:TransferQueue){self.queue=queue;let window=NSWindow(contentRect:NSRect(x:0,y:0,width:720,height:350),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false);window.title="SFTP 传输队列";window.minSize=NSSize(width:580,height:240);window.appearance=NSAppearance(named:.darkAqua);window.isReleasedWhenClosed=false;super.init(window:window)
  let stack=NSStackView();stack.orientation = .vertical;stack.spacing=8;stack.edgeInsets=NSEdgeInsets(top:12,left:12,bottom:12,right:12);stack.translatesAutoresizingMaskIntoConstraints=false;window.contentView!.addSubview(stack);NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor),stack.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor),stack.topAnchor.constraint(equalTo:window.contentView!.topAnchor),stack.bottomAnchor.constraint(equalTo:window.contentView!.bottomAnchor)])
  for (name,width) in [("文件",180.0),("状态",220.0),("目标",270.0)] {let column=NSTableColumn(identifier:NSUserInterfaceItemIdentifier(name));column.title=name;column.width=width;table.addTableColumn(column)};table.dataSource=self;table.delegate=self;table.rowHeight=28
  let scroll=NSScrollView();scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:120).isActive=true;scroll.setContentHuggingPriority(NSLayoutConstraint.Priority(1),for:.vertical);scroll.hasVerticalScroller=true;scroll.hasHorizontalScroller=true;scroll.documentView=table;stack.addArrangedSubview(scroll);scroll.widthAnchor.constraint(equalTo:stack.widthAnchor,constant:-24).isActive=true
  let actions=NSStackView();for (title,selector) in [("取消全部未完成",#selector(cancel)),("重试失败 / 已取消",#selector(retry)),("清除已完成",#selector(clear))]{let button=NSButton(title:title,target:self,action:selector);if selector == #selector(retry){retryControl=button};actions.addArrangedSubview(button)};stack.addArrangedSubview(actions);stack.addArrangedSubview(summary);window.center();reload()
 }
 required init?(coder:NSCoder){fatalError()}
 func numberOfRows(in tableView:NSTableView)->Int{queue.jobs.count}
 func tableView(_ tableView:NSTableView,viewFor column:NSTableColumn?,row:Int)->NSView?{let job=queue.jobs[row];let value:String;switch column?.identifier.rawValue {case "文件":value=(job.uploading ? "↑ " : "↓ ")+job.local.lastPathComponent;case "目标":value=job.uploading ? job.remote : job.local.path;default:value=job.state.text+(job.state == .running && !job.progress.isEmpty ? " · "+job.progress : "")};let field=NSTextField(labelWithString:value);field.lineBreakMode = .byTruncatingMiddle;field.toolTip=value;return field}
 func reload(){table.reloadData();retryControl?.isEnabled = !queue.closed && queue.active == nil && (retryAllowed?() ?? true) && queue.jobs.contains{$0.state.retryable};summary.stringValue=(queue.closed ? "会话已关闭 · " : "")+"共 \(queue.jobs.count) 项 · 完成 \(queue.jobs.filter{$0.state == .succeeded}.count) · 失败 / 取消 \(queue.jobs.filter{$0.state.retryable}.count)"}
 @objc func cancel(){queue.cancel()}
 @objc func retry(){guard retryAllowed?() ?? true else{return};queue.retry()}
 @objc func clear(){queue.clearFinished()}
}
