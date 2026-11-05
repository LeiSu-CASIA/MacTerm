import Cocoa
import Darwin

struct TerminalMacro:Codable,Equatable {
 var id=UUID();var name:String;var body:String;var intervalMilliseconds=500;var sendReturn=true;var events:[RecordedInput]?=nil
 static func ==(a:TerminalMacro,b:TerminalMacro)->Bool {a.id==b.id && Data(a.name.utf8)==Data(b.name.utf8) && Data(a.body.utf8)==Data(b.body.utf8) && a.intervalMilliseconds==b.intervalMilliseconds && a.sendReturn==b.sendReturn && a.events==b.events}
 func validated()throws->TerminalMacro {
  guard !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,name.count<=128,!name.unicodeScalars.contains(where:{$0.value<32 || $0.value==127}) else{throw SFTPError.message("宏名称需为 1–128 个字符")}
  if let events=events {
   guard body.isEmpty,intervalMilliseconds==0,!sendReturn,!events.isEmpty,events.count<=MacroRecorder.maximumEvents else{throw SFTPError.message("录制宏需要 1–10000 个事件，使用事件中的间隔与回车")}
   var bytes=0,milliseconds=0;for event in events {guard !event.input.isEmpty,event.input.utf8.count<=MacroRecorder.maximumBytes-bytes,(0...MacroRecorder.maximumMilliseconds).contains(event.delayMilliseconds),event.delayMilliseconds<=MacroRecorder.maximumMilliseconds-milliseconds else{throw SFTPError.message("录制输入总计最多 64 KB / 10 分钟，间隔不能为负数")};bytes+=event.input.utf8.count;milliseconds+=event.delayMilliseconds};return self
  }
  guard body.utf8.count<=65536,!body.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,!body.unicodeScalars.contains(where:{$0.value<32 && $0.value != 10 && $0.value != 13 && $0.value != 9 || $0.value==127}) else{throw SFTPError.message("宏需包含命令，最多 64 KB，不能包含终端控制字符")}
  guard (0...60000).contains(intervalMilliseconds) else{throw SFTPError.message("发送间隔需为 0–60000 毫秒")}
  guard lines.count<=500,sendReturn || lines.count==1 else{throw SFTPError.message("宏最多 500 行；不发送回车时只支持单行")}
  return self
 }
 var lines:[String] {var value=body.replacingOccurrences(of:"\r\n",with:"\n").replacingOccurrences(of:"\r",with:"\n");if value.hasSuffix("\n"){value.removeLast()};return value.components(separatedBy:"\n")}
 var steps:[String] {events?.map{$0.input} ?? lines.map{$0+(sendReturn ? "\r" : "")}}
 var delays:[Int] {events?.map{$0.delayMilliseconds} ?? lines.indices.map{$0==0 ? 0 : intervalMilliseconds}}
}
struct MacroArchive:Codable {let format:String;let version:Int;let macros:[TerminalMacro]}
private struct MacroContentKey:Hashable {
 let name:Data,body:Data;let interval:Int;let sendReturn:Bool;let events:[RecordedInput]?
 init(_ macro:TerminalMacro){name=Data(macro.name.utf8);body=Data(macro.body.utf8);interval=macro.intervalMilliseconds;sendReturn=macro.sendReturn;events=macro.events}
}
struct MacroMerge {let macros:[TerminalMacro];let added:Int,skipped:Int,remapped:Int}
struct MacroStore {
 let url:URL
 static let maximumBytes=2*1024*1024
 static func decode(_ data:Data)throws->[TerminalMacro] {
  guard data.count<=maximumBytes else{throw SFTPError.message("宏文件超过 2 MB")}
  let archive=try JSONDecoder().decode(MacroArchive.self,from:data)
  guard archive.format=="MacTerm Macros",(1...2).contains(archive.version),archive.macros.count<=500 else{throw SFTPError.message("不支持的宏文件格式、版本或数量")}
  var ids=Set<UUID>();return try archive.macros.map{macro in guard archive.version>=2 || macro.events==nil else{throw SFTPError.message("录制事件需要版本 2 的宏文件")};guard ids.insert(macro.id).inserted else{throw SFTPError.message("宏文件包含重复 ID")};return try macro.validated()}
 }
 static func exported(_ macros:[TerminalMacro])throws->Data {
  let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys];let data=try encoder.encode(MacroArchive(format:"MacTerm Macros",version:macros.contains(where:{$0.events != nil}) ? 2 : 1,macros:macros));_ = try decode(data);return data
 }
 static func imported(from url:URL)throws->[TerminalMacro] {let revision=try MacroStore(url:url).revision();guard case .contents(let data)=revision else{throw SFTPError.message("所选宏文件已不存在")};return try decode(data)}
 static func merge(_ incoming:[TerminalMacro],into existing:[TerminalMacro])throws->MacroMerge {
  _ = try exported(existing);_ = try exported(incoming);var result=existing,keys=Set(existing.map{MacroContentKey($0)}),ids=Set(existing.map{$0.id});var skipped=0,remapped=0
  for var macro in incoming {
   let key=MacroContentKey(macro);if keys.contains(key){skipped+=1;continue}
   if ids.contains(macro.id){repeat{macro.id=UUID()}while ids.contains(macro.id);remapped+=1}
   result.append(macro);ids.insert(macro.id);keys.insert(key)
  }
  _ = try exported(result);return MacroMerge(macros:result,added:result.count-existing.count,skipped:skipped,remapped:remapped)
 }
 static func duplicate(_ macro:TerminalMacro,among existing:[TerminalMacro])throws->TerminalMacro {
  var copy=try macro.validated();let ids=Set(existing.map{$0.id});repeat{copy.id=UUID()}while ids.contains(copy.id);let names=Set(existing.map{Data($0.name.utf8)});var index=1
  while true {let suffix=index==1 ? " 副本" : " 副本 \(index)";let name=String(macro.name.prefix(128-suffix.count))+suffix;if !names.contains(Data(name.utf8)){copy.name=name;return copy};index+=1}
 }
 static func export(_ macros:[TerminalMacro],to destination:URL)throws {
  try writePrivate(exported(macros),to:destination)
 }
 private static func writePrivate(_ data:Data,to destination:URL)throws {
  let temporary=destination.deletingLastPathComponent().appendingPathComponent(".macterm-macros-write-"+UUID().uuidString)
  let descriptor=Darwin.open(temporary.path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600);guard descriptor>=0 else{throw SFTPError.message("无法创建宏文件："+String(cString:strerror(errno)))}
  defer{Darwin.close(descriptor);try? FileManager.default.removeItem(at:temporary)}
  try data.withUnsafeBytes{(bytes:UnsafeRawBufferPointer) in var offset=0;while offset<bytes.count {let count=Darwin.write(descriptor,bytes.baseAddress!.advanced(by:offset),bytes.count-offset);if count<0 && errno==EINTR{continue};guard count>0 else{throw SFTPError.message("宏文件写入失败："+String(cString:strerror(errno)))};offset+=count}}
  guard fchmod(descriptor,0o600)==0,fsync(descriptor)==0 else{throw SFTPError.message("宏文件同步失败")}
  guard Darwin.rename(temporary.path,destination.path)==0 else{throw SFTPError.message("宏文件发布失败："+String(cString:strerror(errno)))}
 }
 func revision()throws->SessionDiskRevision {
  let descriptor=Darwin.open(url.path,O_RDONLY|O_NONBLOCK|O_NOFOLLOW|O_CLOEXEC)
  guard descriptor>=0 else{if errno==ENOENT{return .missing};throw SFTPError.message("无法读取宏文件（不接受符号链接）："+String(cString:strerror(errno)))}
  defer{Darwin.close(descriptor)};var info=stat();guard fstat(descriptor,&info)==0,UInt32(info.st_mode)&UInt32(S_IFMT)==UInt32(S_IFREG),info.st_size>=0,info.st_size<=Self.maximumBytes else{throw SFTPError.message("宏文件类型无效或超过 2 MB")}
  var data=Data(),buffer=[UInt8](repeating:0,count:16384)
  while true {let count=Darwin.read(descriptor,&buffer,buffer.count);if count<0 && errno==EINTR {continue};guard count>=0 else{throw SFTPError.message("宏文件读取失败")};if count==0 {break};guard count<=Self.maximumBytes-data.count else{throw SFTPError.message("宏文件超过 2 MB")};data.append(contentsOf:buffer.prefix(count))}
  return .contents(data)
 }
 func load()throws->(macros:[TerminalMacro],revision:SessionDiskRevision){let snapshot=try revision();if case .contents(let data)=snapshot{return(try Self.decode(data),snapshot)};return([],snapshot)}
 func save(_ macros:[TerminalMacro],expected:SessionDiskRevision)throws->SessionDiskRevision {
  let data=try Self.exported(macros)
  try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
  let lockFile=url.appendingPathExtension("lock");let descriptor=Darwin.open(lockFile.path,O_CREAT|O_RDWR|O_NOFOLLOW|O_CLOEXEC,0o600);guard descriptor>=0 else{throw SFTPError.message("无法打开宏文件锁")};defer{Darwin.close(descriptor)}
  guard flock(descriptor,LOCK_EX|LOCK_NB)==0 else{throw SFTPError.message("其他实例正在保存宏，请稍后重新载入")};defer{flock(descriptor,LOCK_UN)}
  let current=try revision();guard current==expected else{throw SFTPError.message("宏文件已被其他实例修改，请保留当前草稿并重新载入后合并")}
  if case .contents(let old)=current {_ = try Self.decode(old);let backup=url.appendingPathExtension("backup");try Self.writePrivate(old,to:backup)}
  try Self.writePrivate(data,to:url);return .contents(data)
 }
}

enum MacroPlaybackState:Equatable {case idle,running(Int,Int),sent,cancelled,failed(String)}
final class MacroPlayback {
 private(set) var state:MacroPlaybackState = .idle
 var changed:(()->Void)?
 private var token=UUID(),pending:DispatchWorkItem?,send:((String)->Bool)?,steps=[String](),index=0,delays=[Int]()
 var isRunning:Bool {if case .running=state{return true};return false}
 func start(_ macro:TerminalMacro,send:@escaping(String)->Bool)throws {
  guard !isRunning else{throw SFTPError.message("已有宏正在回放，请先取消")};_ = try macro.validated()
  token=UUID();self.send=send;steps=macro.steps;index=0;delays=macro.delays;state = .running(0,steps.count);let generation=token;changed?();if generation==token,isRunning {schedule(after:delays[0],token:generation)}
 }
 private func schedule(after milliseconds:Int,token:UUID){let work=DispatchWorkItem{[weak self] in self?.tick(token)};pending=work;DispatchQueue.main.asyncAfter(deadline:.now() + .milliseconds(milliseconds),execute:work)}
 private func tick(_ generation:UUID){guard generation==token,isRunning else{return};let accepted=send?(steps[index]) == true;guard generation==token,isRunning else{return};guard accepted else{fail("目标终端已结束，后续命令未发送");return};index+=1
  if index==steps.count {pending=nil;send=nil;steps=[];delays=[];state = .sent;changed?()}
  else {state = .running(index,steps.count);changed?();if generation==token,isRunning {schedule(after:delays[index],token:generation)}}
 }
 func cancel(){guard isRunning else{return};finish(.cancelled)}
 func fail(_ reason:String){guard isRunning else{return};finish(.failed(reason))}
 private func finish(_ result:MacroPlaybackState){token=UUID();pending?.cancel();pending=nil;send=nil;steps=[];delays=[];state=result;changed?()}
 deinit{pending?.cancel()}
}

final class MacroWindow:NSWindowController,NSWindowDelegate,NSTableViewDataSource,NSTableViewDelegate,NSTextViewDelegate,NSTextFieldDelegate {
 weak var workspaceOwner:AppDelegate?
 let recorder=MacroRecorder();var recordingTimer:Timer?;var recordingShowsResult=true;private var recordedDraft=false;let recordButton=NSButton(title:"录制当前标签",target:nil,action:nil),formatLabel=NSTextField(labelWithString:"命令宏 · 每行一步")
 let store:MacroStore;let playback=MacroPlayback();let table=NSTableView();let nameField=NSTextField();let commands=NSTextView();let interval=NSTextField(string:"500");let sendReturn=NSButton(checkboxWithTitle:"每行发送回车（执行命令）",target:nil,action:nil)
 let targetLabel=NSTextField(labelWithString:"目标：未选择");let status=NSTextField(wrappingLabelWithString:"")
 let saveButton=NSButton(title:"保存宏",target:nil,action:nil),runButton=NSButton(title:"回放到目标终端",target:nil,action:nil),cancelButton=NSButton(title:"取消回放",target:nil,action:nil),newButton=NSButton(title:"新建",target:nil,action:nil),deleteButton=NSButton(title:"删除",target:nil,action:nil),reloadButton=NSButton(title:"重新载入",target:nil,action:nil),targetButton=NSButton(title:"使用当前标签",target:nil,action:nil)
 let importButton=NSButton(title:"导入…",target:nil,action:nil),exportButton=NSButton(title:"导出全部…",target:nil,action:nil),duplicateButton=NSButton(title:"复制",target:nil,action:nil)
 private(set) var macros=[TerminalMacro]();private var revision:SessionDiskRevision = .missing;private var storeLocked=false,suppressSelection=false,loading=false,dirty=false
 private var original:TerminalMacro?;private var draftID=UUID();private weak var target:TerminalPane?;private var ready:(()->Bool)?;private var targetName="未选择"
 init(store:MacroStore){self.store=store;let window=NSWindow(contentRect:NSRect(x:0,y:0,width:850,height:620),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false);window.title="MacTerm · 命令宏";window.minSize=NSSize(width:760,height:560);window.appearance=NSAppearance(named:.darkAqua);window.backgroundColor=AppTheme.background;window.isReleasedWhenClosed=false;super.init(window:window);window.delegate=self;window.center()
  let root=NSStackView();root.orientation = .vertical;root.alignment = .leading;root.spacing=10;root.edgeInsets=NSEdgeInsets(top:18,left:18,bottom:18,right:18);root.translatesAutoresizingMaskIntoConstraints=false;window.contentView!.addSubview(root);NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor),root.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor),root.topAnchor.constraint(equalTo:window.contentView!.topAnchor),root.bottomAnchor.constraint(equalTo:window.contentView!.bottomAnchor)])
  let heading=NSTextField(labelWithString:"常用命令宏");heading.font = .systemFont(ofSize:22,weight:.semibold);root.addArrangedSubview(heading)
  let hint=NSTextField(wrappingLabelWithString:"命令宏每行一步；录制保留输入与间隔，可能包含密码。请在停止后审阅草稿，删除敏感输入再保存。");hint.textColor=AppTheme.muted;hint.font = .systemFont(ofSize:11);root.addArrangedSubview(hint);hint.widthAnchor.constraint(equalTo:root.widthAnchor,constant:-36).isActive=true
  let targetRow=NSStackView(views:[targetLabel,targetButton,recordButton]);targetLabel.lineBreakMode = .byTruncatingMiddle;targetLabel.setContentCompressionResistancePriority(.init(1),for:.horizontal);targetRow.spacing=12;root.addArrangedSubview(targetRow);targetRow.widthAnchor.constraint(equalTo:root.widthAnchor,constant:-36).isActive=true
  let body=NSStackView();body.orientation = .horizontal;body.alignment = .top;body.spacing=16;body.setContentHuggingPriority(.init(1),for:.vertical);root.addArrangedSubview(body);body.widthAnchor.constraint(equalTo:root.widthAnchor,constant:-36).isActive=true
  let library=NSStackView();library.orientation = .vertical;library.spacing=8;library.widthAnchor.constraint(equalToConstant:180).isActive=true;body.addArrangedSubview(library)
  let column=NSTableColumn(identifier:NSUserInterfaceItemIdentifier("macro"));column.title="已保存的宏";column.width=175;table.addTableColumn(column);table.dataSource=self;table.delegate=self;table.rowHeight=42;table.backgroundColor=AppTheme.sidebar
  let list=NSScrollView();list.hasVerticalScroller=true;list.documentView=table;library.addArrangedSubview(list);list.widthAnchor.constraint(equalTo:library.widthAnchor).isActive=true;list.setContentHuggingPriority(.init(1),for:.vertical)
  let libraryActions=NSStackView(views:[newButton,duplicateButton,deleteButton]);library.addArrangedSubview(libraryActions);let archiveActions=NSStackView(views:[importButton,exportButton]);archiveActions.spacing=6;library.addArrangedSubview(archiveActions);library.addArrangedSubview(reloadButton);duplicateButton.toolTip="把当前编辑内容复制成新草稿，保存后加入宏列表";importButton.toolTip="合并 MacTerm 宏文件，保留现有宏与当前草稿，不自动回放";exportButton.toolTip="导出已载入的全部已保存宏，不包含未保存的编辑内容"
  let editor=NSStackView();editor.orientation = .vertical;editor.alignment = .leading;editor.spacing=8;body.addArrangedSubview(editor);editor.widthAnchor.constraint(equalTo:body.widthAnchor,constant:-196).isActive=true;editor.heightAnchor.constraint(equalTo:library.heightAnchor).isActive=true
  nameField.placeholderString="宏名称";nameField.delegate=self;editor.addArrangedSubview(nameField);nameField.widthAnchor.constraint(equalTo:editor.widthAnchor).isActive=true;formatLabel.font = .systemFont(ofSize:11);formatLabel.textColor=AppTheme.accent;editor.addArrangedSubview(formatLabel);formatLabel.widthAnchor.constraint(equalTo:editor.widthAnchor).isActive=true
  commands.isRichText=false;commands.allowsUndo=true;commands.isAutomaticSpellingCorrectionEnabled=false;commands.isAutomaticLinkDetectionEnabled=false;commands.textContainer?.containerSize=NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude);commands.isAutomaticQuoteSubstitutionEnabled=false;commands.isAutomaticDashSubstitutionEnabled=false;commands.isAutomaticTextReplacementEnabled=false;commands.font = .monospacedSystemFont(ofSize:12,weight:.regular);commands.backgroundColor=AppTheme.terminal;commands.textColor=AppTheme.text;commands.textContainerInset=NSSize(width:10,height:10);commands.delegate=self;commands.isVerticallyResizable=true;commands.isHorizontallyResizable=false;commands.autoresizingMask=[.width];commands.textContainer?.widthTracksTextView=true
  let commandScroll=NSScrollView();commandScroll.backgroundColor=AppTheme.terminal;commandScroll.hasVerticalScroller=true;commandScroll.documentView=commands;editor.addArrangedSubview(commandScroll);commandScroll.widthAnchor.constraint(equalTo:editor.widthAnchor).isActive=true;commandScroll.heightAnchor.constraint(greaterThanOrEqualToConstant:140).isActive=true;commandScroll.setContentHuggingPriority(.init(1),for:.vertical)
  interval.delegate=self;interval.widthAnchor.constraint(equalToConstant:65).isActive=true;interval.setAccessibilityLabel("每步间隔毫秒");let options=NSStackView(views:[NSTextField(labelWithString:"每步间隔"),interval,NSTextField(labelWithString:"毫秒")]);options.spacing=6;editor.addArrangedSubview(options);editor.addArrangedSubview(sendReturn)
  let actions=NSStackView(views:[saveButton,runButton,cancelButton]);actions.spacing=10;root.addArrangedSubview(actions);status.font = .systemFont(ofSize:11);status.textColor=AppTheme.muted;root.addArrangedSubview(status);status.widthAnchor.constraint(equalTo:root.widthAnchor,constant:-36).isActive=true;status.heightAnchor.constraint(greaterThanOrEqualToConstant:30).isActive=true
  for (button,action) in [(recordButton,#selector(toggleRecording)),(importButton,#selector(importMacros)),(exportButton,#selector(exportMacros)),(duplicateButton,#selector(duplicateDraft)),(saveButton,#selector(saveDraft)),(runButton,#selector(runMacro)),(cancelButton,#selector(cancelPlayback)),(newButton,#selector(newMacro)),(deleteButton,#selector(deleteMacro)),(reloadButton,#selector(reloadMacros)),(targetButton,#selector(bindCurrent)),(sendReturn,#selector(draftChanged))] {button.target=self;button.action=action}
  playback.changed = {[weak self] in self?.playbackChanged()};recorder.changed = {[weak self] change in self?.recordingChanged(change)};reloadLibrary(confirm:false)
 }
 required init?(coder:NSCoder){fatalError()}
 func numberOfRows(in tableView:NSTableView)->Int{macros.count}
 func tableView(_ tableView:NSTableView,viewFor column:NSTableColumn?,row:Int)->NSView? {
  let macro=macros[row];let preview=macro.events.map{"录制 · \($0.count) 个输入事件"} ?? String((macro.lines.first ?? "").prefix(140));let label=NSTextField(labelWithString:"")
  let title=NSMutableAttributedString(string:macro.name+"\n",attributes:[.font:NSFont.systemFont(ofSize:12,weight:.medium),.foregroundColor:AppTheme.text]);title.append(NSAttributedString(string:preview,attributes:[.font:NSFont.monospacedSystemFont(ofSize:10,weight:.regular),.foregroundColor:AppTheme.muted]));label.attributedStringValue=title;label.lineBreakMode = .byTruncatingTail;label.toolTip=macro.name+"\n"+preview+"\n间隔：\(macro.intervalMilliseconds) 毫秒 · "+(macro.sendReturn ? "发送回车" : "仅填入");return label
 }
 func selectionShouldChange(in tableView:NSTableView)->Bool {suppressSelection || (!playback.isRunning && !recorder.isRecording && confirmDiscard())}
 func tableViewSelectionDidChange(_ notification:Notification){guard !suppressSelection,!recorder.isRecording,!playback.isRunning else{return};loadDraft(macros.indices.contains(table.selectedRow) ? macros[table.selectedRow] : nil)}
 func confirmDiscard()->Bool {if recorder.isRecording{stopRecording(showResult:false)};guard dirty else{return true};let alert=NSAlert();alert.messageText="放弃尚未保存的宏修改？";alert.addButton(withTitle:"继续编辑");alert.addButton(withTitle:"放弃修改");let discard=alert.runModal() == .alertSecondButtonReturn;if !discard{showWindow(nil);window?.makeKeyAndOrderFront(nil)};return discard}
 private func loadDraft(_ macro:TerminalMacro?,asCopy:Bool=false){loading=true;original=asCopy ? nil : macro;draftID=macro?.id ?? UUID();nameField.stringValue=macro?.name ?? "";recordedDraft=macro?.events != nil;commands.string=macro?.events.flatMap{try? MacroRecorder.json($0)} ?? macro?.body ?? "";formatLabel.stringValue=recordedDraft ? "录制宏 · JSON 事件，可编辑 / 删除；回车与控制键原样回放" : "命令宏 · 每行一步";interval.stringValue=String(macro?.intervalMilliseconds ?? 500);sendReturn.title=recordedDraft ? "回车与控制键按事件原样回放" : "每行发送回车（执行命令）";sendReturn.state=macro?.sendReturn == false ? .off : .on;commands.undoManager?.removeAllActions();loading=false;dirty=asCopy;updateControls()}
 func editedMacro()throws->TerminalMacro {if recordedDraft {return try TerminalMacro(id:draftID,name:nameField.stringValue.trimmingCharacters(in:.whitespacesAndNewlines),body:"",intervalMilliseconds:0,sendReturn:false,events:MacroRecorder.decode(commands.string)).validated()};guard let delay=Int(interval.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)) else{throw SFTPError.message("间隔必须填写整数毫秒")};return try TerminalMacro(id:draftID,name:nameField.stringValue.trimmingCharacters(in:.whitespacesAndNewlines),body:commands.string,intervalMilliseconds:delay,sendReturn:sendReturn.state == .on).validated()}
 @objc func draftChanged(){guard !loading else{return};dirty=(try? editedMacro()) != original || original==nil;do{_ = try editedMacro();status.stringValue=dirty ? "尚未保存的宏修改；回放使用当前编辑内容。" : "未修改"}catch{status.stringValue=error.localizedDescription};updateControls()}
 func controlTextDidChange(_ notification:Notification){draftChanged()}
 func textDidChange(_ notification:Notification){draftChanged()}
 private func choose(_ id:UUID?){suppressSelection=true;table.reloadData();if let id=id,let row=macros.firstIndex(where:{$0.id==id}) {table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false)}else{table.deselectAll(nil)};suppressSelection=false}
 @objc func newMacro(){guard !storeLocked,!playback.isRunning,!recorder.isRecording,confirmDiscard() else{return};choose(nil);loadDraft(nil);nameField.stringValue="新命令宏";dirty=true;window?.makeFirstResponder(commands);status.stringValue="输入命令后保存；回放会使用当前编辑内容。";updateControls()}
 @objc func saveDraft(){guard !storeLocked,!playback.isRunning,!recorder.isRecording else{return};do{let value=try editedMacro();var next=macros;if let index=next.firstIndex(where:{$0.id==value.id}) {next[index]=value}else{next.append(value)};let saved=try store.save(next,expected:revision);macros=next;revision=saved;loadDraft(value);choose(value.id);status.stringValue="宏已保存"}catch{status.stringValue=error.localizedDescription};updateControls()}
 @objc func duplicateDraft(){guard !storeLocked,!playback.isRunning,!recorder.isRecording,macros.count<500 else{return};do{let copy=try MacroStore.duplicate(editedMacro(),among:macros);choose(nil);loadDraft(copy,asCopy:true);status.stringValue="已复制当前内容；保存后加入宏列表。";window?.makeFirstResponder(nameField)}catch{status.stringValue=error.localizedDescription};updateControls()}
 @discardableResult func importLibrary(from url:URL)throws->MacroMerge {
  guard !storeLocked,!playback.isRunning,!recorder.isRecording else{throw SFTPError.message("请先停止回放，或修复并重新载入宏文件")}
  let incoming=try MacroStore.imported(from:url);let merged=try MacroStore.merge(incoming,into:macros)
  if merged.added>0 {
   let firstAdded=merged.macros[macros.count];let saved=try store.save(merged.macros,expected:revision);let preserveDraft=dirty || original != nil;macros=merged.macros;revision=saved
   if preserveDraft{choose(original?.id)}else{choose(firstAdded.id);loadDraft(firstAdded)}
  }
  status.stringValue="已导入 \(merged.added) 个，跳过相同内容 \(merged.skipped) 个"+(merged.remapped>0 ? "；\(merged.remapped) 个 ID 冲突保留为新宏" : "")+"。未自动回放。";updateControls();return merged
 }
 func exportLibrary(to url:URL)throws {
  guard !storeLocked,!playback.isRunning,!recorder.isRecording else{throw SFTPError.message("请先停止回放，或修复并重新载入宏文件")}
  let protected=[store.url,store.url.appendingPathExtension("lock"),store.url.appendingPathExtension("backup")].map{$0.standardizedFileURL.resolvingSymlinksInPath()}
  let resolved=url.standardizedFileURL.resolvingSymlinksInPath()
  let workingFile=protected.contains{path in if path==resolved{return true};var first=stat(),second=stat();return lstat(path.path,&first)==0 && lstat(resolved.path,&second)==0 && first.st_dev==second.st_dev && first.st_ino==second.st_ino}
  guard !workingFile else{throw SFTPError.message("请选择宏工作文件、锁和备份以外的导出位置")}
  try MacroStore.export(macros,to:url);status.stringValue="已导出 \(macros.count) 个已保存宏，不包含未保存草稿。"
 }
 @objc func importMacros(){guard !storeLocked,!playback.isRunning,!recorder.isRecording,let window=window else{return};let picker=NSOpenPanel();picker.canChooseDirectories=false;picker.allowsMultipleSelection=false;picker.message="选择 MacTerm 宏 JSON；合并现有宏，保留当前草稿，不自动回放。";picker.beginSheetModal(for:window){[weak self] response in guard let self=self,response == .OK,let url=picker.url else{return};do{_ = try self.importLibrary(from:url)}catch{self.status.stringValue="导入未完成："+error.localizedDescription};self.updateControls()}}
 @objc func exportMacros(){guard !storeLocked,!playback.isRunning,!recorder.isRecording,!macros.isEmpty,let window=window else{return};let picker=NSSavePanel();picker.nameFieldStringValue="MacTerm-macros.json";picker.message="导出已载入的全部已保存宏，不包含未保存草稿。宏文件包含原始命令，请确认内容后再分享。";picker.beginSheetModal(for:window){[weak self] response in guard let self=self,response == .OK,let url=picker.url else{return};do{try self.exportLibrary(to:url)}catch{self.status.stringValue="导出未完成："+error.localizedDescription}}}
 @objc func deleteMacro(){guard !storeLocked,!playback.isRunning,!recorder.isRecording,let original=original,confirmDiscard() else{return};let alert=NSAlert();alert.messageText="删除宏“\(original.name)”？";alert.addButton(withTitle:"取消");alert.addButton(withTitle:"删除");guard alert.runModal() == .alertSecondButtonReturn else{return};do{let next=macros.filter{$0.id != original.id};revision=try store.save(next,expected:revision);macros=next;choose(nil);loadDraft(nil);status.stringValue="宏已删除"}catch{status.stringValue=error.localizedDescription};updateControls()}
 @objc func reloadMacros(){reloadLibrary(confirm:true)}
 private func reloadLibrary(confirm:Bool){guard !playback.isRunning,!recorder.isRecording,!confirm || confirmDiscard() else{return};do{let loaded=try store.load();macros=loaded.macros;revision=loaded.revision;storeLocked=false;choose(macros.first?.id);loadDraft(macros.first);status.stringValue=macros.isEmpty ? "暂无宏。点击“新建”保存常用命令。" : "已载入 \(macros.count) 个宏"}catch{storeLocked=true;status.stringValue="宏文件读取失败，未覆盖原文件。修复后重新载入。\n"+error.localizedDescription};updateControls()}
 @objc func bindCurrent(){guard !playback.isRunning,!recorder.isRecording else{return};target?.onAvailabilityChanged=nil;target=nil;ready=nil;targetName="未选择"
  if let owner=workspaceOwner,let item=owner.tabs.selectedTabViewItem,let pane=owner.activeTerminal {target=pane
   if let workspace=item.view as? SSHWorkspace {targetName=item.label+" · "+workspace.session.host;ready = {[weak pane,weak workspace] in guard let pane=pane,let workspace=workspace else{return false};return !pane.stopped && pane.pid>0 && !pane.receivedEOF && FileManager.default.fileExists(atPath:workspace.socket)}}
   else {targetName=item.label+" · "+(pane.serialSettings.map{"串口 "+$0.device} ?? pane.telnetDestination.map{"Telnet "+$0} ?? "本机");ready = {[weak pane] in pane.map{!$0.stopped && $0.pid>0 && !$0.receivedEOF && ($0.telnetSettings == nil || $0.telnetConnected) && ($0.serialSettings == nil || $0.serialConnected)} ?? false}}
   pane.onAvailabilityChanged = {[weak self] in guard let self=self else{return};if self.ready?() != true {self.playback.fail("目标终端已结束，后续命令未发送");self.recorder.poll()};self.updateControls()}
  };updateControls()
 }
 @objc func runMacro(){if workspaceOwner?.inputSyncWindow?.runner.isRunning==true{status.stringValue="请先停止实时输入同步。";return};guard !recorder.isRecording,!storeLocked,ready?()==true,let pane=target else{status.stringValue="目标尚未就绪或已结束；SSH 请先完成登录。";return};do{let macro=try editedMacro();let isReady=ready;try playback.start(macro,send:{[weak pane] text in guard isReady?()==true,let pane=pane else{return false};pane.send(text);return true})}catch{status.stringValue=error.localizedDescription}}
 @objc func cancelPlayback(){playback.cancel()}
 private func playbackChanged(){switch playback.state {case .idle:break;case .running(let sent,let total):status.stringValue="目标：\(String(targetName.prefix(120))) · 已发送 \(sent) / \(total) 步";if sent>0{return};case .sent:status.stringValue="全部已提交发送；请在目标终端查看执行结果。";case .cancelled:status.stringValue="已取消后续发送；已提交的命令不会撤回。";case .failed(let reason):status.stringValue=reason};updateControls()}
 private func updateControls(){let running=playback.isRunning || recorder.isRecording;let valid=running || (try? editedMacro()) != nil;targetLabel.toolTip=targetName;targetLabel.stringValue="目标："+targetName+(ready?()==true ? "" : "（尚未就绪或已结束）");nameField.isEnabled = !storeLocked && !running;interval.isEnabled = !storeLocked && !running && !recordedDraft;sendReturn.isEnabled = !storeLocked && !running && !recordedDraft;commands.isEditable = !storeLocked && !running;newButton.isEnabled = !storeLocked && !running && macros.count<500;deleteButton.isEnabled = !storeLocked && !running && original != nil;saveButton.isEnabled = !storeLocked && !running && dirty && valid && (original != nil || macros.count<500);importButton.isEnabled = !storeLocked && !running;exportButton.isEnabled = !storeLocked && !running && !macros.isEmpty;duplicateButton.isEnabled = !storeLocked && !running && valid && macros.count<500;runButton.title=recordedDraft ? "回放录制输入" : "回放到目标终端";runButton.isEnabled = !storeLocked && !running && valid && ready?()==true;runButton.toolTip = !valid ? "请填写有效名称、命令和间隔；宏最多 500 行。" : "向显示的目标终端发送当前编辑内容";cancelButton.isEnabled=playback.isRunning;reloadButton.isEnabled = !running;targetButton.isEnabled = !running;recordButton.toolTip="录制当前标签的输入；回车和控制键会回放。请勿录入密码。";recordButton.title=recorder.isRecording ? "停止并审阅" : "录制当前标签";recordButton.contentTintColor=recorder.isRecording ? .systemRed : AppTheme.text;recordButton.isEnabled=recorder.isRecording || (!storeLocked && !running && macros.count<500 && ready?()==true && target?.recordingSupported==true)}
 func windowShouldClose(_ sender:NSWindow)->Bool {guard confirmDiscard() else{return false};playback.cancel();loadDraft(original);return true}
 func windowWillClose(_ notification:Notification){recordingShowsResult=false;recorder.stop();recordingTimer?.invalidate();playback.cancel()}
}

extension AppDelegate {
 @objc func openMacros(){if macroWindow==nil {macroWindow=MacroWindow(store:MacroStore(url:storage.deletingLastPathComponent().appendingPathComponent("macros.json")));macroWindow?.workspaceOwner=self};if macroWindow?.recorder.isRecording == true {macroWindow?.stopRecording(showResult:true);return};if macroWindow?.playback.isRunning != true {macroWindow?.bindCurrent()};macroWindow?.showWindow(nil);macroWindow?.window?.makeKeyAndOrderFront(nil)}
}
extension AppDelegate:NSWindowDelegate {
 func windowShouldClose(_ sender:NSWindow)->Bool {guard sender === window else{return true};NSApp.terminate(nil);return false}
}

extension MacroWindow {
 @objc func toggleRecording(){if recorder.isRecording{stopRecording(showResult:true)}else{beginRecording()}}
 func beginRecording(){if workspaceOwner?.inputSyncWindow?.runner.isRunning==true{status.stringValue="请先停止实时输入同步。";return};if workspaceOwner?.broadcastWindow?.runner.isRunning==true{status.stringValue="广播发送中，请结束后开始录制。";return};guard !storeLocked,!playback.isRunning,!recorder.isRecording,macros.count<500,workspaceOwner?.broadcastWindow?.runner.isRunning != true,confirmDiscard() else{return};if dirty{loadDraft(original)};bindCurrent();guard let pane=target,let ready=ready,ready(),pane.recordingSupported else{status.stringValue="当前标签未就绪或不支持输入录制。";return}
  recordingShowsResult=true;pane.onRecordedInput = {[weak self,weak pane] input in guard let pane=pane else{return};self?.recorder.capture(input,from:pane.identity)};pane.onUnsupportedRecordingInput = {[weak self] in self?.recorder.stop("遇到二进制鼠标输入，已停止录制；请审阅已录部分")};pane.isRecordingInput=true
  do{try recorder.start(target:pane.identity,available:{[weak pane] in ready() && pane?.recordingSupported==true});recordingTimer?.invalidate();let timer=Timer(timeInterval:0.25,repeats:true){[weak self] _ in self?.recorder.poll()};recordingTimer=timer;RunLoop.main.add(timer,forMode:.common);workspaceOwner?.updateInputRecordingIndicator(true,target:targetName);window?.orderOut(nil);workspaceOwner?.window?.makeKeyAndOrderFront(nil);pane.web.evaluateJavaScript("focusTerminal()",completionHandler:nil)}catch{pane.onRecordedInput=nil;pane.onUnsupportedRecordingInput=nil;pane.isRecordingInput=false;status.stringValue=error.localizedDescription;updateControls()}
 }
 func stopRecording(showResult:Bool){recordingShowsResult=showResult;recorder.stop()}
 func recordingChanged(_ change:MacroRecordingChange){switch change {
  case .started:updateControls();status.stringValue="正在录制固定标签："+String(targetName.prefix(120))+"。请勿输入密码；通过工具栏停止录制。"
  case .progress:status.stringValue="录制中 · \(recorder.events.count) 个事件 · \(recorder.bytes) 字节 · "+targetName
  case .stopped(let reason):recordingTimer?.invalidate();recordingTimer=nil;target?.onRecordedInput=nil;target?.onUnsupportedRecordingInput=nil;target?.isRecordingInput=false;workspaceOwner?.updateInputRecordingIndicator(false)
   if !recorder.events.isEmpty {do{let formatter=DateFormatter();formatter.dateFormat="MM-dd HH:mm:ss";let value=try recorder.draft(name:"录制宏 "+formatter.string(from:Date()));choose(nil);loadDraft(value,asCopy:true);status.stringValue=reason+"。输入仅为草稿，请删除密码等敏感内容后保存。"}catch{status.stringValue=error.localizedDescription}}
   else{status.stringValue=reason+"，没有录到输入。"};updateControls();if recordingShowsResult{showWindow(nil);window?.makeKeyAndOrderFront(nil)}
  }
 }
}
extension AppDelegate {
 @objc func stopInputRecording(){macroWindow?.stopRecording(showResult:true)}
 func updateInputRecordingIndicator(_ recording:Bool,target:String=""){macroToolbarButton?.title=recording ? "停止录制" : "宏";macroToolbarButton?.image=recording ? nil : AppTheme.symbol("play.rectangle");macroToolbarButton?.contentTintColor=recording ? .systemRed : AppTheme.text;macroToolbarButton?.toolTip=recording ? "正在录制："+target+"。点击停止并审阅草稿。" : "管理与录制命令宏";updateTabStrip()}
}
