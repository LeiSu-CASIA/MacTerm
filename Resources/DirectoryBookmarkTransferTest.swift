import Cocoa
import Darwin
@main struct DirectoryBookmarkTransferTests {
 static func reject(_ work:()throws->Void){do{try work();fatalError("Invalid bookmark transfer accepted")}catch{}}
 static func main()throws {
  _ = NSApplication.shared
  let root=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("mt-bookmark-transfer-"+UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
  let store=DirectoryBookmarkStore(url:root.appendingPathComponent("working.json")),other=DirectoryBookmarkStore(url:root.appendingPathComponent("other.json"))
  let session=Session(name:"private-session-name",host:"private-server-name",user:"private-user-name",port:22,key:"",id:UUID()),scope=DirectoryBookmarkStore.scope(session)
  let original=try store.add(title:"原目录",path:"/项目/é",scope:scope);_ = try store.add(title:"另一连接",path:"/not-exported",scope:"unrelated")
  let output=root.appendingPathComponent("portable.json");try store.exportPortable(scope:scope,to:output)
  let exported=try Data(contentsOf:output),text=String(decoding:exported,as:UTF8.self)
  for secret in [session.name,session.host,session.user,scope,original.id.uuidString,"not-exported"]{precondition(!text.contains(secret))}
  let incoming=try DirectoryBookmarkStore.readPortable(from:output);precondition(incoming.count==1 && incoming[0].title==original.title && Data(incoming[0].path.utf8)==Data(original.path.utf8))
  let merged=try other.importPortable(incoming,scope:"destination");precondition(merged.added==1 && merged.skipped==0)
  let imported=try other.bookmarks(for:"destination");precondition(imported.count==1 && imported[0].id != original.id)
  let repeated=try other.importPortable([PortableDirectoryBookmark(title:"不能改掉原名称",path:original.path)],scope:"destination");precondition(repeated.added==0 && repeated.skipped==1);let retained=try other.bookmarks(for:"destination");precondition(retained[0].same(as:imported[0]))
  let composed=try other.importPortable([PortableDirectoryBookmark(title:"分解字符",path:"/项目/e\u{301}")],scope:"destination");precondition(composed.added==1)
  let isolated=try other.importPortable(incoming,scope:"another-destination");precondition(isolated.added==1);let second=try other.bookmarks(for:"another-destination");precondition(second[0].id != imported[0].id)
  let attrs=try FileManager.default.attributesOfItem(atPath:output.path);precondition((attrs[.posixPermissions] as! NSNumber).intValue&0o777==0o600)
  let before=try Data(contentsOf:store.url)
  for target in [store.url,store.url.appendingPathExtension("backup"),store.url.appendingPathExtension("lock")] {reject{try store.exportPortable(scope:scope,to:target)}}
  let hard=root.appendingPathComponent("hardlink.json");precondition(link(store.url.path,hard.path)==0);reject{try store.exportPortable(scope:scope,to:hard)}
  let symlink=root.appendingPathComponent("symlink.json");try FileManager.default.createSymbolicLink(at:symlink,withDestinationURL:output);reject{_ = try DirectoryBookmarkStore.readPortable(from:symlink)};reject{try store.exportPortable(scope:scope,to:symlink)}
  let fifo=root.appendingPathComponent("pipe");precondition(mkfifo(fifo.path,0o600)==0);reject{_ = try DirectoryBookmarkStore.readPortable(from:fifo)};reject{try store.exportPortable(scope:scope,to:fifo)}
  reject{_ = try DirectoryBookmarkStore.readPortable(from:root)};reject{_ = try DirectoryBookmarkStore.readPortable(from:URL(string:"https://example.invalid/bookmarks.json")!)}
  let after=try Data(contentsOf:store.url);precondition(after==before)
  for malformed in [Data("{}".utf8),Data("{\"format\":\"MacTerm Portable Directory Bookmarks\",\"version\":2,\"bookmarks\":[]}".utf8),Data(repeating:32,count:DirectoryBookmarkStore.maximumBytes+1)]{reject{_ = try PortableDirectoryBookmarks.decode(malformed)}}
  for invalid in [[PortableDirectoryBookmark(title:"x",path:"relative")],[PortableDirectoryBookmark(title:"",path:"/a")],[PortableDirectoryBookmark(title:"a",path:"/a"),PortableDirectoryBookmark(title:"b",path:"/a")],(0..<201).map{PortableDirectoryBookmark(title:"x",path:"/\($0)")}]{reject{_ = try store.importPortable(invalid,scope:scope)}}
  reject{_ = try store.importPortable([PortableDirectoryBookmark(title:"控制字符",path:"/a\nb")],scope:scope,ftp:true)}
  let crowded=(0..<199).map{PortableDirectoryBookmark(title:"目录",path:"/capacity/\($0)")};_ = try other.importPortable(crowded,scope:"capacity");let fullBefore=try Data(contentsOf:other.url)
  reject{_ = try other.importPortable([PortableDirectoryBookmark(title:"a",path:"/extra/a"),PortableDirectoryBookmark(title:"b",path:"/extra/b")],scope:"capacity")};let fullAfter=try Data(contentsOf:other.url);precondition(fullBefore==fullAfter)
  let corrupt=Data("{broken".utf8);try corrupt.write(to:other.url);reject{_ = try other.importPortable(incoming,scope:"destination")};let kept=try Data(contentsOf:other.url);precondition(kept==corrupt)
  let preview=DirectoryBookmarkTransfer.makeImportPreview(incoming,connection:"test connection");precondition(preview.buttons.map{$0.title}==["导入","取消"] && preview.informativeText.contains("test connection"));let scroll=preview.accessoryView as! NSScrollView,view=scroll.documentView as! NSTextView;precondition(!view.isEditable && view.isSelectable && view.string.contains(original.path) && scroll.frame.height>=180);preview.window.orderOut(nil)
  reject{_ = try DirectoryBookmarkStore.readPortable(from:store.url)}
  let ssh=SSHWorkspace(session:session,args:["-V"],socket:root.appendingPathComponent("unused-socket").path,bookmarkStore:store);ssh.timer?.invalidate();defer{ssh.stop()}
  let sshMenu=ssh.bookmarkMenu();precondition(sshMenu.items.first{$0.action == #selector(SSHWorkspace.importDirectoryBookmarks)}?.isEnabled==true && sshMenu.items.first{$0.action == #selector(SSHWorkspace.exportDirectoryBookmarks)}?.isEnabled==true)
  ssh.importDirectoryBookmarks();ssh.exportDirectoryBookmarks();precondition(ssh.window==nil);ssh.stop();precondition(ssh.bookmarkMenu().items.first{$0.action == #selector(SSHWorkspace.importDirectoryBookmarks)}?.isEnabled==false)
  let ftpSession=Session(name:"FTP",host:"127.0.0.1",user:"demo",port:21,key:"",id:UUID(),kind:.ftp,ftp:FTPSettings(security:.plain,initialPath:"/")),ftp=FTPWorkspace(session:ftpSession,password:"",autoConnect:false,bookmarkStore:store);defer{ftp.stop()};let ftpMenu=ftp.bookmarkMenu();precondition(ftpMenu.items.first{$0.action == #selector(FTPWorkspace.importDirectoryBookmarks)}?.isEnabled==true && ftpMenu.items.first{$0.action == #selector(FTPWorkspace.exportDirectoryBookmarks)}?.isEnabled==false)
  ftp.importDirectoryBookmarks();ftp.exportDirectoryBookmarks();precondition(!ftp.busy && ftp.directoryHistory.paths.isEmpty)
  let ftpImport=try store.importPortable(incoming,scope:ftp.bookmarkScope,ftp:true);precondition(ftpImport.added==1);let sshRetained=try store.bookmarks(for:scope);precondition(sshRetained.count==1 && sshRetained[0].same(as:original));precondition(ftp.bookmarkMenu().items.first{$0.action == #selector(FTPWorkspace.exportDirectoryBookmarks)}?.isEnabled==true);ftp.stop();precondition(ftp.bookmarkMenu().items.first{$0.action == #selector(FTPWorkspace.exportDirectoryBookmarks)}?.isEnabled==false)
  print("PASS: portable bookmark roundtrip without endpoints/IDs, explicit target preview, byte-exact deduplication preserving names, fresh global IDs, atomic merge/capacity/corruption rollback, private exports, working-file/hardlink/symlink/FIFO protection and FTP path validation")
 }
}
