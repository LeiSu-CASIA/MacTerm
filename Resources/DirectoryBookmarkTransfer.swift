import Cocoa
import UniformTypeIdentifiers

protocol DirectoryBookmarkTransferHost:AnyObject {
 var bookmarkStore:DirectoryBookmarkStore{get};var bookmarkScope:String{get};var session:Session{get};var stopped:Bool{get};var window:NSWindow?{get}
 func bookmarkTransferStatus(_ message:String)
}
enum DirectoryBookmarkTransfer {
 static func addMenu(to menu:NSMenu,target:AnyObject,enabled:Bool,hasBookmarks:Bool,importAction:Selector,exportAction:Selector) {
  menu.addItem(.separator())
  let incoming=menu.addItem(withTitle:"导入目录书签…",action:importAction,keyEquivalent:"");incoming.target=target;incoming.isEnabled=enabled
  let outgoing=menu.addItem(withTitle:"导出此连接的目录书签…",action:exportAction,keyEquivalent:"");outgoing.target=target;outgoing.isEnabled=enabled && hasBookmarks
 }
 static func importBookmarks(_ host:DirectoryBookmarkTransferHost) {
  guard !host.stopped,let window=host.window else{return}
  let picker=NSOpenPanel();picker.canChooseDirectories=false;picker.allowsMultipleSelection=false;picker.allowedContentTypes=[.json];picker.message="选择 MacTerm 目录书签文件。确认后合并到当前连接，不自动打开目录。"
  picker.beginSheetModal(for:window){[weak host] response in
   guard let host=host,!host.stopped,response == .OK,let url=picker.url else{return}
   do {
    let values=try DirectoryBookmarkStore.readPortable(from:url)
    let alert=makeImportPreview(values,connection:host.session.connectionSummary)
    DispatchQueue.main.async{[weak host] in
     guard let host=host,!host.stopped,alert.runModal() == .alertFirstButtonReturn,!host.stopped else{return}
     do{let result=try host.bookmarkStore.importPortable(values,scope:host.bookmarkScope,ftp:host.session.connectionKind == .ftp);host.bookmarkTransferStatus("已导入 \(result.added) 个，跳过已有目录 \(result.skipped) 个；未打开远程目录。")}
     catch{host.bookmarkTransferStatus("导入未完成："+error.localizedDescription)}
    }
   }catch{host.bookmarkTransferStatus("导入未完成："+error.localizedDescription)}
  }
 }
 static func makeImportPreview(_ bookmarks:[PortableDirectoryBookmark],connection:String)->NSAlert {
  let alert=NSAlert();alert.messageText="导入 \(bookmarks.count) 个目录书签？";alert.informativeText="目标连接："+connection+"\n已有相同路径会保留原名称，其他书签不受影响。";alert.window.appearance=NSAppearance(named:.darkAqua);alert.addButton(withTitle:"导入");alert.addButton(withTitle:"取消")
  let scroll=NSScrollView(frame:NSRect(x:0,y:0,width:420,height:180));scroll.hasVerticalScroller=true;scroll.borderType = .bezelBorder
  let text=NSTextView(frame:scroll.bounds);text.isEditable=false;text.isSelectable=true;text.font = .monospacedSystemFont(ofSize:12,weight:.regular);text.textColor=AppTheme.text;text.backgroundColor=AppTheme.background;text.string=bookmarks.map{$0.title+"\n"+$0.path}.joined(separator:"\n\n");text.autoresizingMask=[.width];text.textContainer?.widthTracksTextView=true;text.isVerticallyResizable=true;text.maxSize=NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude);scroll.documentView=text;alert.accessoryView=scroll;return alert
 }
 static func exportBookmarks(_ host:DirectoryBookmarkTransferHost) {
  guard !host.stopped,let window=host.window else{return}
  let picker=NSSavePanel();picker.nameFieldStringValue="MacTerm-directory-bookmarks.json";picker.allowedContentTypes=[.json];picker.message="仅导出此连接的目录名称和路径，不包含服务器地址或密码。路径可能包含项目名称，请确认后再分享。"
  picker.beginSheetModal(for:window){[weak host] response in guard let host=host,!host.stopped,response == .OK,let url=picker.url else{return};do{try host.bookmarkStore.exportPortable(scope:host.bookmarkScope,to:url);host.bookmarkTransferStatus("目录书签已导出。") }catch{host.bookmarkTransferStatus("导出未完成："+error.localizedDescription)}}
 }
}
extension SSHWorkspace:DirectoryBookmarkTransferHost {
 func bookmarkTransferStatus(_ message:String){status.stringValue=message;status.toolTip=message}
 @objc func importDirectoryBookmarks(){DirectoryBookmarkTransfer.importBookmarks(self)}
 @objc func exportDirectoryBookmarks(){DirectoryBookmarkTransfer.exportBookmarks(self)}
}
extension FTPWorkspace:DirectoryBookmarkTransferHost {
 func bookmarkTransferStatus(_ message:String){status.stringValue=message;status.toolTip=message}
 @objc func importDirectoryBookmarks(){DirectoryBookmarkTransfer.importBookmarks(self)}
 @objc func exportDirectoryBookmarks(){DirectoryBookmarkTransfer.exportBookmarks(self)}
}
