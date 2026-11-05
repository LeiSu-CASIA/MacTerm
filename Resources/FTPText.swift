import Cocoa

extension FTPWorkspace {
 static let textSaveNotice="FTP 将用暂存文件替换目标。保存前会再次比对内容，但检查与发布之间的并发更改仍可能被覆盖；原权限、所有者、ACL 和时间不保证保留。失败时请刷新核对，远端可能留有 .macterm-editor-* 临时文件。"
 @objc func editFTPText(){guard table.selectedRowIndexes.count==1,let entry=selected() else{return};openFTPText(entry)}
 func openFTPText(_ entry:RemoteFile,showWindow:Bool=true){
  guard canManageFTPFiles,entry.mode&0o170000==0o100000,!entry.directory else{return}
  let source:String;do{source=try FTPPath.child(entry.name,in:remotePath)}catch{status.stringValue=error.localizedDescription;return};let generation=connectionGeneration;var text:RemoteText?
  perform("读取 FTP 文本…",work:{text=try $0.readText(source)},completion:{[weak self] error in guard let self=self,!self.stopped,self.connectionGeneration==generation,error==nil,let text=text else{return};self.presentFTPText(text,path:source,generation:generation,showWindow:showWindow)})
 }
 @discardableResult func presentFTPText(_ text:RemoteText,path source:String,generation:UUID,showWindow:Bool=true)->RemoteEditor {
  let editor=RemoteEditor(path:source,text:text,location:session.connectionSummary+" · "+source,save:{[weak self] data,expected,done in
   guard let self=self,!self.stopped,self.connectionGeneration==generation else{done(.failure(SFTPError.message("原 FTP 登录已关闭或更换；草稿仍在编辑器，请重新打开远程文件后合并。")));return}
   guard self.canManageFTPFiles else{done(.failure(SFTPError.message("FTP 文件操作正在进行，请稍后保存。")));return}
   self.perform("保存 FTP 文本…",work:{try $0.saveText(data,to:source,expected:expected)},completion:{error in if let error=error{done(.failure(error))}else{done(.success(()))}})
  });editor.confirmSave = {[weak self] in guard let self=self,!self.stopped,self.connectionGeneration==generation,self.canManageFTPFiles else{return true};if let confirm=self.confirmFTPTextSave{return confirm(source)};let alert=NSAlert();alert.window.appearance=NSAppearance(named:.darkAqua);alert.messageText="替换保存 FTP 文件？";alert.informativeText=self.session.connectionSummary+"\n"+source+"\n\n"+Self.textSaveNotice;alert.addButton(withTitle:"替换保存");alert.addButton(withTitle:"取消");return alert.runModal() == .alertFirstButtonReturn}
  editors.append(editor);editor.onClose = {[weak self,weak editor] in self?.editors.removeAll{$0 === editor}};if showWindow{editor.showWindow(nil);editor.window?.makeKeyAndOrderFront(nil)};return editor
 }
 func confirmEditorClose()->Bool {editors.allSatisfy{$0.confirmDiscard()}}
 func closeTextEditors(){for editor in editors{editor.window?.close()};editors=[]}
}
