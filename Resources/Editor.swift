import Cocoa

struct RemoteText {
 static let maximumBytes=4*1024*1024
 let original:Data
 let text:String
 let encoding:String.Encoding
 let bom:Data
 var encodingName:String {encoding == .utf8 ? "UTF-8" : encoding == .utf16LittleEndian ? "UTF-16 LE" : "UTF-16 BE"}
 init(data:Data)throws {
  guard data.count<=Self.maximumBytes else{throw SFTPError.message("文本文件不能超过 4 MB")}
  let encoding:String.Encoding;let bom:Data
  if data.starts(with:[0xef,0xbb,0xbf]) {encoding = .utf8;bom=Data([0xef,0xbb,0xbf])}
  else if data.starts(with:[0xff,0xfe]) {encoding = .utf16LittleEndian;bom=Data([0xff,0xfe])}
  else if data.starts(with:[0xfe,0xff]) {encoding = .utf16BigEndian;bom=Data([0xfe,0xff])}
  else {encoding = .utf8;bom=Data()}
  guard let text=String(data:data.dropFirst(bom.count),encoding:encoding),Self.validContent(text) else{throw SFTPError.message("文件不是支持的文本编码，或包含二进制内容。请下载后用专用编辑器打开。")}
  self.original=data;self.text=text;self.encoding=encoding;self.bom=bom
 }
 static func validContent(_ value:String)->Bool {!value.unicodeScalars.contains(where:{$0.value<32 && ![9,10,12,13].contains($0.value)})}
 func encode(_ value:String)throws->Data {guard Self.validContent(value),let bytes=value.data(using:encoding,allowLossyConversion:false),bytes.count+bom.count<=Self.maximumBytes else{throw SFTPError.message("文本无法编码、含二进制控制字符或超过 4 MB 限制")};return bom+bytes}
}

final class RemoteEditor:NSWindowController,NSWindowDelegate,NSTextViewDelegate,NSSearchFieldDelegate {
 let findBar=EditorFindBar(),findButton=AppActionButton(title:"查找 ⌘F",target:nil,action:nil),replaceFindButton=AppActionButton(title:"替换 ⌥⌘F",target:nil,action:nil),findNextButton=AppActionButton(title:"下一处 ⌘G",target:nil,action:nil),findPreviousButton=AppActionButton(title:"上一处 ⇧⌘G",target:nil,action:nil)
 let findQueue=DispatchQueue(label:"local.macterm.editor-search");var findGeneration=UUID(),findCancellation:EditorSearchCancellation?,findJob:DispatchWorkItem?,findHeight:NSLayoutConstraint!;var searchSnapshot:EditorSearchSnapshot?,searchIndex:Int?,searchBusy=false,selectingSearchMatch=false,editorClosed=false
 let textView=NSTextView();let status=NSTextField(labelWithString:"");let saveButton=AppActionButton(title:"保存到服务器 ⌘S",target:nil,action:nil)
 let path:String;let textModel:RemoteText;var expected:Data;var savedText:String;var saving=false;var confirmingSave=false;var confirmSave:(()->Bool)?;var onClose:(()->Void)?
 let saveAction:(Data,Data,@escaping(Result<Void,Error>)->Void)->Void
 var dirty:Bool {!textView.string.utf16.elementsEqual(savedText.utf16)}
 init(path:String,text:RemoteText,location:String?=nil,save:@escaping(Data,Data,@escaping(Result<Void,Error>)->Void)->Void){self.path=path;textModel=text;expected=text.original;savedText=text.text;saveAction=save
  let window=NSWindow(contentRect:NSRect(x:0,y:0,width:900,height:650),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
  super.init(window:window);window.delegate=self;window.appearance=NSAppearance(named:.darkAqua);window.backgroundColor=AppTheme.background;window.titlebarAppearsTransparent=true;window.title=(path as NSString).lastPathComponent+" — 远程编辑";window.minSize=NSSize(width:500,height:350);window.center()
  let root=NSStackView();root.orientation = .vertical;root.spacing=10;root.edgeInsets=NSEdgeInsets(top:16,left:16,bottom:14,right:16);root.translatesAutoresizingMaskIntoConstraints=false;window.contentView!.addSubview(root);NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor),root.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor),root.topAnchor.constraint(equalTo:window.contentView!.topAnchor),root.bottomAnchor.constraint(equalTo:window.contentView!.bottomAnchor)])
  AppTheme.surface(window.contentView!,AppTheme.background);for button in [findButton,replaceFindButton,findNextButton,findPreviousButton]{AppTheme.action(button)};AppTheme.action(saveButton,primary:true)
  let label=NSTextField(labelWithString:location ?? path);label.font = .monospacedSystemFont(ofSize:12,weight:.medium);label.textColor=AppTheme.muted;label.lineBreakMode = .byTruncatingMiddle;label.toolTip=location ?? path;root.addArrangedSubview(label);label.widthAnchor.constraint(equalTo:root.widthAnchor,constant:-20).isActive=true
  let tools=NSStackView(views:[findButton,replaceFindButton,NSView(),findPreviousButton,findNextButton]);tools.spacing=6;root.addArrangedSubview(tools);tools.widthAnchor.constraint(equalTo:root.widthAnchor,constant:-20).isActive=true
  root.addArrangedSubview(findBar);findBar.widthAnchor.constraint(equalTo:root.widthAnchor,constant:-20).isActive=true;findHeight=findBar.heightAnchor.constraint(equalToConstant:0);findHeight.isActive=true;findBar.isHidden=true
  let scroll=NSScrollView();scroll.backgroundColor=AppTheme.terminal;scroll.hasVerticalScroller=true;scroll.hasHorizontalScroller=true;scroll.borderType = .noBorder;scroll.scrollerStyle = .overlay;scroll.autohidesScrollers=true;AppTheme.surface(scroll,AppTheme.terminal,radius:10);scroll.layer?.borderWidth=1;scroll.layer?.borderColor=AppTheme.border.withAlphaComponent(0.6).cgColor;scroll.setContentHuggingPriority(.init(1),for:.vertical)
  textView.isRichText=false;textView.backgroundColor=AppTheme.terminal;textView.textColor=AppTheme.text;textView.insertionPointColor=AppTheme.accent;textView.textContainerInset=NSSize(width:12,height:12);textView.font = .monospacedSystemFont(ofSize:13,weight:.regular);textView.isAutomaticQuoteSubstitutionEnabled=false;textView.isAutomaticDashSubstitutionEnabled=false;textView.isAutomaticSpellingCorrectionEnabled=false;textView.allowsUndo=true;textView.isHorizontallyResizable=true;textView.isVerticallyResizable=true;textView.autoresizingMask=[.width];textView.textContainer?.widthTracksTextView=false;textView.textContainer?.containerSize=NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude);textView.string=text.text;textView.delegate=self;scroll.documentView=textView;root.addArrangedSubview(scroll);scroll.widthAnchor.constraint(equalTo:root.widthAnchor,constant:-20).isActive=true;scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:90).isActive=true
  let footer=NSStackView();status.font = .systemFont(ofSize:11);status.textColor=AppTheme.muted;status.setContentCompressionResistancePriority(.init(1),for:.horizontal);status.lineBreakMode = .byTruncatingTail;status.stringValue="\(textModel.encodingName) · 已加载";footer.addArrangedSubview(status);footer.addArrangedSubview(NSView());saveButton.target=self;saveButton.action = #selector(saveDocument);saveButton.keyEquivalent="s";saveButton.keyEquivalentModifierMask=[.command];footer.addArrangedSubview(saveButton);root.addArrangedSubview(footer);footer.widthAnchor.constraint(equalTo:root.widthAnchor,constant:-20).isActive=true;configureFindBar()
 }
 required init?(coder:NSCoder){fatalError()}
 func textDidChange(_ notification:Notification){sourceChanged();window?.isDocumentEdited=dirty;status.stringValue="\(textModel.encodingName) · "+(dirty ? "未保存" : "已保存")}
 @objc func saveDocument(){guard !editorClosed,!saving,!confirmingSave,dirty else{return};confirmingSave=true;let approved=confirmSave?() ?? true;confirmingSave=false;guard approved else{status.stringValue="保存已取消，修改仍保留";return};do {let current=textView.string;let data=try textModel.encode(current);saving=true;saveButton.isEnabled=false;status.stringValue="正在保存…";saveAction(data,expected){[weak self] result in guard let self=self else{return};self.saving=false;self.saveButton.isEnabled=true;switch result {case .success:self.expected=data;self.savedText=current;self.window?.isDocumentEdited=self.dirty;self.status.stringValue=self.dirty ? "已保存，仍有新修改未保存" : "已保存到服务器"
  case .failure(let error):self.status.stringValue="保存失败";let alert=NSAlert();alert.messageText="无法保存远程文件";alert.informativeText=error.localizedDescription;if let window=self.window {alert.beginSheetModal(for:window)}}}}
  catch{status.stringValue=error.localizedDescription}}
 func confirmDiscard()->Bool {if confirmingSave{return false};if saving {let alert=NSAlert();alert.messageText="文件正在保存，请等待完成后关闭。";alert.runModal();return false};guard dirty else{return true};let alert=NSAlert();alert.messageText="放弃 \((path as NSString).lastPathComponent) 的未保存修改？";alert.addButton(withTitle:"放弃修改");alert.addButton(withTitle:"继续编辑");return alert.runModal() == .alertFirstButtonReturn}
 func windowShouldClose(_ sender:NSWindow)->Bool {confirmDiscard()}
 func windowWillClose(_ notification:Notification){editorClosed=true;findGeneration=UUID();findCancellation?.cancel();findJob?.cancel();onClose?()}
}
