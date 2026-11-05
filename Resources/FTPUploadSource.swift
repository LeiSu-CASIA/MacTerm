import Foundation
import Darwin

/// Keep the selected root open. Every descendant is opened relative to owned
/// descriptors with NOFOLLOW, rather than re-resolving a mutable absolute path.
final class FTPUploadSource {
 struct Identity {
  let device:dev_t,inode:ino_t,mode:mode_t,size:off_t,modified:timespec,changed:timespec
  init(_ fd:Int32)throws {var value=stat();guard fstat(fd,&value)==0 else{throw SFTPError.message("无法检查本机上传源")};device=value.st_dev;inode=value.st_ino;mode=value.st_mode;size=value.st_size;modified=value.st_mtimespec;changed=value.st_ctimespec}
  var directory:Bool {mode&0o170000==0o040000}
  var regular:Bool {mode&0o170000==0o100000}
  func sameObject(_ other:Identity)->Bool {device==other.device && inode==other.inode && mode==other.mode}
  func sameRevision(_ other:Identity)->Bool {sameObject(other) && size==other.size && modified.tv_sec==other.modified.tv_sec && modified.tv_nsec==other.modified.tv_nsec && changed.tv_sec==other.changed.tv_sec && changed.tv_nsec==other.changed.tv_nsec}
 }
 struct Node {let components:[String];let relative:String;let identity:Identity;var directory:Bool {identity.directory}}
 let rootFD:Int32,rootIdentity:Identity
 private(set) var nodes=[Node]()
 private var directories=[Data:Identity]()
 var fileCount:Int {nodes.filter{!$0.directory}.count}
 init(_ source:URL,expectDirectory:Bool,maximumDepth:Int=64,maximumItems:Int=50000,maximumPathBytes:Int=32*1024*1024,check:()throws->Void={})throws {
  guard source.isFileURL,(1...64).contains(maximumDepth),(1...50000).contains(maximumItems),(1...32*1024*1024).contains(maximumPathBytes) else{throw SFTPError.message("FTP 上传源或扫描限制无效")};try check()
  let fd=Darwin.open(source.path,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK)
  guard fd>=0 else{throw SFTPError.message("无法打开本机上传源；不跟随符号链接")}
  let identity:Identity
  do {identity=try Identity(fd);guard identity.directory==expectDirectory,(identity.directory || identity.regular),identity.size>=0 else{throw SFTPError.message("上传源类型已改变，或含链接 / 特殊文件")}}catch{Darwin.close(fd);throw error}
  rootFD=fd;rootIdentity=identity
  if !expectDirectory {nodes=[Node(components:[],relative:"",identity:identity)];return}
  directories[Data()]=identity
  var pathBytes=0
  func walk(_ current:Int32,parts:[String],depth:Int)throws {
   try check();guard depth<maximumDepth else{throw SFTPError.message("本机上传目录超过 \(maximumDepth) 层")}
   let before=try Identity(current),duplicate=fcntl(current,F_DUPFD_CLOEXEC,0)
   guard duplicate>=0 else{throw SFTPError.message("无法读取本机目录")}
   guard let stream=fdopendir(duplicate) else{Darwin.close(duplicate);throw SFTPError.message("无法读取本机目录")};defer{closedir(stream)}
   while true {
    try check();errno=0;guard let entry=readdir(stream) else{guard errno==0 else{throw SFTPError.message("本机目录读取失败")};break}
    let name=withUnsafePointer(to:&entry.pointee.d_name){pointer in pointer.withMemoryRebound(to:CChar.self,capacity:MemoryLayout.size(ofValue:entry.pointee.d_name)){String(validatingUTF8:$0)}}
    guard let name=name else{throw SFTPError.message("本机目录含非 UTF-8 文件名")};if name=="." || name==".." {continue};_ = try RemoteFileName.validated(name)
    guard nodes.count<maximumItems else{throw SFTPError.message("本机上传目录超过 \(maximumItems) 项")}
    let components=parts+[name],relative=components.joined(separator:"/"),cost=relative.utf8.count
    guard cost<=maximumPathBytes-pathBytes else{throw SFTPError.message("本机上传目录路径总量超过限制")};pathBytes+=cost
    let child=openat(current,name,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK)
    guard child>=0 else{throw SFTPError.message("无法读取上传项目或发现符号链接："+relative)};defer{Darwin.close(child)}
    let value=try Identity(child);guard (value.directory || value.regular),value.size>=0 else{throw SFTPError.message("上传目录含特殊文件："+relative)}
    nodes.append(Node(components:components,relative:relative,identity:value))
    if value.directory {directories[Data(relative.utf8)]=value;try walk(child,parts:components,depth:depth+1)}
   }
   guard before.sameRevision(try Identity(current)) else{throw SFTPError.message("扫描期间本机目录发生变化，请重试")}
  }
  try walk(fd,parts:[],depth:0)
 }
 deinit{Darwin.close(rootFD)}
 private func openNode(_ node:Node)throws->Int32 {
  guard rootIdentity.sameObject(try Identity(rootFD)) else{throw SFTPError.message("本机上传根目录发生变化")}
  var current=fcntl(rootFD,F_DUPFD_CLOEXEC,0);guard current>=0 else{throw SFTPError.message("无法打开本机上传源")}
  do {
   for (index,name) in node.components.enumerated() {
    let next=openat(current,name,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK)
    guard next>=0 else{throw SFTPError.message("上传源已移动、删除或变为符号链接："+node.relative)}
    Darwin.close(current);current=next
    let key=Data(node.components.prefix(index+1).joined(separator:"/").utf8)
    let expected=index==node.components.count-1 ? node.identity : directories[key]
    guard let expected=expected,expected.sameRevision(try Identity(current)) else{throw SFTPError.message("本机上传项目已改变，请重试："+node.relative)}
   }
   guard node.identity.sameRevision(try Identity(current)) else{throw SFTPError.message("本机上传文件已改变，请重试："+node.relative)}
   return current
  }catch{Darwin.close(current);throw error}
 }
 /// Only this private, complete regular-file snapshot is passed to curl.
 func snapshot(_ node:Node,to destination:URL,check:()throws->Void={})throws->UInt64 {
  try check();guard !node.directory,destination.isFileURL else{throw SFTPError.message("上传暂存源必须是普通文件")}
  let input=try openNode(node);defer{Darwin.close(input)}
  let output=Darwin.open(destination.path,O_CREAT|O_WRONLY|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
  guard output>=0 else{throw SFTPError.message("无法创建上传文件暂存副本")};defer{Darwin.close(output)}
  var complete=false;defer{if !complete{try? FileManager.default.removeItem(at:destination)}}
  // dup shares its file offset with the root for a single-file source.
  guard lseek(input,0,SEEK_SET)==0 else{throw SFTPError.message("无法读取本机上传文件")}
  var remaining=node.identity.size,buffer=[UInt8](repeating:0,count:65536)
  while remaining>0 {
   try check();let count=Darwin.read(input,&buffer,min(buffer.count,Int(min(remaining,65536))))
   if count<0 && errno==EINTR {continue};guard count>0 else{throw SFTPError.message("读取本机上传文件失败或内容已改变："+node.relative)}
   try buffer.withUnsafeBytes{bytes in var offset=0;while offset<count {try check();let written=Darwin.write(output,bytes.baseAddress!.advanced(by:offset),count-offset);if written<0 && errno==EINTR{continue};guard written>0 else{throw SFTPError.message("上传暂存磁盘写入失败")};offset+=written}}
   remaining-=off_t(count)
  }
  try check();var extra:UInt8=0;var end:Int;repeat{end=Darwin.read(input,&extra,1)}while end<0 && errno==EINTR
  guard end==0,node.identity.sameRevision(try Identity(input)) else{throw SFTPError.message("生成暂存副本期间本机文件发生变化，请重试："+node.relative)}
  complete=true;return UInt64(node.identity.size)
 }
 func verifyUnchanged(check:()throws->Void={})throws {
  try check();guard rootIdentity.sameRevision(try Identity(rootFD)) else{throw SFTPError.message("上传期间本机根目录发生变化，请重试")}
  for node in nodes {try check();let fd=try openNode(node);Darwin.close(fd)}
 }
}
