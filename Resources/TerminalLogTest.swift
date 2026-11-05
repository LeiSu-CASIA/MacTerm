import Cocoa
import Darwin
@main struct TerminalLogTests {
 static func main()throws {
  let root=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("macterm-log-"+UUID().uuidString);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
  let url=root.appendingPathComponent("中文.log");let writer=try TerminalLogWriter(url:url)
  let chunks=[Data("中文\r\n\u{1b}[31mred\u{1b}[0m".utf8),Data((0..<200000).map{UInt8($0%251)})]
  for data in chunks {precondition(writer.append(data))};writer.finish();writer.finish();precondition(writer.waitUntilClosed(timeout:.now()+5));precondition(!writer.append(Data("late".utf8)))
  let actual=try Data(contentsOf:url);precondition(actual==chunks.reduce(Data(),+));let permissions=try FileManager.default.attributesOfItem(atPath:url.path)[.posixPermissions] as! NSNumber;precondition(permissions.intValue==0o600)
  do{_ = try TerminalLogWriter(url:url);fatalError("Existing log must remain untouched")}catch{};let unchanged=try Data(contentsOf:url);precondition(unchanged==actual)
  let symlink=root.appendingPathComponent("link");try FileManager.default.createSymbolicLink(at:symlink,withDestinationURL:url);do{_ = try TerminalLogWriter(url:symlink);fatalError("Symlink log must fail")}catch{}
  var interrupted=false;let shortURL=root.appendingPathComponent("short.log");let short=try TerminalLogWriter(url:shortURL,write:{fd,pointer,count in if !interrupted {interrupted=true;errno=EINTR;return -1};return Darwin.write(fd,pointer,min(3,count))});precondition(short.append(chunks[0]));short.finish();precondition(short.waitUntilClosed(timeout:.now()+5));let shortData=try Data(contentsOf:shortURL);precondition(shortData==chunks[0])
  let entered=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0);let slowURL=root.appendingPathComponent("slow.log");let slow=try TerminalLogWriter(url:slowURL,maximumQueuedBytes:8,write:{fd,pointer,count in entered.signal();_ = release.wait(timeout:.now()+5);return Darwin.write(fd,pointer,count)})
  precondition(slow.append(Data("12345678".utf8)));precondition(entered.wait(timeout:.now()+2) == .success);precondition(!TerminalLogWriter.isDrained);var didDrain=false;TerminalLogWriter.afterDraining{didDrain=true};precondition(!didDrain);let start=Date();precondition(!slow.append(Data([9])));precondition(Date().timeIntervalSince(start)<0.2);release.signal();precondition(slow.waitUntilClosed(timeout:.now()+5) && slow.error != nil);let prefix=try Data(contentsOf:slowURL);precondition(prefix==Data("12345678".utf8));let drainDeadline=Date().addingTimeInterval(2);while !didDrain && Date()<drainDeadline {RunLoop.current.run(until:Date().addingTimeInterval(0.01))};precondition(didDrain)
  let failed=try TerminalLogWriter(url:root.appendingPathComponent("full.log"),write:{_,_,_ in errno=ENOSPC;return -1});precondition(failed.append(Data("x".utf8)));failed.finish();precondition(failed.waitUntilClosed(timeout:.now()+5) && failed.error != nil)
  let errorDeadline=Date().addingTimeInterval(2);while !TerminalLogWriter.isDrained && Date()<errorDeadline {RunLoop.current.run(until:Date().addingTimeInterval(0.01))};precondition(TerminalLogWriter.isDrained)
  // Exercise the actual PTY -> TerminalPane -> log path. Typed secret is synthetic.
  _ = NSApplication.shared
  let pane=TerminalPane(path:"/bin/sh",args:["-c","stty -echo; printf 'LOG_READY\\n'; IFS= read -r value; printf 'LOG_DONE\\n'"]);defer{pane.stop()}
  let live=root.appendingPathComponent("live.log");try pane.startLogging(to:live);let liveWriter=pane.logWriter!
  let deadline=Date().addingTimeInterval(5);while Date()<deadline {RunLoop.current.run(until:Date().addingTimeInterval(0.01));if let data=try? Data(contentsOf:live),String(decoding:data,as:UTF8.self).contains("LOG_READY"){break}}
  let ready=try Data(contentsOf:live);precondition(String(decoding:ready,as:UTF8.self).contains("LOG_READY"));pane.send("FAKE_SECRET_NOT_FOR_LOG\n")
  while Date()<deadline && !pane.exitReported {RunLoop.current.run(until:Date().addingTimeInterval(0.01))}
  precondition(pane.exitReported && !pane.isLogging && liveWriter.waitUntilClosed(timeout:.now()+5));let liveData=try Data(contentsOf:live);let text=String(decoding:liveData,as:UTF8.self);precondition(text.contains("LOG_DONE") && !text.contains("FAKE_SECRET_NOT_FOR_LOG"));precondition(TerminalLogWriter.isDrained)
  print("PASS: raw UTF-8/ANSI/binary fidelity, mode 0600, existing/symlink refusal, partial writes and EINTR, bounded nonblocking backlog with prefix preserved, disk-full error, PTY output-only recording and EOF drain")
 }
}
