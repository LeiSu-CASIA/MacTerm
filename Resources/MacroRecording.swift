import Cocoa

struct RecordedInput:Codable,Equatable,Hashable {
 var input:String;var delayMilliseconds:Int
 static func ==(a:RecordedInput,b:RecordedInput)->Bool {Data(a.input.utf8)==Data(b.input.utf8) && a.delayMilliseconds==b.delayMilliseconds}
 func hash(into hasher:inout Hasher){hasher.combine(Data(input.utf8));hasher.combine(delayMilliseconds)}
}
enum MacroRecordingChange {case started,progress,stopped(String)}
final class MacroRecorder {
 static let maximumEvents=10000,maximumBytes=65536,maximumMilliseconds=600000
 private(set) var isRecording=false;private(set) var events=[RecordedInput]();private(set) var bytes=0;private(set) var targetID:UUID?
 var changed:((MacroRecordingChange)->Void)?
 private let clock:()->TimeInterval;private var started:TimeInterval=0,last:TimeInterval=0;private var available:(()->Bool)?;private var generation=UUID()
 init(clock:@escaping()->TimeInterval={ProcessInfo.processInfo.systemUptime}){self.clock=clock}
 var recordingIdentity:UUID {generation}
 func start(target:UUID,available:@escaping()->Bool)throws {guard !isRecording else{throw SFTPError.message("已有录制正在进行")};let ready=available();guard !isRecording,ready else{throw SFTPError.message("录制目标未就绪或已有录制正在进行")};generation=UUID();targetID=target;self.available=available;events=[];bytes=0;started=clock();last=started;isRecording=true;changed?(.started)}
 func capture(_ input:String,from target:UUID){guard isRecording,target==targetID,!input.isEmpty else{return};let token=generation;poll();guard token==generation,isRecording,target==targetID else{return};let count=input.utf8.count;guard events.count<Self.maximumEvents,count<=Self.maximumBytes-bytes else{stop("达到 10000 个输入事件或 64 KB 上限，已停止录制");return};let now=clock();let delay=events.isEmpty ? 0 : Int((max(0,now-last)*1000).rounded());events.append(RecordedInput(input:input,delayMilliseconds:delay));bytes+=count;last=now;changed?(.progress)}
 func poll(){guard isRecording else{return};let token=generation;let ready=available?()==true;guard token==generation,isRecording else{return};if !ready{stop("原录制连接已结束，已停止录制")}else if clock()-started>Double(Self.maximumMilliseconds)/1000{stop("录制达到 10 分钟，已停止录制")}}
 func stop(_ reason:String="录制已停止"){guard isRecording else{return};isRecording=false;generation=UUID();available=nil;changed?(.stopped(reason))}
 func draft(name:String)throws->TerminalMacro {try TerminalMacro(name:name,body:"",intervalMilliseconds:0,sendReturn:false,events:events).validated()}
 static func json(_ events:[RecordedInput])throws->String {let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes];let json=String(decoding:try encoder.encode(events),as:UTF8.self);return json.unicodeScalars.map{scalar -> String in let value=scalar.value;return value==127 || (128...159).contains(value) || (0x200e...0x200f).contains(value) || (0x2028...0x202e).contains(value) || (0x2066...0x2069).contains(value) ? String(format:"\\u%04x",value) : String(scalar)}.joined()}
 static func decode(_ value:String)throws->[RecordedInput] {guard value.utf8.count<=MacroStore.maximumBytes else{throw SFTPError.message("录制事件 JSON 超过 2 MB")};return try JSONDecoder().decode([RecordedInput].self,from:Data(value.utf8))}
}
