import Cocoa

struct VNCClipboardSnapshot:Equatable {let revision:UInt64;let text:String}
final class VNCClipboardState {
 static let maximumBytes=1024*1024
 private(set) var snapshot:VNCClipboardSnapshot?;private(set) var issue:String?;private var revision:UInt64=0
 var onChange:(()->Void)?
 static func validated(_ text:String)throws->String {guard text.utf8.count<=maximumBytes,!text.contains("\0") else{throw SFTPError.message("剪贴板仅支持不超过 1 MiB 且不含 NUL 的文本。")};return text}
 func receive(_ text:String){do{_ = try Self.validated(text);revision &+= 1;snapshot=VNCClipboardSnapshot(revision:revision,text:text);issue=nil;onChange?()}catch{reject()}}
 func reject(){revision &+= 1;snapshot=nil;issue="收到的文本超出限制或含 NUL，未保留之前的预览。";onChange?()}
 func clear(){snapshot=nil;issue=nil;revision &+= 1;onChange?()}
}

// An explicit preview panel. Creating it never reads or writes the pasteboard.
// A displayed remote snapshot remains fixed until Refresh is clicked.
final class VNCClipboardController:NSWindowController,NSWindowDelegate,NSTextViewDelegate {
 weak var workspace:VNCWorkspace?;let pasteboard:NSPasteboard
 let remote=NSTextView(),draft=NSTextView(),remoteStatus=NSTextField(wrappingLabelWithString:""),sendStatus=NSTextField(wrappingLabelWithString:"")
 let refreshButton=AppActionButton(title:"刷新远程预览",target:nil,action:nil),copyButton=AppActionButton(title:"复制预览到本机",target:nil,action:nil),loadButton=AppActionButton(title:"读取本机剪贴板",target:nil,action:nil),sendButton=AppActionButton(title:"发送预览到远程",target:nil,action:nil)
 private(set) var displayed:VNCClipboardSnapshot?;private(set) var busy=false;private var closed=false;private var request=UUID()
 init(workspace:VNCWorkspace,pasteboard:NSPasteboard = .general){self.workspace=workspace;self.pasteboard=pasteboard;let panel=NSPanel(contentRect:NSRect(x:0,y:0,width:680,height:700),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false);super.init(window:panel);panel.title="VNC 剪贴板 · "+workspace.session.name;panel.appearance=NSAppearance(named:.darkAqua);panel.backgroundColor=AppTheme.background;panel.titlebarAppearsTransparent=true;panel.minSize=NSSize(width:600,height:650);panel.delegate=self;panel.center()
  let root=NSStackView();AppTheme.surface(root,AppTheme.background);root.orientation = .vertical;root.alignment = .leading;root.spacing=10;root.edgeInsets=NSEdgeInsets(top:22,left:24,bottom:22,right:24);root.translatesAutoresizingMaskIntoConstraints=false;panel.contentView!.addSubview(root);NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:panel.contentView!.leadingAnchor),root.trailingAnchor.constraint(equalTo:panel.contentView!.trailingAnchor),root.topAnchor.constraint(equalTo:panel.contentView!.topAnchor),root.bottomAnchor.constraint(equalTo:panel.contentView!.bottomAnchor)])
  let heading=NSTextField(labelWithString:"双向文本剪贴板");heading.font = .systemFont(ofSize:22,weight:.semibold);root.addArrangedSubview(heading)
  let hint=NSTextField(wrappingLabelWithString:workspace.session.vncDestination+"\n不自动读取或改写本机剪贴板。中文 / 表情发送需服务器支持 UTF-8 扩展。最大 1 MiB，不传文件或图片。发送文本后仍需在远程应用中粘贴。");hint.maximumNumberOfLines=3;hint.toolTip=workspace.session.vncDestination;hint.font = .systemFont(ofSize:12);hint.textColor=AppTheme.muted;root.addArrangedSubview(hint);hint.widthAnchor.constraint(equalTo:root.widthAnchor,constant:-48).isActive=true
  func label(_ text:String){let label=NSTextField(labelWithString:text);label.font = .systemFont(ofSize:12,weight:.semibold);label.textColor=AppTheme.accent;root.addArrangedSubview(label)}
  func editor(_ text:NSTextView,editable:Bool)->NSScrollView {text.isRichText=false;text.isEditable=editable;text.isSelectable=true;text.font = .monospacedSystemFont(ofSize:12,weight:.regular);text.textColor=AppTheme.text;text.backgroundColor=AppTheme.input;text.insertionPointColor=AppTheme.accent;text.textContainerInset=NSSize(width:10,height:10);text.isAutomaticQuoteSubstitutionEnabled=false;text.isAutomaticDashSubstitutionEnabled=false;text.isAutomaticTextReplacementEnabled=false;text.isAutomaticSpellingCorrectionEnabled=false;text.isContinuousSpellCheckingEnabled=false;text.isAutomaticLinkDetectionEnabled=false;text.isGrammarCheckingEnabled=false;text.isHorizontallyResizable=false;text.isVerticallyResizable=true;text.autoresizingMask=[.width];text.textContainer?.widthTracksTextView=true;let scroll=NSScrollView();scroll.borderType = .noBorder;scroll.hasVerticalScroller=true;scroll.scrollerStyle = .overlay;scroll.drawsBackground=true;scroll.backgroundColor=AppTheme.input;scroll.documentView=text;AppTheme.surface(scroll,AppTheme.input,radius:8);scroll.layer?.borderColor=AppTheme.border.cgColor;scroll.layer?.borderWidth=1;root.addArrangedSubview(scroll);scroll.widthAnchor.constraint(equalTo:root.widthAnchor,constant:-48).isActive=true;scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:80).isActive=true;scroll.setContentHuggingPriority(.init(1),for:.vertical);text.setAccessibilityLabel(editable ? "发送到远程的文本预览" : "远程剪贴板文本预览");return scroll}
  label("远程 → 本机");let remoteScroll=editor(remote,editable:false)
  for field in [remoteStatus,sendStatus]{field.font = .systemFont(ofSize:11);field.textColor=AppTheme.muted;field.lineBreakMode = .byWordWrapping;field.maximumNumberOfLines=2;field.heightAnchor.constraint(equalToConstant:28).isActive=true}
  root.addArrangedSubview(remoteStatus);remoteStatus.widthAnchor.constraint(equalTo:root.widthAnchor,constant:-48).isActive=true
  let remoteActions=NSStackView(views:[refreshButton,copyButton]);remoteActions.spacing=10;root.addArrangedSubview(remoteActions)
  label("本机 → 远程");let draftScroll=editor(draft,editable:true);draft.delegate=self;draftScroll.heightAnchor.constraint(equalTo:remoteScroll.heightAnchor).isActive=true
  root.addArrangedSubview(sendStatus);sendStatus.widthAnchor.constraint(equalTo:root.widthAnchor,constant:-48).isActive=true;sendStatus.heightAnchor.constraint(greaterThanOrEqualToConstant:28).isActive=true
  let actions=NSStackView(views:[loadButton,sendButton]);actions.spacing=10;root.addArrangedSubview(actions)
  for (button,selector) in [(refreshButton,#selector(refreshRemote)),(copyButton,#selector(copyRemote)),(loadButton,#selector(loadLocal)),(sendButton,#selector(sendDraft))] {button.target=self;button.action=selector;button.isBordered=false;button.restingColor=button === sendButton ? AppTheme.accent : AppTheme.surface;button.contentTintColor=button === sendButton ? AppTheme.background : AppTheme.text;button.font = .systemFont(ofSize:12,weight:.medium);button.widthAnchor.constraint(equalToConstant:148).isActive=true;button.heightAnchor.constraint(equalToConstant:30).isActive=true}
  sendButton.toolTip="只传送当前预览文本，不自动粘贴；空文本会清空远程剪贴板。";copyButton.toolTip="复制当前显示的远程预览，覆盖本机剪贴板文本。"
  workspace.clipboard.onChange={[weak self] in self?.receivedUpdate()};sendStatus.stringValue="输入文本，或按「读取本机剪贴板」载入后预览。";refreshRemote();updateControls()
 }
 required init?(coder:NSCoder){fatalError()}
 var available:Bool {workspace?.state == .connected && workspace?.stopped == false && workspace?.session.vnc?.viewOnly != true && !closed}
 private func updateControls(){let active=available;refreshButton.isEnabled=active;copyButton.isEnabled=active && displayed != nil;loadButton.isEnabled=active && !busy;sendButton.isEnabled=active && !busy && (try? VNCClipboardState.validated(draft.string)) != nil;draft.isEditable=active}
 private func receivedUpdate(){guard !closed else{return};guard let state=workspace?.clipboard else{return};if let issue=state.issue {displayed=nil;remote.string="";remoteStatus.stringValue=issue}else if state.snapshot?.revision != displayed?.revision {remoteStatus.stringValue="有新的远程文本，点击「刷新远程预览」查看。"};updateControls()}
 @objc func refreshRemote(){guard !closed else{return};displayed=workspace?.clipboard.snapshot;remote.string=displayed?.text ?? "";remoteStatus.stringValue=workspace?.clipboard.issue ?? (displayed == nil ? "尚未收到文本；请先在远程桌面复制内容。" : "当前预览：\(displayed!.text.utf8.count) 字节。主动复制后才会写入本机。");updateControls()}
 @objc func copyRemote(){guard available,let snapshot=displayed else{return};pasteboard.clearContents();if pasteboard.setString(snapshot.text,forType:.string){remoteStatus.stringValue=workspace?.clipboard.snapshot?.revision != snapshot.revision ? "已复制当前预览；远程有更新，可点击刷新。" : "已将当前预览复制到本机。"}else{remoteStatus.stringValue="写入本机剪贴板失败。"}}
 @objc func loadLocal(){guard available,!busy else{return};guard let text=pasteboard.string(forType:.string) else{sendStatus.stringValue="本机剪贴板没有可读取的文本。";return};do{draft.string=try VNCClipboardState.validated(text);sendStatus.stringValue="已载入 \(text.utf8.count) 字节，请核对后点击发送。"}catch{sendStatus.stringValue=error.localizedDescription};updateControls()}
 @objc func sendDraft(){guard available,!busy,let workspace=workspace else{return};let text:String;do{text=try VNCClipboardState.validated(draft.string)}catch{sendStatus.stringValue=error.localizedDescription;return};let ticket=UUID();request=ticket;busy=true;sendStatus.stringValue="正在提交此次文本快照…";updateControls();workspace.sendClipboard(text){[weak self] result in guard let self=self,!self.closed,self.request==ticket else{return};self.busy=false;switch result{case .success(let message):self.sendStatus.stringValue=message;case .failure(let error):self.sendStatus.stringValue=error.localizedDescription};self.updateControls()}}
 func textDidChange(_ notification:Notification){if !busy{sendStatus.stringValue=(try? VNCClipboardState.validated(draft.string)) != nil ? "预览已修改；尚未发送。" : "文本超过 1 MiB 或包含 NUL，不能发送。"};updateControls()}
 private func clear(){guard !closed else{return};closed=true;request=UUID();workspace?.clipboard.onChange=nil;workspace=nil;displayed=nil;remote.string="";draft.string="";remoteStatus.stringValue="";sendStatus.stringValue="";busy=false;updateControls()}
 func disconnect(){clear();close()}
 func windowWillClose(_ notification:Notification){clear()}
}
