import Cocoa

struct KeywordRuleGroup:Codable,Equatable {
 let id:UUID;var name:String,settings:KeywordHighlights
 func validated()throws->KeywordRuleGroup {
  guard !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,name.count<=80,!name.unicodeScalars.contains(where:{$0.value<32 || $0.value==127}) else{throw SFTPError.message("规则组名称需为 1–80 个字符，不能包含控制字符")}
  _ = try settings.validated();return self
 }
}
struct KeywordRuleGroupArchive:Codable {let format:String,version:Int,groups:[KeywordRuleGroup]}
struct KeywordRuleGroupSnapshot {let groups:[KeywordRuleGroup],revision:Data?}
struct KeywordRuleGroupStore {
 static let key="keywordRuleGroups.v1",maximumBytes=256*1024
 let defaults:UserDefaults
 init(defaults:UserDefaults = .standard){self.defaults=defaults}
 static func decode(_ data:Data)throws->[KeywordRuleGroup] {
  guard data.count<=maximumBytes else{throw SFTPError.message("规则组文件超过 256 KB")}
  let archive=try JSONDecoder().decode(KeywordRuleGroupArchive.self,from:data)
  guard archive.format=="MacTerm Keyword Rule Groups",archive.version==1,archive.groups.count<=20 else{throw SFTPError.message("规则组格式、版本无效或超过 20 组")}
  var ids=Set<UUID>(),names=Set<Data>()
  for group in archive.groups {_ = try group.validated();guard ids.insert(group.id).inserted,names.insert(Data(group.name.utf8)).inserted else{throw SFTPError.message("规则组 ID 或名称重复")}}
  return archive.groups
 }
 func load()throws->KeywordRuleGroupSnapshot {
  guard let item=defaults.object(forKey:Self.key) else{return KeywordRuleGroupSnapshot(groups:[],revision:nil)}
  guard let data=item as? Data else{throw SFTPError.message("规则组数据无法读取，原数据已保留")}
  return try KeywordRuleGroupSnapshot(groups:Self.decode(data),revision:data)
 }
 func save(_ groups:[KeywordRuleGroup],expected:Data?)throws->KeywordRuleGroupSnapshot {
  let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys];let data=try encoder.encode(KeywordRuleGroupArchive(format:"MacTerm Keyword Rule Groups",version:1,groups:groups));_ = try Self.decode(data)
  let current=try load();guard current.revision==expected else{throw SFTPError.message("规则组已被其他窗口修改，请重新载入列表；当前草稿已保留")}
  defaults.set(data,forKey:Self.key);return KeywordRuleGroupSnapshot(groups:groups,revision:data)
 }
}

extension KeywordHighlightEditor {
 func configureRuleGroups(_ root:NSStackView) {
  groupPicker.setAccessibilityLabel("高亮规则组");groupPicker.target=self;groupPicker.action = #selector(groupSelectionChanged);groupPicker.setContentHuggingPriority(.init(1),for:.horizontal);groupPicker.setContentCompressionResistancePriority(.init(1),for:.horizontal);groupPicker.cell?.lineBreakMode = .byTruncatingTail;groupPicker.widthAnchor.constraint(greaterThanOrEqualToConstant:180).isActive=true
  let row=NSStackView(views:[groupPicker,groupSaveButton,groupUpdateButton,groupRenameButton,groupDeleteButton]);row.spacing=8;root.addArrangedSubview(row);row.widthAnchor.constraint(equalTo:root.widthAnchor,constant:-48).isActive=true;row.heightAnchor.constraint(equalToConstant:28).isActive=true
  for(button,action) in [(groupSaveButton,#selector(saveRuleGroupAs)),(groupUpdateButton,#selector(updateRuleGroup)),(groupRenameButton,#selector(renameRuleGroup)),(groupDeleteButton,#selector(deleteRuleGroup))]{button.target=self;button.action=action;button.bezelStyle = .rounded}
  reloadRuleGroups()
 }
 func reloadRuleGroups(){do{groupSnapshot=try groupStore.load();groupIssue=nil}catch{groupIssue="规则组读取失败，原数据已保留："+error.localizedDescription};refreshGroupMenu();updateGroupControls(valid:(try? edited()) != nil)}
 func refreshGroupMenu(){
  groupPicker.removeAllItems();groupPicker.addItem(withTitle:groupIssue==nil ? "当前草稿 / 选择规则组" : "规则组读取失败")
  for group in groupSnapshot.groups {groupPicker.addItem(withTitle:group.name);groupPicker.lastItem?.representedObject=group.id;groupPicker.lastItem?.toolTip=group.name}
  groupPicker.menu?.addItem(.separator());groupPicker.addItem(withTitle:"重新载入列表…");groupPicker.lastItem?.tag = -1
  if let id=selectedGroup,let index=groupSnapshot.groups.firstIndex(where:{$0.id==id}){groupPicker.selectItem(at:index+1)}else{selectedGroup=nil;groupPicker.selectItem(at:0)}
 }
 func updateGroupControls(valid:Bool){let editable=groupIssue==nil;groupSaveButton.isEnabled=editable && valid && groupSnapshot.groups.count<20;groupUpdateButton.isEnabled=editable && valid && selectedGroup != nil;groupRenameButton.isEnabled=editable && selectedGroup != nil;groupDeleteButton.isEnabled=editable && selectedGroup != nil}
 @objc func groupSelectionChanged(){
  if groupPicker.selectedItem?.tag == -1 {reloadRuleGroups();changed();return}
  guard let id=groupPicker.selectedItem?.representedObject as? UUID else{selectedGroup=nil;refreshGroupMenu();updateGroupControls(valid:(try? edited()) != nil);return}
  _ = selectRuleGroup(id){[weak self] in self?.confirmRuleGroupDiscard() ?? false};refreshGroupMenu()
 }
 func confirmRuleGroupDiscard()->Bool {if let confirm=confirmGroupDiscard{return confirm()};let alert=NSAlert();alert.messageText="替换当前规则草稿？";alert.informativeText="切换后会用所选规则组替换未保存的修改。当前终端高亮不会改变。";alert.window.appearance=NSAppearance(named:.darkAqua);alert.addButton(withTitle:"替换草稿");alert.addButton(withTitle:"继续编辑");return alert.runModal() == .alertFirstButtonReturn}
 @discardableResult func selectRuleGroup(_ id:UUID,confirm:()->Bool)->Bool {
  guard groupIssue==nil,let value=groupSnapshot.groups.first(where:{$0.id==id}) else{return false}
  let draft=try? edited();let unchanged=draft.map{$0.sameGroupContents(as:groupDraftBaseline)} ?? false;if !unchanged && !confirm(){return false}
  do{guard try groupStore.load().revision==groupSnapshot.revision else{throw SFTPError.message("规则组已变化，请重新载入列表；当前草稿已保留")};selectedGroup=id;fill(value.settings);groupDraftBaseline=value.settings;refreshGroupMenu();status.stringValue="已载入规则组；仅预览，保存并应用后影响终端。";return true}catch{status.stringValue=error.localizedDescription;return false}
 }
 func persistRuleGroups(_ groups:[KeywordRuleGroup],selected:UUID?)throws {guard groupIssue==nil else{throw SFTPError.message("请先修复并重新载入规则组，当前草稿仍可应用")};let snapshot=try groupStore.save(groups,expected:groupSnapshot.revision);groupSnapshot=snapshot;selectedGroup=selected;refreshGroupMenu();updateGroupControls(valid:(try? edited()) != nil)}
 @discardableResult func createRuleGroup(name:String)throws->UUID {
  let settings=try edited(),value=try KeywordRuleGroup(id:UUID(),name:name,settings:settings).validated();try persistRuleGroups(groupSnapshot.groups+[value],selected:value.id);groupDraftBaseline=settings;status.stringValue="规则组已保存；当前终端尚未改变。";return value.id
 }
 func updateSelectedRuleGroup()throws {
  guard let id=selectedGroup,let index=groupSnapshot.groups.firstIndex(where:{$0.id==id}) else{throw SFTPError.message("请先选择规则组")};let settings=try edited();var groups=groupSnapshot.groups;groups[index].settings=settings;try persistRuleGroups(groups,selected:id);groupDraftBaseline=settings;status.stringValue="规则组已更新；当前终端尚未改变。"
 }
 func renameSelectedRuleGroup(to name:String)throws {guard let id=selectedGroup,let index=groupSnapshot.groups.firstIndex(where:{$0.id==id}) else{throw SFTPError.message("请先选择规则组")};var groups=groupSnapshot.groups;groups[index].name=name;try persistRuleGroups(groups,selected:id);status.stringValue="规则组已改名；草稿已保留。"}
 func removeSelectedRuleGroup()throws {guard let id=selectedGroup else{return};try persistRuleGroups(groupSnapshot.groups.filter{$0.id != id},selected:nil);status.stringValue="规则组已删除；当前草稿和终端高亮已保留。"}
 func requestRuleGroupName(_ title:String,initial:String)->String? {let alert=NSAlert();alert.messageText=title;alert.informativeText="保存规则组供以后使用；点击“保存并应用”后才改变终端高亮。";alert.window.appearance=NSAppearance(named:.darkAqua);alert.addButton(withTitle:"保存");alert.addButton(withTitle:"取消");let field=NSTextField(frame:NSRect(x:0,y:0,width:320,height:28));AppTheme.field(field);field.stringValue=initial;field.setAccessibilityLabel("规则组名称");alert.accessoryView=field;alert.window.initialFirstResponder=field;guard alert.runModal() == .alertFirstButtonReturn else{return nil};return field.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)}
 @objc func saveRuleGroupAs(){guard let name=requestRuleGroupName("另存高亮规则组",initial:"") else{return};do{_ = try createRuleGroup(name:name)}catch{status.stringValue=error.localizedDescription}}
 @objc func updateRuleGroup(){do{try updateSelectedRuleGroup()}catch{status.stringValue=error.localizedDescription}}
 @objc func renameRuleGroup(){guard let value=groupSnapshot.groups.first(where:{$0.id==selectedGroup}),let name=requestRuleGroupName("规则组改名",initial:value.name) else{return};do{try renameSelectedRuleGroup(to:name)}catch{status.stringValue=error.localizedDescription}}
 @objc func deleteRuleGroup(){guard let value=groupSnapshot.groups.first(where:{$0.id==selectedGroup}) else{return};let alert=NSAlert();alert.messageText="删除规则组“"+value.name+"”？";alert.informativeText="当前草稿和已应用的终端高亮保持不变。";alert.window.appearance=NSAppearance(named:.darkAqua);alert.addButton(withTitle:"删除");alert.addButton(withTitle:"取消");guard alert.runModal() == .alertFirstButtonReturn else{return};do{try removeSelectedRuleGroup()}catch{status.stringValue=error.localizedDescription}}
}

extension KeywordHighlights {
 func sameGroupContents(as other:KeywordHighlights)->Bool {enabled==other.enabled && ignoreCase==other.ignoreCase && (regularExpression ?? false)==(other.regularExpression ?? false) && rules.count==other.rules.count && zip(rules,other.rules).allSatisfy{Data($0.keyword.utf8)==Data($1.keyword.utf8) && Data($0.color.utf8)==Data($1.color.utf8)}}
}
