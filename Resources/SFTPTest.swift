import Foundation
import Darwin
@main struct SFTPTests {
 static func main()throws {
  let root=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("macterm-sftp-"+UUID().uuidString)
  try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:root)}
  let socket=ProcessInfo.processInfo.environment["MACTERM_TEST_SOCKET"];let client = try socket.map {try SFTPClient(arguments:SSHWorkspace.fileChannelArguments(host:"fixture-target.invalid",socket:$0))} ?? SFTPClient(command:"/usr/libexec/sftp-server",arguments:[]);defer{client.close()}
  let nested=root.appendingPathComponent("中文 空格 ' \" $;目录");try FileManager.default.createDirectory(at:nested,withIntermediateDirectories:true)
  let source=root.appendingPathComponent("source.bin");let payload=Data((0..<150000).map{UInt8($0%251)});try payload.write(to:source)
  let remote=nested.appendingPathComponent("测试 ' \" $;file.bin").path
  try client.upload(source,to:remote)
  let canonical=try client.canonical(nested.path);precondition(canonical==nested.path || canonical=="/private"+nested.path)
  let entries=try client.list(root.path);precondition(entries.contains{$0.directory && $0.name==nested.lastPathComponent})
  let list=try client.list(nested.path);precondition(list.count==1 && list[0].size==payload.count && !list[0].directory)
  let details=try client.fileAttributes(remote);precondition(details.size==UInt64(payload.count) && details.kind=="普通文件" && details.uid != nil && details.gid != nil && details.modified != nil)
  precondition(list[0].mode==details.mode && list[0].modified==details.modified)
  let link=nested.appendingPathComponent("link");try FileManager.default.createSymbolicLink(at:link,withDestinationURL:URL(fileURLWithPath:remote))
  let linkDetails=try client.fileAttributes(link.path);let targetDetails=try client.fileAttributes(link.path,followLinks:true);precondition(linkDetails.symbolicLink && targetDetails.kind=="普通文件" && targetDetails.size==UInt64(payload.count))
  let literalTarget=try client.readLink(link.path);precondition(literalTarget==remote)
  try FileManager.default.removeItem(at:link)
  let textFile=nested.appendingPathComponent("目标 文本.txt");try Data("原始文本\n".utf8).write(to:textFile)
  let textLink=nested.appendingPathComponent("text-link");try FileManager.default.createSymbolicLink(atPath:textLink.path,withDestinationPath:textFile.lastPathComponent)
  let relativeTarget=try client.readLink(textLink.path);precondition(relativeTarget==textFile.lastPathComponent)
  let expectedText=try client.canonical(textFile.path)
  if case .text(let resolved,let text)=try client.openEntry(textLink.path) {precondition(resolved==expectedText && text.text=="原始文本\n")}else{fatalError("Text symlink must open its canonical target")}
  let directoryLink=root.appendingPathComponent("目录链接");try FileManager.default.createSymbolicLink(atPath:directoryLink.path,withDestinationPath:nested.lastPathComponent)
  if case .directory(let resolved,let entries)=try client.openEntry(directoryLink.path) {precondition(resolved==canonical && entries.contains{$0.name==textFile.lastPathComponent})}else{fatalError("Directory symlink must browse")}
  for (path,mode) in [(textLink.path,RemoteEntryOpenMode.directory),(directoryLink.path,.text)] {do{_ = try client.openEntry(path,mode:mode);fatalError("Wrong target type must fail")}catch{}}
  let broken=root.appendingPathComponent("broken"),loop=root.appendingPathComponent("loop"),fifo=root.appendingPathComponent("pipe")
  try FileManager.default.createSymbolicLink(atPath:broken.path,withDestinationPath:"missing");try FileManager.default.createSymbolicLink(atPath:loop.path,withDestinationPath:"loop");precondition(mkfifo(fifo.path,0o600)==0)
  let brokenTarget=try client.readLink(broken.path);precondition(brokenTarget=="missing")
  for path in [broken.path,loop.path,fifo.path] {do{_ = try client.openEntry(path);fatalError("Broken links, cycles and devices must fail without reading content")}catch{}}
  do{_ = try client.readLink(textFile.path);fatalError("READLINK on a regular file must fail")}catch{}
  for url in [textLink,textFile,directoryLink,broken,loop,fifo] {try FileManager.default.removeItem(at:url)}
  print("PASS: absolute/relative Unicode symlink targets, directory navigation, canonical text target, type errors, broken/cyclic links and FIFO rejection")
  let destination=root.appendingPathComponent("download.bin");try client.download(remote,to:destination);let downloaded = try Data(contentsOf:destination);precondition(downloaded==payload)
  try Data("old".utf8).write(to:destination);try client.download(remote,to:destination);let replaced = try Data(contentsOf:destination);precondition(replaced==payload)
  do {try client.upload(source,to:remote);fatalError("Existing file must not be overwritten")}catch{}
  let empty=root.appendingPathComponent("empty");try Data().write(to:empty);try client.upload(empty,to:nested.appendingPathComponent("empty").path);try client.download(nested.appendingPathComponent("empty").path,to:root.appendingPathComponent("empty-copy"))
  do {_ = try client.list(root.appendingPathComponent("missing").path);fatalError("Missing directory must fail")}catch{}
  let created=root.appendingPathComponent("新建目录").path;try client.mkdir(created)
  let renamed=root.appendingPathComponent("重命名目录").path;try client.rename(created,to:renamed)
  try client.remove(renamed,directory:true)
  let renamedFile=nested.appendingPathComponent("renamed.bin").path;try client.rename(remote,to:renamedFile);try client.remove(renamedFile)
  let failed=nested.appendingPathComponent("failed.bin").path
  let rejecting=try SFTPClient(command:"/usr/libexec/sftp-server",arguments:["-P","write"]);defer{rejecting.close()}
  do {try rejecting.upload(source,to:failed);fatalError("Server write rejection must fail")}catch{}
  let afterFailure=try client.list(nested.path);precondition(!afterFailure.contains{$0.name.hasPrefix(".macterm-upload-") || $0.name=="failed.bin"})
  var ticks=0;client.progress={done,total in ticks+=1};try client.upload(source,to:remote);precondition(ticks>2)
  let cancelling=try SFTPClient(command:"/usr/libexec/sftp-server",arguments:[]);defer{cancelling.close()};var cancelled=false
  cancelling.progress={done,_ in if done>0 && !cancelled {cancelled=true;cancelling.process.terminate()}}
  do {try cancelling.upload(source,to:nested.appendingPathComponent("cancelled.bin").path);fatalError("Cancelled upload must fail")}catch{}
  precondition(cancelled && !FileManager.default.fileExists(atPath:nested.appendingPathComponent("cancelled.bin").path))
  print("PASS: mkdir, rename, remove, atomic publish, rejected-write cleanup, progress, cancellation without final file")
  print("SFTP passed: real OpenSSH server, list, canonical paths, binary multi-chunk upload/download, Unicode and quoted filenames, empty files, local replacement, remote overwrite protection, errors")
 }
}
