import Cocoa
@main struct TransferTests {
 static func main()throws {
  if CommandLine.arguments.contains("--preview") || Bundle.main.bundleIdentifier == "local.macterm.transfer-preview" {
   let app=NSApplication.shared;app.setActivationPolicy(.regular)
   let preview=TransferQueue();var finish:((Error?)->Void)?
   preview.execute={_,done in finish=done};preview.cancelActive={finish?(SFTPError.message("预览取消"))}
   let items=["中文文件.txt","已有同名文件.txt","目录备份","等待上传.txt"].map{TransferJob(local:URL(fileURLWithPath:"/tmp/"+$0),remote:"/home/demo/"+$0,uploading:true)}
   preview.enqueue(items);finish?(nil);finish?(SFTPError.message("远程已有同名项目，未覆盖"));preview.updateProgress("32 KB / 80 KB")
   let controller=TransferQueueWindow(queue:preview);preview.changed={controller.reload()};controller.showWindow(nil);app.activate(ignoringOtherApps:true);app.run();return
  }

  let root=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("macterm-tree-"+UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
  let source=root.appendingPathComponent("source"),folder=source.appendingPathComponent("中文 子目录");try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true);try FileManager.default.createDirectory(at:source.appendingPathComponent("empty"),withIntermediateDirectories:true)
  let payload=Data((0..<80000).map{UInt8($0%251)});try payload.write(to:folder.appendingPathComponent("特殊 ' \" ; $file"));try Data("root".utf8).write(to:source.appendingPathComponent("root.txt"))
  let client=try SFTPClient(command:"/usr/libexec/sftp-server",arguments:[]);defer{client.close()}
  let remote=root.appendingPathComponent("remote");try client.uploadItem(source,to:remote.path)
  let copy=root.appendingPathComponent("copy");try client.downloadItem(remote.path,to:copy)
  let received=try Data(contentsOf:copy.appendingPathComponent("中文 子目录/特殊 ' \" ; $file"));precondition(received==payload);var directory:ObjCBool=false;precondition(FileManager.default.fileExists(atPath:copy.appendingPathComponent("empty").path,isDirectory:&directory) && directory.boolValue)
  do {try client.uploadItem(source,to:remote.path);fatalError("Existing remote directory must fail")}catch{}
  do {try client.downloadItem(remote.path,to:copy);fatalError("Existing local directory must fail")}catch{}
  let symlink=source.appendingPathComponent("link");try FileManager.default.createSymbolicLink(at:symlink,withDestinationURL:folder)
  let failed=root.appendingPathComponent("failed");do {try client.uploadItem(source,to:failed.path);fatalError("Symlink upload must fail")}catch{};precondition(!FileManager.default.fileExists(atPath:failed.path))
  try FileManager.default.createSymbolicLink(at:remote.appendingPathComponent("loop"),withDestinationURL:remote)
  let failedCopy=root.appendingPathComponent("failed-copy");do {try client.downloadItem(remote.path,to:failedCopy);fatalError("Remote symlink must not be followed")}catch{};precondition(!FileManager.default.fileExists(atPath:failedCopy.path))
  let leftovers=try FileManager.default.contentsOfDirectory(atPath:root.path);precondition(!leftovers.contains{$0.hasPrefix(".macterm-")})
  let queue=TransferQueue();let first=TransferJob(local:source,remote:remote.path,uploading:true),second=TransferJob(local:source,remote:remote.path,uploading:true),third=TransferJob(local:source,remote:remote.path,uploading:true)
  var starts=[UUID]();var finish:((Error?)->Void)?;var cancellations=0
  queue.execute={job,done in starts.append(job.id);finish=done};queue.cancelActive={cancellations+=1}
  queue.enqueue([first,second,third]);precondition(starts==[first.id] && second.state == .waiting)
  finish?(nil);precondition(first.state == .succeeded && starts==[first.id,second.id])
  finish?(SFTPError.message("fixture failure"));precondition(second.state.retryable && starts==[first.id,second.id,third.id])
  queue.cancel();precondition(cancellations==1 && queue.active === third);finish?(SFTPError.message("cancelled"));precondition(third.state == .cancelled)
  queue.retry();precondition(starts==[first.id,second.id,third.id,second.id]);finish?(nil);precondition(queue.active === third);finish?(nil);precondition(queue.jobs.allSatisfy{$0.state == .succeeded})
  queue.clearFinished();precondition(queue.jobs.isEmpty)
  queue.enqueue([TransferJob(local:source,remote:remote.path,uploading:true),TransferJob(local:source,remote:remote.path,uploading:true)]);let count=starts.count;queue.close();finish?(nil);precondition(queue.jobs.allSatisfy{$0.state == .cancelled} && starts.count==count);queue.retry();precondition(starts.count==count)
  let existingJob=TransferJob(local:copy,remote:remote.path,uploading:false);do{try existingJob.perform(client);fatalError("Queued download must refuse an existing target")}catch{}
  // Exercise scheduler + the actual OpenSSH SFTP server together, including retry.
  let batch=TransferQueue();let batchURLs=(0..<3).map{root.appendingPathComponent("queued-\($0).txt")}
  try Data("occupied".utf8).write(to:batchURLs[1])
  batch.execute={job,done in do {try job.perform(client);done(nil)}catch{done(error)}}
  batch.enqueue(batchURLs.map{TransferJob(local:$0,remote:remote.appendingPathComponent("root.txt").path,uploading:false)})
  precondition(batch.jobs[0].state == .succeeded && batch.jobs[1].state.retryable && batch.jobs[2].state == .succeeded)
  let occupied=try Data(contentsOf:batchURLs[1]);precondition(occupied == Data("occupied".utf8))
  try FileManager.default.removeItem(at:batchURLs[1]);batch.retry();precondition(batch.jobs.allSatisfy{$0.state == .succeeded})
  for url in batchURLs {let value=try Data(contentsOf:url);precondition(value == Data("root".utf8))}
  _ = NSApplication.shared;let queueWindow=TransferQueueWindow(queue:batch);queueWindow.window?.contentView?.layoutSubtreeIfNeeded()
  precondition(queueWindow.table.numberOfRows==3 && queueWindow.window?.appearance?.name == .darkAqua && queueWindow.table.enclosingScrollView!.frame.height>=120)
  queueWindow.close()
  let collisionSource=root.appendingPathComponent("collision-source");try FileManager.default.createDirectory(at:collisionSource,withIntermediateDirectories:false);try Data("preserve first".utf8).write(to:collisionSource.appendingPathComponent("collision.txt"))
  let alias=FileManager.default.fileExists(atPath:collisionSource.appendingPathComponent("COLLISION.TXT").path) ? "COLLISION.TXT" : "collision.txt"
  let colliding=try SFTPClient(command:"/usr/bin/python3",arguments:[FileManager.default.currentDirectoryPath+"/Tests/DirectoryCollisionServer.py",alias]);defer{colliding.close()};let collisionDestination=root.appendingPathComponent("collision-copy")
  do{try colliding.downloadItem(collisionSource.path,to:collisionDestination);fatalError("A colliding nested filename must not overwrite and publish")}catch{precondition(error.localizedDescription.contains("文件名冲突"))};precondition(!FileManager.default.fileExists(atPath:collisionDestination.path));let remaining=try FileManager.default.contentsOfDirectory(atPath:root.path);precondition(!remaining.contains{$0.hasPrefix(".macterm-directory-")})
  print("PASS: recursive download refuses native filesystem name collisions without overwriting or publishing a partial directory")
  print("PASS: serial queue, individual failures, retry skips successes, cancellation, close prevents pending work, existing target protection")
  print("PASS: recursive directory transfer, Unicode and special filenames, empty directories, binary file fidelity, no overwrite, symlink loop refusal, failure staging cleanup")
 }
}
