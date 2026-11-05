import Cocoa

enum FTPDropFiles {
 /// Read only the pasteboard belonging to this drag. Reject partial/mixed drops
 /// rather than silently uploading the subset that happens to be a file URL.
 static func decode(_ pasteboard:NSPasteboard)throws->[URL] {
  guard let items=pasteboard.pasteboardItems,!items.isEmpty,items.count<=200 else{throw SFTPError.message("一次拖入 1–200 个文件或文件夹")}
  var bytes=0
  return try items.map{item in
   guard let raw=item.string(forType:.fileURL),raw.utf8.count<=65536 else{throw SFTPError.message("仅接受 Finder 中的本机文件和文件夹，不接受文本或文件承诺")}
   let size=raw.utf8.count;guard size<=1024*1024-bytes else{throw SFTPError.message("拖入地址总量超过限制")};bytes+=size
   guard let parts=URLComponents(string:raw),let decodedPath=parts.percentEncodedPath.removingPercentEncoding,decodedPath.hasPrefix("/"),!decodedPath.contains("\0"),let url=URL(string:raw),url.isFileURL,url.path.hasPrefix("/"),!url.path.contains("\0"),url.query==nil,url.fragment==nil,url.user==nil,url.password==nil,url.port==nil,(url.host ?? "").isEmpty || url.host?.lowercased()=="localhost" else{throw SFTPError.message("拖入内容含非本机文件地址或无效路径")}
   return url
  }
 }
}
struct FTPUploadProposal {
 let id=UUID();let directory:String;let operation:UUID;let jobs:[TransferJob]
 func makeAlert()->NSAlert {
  let alert=NSAlert();alert.window.appearance=NSAppearance(named:.darkAqua);alert.messageText="上传 \(jobs.count) 个项目？"
  let names=jobs.map{($0.isDirectory ? "文件夹：" : "文件：")+$0.local.lastPathComponent}.joined(separator:"\n")
  let files=jobs.contains{!$0.isDirectory},folders=jobs.contains{$0.isDirectory}
  alert.informativeText=(files ? "普通文件可能替换同名文件。" : "")+(folders ? "目录不合并，已知同名目标会拒绝；FTP 发布瞬间并发出现的目标仍可能被服务器替换。" : "")+"取消或失败会尽力清理本次临时目录，断连时可能保留。"
  let scroll=NSScrollView(frame:NSRect(x:0,y:0,width:420,height:140));scroll.hasVerticalScroller=true;scroll.autohidesScrollers=true;scroll.scrollerStyle = .overlay;scroll.borderType = .noBorder;scroll.drawsBackground=true;scroll.backgroundColor=AppTheme.input;AppTheme.surface(scroll,AppTheme.input,radius:8)
  let preview=NSTextView(frame:scroll.bounds);preview.isEditable=false;preview.isSelectable=true;preview.isRichText=false;preview.importsGraphics=false;preview.font = .monospacedSystemFont(ofSize:12,weight:.regular);preview.textColor=AppTheme.text;preview.backgroundColor=AppTheme.input;preview.textContainerInset=NSSize(width:10,height:10);preview.isVerticallyResizable=true;preview.isHorizontallyResizable=false;preview.autoresizingMask=[.width];preview.textContainer?.widthTracksTextView=true;preview.textContainer?.containerSize=NSSize(width:400,height:CGFloat.greatestFiniteMagnitude);preview.string="目标目录：\(directory)\n\n"+names;preview.setAccessibilityLabel("上传目标与项目列表");scroll.documentView=preview;alert.accessoryView=scroll
  alert.addButton(withTitle:files ? "上传（文件允许覆盖）" : "上传目录");alert.addButton(withTitle:"取消");return alert
 }
}
extension FTPWorkspace {
 func tableView(_ tableView:NSTableView,validateDrop info:NSDraggingInfo,proposedRow row:Int,proposedDropOperation operation:NSTableView.DropOperation)->NSDragOperation {
  guard tableView === table,canManageFTPFiles,info.draggingSourceOperationMask.contains(.copy),!(info.draggingSource as AnyObject? === table),let _=try? FTPDropFiles.decode(info.draggingPasteboard) else{return []}
  // A row under the pointer is not a destination directory: the path bar wins.
  tableView.setDropRow(-1,dropOperation:.on);return .copy
 }
 func tableView(_ tableView:NSTableView,acceptDrop info:NSDraggingInfo,row:Int,dropOperation:NSTableView.DropOperation)->Bool {
  guard tableView === table,canManageFTPFiles,info.draggingSourceOperationMask.contains(.copy),!(info.draggingSource as AnyObject? === table) else{return false}
  do {let urls=try FTPDropFiles.decode(info.draggingPasteboard);guard let proposal=prepareFTPUpload(urls) else{return false}
   // Let AppKit finish the drag before presenting a modal confirmation.
   DispatchQueue.main.async{[weak self] in _ = self?.reviewFTPUpload(proposal)};return true
  }catch{status.stringValue=error.localizedDescription;status.toolTip=status.stringValue;return false}
 }
}
