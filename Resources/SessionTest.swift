import Cocoa
@main struct SessionTests {
 static func main()throws {
  _ = NSApplication.shared
  if CommandLine.arguments.count==3,CommandLine.arguments[1]=="--emit-arguments" {let value=try JSONDecoder().decode(Session.self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[2])));let arguments=AppDelegate().arguments(try value.validated(),sftp:false);FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:arguments));return}
  let legacy=Data(#"{"name":"legacy","host":"example.invalid","user":"test","port":22,"key":""}"#.utf8)
  let old=try JSONDecoder().decode(Session.self,from:legacy);precondition(old.jumpHost==nil && old.keepAlive==nil && old.x11==nil && old.compression==nil && old.forwardAgent==nil && old.remoteCommand==nil && old.commandTTY==nil)
  let configured=Session(name:"test",host:"destination.invalid",user:"remoteuser",port:2222,key:"",jumpHost:"jumpuser@gateway.invalid:2200",keepAlive:45,connectionTimeout:12,x11:true,compression:true,forwardAgent:true,remoteCommand:"printf 'quoted ; $literal'",commandTTY:false)
  let restored=try JSONDecoder().decode(Session.self,from:JSONEncoder().encode(configured));precondition(restored.jumpHost==configured.jumpHost && restored.x11==true && restored.compression==true && restored.forwardAgent==true && restored.remoteCommand==configured.remoteCommand && restored.commandTTY==false)
  let delegate=AppDelegate();let args=delegate.arguments(restored,sftp:false)
  let process=Process(),output=Pipe();process.executableURL=URL(fileURLWithPath:"/usr/bin/ssh");process.arguments=["-G","-F","/dev/null"]+args;process.standardOutput=output;process.standardError=FileHandle.nullDevice;try process.run();let text=String(decoding:output.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self);process.waitUntilExit();precondition(process.terminationStatus==0)
  for setting in ["user remoteuser","hostname destination.invalid","port 2222","serveraliveinterval 45","connecttimeout 12","forwardx11 yes","proxyjump jumpuser@gateway.invalid:2200","compression yes","forwardagent yes","requesttty false","remotecommand printf 'quoted ; $literal'"] {precondition(text.contains(setting),setting)}
  let root=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("macterm-ssh-options-"+UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
  let config=root.appendingPathComponent("config");try Data("Host destination.invalid\n Compression yes\n ForwardAgent yes\n RemoteCommand printf inherited\n RequestTTY no\n".utf8).write(to:config)
  func resolved(_ session:Session)throws->String {let p=Process(),pipe=Pipe();p.executableURL=URL(fileURLWithPath:"/usr/bin/ssh");p.arguments=["-G","-F",config.path]+delegate.arguments(session,sftp:false);p.standardOutput=pipe;p.standardError=FileHandle.nullDevice;try p.run();let output=pipe.fileHandleForReading.readDataToEndOfFile();p.waitUntilExit();precondition(p.terminationStatus==0);return String(decoding:output,as:UTF8.self)}
  let defaults=Session(name:"defaults",host:"destination.invalid",user:"",port:0,key:"");let inherited=try resolved(defaults);precondition(inherited.contains("compression yes") && inherited.contains("forwardagent yes") && inherited.contains("remotecommand printf inherited"))
  var explicit=defaults;explicit.compression=false;explicit.forwardAgent=false;explicit.remoteCommand="printf explicit";let overridden=try resolved(explicit);precondition(overridden.contains("compression no") && overridden.contains("forwardagent no") && overridden.contains("remotecommand printf explicit") && overridden.contains("requesttty force"))
  explicit.commandTTY=false;let noTTY=try resolved(explicit);precondition(noTTY.contains("requesttty false"));precondition(explicit.fingerprint != defaults.fingerprint)
  for invalid in ["echo one\necho two","echo\u{0}",String(repeating:"x",count:4097)] {explicit.remoteCommand=invalid;do{_ = try explicit.validated();fatalError("Invalid remote command accepted")}catch{}}
  let fileArgs=delegate.arguments(restored,sftp:true);precondition(!fileArgs.contains(where:{$0.hasPrefix("RemoteCommand=") || $0.hasPrefix("RequestTTY=") || $0.hasPrefix("ForwardAgent=")}))
  let channel=SSHWorkspace.fileChannelArguments(host:restored.host,socket:"/tmp/test-socket");precondition(!channel.contains("-J") && !channel.contains("-X") && channel.contains("ProxyCommand=/usr/bin/false") && channel.contains("/dev/null"))
  precondition(!delegate.arguments(restored,sftp:true).contains("-X"))
  do {_ = try SFTPClient(arguments:SSHWorkspace.fileChannelArguments(host:"127.0.0.1",socket:"/tmp/macterm-missing-"+UUID().uuidString));fatalError("Missing control connection must not fall back to new authentication")}catch{}
  print("PASS: legacy session migration, settings roundtrip, real ssh -G confirms jump host, user, port, timeout, keepalive, X11, compression, agent and remote command/TTY; inheritance and explicit overrides")
 }
}
