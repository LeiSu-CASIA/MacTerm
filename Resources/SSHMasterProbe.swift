import Foundation
import Darwin

/// Local mux check only: -O check never starts a new network connection. The
/// returned master PID must be this pane's owned SSH process, not just a socket.
final class SSHMasterProbe {
 private let lock=NSLock();private var stopped=false,running=false;private var task:Process?
 static func matches(_ data:Data,pid:Int32)->Bool {
  guard pid>0,data.count<=4096,let value=String(data:data,encoding:.utf8) else{return false}
  return value.trimmingCharacters(in:.whitespacesAndNewlines)=="Master running (pid=\(pid))"
 }
 func check(host:String,socket:String,pid:Int32,completion:@escaping(Bool)->Void){
  lock.lock();guard !stopped,!running,pid>0 else{lock.unlock();return};running=true;lock.unlock()
  DispatchQueue.global().async{[self] in
   var value=stat();var ready=false
   if lstat(socket,&value)==0,value.st_mode&0o170000==0o140000 {
    let process=Process(),errors=Pipe();process.executableURL=URL(fileURLWithPath:"/usr/bin/ssh");process.arguments=["-F","/dev/null","-o","LogLevel=INFO","-S",socket,"-O","check","--",host];process.standardInput=FileHandle.nullDevice;process.standardOutput=FileHandle.nullDevice;process.standardError=errors
    lock.lock();if !stopped {do{try process.run();task=process}catch{}};let launched=task === process;lock.unlock()
    if launched {
     let timeout=DispatchWorkItem{[weak process] in if let process=process,process.isRunning{process.terminate()}};DispatchQueue.global().asyncAfter(deadline:.now()+1.5,execute:timeout)
     var output=Data(),overflow=false
     while let bytes=try? errors.fileHandleForReading.read(upToCount:1024),!bytes.isEmpty {if bytes.count>4096-output.count{overflow=true;if process.isRunning{process.terminate()}}else if !overflow{output.append(bytes)}}
     process.waitUntilExit();timeout.cancel();ready = !overflow && process.terminationStatus==0 && Self.matches(output,pid:pid)
    }
   }
   lock.lock();task=nil;running=false;let cancelled=stopped;lock.unlock();let result=ready
   DispatchQueue.main.async{[self] in lock.lock();let active = !stopped;lock.unlock();if !cancelled && active{completion(result)}}
  }
 }
 func stop(){lock.lock();stopped=true;let process=task;lock.unlock();if let process=process,process.isRunning{process.terminate()}}
 deinit{stop()}
}
