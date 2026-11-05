import Cocoa
import Darwin
@main struct FTPUploadSourceTests {
 static let fm=FileManager.default
 static func rejects(_ work:()throws->Void){do{try work();fatalError("Unsafe upload source accepted")}catch{}}
 static func fdCount()->Int {(0..<1024).filter{fcntl(Int32($0),F_GETFD)>=0}.count}
 static func main()throws {
  let root=fm.temporaryDirectory.appendingPathComponent("mt-upload-source-"+UUID().uuidString);try fm.createDirectory(at:root,withIntermediateDirectories:false);defer{try? fm.removeItem(at:root)}
  let tree=root.appendingPathComponent("tree"),nested=tree.appendingPathComponent("nested"),empty=tree.appendingPathComponent("empty"),file=nested.appendingPathComponent("中文 ' \" $;[].bin"),bytes=Data((0..<200000).map{UInt8($0%251)})
  try fm.createDirectory(at:nested,withIntermediateDirectories:true);try fm.createDirectory(at:empty,withIntermediateDirectories:false);try bytes.write(to:file);try Data().write(to:tree.appendingPathComponent(".hidden"))
  let source=try FTPUploadSource(tree,expectDirectory:true);precondition(source.fileCount==2 && source.nodes.count==4 && fcntl(source.rootFD,F_GETFD)&FD_CLOEXEC != 0)
  let node=source.nodes.first{$0.relative=="nested/中文 ' \" $;[].bin"}!,copy=root.appendingPathComponent("copy.bin");let count=try source.snapshot(node,to:copy),actual=try Data(contentsOf:copy);precondition(count==200000 && actual==bytes)
  let attributes=try fm.attributesOfItem(atPath:copy.path);precondition((attributes[.posixPermissions] as? NSNumber)?.intValue==0o600);try source.verifyUnchanged();rejects{_ = try source.snapshot(node,to:copy)}
  rejects{_ = try FTPUploadSource(tree,expectDirectory:false)};rejects{_ = try FTPUploadSource(file,expectDirectory:true)}
  rejects{_ = try FTPUploadSource(tree,expectDirectory:true,maximumItems:2)};rejects{_ = try FTPUploadSource(tree,expectDirectory:true,maximumDepth:1)};rejects{_ = try FTPUploadSource(tree,expectDirectory:true,maximumPathBytes:2)}
  let alias=root.appendingPathComponent("alias");try fm.createSymbolicLink(at:alias,withDestinationURL:tree);rejects{_ = try FTPUploadSource(alias,expectDirectory:true)}
  let link=tree.appendingPathComponent("link");try fm.createSymbolicLink(at:link,withDestinationURL:file);rejects{_ = try FTPUploadSource(tree,expectDirectory:true)}
  let before=fdCount();for _ in 0..<100 {rejects{_ = try FTPUploadSource(tree,expectDirectory:true)}};precondition(fdCount()<=before+2,"Descriptors leaked when directory preflight throws");try fm.removeItem(at:link)
  let fifo=tree.appendingPathComponent("fifo");precondition(mkfifo(fifo.path,0o600)==0);rejects{_ = try FTPUploadSource(tree,expectDirectory:true)};rejects{_ = try FTPUploadSource(fifo,expectDirectory:false)};try fm.removeItem(at:fifo)
  let invalid=Array((tree.path+"/").utf8)+[UInt8(255),0];invalid.withUnsafeBytes{raw in let path=raw.baseAddress!.assumingMemoryBound(to:CChar.self),fd=Darwin.open(path,O_CREAT|O_EXCL|O_WRONLY,0o600);if fd<0{return};Darwin.close(fd);defer{unlink(path)};rejects{_ = try FTPUploadSource(tree,expectDirectory:true)}}
  var checks=0;let partial=root.appendingPathComponent("cancelled.bin");rejects{_ = try source.snapshot(node,to:partial,check:{checks+=1;if checks==3{throw SFTPError.message("cancel")}})};precondition(!fm.fileExists(atPath:partial.path))
  let changing=try FTPUploadSource(file,expectDirectory:false),changedCopy=root.appendingPathComponent("changed-copy.bin");checks=0
  rejects{_ = try changing.snapshot(changing.nodes[0],to:changedCopy,check:{checks+=1;if checks==3{let writer=try FileHandle(forWritingTo:file);try writer.seekToEnd();try writer.write(contentsOf:Data([1]));try writer.close()}})};precondition(!fm.fileExists(atPath:changedCopy.path));try bytes.write(to:file)
  let replaced=try FTPUploadSource(tree,expectDirectory:true),replacedNode=replaced.nodes.first{$0.relative==node.relative}!,original=root.appendingPathComponent("original-file");try fm.moveItem(at:file,to:original);try fm.createSymbolicLink(at:file,withDestinationURL:root.appendingPathComponent("secret"));try Data("private secret".utf8).write(to:root.appendingPathComponent("secret"));let denied=root.appendingPathComponent("must-not-copy")
  rejects{_ = try replaced.snapshot(replacedNode,to:denied)};precondition(!fm.fileExists(atPath:denied.path));try fm.removeItem(at:file);try fm.moveItem(at:original,to:file)
  let replacedDirectory=try FTPUploadSource(tree,expectDirectory:true),directoryNode=replacedDirectory.nodes.first{$0.relative==node.relative}!,old=root.appendingPathComponent("old-nested");try fm.moveItem(at:nested,to:old);try fm.createDirectory(at:nested,withIntermediateDirectories:false);try Data("replacement".utf8).write(to:file)
  rejects{_ = try replacedDirectory.snapshot(directoryNode,to:denied)};rejects{try replacedDirectory.verifyUnchanged()};precondition(!fm.fileExists(atPath:denied.path))
  let single=try FTPUploadSource(copy,expectDirectory:false),once=root.appendingPathComponent("once"),twice=root.appendingPathComponent("twice");_ = try single.snapshot(single.nodes[0],to:once);_ = try single.snapshot(single.nodes[0],to:twice);let a=try Data(contentsOf:once),b=try Data(contentsOf:twice);precondition(a==bytes && b==bytes)
  print("PASS: descriptor-relative upload scan/snapshots, Unicode/binary/empty files, private modes/CLOEXEC, bounds, symlink/FIFO refusal and filesystem-conditional invalid-name handling, cancellation/mutation cleanup, file/directory replacement isolation and no failure descriptor leaks")
 }
}
