import Cocoa

struct TerminalPastePlan {
 static let maximumBytes=1024*1024
 let text:String,bytes:Int,lineBreaks:Int,controls:Bool
 init(_ text:String)throws {
  let bytes=text.utf8.count;guard !text.isEmpty,bytes<=Self.maximumBytes,!text.contains("\0") else{throw SFTPError.message("粘贴需要 1 字节至 1 MiB 的文本，不能包含 NUL 字符。")}
  self.text=text;self.bytes=bytes;lineBreaks=text.replacingOccurrences(of:"\r\n",with:"\n").unicodeScalars.filter{$0.value==10 || $0.value==13}.count;controls=text.unicodeScalars.contains{Self.special($0.value)}
 }
 static func special(_ value:UInt32)->Bool {(value<32 && value != 9 && value != 10 && value != 13) || (127...159).contains(value) || (0x200b...0x200f).contains(value) && value != 0x200c && value != 0x200d || (0x2028...0x202e).contains(value) || (0x2066...0x2069).contains(value)}
 var needsConfirmation:Bool {lineBreaks>0 || bytes>4096 || controls}
 var normalized:String {text.replacingOccurrences(of:"\r\n",with:"\r").replacingOccurrences(of:"\n",with:"\r")}
 var preview:String {
  let input=text.replacingOccurrences(of:"\r\n",with:"\n").replacingOccurrences(of:"\r",with:"\n"),scalars=input.unicodeScalars.prefix(16384)
  return scalars.map{scalar in Self.special(scalar.value) ? String(format:"⟦U+%04X⟧",scalar.value) : scalar.value==9 ? "⇥" : String(scalar)}.joined()+(input.unicodeScalars.count>16384 ? "\n…（预览已截断，将发送完整内容）" : "")
 }
 func accepts(_ packet:String)->Bool {Data(packet.utf8)==Data(normalized.utf8) || Data(packet.utf8)==Data(("\u{1b}[200~"+normalized+"\u{1b}[201~").utf8)}
}
struct TerminalPasteContext:Equatable {
 var label="当前终端";var phase:WorkspaceConnectionStatus.Phase = .unknown
 var recording=false,source=false,target=false;var recordingID:UUID?,syncID:UUID?;var targetIDs=[UUID](),targetNames=[String]()
}
struct TerminalPasteRequest {
 let id=UUID(),epoch:UUID,pid:Int32,plan:TerminalPastePlan,context:TerminalPasteContext
 func makeAlert()->NSAlert {
  let alert=NSAlert();alert.window.appearance=NSAppearance(named:.darkAqua);alert.messageText="确认粘贴到 "+context.label
  alert.informativeText="共 \(plan.bytes) 字节，\(plan.lineBreaks) 处换行。"+(plan.lineBreaks>0 ? "换行可能立即执行命令。" : "")+(plan.controls ? "包含控制 / 隐藏字符，预览用 U+ 编码标出。" : "")+(context.source ? "\n这是输入同步来源，还会发送到其他已选终端；已提交输入不能撤回。" : "")+(context.recording ? "\n录制已开启，粘贴内容可能被记录；达到录制上限时会停止。" : "")
  let scroll=NSScrollView(frame:NSRect(x:0,y:0,width:440,height:200));scroll.hasVerticalScroller=true;scroll.autohidesScrollers=true;scroll.scrollerStyle = .overlay;scroll.borderType = .noBorder;scroll.backgroundColor=AppTheme.input;AppTheme.surface(scroll,AppTheme.input,radius:8)
  let preview=NSTextView(frame:scroll.bounds);preview.isEditable=false;preview.isSelectable=true;preview.isRichText=false;preview.importsGraphics=false;preview.font = .monospacedSystemFont(ofSize:12,weight:.regular);preview.textColor=AppTheme.text;preview.backgroundColor=AppTheme.input;preview.textContainerInset=NSSize(width:10,height:10);preview.isVerticallyResizable=true;preview.isHorizontallyResizable=false;preview.autoresizingMask=[.width];preview.textContainer?.widthTracksTextView=true;preview.textContainer?.containerSize=NSSize(width:420,height:CGFloat.greatestFiniteMagnitude);preview.string="目标："+context.label+(context.source ? "\n同步目标："+(context.targetNames.isEmpty ? "其他已选择的终端" : context.targetNames.joined(separator:"、")) : "")+"\n\n"+plan.preview;preview.setAccessibilityLabel("粘贴目标和文本预览");scroll.documentView=preview;alert.accessoryView=scroll
  alert.addButton(withTitle:"取消");alert.addButton(withTitle:"粘贴");alert.buttons[0].keyEquivalent="\r";alert.buttons[1].keyEquivalent="";return alert
 }
}
final class TerminalInteractionController {
 weak var pane:TerminalPane?
 var pasteboard:()->NSPasteboard = {NSPasteboard.general}
 var isCurrentTarget:(()->Bool)?,contextProvider:(()->TerminalPasteContext)?,onAction:((String)->Void)?,confirm:((TerminalPasteRequest)->Bool)?,onIssue:((String)->Void)?
 private(set) var copyPending=false
 private var epoch=UUID(),copyTicket=UUID(),pending:TerminalPasteRequest?,alert:NSAlert?
 var hasPendingPaste:Bool {pending != nil}
 init(pane:TerminalPane){self.pane=pane}
 static func js(_ text:String)->String {String(decoding:try! JSONEncoder().encode(text),as:UTF8.self)}
 var current:Bool {guard let pane=pane,!pane.stopped,pane.ready,!pane.rendererFailed,pane.window != nil,!pane.isHiddenOrHasHiddenAncestor else{return false};return isCurrentTarget?() ?? true}
 var context:TerminalPasteContext {if let provider=contextProvider{return provider()};guard let pane=pane else{return TerminalPasteContext()};return TerminalPasteContext(phase:WorkspaceConnectionStatus.terminal(pane).phase,recording:pane.isRecordingInput,source:pane.isInputSyncSource,target:pane.isInputSyncTarget)}
 func issue(_ text:String){onIssue?(text);pane?.web.evaluateJavaScript("window.terminalInteractionNotice?.("+Self.js(text)+")",completionHandler:nil)}
 func cancelPaste(){pending=nil;if let alert=alert{if NSApp.modalWindow === alert.window{NSApp.abortModal()};alert.window.orderOut(nil);self.alert=nil}}
 func invalidate(){epoch=UUID();copyTicket=UUID();copyPending=false;cancelPaste()}
 func update(){guard let pane=pane else{return};if !current{copyTicket=UUID();copyPending=false};if let request=pending,!valid(request){cancelPaste();if current && pane.acceptsInput{issue("终端或同步 / 录制状态已变化，未提交粘贴内容。")}};if !current || !pane.acceptsInput{cancelPaste()};guard pane.ready else{return};pane.web.evaluateJavaScript("window.updateTerminalActions?.({enabled:true,canPaste:"+(current && pane.acceptsInput ? "true" : "false")+"})",completionHandler:nil)}
 func action(_ name:String){guard current,let pane=pane else{return};switch name {
  case "copy":copySelection()
  case "paste":let board=pasteboard();if let value=board.string(forType:.string),!value.isEmpty{requestPaste(value)}else{issue("剪贴板中没有可粘贴的文本。")}
  case "search":pane.web.evaluateJavaScript("showSearch()",completionHandler:nil)
  case "clear":pane.web.evaluateJavaScript("terminal.clear();terminal.focus()",completionHandler:nil)
  case "export","reconnect":onAction?(name)
  default:break
 }}
 func copySelection(){guard current,let pane=pane else{return};let ticket=UUID(),generation=epoch,board=pasteboard(),revision=board.changeCount;copyTicket=ticket;copyPending=true
  pane.web.evaluateJavaScript("window.terminalSelectionSnapshot()") {[weak self] value,error in guard let self=self else{return};defer{if self.copyTicket==ticket{self.copyPending=false}};guard self.current,self.epoch==generation,self.copyTicket==ticket else{return};guard error==nil,let value=value as? [String:Any] else{self.issue("无法读取终端选区。");return};if let failure=value["error"] as? String{self.issue(failure);return};guard let text=value["text"] as? String,!text.isEmpty else{return};guard text.utf8.count<=TerminalPastePlan.maximumBytes else{self.issue("选区超过 1 MiB，请缩小选区或导出文本。");return};guard board.changeCount==revision else{self.issue("复制期间剪贴板已变化，请重新复制。");return};board.clearContents();guard board.setString(text,forType:.string) else{self.issue("无法写入剪贴板。");return}
  }
 }
 @discardableResult func requestPaste(_ text:String)->Bool {
  guard current,let pane=pane,pane.acceptsInput else{issue("当前终端未就绪，未粘贴。");return false};guard pending==nil else{issue("已有粘贴等待处理，请稍后重试。");return false}
  let plan:TerminalPastePlan;do{plan=try TerminalPastePlan(text)}catch{issue(error.localizedDescription);return false};let scope=context
  guard !(scope.source || scope.recording) || plan.bytes<=65536-12 else{issue("输入同步或录制期间，一次粘贴最多 65524 字节；请缩小内容或先停止同步 / 录制。");return false}
  let request=TerminalPasteRequest(epoch:epoch,pid:pane.pid,plan:plan,context:scope);pending=request
  // Defer the native modal until the browser's paste/contextmenu callback ends.
  DispatchQueue.main.async{[weak self] in self?.review(request)};return true
 }
 private func valid(_ request:TerminalPasteRequest)->Bool {guard let pane=pane else{return false};return pending?.id==request.id && current && pane.acceptsInput && pane.pid==request.pid && epoch==request.epoch && context==request.context}
 private func review(_ request:TerminalPasteRequest){guard valid(request) else{if pending?.id==request.id{cancelPaste()};return}
  if request.plan.needsConfirmation || request.context.source {
   let accepted:Bool;if let confirm=confirm {accepted=confirm(request)}else{let dialog=request.makeAlert();alert=dialog;accepted=dialog.runModal() == .alertSecondButtonReturn;alert=nil}
   guard accepted else{if pending?.id==request.id{cancelPaste()};return}
  }
  guard valid(request),let pane=pane else{if pending?.id==request.id{cancelPaste();issue("粘贴目标或同步 / 录制状态已变化，请重新粘贴。")};return}
  pane.web.evaluateJavaScript("window.prepareTerminalPaste("+Self.js(request.plan.text)+")") {[weak self] value,error in
   guard let self=self,self.valid(request),let pane=self.pane else{if self?.pending?.id==request.id{self?.cancelPaste();if self?.current==true{self?.issue("终端或同步 / 录制状态已变化，未提交粘贴内容。")}};return}
   self.pending=nil
   guard error==nil,let object=value as? [String:Any],let data=object["data"] as? String,request.plan.accepts(data),data.utf8.count<=TerminalPastePlan.maximumBytes+12,!data.contains("\0") else{self.issue("终端未能准备粘贴内容，没有提交输入。");return}
   let recordable=object["recordable"] as? Bool ?? false
   guard !(request.context.source || request.context.recording) || recordable else{self.issue("当前终端不支持可靠的粘贴录制 / 同步，请先停止该功能。");return}
   pane.receiveUserInput(data,recordable:recordable);pane.web.evaluateJavaScript("focusTerminal()",completionHandler:nil)
  }
 }
}
extension AppDelegate {
 @objc func selectAllFocused(_ sender:Any?){
  guard NSApp.keyWindow === window,let pane=activeTerminal,let responder=window?.firstResponder as? NSView,responder === pane.web || responder.isDescendant(of:pane.web) else{NSApp.sendAction(#selector(NSText.selectAll(_:)),to:nil,from:sender);return}
  pane.web.evaluateJavaScript("window.selectAllTerminalOrInput()",completionHandler:nil)
 }
 func terminalPasteLabel(_ pane:TerminalPane)->String {
  let item=tabs.tabViewItems.first{($0.view as? TerminalPane) === pane || ($0.view as? SSHWorkspace)?.terminal === pane},name=item?.label ?? "当前终端"
  if let workspace=item?.view as? SSHWorkspace{return name+" · "+workspace.session.connectionSummary}
  if let serial=pane.serialSettings{return name+" · "+serial.summary}
  if let destination=pane.telnetDestination{return name+" · "+destination}
  return name+" · 本地终端"
 }
 func configureTerminalInteraction(_ pane:TerminalPane){
  pane.interaction.isCurrentTarget = {[weak self,weak pane] in guard let self=self,let pane=pane else{return false};return self.activeTerminal === pane}
  pane.interaction.contextProvider = {[weak self,weak pane] in guard let self=self,let pane=pane else{return TerminalPasteContext()};let item=self.tabs.tabViewItems.first{($0.view as? TerminalPane) === pane || ($0.view as? SSHWorkspace)?.terminal === pane};var value=TerminalPasteContext(label:self.terminalPasteLabel(pane),phase:WorkspaceConnectionStatus.workspace(item?.view).phase,recording:pane.isRecordingInput,source:pane.isInputSyncSource,target:pane.isInputSyncTarget)
   if let recorder=self.macroWindow?.recorder,recorder.isRecording,recorder.targetID==pane.identity{value.recordingID=recorder.recordingIdentity}
   if let sync=self.inputSyncWindow?.runner,sync.isRunning,sync.sourceID==pane.identity{value.syncID=sync.runID;let targets=sync.receipts.filter{$0.reason==nil};value.targetIDs=targets.map{$0.id};value.targetNames=targets.map{receipt in self.allTerminals.first{$0.identity==receipt.id}.map{self.terminalPasteLabel($0)} ?? receipt.label}}
   return value
  }
  pane.interaction.onAction = {[weak self,weak pane] action in guard let self=self,let pane=pane,self.activeTerminal === pane else{return};if action=="export"{self.exportTerminal()}else if action=="reconnect"{self.reconnect()}}
 }
}
