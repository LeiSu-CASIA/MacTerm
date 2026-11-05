import Cocoa

final class WorkspaceTabCell:NSButtonCell {
 override func drawInterior(withFrame cellFrame:NSRect,in controlView:NSView){super.drawInterior(withFrame:cellFrame.insetBy(dx:12,dy:0),in:controlView)}
}
final class WorkspaceTabButton:NSButton {
 var baseTooltip=""
 var connectionStatus=WorkspaceConnectionStatus(phase:.unknown,text:"",detail:""){didSet{needsDisplay=true}}
 override init(frame:NSRect){super.init(frame:frame);cell=WorkspaceTabCell(textCell:"")}
 required init?(coder:NSCoder){fatalError()}
 weak var owner:AppDelegate?
 var tabItem:NSTabViewItem?
 var isCurrent=false
 private var hoverArea:NSTrackingArea?
 private var hovering=false
 override func updateTrackingAreas(){if let area=hoverArea {removeTrackingArea(area)};let area=NSTrackingArea(rect:.zero,options:[.mouseEnteredAndExited,.activeInKeyWindow,.inVisibleRect],owner:self,userInfo:nil);addTrackingArea(area);hoverArea=area;super.updateTrackingAreas()}
 override func mouseEntered(with event:NSEvent){hovering=true;needsDisplay=true}
 override func mouseExited(with event:NSEvent){hovering=false;needsDisplay=true}
 override func draw(_ dirtyRect:NSRect){if hovering && !isCurrent {AppTheme.surface.setFill();NSBezierPath(roundedRect:bounds.insetBy(dx:1,dy:1),xRadius:8,yRadius:8).fill()};super.draw(dirtyRect);if connectionStatus.phase != .unknown {connectionStatus.color.setFill();NSBezierPath(ovalIn:NSRect(x:5,y:(bounds.height-5)/2,width:5,height:5)).fill()};if isCurrent {AppTheme.accent.setFill();NSBezierPath(roundedRect:NSRect(x:14,y:0,width:max(0,bounds.width-28),height:2),xRadius:1,yRadius:1).fill()}}
 override func mouseDown(with event:NSEvent){
  guard let window=window,let strip=superview as? WorkspaceTabStrip else{return}
  if event.clickCount==2,let item=tabItem {owner?.requestTabRename(item);return}
  let origin=event.locationInWindow;var dragging=false
  defer{alphaValue=1;strip.hideInsertion()}
  while let next=window.nextEvent(matching:[.leftMouseDragged,.leftMouseUp]) {
   let point=next.locationInWindow
   if hypot(point.x-origin.x,point.y-origin.y)>5 {dragging=true}
   if dragging {alphaValue=0.55;strip.showInsertion(at:point);_ = strip.autoscroll(with:next)}
   if next.type == .leftMouseUp {
    if dragging {if let item=tabItem {strip.move(item,at:point)}}
    else {performClick(nil)}
    return
   }
  }
 }
}

final class WorkspaceTabStrip:NSStackView {
 weak var owner:AppDelegate?
 private let indicator=CALayer()
 override init(frame:NSRect){super.init(frame:frame);wantsLayer=true;indicator.backgroundColor=AppTheme.accent.cgColor;indicator.cornerRadius=1;indicator.isHidden=true;layer?.addSublayer(indicator)}
 required init?(coder:NSCoder){fatalError()}
 var tabButtons:[WorkspaceTabButton] {arrangedSubviews.compactMap{$0 as? WorkspaceTabButton}}
 func insertionIndex(atX x:CGFloat)->Int {tabButtons.prefix{$0.frame.midX<x}.count}
 func showInsertion(at windowPoint:NSPoint){
  let point=convert(windowPoint,from:nil);guard bounds.contains(point) else{hideInsertion();return}
  let buttons=tabButtons;let index=insertionIndex(atX:point.x)
  let x=index<buttons.count ? buttons[index].frame.minX-4 : (buttons.last?.frame.maxX ?? 0)+22
  CATransaction.begin();CATransaction.setDisableActions(true);indicator.frame=NSRect(x:max(1,min(bounds.width-3,x)),y:7,width:2,height:max(1,bounds.height-14));indicator.isHidden=false;CATransaction.commit()
 }
 func hideInsertion(){indicator.isHidden=true}
 @discardableResult func move(_ item:NSTabViewItem,at windowPoint:NSPoint)->Bool {
  let point=convert(windowPoint,from:nil);guard bounds.contains(point),let owner=owner else{return false}
  return owner.moveTab(item,toInsertion:insertionIndex(atX:point.x))
 }
}

extension AppDelegate {
 @discardableResult func moveTab(_ item:NSTabViewItem,toInsertion insertion:Int)->Bool {
  let index=tabs.indexOfTabViewItem(item);guard index != NSNotFound,(0...tabs.numberOfTabViewItems).contains(insertion) else{return false}
  let target=insertion>index ? insertion-1 : insertion;guard target != index else{return true}
  let selected=tabs.selectedTabViewItem
  tabs.removeTabViewItem(item);tabs.insertTabViewItem(item,at:target)
  if let selected=selected {tabs.selectTabViewItem(selected)}
  updateTabStrip();return true
 }
 func renameTab(_ item:NSTabViewItem,to name:String)throws {
  guard tabs.indexOfTabViewItem(item) != NSNotFound else{throw SFTPError.message("该标签已关闭")}
  let value=name.trimmingCharacters(in:.whitespacesAndNewlines)
  guard !value.isEmpty,value.count<=80,!value.unicodeScalars.contains(where:{$0.value<32 || $0.value==127}) else{throw SFTPError.message("标签名称需为 1–80 个字符，不能含控制字符")}
  item.label=value;updateTabStrip()
 }
 func requestTabRename(_ item:NSTabViewItem){
  guard tabs.indexOfTabViewItem(item) != NSNotFound else{return}
  let alert=NSAlert();alert.messageText="重命名标签";alert.informativeText="只修改当前标签名称，会话配置保持原样。";alert.addButton(withTitle:"保存");alert.addButton(withTitle:"取消");alert.window.appearance=NSAppearance(named:.darkAqua)
  let field=NSTextField(frame:NSRect(x:0,y:0,width:300,height:26));field.stringValue=item.label;alert.accessoryView=field;alert.window.initialFirstResponder=field
  guard alert.runModal() == .alertFirstButtonReturn else{return}
  do{try renameTab(item,to:field.stringValue)}catch{self.alert(error.localizedDescription)}
 }
 func tabContextMenu(_ item:NSTabViewItem)->NSMenu {
  let menu=NSMenu();menu.autoenablesItems=false
  let index=tabs.indexOfTabViewItem(item)
  for(title,selector,enabled) in [("重命名标签…",#selector(renameTabFromMenu(_:)),true),("向左移动",#selector(moveTabLeft(_:)),index>0),("向右移动",#selector(moveTabRight(_:)),index<tabs.numberOfTabViewItems-1)] {
   let entry=menu.addItem(withTitle:title,action:selector,keyEquivalent:"");entry.target=self;entry.representedObject=item;entry.isEnabled=enabled
  }
  menu.addItem(.separator());let close=menu.addItem(withTitle:"关闭标签",action:#selector(closeTabFromMenu(_:)),keyEquivalent:"");close.target=self;close.representedObject=item;return menu
 }
 @objc func renameTabFromMenu(_ sender:NSMenuItem){if let item=sender.representedObject as? NSTabViewItem {requestTabRename(item)}}
 @objc func moveTabLeft(_ sender:NSMenuItem){guard let item=sender.representedObject as? NSTabViewItem else{return};let index=tabs.indexOfTabViewItem(item);guard index != NSNotFound,index>0 else{return};moveTab(item,toInsertion:index-1)}
 @objc func moveTabRight(_ sender:NSMenuItem){guard let item=sender.representedObject as? NSTabViewItem else{return};let index=tabs.indexOfTabViewItem(item);guard index != NSNotFound,index<tabs.numberOfTabViewItems-1 else{return};moveTab(item,toInsertion:index+2)}
 @objc func closeTabFromMenu(_ sender:NSMenuItem){guard let item=sender.representedObject as? NSTabViewItem,tabs.indexOfTabViewItem(item) != NSNotFound else{return};tabs.selectTabViewItem(item);updateTabStrip();closeTab()}
}
