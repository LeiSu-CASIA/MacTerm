import Cocoa

struct InputSyncReceipt {
 let id:UUID,label:String
 var bytes=0;var reason:String?
}
// User input only. send callbacks write directly to fixed transport identities.
final class TerminalInputSync {
 private(set) var sourceID:UUID?;private(set) var receipts=[InputSyncReceipt]();private(set) var isRunning=false;private(set) var message="尚未开始同步"
 var changed:(()->Void)?
 private var source:BroadcastTarget?,targets=[BroadcastTarget](),generation=UUID();private(set) var runID=UUID()
 func start(source:BroadcastTarget,targets:[BroadcastTarget])throws {
  guard !isRunning,targets.count>0,targets.count<=100,Set(targets.map{$0.id}).count==targets.count,!targets.contains(where:{$0.id==source.id}) else{throw SFTPError.message("请选择来源及 1–100 个不同的其他目标终端")}
  let token=generation;guard source.isReady(),targets.allSatisfy({$0.isReady()}) else{throw SFTPError.message("来源和所有目标需先就绪；SSH 请先完成认证")}
  guard !isRunning,token==generation else{throw SFTPError.message("同步状态已变化，请重新选择")}
  self.source=source;sourceID=source.id;self.targets=targets;receipts=targets.map{InputSyncReceipt(id:$0.id,label:$0.label)};generation=UUID();runID=UUID();isRunning=true;message="正在同步固定来源："+source.label;changed?()
 }
 func receive(_ input:String,from id:UUID,run:UUID?=nil){
  guard run==nil || run==runID else{return}
  guard isRunning,id==sourceID,!input.isEmpty else{return}
  guard input.utf8.count<=65536 else{stop("单次输入超过 64 KB，已停止同步；该次输入未发送到目标");return}
  let token=generation,identity=runID;guard source?.isReady()==true else{if token==generation{stop("来源已断开，已停止同步")};return};guard token==generation,isRunning else{return}
  for index in targets.indices {
   guard token==generation,isRunning else{return};guard receipts[index].reason==nil else{continue}
   let target=targets[index],ready=target.isReady();guard token==generation,isRunning else{return}
   guard ready else{receipts[index].reason="目标已断开，后续输入不再发送";changed?();continue}
   let accepted=target.send(input);guard identity==runID else{return}
   if accepted{receipts[index].bytes+=input.utf8.count}else{receipts[index].reason="目标拒绝输入";changed?()}
   guard token==generation,isRunning else{return}
  }
  if !receipts.contains(where:{$0.reason==nil}){stop("所有目标均已断开或拒绝输入，已停止同步")}
 }
 func poll(){
  guard isRunning else{return};let token=generation
  let ready=source?.isReady()==true;guard token==generation,isRunning else{return};guard ready else{stop("来源已断开，已停止同步");return}
  var updated=false
  for index in targets.indices where receipts[index].reason==nil {let ready=targets[index].isReady();guard token==generation,isRunning else{return};if !ready{receipts[index].reason="目标已断开，后续输入不再发送";updated=true}}
  if !receipts.contains(where:{$0.reason==nil}){stop("所有目标已断开，已停止同步")}else if updated{changed?()}
 }
 func stop(_ reason:String="已停止同步；已提交的输入不能撤回") {guard isRunning else{return};generation=UUID();isRunning=false;source=nil;targets=[];message=reason;changed?()}
}
private final class SyncPaneReference {weak var pane:TerminalPane?;init(_ pane:TerminalPane){self.pane=pane}}

final class InputSyncWindow:NSWindowController,NSWindowDelegate,NSTableViewDataSource,NSTableViewDelegate {
 weak var workspaceOwner:AppDelegate?
 let runner=TerminalInputSync(),sourcePicker=NSPopUpButton(),table=NSTableView()
 let startButton=AppActionButton(title:"开始实时同步",target:nil,action:nil),stopButton=NSButton(title:"停止同步",target:nil,action:nil),refreshButton=NSButton(title:"刷新连接",target:nil,action:nil)
 let status=NSTextField(wrappingLabelWithString:"选择来源，勾选目标后开始。不会自动开始同步。")
 private(set) var rows=[BroadcastTarget]();private(set) var selectedIDs=Set<UUID>();private var timer:Timer?;private weak var sourcePane:TerminalPane?;private var markedPanes=[SyncPaneReference]()
 var selectedSourceID:UUID? {sourcePicker.selectedItem?.representedObject as? UUID}
 init(){let panel=NSWindow(contentRect:NSRect(x:0,y:0,width:760,height:540),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false);panel.title="MacTerm · 实时输入同步";panel.appearance=NSAppearance(named:.darkAqua);panel.backgroundColor=AppTheme.background;panel.titlebarAppearsTransparent=true;panel.minSize=NSSize(width:660,height:480);panel.isReleasedWhenClosed=false;super.init(window:panel);panel.delegate=self;panel.center()
  let root=NSStackView();root.orientation = .vertical;root.alignment = .leading;root.spacing=12;root.edgeInsets=NSEdgeInsets(top:22,left:24,bottom:22,right:24);root.translatesAutoresizingMaskIntoConstraints=false;panel.contentView!.addSubview(root);NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:panel.contentView!.leadingAnchor),root.trailingAnchor.constraint(equalTo:panel.contentView!.trailingAnchor),root.topAnchor.constraint(equalTo:panel.contentView!.topAnchor),root.bottomAnchor.constraint(equalTo:panel.contentView!.bottomAnchor)])
  let heading=NSTextField(labelWithString:"实时输入同步");heading.font = .systemFont(ofSize:22,weight:.semibold);root.addArrangedSubview(heading)
  let hint=NSTextField(wrappingLabelWithString:"来源中的输入会立即发送到勾选目标，包括回车、控制键和密码。\n请先完成登录并核对目标。停止只影响后续输入，已发送内容不能撤回。");hint.textColor=AppTheme.muted;hint.font = .systemFont(ofSize:12);root.addArrangedSubview(hint);hint.widthAnchor.constraint(equalTo:root.widthAnchor,constant:-48).isActive=true
  let source=NSStackView(views:[NSTextField(labelWithString:"来源终端"),sourcePicker,refreshButton]);source.spacing=10;root.addArrangedSubview(source);source.widthAnchor.constraint(equalTo:root.widthAnchor,constant:-48).isActive=true;sourcePicker.setContentHuggingPriority(.init(1),for:.horizontal);sourcePicker.setContentCompressionResistancePriority(.init(1),for:.horizontal);sourcePicker.cell?.lineBreakMode = .byTruncatingMiddle;sourcePicker.setAccessibilityLabel("实时同步来源终端");sourcePicker.target=self;sourcePicker.action = #selector(sourceChanged)
  for (id,title,width) in [("choice","",36.0),("target","目标终端",340.0),("status","同步状态",320.0)] {let column=NSTableColumn(identifier:NSUserInterfaceItemIdentifier(id));column.title=title;column.width=width;if id=="choice"{column.minWidth=36;column.maxWidth=36};table.addTableColumn(column)}
  table.backgroundColor=AppTheme.sidebar;table.rowHeight=42;table.dataSource=self;table.delegate=self;table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
  let scroll=NSScrollView();scroll.documentView=table;scroll.hasVerticalScroller=true;scroll.scrollerStyle = .overlay;root.addArrangedSubview(scroll);scroll.widthAnchor.constraint(equalTo:root.widthAnchor,constant:-48).isActive=true;scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:100).isActive=true;scroll.setContentHuggingPriority(.init(1),for:.vertical)
  status.font = .systemFont(ofSize:12);status.textColor=AppTheme.muted;root.addArrangedSubview(status);status.widthAnchor.constraint(equalTo:root.widthAnchor,constant:-48).isActive=true;status.heightAnchor.constraint(greaterThanOrEqualToConstant:36).isActive=true
  startButton.isBordered=false;startButton.restingColor=AppTheme.accent;startButton.contentTintColor=AppTheme.background;startButton.widthAnchor.constraint(equalToConstant:130).isActive=true;startButton.heightAnchor.constraint(equalToConstant:32).isActive=true
  let actions=NSStackView(views:[startButton,stopButton]);actions.spacing=12;root.addArrangedSubview(actions)
  startButton.target=self;startButton.action = #selector(startSynchronization);stopButton.target=self;stopButton.action = #selector(stopSynchronization);refreshButton.target=self;refreshButton.action = #selector(refreshTargets)
  runner.changed = {[weak self] in self?.synchronizationChanged()};updateControls()
 }
 required init?(coder:NSCoder){fatalError()}
 func present(){if !runner.isRunning{refreshTargets()};showWindow(nil);window?.makeKeyAndOrderFront(nil);ensureTimer()}
 private func ensureTimer(){guard timer==nil else{return};let timer=Timer(timeInterval:0.25,repeats:true){[weak self] _ in self?.runner.poll();self?.table.reloadData();self?.updateControls()};self.timer=timer;RunLoop.main.add(timer,forMode:.common)}
 @objc func refreshTargets(){guard !runner.isRunning else{return};let old=selectedSourceID;rows=workspaceOwner?.broadcastTargets ?? [];sourcePicker.removeAllItems();for row in rows {sourcePicker.addItem(withTitle:row.label+" · "+row.detail);sourcePicker.lastItem?.representedObject=row.id};let chosen=old ?? workspaceOwner?.activeTerminal?.identity;if let index=rows.firstIndex(where:{$0.id==chosen}){sourcePicker.selectItem(at:index)};selectedIDs.formIntersection(Set(rows.map{$0.id}));sourceChanged()}
 @objc func sourceChanged(){guard !runner.isRunning else{return};if let id=selectedSourceID{selectedIDs.remove(id)};table.reloadData();updateControls()}
 func chooseTargets(_ ids:Set<UUID>){guard !runner.isRunning else{return};selectedIDs=ids.intersection(Set(rows.map{$0.id}));if let id=selectedSourceID{selectedIDs.remove(id)};table.reloadData();updateControls()}
 @objc func toggleTarget(_ sender:NSButton){guard !runner.isRunning,let value=sender.identifier?.rawValue,let id=UUID(uuidString:value),id != selectedSourceID else{return};var selection=selectedIDs;if selection.contains(id){selection.remove(id)}else{selection.insert(id)};chooseTargets(selection)}
 func numberOfRows(in tableView:NSTableView)->Int {rows.count}
 func tableView(_ tableView:NSTableView,viewFor column:NSTableColumn?,row index:Int)->NSView? {let target=rows[index]
  if column?.identifier.rawValue=="choice" {let button=NSButton(checkboxWithTitle:"",target:self,action:#selector(toggleTarget(_:)));button.identifier=NSUserInterfaceItemIdentifier(target.id.uuidString);button.state=selectedIDs.contains(target.id) ? .on : .off;button.isEnabled = !runner.isRunning && target.id != selectedSourceID && (target.isReady() || selectedIDs.contains(target.id));button.setAccessibilityLabel("同步到 "+target.label+" · "+target.detail);return button}
  let label=NSTextField(labelWithString:"");label.lineBreakMode = .byTruncatingTail;label.font = .systemFont(ofSize:11);label.textColor=AppTheme.muted
  if column?.identifier.rawValue=="target" {label.stringValue=target.label+" · "+target.detail}
  else if let receipt=runner.receipts.first(where:{$0.id==target.id}) {label.stringValue=receipt.reason ?? "已提交 \(receipt.bytes) 字节";label.textColor=receipt.reason==nil ? AppTheme.accent : .systemOrange}
  else {label.stringValue=target.id==selectedSourceID ? "来源（不重复发送）" : target.isReady() ? "可用" : "未就绪 / 已断开"};label.toolTip=label.stringValue;return label
 }
 @objc func startSynchronization(){
  guard !runner.isRunning,let owner=workspaceOwner else{return}
  guard owner.macroWindow?.recorder.isRecording != true,owner.macroWindow?.playback.isRunning != true,owner.broadcastWindow?.runner.isRunning != true else{status.stringValue="请先停止输入录制、宏回放或命令广播。";return}
  guard let id=selectedSourceID,let source=rows.first(where:{$0.id==id}),let pane=owner.allTerminals.first(where:{$0.identity==id}),pane.recordingSupported else{status.stringValue="来源未就绪或不支持用户输入识别，请刷新后重试。";return}
  let bound=BroadcastTarget(id:source.id,label:source.label,detail:source.detail,isReady:{[weak pane] in source.isReady() && pane?.recordingSupported==true},send:source.send)
  do{try runner.start(source:bound,targets:rows.filter{selectedIDs.contains($0.id)})}catch{status.stringValue=error.localizedDescription;return}
  guard runner.isRunning else{return};let epoch=runner.runID;sourcePane=pane;pane.onSynchronizedUserInput = {[weak self,weak pane] input in guard let pane=pane else{return};self?.runner.receive(input,from:pane.identity,run:epoch)};pane.onUnsupportedSynchronizedInput = {[weak self] in self?.runner.stop("遇到二进制鼠标输入，已停止同步")}
  markedPanes=owner.allTerminals.filter{$0.identity==id || selectedIDs.contains($0.identity)}.map{SyncPaneReference($0)};refreshIndicators();ensureTimer()
  if let item=owner.tabs.tabViewItems.first(where:{(($0.view as? TerminalPane) ?? ($0.view as? SSHWorkspace)?.terminal) === pane}){owner.tabs.selectTabViewItem(item);owner.updateTabStrip()}
  window?.orderOut(nil);owner.window?.makeKeyAndOrderFront(nil);pane.web.evaluateJavaScript("focusTerminal()",completionHandler:nil)
 }
 @objc func stopSynchronization(){runner.stop()}
 private func refreshIndicators(){for reference in markedPanes {guard let pane=reference.pane else{continue};pane.isInputSyncSource=runner.isRunning && pane.identity==runner.sourceID;pane.isInputSyncTarget=runner.isRunning && runner.receipts.contains{$0.id==pane.identity && $0.reason==nil}};workspaceOwner?.updateInputSyncIndicator(runner.isRunning)}
 private func synchronizationChanged(){if !runner.isRunning{sourcePane?.onSynchronizedUserInput=nil;sourcePane?.onUnsupportedSynchronizedInput=nil;sourcePane=nil;if window?.isVisible != true{timer?.invalidate();timer=nil}};refreshIndicators();if !runner.isRunning{markedPanes=[]};status.stringValue=runner.message;table.reloadData();updateControls()}
 private func updateControls(){let active=runner.isRunning;sourcePicker.isEnabled = !active;refreshButton.isEnabled = !active;stopButton.isEnabled=active;startButton.isEnabled = !active && selectedIDs.count>0 && selectedIDs.count<=100 && rows.contains{$0.id==selectedSourceID && $0.isReady()} && rows.filter{selectedIDs.contains($0.id)}.allSatisfy{$0.isReady()};if active{status.stringValue="同步中 · 固定来源与 \(runner.receipts.filter{$0.reason==nil}.count) 个目标 · 已提交 \(runner.receipts.reduce(0){$0+$1.bytes}) 字节。工具栏可随时停止。"}}
 func windowWillClose(_ notification:Notification){runner.stop();timer?.invalidate();timer=nil}
 deinit{timer?.invalidate()}
}
extension AppDelegate {
 @objc func openInputSynchronization(){if inputSyncWindow==nil{inputSyncWindow=InputSyncWindow();inputSyncWindow?.workspaceOwner=self};inputSyncWindow?.present()}
 @objc func stopInputSynchronization(){inputSyncWindow?.stopSynchronization()}
 func updateInputSyncIndicator(_ running:Bool){broadcastToolbarButton?.title=running ? "停止同步" : "广播";broadcastToolbarButton?.image=running ? nil : AppTheme.symbol("square.stack.3d.up");broadcastToolbarButton?.contentTintColor=running ? .systemOrange : AppTheme.accent;broadcastToolbarButton?.toolTip=running ? "实时输入同步中，点击停止后续发送" : "多终端命令广播";updateTabStrip()}
}
