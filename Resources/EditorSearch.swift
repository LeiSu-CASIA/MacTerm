import Cocoa

struct EditorSearchSpec:Equatable {
 var query:String;var caseSensitive=false,wholeWord=false,regularExpression=false
 static func ==(lhs:Self,rhs:Self)->Bool {Data(lhs.query.utf8)==Data(rhs.query.utf8) && lhs.caseSensitive==rhs.caseSensitive && lhs.wholeWord==rhs.wholeWord && lhs.regularExpression==rhs.regularExpression}
}
final class EditorSearchCancellation {
 private let lock=NSLock();private var value=false
 var cancelled:Bool {lock.lock();defer{lock.unlock()};return value}
 func cancel(){lock.lock();value=true;lock.unlock()}
}
struct EditorSearchSnapshot {
 let source:String,spec:EditorSearchSpec,matches:[NSTextCheckingResult],groups:Int
 static let maximumMatches=20000
 static func find(_ source:String,spec:EditorSearchSpec,cancellation:EditorSearchCancellation=EditorSearchCancellation(),maximumMatches:Int=maximumMatches,timeLimit:TimeInterval=0.5)throws->Self {
  guard source.utf16.count<=RemoteText.maximumBytes,spec.query.utf8.count<=4096,(1...Self.maximumMatches).contains(maximumMatches),timeLimit>0,timeLimit<=5 else{throw SFTPError.message("查找文本最多 4 KiB，文档或搜索限制超出范围")}
  guard !cancellation.cancelled else{throw SFTPError.message("查找已取消")}
  if spec.query.isEmpty{return Self(source:source,spec:spec,matches:[],groups:0)}
  let deadline=ProcessInfo.processInfo.systemUptime+timeLimit
  var pattern=spec.regularExpression ? spec.query : NSRegularExpression.escapedPattern(for:spec.query)
  if spec.wholeWord {let word="[\\p{L}\\p{N}\\p{M}\\p{Pc}\\u200C\\u200D]";pattern="(?<!"+word+")(?:"+pattern+")(?!"+word+")"}
  var options:NSRegularExpression.Options=[.anchorsMatchLines];if !spec.caseSensitive{options.insert(.caseInsensitive)}
  let expression:NSRegularExpression;do{expression=try NSRegularExpression(pattern:pattern,options:options)}catch{throw SFTPError.message("正则表达式无效："+error.localizedDescription)}
  let units=Array(source.utf16);var matches=[NSTextCheckingResult](),failure:String?
  expression.enumerateMatches(in:source,options:[.reportProgress,.reportCompletion],range:NSRange(location:0,length:units.count)){match,flags,stop in
   if cancellation.cancelled {failure="查找已取消";stop.pointee=true;return}
   if ProcessInfo.processInfo.systemUptime>deadline{failure="查找用时过长，请缩小范围或简化正则表达式";stop.pointee=true;return}
   if flags.contains(.internalError){failure="正则匹配失败，请简化表达式";stop.pointee=true;return}
   guard let match=match else{return}
   guard valid(match.range,units:units) else{failure="匹配范围不在完整 Unicode 字符边界上";stop.pointee=true;return}
   guard matches.count<maximumMatches else{failure="匹配超过 \(maximumMatches) 项，请缩小条件；未执行部分替换";stop.pointee=true;return};matches.append(match)
  }
  if let failure=failure{throw SFTPError.message(failure)}
  return Self(source:source,spec:spec,matches:matches,groups:expression.numberOfCaptureGroups)
 }
 private static func valid(_ range:NSRange,units:[UInt16])->Bool {
  guard range.location>=0,range.location<=units.count,range.length>=0,range.length<=units.count-range.location else{return false}
  func boundary(_ index:Int)->Bool {index==0 || index==units.count || !((0xDC00...0xDFFF).contains(units[index]) && (0xD800...0xDBFF).contains(units[index-1]))}
  return boundary(range.location) && boundary(range.location+range.length)
 }
 enum Part {case literal(String);case group(Int)}
 private func template(_ input:String)throws->[Part] {
  guard input.utf8.count<=65536 else{throw SFTPError.message("替换文本不能超过 64 KiB")}
  guard spec.regularExpression else{return [.literal(input)]}
  let characters=Array(input.unicodeScalars);var result=[Part](),literal="",index=0
  func flush(){if !literal.isEmpty{result.append(.literal(literal));literal=""}}
  while index<characters.count {
   let value=characters[index];index+=1
   if value.value==92 {
    guard index<characters.count else{throw SFTPError.message("正则替换末尾的反斜杠需要转义为 \\\\")};let escaped=characters[index];index+=1
    switch escaped.value{case 110:literal+="\n";case 114:literal+="\r";case 116:literal+="\t";default:literal.unicodeScalars.append(escaped)}
   }else if value.value==36 {
    flush();var digits=""
    while index<characters.count,(48...57).contains(characters[index].value){guard digits.count<6 else{throw SFTPError.message("捕获组编号超出范围")};digits.unicodeScalars.append(characters[index]);index+=1}
    guard !digits.isEmpty,let group=Int(digits),group<=groups else{throw SFTPError.message("替换包含不存在的捕获组；字面 $ 请写成 \\$")};result.append(.group(group))
   }else{literal.unicodeScalars.append(value)}
  };flush();return result
 }
 func replacing(_ replacement:String,only index:Int?=nil)throws->(text:String,changes:[(NSRange,String)]) {
  if let index=index {guard matches.indices.contains(index) else{throw SFTPError.message("当前匹配已失效")}}
  let parts=try template(replacement),units=Array(source.utf16),string=source as NSString,chosen=index.map{[matches[$0]]} ?? matches
  var predicted=units.count,changes=[(NSRange,String)]()
  for match in chosen {
   guard Self.valid(match.range,units:units) else{throw SFTPError.message("替换范围已失效")};let allowance=RemoteText.maximumBytes-predicted+match.range.length;var expanded="",length=0
   for part in parts {
    let piece:String,count:Int
    switch part {
    case .literal(let value):piece=value;count=value.utf16.count
    case .group(let group):
     guard group<match.numberOfRanges else{throw SFTPError.message("捕获组与当前匹配不一致")};let range=match.range(at:group);if range.location==NSNotFound{piece="";count=0}
     else{guard Self.valid(range,units:units),range.length<=allowance-length else{throw SFTPError.message("捕获组展开后超过文本大小限制")};piece=string.substring(with:range);count=range.length}
    }
    guard count<=allowance-length else{throw SFTPError.message("替换后超过文本大小限制")};expanded+=piece;length+=count
   }
   predicted+=length-match.range.length;changes.append((match.range,expanded))
  }
  let output=NSMutableString(capacity:predicted);var offset=0
  for (range,value) in changes {output.append(string.substring(with:NSRange(location:offset,length:range.location-offset)));output.append(value);offset=range.location+range.length}
  output.append(string.substring(from:offset));return(output as String,changes)
 }
}

final class EditorFindBar:NSView {
 override var isFlipped:Bool {true}
 let query=NSSearchField(),replacement=NSTextField(),caseSensitive=NSButton(checkboxWithTitle:"区分大小写",target:nil,action:nil),wholeWord=NSButton(checkboxWithTitle:"整词",target:nil,action:nil),regex=NSButton(checkboxWithTitle:"正则",target:nil,action:nil)
 let previous=AppActionButton(title:"↑",target:nil,action:nil),next=AppActionButton(title:"↓",target:nil,action:nil),close=AppActionButton(title:"×",target:nil,action:nil),replace=AppActionButton(title:"替换当前",target:nil,action:nil),replaceAll=AppActionButton(title:"全部替换",target:nil,action:nil),message=NSTextField(labelWithString:"")
 var showsReplacement=false {didSet{replacement.isHidden = !showsReplacement;replace.isHidden = !showsReplacement;replaceAll.isHidden = !showsReplacement;needsLayout=true}}
 var spec:EditorSearchSpec {EditorSearchSpec(query:query.stringValue,caseSensitive:caseSensitive.state == .on,wholeWord:wholeWord.state == .on,regularExpression:regex.state == .on)}
 override init(frame:NSRect){super.init(frame:frame);AppTheme.surface(self,AppTheme.sidebar,radius:8)
  for button in [previous,next,close,replace,replaceAll]{AppTheme.action(button)};query.recentsAutosaveName=nil;query.maximumRecents=0;query.placeholderString="查找文本或正则表达式";replacement.placeholderString="替换为…（正则：$1、\\n、\\t）";AppTheme.field(query);AppTheme.field(replacement);query.setAccessibilityLabel("当前文件查找");replacement.setAccessibilityLabel("当前文件替换文本");message.font = .systemFont(ofSize:11);message.textColor=AppTheme.muted;message.lineBreakMode = .byTruncatingTail
  for view in [query,replacement,caseSensitive,wholeWord,regex,previous,next,close,replace,replaceAll,message] as [NSView]{addSubview(view)};showsReplacement=false;replacement.isHidden=true;replace.isHidden=true;replaceAll.isHidden=true
 }
 required init?(coder:NSCoder){fatalError()}
 override func layout(){super.layout();let width=bounds.width;query.frame=NSRect(x:10,y:8,width:max(80,width-118),height:28);previous.frame=NSRect(x:width-104,y:8,width:28,height:28);next.frame=NSRect(x:width-72,y:8,width:28,height:28);close.frame=NSRect(x:width-40,y:8,width:28,height:28)
  caseSensitive.frame=NSRect(x:10,y:43,width:105,height:20);wholeWord.frame=NSRect(x:119,y:43,width:61,height:20);regex.frame=NSRect(x:184,y:43,width:61,height:20);message.frame=NSRect(x:250,y:44,width:max(0,width-260),height:18)
  replacement.frame=NSRect(x:10,y:76,width:max(80,width-190),height:28);replace.frame=NSRect(x:width-174,y:76,width:77,height:28);replaceAll.frame=NSRect(x:width-93,y:76,width:83,height:28)
 }
}

extension RemoteEditor {
 var currentSearch:Bool {guard let snapshot=searchSnapshot else{return false};return !searchBusy && snapshot.spec==findBar.spec && snapshot.source.utf16.elementsEqual(textView.string.utf16)}
 func configureFindBar(){
  findBar.query.delegate=self;findBar.replacement.delegate=self
  for (button,action) in [(findButton,#selector(showFind)),(replaceFindButton,#selector(showReplace)),(findBar.close,#selector(hideFind)),(findBar.next,#selector(nextMatch)),(findBar.previous,#selector(previousMatch)),(findNextButton,#selector(nextMatch)),(findPreviousButton,#selector(previousMatch)),(findBar.replace,#selector(replaceCurrentMatch)),(findBar.replaceAll,#selector(replaceAllMatches)),(findBar.caseSensitive,#selector(searchOptionsChanged)),(findBar.wholeWord,#selector(searchOptionsChanged)),(findBar.regex,#selector(searchOptionsChanged))] {button.target=self;button.action=action}
  for (button,key,modifiers) in [(findButton,"f",NSEvent.ModifierFlags.command),(replaceFindButton,"f",[.command,.option]),(findNextButton,"g",.command),(findPreviousButton,"g",[.command,.shift])] {button.keyEquivalent=key;button.keyEquivalentModifierMask=modifiers}
  updateFindControls()
 }
 @objc func showFind(){showFinder(replace:false)}
 @objc func showReplace(){showFinder(replace:true)}
 private func showFinder(replace:Bool){guard !editorClosed else{return};findBar.showsReplacement=replace;findHeight.constant=replace ? 114 : 72;findBar.isHidden=false;window?.contentView?.layoutSubtreeIfNeeded();window?.makeFirstResponder(findBar.query);findBar.query.selectText(nil);scheduleSearch(select:true,delay:0)}
 @objc func hideFind(){findGeneration=UUID();findCancellation?.cancel();findJob?.cancel();searchBusy=false;findBar.isHidden=true;findHeight.constant=0;window?.makeFirstResponder(textView);updateFindControls()}
 @objc func searchOptionsChanged(){scheduleSearch(select:true,delay:0)}
 func controlTextDidChange(_ notification:Notification){if notification.object as? NSSearchField === findBar.query{scheduleSearch(select:true)}else{updateFindControls()}}
 func control(_ control:NSControl,textView fieldEditor:NSTextView,doCommandBy commandSelector:Selector)->Bool {
  if commandSelector == #selector(NSResponder.cancelOperation(_:)){hideFind();return true}
  if commandSelector == #selector(NSResponder.insertNewline(_:)){if control === findBar.replacement{replaceCurrentMatch()}else if NSApp.currentEvent?.modifierFlags.contains(.shift)==true{previousMatch()}else{nextMatch()};return true};return false
 }
 func sourceChanged(){findGeneration=UUID();findCancellation?.cancel();findJob?.cancel();searchSnapshot=nil;searchIndex=nil;searchBusy=false;if !findBar.isHidden,!findBar.query.stringValue.isEmpty{scheduleSearch(select:false)}else{updateFindControls()}}
 func scheduleSearch(select:Bool,delay:TimeInterval=0.12){
  guard !editorClosed else{return};findGeneration=UUID();let generation=findGeneration;findCancellation?.cancel();findJob?.cancel();searchSnapshot=nil;searchIndex=nil
  if findBar.query.stringValue.isEmpty{searchBusy=false;findBar.message.stringValue="";updateFindControls();return}
  searchBusy=true;findBar.message.stringValue="查找中…";findBar.message.textColor=AppTheme.muted;updateFindControls()
  let job=DispatchWorkItem{[weak self] in guard let self=self,!self.editorClosed,self.findGeneration==generation else{return};let source=self.textView.string,spec=self.findBar.spec,token=EditorSearchCancellation();self.findCancellation=token
   self.findQueue.async{let result=Result{try EditorSearchSnapshot.find(source,spec:spec,cancellation:token)}
    DispatchQueue.main.async{[weak self] in guard let self=self,!self.editorClosed,self.findGeneration==generation else{return};self.searchBusy=false
     guard self.findBar.spec==spec,source.utf16.elementsEqual(self.textView.string.utf16) else{self.sourceChanged();return}
     switch result{case .success(let snapshot):self.searchSnapshot=snapshot
      if select,!snapshot.matches.isEmpty{let caret=self.textView.selectedRange().location;self.selectSearchMatch(snapshot.matches.firstIndex{$0.range.location>=caret} ?? 0)}
      else{self.searchIndex=snapshot.matches.firstIndex{$0.range==self.textView.selectedRange()};self.updateFindControls()}
     case .failure(let error):self.searchSnapshot=nil;self.searchIndex=nil;self.findBar.message.stringValue=error.localizedDescription;self.findBar.message.textColor = .systemOrange;self.updateFindControls(keepMessage:true)}
    }
   }
  };findJob=job;DispatchQueue.main.asyncAfter(deadline:.now()+delay,execute:job)
 }
 private func selectSearchMatch(_ index:Int){guard currentSearch,let snapshot=searchSnapshot,snapshot.matches.indices.contains(index) else{return};selectingSearchMatch=true;searchIndex=index;let range=snapshot.matches[index].range;textView.setSelectedRange(range);textView.scrollRangeToVisible(range);selectingSearchMatch=false;updateFindControls()}
 func textViewDidChangeSelection(_ notification:Notification){guard !selectingSearchMatch else{return};if currentSearch{searchIndex=searchSnapshot?.matches.firstIndex{$0.range==textView.selectedRange()}}else{searchIndex=nil};updateFindControls()}
 @objc func nextMatch(){navigateSearch(forward:true)}
 @objc func previousMatch(){navigateSearch(forward:false)}
 private func navigateSearch(forward:Bool){guard !editorClosed else{return};guard currentSearch,let snapshot=searchSnapshot,!snapshot.matches.isEmpty else{if findBar.isHidden{showFinder(replace:false)}else{scheduleSearch(select:true,delay:0)};return}
  let range=textView.selectedRange(),count=snapshot.matches.count,index:Int
  if let current=searchIndex,snapshot.matches.indices.contains(current),snapshot.matches[current].range==range {index=(current+(forward ? 1 : -1)+count)%count}
  else if forward {index=snapshot.matches.firstIndex{$0.range.location>=NSMaxRange(range)} ?? 0}
  else {index=snapshot.matches.lastIndex{NSMaxRange($0.range)<=range.location} ?? count-1}
  selectSearchMatch(index)
 }
 func updateFindControls(keepMessage:Bool=false){
  let valid=currentSearch,hasMatches=valid && searchSnapshot?.matches.isEmpty==false
  for button in [findBar.next,findBar.previous,findNextButton,findPreviousButton]{button.isEnabled = !editorClosed && !findBar.query.stringValue.isEmpty}
  findBar.replaceAll.isEnabled = !editorClosed && hasMatches;findBar.replace.isEnabled = !editorClosed && hasMatches && searchIndex.flatMap{searchSnapshot?.matches.indices.contains($0)==true ? searchSnapshot?.matches[$0].range : nil}==textView.selectedRange()
  if !keepMessage,valid,let snapshot=searchSnapshot {findBar.message.textColor=AppTheme.muted;findBar.message.stringValue=searchIndex.map{"\($0+1) / \(snapshot.matches.count)"} ?? "共 \(snapshot.matches.count) 项"}
  findBar.message.toolTip=findBar.message.stringValue
 }
 @objc func replaceCurrentMatch(){
  guard !editorClosed,currentSearch,let snapshot=searchSnapshot,let index=searchIndex,snapshot.matches.indices.contains(index),snapshot.matches[index].range==textView.selectedRange() else{return}
  do {let result=try snapshot.replacing(findBar.replacement.stringValue,only:index);_ = try textModel.encode(result.text)
   guard !result.text.utf16.elementsEqual(textView.string.utf16) else{nextMatch();return};let change=result.changes[0]
   if applyEditorReplacement(range:change.0,value:change.1,name:"替换当前"){scheduleSearch(select:true,delay:0)}
  }catch{findBar.message.stringValue=error.localizedDescription;findBar.message.textColor = .systemOrange;findBar.message.toolTip=error.localizedDescription}
 }
 @objc func replaceAllMatches(){guard !editorClosed,currentSearch,let snapshot=searchSnapshot,!snapshot.matches.isEmpty else{return}
  do {let result=try snapshot.replacing(findBar.replacement.stringValue);_ = try textModel.encode(result.text);guard !result.text.utf16.elementsEqual(textView.string.utf16) else{findBar.message.stringValue="替换后内容未变化";return}
   _ = applyEditorReplacement(range:NSRange(location:0,length:snapshot.source.utf16.count),value:result.text,name:"全部替换")
  }catch{findBar.message.stringValue=error.localizedDescription;findBar.message.textColor = .systemOrange;findBar.message.toolTip=error.localizedDescription}
 }
 private func applyEditorReplacement(range:NSRange,value:String,name:String)->Bool {
  guard let storage=textView.textStorage else{return false};let undo=textView.undoManager;undo?.beginUndoGrouping();defer{undo?.endUndoGrouping()};guard textView.shouldChangeText(in:range,replacementString:value) else{return false};storage.replaceCharacters(in:range,with:value);textView.didChangeText();textView.setSelectedRange(NSRange(location:range.location+value.utf16.count,length:0));undo?.setActionName(name);return true
 }
}
