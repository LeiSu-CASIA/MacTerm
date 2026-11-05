import Cocoa
@main struct WorkspaceTabsTests {
 static func main()throws {
  _ = NSApplication.shared
  let app=AppDelegate(storage:URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString))
  let items=(0..<4).map{index->NSTabViewItem in let item=NSTabViewItem(identifier:UUID().uuidString);item.label="tab-\(index)";item.view=NSView();app.tabs.addTabViewItem(item);return item}
  let views=items.map{$0.view!};app.tabs.selectTabViewItem(items[1]);app.updateTabStrip()
  precondition(app.moveTab(items[0],toInsertion:4));precondition(app.tabs.tabViewItems.elementsEqual([items[1],items[2],items[3],items[0]],by:{$0 === $1}));precondition(app.tabs.selectedTabViewItem === items[1])
  precondition(app.moveTab(items[0],toInsertion:0));precondition(app.tabs.tabViewItems.elementsEqual(items,by:{$0 === $1}));precondition(app.tabs.selectedTabViewItem === items[1])
  precondition(app.moveTab(items[1],toInsertion:4));precondition(app.tabs.selectedTabViewItem === items[1]);precondition(items.enumerated().allSatisfy{$0.element.view === views[$0.offset]})
  let order=app.tabs.tabViewItems;precondition(!app.moveTab(items[0],toInsertion:-1) && !app.moveTab(items[0],toInsertion:5));precondition(app.tabs.tabViewItems.elementsEqual(order,by:{$0 === $1}))
  try app.renameTab(items[1],to:"  生产日志 · 中文  ");precondition(items[1].label=="生产日志 · 中文")
  for invalid in ["",String(repeating:"x",count:81),"one\ntwo","escape\u{1b}"] {do{try app.renameTab(items[1],to:invalid);fatalError("Invalid tab title accepted")}catch{}}
  let first=app.tabs.tabViewItems.first!,last=app.tabs.tabViewItems.last!
  precondition(!app.tabContextMenu(first).items[1].isEnabled && !app.tabContextMenu(last).items[2].isEnabled)
  let menu=app.tabContextMenu(items[2]);let move=menu.items[2];app.moveTabRight(move);precondition(app.tabs.tabViewItems[2] === items[2]);app.moveTabRight(move);precondition(app.tabs.tabViewItems.last === items[2]);precondition(app.tabs.selectedTabViewItem === items[1])
  let stale=NSTabViewItem(identifier:UUID().uuidString);stale.view=NSView();precondition(!app.moveTab(stale,toInsertion:0));do{try app.renameTab(stale,to:"closed");fatalError("A stale item must not rename another tab")}catch{}
  let staleButton=WorkspaceTabButton();staleButton.tabItem=stale;staleButton.tag=0;let selected=app.tabs.selectedTabViewItem;app.selectTab(staleButton);precondition(app.tabs.selectedTabViewItem === selected)
  let before=app.tabs.tabViewItems;let staleAction=NSMenuItem();staleAction.representedObject=stale;app.moveTabRight(staleAction);app.moveTabLeft(staleAction);app.closeTabFromMenu(staleAction);precondition(app.tabs.tabViewItems.elementsEqual(before,by:{$0 === $1}))
  precondition(app.tabStrip.arrangedSubviews.compactMap{$0 as? WorkspaceTabButton}.count==4)
  print("PASS: reorder preserves current selection and live views, move boundaries, contextual actions target stable tab identity, stale actions ignored, Unicode rename validation")
 }
}
