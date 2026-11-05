import Cocoa

enum RDPClipboardText {
 static let maximumBytes=1024*1024,maximumWire=2*maximumBytes+2
 static func validated(_ text:String)throws->String {
  guard !text.contains("\0"),text.utf8.count<=maximumBytes else{throw SFTPError.message("仅支持不含 NUL、最多 1 MiB 的文本。")}
  let normalized=text.replacingOccurrences(of:"\r\n",with:"\n").replacingOccurrences(of:"\r",with:"\n").replacingOccurrences(of:"\n",with:"\r\n")
  guard normalized.utf8.count<=maximumBytes else{throw SFTPError.message("转换 Windows 换行后超过 1 MiB。")};return normalized
 }
 static func encode(_ text:String)throws->String {let normalized=try validated(text);var data=normalized.data(using:.utf16LittleEndian)!;data.append(contentsOf:[0,0]);return data.base64EncodedString()
 }
 static func decode(_ encoded:String)throws->String {
  guard encoded.utf8.count<=4*((maximumWire+2)/3),let data=Data(base64Encoded:encoded),data.count>=2,data.count<=maximumWire,data.count%2==0 else{throw SFTPError.message("远程剪贴板格式无效或超过限制。")}
  let bytes=[UInt8](data);var offset=0,end:Int?
  while offset<bytes.count {let unit=UInt16(bytes[offset])|UInt16(bytes[offset+1])<<8
   if unit==0 {guard bytes[(offset+2)...].allSatisfy({$0==0}) else{throw SFTPError.message("远程剪贴板含嵌入 NUL。")};end=offset;break}
   if (0xD800...0xDBFF).contains(unit){guard offset+3<bytes.count else{throw SFTPError.message("远程 Unicode 文本不完整。")};let low=UInt16(bytes[offset+2])|UInt16(bytes[offset+3])<<8;guard (0xDC00...0xDFFF).contains(low) else{throw SFTPError.message("远程 Unicode 文本无效。")};offset+=2}
   else if (0xDC00...0xDFFF).contains(unit){throw SFTPError.message("远程 Unicode 文本无效。")};offset+=2
  }
  guard let end=end else{throw SFTPError.message("远程文本未终止。")}
  let units=stride(from:0,to:end,by:2).map{UInt16(bytes[$0])|UInt16(bytes[$0+1])<<8};let text=String(decoding:units,as:UTF16.self)
  guard text.utf8.count<=maximumBytes else{throw SFTPError.message("远程文本未终止或超过 1 MiB。")};return text
 }
}
final class RDPClipboardState {
 enum Operation {case read,offer}
 struct Request {let id:Int,operation:Operation,revision:Int;let completion:(Result<String,Error>)->Void}
 private(set) var supported=false,connected=false,viewOnly=false,ready=false,remoteText=false,readBlocked=false,offerBlocked=false,revision=0
 private(set) var snapshot:String?,issue:String?;private var sequence=0,pending:Request?,timer:Timer?;var send:(([String:Any])->Bool)?,onChange:(()->Void)?
 var busy:Bool {pending != nil}
 var canRead:Bool {supported && connected && ready && remoteText && !readBlocked && !busy}
 var canOffer:Bool {supported && connected && ready && !viewOnly && !offerBlocked && !busy}
 func configure(supported:Bool){self.supported=supported;onChange?()}
 func connection(_ connected:Bool,viewOnly:Bool){self.connected=connected;self.viewOnly=viewOnly;onChange?()}
 func read(completion:@escaping(Result<String,Error>)->Void){guard canRead else{completion(.failure(SFTPError.message("请先在远程应用复制文本；超时后需重连。")));return};begin(.read,extra:[:],completion:completion)}
 func offer(_ text:String,completion:@escaping(Result<String,Error>)->Void){guard canOffer else{completion(.failure(SFTPError.message("剪贴板通道尚不可用、正在处理或当前为只读。")));return};do{let data=try RDPClipboardText.encode(text);begin(.offer,extra:["data":data],completion:completion)}catch{completion(.failure(error))}}
 private func begin(_ operation:Operation,extra:[String:Any],completion:@escaping(Result<String,Error>)->Void){sequence=sequence==Int(Int32.max) ? 1 : sequence+1;let id=sequence;pending=Request(id:id,operation:operation,revision:revision,completion:completion);issue=nil;var object=extra;object["type"]=operation == .read ? "clipboardRead" : "clipboardOffer";object["id"]=id;onChange?()
  guard send?(object)==true else{finish(.failure(SFTPError.message("RDP 连接已不可用。")));return};timer=Timer.scheduledTimer(withTimeInterval:12,repeats:false){[weak self] _ in guard let self=self,self.pending?.id==id else{return};if operation == .read{self.readBlocked=true}else{self.offerBlocked=true};self.finish(.failure(SFTPError.message("剪贴板响应超时，请重连后重试。")))}
 }
 func receive(_ object:[String:Any])->Bool {
  guard let type=object["type"] as? String else{return false}
  if type=="clipboardState" {guard supported,let ready=object["ready"] as? Bool,let remote=object["remoteText"] as? Bool,let readBlocked=object["readBlocked"] as? Bool,let offerBlocked=object["offerBlocked"] as? Bool,let revision=object["revision"] as? Int,revision>=0 else{return false};if revision != self.revision || !ready || !remote{snapshot=nil};self.ready=ready;remoteText=remote;self.readBlocked=readBlocked;self.offerBlocked=offerBlocked;self.revision=revision;onChange?();return true}
  guard ["clipboardReadResult","clipboardOfferResult"].contains(type),let id=object["id"] as? Int,let ok=object["ok"] as? Bool else{return false}
  guard let request=pending,request.id==id,type==(request.operation == .read ? "clipboardReadResult" : "clipboardOfferResult") else{return true}
  if !ok{let raw=object["message"] as? String ?? "";let message=raw.localizedCaseInsensitiveContains("timed out") ? "剪贴板响应超时，请重连后重试。" : raw.localizedCaseInsensitiveContains("changed") ? "远程剪贴板已变化，请重新读取或发送。" : raw.localizedCaseInsensitiveContains("1 MiB") ? "远程文本无效或超过 1 MiB，未保留预览。" : "远程剪贴板操作未成功，请确认已复制 Unicode 文本及服务器策略。";finish(.failure(SFTPError.message(message)));return true}
  if request.operation == .read {do{guard request.revision==revision,ready,connected,remoteText,let encoded=object["data"] as? String else{throw SFTPError.message("远程剪贴板已变化，请重新读取。")};let text=try RDPClipboardText.decode(encoded);snapshot=text;finish(.success(text))}catch{finish(.failure(error))}}
  else{finish(.success(""))};return true
 }
 private func finish(_ result:Result<String,Error>){guard let request=pending else{return};pending=nil;timer?.invalidate();timer=nil;if case .failure(let error)=result{issue=error.localizedDescription;if request.operation == .read{snapshot=nil}};onChange?();request.completion(result)}
 func stop(){connected=false;ready=false;remoteText=false;snapshot=nil;if pending != nil{finish(.failure(SFTPError.message("RDP 连接已关闭。")))};timer?.invalidate();timer=nil;send=nil;onChange?()}
}

final class RDPClipboardController:NSWindowController,NSWindowDelegate,NSTextViewDelegate {
 weak var workspace:RDPWorkspace?;let pasteboard:NSPasteboard;let remote=NSTextView(),draft=NSTextView(),note=NSTextField(wrappingLabelWithString:""),sendNote=NSTextField(wrappingLabelWithString:"尚未发送。")
 let readButton=AppActionButton(title:"读取远程文本",target:nil,action:nil),copyButton=AppActionButton(title:"复制预览到本机",target:nil,action:nil),loadButton=AppActionButton(title:"读取本机剪贴板",target:nil,action:nil),sendButton=AppActionButton(title:"发送预览到远程",target:nil,action:nil);private var closed=false
 init(workspace:RDPWorkspace,pasteboard:NSPasteboard = .general){self.workspace=workspace;self.pasteboard=pasteboard;let panel=NSPanel(contentRect:NSRect(x:0,y:0,width:700,height:690),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false);super.init(window:panel);panel.title="RDP 剪贴板 · "+workspace.session.name;panel.appearance=NSAppearance(named:.darkAqua);panel.backgroundColor=AppTheme.background;panel.titlebarAppearsTransparent=true;panel.minSize=NSSize(width:600,height:560);panel.delegate=self;panel.center()
  let root=NSStackView();root.orientation = .vertical;root.alignment = .leading;root.spacing=10;root.edgeInsets=NSEdgeInsets(top:20,left:22,bottom:20,right:22);root.translatesAutoresizingMaskIntoConstraints=false;AppTheme.surface(root,AppTheme.background);panel.contentView!.addSubview(root);NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:panel.contentView!.leadingAnchor),root.trailingAnchor.constraint(equalTo:panel.contentView!.trailingAnchor),root.topAnchor.constraint(equalTo:panel.contentView!.topAnchor),root.bottomAnchor.constraint(equalTo:panel.contentView!.bottomAnchor)])
  let title=NSTextField(labelWithString:"双向文本剪贴板");title.font = .systemFont(ofSize:22,weight:.semibold);root.addArrangedSubview(title)
  let hint=NSTextField(wrappingLabelWithString:workspace.session.rdpDestination+"\n点击按钮才读取或改写本机剪贴板；最大 1 MiB，不传文件或图片。发送后仍需在远程应用粘贴；发送换行采用 Windows CRLF。");hint.font = .systemFont(ofSize:12);hint.textColor=AppTheme.muted;root.addArrangedSubview(hint);hint.widthAnchor.constraint(equalTo:root.widthAnchor,constant:-44).isActive=true
  func editor(_ text:NSTextView,editable:Bool){text.isRichText=false;text.isEditable=editable;text.isSelectable=true;text.font = .monospacedSystemFont(ofSize:12,weight:.regular);text.backgroundColor=AppTheme.input;text.textColor=AppTheme.text;text.insertionPointColor=AppTheme.accent;text.textContainerInset=NSSize(width:10,height:10);text.isAutomaticQuoteSubstitutionEnabled=false;text.isAutomaticDashSubstitutionEnabled=false;text.isAutomaticTextReplacementEnabled=false;text.isAutomaticSpellingCorrectionEnabled=false;text.isContinuousSpellCheckingEnabled=false;text.isHorizontallyResizable=false;text.isVerticallyResizable=true;text.autoresizingMask=[.width];text.textContainer?.widthTracksTextView=true;let scroll=NSScrollView();scroll.hasVerticalScroller=true;scroll.scrollerStyle = .overlay;scroll.borderType = .noBorder;scroll.documentView=text;AppTheme.surface(scroll,AppTheme.input,radius:8);root.addArrangedSubview(scroll);scroll.widthAnchor.constraint(equalTo:root.widthAnchor,constant:-44).isActive=true;scroll.heightAnchor.constraint(greaterThanOrEqualToConstant:80).isActive=true;scroll.setContentHuggingPriority(.init(1),for:.vertical)}
  editor(remote,editable:false);let readActions=NSStackView(views:[readButton,copyButton]);root.addArrangedSubview(readActions);root.addArrangedSubview(note);note.widthAnchor.constraint(equalTo:root.widthAnchor,constant:-44).isActive=true;editor(draft,editable:true);draft.delegate=self;let sendActions=NSStackView(views:[loadButton,sendButton]);root.addArrangedSubview(sendActions);root.addArrangedSubview(sendNote);sendNote.widthAnchor.constraint(equalTo:root.widthAnchor,constant:-44).isActive=true
  for label in [note,sendNote]{label.font = .systemFont(ofSize:11);label.textColor=AppTheme.muted}
  for (button,action) in [(readButton,#selector(readRemote)),(copyButton,#selector(copyRemote)),(loadButton,#selector(loadLocal)),(sendButton,#selector(sendDraft))]{AppTheme.action(button,primary:button === sendButton);button.target=self;button.action=action;button.widthAnchor.constraint(greaterThanOrEqualToConstant:(button.title as NSString).size(withAttributes:[.font:button.font!]).width+20).isActive=true}
  workspace.clipboard.onChange = {[weak self] in self?.refresh()};refresh()
 }
 required init?(coder:NSCoder){fatalError()}
 func refresh(){guard !closed else{return};let state=workspace?.clipboard;remote.string=state?.snapshot ?? "";note.stringValue=state?.issue ?? (state?.snapshot != nil ? "已读取，尚未改写本机剪贴板。" : state?.ready==true ? "先在远程应用复制 Unicode 文本，再点「读取远程文本」。" : "服务器剪贴板通道尚未就绪或未启用。")
  readButton.isEnabled=state?.canRead==true;copyButton.isEnabled=state?.connected==true && state?.snapshot != nil;loadButton.isEnabled=state?.canOffer==true;sendButton.isEnabled=state?.canOffer==true && (try? RDPClipboardText.validated(draft.string)) != nil
 }
 @objc func readRemote(){workspace?.clipboard.read{[weak self] _ in self?.refresh()}}
 @objc func copyRemote(){guard !closed,let state=workspace?.clipboard,state.connected,let text=state.snapshot else{return};pasteboard.clearContents();if pasteboard.setString(text,forType:.string){note.stringValue="已复制此预览到本机。"}else{note.stringValue="无法写入本机剪贴板。"}}
 @objc func loadLocal(){guard !closed,workspace?.clipboard.canOffer==true else{return};guard let text=pasteboard.string(forType:.string),(try? RDPClipboardText.validated(text)) != nil else{sendNote.stringValue="本机剪贴板没有支持的文本，或超过限制。";return};draft.string=text;sendNote.stringValue="已读取到预览，尚未发送。";refresh()}
 @objc func sendDraft(){guard !closed else{return};sendNote.stringValue="正在提供给远程剪贴板…";workspace?.clipboard.offer(draft.string){[weak self] result in guard let self=self,!self.closed else{return};switch result{case .success:self.sendNote.stringValue="远程已接受文本格式，请在远程应用中粘贴。";case .failure(let error):self.sendNote.stringValue=error.localizedDescription};self.refresh()}}
 func textDidChange(_ notification:Notification){sendNote.stringValue="预览已修改，尚未发送。";refresh()}
 func disconnect(){close();clear()}
 private func clear(){guard !closed else{return};closed=true;workspace?.clipboard.onChange=nil;workspace?.clipboardWindow=nil;workspace=nil;remote.string="";draft.string="";note.stringValue="";sendNote.stringValue="";for button in [readButton,copyButton,loadButton,sendButton]{button.isEnabled=false}}
 func windowWillClose(_ notification:Notification){clear()}
}
