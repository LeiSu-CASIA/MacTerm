import Cocoa
@main struct TerminalTests {
 static func main()throws {
  for (value,host,user,port) in [("server","server","",0),("test@server:2200","server","test",2200),("ssh://user@host:22","host","user",22),("user@[2001:db8::1]:2222","2001:db8::1","user",2222),("::1","::1","",0)] {let parsed=try QuickConnection.parse(value);precondition(parsed.host==host && parsed.user==user && parsed.port==port)}
  for invalid in ["","-host","user@","@host","user@@host","host:0","host:65536","[::1","[host]","[::1]:oops","bad:ipv6:address","ssh://user:password@host","ssh://host/path","host\u{1b}x"] {do {_ = try QuickConnection.parse(invalid);fatalError("Must reject \(invalid)")}catch{}}
  let shortPipe=Pipe(),shortReader=TerminalOutput(fd:shortPipe.fileHandleForReading.fileDescriptor)
  try shortPipe.fileHandleForWriting.write(contentsOf:Data("short prompt".utf8))
  let shortDone=DispatchSemaphore(value:0);let shortResult=ResultBox()
  DispatchQueue.global().async {if case .data(let data)=shortReader.readAvailable(){shortResult.value=data};shortDone.signal()}
  precondition(shortDone.wait(timeout:.now()+1) == .success && shortResult.value==Data("short prompt".utf8))
  shortReader.stop()
  if case .closed=shortReader.readAvailable() {}else{fatalError("A stopped reader must not read another descriptor")}
  let pipe=Pipe();let writer=TerminalInput(fd:pipe.fileHandleForWriting.fileDescriptor);let prefix=Data("中文\n".utf8);let payload=Data((0..<1048576).map{UInt8($0%251)});let expected=prefix+payload;let done=DispatchSemaphore(value:0);let result=ResultBox()
  DispatchQueue.global().async {var data=Data();while data.count<expected.count {let chunk=pipe.fileHandleForReading.readData(ofLength:min(65536,expected.count-data.count));if chunk.isEmpty{break};data.append(chunk)};result.value=data;done.signal()}
  let started=Date();writer.send(prefix);writer.send(payload);precondition(Date().timeIntervalSince(started)<0.2);precondition(done.wait(timeout:.now()+10) == .success);precondition(result.value==expected);writer.stop()
  // Pending input after stop must never be delivered to another session.
  let pipe2=Pipe(),pipe3=Pipe();let old=TerminalInput(fd:pipe2.fileHandleForWriting.fileDescriptor);old.stop();old.send(Data("stale".utf8));let fresh=TerminalInput(fd:pipe3.fileHandleForWriting.fileDescriptor);fresh.send(Data("fresh".utf8));let received=pipe3.fileHandleForReading.readData(ofLength:5);precondition(received==Data("fresh".utf8));fresh.stop()
  print("PASS: quick connect aliases, ports, IPv6 and URL validation; short live output without EOF, nonblocking UI submission, ordered 1 MB input fidelity and closed-session isolation")
 }
}
final class ResultBox {var value=Data()}
