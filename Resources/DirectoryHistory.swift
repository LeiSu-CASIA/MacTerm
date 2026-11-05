import Cocoa

enum RemoteFileIdentity {static func key(_ value:String)->Data {Data(value.utf8)}}

struct RemoteDirectoryHistory {
 struct Ticket:Equatable {let owner:UUID;let revision:Int;let index:Int;let path:String;static func ==(a:Ticket,b:Ticket)->Bool {a.owner==b.owner && a.revision==b.revision && a.index==b.index && RemoteFileIdentity.key(a.path)==RemoteFileIdentity.key(b.path)}}
 private let identity=UUID();private(set) var paths=[String]();private(set) var index = -1;private var revision=0;let capacity:Int
 init(capacity:Int=100){self.capacity=max(1,capacity)}
 var current:String? {paths.indices.contains(index) ? paths[index] : nil}
 var canGoBack:Bool {index>0}
 var canGoForward:Bool {index>=0 && index+1<paths.count}
 func ticket(at destination:Int)->Ticket? {guard paths.indices.contains(destination),destination != index else{return nil};return Ticket(owner:identity,revision:revision,index:destination,path:paths[destination])}
 var backward:Ticket? {ticket(at:index-1)}
 var forward:Ticket? {ticket(at:index+1)}
 mutating func visit(_ path:String){guard !path.isEmpty,(current.map{RemoteFileIdentity.key($0) != RemoteFileIdentity.key(path)} ?? true) else{return};if index+1<paths.count {paths.removeSubrange((index+1)..<paths.count)};paths.append(path);if paths.count>capacity {paths.removeFirst(paths.count-capacity)};index=paths.count-1;revision+=1}
 func accepts(_ ticket:Ticket)->Bool {ticket.owner==identity && ticket.revision==revision && paths.indices.contains(ticket.index) && RemoteFileIdentity.key(paths[ticket.index])==RemoteFileIdentity.key(ticket.path)}
 @discardableResult mutating func commit(_ ticket:Ticket,canonical:String)->Bool {guard accepts(ticket),!canonical.isEmpty else{return false};paths[ticket.index]=canonical;index=ticket.index;revision+=1;return true}
 mutating func clear(){if let path=current {paths=[path];index=0}else{paths=[];index = -1};revision+=1}
 static func resolve(_ input:String,relativeTo current:String)->String {if input.isEmpty {return current};if input.hasPrefix("/") || current=="." || current.isEmpty {return input};return (current=="/" ? "/" : current+"/")+input}
 static func menuTitle(_ path:String)->String {let clean=path.replacingOccurrences(of:"\n",with:"\\n").replacingOccurrences(of:"\r",with:"\\r").replacingOccurrences(of:"\t",with:"\\t");return clean.count>160 ? String(clean.prefix(77))+"…"+String(clean.suffix(77)) : clean}
}
struct RemoteDirectoryView {var query:String;var selected:Set<Data>;var scrollY:CGFloat}

extension SSHWorkspace {
 func updateNavigationControls(){let enabled = !busy && !stopped && terminal.pid>0 && transferQueue.active==nil;path.isEnabled=enabled;backDirectoryButton.isEnabled=enabled && directoryHistory.canGoBack;forwardDirectoryButton.isEnabled=enabled && directoryHistory.canGoForward;historyDirectoryButton.isEnabled=enabled && !directoryHistory.paths.isEmpty}
 func commitDirectory(_ canonical:String,entries:[RemoteFile],ticket:RemoteDirectoryHistory.Ticket?=nil)->Bool {
  let selected=Set(files.selectedRowIndexes.compactMap{self.entries.indices.contains($0) ? RemoteFileIdentity.key(self.entries[$0].name) : nil})
  let view=RemoteDirectoryView(query:fileFilter.stringValue,selected:selected,scrollY:files.enclosingScrollView?.contentView.bounds.origin.y ?? 0)
  let previous=directoryHistory.current
  if let ticket=ticket {guard directoryHistory.commit(ticket,canonical:canonical) else{return false}}else{directoryHistory.visit(canonical)}
  if let previous=previous {directoryViews[RemoteFileIdentity.key(previous)]=view}
  let retained=Set(directoryHistory.paths.map{RemoteFileIdentity.key($0)});directoryViews=directoryViews.filter{retained.contains($0.key)}
  let restored=directoryViews[RemoteFileIdentity.key(canonical)] ?? RemoteDirectoryView(query:"",selected:[],scrollY:0)
  remotePath=canonical;path.stringValue=canonical;path.toolTip=canonical+"\n相对路径从当前目录解析；~ 跳到 SFTP 起始目录。";allEntries=entries;fileFilter.stringValue=restored.query;renderFiles(preserveSelection:false)
  files.selectRowIndexes(IndexSet(self.entries.indices.filter{restored.selected.contains(RemoteFileIdentity.key(self.entries[$0].name))}),byExtendingSelection:false)
  if let scroll=files.enclosingScrollView {files.layoutSubtreeIfNeeded();let maximum=max(0,scroll.contentView.documentRect.height-scroll.contentView.bounds.height);scroll.contentView.scroll(to:NSPoint(x:0,y:min(max(0,restored.scrollY),maximum)));scroll.reflectScrolledClipView(scroll.contentView)}
  updateNavigationControls();return true
 }
 func load(_ target:String,ticket:RemoteDirectoryHistory.Ticket?=nil){guard !busy,!stopped,terminal.pid>0,transferQueue.active==nil else{path.stringValue=remotePath;return};if let ticket=ticket,!directoryHistory.accepts(ticket){path.stringValue=remotePath;return};let request=UUID();directoryRequest=request;let current=remotePath;var result:(String,[RemoteFile])?
  run("读取目录…",completion:{[weak self] error in guard let self=self,!self.stopped,self.directoryRequest==request else{return};guard error==nil,!self.cancelRequested,let result=result else{self.path.stringValue=self.remotePath;return};if !self.commitDirectory(result.0,entries:result.1,ticket:ticket){self.path.stringValue=self.remotePath;self.status.stringValue="路径历史已变化，结果未应用"}}){client in
   let resolved:String
   if target=="~" || target.hasPrefix("~/") {let home=try client.canonical(".");resolved=target=="~" ? home : RemoteDirectoryHistory.resolve(String(target.dropFirst(2)),relativeTo:home)}
   else {resolved=RemoteDirectoryHistory.resolve(target,relativeTo:current)}
   let canonical=try client.canonical(resolved);result=(canonical,try client.list(canonical))
  }
 }
 @objc func backDirectory(){if let ticket=directoryHistory.backward {load(ticket.path,ticket:ticket)}}
 @objc func forwardDirectory(){if let ticket=directoryHistory.forward {load(ticket.path,ticket:ticket)}}
 func directoryMenu()->NSMenu {let menu=NSMenu();menu.autoenablesItems=false
  for index in directoryHistory.paths.indices.reversed() {let entry=menu.addItem(withTitle:RemoteDirectoryHistory.menuTitle(directoryHistory.paths[index]),action:#selector(jumpToDirectory(_:)),keyEquivalent:"");entry.target=self;entry.toolTip=directoryHistory.paths[index];entry.state=index==directoryHistory.index ? .on : .off;entry.representedObject=directoryHistory.ticket(at:index);entry.isEnabled = !busy && !stopped && terminal.pid>0 && transferQueue.active==nil && index != directoryHistory.index}
  if directoryHistory.paths.isEmpty {let empty=menu.addItem(withTitle:"尚无成功打开的路径",action:nil,keyEquivalent:"");empty.isEnabled=false}
  menu.addItem(.separator());let clear=menu.addItem(withTitle:"清空历史（保留当前位置）",action:#selector(clearDirectoryHistory),keyEquivalent:"");clear.target=self;clear.isEnabled = !busy && transferQueue.active==nil && directoryHistory.paths.count>1;return menu
 }
 @objc func showDirectoryHistory(_ sender:NSButton){directoryMenu().popUp(positioning:nil,at:NSPoint(x:0,y:sender.bounds.height),in:sender)}
 @objc func jumpToDirectory(_ sender:NSMenuItem){guard let ticket=sender.representedObject as? RemoteDirectoryHistory.Ticket else{return};load(ticket.path,ticket:ticket)}
 @objc func clearDirectoryHistory(){guard !busy,transferQueue.active==nil else{return};directoryHistory.clear();directoryViews=directoryViews.filter{$0.key==RemoteFileIdentity.key(remotePath)};updateNavigationControls()}
 func finishFileOperation(_ error:Error?,completion:((Error?)->Void)?){let cancelled=cancelRequested;busy=false;let finalError:Error?=cancelled ? SFTPError.message("操作已取消；已完成的远程操作可能保留，请刷新确认") : error
  if !stopped {if terminal.pid==0 {status.stringValue="SSH 已断开"}else if cancelled {status.stringValue="已取消"}else{status.stringValue=finalError?.localizedDescription ?? "完成"};status.toolTip=finalError?.localizedDescription}
  updateNavigationControls();completion?(finalError)
 }
}
