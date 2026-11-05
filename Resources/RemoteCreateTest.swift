import Cocoa
@main struct RemoteCreateTests {
 static func spin(_ predicate:()->Bool){let until=Date().addingTimeInterval(10);while !predicate() && Date()<until {RunLoop.current.run(until:Date().addingTimeInterval(0.01))};precondition(predicate(),"Remote creation timed out")}
 static func rejected(_ work:()throws->Void){do{try work();fatalError("Operation should have been rejected")}catch{}}
 static func main()throws {
  _ = NSApplication.shared
  if CommandLine.arguments.count==3,CommandLine.arguments[1]=="--ssh-fixture" {
   let fixture=URL(fileURLWithPath:CommandLine.arguments[2]),folder=URL(fileURLWithPath:CommandLine.arguments[2]).deletingLastPathComponent()
   let session=try JSONDecoder().decode(Session.self,from:Data(contentsOf:fixture)),owner=AppDelegate(storage:folder.appendingPathComponent("unused-create-sessions.json"))
   let args=["-F","/dev/null","-o","IdentitiesOnly=yes","-o","StrictHostKeyChecking=yes","-o","UserKnownHostsFile="+folder.appendingPathComponent("known_hosts").path,"-o","BatchMode=yes"]+owner.arguments(session,sftp:false)
   let workspace=SSHWorkspace(session:session,args:args,socket:folder.appendingPathComponent("create-mux").path);workspace.timer?.invalidate();defer{workspace.stop()};spin{FileManager.default.fileExists(atPath:workspace.socket)}
   let base=folder.appendingPathComponent("create-fixture");try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true)
   workspace.load(base.path);spin{!workspace.busy && workspace.remotePath==base.path}
   let history=workspace.directoryHistory.paths
   let name=" 中文 ' \" $;notes.txt",file=base.appendingPathComponent(" 中文 ' \" $;notes.txt")
   workspace.createRemoteFile(name:name,openAfterCreation:true);spin{!workspace.busy && workspace.editors.count==1}
   precondition(workspace.chosen()?.name==name && workspace.directoryHistory.paths==history && workspace.status.stringValue.contains("已创建"))
   let editor=workspace.editors[0];precondition(editor.path==file.path && editor.expected.isEmpty && editor.textView.string.isEmpty)
   editor.textView.string="首行\ncreated and edited over SSH\n";editor.saveDocument();spin{!editor.saving && !workspace.busy};let saved=try Data(contentsOf:file);precondition(saved==Data(editor.textView.string.utf8));editor.window?.close();precondition(workspace.editors.isEmpty)
   workspace.createRemoteFile(name:name,openAfterCreation:true);spin{!workspace.busy};precondition(workspace.editors.isEmpty);let retained=try Data(contentsOf:file);precondition(retained==saved)
   workspace.fileFilter.stringValue="does-not-match";workspace.renderFiles();workspace.createRemoteFile(name:".hidden-new",openAfterCreation:false);spin{!workspace.busy};precondition(workspace.editors.isEmpty && workspace.fileFilter.stringValue=="does-not-match" && workspace.allEntries.contains{$0.name==".hidden-new"});let hidden=try Data(contentsOf:base.appendingPathComponent(".hidden-new"));precondition(hidden.isEmpty)
   workspace.createRemoteFile(name:"conflict.txt",openAfterCreation:true);spin{!workspace.busy && workspace.editors.count==1};let conflict=workspace.editors[0];try Data("external writer".utf8).write(to:base.appendingPathComponent("conflict.txt"));var saveResult:Result<Void,Error>?
   conflict.saveAction(Data("my draft".utf8),conflict.expected){saveResult=$0};spin{saveResult != nil && !workspace.busy};if case .success?=saveResult {fatalError("Concurrent changes must not be overwritten")};let external=try String(contentsOf:base.appendingPathComponent("conflict.txt"));precondition(external=="external writer");conflict.window?.close()
   workspace.createRemoteFile(name:"cancelled.txt",openAfterCreation:true);workspace.cancelCurrentOperation();spin{!workspace.busy};precondition(workspace.editors.isEmpty)
   workspace.createRemoteFile(name:"terminal-stopped.txt",openAfterCreation:true);workspace.terminal.stop();spin{!workspace.busy};precondition(workspace.editors.isEmpty)
   workspace.createRemoteFile(name:"after-terminal-stop.txt",openAfterCreation:true);precondition(!workspace.busy && !FileManager.default.fileExists(atPath:base.appendingPathComponent("after-terminal-stop.txt").path))
   let closing=SSHWorkspace(session:session,args:args,socket:folder.appendingPathComponent("create-closed-mux").path);closing.timer?.invalidate();closing.remotePath=base.path;spin{FileManager.default.fileExists(atPath:closing.socket)}
   closing.createRemoteFile(name:"closed.txt",openAfterCreation:true);closing.stop();let until=Date().addingTimeInterval(0.2);while Date()<until {RunLoop.current.run(until:Date().addingTimeInterval(0.01))};precondition(closing.editors.isEmpty)
   print("PASS: real SSH create/edit/save, exact filename selection, existing content protection, hidden/filter preservation, concurrent edit conflict, cancellation and closed-workspace editor isolation");return
  }
  for bad in ["",".","..","/absolute","parent/name","a\0b","a\nb","a\tb","a\u{7f}",String(repeating:"中",count:342)] {rejected{_ = try RemoteFileName.validated(bad)}}
  for good in ["notes.txt",".env","  spaces  ","中文 ' \" $;file","e\u{301}",String(repeating:"x",count:1024)] {let checked=try RemoteFileName.validated(good);precondition(checked==good)}
  let form=RemoteFileCreationForm();precondition(form.openEditor.state == .on && form.bounds.contains(form.name.frame) && form.bounds.contains(form.openEditor.frame) && !form.name.frame.intersects(form.openEditor.frame))
  let root=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("mt-create-"+UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
  let client=try SFTPClient(command:"/usr/libexec/sftp-server",arguments:[]);defer{client.close()}
  let name=" 中文 ' \" $;file",file=root.appendingPathComponent(" 中文 ' \" $;file")
  try client.createFile(file.path);let attributes=try client.fileAttributes(file.path);precondition(attributes.kind=="普通文件" && attributes.size==0 && attributes.mode&0o777==0o600)
  try Data("preserve me".utf8).write(to:file);rejected{try client.createFile(file.path)};let data=try Data(contentsOf:file);precondition(data==Data("preserve me".utf8))
  let directory=root.appendingPathComponent("directory");try client.mkdir(directory.path);rejected{try client.createFile(directory.path)}
  let linked=root.appendingPathComponent("link"),broken=root.appendingPathComponent("broken"),absent=root.appendingPathComponent("absent")
  try FileManager.default.createSymbolicLink(atPath:linked.path,withDestinationPath:name);try FileManager.default.createSymbolicLink(atPath:broken.path,withDestinationPath:"absent")
  for path in [linked.path,broken.path] {rejected{try client.createFile(path)}};precondition(!FileManager.default.fileExists(atPath:absent.path));let linkedData=try Data(contentsOf:file);precondition(linkedData==Data("preserve me".utf8))
  for path in ["",String(repeating:"x",count:65537),"abc\0def"] {rejected{try client.createFile(path)}}
  let refused=try SFTPClient(command:"/usr/libexec/sftp-server",arguments:["-P","open"]);defer{refused.close()};let denied=root.appendingPathComponent("denied");rejected{try refused.createFile(denied.path)};precondition(!FileManager.default.fileExists(atPath:denied.path))
  let closeRefused=try SFTPClient(command:"/usr/libexec/sftp-server",arguments:["-P","close"]);defer{closeRefused.close()};let uncertain=root.appendingPathComponent("close-failed");do{try closeRefused.createFile(uncertain.path);fatalError("Close failure must be reported")}catch{precondition(error.localizedDescription.contains("可能已创建"))};precondition(FileManager.default.fileExists(atPath:uncertain.path))
  let concurrent=root.appendingPathComponent("exclusive-race");let first=try SFTPClient(command:"/usr/libexec/sftp-server",arguments:[]),second=try SFTPClient(command:"/usr/libexec/sftp-server",arguments:[]);defer{first.close();second.close()}
  let group=DispatchGroup(),lock=NSLock();var successes=0,failures=0
  for connection in [first,second] {group.enter();DispatchQueue.global().async{defer{group.leave()};do{try connection.createFile(concurrent.path);lock.lock();successes+=1;lock.unlock()}catch{lock.lock();failures+=1;lock.unlock()}}};precondition(group.wait(timeout:.now()+8) == .success);precondition(successes==1 && failures==1)
  let workspace=SSHWorkspace(session:Session(name:"fixture",host:"fixture.invalid",user:"",port:22,key:""),args:["-V"],socket:NSTemporaryDirectory()+UUID().uuidString);workspace.timer?.invalidate();defer{workspace.stop()}
  let menu=workspace.fileMenu();let newItem=menu.items.first{$0.action == #selector(SSHWorkspace.newFile)}!;precondition(newItem.title=="新建文件…");workspace.busy=true;precondition(!workspace.validateMenuItem(newItem));workspace.createRemoteFile(name:"unavailable",openAfterCreation:true);precondition(workspace.editors.isEmpty);workspace.busy=false;workspace.stop();precondition(!workspace.validateMenuItem(newItem))
  print("PASS: exclusive remote empty-file creation, 0600 permissions, UTF-8 names, existing file/directory/symlink preservation, parallel creator isolation, OPEN/CLOSE rejection and creation form/menu states")
 }
}
