import Cocoa
import WebKit

enum TerminalFont:String,Codable,CaseIterable {
 case menlo,monaco,courier
 var title:String {switch self {case .menlo:return "Menlo";case .monaco:return "Monaco";case .courier:return "Courier New"}}
 var css:String {switch self {case .menlo:return "Menlo, monospace";case .monaco:return "Monaco, monospace";case .courier:return "'Courier New', monospace"}}
}
enum TerminalCursor:String,Codable,CaseIterable {case block,bar,underline
 var title:String {switch self {case .block:return "方块";case .bar:return "竖线";case .underline:return "下划线"}}
}
enum TerminalTheme:String,Codable,CaseIterable {
 case graphite,ocean,forest,paper
 var title:String {switch self {case .graphite:return "石墨（默认）";case .ocean:return "深海";case .forest:return "墨绿";case .paper:return "暖纸（浅色）"}}
 var background:UInt32 {switch self {case .graphite:return 0x10151f;case .ocean:return 0x0b1622;case .forest:return 0x0d1d1a;case .paper:return 0xf6f4ee}}
 var palette:[String:String] {
  let foreground:UInt32,accent:UInt32,selection:UInt32,colors:[UInt32]
  switch self {
  case .graphite:foreground=0xdce5f3;accent=0x70decb;selection=0x304b59;colors=[0x243044,0xf38ba8,0xa6da95,0xeed49f,0x8aadf4,0xc6a0f6,0x70decb,0xdce5f3,0x67758c,0xf5a1b7,0xb9e5a9,0xf4deb2,0xa3bdfa,0xd5b7fa,0x98e7db,0xffffff]
  case .ocean:foreground=0xd6e6f4;accent=0x7dd3fc;selection=0x28465e;colors=[0x20334a,0xfca5a5,0x86efac,0xfde68a,0x93c5fd,0xc4b5fd,0x67e8f9,0xd6e6f4,0x7188a3,0xfecaca,0xbbf7d0,0xfef3c7,0xbfdbfe,0xddd6fe,0xa5f3fc,0xffffff]
  case .forest:foreground=0xd0e1db;accent=0x8ad9b2;selection=0x294e43;colors=[0x233c33,0xe99c9c,0x8ad9b2,0xe6d29a,0x94bcdc,0xc2a6d8,0x8bd5ce,0xd0e1db,0x758e83,0xf2bbbb,0xb3e8cc,0xf2e3b7,0xb7d3e8,0xd6bfe8,0xb0e8df,0xf3faf6]
  case .paper:foreground=0x26313e;accent=0x157f7b;selection=0xd8e7e2;colors=[0x26313e,0xa23239,0x2d6b3e,0x936000,0x1f5ca8,0x7a48a3,0x13727a,0x687480,0x697581,0xbd4148,0x397c4d,0xa57016,0x3074bc,0x9160b6,0x25868b,0x17232f]
  }
  var result=["background":Self.hex(background),"foreground":Self.hex(foreground),"cursor":Self.hex(accent),"cursorAccent":Self.hex(background),"selectionBackground":Self.hex(selection),"selectionForeground":Self.hex(foreground)]
  let names=["black","red","green","yellow","blue","magenta","cyan","white","brightBlack","brightRed","brightGreen","brightYellow","brightBlue","brightMagenta","brightCyan","brightWhite"]
  for (name,color) in zip(names,colors){result[name]=Self.hex(color)};return result
 }
 var ui:[String:String] {let colors:[UInt32]=self == .paper ? [0xebe9e1,0xc7cec8,0x586763,0xffffff,0xb8c7c1] : self == .forest ? [0x18312a,0x36564a,0x9db6aa,0x10251e,0x486a5b] : self == .ocean ? [0x192d43,0x36516d,0x9db3cd,0x101e30,0x36516d] : [0x202b3c,0x34445a,0xaab9ce,0x141c29,0x334155];return Dictionary(uniqueKeysWithValues:zip(["panelBackground","panelBorder","muted","fieldBackground","scrollThumb"],colors.map{Self.hex($0)}))}
 private static func hex(_ value:UInt32)->String {String(format:"#%06x",value)}
}
struct TerminalPreferences:Codable,Equatable {
 var theme:TerminalTheme = .graphite,font:TerminalFont = .menlo,fontSize=14,lineHeight=1.18,scrollback=10000,cursor:TerminalCursor = .block,cursorBlink=true
 func validated()throws->TerminalPreferences {guard (9...32).contains(fontSize),lineHeight.isFinite,(1...2).contains(lineHeight),(0...100000).contains(scrollback) else{throw SFTPError.message("字号为 9–32，行高为 1–2，滚动记录为 0–100000 行")};return self}
 func renderingData()throws->Data {_ = try validated();return try JSONSerialization.data(withJSONObject:["theme":theme.palette,"ui":theme.ui,"colorScheme":theme == .paper ? "light" : "dark","fontFamily":font.css,"fontSize":fontSize,"lineHeight":lineHeight,"scrollback":scrollback,"cursorStyle":cursor.rawValue,"cursorBlink":cursorBlink] as [String:Any],options:[.sortedKeys])}
 func startupScript()throws->String {"window.initialTerminalPreferences=JSON.parse(atob('"+(try renderingData()).base64EncodedString()+"'));"}
 func renderingScript()throws->String {"applyTerminalPreferences(JSON.parse(atob('"+(try renderingData()).base64EncodedString()+"')))"}
}
struct TerminalPreferencesArchive:Codable {let version:Int;let settings:TerminalPreferences}
struct TerminalPreferencesStore {
 static let key="terminalPreferences.v1"
 let defaults:UserDefaults
 init(defaults:UserDefaults = .standard){self.defaults=defaults}
 func load()->(settings:TerminalPreferences,issue:String?) {
  var fallback=TerminalPreferences();if let old=defaults.object(forKey:"terminalFontSize") as? Int,(9...32).contains(old){fallback.fontSize=old}
  guard let object=defaults.object(forKey:Self.key) else{return(fallback,nil)}
  do{guard let data=object as? Data,data.count<=8192 else{throw SFTPError.message("设置数据无效")};let archive=try JSONDecoder().decode(TerminalPreferencesArchive.self,from:data);guard archive.version==1 else{throw SFTPError.message("设置版本不支持")};return(try archive.settings.validated(),nil)}catch{return(fallback,"原终端设置无法读取，当前显示默认值。保存后替换原设置。")}
 }
 func save(_ settings:TerminalPreferences)throws {_ = try settings.validated();let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys];let data=try encoder.encode(TerminalPreferencesArchive(version:1,settings:settings));defaults.set(data,forKey:Self.key);defaults.set(settings.fontSize,forKey:"terminalFontSize")}
}

final class TerminalPreferencesPreview:NSView,WKScriptMessageHandler,WKNavigationDelegate {
 var web:WKWebView!;private(set) var ready=false;var preferences=TerminalPreferences();private var stopped=false
 init(settings:TerminalPreferences=TerminalPreferences(),resourceURL:URL?=nil){preferences=settings;super.init(frame:.zero);let config=WKWebViewConfiguration();if let source=try? settings.startupScript(){config.userContentController.addUserScript(WKUserScript(source:source,injectionTime:.atDocumentStart,forMainFrameOnly:true))};config.websiteDataStore = .nonPersistent();config.userContentController.add(self,name:"bridge");web=WKWebView(frame:bounds,configuration:config);web.autoresizingMask=[.width,.height];web.navigationDelegate=self;web.underPageBackgroundColor=AppTheme.terminal;addSubview(web);let file=resourceURL ?? Bundle.main.resourceURL!.appendingPathComponent("terminal.html");web.loadFileURL(file,allowingReadAccessTo:file.deletingLastPathComponent())}
 required init?(coder:NSCoder){fatalError()}
 func update(_ settings:TerminalPreferences){guard !stopped,(try? settings.validated()) != nil else{return};preferences=settings;web.underPageBackgroundColor=AppTheme.color(settings.theme.background);if ready,let script=try? settings.renderingScript(){web.evaluateJavaScript(script,completionHandler:nil)}}
 func userContentController(_ userContentController:WKUserContentController,didReceive message:WKScriptMessage){guard !stopped,(message.body as? [String:Any])?["type"] as? String == "ready" else{return};ready=true;web.evaluateJavaScript("terminal.options.disableStdin=true",completionHandler:nil);update(preferences);let sample="MacTerm · 示例预览 / English\r\n\u{1b}[32muser\u{1b}[0m@\u{1b}[34mserver\u{1b}[0m:~$ ls -lah\r\n\u{1b}[34mDocuments/\u{1b}[0m  \u{1b}[36mcurrent -> releases/\u{1b}[0m\r\n\u{1b}[32m✓ connected\u{1b}[0m  \u{1b}[33mnotice\u{1b}[0m  \u{1b}[31merror\u{1b}[0m\r\n中文字符、1234567890、{} [] ()\r\n$ ";web.evaluateJavaScript("receive('"+Data(sample.utf8).base64EncodedString()+"')",completionHandler:nil)}
 func webView(_ webView:WKWebView,decidePolicyFor navigationAction:WKNavigationAction,decisionHandler:@escaping(WKNavigationActionPolicy)->Void){decisionHandler(navigationAction.request.url?.isFileURL == true ? .allow : .cancel)}
 func stop(){guard !stopped else{return};stopped=true;web.stopLoading();web.configuration.userContentController.removeScriptMessageHandler(forName:"bridge")}
}
final class TerminalPreferencesEditor:NSWindowController,NSWindowDelegate,NSTextFieldDelegate {
 let theme=NSPopUpButton(),font=NSPopUpButton(),cursor=NSPopUpButton();let size=NSTextField(),lineHeight=NSTextField(),scrollback=NSTextField();let blink=NSButton(checkboxWithTitle:"光标闪烁",target:nil,action:nil)
 let preview:TerminalPreferencesPreview;let status=NSTextField(wrappingLabelWithString:"");let saveButton=NSButton(title:"保存并应用",target:nil,action:nil),cancelButton=NSButton(title:"取消",target:nil,action:nil),resetButton=NSButton(title:"恢复默认",target:nil,action:nil);var result:TerminalPreferences?
 init(settings:TerminalPreferences,issue:String?=nil,resourceURL:URL?=nil){preview=TerminalPreferencesPreview(settings:settings,resourceURL:resourceURL);let panel=NSPanel(contentRect:NSRect(x:0,y:0,width:740,height:700),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false);super.init(window:panel);panel.title="MacTerm · 终端设置";panel.appearance=NSAppearance(named:.darkAqua);panel.backgroundColor=AppTheme.background;panel.titlebarAppearsTransparent=true;panel.minSize=NSSize(width:680,height:650);panel.delegate=self;panel.center()
  let root=NSStackView();root.orientation = .vertical;root.alignment = .leading;root.spacing=10;root.edgeInsets=NSEdgeInsets(top:24,left:26,bottom:24,right:26);root.translatesAutoresizingMaskIntoConstraints=false;panel.contentView!.addSubview(root);NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:panel.contentView!.leadingAnchor),root.trailingAnchor.constraint(equalTo:panel.contentView!.trailingAnchor),root.topAnchor.constraint(equalTo:panel.contentView!.topAnchor),root.bottomAnchor.constraint(equalTo:panel.contentView!.bottomAnchor)])
  let heading=NSTextField(labelWithString:"终端外观与滚动记录");heading.font = .systemFont(ofSize:22,weight:.semibold);root.addArrangedSubview(heading);let hint=NSTextField(wrappingLabelWithString:"下方预览使用示例内容；保存后应用所有终端，新标签沿用设置。\n降低滚动记录行数会裁剪旧内容。");hint.font = .systemFont(ofSize:12);hint.textColor=AppTheme.muted;root.addArrangedSubview(hint);hint.widthAnchor.constraint(equalTo:root.widthAnchor,constant:-52).isActive=true
  theme.addItems(withTitles:TerminalTheme.allCases.map{$0.title});font.addItems(withTitles:TerminalFont.allCases.map{$0.title});cursor.addItems(withTitles:TerminalCursor.allCases.map{$0.title})
  func grid(_ values:[(String,NSView)])->NSGridView {let grid=NSGridView(views:values.map{title,view in let label=NSTextField(labelWithString:title);label.font = .systemFont(ofSize:12);label.textColor=AppTheme.muted;return [label,view]});grid.rowSpacing=12;grid.columnSpacing=12;grid.column(at:0).width=60;grid.column(at:0).xPlacement = .trailing;grid.column(at:1).xPlacement = .fill;return grid}
  let left=grid([("终端主题",theme),("字号",size),("滚动行数",scrollback)]),right=grid([("字体",font),("行高",lineHeight),("光标形状",cursor)]);let forms=NSStackView(views:[left,right]);forms.spacing=24;forms.alignment = .top;root.addArrangedSubview(forms);forms.widthAnchor.constraint(equalTo:root.widthAnchor,constant:-52).isActive=true;left.widthAnchor.constraint(equalTo:right.widthAnchor).isActive=true
  for field in [size,lineHeight,scrollback] {field.font = .monospacedSystemFont(ofSize:13,weight:.regular);field.bezelStyle = .roundedBezel;field.backgroundColor=AppTheme.input;field.textColor=AppTheme.text;field.heightAnchor.constraint(equalToConstant:28).isActive=true;field.delegate=self};size.setAccessibilityLabel("终端字号，9 至 32");lineHeight.setAccessibilityLabel("终端行高，1 至 2");scrollback.setAccessibilityLabel("滚动记录，0 至 100000 行");root.addArrangedSubview(blink)
  let label=NSTextField(labelWithString:"示例预览");label.font = .systemFont(ofSize:11,weight:.medium);label.textColor=AppTheme.muted;root.addArrangedSubview(label);root.addArrangedSubview(preview);preview.widthAnchor.constraint(equalTo:root.widthAnchor,constant:-52).isActive=true;preview.heightAnchor.constraint(greaterThanOrEqualToConstant:120).isActive=true;preview.setContentHuggingPriority(.init(1),for:.vertical)
  status.font = .systemFont(ofSize:11);status.textColor = .systemOrange;root.addArrangedSubview(status);status.widthAnchor.constraint(equalTo:root.widthAnchor,constant:-52).isActive=true;status.heightAnchor.constraint(greaterThanOrEqualToConstant:28).isActive=true;let spacer=NSView();spacer.setContentHuggingPriority(.init(1),for:.horizontal);let actions=NSStackView(views:[resetButton,spacer,cancelButton,saveButton]);actions.spacing=10;root.addArrangedSubview(actions);actions.widthAnchor.constraint(equalTo:root.widthAnchor,constant:-52).isActive=true
  for button in [resetButton,cancelButton,saveButton]{button.bezelStyle = .rounded};saveButton.bezelColor=AppTheme.accent;saveButton.contentTintColor=AppTheme.background;saveButton.keyEquivalent="\r";cancelButton.keyEquivalent="\u{1b}"
  for (control,action) in [(theme,#selector(optionsChanged)),(font,#selector(optionsChanged)),(cursor,#selector(optionsChanged)),(blink,#selector(optionsChanged)),(resetButton,#selector(resetDefaults)),(cancelButton,#selector(cancel)),(saveButton,#selector(save))] as [(NSControl,Selector)] {control.target=self;control.action=action}
  fill(settings);status.stringValue=issue ?? "保存后立即生效；当前连接保持打开。"
 }
 required init?(coder:NSCoder){fatalError()}
 private func fill(_ value:TerminalPreferences){theme.selectItem(at:TerminalTheme.allCases.firstIndex(of:value.theme)!);font.selectItem(at:TerminalFont.allCases.firstIndex(of:value.font)!);cursor.selectItem(at:TerminalCursor.allCases.firstIndex(of:value.cursor)!);size.stringValue=String(value.fontSize);lineHeight.stringValue=String(value.lineHeight);scrollback.stringValue=String(value.scrollback);blink.state=value.cursorBlink ? .on : .off;optionsChanged()}
 func edited()throws->TerminalPreferences {guard let size=Int(size.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)),let height=Double(lineHeight.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)),let lines=Int(scrollback.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)) else{throw SFTPError.message("字号和滚动行数使用整数，行高使用数字（例如 1.18）")};return try TerminalPreferences(theme:TerminalTheme.allCases[theme.indexOfSelectedItem],font:TerminalFont.allCases[font.indexOfSelectedItem],fontSize:size,lineHeight:height,scrollback:lines,cursor:TerminalCursor.allCases[cursor.indexOfSelectedItem],cursorBlink:blink.state == .on).validated()}
 @objc func optionsChanged(){do{let value=try edited();preview.update(value);saveButton.isEnabled=true;status.stringValue="保存后立即生效；降低滚动行数会裁剪旧内容。"}catch{saveButton.isEnabled=false;status.stringValue=error.localizedDescription}}
 func controlTextDidChange(_ notification:Notification){optionsChanged()}
 @objc func resetDefaults(){fill(TerminalPreferences());status.stringValue="默认值已载入预览，保存后生效。"}
 @objc func save(){do{result=try edited();NSApp.stopModal(withCode:.OK)}catch{status.stringValue=error.localizedDescription}}
 @objc func cancel(){result=nil;NSApp.stopModal(withCode:.cancel)}
 func run()->TerminalPreferences? {guard let window=window else{return nil};window.makeKeyAndOrderFront(nil);window.layoutIfNeeded();NSApp.runModal(for:window);window.delegate=nil;close();return result}
 func windowShouldClose(_ sender:NSWindow)->Bool{cancel();return false}
 override func close(){preview.stop();super.close()}
}
extension AppDelegate {
 var savedTerminalPreferences:TerminalPreferences {preferencesStore.load().settings}
 func saveTerminalPreferences(_ settings:TerminalPreferences)throws {try preferencesStore.save(settings);for pane in allTerminals{try pane.applyPreferences(settings)}}
 @objc func openTerminalPreferences(){if let editor=preferencesEditor{editor.window?.makeKeyAndOrderFront(nil);return};let loaded=preferencesStore.load();let editor=TerminalPreferencesEditor(settings:loaded.settings,issue:loaded.issue);preferencesEditor=editor;defer{preferencesEditor=nil};if let settings=editor.run(){do{try saveTerminalPreferences(settings)}catch{alert("终端设置保存失败："+error.localizedDescription)}}}
}
