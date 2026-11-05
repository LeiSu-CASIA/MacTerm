import Cocoa

enum ConnectionKind:String,Codable {case ssh,serial,telnet,ftp,vnc,rdp}
enum SerialParity:String,Codable,CaseIterable {case none,even,odd}
enum SerialFlow:String,Codable,CaseIterable {case none,hardware,software}
enum SerialLineEnding:String,Codable,CaseIterable {case cr,lf,crlf
 var text:String {switch self {case .cr:return "\r";case .lf:return "\n";case .crlf:return "\r\n"}}
}
struct SerialSettings:Codable,Equatable {
 var device:String;var baud=115200;var dataBits=8;var parity:SerialParity = .none;var stopBits=1;var flow:SerialFlow = .none;var lineEnding:SerialLineEnding = .cr;var localEcho=false
 static let rates=[300,600,1200,2400,4800,9600,19200,38400,57600,115200,230400]
 enum CodingKeys:String,CodingKey {case device,baud,dataBits,parity,stopBits,flow,lineEnding,localEcho}
 func validated()throws->SerialSettings {
  let name=String(device.dropFirst(5));let pseudo=name.range(of:"^ttys[0-9]{3,}$",options:.regularExpression) != nil
  guard device.hasPrefix("/dev/"),!name.contains("/"),name.hasPrefix("cu.") || name.hasPrefix("tty.") || pseudo,device.utf8.count<=1024,!device.unicodeScalars.contains(where:{$0.value<32 || $0.value==127}) else{throw SFTPError.message("请选择 /dev/cu.*、/dev/tty.* 或有效虚拟串口设备")}
  guard Self.rates.contains(baud),(5...8).contains(dataBits),(1...2).contains(stopBits) else{throw SFTPError.message("串口波特率、数据位或停止位无效")};return self
 }
 var arguments:[String] {[device,String(baud),String(dataBits),parity.rawValue,String(stopBits),flow.rawValue]}
 var summary:String {"\(device) · \(baud) baud · \(dataBits)\(parity == .none ? "N" : parity == .even ? "E" : "O")\(stopBits)"}
 func input(_ value:String)->String {value.replacingOccurrences(of:"\r",with:lineEnding.text)}
 func echo(_ value:String)->String {value.replacingOccurrences(of:"\r",with:"\r\n").replacingOccurrences(of:"\u{7f}",with:"\u{8} \u{8}")}
 static func devices()->[String] {((try? FileManager.default.contentsOfDirectory(atPath:"/dev")) ?? []).filter{$0.hasPrefix("cu.")}.sorted{$0.localizedStandardCompare($1) == .orderedAscending}.map{"/dev/"+$0}}
 static var helperURL:URL {Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("MacTermSerial")}
}
extension SerialSettings {
 init(from decoder:Decoder)throws {let c=try decoder.container(keyedBy:CodingKeys.self);self.init(device:try c.decode(String.self,forKey:.device),baud:try c.decodeIfPresent(Int.self,forKey:.baud) ?? 115200,dataBits:try c.decodeIfPresent(Int.self,forKey:.dataBits) ?? 8,parity:try c.decodeIfPresent(SerialParity.self,forKey:.parity) ?? .none,stopBits:try c.decodeIfPresent(Int.self,forKey:.stopBits) ?? 1,flow:try c.decodeIfPresent(SerialFlow.self,forKey:.flow) ?? .none,lineEnding:try c.decodeIfPresent(SerialLineEnding.self,forKey:.lineEnding) ?? .cr,localEcho:try c.decodeIfPresent(Bool.self,forKey:.localEcho) ?? false)}
}
extension Session {
 var connectionKind:ConnectionKind {kind ?? .ssh}
 var connectionSummary:String {if connectionKind == .rdp{return "RDP · "+rdpDestination};if connectionKind == .vnc{return "VNC · "+vncDestination};if connectionKind == .ftp{return (ftp?.security.title ?? "FTP")+" · "+user+"@"+(host.contains(":") ? "["+host+"]" : host)+":"+String(port)};if connectionKind == .serial {return serial?.summary ?? "串口设置缺失"};if connectionKind == .telnet {return "Telnet · "+telnetDestination};return "\(user.isEmpty ? "默认" : user)@\(host)\(port==0 ? "" : ":\(port)")"}
}

final class SerialFormBody:NSView {
 override var isFlipped:Bool {true}
 let name=NSTextField(),group=NSTextField(),device=NSComboBox();let refresh=NSButton(title:"刷新",target:nil,action:nil)
 let baud=NSPopUpButton(),bits=NSPopUpButton(),parity=NSPopUpButton(),stops=NSPopUpButton(),flow=NSPopUpButton(),ending=NSPopUpButton()
 let echo=NSButton(checkboxWithTitle:"本地回显（键入内容会显示在终端）",target:nil,action:nil)
 let labels=["会话名称","分组","设备路径","波特率","数据位","校验位","停止位","流控","回车键发送"].map{NSTextField(labelWithString:$0)}
 init(session:Session){super.init(frame:NSRect(x:0,y:0,width:640,height:366));autoresizingMask=[.width]
  let settings=session.serial ?? SerialSettings(device:SerialSettings.devices().first ?? "");name.stringValue=session.name;group.stringValue=session.group ?? "";device.addItems(withObjectValues:SerialSettings.devices());device.isEditable=true;device.completes=true;device.stringValue=settings.device;device.placeholderString="选择或输入 /dev/cu.* 设备";name.placeholderString="例如：开发板串口";group.placeholderString="User sessions"
  for (control,titles,index) in [(baud,SerialSettings.rates.map{String($0)},SerialSettings.rates.firstIndex(of:settings.baud) ?? 9),(bits,["5","6","7","8"],settings.dataBits-5),(parity,["无","偶校验","奇校验"],SerialParity.allCases.firstIndex(of:settings.parity)!),(stops,["1","2"],settings.stopBits-1),(flow,["无","RTS / CTS","XON / XOFF"],SerialFlow.allCases.firstIndex(of:settings.flow)!),(ending,["CR（\\r）","LF（\\n）","CRLF（\\r\\n）"],SerialLineEnding.allCases.firstIndex(of:settings.lineEnding)!)] {control.addItems(withTitles:titles);control.selectItem(at:index);addSubview(control)}
  echo.state=settings.localEcho ? .on : .off;for control in [name,group,device,refresh,echo] as [NSView] {addSubview(control)};for label in labels {label.font = .systemFont(ofSize:12);label.textColor=AppTheme.muted;addSubview(label)}
 }
 required init?(coder:NSCoder){fatalError()}
 override func layout(){super.layout();let gap:CGFloat=20,col=(bounds.width-gap)/2
  let positions:[(Int,NSView,CGFloat,CGFloat)]=[(0,name,0,0),(1,group,col+gap,0),(2,device,0,64),(3,baud,0,128),(4,bits,col+gap,128),(5,parity,0,192),(6,stops,col+gap,192),(7,flow,0,256),(8,ending,col+gap,256)]
  for(index,control,x,y) in positions {labels[index].frame=NSRect(x:x,y:y,width:index==2 ? bounds.width : col,height:18);control.frame=NSRect(x:x,y:y+23,width:index==2 ? bounds.width-72 : col,height:28)}
  refresh.frame=NSRect(x:bounds.width-66,y:87,width:66,height:28);echo.frame=NSRect(x:0,y:328,width:bounds.width,height:24)
 }
 func settings()throws->SerialSettings {try SerialSettings(device:device.stringValue.trimmingCharacters(in:.whitespacesAndNewlines),baud:SerialSettings.rates[baud.indexOfSelectedItem],dataBits:bits.indexOfSelectedItem+5,parity:SerialParity.allCases[parity.indexOfSelectedItem],stopBits:stops.indexOfSelectedItem+1,flow:SerialFlow.allCases[flow.indexOfSelectedItem],lineEnding:SerialLineEnding.allCases[ending.indexOfSelectedItem],localEcho:echo.state == .on).validated()}
}
final class SerialPanelContent:NSView {
 let heading=NSTextField(labelWithString:"串口会话"),subtitle=NSTextField(labelWithString:"仅选择设备不会打开串口，保存后点击连接。")
 let scroll=NSScrollView(),error=NSTextField(wrappingLabelWithString:"");let save=NSButton(title:"保存会话",target:nil,action:nil),cancel=NSButton(title:"取消",target:nil,action:nil);let body:SerialFormBody
 init(session:Session){body=SerialFormBody(session:session);super.init(frame:.zero);wantsLayer=true;layer?.backgroundColor=AppTheme.background.cgColor;heading.font = .systemFont(ofSize:23,weight:.semibold);subtitle.font = .systemFont(ofSize:12);subtitle.textColor=AppTheme.muted;scroll.drawsBackground=false;scroll.hasVerticalScroller=true;scroll.autohidesScrollers=true;scroll.documentView=body;error.textColor = .systemOrange;error.font = .systemFont(ofSize:11);save.keyEquivalent="\r";cancel.keyEquivalent="\u{1b}";for view in [heading,subtitle,scroll,error,save,cancel] as [NSView] {addSubview(view)}}
 required init?(coder:NSCoder){fatalError()}
 override func layout(){super.layout();let w=bounds.width,h=bounds.height;heading.frame=NSRect(x:26,y:h-56,width:w-52,height:30);subtitle.frame=NSRect(x:26,y:h-82,width:w-52,height:18);scroll.frame=NSRect(x:26,y:85,width:w-52,height:max(80,h-187));body.setFrameSize(NSSize(width:scroll.contentSize.width,height:366));body.needsLayout=true;error.frame=NSRect(x:26,y:28,width:max(150,w-270),height:42);cancel.frame=NSRect(x:w-232,y:32,width:90,height:32);save.frame=NSRect(x:w-134,y:32,width:108,height:32)}
}
final class SerialEditor:NSWindowController,NSWindowDelegate {
 let original:Session;let form:SerialPanelContent;var result:Session?
 init(session:Session){original=session;form=SerialPanelContent(session:session);let panel=NSPanel(contentRect:NSRect(x:0,y:0,width:700,height:600),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false);super.init(window:panel);panel.title="MacTerm · 串口会话";panel.appearance=NSAppearance(named:.darkAqua);panel.minSize=NSSize(width:620,height:440);panel.contentView=form;panel.delegate=self;panel.center();form.save.target=self;form.save.action = #selector(save);form.cancel.target=self;form.cancel.action = #selector(cancel);form.body.refresh.target=self;form.body.refresh.action = #selector(refreshDevices)}
 required init?(coder:NSCoder){fatalError()}
 func editedSession()throws->Session {let settings=try form.body.settings();let name=form.body.name.stringValue.trimmingCharacters(in:.whitespacesAndNewlines),group=form.body.group.stringValue.trimmingCharacters(in:.whitespacesAndNewlines);return try Session(name:name.isEmpty ? (settings.device as NSString).lastPathComponent : name,host:settings.device,user:"",port:0,key:"",id:original.id ?? UUID(),group:group.isEmpty ? nil : group,favorite:original.favorite,lastUsed:original.lastUsed,kind:.serial,serial:settings).validated()}
 func run()->Session? {guard let window=window else{return nil};window.makeKeyAndOrderFront(nil);window.layoutIfNeeded();window.makeFirstResponder(form.body.name);NSApp.runModal(for:window);window.delegate=nil;window.close();return result}
 @objc func save(){do{result=try editedSession();NSApp.stopModal(withCode:.OK)}catch{form.error.stringValue=error.localizedDescription}}
 @objc func cancel(){result=nil;NSApp.stopModal(withCode:.cancel)}
 func windowShouldClose(_ sender:NSWindow)->Bool{cancel();return false}
 @objc func refreshDevices(){let current=form.body.device.stringValue;form.body.device.removeAllItems();form.body.device.addItems(withObjectValues:SerialSettings.devices());form.body.device.stringValue=current;form.error.stringValue="设备列表已刷新，未打开任何设备。"}
}

extension AppDelegate {
 @objc func newSerialSession(){serialForm(index:nil)}
 func serialForm(index:Int?){let old=index.map{sessions[$0]} ?? Session(name:"",host:"",user:"",port:0,key:"",id:UUID(),group:sessionBrowser.selectedGroup,kind:.serial,serial:SerialSettings(device:""));guard let value=SerialEditor(session:old).run() else{return};let before=sessions;if let index=index {sessions[index]=value}else{sessions.append(value)};if !persist(){sessions=before;sessionBrowser.reload(sessions)}}
 func openSerial(_ input:Session){do{_ = try input.validated();guard input.connectionKind == .serial,let settings=input.serial else{throw SFTPError.message("请选择串口会话")};let helper=SerialSettings.helperURL;guard FileManager.default.isExecutableFile(atPath:helper.path) else{throw SFTPError.message("串口组件缺失，请重新安装 MacTerm")};let session=recordRecent(input);let pane=TerminalPane(path:helper.path,args:settings.arguments,preferences:savedTerminalPreferences);pane.serialSettings=settings;watchLogging(pane);let item=NSTabViewItem(identifier:UUID().uuidString);item.label=session.name;item.view=pane;tabs.addTabViewItem(item);tabs.selectTabViewItem(item);updateTabStrip()}catch{alert(error.localizedDescription)}}
 func newConnectionButton()->NSButton {let popup=NSPopUpButton(frame:.zero,pullsDown:true);let menu=NSMenu();menu.addItem(withTitle:"新建会话",action:nil,keyEquivalent:"");for(title,action) in [("SSH 会话…",#selector(newSession)),("VNC 远程桌面…",#selector(newVNCSession)),("RDP 远程桌面…",#selector(newRDPSession)),("Telnet 会话…",#selector(newTelnetSession)),("FTP / FTPS 会话…",#selector(newFTPSession)),("串口会话…",#selector(newSerialSession))] {let item=menu.addItem(withTitle:title,action:action,keyEquivalent:"");item.target=self};popup.menu=menu;return popup}
}
