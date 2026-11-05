import Cocoa
@main struct SessionStoreTests {
 static func main()throws {
  _ = NSApplication.shared
  let root=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("macterm-sessions-"+UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
  let file=root.appendingPathComponent("sessions.json"),store=SessionStore(url:root.appendingPathComponent("sessions.json"))
  let empty=try store.load();precondition(empty.isEmpty)
  let shared=SessionStore(url:root.appendingPathComponent("shared.json"))
  let missing=try shared.loadWithRevision()
  let initial=[Session(name:"shared",host:"shared.invalid",user:"user",port:22,key:"")]
  try shared.save(initial)
  do {try shared.save([],expected:missing.revision);fatalError("A stale empty instance must not overwrite a new file")}catch{}
  let first=try shared.loadWithRevision(),second=try shared.loadWithRevision()
  var changed=first.sessions;changed[0].name="changed by first"
  let committed=try shared.save(changed,expected:first.revision)
  let currentData=try Data(contentsOf:shared.url),currentBackup=try Data(contentsOf:shared.url.appendingPathExtension("backup"))
  do {try shared.save(second.sessions,expected:second.revision);fatalError("A stale instance must not overwrite newer settings")}catch{}
  let preservedData=try Data(contentsOf:shared.url),preservedBackup=try Data(contentsOf:shared.url.appendingPathExtension("backup"))
  precondition(preservedData==currentData && preservedBackup==currentBackup)
  let latest=try shared.loadWithRevision();precondition(latest.sessions[0].name=="changed by first")
  let descriptor=Darwin.open(shared.url.appendingPathExtension("lock").path,O_RDWR)
  precondition(descriptor>=0 && flock(descriptor,LOCK_EX|LOCK_NB)==0)
  do {try shared.save([],expected:committed);fatalError("An active writer must prevent a second save")}catch{}
  _ = flock(descriptor,LOCK_UN);Darwin.close(descriptor)
  try shared.save(latest.sessions,expected:latest.revision)
  let beforeDeletion=try shared.loadWithRevision();try FileManager.default.removeItem(at:shared.url)
  do {try shared.save(beforeDeletion.sessions,expected:beforeDeletion.revision);fatalError("A stale instance must not recreate a removed file")}catch{}
  precondition(!FileManager.default.fileExists(atPath:shared.url.path))
  let app=AppDelegate(storage:shared.url)
  app.sessions=beforeDeletion.sessions;app.sessionsLoadFailed=true;app.sessionRevision=beforeDeletion.revision
  let tab=NSTabViewItem(identifier:"kept");tab.view=NSView();app.tabs.addTabViewItem(tab)
  app.reloadSessions()
  precondition(app.sessions.isEmpty && !app.sessionsLoadFailed && app.sessionRevision == .missing)
  precondition(app.tabs.tabViewItems.count==1 && app.tabs.tabViewItems[0] === tab)
  try shared.save(initial);app.reloadSessions()
  precondition(app.sessions.count==1 && app.sessions[0].name=="shared")
  precondition(app.sessionMenu().items.contains{$0.title=="重新载入会话"})
  let legacy=Data(#"[{"name":"旧会话","host":"old.invalid","user":"user","port":22,"key":""}]"#.utf8);try legacy.write(to:file);let migrated=try store.load();precondition(migrated[0].id != nil && migrated[0].host=="old.invalid")
  try store.save(migrated);let loaded=try store.load();precondition(loaded[0].id==migrated[0].id);let backup=try Data(contentsOf:file.appendingPathExtension("backup"));precondition(backup==legacy)
  let export=try SessionStore.exported(loaded);let restored=try SessionStore.decode(export);precondition(restored[0].id==loaded[0].id)
  var copy=loaded[0];copy.id=UUID();let duplicate=try SessionStore.merge([copy],into:loaded);precondition(duplicate.added==0 && duplicate.skipped==1)
  copy.group="changed";copy.favorite=true;let movedImport=try SessionStore.merge([copy],into:loaded);precondition(movedImport.added==0)
  copy.name="new";let merged=try SessionStore.merge([copy],into:loaded);precondition(merged.added==1 && merged.sessions.count==2)
  var invalid=copy;invalid.host="-bad";do {_ = try SessionStore.merge([invalid],into:loaded);fatalError("Invalid import must fail")}catch{}
  let changedVersion=String(decoding:export,as:UTF8.self).replacingOccurrences(of:"\"version\" : 1",with:"\"version\" : 99");do {_ = try SessionStore.decode(Data(changedVersion.utf8));fatalError("Unsupported archive version must fail")}catch{}
  try Data("broken".utf8).write(to:file);do {try store.save(loaded);fatalError("Broken source file must not be overwritten")}catch{};let preserved=try Data(contentsOf:file);precondition(preserved==Data("broken".utf8))
  let browser=SessionBrowser(frame:NSRect(x:0,y:0,width:260,height:300));var items=try SessionStore.normalize([Session(name:"Alpha",host:"alpha.invalid",user:"user",port:22,key:"",group:"生产"),Session(name:"Beta",host:"beta.invalid",user:"user",port:2200,key:"",group:"测试",favorite:true,lastUsed:Date())]);browser.reload(items)
  browser.search.stringValue="BETA.INVALID";browser.reload(items);let matches=browser.roots.flatMap{$0.children};precondition(!matches.isEmpty && matches.allSatisfy{$0.index==1})
  let selectedRow=(0..<browser.outline.numberOfRows).first{(browser.outline.item(atRow:$0) as? SessionNode)?.index==1}!;browser.outline.selectRowIndexes(IndexSet(integer:selectedRow),byExtendingSelection:false);precondition(browser.selectedIndex==1)
  items[1].group="新分组";browser.reload(items);precondition(browser.selectedIndex==1)
  browser.search.stringValue="不存在";browser.reload(items);precondition(browser.roots.isEmpty && browser.selectedIndex==nil)
  browser.search.stringValue="";browser.reload(items);precondition(browser.roots.flatMap{$0.children}.contains{$0.index==0})
  print("PASS: stale-instance and active-writer protection, reload revisions, deletion conflicts, private saves/backups, legacy migration, import/export and filtered selection")
 }
}
