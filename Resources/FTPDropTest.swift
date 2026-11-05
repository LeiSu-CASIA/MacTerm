import Cocoa
final class FTPTestDrag:NSObject,NSDraggingInfo {
 let draggingPasteboard:NSPasteboard
 var draggingDestinationWindow:NSWindow? {nil};var draggingSourceOperationMask:NSDragOperation = .copy
 var draggingLocation:NSPoint {.zero};var draggedImageLocation:NSPoint {.zero};var draggedImage:NSImage? {nil};var draggingSource:Any?;var draggingSequenceNumber:Int {1}
 var draggingFormation:NSDraggingFormation = .none;var animatesToDestination=false;var numberOfValidItemsForDrop=0;var springLoadingHighlight:NSSpringLoadingHighlight {.none}
 init(_ pasteboard:NSPasteboard){draggingPasteboard=pasteboard}
 func slideDraggedImage(to screenPoint:NSPoint){}
 override func namesOfPromisedFilesDropped(atDestination dropDestination:URL)->[String]? {nil}
 func enumerateDraggingItems(options:NSDraggingItemEnumerationOptions,for view:NSView?,classes classArray:[AnyClass],searchOptions:[NSPasteboard.ReadingOptionKey:Any],using block:(NSDraggingItem,Int,UnsafeMutablePointer<ObjCBool>)->Void){}
 func resetSpringLoading(){}
}
@main struct FTPDropTests {
 struct Fixture:Decodable {let session:Session,password:String,root:String;let caFile:String?}
 static let fm=FileManager.default
 static func spin(_ predicate:()->Bool){let deadline=Date().addingTimeInterval(25);while !predicate() && Date()<deadline{RunLoop.current.run(until:Date().addingTimeInterval(0.005))};precondition(predicate(),"FTP drop callback timed out")}
 static func rejects(_ work:()throws->Void){do{try work();fatalError("Invalid drop accepted")}catch{}}
 static func write(_ raw:[String],to board:NSPasteboard){board.clearContents();let items=raw.map{value->NSPasteboardItem in let item=NSPasteboardItem();item.setString(value,forType:.fileURL);return item};precondition(board.writeObjects(items))}
 static func main()throws {
  _ = NSApplication.shared
  let root=fm.temporaryDirectory.appendingPathComponent("mt-ftp-drop-"+UUID().uuidString);try fm.createDirectory(at:root,withIntermediateDirectories:false);defer{try? fm.removeItem(at:root)}
  let file=root.appendingPathComponent("拖入 ' file.txt"),folder=root.appendingPathComponent("folder-"+UUID().uuidString),hidden=folder.appendingPathComponent(".hidden");try Data("drop bytes".utf8).write(to:file);try fm.createDirectory(at:folder.appendingPathComponent("empty"),withIntermediateDirectories:true);try Data("nested bytes".utf8).write(to:hidden)
  let board=NSPasteboard(name:NSPasteboard.Name("macterm-drop-test-"+UUID().uuidString));defer{board.releaseGlobally()};write([file.absoluteString,folder.absoluteString],to:board);let drag=FTPTestDrag(board)
  if CommandLine.arguments.count==3,CommandLine.arguments[1]=="--fixture" {
   let fixture=try JSONDecoder().decode(Fixture.self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[2]))),ca=fixture.caFile.map{URL(fileURLWithPath:$0)},workspace=FTPWorkspace(session:fixture.session,password:fixture.password,caFile:ca,autoConnect:false);defer{workspace.stop()};workspace.load("/中文 目录");spin{!workspace.busy};precondition(workspace.remotePath=="/中文 目录")
   let server=URL(fileURLWithPath:fixture.root).appendingPathComponent("files/中文 目录");var approvals=0
   workspace.path.stringValue="/typed-but-not-opened";workspace.confirmUpload={proposal in approvals+=1;precondition(proposal.directory=="/中文 目录" && proposal.jobs.count==2 && proposal.jobs[1].isDirectory);return true}
   precondition(workspace.tableView(workspace.table,validateDrop:drag,proposedRow:0,proposedDropOperation:.on) == .copy)
   precondition(workspace.tableView(workspace.table,acceptDrop:drag,row:0,dropOperation:.on));precondition(approvals==0 && workspace.hasPendingFTPUpload && workspace.transferQueue.jobs.isEmpty)
   // The original drag data is retained; a later pasteboard change is irrelevant.
   board.clearContents();board.setString("changed after drop",forType:.string)
   spin{approvals==1 && !workspace.hasPendingFTPUpload && !workspace.busy && workspace.transferQueue.active==nil}
   precondition(workspace.transferQueue.jobs.count==2 && workspace.transferQueue.jobs.allSatisfy{$0.state == .succeeded});let actual=try Data(contentsOf:server.appendingPathComponent(file.lastPathComponent)),nested=try Data(contentsOf:server.appendingPathComponent(folder.lastPathComponent+"/.hidden"));precondition(actual==Data("drop bytes".utf8) && nested==Data("nested bytes".utf8));let empty=try fm.contentsOfDirectory(atPath:server.appendingPathComponent(folder.lastPathComponent+"/empty").path);precondition(empty.isEmpty)
   try fm.removeItem(at:server.appendingPathComponent(file.lastPathComponent));try fm.removeItem(at:server.appendingPathComponent(folder.lastPathComponent))
   print("PASS: real \(fixture.session.ftp!.security.rawValue) Finder-style drag delegate -> deferred explicit approval -> fixed visible directory -> queued file and directory upload; post-drop pasteboard changes cannot retarget it");return
  }
  let session=Session(name:"drop",host:"127.0.0.1",user:"demo",port:21,key:"",kind:.ftp,ftp:FTPSettings(security:.plain,initialPath:"/")),workspace=FTPWorkspace(session:session,password:"",autoConnect:false);defer{workspace.stop()}
  let decoded=try FTPDropFiles.decode(board);precondition(decoded==[file,folder] && workspace.table.registeredDraggedTypes.contains(.fileURL))
  precondition(workspace.tableView(workspace.table,validateDrop:drag,proposedRow:3,proposedDropOperation:.above) == .copy)
  drag.draggingSourceOperationMask = .move;precondition(workspace.tableView(workspace.table,validateDrop:drag,proposedRow:0,proposedDropOperation:.on).isEmpty);precondition(!workspace.tableView(workspace.table,acceptDrop:drag,row:0,dropOperation:.on));drag.draggingSourceOperationMask = .copy;drag.draggingSource=workspace.table;precondition(workspace.tableView(workspace.table,validateDrop:drag,proposedRow:0,proposedDropOperation:.on).isEmpty);drag.draggingSource=nil
  precondition(!workspace.tableView(RemoteFileTable(),acceptDrop:drag,row:0,dropOperation:.on))
  for raw in ["https://example.com/file","file://remote-host/share/file","file:///tmp/file?query=x","file:///tmp/file#fragment","file:///tmp/a%00b/file","file:relative"] {write([file.absoluteString,raw],to:board);rejects{_ = try FTPDropFiles.decode(board)}}
  board.clearContents();board.setString("/tmp/a",forType:.string);rejects{_ = try FTPDropFiles.decode(board)}
  write(Array(repeating:file.absoluteString,count:201),to:board);rejects{_ = try FTPDropFiles.decode(board)}
  write(Array(repeating:"file:///tmp/"+String(repeating:"a",count:50000),count:22),to:board);rejects{_ = try FTPDropFiles.decode(board)}
  write([file.absoluteString,folder.absoluteString],to:board)
  let gate=DispatchSemaphore(value:0);workspace.perform("busy gate",work:{_ in _ = gate.wait(timeout:.now()+5)});precondition(workspace.tableView(workspace.table,validateDrop:drag,proposedRow:0,proposedDropOperation:.on).isEmpty);precondition(!workspace.tableView(workspace.table,acceptDrop:drag,row:0,dropOperation:.on));gate.signal();spin{!workspace.busy}
  let literal=root.appendingPathComponent("literal%00.txt");try Data().write(to:literal);write([literal.absoluteString],to:board);let percent=try FTPDropFiles.decode(board);precondition(percent==[literal]);write([file.absoluteString,folder.absoluteString],to:board)
  let proposal=workspace.prepareFTPUpload(decoded)!;precondition(workspace.hasPendingFTPUpload && !workspace.canManageFTPFiles && !workspace.uploadButton.isEnabled && workspace.prepareFTPUpload(decoded)==nil)
  let alert=proposal.makeAlert();let preview=(alert.accessoryView as! NSScrollView).documentView as! NSTextView;precondition(preview.string.contains(file.lastPathComponent) && preview.string.contains(folder.lastPathComponent) && preview.string.contains("目标目录：/") && !preview.isEditable && preview.isSelectable && alert.accessoryView!.frame.height<=160 && alert.buttons.count==2 && alert.window.appearance?.name == .darkAqua)
  let long=FTPUploadProposal(directory:"/"+String(repeating:"目录/",count:1000),operation:UUID(),jobs:Array(repeating:proposal.jobs[0],count:200)).makeAlert();long.layout();precondition(long.window.frame.height<700 && ((long.accessoryView as! NSScrollView).documentView as! NSTextView).string.contains(String(repeating:"目录/",count:1000)))
  precondition(!workspace.reviewFTPUpload(proposal,confirm:{_ in false},showQueue:false));precondition(workspace.transferQueue.jobs.isEmpty && workspace.canManageFTPFiles)
  let stale=workspace.prepareFTPUpload([file])!;workspace.perform("generation test",work:{_ in});spin{!workspace.busy};var prompted=false;precondition(!workspace.reviewFTPUpload(stale,confirm:{_ in prompted=true;return true},showQueue:false));precondition(!prompted && workspace.transferQueue.jobs.isEmpty)
  let changed=workspace.prepareFTPUpload([file])!;precondition(!workspace.reviewFTPUpload(changed,confirm:{_ in workspace.perform("generation changed",work:{_ in});return true},showQueue:false));spin{!workspace.busy};precondition(workspace.transferQueue.jobs.isEmpty)
  let capacity=workspace.prepareFTPUpload([file])!,filler=TransferJob(local:file,remote:"/unrelated",uploading:true);workspace.transferQueue.jobs=Array(repeating:filler,count:1000);precondition(!workspace.reviewFTPUpload(capacity,confirm:{_ in true},showQueue:false));workspace.transferQueue.jobs=[]
  var executed=[TransferJob]();workspace.transferQueue.execute={job,done in executed.append(job);done(nil)};let approved=workspace.prepareFTPUpload(decoded)!;workspace.path.stringValue="/uncommitted text";precondition(workspace.reviewFTPUpload(approved,confirm:{_ in true},showQueue:false));precondition(executed.count==2 && executed[0].remote=="/"+file.lastPathComponent && executed[1].isDirectory && executed.allSatisfy{$0.state == .succeeded});workspace.transferQueue.jobs=[]
  var count=0;workspace.confirmUpload={value in count+=1;precondition(value.jobs[0].local==file);return false};precondition(workspace.tableView(workspace.table,acceptDrop:drag,row:0,dropOperation:.on));precondition(count==0 && workspace.hasPendingFTPUpload);board.clearContents();board.setString("changed",forType:.string);spin{!workspace.hasPendingFTPUpload};precondition(count==1 && workspace.transferQueue.jobs.isEmpty)
  let alias=root.appendingPathComponent("link");try fm.createSymbolicLink(at:alias,withDestinationURL:folder);write([alias.absoluteString],to:board);precondition(!workspace.tableView(workspace.table,acceptDrop:drag,row:0,dropOperation:.on));precondition(!workspace.hasPendingFTPUpload)
  write([file.absoluteString],to:board);workspace.confirmUpload={_ in fatalError("Closed workspace must not ask for upload approval")};precondition(workspace.tableView(workspace.table,acceptDrop:drag,row:0,dropOperation:.on));workspace.stop();RunLoop.current.run(until:Date().addingTimeInterval(0.02));precondition(!workspace.hasPendingFTPUpload && workspace.transferQueue.closed && workspace.transferQueue.jobs.isEmpty)
  print("PASS: isolated drag pasteboard URL validation/bounds, copy-only/self/cross-table rejection, native registration, deferred review, fixed paths/item types, explicit cancellation, operation-generation/capacity rechecks, symlink refusal and close-before-prompt isolation")
 }
}
