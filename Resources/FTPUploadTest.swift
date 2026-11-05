import Cocoa
@main struct FTPUploadTests {
 struct Fixture:Decodable {let session:Session,password:String,root:String;let caFile:String?}
 static let fm=FileManager.default
 static func caught(_ work:()throws->Void)->String {do{try work();fatalError("Failed/unsafe upload accepted")}catch{return error.localizedDescription}}
 static func spin(_ predicate:()->Bool){let deadline=Date().addingTimeInterval(25);while !predicate() && Date()<deadline{RunLoop.current.run(until:Date().addingTimeInterval(0.005))};precondition(predicate(),"FTP upload timed out")}
 static func verify(_ destination:URL)throws {let expected=Set(["nested","nested/中文 ' \" $;[].bin","nested/zero","empty",".hidden"]),paths=try fm.subpathsOfDirectory(atPath:destination.path);precondition(Set(paths)==expected);let bytes=try Data(contentsOf:destination.appendingPathComponent("nested/中文 ' \" $;[].bin"));precondition(bytes==Data((0..<200000).map{UInt8($0%251)}));let hidden=try String(contentsOf:destination.appendingPathComponent(".hidden"),encoding:.utf8);precondition(hidden=="hidden contents");let zero=try Data(contentsOf:destination.appendingPathComponent("nested/zero"));precondition(zero.isEmpty)}
 static func noRemoteStages(_ root:URL)throws {let names=try fm.contentsOfDirectory(atPath:root.path);precondition(!names.contains{$0.hasPrefix(".macterm-directory-")},"Remote staging was not cleaned")}
 static func main()throws {
  _ = NSApplication.shared
  let local=fm.temporaryDirectory.appendingPathComponent("mt-ftp-upload-test-"+UUID().uuidString);try fm.createDirectory(at:local,withIntermediateDirectories:false);defer{try? fm.removeItem(at:local)}
  guard CommandLine.arguments.count==3,CommandLine.arguments[1].hasSuffix("fixture") else {
   let tree=local.appendingPathComponent("folder"),file=local.appendingPathComponent("file");try fm.createDirectory(at:tree,withIntermediateDirectories:false);try Data("source".utf8).write(to:file)
   let jobs=try FTPBatch.uploads([tree,file],directory:"/fixed");precondition(jobs[0].isDirectory && !jobs[0].allowOverwrite && jobs[0].remote=="/fixed/folder" && !jobs[1].isDirectory && jobs[1].allowOverwrite)
   let alias=local.appendingPathComponent("alias");try fm.createSymbolicLink(at:alias,withDestinationURL:tree);_ = caught{_ = try FTPBatch.uploads([alias],directory:"/")}
   let source=try FTPUploadSource(file,expectDirectory:false),copy=local.appendingPathComponent("private-copy");_ = try source.snapshot(source.nodes[0],to:copy);try Data("later edits".utf8).write(to:file);let kept=try String(contentsOf:copy,encoding:.utf8);precondition(kept=="source")
   print("PASS: mixed FTP upload plans preserve item type, fixed targets and file/directory overwrite policy; private snapshot retains selected bytes after source edits");return
  }
  let fixture=try JSONDecoder().decode(Fixture.self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[2]))),server=URL(fileURLWithPath:fixture.root).appendingPathComponent("files"),ca=fixture.caFile.map{URL(fileURLWithPath:$0)}
  let source=local.appendingPathComponent("source"),nested=source.appendingPathComponent("nested");try fm.createDirectory(at:nested,withIntermediateDirectories:true);try fm.createDirectory(at:source.appendingPathComponent("empty"),withIntermediateDirectories:false);try Data("hidden contents".utf8).write(to:source.appendingPathComponent(".hidden"));try Data().write(to:nested.appendingPathComponent("zero"));try Data((0..<200000).map{UInt8($0%251)}).write(to:nested.appendingPathComponent("中文 ' \" $;[].bin"))
  let client=try FTPClient(session:fixture.session,password:fixture.password,maximumTime:20,caFile:ca),name="uploaded-"+UUID().uuidString,remote="/"+name,final=server.appendingPathComponent(name)
  switch CommandLine.arguments[1] {
  case "--upload-failure-fixture","--cleanup-failure-fixture":
   try Data("must fail".utf8).write(to:source.appendingPathComponent("blocked.bin"));let error=caught{try client.uploadDirectory(source,to:remote)};precondition(!fm.fileExists(atPath:final.path))
   if CommandLine.arguments[1]=="--cleanup-failure-fixture" {let stages=try fm.contentsOfDirectory(atPath:server.path).filter{$0.hasPrefix(".macterm-directory-")};precondition(!stages.isEmpty && error.contains("暂存目录可能保留"));for stage in stages{precondition(error.contains(stage))}}
   else{try noRemoteStages(server);precondition(error.contains("暂存路径已不存在"))}
   print("PASS: FTP directory \(CommandLine.arguments[1]) refuses partial publication, reports cleanup outcome and preserves final targets");return
  case "--rename-failure-fixture","--uncertain-fixture":
   let error=caught{try client.uploadDirectory(source,to:remote)};precondition(error.contains("发布结果未确认"));try noRemoteStages(server)
   if CommandLine.arguments[1]=="--uncertain-fixture" {try verify(final);_ = caught{try client.uploadDirectory(source,to:remote)};try verify(final)}
   else{precondition(!fm.fileExists(atPath:final.path))}
   print("PASS: FTP directory \(CommandLine.arguments[1]) handles publication refusal/lost success acknowledgement, cleans only staging and never deletes a possibly published target");return
  case "--foreign-fixture":
   let error=caught{try client.uploadDirectory(source,to:remote)};precondition(!fm.fileExists(atPath:final.path) && error.contains("暂存目录可能保留"));let stages=try fm.contentsOfDirectory(at:server,includingPropertiesForKeys:nil).filter{$0.lastPathComponent.hasPrefix(".macterm-directory-")};precondition(stages.count==1);let foreign=try String(contentsOf:stages[0].appendingPathComponent("foreign"),encoding:.utf8);precondition(foreign=="do not remove")
   print("PASS: FTP directory verification rejects foreign server entries; cleanup never traverses or deletes unowned names");return
  case "--cancel-fixture":
   let slow=local.appendingPathComponent("slow-source");try fm.createDirectory(at:slow,withIntermediateDirectories:false);try Data(repeating:65,count:2*1024*1024).write(to:slow.appendingPathComponent("slow.bin"));var done=false,failure:Error?
   DispatchQueue.global().async{var error:Error?;do{try client.uploadDirectory(slow,to:remote)}catch let caught{error=caught};let result=error;DispatchQueue.main.async{failure=result;done=true}}
   spin{let stages=(try? fm.contentsOfDirectory(at:server,includingPropertiesForKeys:nil)) ?? [];return done || stages.contains{$0.lastPathComponent.hasPrefix(".macterm-directory-") && ((try? $0.appendingPathComponent("slow.bin").resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0)>0}};precondition(!done);client.cancel();spin{done};precondition(failure != nil && !fm.fileExists(atPath:final.path));try noRemoteStages(server)
   print("PASS: real throttled FTP directory STOR cancellation stops transport, removes owned remote staging and never publishes the final target");return
  default:break
  }
  var messages=[String]();try client.uploadDirectory(source,to:remote,progress:{messages.append($0)});try verify(final);try noRemoteStages(server);precondition(messages.contains{$0.contains("核对远端")} && messages.last=="已完成 · 3 个文件")
  _ = caught{try client.uploadDirectory(source,to:remote)};try verify(final)
  _ = caught{try client.uploadDirectory(source,to:remote.uppercased())};try verify(final)
  let protected=server.appendingPathComponent("protected-file-"+UUID().uuidString);try Data("keep original".utf8).write(to:protected);_ = caught{try client.uploadDirectory(source,to:"/"+protected.lastPathComponent)};let kept=try String(contentsOf:protected,encoding:.utf8);precondition(kept=="keep original")
  let alias=source.appendingPathComponent("link");try fm.createSymbolicLink(at:alias,withDestinationURL:nested);_ = caught{try client.uploadDirectory(source,to:"/must-not-publish")};try fm.removeItem(at:alias);precondition(!fm.fileExists(atPath:server.appendingPathComponent("must-not-publish").path));try noRemoteStages(server)
  let empty=local.appendingPathComponent("empty");try fm.createDirectory(at:empty,withIntermediateDirectories:false);try client.uploadDirectory(empty,to:"/empty-"+name);let empties=try fm.contentsOfDirectory(atPath:server.appendingPathComponent("empty-"+name).path);precondition(empties.isEmpty)
  let mutated=local.appendingPathComponent("mutated");try fm.createDirectory(at:mutated,withIntermediateDirectories:false);let changing=mutated.appendingPathComponent("file");try Data("before".utf8).write(to:changing);let changedClient=try FTPClient(session:fixture.session,password:fixture.password,caFile:ca)
  _ = caught{try changedClient.uploadDirectory(mutated,to:"/changed-"+name,progress:{if $0.hasPrefix("已上传 1/1") {try! Data("after".utf8).write(to:changing)}})};precondition(!fm.fileExists(atPath:server.appendingPathComponent("changed-"+name).path));try noRemoteStages(server)
  let cancelled=try FTPClient(session:fixture.session,password:fixture.password,caFile:ca)
  _ = caught{try cancelled.uploadDirectory(source,to:"/cancelled-"+name,progress:{if $0.hasPrefix("已上传 1/"){cancelled.cancel()}})};precondition(!fm.fileExists(atPath:server.appendingPathComponent("cancelled-"+name).path));try noRemoteStages(server)
  // A target that appears while data is being sent is caught by the second check.
  let race="/race-"+name,raceTarget=server.appendingPathComponent("race-"+name);let raceClient=try FTPClient(session:fixture.session,password:fixture.password,caFile:ca);var created=false
  _ = caught{try raceClient.uploadDirectory(source,to:race,progress:{if !created && $0.hasPrefix("已上传 1/") {created=true;try! fm.createDirectory(at:raceTarget,withIntermediateDirectories:false);try! Data("concurrent".utf8).write(to:raceTarget.appendingPathComponent("keep"))}})};let retained=try String(contentsOf:raceTarget.appendingPathComponent("keep"),encoding:.utf8);precondition(retained=="concurrent");try noRemoteStages(server)
  let workspace=FTPWorkspace(session:fixture.session,password:fixture.password,caFile:ca,autoConnect:false);defer{workspace.stop()};let queueJobs=try FTPBatch.uploads([source],directory:"/"),failed=TransferJob(local:source,remote:remote,uploading:true,isDirectory:true),file=local.appendingPathComponent("tail-"+name);try Data("tail".utf8).write(to:file);let tail=try FTPBatch.uploads([file],directory:"/")[0]
  workspace.enqueueFTPJobs([queueJobs[0],failed,tail]);spin{!workspace.busy && workspace.transferQueue.active==nil};precondition(queueJobs[0].state == .succeeded && failed.state.retryable && tail.state == .succeeded);try verify(server.appendingPathComponent("source"))
  let queueFinal=server.appendingPathComponent("source/.hidden");try Data("remote edits".utf8).write(to:queueFinal);workspace.transferQueue.retry();spin{!workspace.busy && workspace.transferQueue.active==nil};let edits=try String(contentsOf:queueFinal,encoding:.utf8);precondition(edits=="remote edits")
  // Keep a later security-mode fixture independent of the queue's fixed name.
  try fm.removeItem(at:server.appendingPathComponent("source"));try noRemoteStages(server)
  print("PASS: real \(fixture.session.ftp!.security.rawValue) FTP directory uploads, binary/Unicode/hidden/empty trees, remote verification, existing/case/concurrent targets, source edits, cancellation cleanup and mixed queue retry isolation")
 }
}
