import Cocoa
import Darwin

/// Output only. File I/O stays on a serial worker; the UI never waits for the disk.
final class TerminalLogWriter {
 private static let allWriters=DispatchGroup()
 private let closed=DispatchGroup(),lock=NSLock(),queue=DispatchQueue(label:"local.macterm.output-log")
 private var fd:Int32;private var accepting=true;private var closing=false;private var queuedBytes=0;private var writeFailed=false;private var failure:String?
 private let limit:Int;private let writeChunk:(Int32,UnsafeRawPointer,Int)->Int
 let url:URL
 var onFailure:((String)->Void)?
 init(url:URL,maximumQueuedBytes:Int=4*1024*1024,write:@escaping(Int32,UnsafeRawPointer,Int)->Int={Darwin.write($0,$1,$2)})throws {
  guard url.isFileURL,maximumQueuedBytes>0 else{throw SFTPError.message("无效的日志路径或缓冲区大小")}
  let descriptor=Darwin.open(url.path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
  guard descriptor>=0 else{throw SFTPError.message("无法创建日志（同名文件不覆盖）：\(String(cString:strerror(errno)))")}
  guard fchmod(descriptor,0o600)==0 else{let code=errno;Darwin.close(descriptor);throw SFTPError.message("无法设置日志权限：\(String(cString:strerror(code)))")}
  self.url=url;fd=descriptor;limit=maximumQueuedBytes;writeChunk=write;closed.enter();Self.allWriters.enter()
 }
 var error:String? {lock.lock();defer{lock.unlock()};return failure}
 private func failLocked(_ message:String){
  accepting=false
  if failure==nil {failure=message;Self.allWriters.enter();DispatchQueue.main.async {[self] in defer{Self.allWriters.leave()};onFailure?(message)}}
  finishLocked()
 }
 private func finishLocked(){guard !closing else{return};closing=true;accepting=false;queue.async {[self] in
  if !writeFailed {var result=fsync(fd);while result<0 && errno==EINTR {result=fsync(fd)};if result<0 {let message="日志同步失败："+String(cString:strerror(errno));lock.lock();failLocked(message);lock.unlock()}}
  Darwin.close(fd);fd = -1;closed.leave();Self.allWriters.leave()
 }}
 @discardableResult func append(_ data:Data)->Bool {
  guard !data.isEmpty else{return true}
  lock.lock();defer{lock.unlock()};guard accepting else{return false}
  guard data.count<=limit-queuedBytes else{failLocked("磁盘写入跟不上终端输出，日志缓冲区已满；已停止记录，已有内容仍保留");return false}
  queuedBytes+=data.count
  queue.async {[self] in
   if !writeFailed {data.withUnsafeBytes {bytes in guard let base=bytes.baseAddress else{return};var offset=0
    while offset<data.count {let count=writeChunk(fd,base.advanced(by:offset),data.count-offset);if count<0 && errno==EINTR {continue};guard count>0,count<=data.count-offset else{let message=count==0 ? "日志写入返回零字节" : "日志写入失败："+String(cString:strerror(errno));writeFailed=true;lock.lock();failLocked(message);lock.unlock();break};offset+=count}
   }}
   lock.lock();queuedBytes-=data.count;lock.unlock()
  }
  return true
 }
 func finish(){lock.lock();finishLocked();lock.unlock()}
 func waitUntilClosed(timeout:DispatchTime)->Bool {closed.wait(timeout:timeout) == .success}
 static var isDrained:Bool {allWriters.wait(timeout:.now()) == .success}
 static func afterDraining(_ completion:@escaping()->Void){allWriters.notify(queue:.main,execute:completion)}
 deinit {if fd>=0 {Darwin.close(fd);closed.leave();Self.allWriters.leave()}}
}

extension TerminalPane {
 var isLogging:Bool {logWriter != nil}
 func startLogging(to url:URL)throws {
  guard !stopped,pid>0,!receivedEOF else{throw SFTPError.message("会话已结束，无法开始记录")}
  guard logWriter==nil else{throw SFTPError.message("此标签已在记录日志")}
  let writer=try TerminalLogWriter(url:url);logWriter=writer;lastLogURL=url
  let reportError=onLoggingError
  writer.onFailure = {[weak self,weak writer] message in if let self=self,self.logWriter === writer {self.logWriter=nil;self.onLoggingChanged?()};reportError?("\(url.path)\n\(message)")}
  onLoggingChanged?()
 }
 func stopLogging(notify:Bool=true){guard let writer=logWriter else{return};logWriter=nil;writer.finish();if notify {onLoggingChanged?()}}
}

extension AppDelegate:NSMenuItemValidation {
 func watchLogging(_ pane:TerminalPane){configureTerminalInteraction(pane);pane.onLoggingChanged = {[weak self] in self?.updateTabStrip()};pane.onLoggingError = {[weak self] message in self?.alert("终端日志已停止：\n"+message)}}
 @objc func startOutputLog(){guard NSApp.keyWindow === window,let pane=activeTerminal else{return};let panel=NSSavePanel();panel.title="开始终端输出日志";panel.nameFieldStringValue="MacTerm-\(Int(Date().timeIntervalSince1970)).log";panel.message="从现在开始记录原始输出，包含终端回显和 ANSI 控制码。请选新文件；纯文本请用“导出终端文本”。";guard panel.runModal() == .OK,let url=panel.url else{return};do{try pane.startLogging(to:url)}catch{alert(error.localizedDescription)}}
 @objc func stopOutputLog(){guard NSApp.keyWindow === window else{return};activeTerminal?.stopLogging()}
 @objc func revealOutputLog(){guard NSApp.keyWindow === window,let url=activeTerminal?.lastLogURL else{return};NSWorkspace.shared.activateFileViewerSelecting([url])}
 func validateMenuItem(_ item:NSMenuItem)->Bool {switch item.action {
  case #selector(findInTerminal),#selector(exportTerminal),#selector(clearTerminal),#selector(largerFont),#selector(smallerFont),#selector(resetFont):return NSApp.keyWindow === window && activeTerminal != nil
  case #selector(stopInputSynchronization):return inputSyncWindow?.runner.isRunning==true
  case #selector(startOutputLog):return NSApp.keyWindow === window && activeTerminal.map{!$0.stopped && $0.pid>0 && !$0.receivedEOF && !$0.isLogging} == true
  case #selector(stopOutputLog):return NSApp.keyWindow === window && activeTerminal?.isLogging == true
  case #selector(revealOutputLog):return NSApp.keyWindow === window && activeTerminal?.lastLogURL != nil
  default:return true
 }}
}
