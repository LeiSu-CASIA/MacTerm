import Cocoa

struct FTPFileProperties {
 let connection:String,path:String,entry:RemoteFile
 var values:[(String,String)] {
  let kind:String
  switch entry.mode&0o170000 {case 0o100000:kind="文件";case 0o040000:kind="文件夹";case 0o120000:kind="符号链接（未跟随）";default:kind="服务器未提供"}
  let formatter=DateFormatter();formatter.dateStyle = .medium;formatter.timeStyle = .medium
  return [("连接",connection),("远程路径",path),("类型",kind),("大小",entry.directory ? "不统计子目录内容" : entry.sizeAvailable ? "\(entry.size) 字节" : "服务器未提供"),("修改时间",entry.modified.map{formatter.string(from:$0)} ?? "服务器未提供")]
 }
 func makeAlert()->NSAlert {
  let alert=NSAlert();alert.messageText=entry.name+" · 属性";alert.informativeText="当前服务器返回的只读属性。";alert.window.appearance=NSAppearance(named:.darkAqua);alert.addButton(withTitle:"关闭")
  let rows=values.map{title,value->[NSView] in
   let label=NSTextField(labelWithString:title);label.textColor=AppTheme.muted
   let field=NSTextField(wrappingLabelWithString:value);field.isSelectable=true;field.font = .systemFont(ofSize:12);field.maximumNumberOfLines=3;field.lineBreakMode = .byTruncatingMiddle;field.toolTip=value;field.setAccessibilityLabel(title);field.widthAnchor.constraint(equalToConstant:340).isActive=true
   return [label,field]
  }
  let grid=NSGridView(views:rows);grid.rowSpacing=12;grid.columnSpacing=14;grid.column(at:0).xPlacement = .trailing;grid.layoutSubtreeIfNeeded();grid.frame=NSRect(origin:.zero,size:grid.fittingSize);alert.accessoryView=grid;return alert
 }
}
extension FTPWorkspace {
 @objc func showFTPProperties(){guard canManageFTPFiles,table.selectedRowIndexes.count==1,let entry=selected() else{return};readFTPProperties(entry){properties in _ = properties.makeAlert().runModal()}}
 func readFTPProperties(_ entry:RemoteFile,completion:@escaping(FTPFileProperties)->Void) {
  guard canManageFTPFiles else{return}
  do {
   let directory=remotePath,source=try FTPPath.child(entry.name,in:remotePath),generation=connectionGeneration;var details:FTPFileProperties?
   perform("读取属性…",work:{client in
    let listing=try client.list(directory)
    guard let current=listing.first(where:{Data($0.name.utf8)==Data(entry.name.utf8)}) else{throw SFTPError.message("项目已不存在，请刷新目录。")}
    details=FTPFileProperties(connection:self.session.connectionSummary,path:source,entry:current)
   },completion:{[weak self] error in
    guard let self=self,!self.stopped,self.connectionGeneration==generation,error==nil,let details=details else{return}
    completion(details)
   })
  }catch{status.stringValue=error.localizedDescription;status.toolTip=status.stringValue}
 }
}
