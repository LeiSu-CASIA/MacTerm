import Cocoa

struct BroadcastTarget {
 let id:UUID,label:String,detail:String
 let isReady:()->Bool
 let send:(String)->Bool
}
struct BroadcastReceipt {
 let id:UUID,label:String,detail:String,total:Int
 var submitted=0;var reason:String?;var cancelled=false
 var active:Bool {!cancelled && reason==nil && submitted<total}
 var summary:String {
  if let reason=reason{return "已跳过 · \(submitted)/\(total) · "+reason}
  if cancelled && submitted<total{return "已取消后续 · \(submitted)/\(total)"}
  return submitted==total ? "已提交 \(submitted)/\(total)" : "等待发送 · \(submitted)/\(total)"
 }
}
enum BroadcastState:Equatable {case idle,running(Int,Int),complete,cancelled}
// Main-thread scheduler: one immutable target/command snapshot per explicit send.
final class CommandBroadcast {
 private(set) var state:BroadcastState = .idle
 private(set) var receipts=[BroadcastReceipt]();private(set) var sendsReturn=false
 var changed:(()->Void)?
 private var targets=[BroadcastTarget](),steps=[String](),index=0,delay=0,generation=UUID(),runID=UUID();private var pending:DispatchWorkItem?
 var isRunning:Bool {if case .running=state{return true};return false}
 func start(_ command:TerminalMacro,targets:[BroadcastTarget])throws {
  guard !isRunning,command.events==nil else{throw SFTPError.message("广播需要命令文本，且不能在发送中再次启动")};_ = try command.validated()
  guard !targets.isEmpty,targets.count<=100,Set(targets.map{$0.id}).count==targets.count else{throw SFTPError.message("请选择 1–100 个不同的目标终端")}
  generation=UUID();runID=UUID();self.targets=targets;steps=command.steps;sendsReturn=command.sendReturn;delay=command.intervalMilliseconds;index=0
  receipts=targets.map{BroadcastReceipt(id:$0.id,label:$0.label,detail:$0.detail,total:steps.count)};state = .running(0,steps.count);let token=generation;changed?();if token==generation,isRunning{schedule(token,after:0)}
 }
 private func schedule(_ token:UUID,after milliseconds:Int){let work=DispatchWorkItem{[weak self] in self?.tick(token)};pending=work;DispatchQueue.main.asyncAfter(deadline:.now() + .milliseconds(milliseconds),execute:work)}
 private func tick(_ token:UUID){guard token==generation,isRunning else{return};let identity=runID
  for row in receipts.indices {
   guard token==generation,isRunning else{return};guard receipts[row].active else{continue}
   let target=targets[row]
   let ready=target.isReady();guard token==generation,isRunning else{return};guard ready else{receipts[row].reason="尚未就绪或已断开";continue}
   let accepted=target.send(steps[index])
   // A send callback may cancel/restart. Count accepted input for this run even
   // when cancellation occurred during the callback; never mutate a new run.
   guard identity==runID else{return}
   if accepted{receipts[row].submitted+=1}else if !receipts[row].cancelled{receipts[row].reason="输入未接受"}
   guard token==generation,isRunning else{changed?();return}
  }
  index+=1
  if index==steps.count || !receipts.contains(where:{$0.active}) {pending=nil;targets=[];steps=[];state = .complete;changed?()}
  else {state = .running(index,steps.count);changed?();if token==generation,isRunning{schedule(token,after:delay)}}
 }
 func cancel(){guard isRunning else{return};generation=UUID();pending?.cancel();pending=nil;for index in receipts.indices where receipts[index].active {receipts[index].cancelled=true};targets=[];steps=[];state = .cancelled;changed?()}
 deinit{pending?.cancel()}
}

extension AppDelegate {
 var broadcastTargets:[BroadcastTarget] {tabs.tabViewItems.compactMap{item in
  guard let pane=(item.view as? TerminalPane) ?? (item.view as? SSHWorkspace)?.terminal else{return nil}
  let readiness:()->Bool;let detail:String
  if let workspace=item.view as? SSHWorkspace {detail="SSH · "+workspace.session.connectionSummary;readiness = {[weak pane,weak workspace] in guard let pane=pane,let workspace=workspace else{return false};return !workspace.stopped && !pane.stopped && pane.pid>0 && !pane.receivedEOF && FileManager.default.fileExists(atPath:workspace.socket)}}
  else {detail=pane.serialSettings.map{"串口 · "+$0.summary} ?? pane.telnetDestination.map{"Telnet · "+$0} ?? "本地终端";readiness = {[weak pane] in guard let pane=pane else{return false};return !pane.stopped && pane.pid>0 && !pane.receivedEOF && (pane.serialSettings==nil || pane.serialConnected) && (pane.telnetSettings==nil || pane.telnetConnected)}}
  return BroadcastTarget(id:pane.identity,label:item.label,detail:detail,isReady:readiness,send:{[weak pane] text in guard readiness(),let pane=pane else{return false};pane.send(text);return true})
 }}
 @objc func openBroadcastFromToolbar(){if inputSyncWindow?.runner.isRunning==true{stopInputSynchronization()}else{openBroadcast()}}
 @objc func openBroadcast(){if broadcastWindow==nil{broadcastWindow=BroadcastWindow();broadcastWindow?.workspaceOwner=self};broadcastWindow?.present()}
}

final class BroadcastWindow:NSWindowController,NSWindowDelegate,NSTableViewDataSource,NSTableViewDelegate,NSTextViewDelegate,NSTextFieldDelegate {
 weak var workspaceOwner:AppDelegate?
 let runner=CommandBroadcast();let table=NSTableView(),commands=NSTextView();let interval=NSTextField(string:"500"),execute=NSButton(checkboxWithTitle:"发送回车（执行命令）",target:nil,action:nil)
 let sendButton=NSButton(title:"填入所选终端",target:nil,action:nil),cancelButton=NSButton(title:"取消后续发送",target:nil,action:nil),refreshButton=NSButton(title:"刷新目标",target:nil,action:nil),allButton=NSButton(title:"全选可用",target:nil,action:nil),currentButton=NSButton(title:"仅选当前标签",target:nil,action:nil),clearButton=NSButton(title:"清空选择",target:nil,action:nil)
 let countLabel=NSTextField(labelWithString:"未选择目标"),status=NSTextField(wrappingLabelWithString:"选择目标并输入命令。默认只填入，不发送回车。")
 private(set) var rows=[BroadcastTarget]();private(set) var selectedIDs=Set<UUID>();private var timer:Timer?
 init(){let window=NSWindow(contentRect:NSRect(x:0,y:0,width:900,height:710),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false);window.title="MacTerm · 多终端命令广播";window.appearance=NSAppearance(named:.darkAqua);window.backgroundColor=AppTheme.background;window.titlebarAppearsTransparent=true;window.minSize=NSSize(width:760,height:660);window.isReleasedWhenClosed=false;super.init(window:window);window.delegate=self;window.center()
  let root=NSStackView();root.orientation = .vertical;root.alignment = .leading;root.spacing=10;root.edgeInsets=NSEdgeInsets(top:20,left:20,bottom:20,right:20);root.translatesAutoresizingMaskIntoConstraints=false;window.contentView!.addSubview(root);NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor),root.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor),root.topAnchor.constraint(equalTo:window.contentView!.topAnchor),root.bottomAnchor.constraint(equalTo:window.contentView!.bottomAnchor)])
  let heading=NSTextField(labelWithString:"多终端命令广播");heading.font = .systemFont(ofSize:22,weight:.semibold);root.addArrangedSubview(heading)
  let hint=NSTextField(wrappingLabelWithString:"仅发送到明确勾选的连接。SSH 请先完成认证，Telnet 请先完成登录。\n每行一步，按固定间隔提交，不等待命令结束；重连后的新连接需重新选择。");hint.font = .systemFont(ofSize:12);hint.textColor=AppTheme.muted;root.addArrangedSubview(hint);hint.widthAnchor.constraint(equalTo:root.widthAnchor,constant:-40).isActive=true
  let sync=NSButton(title:"实时输入同步…",target:self,action:#selector(openInputSync));let choices=NSStackView(views:[refreshButton,allButton,currentButton,clearButton,sync]);choices.spacing=8;root.addArrangedSubview(choices)
  for (id,title,width) in [("choice","",36.0),("target","目标终端",320.0),("status","状态 / 最近一次发送",420.0)] {let column=NSTableColumn(identifier:NSUserInterfaceItemIdentifier(id));column.title=title;column.width=width;if id=="choice"{column.minWidth=36;column.maxWidth=36};table.addTableColumn(column)};table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle;table.rowHeight=42;table.backgroundColor=AppTheme.sidebar;table.dataSource=self;table.delegate=self;table.allowsEmptySelection=true
  let list=NSScrollView();list.hasVerticalScroller=true;list.scrollerStyle = .overlay;list.documentView=table;root.addArrangedSubview(list);list.widthAnchor.constraint(equalTo:root.widthAnchor,constant:-40).isActive=true;list.heightAnchor.constraint(greaterThanOrEqualToConstant:110).isActive=true;list.setContentHuggingPriority(.init(1),for:.vertical)
  countLabel.font = .systemFont(ofSize:11,weight:.medium);countLabel.textColor=AppTheme.accent;root.addArrangedSubview(countLabel)
  commands.isRichText=false;commands.allowsUndo=true;commands.font = .monospacedSystemFont(ofSize:13,weight:.regular);commands.backgroundColor=AppTheme.terminal;commands.textColor=AppTheme.text;commands.insertionPointColor=AppTheme.accent;commands.textContainerInset=NSSize(width:10,height:10);commands.isAutomaticQuoteSubstitutionEnabled=false;commands.isAutomaticDashSubstitutionEnabled=false;commands.isAutomaticTextReplacementEnabled=false;commands.isAutomaticSpellingCorrectionEnabled=false;commands.delegate=self;commands.isVerticallyResizable=true;commands.autoresizingMask=[.width];commands.textContainer?.widthTracksTextView=true
  let editor=NSScrollView();editor.hasVerticalScroller=true;editor.backgroundColor=AppTheme.terminal;editor.documentView=commands;root.addArrangedSubview(editor);editor.widthAnchor.constraint(equalTo:root.widthAnchor,constant:-40).isActive=true;editor.heightAnchor.constraint(equalToConstant:110).isActive=true
  interval.delegate=self;interval.widthAnchor.constraint(equalToConstant:65).isActive=true;interval.setAccessibilityLabel("广播每行间隔毫秒");let options=NSStackView(views:[NSTextField(labelWithString:"每行间隔"),interval,NSTextField(labelWithString:"毫秒"),execute]);options.spacing=8;root.addArrangedSubview(options)
  let actions=NSStackView(views:[sendButton,cancelButton]);actions.spacing=10;root.addArrangedSubview(actions);sendButton.bezelStyle = .rounded;sendButton.bezelColor=AppTheme.accent;sendButton.contentTintColor=AppTheme.background;status.font = .systemFont(ofSize:11);status.textColor=AppTheme.muted;root.addArrangedSubview(status);status.widthAnchor.constraint(equalTo:root.widthAnchor,constant:-40).isActive=true;status.heightAnchor.constraint(greaterThanOrEqualToConstant:30).isActive=true
  for (button,action) in [(sendButton,#selector(submit)),(cancelButton,#selector(cancelSending)),(refreshButton,#selector(refreshTargets)),(allButton,#selector(selectAllReady)),(currentButton,#selector(selectCurrent)),(clearButton,#selector(clearSelection)),(execute,#selector(changedOptions))] {button.target=self;button.action=action}
  runner.changed = {[weak self] in self?.broadcastChanged()};updateControls()
 }
 required init?(coder:NSCoder){fatalError()}
 func present(){if !runner.isRunning {refreshTargets()};showWindow(nil);window?.makeKeyAndOrderFront(nil);timer?.invalidate();timer=Timer.scheduledTimer(withTimeInterval:0.5,repeats:true){[weak self] _ in self?.table.reloadData();self?.updateControls()}}
 @objc func refreshTargets(){guard !runner.isRunning else{return};let fresh=workspaceOwner?.broadcastTargets ?? [];let ids=Set(fresh.map{$0.id}),receipts=Set(runner.receipts.map{$0.id});let retained=rows.filter{!ids.contains($0.id)&&receipts.contains($0.id)};rows=fresh+retained;selectedIDs.formIntersection(ids);table.reloadData();updateControls()}
 func numberOfRows(in tableView:NSTableView)->Int{rows.count}
 func tableView(_ tableView:NSTableView,viewFor column:NSTableColumn?,row:Int)->NSView? {let target=rows[row]
  if column?.identifier.rawValue=="choice" {let button=NSButton(checkboxWithTitle:"",target:self,action:#selector(toggleTarget(_:)));button.identifier=NSUserInterfaceItemIdentifier(target.id.uuidString);button.setAccessibilityLabel("选择 "+target.label+" · "+target.detail);button.state=selectedIDs.contains(target.id) ? .on : .off;button.isEnabled = !runner.isRunning && (target.isReady() || selectedIDs.contains(target.id));let cell=NSView();button.translatesAutoresizingMaskIntoConstraints=false;cell.addSubview(button);NSLayoutConstraint.activate([button.centerXAnchor.constraint(equalTo:cell.centerXAnchor),button.centerYAnchor.constraint(equalTo:cell.centerYAnchor)]);return cell}
  let label=NSTextField(labelWithString:"");label.lineBreakMode = .byTruncatingTail
  if column?.identifier.rawValue=="target" {let title=NSMutableAttributedString(string:target.label+"\n",attributes:[.font:NSFont.systemFont(ofSize:12,weight:.medium),.foregroundColor:AppTheme.text]);title.append(NSAttributedString(string:target.detail,attributes:[.font:NSFont.monospacedSystemFont(ofSize:10,weight:.regular),.foregroundColor:AppTheme.muted]));label.attributedStringValue=title;label.toolTip=target.label+"\n"+target.detail}
  else {let receipt=runner.receipts.first{$0.id==target.id};label.font = .systemFont(ofSize:11);label.stringValue=receipt?.summary ?? (target.isReady() ? "可用" : "尚未就绪 / 已断开");label.textColor=receipt?.reason != nil ? .systemOrange : receipt?.submitted==receipt?.total && receipt != nil ? AppTheme.accent : AppTheme.muted;label.toolTip=label.stringValue};return label
 }
 @objc func toggleTarget(_ sender:NSButton){guard !runner.isRunning,let raw=sender.identifier?.rawValue,let id=UUID(uuidString:raw),let row=rows.first(where:{$0.id==id}) else{return};if selectedIDs.contains(id){selectedIDs.remove(id)}else if row.isReady(),selectedIDs.count<100{selectedIDs.insert(id)}else{status.stringValue="最多选择 100 个已就绪终端。"};table.reloadData();updateControls()}
 func choose(_ ids:Set<UUID>){guard !runner.isRunning,ids.count<=100 else{return};selectedIDs=ids.intersection(Set(rows.map{$0.id}));table.reloadData();updateControls()}
 @objc func selectAllReady(){guard !runner.isRunning else{return};let ids=Set(rows.filter{$0.isReady()}.map{$0.id});guard ids.count<=100 else{status.stringValue="可用终端超过 100 个，请手动选择目标。";return};choose(ids)}
 @objc func clearSelection(){choose([])}
 @objc func selectCurrent(){guard !runner.isRunning else{return};choose([]);if let id=workspaceOwner?.activeTerminal?.identity,rows.contains(where:{$0.id==id && $0.isReady()}){choose([id])}else{status.stringValue="当前标签尚未就绪；没有选择目标。"}}
 func command()throws->TerminalMacro {guard let delay=Int(interval.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)) else{throw SFTPError.message("间隔必须填写整数毫秒")};do{return try TerminalMacro(name:"多终端广播",body:commands.string,intervalMilliseconds:delay,sendReturn:execute.state == .on).validated()}catch{throw SFTPError.message(error.localizedDescription.replacingOccurrences(of:"宏",with:"广播命令"))}}
 @objc func changedOptions(){guard !runner.isRunning else{return};do{_ = try command();status.stringValue=execute.state == .on ? "准备发送命令并回车；请核对勾选目标。" : "准备填入单行文本；不发送回车。"}catch{status.stringValue=error.localizedDescription};updateControls()}
 func textDidChange(_ notification:Notification){changedOptions()}
 func controlTextDidChange(_ notification:Notification){changedOptions()}
 @objc func openInputSync(){workspaceOwner?.openInputSynchronization()}
 @objc func submit(){guard !runner.isRunning else{return};if workspaceOwner?.inputSyncWindow?.runner.isRunning==true{status.stringValue="实时同步中，请先停止后再广播。";return};if workspaceOwner?.macroWindow?.recorder.isRecording==true{status.stringValue="输入录制中，请停止录制后再广播。";return};do{try runner.start(command(),targets:rows.filter{selectedIDs.contains($0.id)})}catch{status.stringValue=error.localizedDescription};updateControls()}
 @objc func cancelSending(){runner.cancel()}
 private func broadcastChanged(){let submitted=runner.receipts.reduce(0){$0+$1.submitted},skipped=runner.receipts.filter{$0.reason != nil}.count
  switch runner.state {
  case .idle:break
  case .running(let step,let total):status.stringValue="广播中：第 \(step)/\(total) 步 · \(runner.receipts.count) 个固定目标 · 已提交 \(submitted) 次"
  case .complete:status.stringValue="本轮已提交 \(submitted) 次，跳过 \(skipped) 个目标。请在各终端确认结果。"
  case .cancelled:status.stringValue="已取消后续发送；已提交 \(submitted) 次，不能撤回。"
  };table.reloadData();updateControls()
 }
 private func updateControls(){let running=runner.isRunning,chosen=rows.filter{selectedIDs.contains($0.id)};let valid=(try? command()) != nil;countLabel.stringValue="已选 \(chosen.count) 个 · 当前可用 \(rows.filter{$0.isReady()}.count) 个 · 发送期间固定目标";sendButton.title=(execute.state == .on ? "发送并执行到 " : "填入 ")+String(chosen.count)+" 个终端";sendButton.isEnabled = !running && workspaceOwner?.inputSyncWindow?.runner.isRunning != true && workspaceOwner?.macroWindow?.recorder.isRecording != true && valid && !chosen.isEmpty && chosen.contains{$0.isReady()};sendButton.toolTip=valid ? "只提交到勾选目标，不等待远端执行结果" : "请输入有效命令和 0–60000 毫秒间隔；仅填入模式只允许单行";cancelButton.isEnabled=running;commands.isEditable = !running;interval.isEnabled = !running;execute.isEnabled = !running;for button in [refreshButton,allButton,currentButton,clearButton]{button.isEnabled = !running}}
 func windowWillClose(_ notification:Notification){runner.cancel();timer?.invalidate();timer=nil}
 deinit{timer?.invalidate()}
}
