import Cocoa

enum FTPBatch {
 static func uploads(_ urls:[URL],directory:String)throws->[TransferJob] {
  guard !urls.isEmpty,urls.count<=200 else{throw SFTPError.message("一次选择 1–200 个文件或目录")}
  var destinations=Set<Data>()
  return try urls.map{url in
   guard url.isFileURL else{throw SFTPError.message("上传源必须是本机文件地址")};let values=try url.resourceValues(forKeys:[.isRegularFileKey,.isDirectoryKey,.isSymbolicLinkKey]);guard url.isFileURL,(values.isRegularFile==true || values.isDirectory==true),values.isSymbolicLink != true else{throw SFTPError.message("FTP 上传只接受普通文件或目录，不跟随符号链接")}
   let target=try FTPPath.child(url.lastPathComponent,in:directory);guard destinations.insert(Data(target.utf8)).inserted else{throw SFTPError.message("选中的文件有同名目标，请分开上传")}
   return TransferJob(local:url,remote:target,uploading:true,allowOverwrite:values.isDirectory != true,isDirectory:values.isDirectory==true)
  }
 }
 static func canDownload(_ entry:RemoteFile)->Bool {(entry.mode&0o170000==0o100000 && !entry.directory) || (entry.mode&0o170000==0o040000 && entry.directory)}
 static func downloads(_ entries:[RemoteFile],directory:String,to local:URL)throws->[TransferJob] {
  guard !entries.isEmpty,entries.count<=200,local.isFileURL else{throw SFTPError.message("一次选择 1–200 个文件或目录和本机下载目录")}
  var names=Set<Data>();return try entries.map{entry in
   guard FTPBatch.canDownload(entry),names.insert(Data(entry.name.utf8)).inserted else{throw SFTPError.message("下载只接受不同的普通文件或目录，不包含链接或未知类型")}
   let source=try FTPPath.child(entry.name,in:directory)
   return TransferJob(local:local.appendingPathComponent(entry.name),remote:source,uploading:false,allowOverwrite:false,isDirectory:entry.directory)
  }
 }
}
extension FTPWorkspace {
 var selectedFTPFiles:[RemoteFile] {table.selectedRowIndexes.compactMap{entries.indices.contains($0) ? entries[$0] : nil}}
 func configureFTPTransfers(){
  transferQueue.changed = {[weak self] in self?.updateControls()}
  transferQueue.cancelActive = {[weak self] in self?.cancelCurrentFTP()}
  transferQueue.execute = {[weak self] item,done in
   guard let self=self,!self.stopped,!self.busy else{done(SFTPError.message("FTP 会话已关闭或正忙，请稍后重试"));return}
   self.queueFinish=done
   self.perform(item.uploading ? (item.isDirectory ? "上传 FTP 目录…" : "上传 FTP 文件…") : item.isDirectory ? "下载 FTP 目录…" : "下载 FTP 文件…",work:{client in
    let report:(String)->Void = {[weak self,weak item] message in DispatchQueue.main.async {guard let self=self,let item=item else{return};self.updateFTPTransferProgress(message,for:item)}}
    if item.uploading && item.isDirectory {try client.uploadDirectory(item.local,to:item.remote,progress:report)}
    else if item.uploading{try client.upload(item.local,to:item.remote)}
    else if item.isDirectory {try client.downloadDirectory(item.remote,to:item.local,progress:report)}
    else{try client.download(item.remote,to:item.local,allowOverwrite:item.allowOverwrite)}
   },completion:{[weak self] error in
    guard let self=self else{done(error);return};self.queueFinish=nil;if item.uploading,error==nil{self.pendingQueueRefresh=true};done(error)
    guard !self.stopped,self.transferQueue.active==nil else{return}
    if self.pendingQueueRefresh{self.pendingQueueRefresh=false;self.refresh()}
    else{self.status.stringValue="队列已结束 · 完成 \(self.transferQueue.jobs.filter{$0.state == .succeeded}.count) 项 · 失败 / 取消 \(self.transferQueue.jobs.filter{$0.state.retryable}.count) 项";self.status.toolTip=error?.localizedDescription ?? self.status.stringValue}
   })
  }
 }
 func enqueueFTPJobs(_ jobs:[TransferJob],showQueue:Bool=false){
  guard canManageFTPFiles else{return}
  guard !jobs.isEmpty,jobs.count<=200,transferQueue.jobs.count+jobs.count<=1000 else{status.stringValue="一次最多 200 项，队列最多 1000 项；请清除已完成项目。";return}
  transferQueue.enqueue(jobs);if showQueue{showFTPTransfers()}
 }
 func enqueueFTPUploads(_ urls:[URL],to directory:String,showQueue:Bool=false){do{enqueueFTPJobs(try FTPBatch.uploads(urls,directory:directory),showQueue:showQueue)}catch{status.stringValue=error.localizedDescription;status.toolTip=status.stringValue}}
 func enqueueFTPDownloads(_ files:[RemoteFile],from directory:String,to local:URL,showQueue:Bool=false){do{enqueueFTPJobs(try FTPBatch.downloads(files,directory:directory,to:local),showQueue:showQueue)}catch{status.stringValue=error.localizedDescription;status.toolTip=status.stringValue}}
 @objc func showFTPTransfers(){
  if transferWindow==nil{transferWindow=TransferQueueWindow(queue:transferQueue);transferWindow?.window?.title="FTP 传输队列 · "+session.name;transferWindow?.retryAllowed = {[weak self] in self?.canManageFTPFiles==true}}
  transferWindow?.reload();transferWindow?.showWindow(nil);transferWindow?.window?.makeKeyAndOrderFront(nil)
 }
}
