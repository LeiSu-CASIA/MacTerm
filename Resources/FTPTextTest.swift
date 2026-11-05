import Cocoa
@main struct FTPTextTests {
 struct Fixture:Decodable {let session:Session,password:String,root:String;let caFile:String?}
 static let fm=FileManager.default
 static func spin(_ predicate:()->Bool){let end=Date().addingTimeInterval(20);while !predicate() && Date()<end{RunLoop.current.run(until:Date().addingTimeInterval(0.005))};precondition(predicate(),"FTP text callback timed out")}
 static func reject(_ work:()throws->Void)->String {do{try work();fatalError("Unsafe FTP text operation accepted")}catch{return error.localizedDescription}}
 static func main()throws {
  _ = NSApplication.shared
  if CommandLine.arguments.count==3{try fixture(CommandLine.arguments[1],url:URL(fileURLWithPath:CommandLine.arguments[2]));return}
  let model=try RemoteText(data:Data("original\r\n中文".utf8));var saves=0
  let editor=RemoteEditor(path:"/config.txt",text:model,location:"FTP 测试 · /config.txt",save:{data,expected,done in saves+=1;precondition(expected==model.original && String(data:data,encoding:.utf8)=="changed");done(.success(()))});defer{editor.close()}
  editor.textView.string="changed";editor.confirmSave={false};editor.saveDocument();precondition(saves==0 && editor.dirty && !editor.saving && editor.status.stringValue.contains("取消"))
  editor.confirmSave={editor.saveDocument();return true};editor.saveDocument();precondition(saves==1 && !editor.dirty && !editor.saving && !editor.confirmingSave)
  editor.close();editor.textView.string="must not save after close";editor.saveDocument();precondition(saves==1 && editor.editorClosed)
  let root=URL(fileURLWithPath:"/private/tmp").appendingPathComponent("mt-ftp-text-model-"+UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false);defer{try? FileManager.default.removeItem(at:root)}
  let session=Session(name:"FTP text",host:"127.0.0.1",user:"demo",port:21,key:"",kind:.ftp,ftp:FTPSettings(security:.plain)),workspace=FTPWorkspace(session:session,password:"",autoConnect:false,bookmarkStore:DirectoryBookmarkStore(url:root.appendingPathComponent("bookmarks.json")));defer{workspace.stop()}
  workspace.confirmFTPTextSave={path in precondition(path=="/test.txt");return false};let ftpEditor=workspace.presentFTPText(model,path:"/test.txt",generation:workspace.connectionGeneration,showWindow:false);ftpEditor.textView.string="changed";ftpEditor.saveDocument();precondition(ftpEditor.dirty && !ftpEditor.saving && !workspace.busy && workspace.editors.count==1)
  let generation=workspace.connectionGeneration;ftpEditor.confirmingSave=true;workspace.reconnectFTP(FTPCredentialChoice(password:""));precondition(workspace.connectionGeneration==generation && workspace.editors.count==1 && !workspace.busy);ftpEditor.confirmingSave=false
  let invalid=RemoteFile(name:"folder",size:0,directory:true,mode:0o040000);workspace.openFTPText(invalid,showWindow:false);precondition(!workspace.busy && workspace.editors.count==1)
  ftpEditor.window?.close();precondition(workspace.editors.isEmpty)
  print("PASS: explicit text-save approval/cancel/reentrancy guards, exact baseline update, closed-editor refusal, FTP editor ownership, reconnect confirmation guard and non-file refusal")
 }
 static func fixture(_ mode:String,url:URL)throws {
  let fixture=try JSONDecoder().decode(Fixture.self,from:Data(contentsOf:url)),ca=fixture.caFile.map{URL(fileURLWithPath:$0)},parent="/text-editor-"+UUID().uuidString,server=URL(fileURLWithPath:fixture.root).appendingPathComponent("files"+parent)
  try fm.createDirectory(at:server,withIntermediateDirectories:false);defer{try? fm.removeItem(at:server)}
  let client=try FTPClient(session:fixture.session,password:fixture.password,maximumTime:30,caFile:ca),path=parent+"/edit.txt",file=server.appendingPathComponent("edit.txt"),original=Data("old value 中文\r\n".utf8),updated=Data("new value 😀\r\n".utf8)
  if mode != "--fixture" {
   if mode=="--oversize-fixture" {let huge=Data(repeating:65,count:RemoteText.maximumBytes+1);try huge.write(to:file);let error=reject{_ = try client.readText(path)};precondition(error.contains("限制") || error.contains("FTP 失败"));let kept=try Data(contentsOf:file);precondition(kept==huge);print("PASS: FTP text bounded RETR rejects a server lying about MLSD/SIZE without changing remote content");return}
   try original.write(to:file)
   if mode=="--cancel-fixture" {
    let large=Data(repeating:97,count:1024*1024);var done=false,failure:Error?
    DispatchQueue.global().async {var caught:Error?;do{try client.saveText(large,to:path,expected:original)}catch{caught=error};let result=caught;DispatchQueue.main.async{failure=result;done=true}}
    spin{((try? fm.contentsOfDirectory(at:server,includingPropertiesForKeys:[.fileSizeKey]).contains{$0.lastPathComponent.hasPrefix(".macterm-editor-") && ((try? $0.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0)>0}) ?? false) || done};precondition(!done);client.cancel();spin{done};let kept=try Data(contentsOf:file);precondition(failure != nil && kept==original);print("PASS: throttled FTP text STOR cancellation preserves original and reports possible remote temporary content");return
   }
   let error=reject{try client.saveText(updated,to:path,expected:original)},kept=try Data(contentsOf:file),temporaries=try fm.contentsOfDirectory(at:server,includingPropertiesForKeys:nil).filter{$0.lastPathComponent.hasPrefix(".macterm-editor-")}
   switch mode {
   case "--conflict-fixture":precondition(kept==Data("external writer".utf8) && error.contains("未请求替换") && temporaries.count==1)
   case "--tamper-fixture":precondition(kept==original && error.contains("暂存内容") && temporaries.count==1)
   case "--rename-failure-fixture":precondition(kept==original && error.contains("发布结果未获确认") && temporaries.count==1)
   case "--uncertain-fixture":precondition(kept==updated && error.contains("发布结果未获确认") && temporaries.isEmpty);let retried=reject{try client.saveText(updated,to:path,expected:original)};precondition(retried.contains("其他程序修改"));let after=try Data(contentsOf:file);precondition(after==updated)
   default:fatalError("Unknown FTP text fixture")
   }
   print("PASS: FTP text \(mode) preserves target/conflicting writer, checks staged bytes and reports uncertain publication without deleting remote data");return
  }
  let store=DirectoryBookmarkStore(url:URL(fileURLWithPath:fixture.root).appendingPathComponent("text-bookmarks.json")),workspace=FTPWorkspace(session:fixture.session,password:fixture.password,caFile:ca,autoConnect:false,bookmarkStore:store);defer{workspace.stop()}
  let variants:[(String,String.Encoding,Data)]=[("utf8",.utf8,Data()),("utf8bom",.utf8,Data([0xef,0xbb,0xbf])),("utf16le",.utf16LittleEndian,Data([0xff,0xfe])),("utf16be",.utf16BigEndian,Data([0xfe,0xff]))]
  for (tag,encoding,bom) in variants {
   let name="文本 ' \" "+tag+".txt",local=server.appendingPathComponent(name),remote=try FTPPath.child(name,in:parent),value="old_red 中文\r\nold_blue 😀\r\n",bytes=bom+value.data(using:encoding)!
   try bytes.write(to:local);try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:local.path)
   let loaded=try client.readText(remote);precondition(loaded.original==bytes && loaded.text==value)
   workspace.load(parent);spin{!workspace.busy};let entry=workspace.allEntries.first{$0.name==name}!;workspace.path.stringValue="/typed-not-opened";workspace.openFTPText(entry,showWindow:false);spin{!workspace.busy && workspace.editors.count==1};let editor=workspace.editors[0];precondition(editor.path==remote && !editor.dirty)
   workspace.load("/");spin{!workspace.busy};editor.showReplace();editor.findBar.query.stringValue="old_(red|blue)";editor.findBar.regex.state = .on;editor.scheduleSearch(select:true,delay:0);spin{!editor.searchBusy};precondition(editor.searchSnapshot?.matches.count==2);editor.findBar.replacement.stringValue="new_$1";editor.replaceAllMatches();precondition(editor.dirty);let untouched=try Data(contentsOf:local);precondition(untouched==bytes)
   var approvals=0;workspace.confirmFTPTextSave={target in approvals+=1;precondition(target==remote);return false};editor.saveDocument();precondition(approvals==1 && editor.dirty && !editor.saving && !workspace.busy);let cancelled=try Data(contentsOf:local);precondition(cancelled==bytes)
   workspace.confirmFTPTextSave={target in approvals+=1;precondition(target==remote);return true};let first=editor.textView.string;editor.saveDocument();precondition(editor.saving);editor.textView.string=first+"later edit\r\n";editor.textDidChange(Notification(name:NSText.didChangeNotification,object:editor.textView));spin{!editor.saving};let saved=try Data(contentsOf:local);precondition(approvals==2 && saved==bom+first.data(using:encoding)! && editor.dirty && editor.savedText==first)
   editor.saveDocument();spin{!editor.saving};let final=try Data(contentsOf:local);precondition(final==bom+editor.textView.string.data(using:encoding)! && !editor.dirty && workspace.remotePath=="/")
   editor.textView.string="";editor.textDidChange(Notification(name:NSText.didChangeNotification,object:editor.textView));editor.saveDocument();spin{!editor.saving};let empty=try Data(contentsOf:local),emptyModel=try client.readText(remote);precondition(empty==bom && emptyModel.text.isEmpty && !editor.dirty)
   editor.confirmingSave=true;let generation=workspace.connectionGeneration;workspace.reconnectFTP(FTPCredentialChoice(password:fixture.password));precondition(workspace.connectionGeneration==generation && !workspace.busy);editor.confirmingSave=false
   editor.window?.close();precondition(workspace.editors.isEmpty);let count=approvals;editor.textView.string="closed draft";editor.saveDocument();precondition(approvals==count)
   let newText=try client.readText(remote);try Data("external writer".utf8).write(to:local);let before=try fm.contentsOfDirectory(atPath:server.path);let error=reject{try client.saveText(newText.original,to:remote,expected:bytes)};let after=try fm.contentsOfDirectory(atPath:server.path),kept=try Data(contentsOf:local);precondition(error.contains("其他程序修改") && Set(before.map{Data($0.utf8)})==Set(after.map{Data($0.utf8)}) && kept==Data("external writer".utf8))
  }
  workspace.load(parent);spin{!workspace.busy};let regular=workspace.allEntries.first{$0.mode&0o170000==0o100000}!;workspace.openFTPText(regular,showWindow:false);workspace.cancelFTP();spin{!workspace.busy};precondition(workspace.editors.isEmpty)
  let binary=server.appendingPathComponent("binary.bin");try Data([0,1,255,0]).write(to:binary);_ = reject{_ = try client.readText(parent+"/binary.bin")};let boundary=server.appendingPathComponent("boundary.txt"),maximal=Data(repeating:97,count:RemoteText.maximumBytes);try maximal.write(to:boundary);let limit=try client.readText(parent+"/boundary.txt");precondition(limit.original==maximal);try (maximal+Data([97])).write(to:boundary);_ = reject{_ = try client.readText(parent+"/boundary.txt")}
  let tempNames=try fm.contentsOfDirectory(atPath:server.path);precondition(!tempNames.contains{$0.hasPrefix(".macterm-editor-")})
  print("PASS: real \(fixture.session.ftp!.security.rawValue) FTP editor four encoding/BOM variants, CRLF/Unicode regex replacement, explicit save consent/cancel, fixed source across navigation, newer draft preservation, repeated save baseline, conflict/binary/4MiB guards and cancelled-open isolation")
 }

}
