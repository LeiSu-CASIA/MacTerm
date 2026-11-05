import Cocoa
@main struct TunnelTests {
 static func main()throws {
  if CommandLine.arguments.count==7 {let a=CommandLine.arguments;let definition=TunnelDefinition(name:"integration",kind:TunnelDefinition.Kind(rawValue:a[2])!,listenPort:Int(a[3])!,targetPort:Int(a[4])!);do {try TunnelCommand.run(definition,operation:TunnelCommand.Operation(rawValue:a[1])!,host:"test-target.invalid",socket:a[5]);print("OK");return}catch{fputs(error.localizedDescription+"\n",stderr);exit(1)}}
  _ = NSApplication.shared
  let local=TunnelDefinition(name:"local",kind:.local,listenPort:18080,targetHost:"db.example.invalid",targetPort:5432)
  let localArgs=try local.forwardingArguments();precondition(localArgs==["-L","127.0.0.1:18080:db.example.invalid:5432"])
  let remote=TunnelDefinition(name:"remote",kind:.remote,listenHost:"::1",listenPort:18081,targetHost:"::1",targetPort:22)
  let remoteArgs=try remote.forwardingArguments();precondition(remoteArgs==["-R","[::1]:18081:[::1]:22"])
  let dynamic=TunnelDefinition(name:"socks",kind:.dynamic,listenPort:1080,targetHost:"",targetPort:0)
  let dynamicArgs=try dynamic.forwardingArguments();precondition(dynamicArgs==["-D","127.0.0.1:1080"])
  let args=try TunnelCommand.arguments(local,operation:.forward,host:"alias",socket:"/tmp/mux");precondition(args.contains("ProxyCommand=/usr/bin/false") && args.contains("forward") && !args.contains("-J"))
  for invalid in [TunnelDefinition(name:"",kind:.local,listenPort:22),TunnelDefinition(name:"bad",kind:.local,listenPort:0),TunnelDefinition(name:"bad",kind:.local,listenPort:42,targetHost:"host\ncommand"),TunnelDefinition(name:"bad",kind:.dynamic,listenHost:"-R",listenPort:22)] {do {_ = try invalid.validated();fatalError("Invalid tunnel must fail")}catch{}}
  do {try TunnelDefinition.validateList([local,TunnelDefinition(name:"conflict",kind:.dynamic,listenPort:18080)]);fatalError("Local/dynamic collision must be rejected")}catch{}
  try TunnelDefinition.validateList([local,remote,dynamic])
  var session=Session(name:"host",host:"example.invalid",user:"user",port:22,key:"");session.tunnels=[local,remote,dynamic];let saved=try JSONEncoder().encode(session);let restored=try JSONDecoder().decode(Session.self,from:saved);precondition(restored.tunnels==session.tunnels)
  do {try TunnelCommand.run(local,operation:.forward,host:"127.0.0.1",socket:"/tmp/missing-tunnel-"+UUID().uuidString);fatalError("Missing master must not start a new SSH connection")}catch{}
  func wait(_ check:()->Bool){let deadline=Date().addingTimeInterval(3);while !check() && Date()<deadline {RunLoop.current.run(until:Date().addingTimeInterval(0.01))};precondition(check(),"Manager state update timed out")}
  var automatic=local;automatic.autoStart=true;var stopCount=0
  let manager=TunnelManager(host:"test",socket:"unused",definitions:[automatic,dynamic],executor:{_,operation,_,_ in if operation == .cancel {stopCount+=1;if stopCount==1 {throw SFTPError.message("simulated cancellation failure")}}})
  manager.startAutomatic();precondition(manager.state(automatic.id ) == .starting && manager.state(dynamic.id ) == .stopped)
  wait{manager.state(automatic.id ) == .running}
  do {try manager.replace([dynamic]);fatalError("Active tunnel must not be deleted")}catch{}
  manager.stop(automatic.id);wait{if case .uncertain=manager.state(automatic.id){return true};return false};precondition(manager.state(automatic.id).active)
  manager.stop(automatic.id);wait{manager.state(automatic.id ) == .stopped};try manager.replace([dynamic])
  let blocker=DispatchSemaphore(value:0),finished=DispatchSemaphore(value:0)
  let closing=TunnelManager(host:"test",socket:"unused",definitions:[local],executor:{_,_,_,_ in blocker.wait();finished.signal()})
  closing.start(local.id);closing.connectionClosed();blocker.signal();precondition(finished.wait(timeout:.now()+2 ) == .success)
  RunLoop.current.run(until:Date().addingTimeInterval(0.05));precondition(closing.state(local.id ) == .stopped && closing.closed)
  let interrupt=TunnelManager(host:"test",socket:"unused",definitions:[local],executor:{_,_,_,_ in throw TunnelCommandError.uncertain});interrupt.start(local.id);wait{if case .uncertain=interrupt.state(local.id){return true};return false}
  print("PASS: automatic startup state, active-edit refusal, failed-stop uncertainty and retry, interrupted-start uncertainty, late callback ignored after disconnect")
  print("PASS: local/remote/SOCKS arguments, IPv6, validation, collision checks, session persistence and missing-master refusal")
 }
}
