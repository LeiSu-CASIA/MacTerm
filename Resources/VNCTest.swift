import Cocoa
import WebKit
@main struct VNCTests {
 static func wait(_ description:String,seconds:Double=12,_ predicate:()->Bool)throws {let end=Date().addingTimeInterval(seconds);while !predicate() && Date()<end{RunLoop.current.run(until:Date().addingTimeInterval(0.005))};guard predicate() else{throw SFTPError.message("VNC test timeout: "+description)}}
 static func js(_ web:WKWebView,_ script:String)throws->Any {var done=false,value:Any?,error:Error?;web.evaluateJavaScript(script){value=$0;error=$1;done=true};try wait("JavaScript"){done};if let error=error{throw error};return value ?? NSNull()}
 static func rejects(_ body:()throws->Void){do{try body();fatalError("Invalid VNC accepted")}catch{}}
 static func main()throws {
  _ = NSApplication.shared;setbuf(stdout,nil)
  let base=try Session.quickVNC("vnc://host.invalid");precondition(base.port==5900 && base.connectionKind == .vnc)
  for input in ["vnc://[::1]:5901","vnc://host.invalid:5900"]{_ = try Session.quickVNC(input)}
  for input in ["vnc://user:password@host","vnc://host/path","vnc://host?password=x","vnc://host:0","vnc://bad:ipv6:address","vnc://[::1%lo0]","ssh://host"]{rejects{_ = try Session.quickVNC(input)}}
  var v=base;v.vnc=VNCSettings(viewOnly:true);v.user="用户名";v.id=UUID();v.group="桌面";let data=try JSONEncoder().encode(v);let round=try JSONDecoder().decode(Session.self,from:data);precondition(round.vnc?.viewOnly==true && round.id==v.id && round.fingerprint != base.fingerprint)
  var mixed=v;mixed.kind = .ssh;rejects{_ = try mixed.validated()};mixed=v;mixed.serial=SerialSettings(device:"/dev/cu.test");rejects{_ = try mixed.validated()};mixed=v;mixed.jumpHost="jump";rejects{_ = try mixed.validated()};mixed=v;mixed.port=65536;rejects{_ = try mixed.validated()}
  let editor=VNCEditor(session:v);editor.window?.layoutIfNeeded();editor.window?.contentView?.layoutSubtreeIfNeeded();for field in [editor.name,editor.host,editor.port,editor.user,editor.group,editor.timeout] {let rect=field.convert(field.bounds,to:editor.window!.contentView!);precondition(editor.window!.contentView!.bounds.contains(rect) && rect.width>200 && rect.height>=26)};let edited=try editor.edited();precondition(edited.id==v.id && edited.vnc?.viewOnly==true && edited.user==v.user);editor.window?.delegate=nil;editor.close()
  print("PASS: VNC saved profiles, IPv6/default ports, address credential rejection, mixed-protocol rejection and editor round trip")
  guard CommandLine.arguments.contains("--renderer") else{return}
  let root=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("macterm-vnc-test-"+UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
  let resource=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/MacTerm.app/Contents/Resources/vnc.html")
  for mode in ["none","auth","wrong","resize","viewOnly","oversize","pixelcap","earlyclose","unsupported","timeout","cancel"] {
   let dir=root.appendingPathComponent(mode);try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true);let server=Process();server.executableURL=URL(fileURLWithPath:"/usr/bin/python3");server.arguments=["Tests/vnc_server.py",dir.path,mode];let stderr=Pipe();server.standardError=stderr;server.standardOutput=FileHandle.nullDevice;try server.run();defer{if server.isRunning{server.terminate()};server.waitUntilExit()}
   try wait("fixture port"){(try? String(contentsOf:dir.appendingPathComponent("port"))).flatMap{Int($0)}.map{(1...65535).contains($0)} == true};var profile=base;profile.host="127.0.0.1";profile.port=Int(try String(contentsOf:dir.appendingPathComponent("port")))!;profile.connectionTimeout=mode=="timeout" ? 2 : 10;profile.vnc=VNCSettings(viewOnly:mode=="viewOnly")
   var requests=0;let pane=VNCWorkspace(session:profile,resourceURL:resource,credentialsProvider:{types in requests+=1;precondition(types==["password"]);return ["password":"TestPass"]});let window=NSWindow(contentRect:NSRect(x:0,y:0,width:800,height:520),styleMask:[.titled],backing:.buffered,defer:false);window.contentView=pane;window.layoutIfNeeded();defer{pane.stop();window.close()}
   var hadConnected=false;pane.onStateChanged={if $0 == .connected{hadConnected=true}}
   func events()->[[String:Any]] {let value=(try? String(contentsOf:dir.appendingPathComponent("events.jsonl"))) ?? "";return value.split(separator:"\n").compactMap{(try? JSONSerialization.jsonObject(with:Data($0.utf8))) as? [String:Any]}}
   if mode=="cancel" {try wait("page transport preparation"){pane.state != .loading};pane.stop();precondition(pane.state == .closed && pane.stopped);let before=events().filter{$0["kind"] as? String=="key"}.count;_ = try js(pane.web,"if(rfb)rfb.sendKey(65,'KeyA');true");RunLoop.current.run(until:Date().addingTimeInterval(0.1));precondition(events().filter{$0["kind"] as? String=="key"}.count==before);print("PASS: stopped VNC workspace cannot send later input");continue}
   if ["wrong","oversize","pixelcap","earlyclose","unsupported","timeout"].contains(mode) {try wait("expected failure \(mode), current \(pane.state)"){pane.stopped};precondition(pane.state == .failed && !hadConnected,"Unexpected state \(pane.state): \(pane.failure ?? "")");if mode=="wrong"{precondition(requests==1 && pane.failure?.contains("认证失败")==true)};if mode=="oversize" || mode=="pixelcap"{precondition(pane.failure?.contains("超出限制")==true || pane.failure?.contains("处理失败")==true)};print("PASS: \(mode) stops without a false connected state");continue}
   try wait("connected \(mode)"){pane.state == .connected || pane.stopped};guard pane.state == .connected else{throw SFTPError.message("\(mode): \(pane.failure ?? pane.status.stringValue)")}
   try wait("frame pixels \(mode)"){(try? js(pane.web,"(()=>{const c=document.querySelector('canvas');if(!c||c.width<4)return false;const p=c.getContext('2d').getImageData(0,0,2,1).data;return p[0]===255&&p[1]===0&&p[2]===0&&p[4]===0&&p[5]===0&&p[6]===255})()")) as? Bool==true || (mode=="resize" && events().contains{$0["kind"] as? String=="resize"})}
   if mode=="auth"{precondition(requests==1 && events().contains{($0["kind"] as? String)=="auth" && ($0["valid"] as? Bool)==true})}
   try wait("Unicode desktop name"){pane.desktopName.stringValue=="MacTerm 测试桌面"}
   _ = try js(pane.web,"rfb.sendKey(65,'KeyA');(()=>{const c=document.querySelector('canvas'),r=c.getBoundingClientRect();for(const type of ['mousedown','mouseup'])c.dispatchEvent(new MouseEvent(type,{bubbles:true,button:0,buttons:type==='mousedown'?1:0,clientX:r.left+r.width/2,clientY:r.top+r.height/2}));})();true")
   if mode=="viewOnly" {RunLoop.current.run(until:Date().addingTimeInterval(0.2));precondition(!events().contains{["key","pointer"].contains($0["kind"] as? String ?? "")})}
   else {try wait("real keyboard/pointer bytes"){let values=events();return values.contains{$0["kind"] as? String=="key" && $0["key"] as? Int==65} && values.contains{$0["kind"] as? String=="pointer" && $0["mask"] as? Int==1}}}
   if mode=="resize"{try wait("desktop resize pixels"){(try? js(pane.web,"(()=>{const c=document.querySelector('canvas');return c.width===6&&c.height===2&&c.getContext('2d').getImageData(0,0,1,1).data[1]===255})()")) as? Bool==true}}
   _ = try js(pane.web,"vncMessage('<script>bad</script>');true");let safeText=try js(pane.web,"document.querySelector('#message span').textContent");precondition(safeText as? String=="<script>bad</script>")
   pane.stop();try wait("socket closure"){events().contains{$0["kind"] as? String=="closed"}};precondition(!events().contains{$0["kind"] as? String=="error"});print("PASS: real WebKit VNC \(mode), canvas pixels, input transport and clean shutdown")
  }
 }
}
