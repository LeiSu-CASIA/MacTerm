import Cocoa
import Darwin
@main struct FTPDirectoryTests {
 struct Fixture:Decodable {let session:Session,password:String,root:String;let caFile:String?}
 static let manager=FileManager.default
 static func rejects(_ work:()throws->Void){do{try work();fatalError("Unsafe/incomplete directory transfer accepted")}catch{}}
 static func spin(_ predicate:()->Bool){let deadline=Date().addingTimeInterval(25);while !predicate() && Date()<deadline {RunLoop.current.run(until:Date().addingTimeInterval(0.005))};precondition(predicate(),"FTP directory operation timed out")}
 static func clean(_ root:URL)throws {let names=try manager.contentsOfDirectory(atPath:root.path);precondition(names.allSatisfy{!$0.hasPrefix(".macterm-ftp-directory-")},"Staging tree leaked")}
 static func verify(_ target:URL)throws {
  let data=try Data(contentsOf:target.appendingPathComponent("nested/二进制 ' \" $;[].bin"));precondition(data==Data((0..<200000).map{UInt8($0%251)}))
  let hidden=try String(contentsOf:target.appendingPathComponent(".hidden"),encoding:.utf8);precondition(hidden=="hidden contents")
  let empty=try Data(contentsOf:target.appendingPathComponent("nested/zero"));precondition(empty.isEmpty)
  let emptyDirectory=try manager.contentsOfDirectory(atPath:target.appendingPathComponent("empty").path);precondition(emptyDirectory.isEmpty)
  let files=try manager.subpathsOfDirectory(atPath:target.path);precondition(Set(files)==Set(["nested","nested/二进制 ' \" $;[].bin","nested/zero","empty",".hidden"]))
  for path in [target,target.appendingPathComponent("nested"),target.appendingPathComponent("empty")] {let attrs=try manager.attributesOfItem(atPath:path.path);precondition((attrs[.posixPermissions] as? NSNumber)?.intValue==0o700)}
  let attrs=try manager.attributesOfItem(atPath:target.appendingPathComponent(".hidden").path);precondition((attrs[.posixPermissions] as? NSNumber)?.intValue==0o600)
 }
 static func main()throws {
  _ = NSApplication.shared
  let local=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("mt-ftp-directory-test-"+UUID().uuidString);try manager.createDirectory(at:local,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);defer{try? manager.removeItem(at:local)}
  if CommandLine.arguments.count==3,CommandLine.arguments[1].hasSuffix("fixture") {
   let fixture=try JSONDecoder().decode(Fixture.self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[2]))),ca=fixture.caFile.map{URL(fileURLWithPath:$0)}
   let client=try FTPClient(session:fixture.session,password:fixture.password,maximumTime:20,caFile:ca),target=local.appendingPathComponent("downloaded")
   switch CommandLine.arguments[1] {
   case "--cancel-fixture","--race-fixture":
    var done=false,failure:Error?
    DispatchQueue.global().async{var error:Error?;do{try client.downloadDirectory("/slow-tree",to:target)}catch let caught{error=caught};let result=error;DispatchQueue.main.async{failure=result;done=true}}
    spin{let dirs=(try? manager.contentsOfDirectory(at:local,includingPropertiesForKeys:nil)) ?? [];return dirs.contains{((try? $0.appendingPathComponent("tree/slow.bin").resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0)>0} || done};precondition(!done)
    if CommandLine.arguments[1]=="--cancel-fixture" {client.cancel()}
    else{try manager.createDirectory(at:target,withIntermediateDirectories:false);try Data("concurrent target".utf8).write(to:target.appendingPathComponent("keep"))}
    spin{done};precondition(failure != nil)
    if CommandLine.arguments[1]=="--cancel-fixture" {precondition(!manager.fileExists(atPath:target.path))}
    else{let kept=try Data(contentsOf:target.appendingPathComponent("keep"));precondition(kept==Data("concurrent target".utf8));let paths=try manager.contentsOfDirectory(atPath:target.path);precondition(paths==["keep"])}
    try clean(local);print("PASS: FTP directory \(CommandLine.arguments[1]) during real data transfer, no partial publication, exclusive target protection and staging cleanup");return
   case "--failure-fixture":
    rejects{try client.downloadDirectory("/failure-tree",to:target)};precondition(!manager.fileExists(atPath:target.path));try clean(local)
    let fallback=local.appendingPathComponent("after-error.bin");try client.download("/payload.bin",to:fallback);let data=try Data(contentsOf:fallback);precondition(data.count==200000)
    print("PASS: FTP directory child RETR failure removes the staged tree, publishes nothing and leaves the connection client usable");return
   case "--collision-fixture":
    let probe=local.appendingPathComponent("Case"),other=local.appendingPathComponent("case");try Data().write(to:probe);let fd=Darwin.open(other.path,O_CREAT|O_EXCL|O_WRONLY,0o600),caseSensitive=fd>=0;if fd>=0{Darwin.close(fd)}
    if caseSensitive {try client.downloadDirectory("/case-clash",to:target);let paths=try manager.contentsOfDirectory(atPath:target.path);precondition(Set(paths)==Set(["Case","case"]))}
    else{rejects{try client.downloadDirectory("/case-clash",to:target)};precondition(!manager.fileExists(atPath:target.path))}
    try clean(local);print("PASS: FTP server names differing only in case use the actual local filesystem rules; collision refuses publication and cleans staging");return
   default:break
   }
   var messages=[String]();try client.downloadDirectory("/download-tree",to:target,progress:{messages.append($0)});try verify(target);try clean(local)
   precondition(messages.contains{$0.contains("扫描")} && messages.contains{$0.contains("3/3")} && messages.last=="已完成 · 3 个文件")
   rejects{try client.downloadDirectory("/download-tree",to:target)};try verify(target)
   let broken=local.appendingPathComponent("broken-link");try manager.createSymbolicLink(at:broken,withDestinationURL:local.appendingPathComponent("missing"));rejects{try client.downloadDirectory("/download-tree",to:broken)};let linked=try manager.destinationOfSymbolicLink(atPath:broken.path);precondition(linked==local.appendingPathComponent("missing").path)
   let cancelled=try FTPClient(session:fixture.session,password:fixture.password,caFile:ca);cancelled.cancel();let absent=local.appendingPathComponent("pre-cancelled");rejects{try cancelled.downloadDirectory("/download-tree",to:absent)};precondition(!manager.fileExists(atPath:absent.path))
   let finalCancel=try FTPClient(session:fixture.session,password:fixture.password,caFile:ca),finalTarget=local.appendingPathComponent("cancel-before-publish");rejects{try finalCancel.downloadDirectory("/download-tree",to:finalTarget,progress:{if $0.contains("3/3"){finalCancel.cancel()}})};precondition(!manager.fileExists(atPath:finalTarget.path));try clean(local)
   let empty=local.appendingPathComponent("empty");try client.downloadDirectory("/download-tree/empty",to:empty);let emptyContents=try manager.contentsOfDirectory(atPath:empty.path);precondition(emptyContents.isEmpty)
   let workspace=FTPWorkspace(session:fixture.session,password:fixture.password,caFile:ca,autoConnect:false);defer{workspace.stop()}
   let entry=RemoteFile(name:"download-tree",size:0,directory:true,mode:0o040000),job=try FTPBatch.downloads([entry],directory:"/",to:local.appendingPathComponent("queued"))[0]
   try manager.createDirectory(at:local.appendingPathComponent("queued"),withIntermediateDirectories:false)
   let failed=TransferJob(local:local.appendingPathComponent("missing"),remote:"/missing-directory",uploading:false,isDirectory:true),tail=TransferJob(local:local.appendingPathComponent("tail.bin"),remote:"/payload.bin",uploading:false)
   workspace.enqueueFTPJobs([job,failed,tail]);spin{workspace.transferQueue.active==nil && !workspace.busy};precondition(job.state == .succeeded && failed.state.retryable && tail.state == .succeeded && job.progress.contains("已完成"));try verify(job.local)
   // A retry skips the successful directory even after its contents were edited.
   try Data("local edits".utf8).write(to:job.local.appendingPathComponent(".hidden"));workspace.transferQueue.retry();spin{workspace.transferQueue.active==nil && !workspace.busy};let kept=try String(contentsOf:job.local.appendingPathComponent(".hidden"),encoding:.utf8);precondition(kept=="local edits" && job.state == .succeeded)
   workspace.updateFTPTransferProgress("late callback",for:job);precondition(job.progress != "late callback");try clean(local)
   print("PASS: real \(fixture.session.ftp!.security.rawValue) FTP directory binary/Unicode/hidden/empty downloads, private modes, progress, existing/broken-link/cancel protection, queue continuation and retry isolation");return
  }
  let file=RemoteFile(name:"file",size:1,directory:false,mode:0o100000),folder=RemoteFile(name:"nested",size:0,directory:true,mode:0o040000)
  let plan=try FTPDirectoryPlan.scan("/root",check:{},list:{$0=="/root" ? [folder,file] : [RemoteFile(name:"中文",size:0,directory:false,mode:0o100000)]});precondition(plan.nodes.count==3 && plan.fileCount==2 && plan.nodes[1].remote=="/root/nested/中文" && plan.nodes[1].relative=="nested/中文")
  for entry in [RemoteFile(name:"../escape",size:0,directory:false,mode:0o100000),RemoteFile(name:"link",size:0,directory:false,mode:0o120000),RemoteFile(name:"unknown",size:0,directory:false),RemoteFile(name:"mismatch",size:0,directory:true,mode:0o100000)] {rejects{_ = try FTPDirectoryPlan.scan("/",check:{},list:{_ in [entry]})}}
  rejects{_ = try FTPDirectoryPlan.scan("/",check:{},list:{_ in [file,file]})}
  rejects{_ = try FTPDirectoryPlan.scan("/",maximumItems:1,check:{},list:{$0=="/" ? [folder] : [file]})}
  var calls=0;rejects{_ = try FTPDirectoryPlan.scan("/",maximumDepth:3,check:{},list:{_ in calls+=1;return [folder]})};precondition(calls==3,"Alias cycle did not stop at the depth bound")
  calls=0;rejects{_ = try FTPDirectoryPlan.scan("/",maximumItems:2,check:{},list:{path in calls+=1;return path=="/" ? [folder,file] : [folder]})};precondition(calls==2,"Pending siblings must count toward the discovery budget")
  rejects{_ = try FTPDirectoryPlan.scan("/",maximumPathBytes:2,check:{},list:{_ in [file]})}
  var checked=0;rejects{_ = try FTPDirectoryPlan.scan("/",check:{checked+=1;if checked==2{throw SFTPError.message("cancel")}},list:{_ in [file]})};precondition(checked==2)
  let distinct=try FTPListing.decode(Data("type=file; é\r\ntype=file; e\u{301}\r\n".utf8));let exact=try FTPDirectoryPlan.scan("/",check:{},list:{_ in distinct});precondition(exact.nodes.count==2)
  for line in ["type=OS.unix=slink:/target; link\r\n","type=file;unix.slink=/target; link\r\n"] {let link=try FTPListing.decode(Data(line.utf8));precondition(link[0].symbolicLink && !FTPBatch.canDownload(link[0]));rejects{_ = try FTPDirectoryPlan.scan("/",check:{},list:{_ in link})}}
  print("PASS: FTP directory preflight, exact UTF-8 names, safe path/type/duplicate checks, explicit links, bounded alias cycles/item/path budgets and cancellation")
 }
}
