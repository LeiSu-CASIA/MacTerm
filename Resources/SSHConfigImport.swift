import Foundation
import Darwin

struct SSHConfigReport {let sessions:[Session];let skippedPatterns:Int;let skippedIncludes:Int}
struct SSHConfigImporter {
 /// Static alias discovery only; connection evaluation remains with OpenSSH.
 static func scan(_ config:URL,sshDirectory:URL=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh"))throws->SSHConfigReport {
  var visited=Set<String>(),aliases=Set<String>(),patterns=0,skipped=0,total=0
  func tokens(_ line:String)throws->[String] {var values=[String](),word="",quoted=false,escaped=false
   for char in line {if escaped {word.append(char);escaped=false;continue};if char=="\\" {escaped=true;continue};if char=="\"" {quoted.toggle();continue};if char=="#" && !quoted {break};if char.isWhitespace && !quoted {if !word.isEmpty{values.append(word);word=""}}else{word.append(char)}}
   guard !quoted,!escaped else{throw SFTPError.message("SSH 配置含未闭合引号或转义，未导入")};if !word.isEmpty{values.append(word)};return values
  }
  func read(_ url:URL,depth:Int)throws {guard depth<=8,visited.count<128 else{throw SFTPError.message("SSH Include 层级或文件数超过扫描限制")};let canonical=url.resolvingSymlinksInPath().standardizedFileURL.path;guard !visited.contains(canonical) else{return};visited.insert(canonical)
   let attrs=try FileManager.default.attributesOfItem(atPath:url.path);guard let size=attrs[.size] as? NSNumber,size.intValue>=0,size.intValue<=8*1024*1024-total else{throw SFTPError.message("SSH 配置超过 8 MB 扫描限制")};let data=try Data(contentsOf:url);total+=data.count;guard let text=String(data:data,encoding:.utf8) else{throw SFTPError.message("SSH 配置不是 UTF-8 文本")}
   for rawLine in text.components(separatedBy:.newlines) {let line=rawLine.trimmingCharacters(in:.whitespaces);guard !line.isEmpty,!line.hasPrefix("#"),let separator=line.firstIndex(where:{$0.isWhitespace || $0=="="}) else{continue};let directive=line[..<separator].lowercased();guard directive=="host" || directive=="include" else{continue};var remainder=String(line[separator...]).trimmingCharacters(in:.whitespaces);if remainder.hasPrefix("="){remainder.removeFirst()};let values=try tokens(remainder)
    if directive=="host" {for alias in values {if alias.contains(where:{"*?[]!@:".contains($0)}) || alias.hasPrefix("-") || alias.contains(where:{$0.isWhitespace}) {patterns+=1;continue};_ = try Session(name:alias,host:alias,user:"",port:0,key:"").validated();aliases.insert(alias)}}
    else {for value in values {guard !value.contains("%"),!value.contains("${"),!value.contains("\0") else{skipped+=1;continue};let expanded=(value as NSString).expandingTildeInPath;let pattern=expanded.hasPrefix("/") ? expanded : sshDirectory.appendingPathComponent(expanded).path;var result=glob_t();let status=Darwin.glob(pattern,0,nil,&result);defer{globfree(&result)};if status != 0 {skipped+=1;continue};for index in 0..<Int(result.gl_pathc){if let name=result.gl_pathv[index] {try read(URL(fileURLWithPath:String(cString:name)),depth:depth+1)}}}}
   }
  }
  try read(config,depth:0)
  return SSHConfigReport(sessions:try aliases.sorted().map{try Session(name:$0,host:$0,user:"",port:0,key:"",id:UUID(),group:"SSH Config").validated()},skippedPatterns:patterns,skippedIncludes:skipped)
 }
}

extension AppDelegate {
 @objc func importSSHConfig(){do {let report=try SSHConfigImporter.scan(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config"));let merged=try SessionStore.merge(report.sessions,into:sessions);if merged.added>0 {let previous=sessions;sessions=merged.sessions;if !persist(){sessions=previous;sessionBrowser.reload(sessions);return}};alert("已导入 \(merged.added) 个 SSH 别名，跳过重复项 \(merged.skipped) 个。\n未导入通配/否定模式 \(report.skippedPatterns) 个，未展开 Include \(report.skippedIncludes) 项。\n实际连接仍由 ~/.ssh/config 配置决定；导入时不执行 Match exec，也不评估条件块。") }catch{alert("SSH 配置导入失败，现有会话未更改：\(error.localizedDescription)")}}
}
