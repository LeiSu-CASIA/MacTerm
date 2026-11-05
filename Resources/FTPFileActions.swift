import Cocoa

extension FTPWorkspace:NSMenuItemValidation {
 var canManageFTPFiles:Bool {!busy && !stopped && transferQueue.active==nil && !hasPendingFTPUpload}
 func fileMenu()->NSMenu {
  let menu=NSMenu()
  for (title,action) in [("属性…",#selector(showFTPProperties)),("编辑文本…",#selector(editFTPText)),("新建目录…",#selector(newFTPDirectory)),("重命名…",#selector(renameFTPEntry)),("删除文件 / 空目录…",#selector(deleteFTPEntry)),("复制远程路径",#selector(copyFTPPath))] {
   let item=menu.addItem(withTitle:title,action:action,keyEquivalent:"");item.target=self
  }
  return menu
 }
 func validateMenuItem(_ item:NSMenuItem)->Bool {
  switch item.action {
  case #selector(showFTPProperties):return canManageFTPFiles && table.selectedRowIndexes.count==1 && selected() != nil
  case #selector(editFTPText):return canManageFTPFiles && table.selectedRowIndexes.count==1 && selected().map{!$0.directory && $0.mode&0o170000==0o100000}==true
  case #selector(newFTPDirectory):return canManageFTPFiles
  case #selector(renameFTPEntry),#selector(deleteFTPEntry):return canManageFTPFiles && table.selectedRowIndexes.count==1 && selected().map{[UInt32(0o100000),UInt32(0o040000)].contains($0.mode&0o170000)}==true
  case #selector(copyFTPPath):return !stopped && table.selectedRowIndexes.count==1 && selected() != nil
  default:return true
  }
 }
 @objc func showFTPFileMenu(_ sender:NSButton){fileMenu().popUp(positioning:nil,at:NSPoint(x:0,y:sender.bounds.height),in:sender)}
 func requestFTPName(_ title:String,initial:String="",warning:String="")->String? {
  let alert=NSAlert();alert.messageText=title;alert.informativeText=warning;alert.window.appearance=NSAppearance(named:.darkAqua);alert.addButton(withTitle:"确定");alert.addButton(withTitle:"取消")
  let field=NSTextField(frame:NSRect(x:0,y:0,width:340,height:28));AppTheme.field(field);field.stringValue=initial;field.setAccessibilityLabel("远程名称");alert.accessoryView=field;alert.window.initialFirstResponder=field
  while alert.runModal() == .alertFirstButtonReturn {
   do{return try RemoteFileName.validated(field.stringValue)}catch{alert.informativeText=error.localizedDescription+"\n"+warning}
  }
  return nil
 }
 func mutateFTP(_ title:String,selecting name:String?=nil,work:@escaping(FTPClient)throws->Void){
  guard canManageFTPFiles else{return}
  let directory=remotePath
  var listing:[RemoteFile]?,refreshError:Error?
  perform(title,work:{client in
   try work(client)
   do{listing=try client.list(directory)}catch{refreshError=error}
  },completion:{[weak self] error in
   guard let self=self,error==nil else{return}
   if let listing=listing,Data(self.remotePath.utf8)==Data(directory.utf8){self.applyMutationListing(listing,selecting:name)}
   let visible=name.map{value in self.entries.contains{Data($0.name.utf8)==Data(value.utf8)}} ?? true
   self.status.stringValue=refreshError.map{"远程更改已完成，但刷新失败："+$0.localizedDescription} ?? title+"已完成"+(name.map{"："+$0} ?? "")+(visible ? "" : "（当前筛选未显示）")
   self.status.toolTip=self.status.stringValue
  })
 }
 @objc func newFTPDirectory(){guard canManageFTPFiles,let name=requestFTPName("新建 FTP 目录") else{return};createDirectory(name:name)}
 func createDirectory(name:String){
  guard canManageFTPFiles else{return}
  do{let destination=try FTPPath.child(name,in:remotePath);mutateFTP("创建目录",selecting:name){try $0.mkdir(destination)}}catch{status.stringValue=error.localizedDescription;status.toolTip=status.stringValue}
 }
 @objc func renameFTPEntry(){
  guard canManageFTPFiles,table.selectedRowIndexes.count==1,let entry=selected(),let name=requestFTPName("重命名 "+entry.name,initial:entry.name,warning:"FTP 服务器可能替换目标同名文件，请核对新名称。") else{return}
  renameEntry(entry,to:name)
 }
 func renameEntry(_ entry:RemoteFile,to name:String){
  guard canManageFTPFiles,[UInt32(0o100000),UInt32(0o040000)].contains(entry.mode&0o170000) else{return}
  do{let source=try FTPPath.child(entry.name,in:remotePath),destination=try FTPPath.child(name,in:remotePath);guard Data(source.utf8) != Data(destination.utf8) else{status.stringValue="名称未改变";return};mutateFTP("重命名",selecting:name){try $0.rename(source,to:destination)}}catch{status.stringValue=error.localizedDescription;status.toolTip=status.stringValue}
 }
 @objc func deleteFTPEntry(){
  guard canManageFTPFiles,table.selectedRowIndexes.count==1,let entry=selected(),[UInt32(0o100000),UInt32(0o040000)].contains(entry.mode&0o170000) else{return}
  let alert=NSAlert();alert.messageText="永久删除 "+entry.name+"？";alert.informativeText="目标："+((try? FTPPath.child(entry.name,in:remotePath)) ?? entry.name)+"\n删除不能撤回。仅支持单个文件或空目录，不递归删除。";alert.window.appearance=NSAppearance(named:.darkAqua);alert.addButton(withTitle:"删除");alert.addButton(withTitle:"取消")
  guard alert.runModal() == .alertFirstButtonReturn else{return};deleteEntry(entry)
 }
 func deleteEntry(_ entry:RemoteFile){
  guard canManageFTPFiles,[UInt32(0o100000),UInt32(0o040000)].contains(entry.mode&0o170000) else{return}
  do{let source=try FTPPath.child(entry.name,in:remotePath);mutateFTP("删除"){try $0.remove(source,directory:entry.directory)}}catch{status.stringValue=error.localizedDescription;status.toolTip=status.stringValue}
 }
 @objc func copyFTPPath(){guard !stopped,table.selectedRowIndexes.count==1,let entry=selected(),let value=try? FTPPath.child(entry.name,in:remotePath) else{return};NSPasteboard.general.clearContents();NSPasteboard.general.setString(value,forType:.string)}
}
