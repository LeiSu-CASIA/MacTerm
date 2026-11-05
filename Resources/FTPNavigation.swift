import Cocoa

struct FTPDirectoryView {
 var query:String;var selected:Set<Data>;var scrollY:CGFloat;var hidden:Bool;var sort:Int
}
extension FTPWorkspace {
 var canUseDirectoryBookmarks:Bool {canManageFTPFiles}
 var bookmarkScope:String {DirectoryBookmarkStore.scope(session)}
 func configureNavigation(){
  for (button,action,hint) in [(backDirectoryButton,#selector(backDirectory),"后退到上次成功打开的目录"),(forwardDirectoryButton,#selector(forwardDirectory),"前进"),(historyDirectoryButton,#selector(showDirectoryHistory(_:)),"当前标签的目录历史"),(bookmarkDirectoryButton,#selector(showDirectoryBookmarks(_:)),"此连接的目录书签")] {button.target=self;button.action=action;button.toolTip=hint;AppTheme.action(button);button.widthAnchor.constraint(equalToConstant:30).isActive=true}
 }
 func updateNavigationControls(){let enabled=canManageFTPFiles;backDirectoryButton.isEnabled=enabled && directoryHistory.canGoBack;forwardDirectoryButton.isEnabled=enabled && directoryHistory.canGoForward;historyDirectoryButton.isEnabled=enabled && !directoryHistory.paths.isEmpty;bookmarkDirectoryButton.isEnabled = !stopped}
 @discardableResult func commitFTPDirectory(_ destination:String,entries:[RemoteFile],ticket:RemoteDirectoryHistory.Ticket?=nil)->Bool {
  let view=FTPDirectoryView(query:filter.stringValue,selected:Set(selectedFTPFiles.map{Data($0.name.utf8)}),scrollY:table.enclosingScrollView?.contentView.bounds.origin.y ?? 0,hidden:showHidden.state == .on,sort:sort.indexOfSelectedItem),previous=directoryHistory.current
  if let ticket=ticket{guard directoryHistory.commit(ticket,canonical:destination) else{return false}}else{directoryHistory.visit(destination)}
  if let previous=previous{directoryViews[Data(previous.utf8)]=view};let retained=Set(directoryHistory.paths.map{Data($0.utf8)});directoryViews=directoryViews.filter{retained.contains($0.key)}
  let restored=directoryViews[Data(destination.utf8)] ?? FTPDirectoryView(query:"",selected:[],scrollY:0,hidden:view.hidden,sort:view.sort)
  remotePath=destination;path.stringValue=destination;path.toolTip=destination+"\n相对路径从已打开目录解析；历史保存 FTP 路径，不解析服务器链接的真实路径。";allEntries=entries;filter.stringValue=restored.query;showHidden.state=restored.hidden ? .on : .off;sort.selectItem(at:restored.sort);renderFiles(preserveSelection:false)
  table.selectRowIndexes(IndexSet(self.entries.indices.filter{restored.selected.contains(Data(self.entries[$0].name.utf8))}),byExtendingSelection:false)
  if let scroll=table.enclosingScrollView{table.layoutSubtreeIfNeeded();let maximum=max(0,scroll.contentView.documentRect.height-scroll.contentView.bounds.height);scroll.contentView.scroll(to:NSPoint(x:0,y:min(max(0,restored.scrollY),maximum)));scroll.reflectScrolledClipView(scroll.contentView)};updateNavigationControls();return true
 }
 func load(_ input:String,ticket:RemoteDirectoryHistory.Ticket?=nil){
  guard canManageFTPFiles else{path.stringValue=remotePath;return};if let ticket=ticket,!directoryHistory.accepts(ticket){path.stringValue=remotePath;return}
  let destination:String;do{destination=try FTPPath.normalize(input,relativeTo:remotePath)}catch{status.stringValue=error.localizedDescription;status.toolTip=status.stringValue;path.stringValue=remotePath;return}
  var listing=[RemoteFile]();perform("读取 FTP 目录…",work:{listing=try $0.list(destination)},completion:{[weak self] error in guard let self=self,!self.stopped else{return}
   if error==nil {if self.commitFTPDirectory(destination,entries:listing,ticket:ticket){self.status.stringValue="\(listing.count) 个项目 · "+(self.session.ftp?.security.title ?? "FTP")}else{self.status.stringValue="目录历史已变化，结果未应用";self.path.stringValue=self.remotePath}}
   else{self.path.stringValue=self.remotePath};self.status.toolTip=self.status.stringValue;self.updateControls()
  })
 }
 @objc func backDirectory(){if let ticket=directoryHistory.backward{load(ticket.path,ticket:ticket)}}
 @objc func forwardDirectory(){if let ticket=directoryHistory.forward{load(ticket.path,ticket:ticket)}}
 func directoryMenu()->NSMenu {let menu=NSMenu();menu.autoenablesItems=false
  for index in directoryHistory.paths.indices.reversed(){let item=menu.addItem(withTitle:RemoteDirectoryHistory.menuTitle(directoryHistory.paths[index]),action:#selector(jumpToDirectory(_:)),keyEquivalent:"");item.target=self;item.toolTip=directoryHistory.paths[index];item.state=index==directoryHistory.index ? .on : .off;item.representedObject=directoryHistory.ticket(at:index);item.isEnabled=canManageFTPFiles && index != directoryHistory.index}
  if directoryHistory.paths.isEmpty{let item=menu.addItem(withTitle:"尚无成功打开的路径",action:nil,keyEquivalent:"");item.isEnabled=false};menu.addItem(.separator());let clear=menu.addItem(withTitle:"清空历史（保留当前位置）",action:#selector(clearDirectoryHistory),keyEquivalent:"");clear.target=self;clear.isEnabled=canManageFTPFiles && directoryHistory.paths.count>1;return menu
 }
 @objc func showDirectoryHistory(_ sender:NSButton){directoryMenu().popUp(positioning:nil,at:NSPoint(x:0,y:sender.bounds.height),in:sender)}
 @objc func jumpToDirectory(_ sender:NSMenuItem){guard let ticket=sender.representedObject as? RemoteDirectoryHistory.Ticket else{return};load(ticket.path,ticket:ticket)}
 @objc func clearDirectoryHistory(){guard canManageFTPFiles else{return};directoryHistory.clear();directoryViews=directoryViews.filter{$0.key==Data(remotePath.utf8)};updateNavigationControls()}
}

extension FTPWorkspace {
 func bookmarkMenu()->NSMenu {
  let menu=NSMenu();menu.autoenablesItems=false
  do {
   let bookmarks=try bookmarkStore.bookmarks(for:bookmarkScope)
   let current=bookmarks.first{Data($0.path.utf8)==Data(remotePath.utf8)}
   let add=menu.addItem(withTitle:"将当前目录加入书签…",action:#selector(addDirectoryBookmark),keyEquivalent:"");add.target=self;add.isEnabled=canUseDirectoryBookmarks && directoryHistory.current != nil && current==nil
   menu.addItem(.separator())
   for bookmark in bookmarks.sorted(by:{$0.title.localizedStandardCompare($1.title) == .orderedAscending}) {
    let entry=menu.addItem(withTitle:bookmark.title,action:#selector(jumpToBookmark(_:)),keyEquivalent:"");entry.target=self;entry.representedObject=bookmark;entry.toolTip=bookmark.path;entry.state=bookmark.id==current?.id ? .on : .off;entry.isEnabled=canUseDirectoryBookmarks
   }
   if bookmarks.isEmpty {let empty=menu.addItem(withTitle:"尚无目录书签",action:nil,keyEquivalent:"");empty.isEnabled=false}
   else {menu.addItem(.separator());let manage=NSMenu();manage.autoenablesItems=false;let parent=menu.addItem(withTitle:"管理书签",action:nil,keyEquivalent:"");parent.submenu=manage
    for bookmark in bookmarks {let item=manage.addItem(withTitle:bookmark.title,action:nil,keyEquivalent:"");item.toolTip=bookmark.path;let actions=NSMenu();actions.autoenablesItems=false;item.submenu=actions
     for(title,selector) in [("重命名…",#selector(renameDirectoryBookmark(_:))),("移除书签",#selector(removeDirectoryBookmark(_:)))] {let action=actions.addItem(withTitle:title,action:selector,keyEquivalent:"");action.target=self;action.representedObject=bookmark;action.isEnabled = !stopped}
    }
   }
   DirectoryBookmarkTransfer.addMenu(to:menu,target:self,enabled:!stopped,hasBookmarks:!bookmarks.isEmpty,importAction:#selector(FTPWorkspace.importDirectoryBookmarks),exportAction:#selector(FTPWorkspace.exportDirectoryBookmarks))
  }catch{let failed=menu.addItem(withTitle:"书签读取失败，原文件已保留",action:nil,keyEquivalent:"");failed.isEnabled=false;failed.toolTip=error.localizedDescription;status.stringValue=error.localizedDescription;status.toolTip=error.localizedDescription}
  return menu
 }
 @objc func showDirectoryBookmarks(_ sender:NSButton){bookmarkMenu().popUp(positioning:nil,at:NSPoint(x:0,y:sender.bounds.height),in:sender)}
 func requestBookmarkTitle(_ heading:String,initial:String)->String? {
  let alert=NSAlert();alert.messageText=heading;alert.informativeText="书签只保存目录位置，打开时不会执行终端命令。";alert.window.appearance=NSAppearance(named:.darkAqua);alert.addButton(withTitle:"保存");alert.addButton(withTitle:"取消")
  let field=NSTextField(frame:NSRect(x:0,y:0,width:300,height:28));AppTheme.field(field);field.stringValue=initial;field.setAccessibilityLabel("目录书签名称");alert.accessoryView=field;alert.window.initialFirstResponder=field
  while alert.runModal() == .alertFirstButtonReturn {let title=field.stringValue.trimmingCharacters(in:.whitespacesAndNewlines);if !title.isEmpty,title.count<=80,!title.unicodeScalars.contains(where:{$0.value<32 || $0.value==127}){return title};alert.informativeText="名称需为 1–80 个字符，不能包含控制字符。"};return nil
 }
 @objc func addDirectoryBookmark(){
  guard canUseDirectoryBookmarks,let current=directoryHistory.current else{return}
  let name=(current as NSString).lastPathComponent;let initial=String((name.isEmpty ? "/" : name).unicodeScalars.map{$0.value<32 || $0.value==127 ? "_" : String($0)}.joined().prefix(80))
  guard let title=requestBookmarkTitle("添加目录书签",initial:initial),!stopped else{return}
  do{_ = try bookmarkStore.add(title:title,path:current,scope:bookmarkScope);status.stringValue="已添加目录书签："+title}catch{status.stringValue=error.localizedDescription};status.toolTip=status.stringValue
 }
 @objc func jumpToBookmark(_ sender:NSMenuItem){
  guard canUseDirectoryBookmarks,let bookmark=sender.representedObject as? DirectoryBookmark else{return}
  do{guard try bookmarkStore.bookmarks(for:bookmarkScope).contains(where:{$0.same(as:bookmark)}) else{throw SFTPError.message("目录书签已变化，请重新打开书签菜单")};load(bookmark.path)}catch{status.stringValue=error.localizedDescription;status.toolTip=status.stringValue}
 }
 @objc func renameDirectoryBookmark(_ sender:NSMenuItem){guard !stopped,let bookmark=sender.representedObject as? DirectoryBookmark,let title=requestBookmarkTitle("重命名目录书签",initial:bookmark.title),!stopped else{return};do{try bookmarkStore.rename(bookmark,title:title,scope:bookmarkScope);status.stringValue="目录书签已重命名"}catch{status.stringValue=error.localizedDescription};status.toolTip=status.stringValue}
 @objc func removeDirectoryBookmark(_ sender:NSMenuItem){guard !stopped,let bookmark=sender.representedObject as? DirectoryBookmark else{return};do{try bookmarkStore.remove(bookmark,scope:bookmarkScope);status.stringValue="已移除目录书签，远程目录保留"}catch{status.stringValue=error.localizedDescription};status.toolTip=status.stringValue}
}
