import Foundation

/// MLSD describes the server's virtual filesystem. A server may present aliases
/// as ordinary directories; bounded traversal is required even without links.
struct FTPDirectoryPlan {
 struct Node {let remote:String;let relative:String;let directory:Bool}
 let nodes:[Node]
 var fileCount:Int {nodes.filter{!$0.directory}.count}
 static func scan(_ source:String,maximumDepth:Int=64,maximumItems:Int=50000,maximumPathBytes:Int=32*1024*1024,check:()throws->Void,list:(String)throws->[RemoteFile])throws->FTPDirectoryPlan {
  guard (1...64).contains(maximumDepth),(1...50000).contains(maximumItems),(1...32*1024*1024).contains(maximumPathBytes) else{throw SFTPError.message("FTP 目录扫描限制无效")}
  let root=try FTPPath.normalize(source);var nodes=[Node](),pathBytes=0,discovered=0
  func walk(_ remote:String,relative:String,depth:Int)throws {
   try check();guard depth<maximumDepth else{throw SFTPError.message("FTP 目录超过 \(maximumDepth) 层，未发布下载目录")}
   let entries=try list(remote)
   guard entries.count<=maximumItems-discovered else{throw SFTPError.message("FTP 目录超过 \(maximumItems) 项，未发布下载目录")};discovered+=entries.count
   var names=Set<Data>()
   for entry in entries {
    try check();_ = try RemoteFileName.validated(entry.name)
    guard names.insert(Data(entry.name.utf8)).inserted else{throw SFTPError.message("FTP 目录存在重复文件名，未发布下载目录")}
    let kind=entry.mode&0o170000
    guard (kind==0o040000 && entry.directory) || (kind==0o100000 && !entry.directory) else{throw SFTPError.message("FTP 目录含链接、未知类型或特殊文件：\(entry.name)，未发布下载目录")}
    guard nodes.count<maximumItems else{throw SFTPError.message("FTP 目录超过 \(maximumItems) 项，未发布下载目录")}
    let child=try FTPPath.child(entry.name,in:remote),childRelative=relative.isEmpty ? entry.name : relative+"/"+entry.name
    let cost=child.utf8.count+childRelative.utf8.count
    guard cost<=maximumPathBytes-pathBytes else{throw SFTPError.message("FTP 目录路径总量超过限制，未发布下载目录")};pathBytes+=cost
    nodes.append(Node(remote:child,relative:childRelative,directory:entry.directory))
    if entry.directory {try walk(child,relative:childRelative,depth:depth+1)}
   }
  }
  try walk(root,relative:"",depth:0);return FTPDirectoryPlan(nodes:nodes)
 }
}
