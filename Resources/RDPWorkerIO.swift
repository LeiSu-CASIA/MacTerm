import Cocoa
import Darwin

struct RDPTile {
 let width:Int,height:Int,x:Int,y:Int,tileWidth:Int,tileHeight:Int,pixels:Data
 init(packet:Data)throws {guard packet.count>=25,packet.first==2 else{throw SFTPError.message("RDP 画面数据无效")};func number(_ offset:Int)->Int{packet[offset..<offset+4].reduce(0){($0<<8)|Int($1)}};let w=number(1),h=number(5),x=number(9),y=number(13),rw=number(17),rh=number(21);guard (64...8192).contains(w),(64...8192).contains(h),w*h<=16000000,rw>0,rh>0,x<=w,y<=h,rw<=w-x,rh<=h-y,rw*rh<=1048576,packet.count==25+rw*rh*4 else{throw SFTPError.message("RDP 画面大小超出限制")};self.width=w;self.height=h;self.x=x;self.y=y;self.tileWidth=rw;self.tileHeight=rh;self.pixels=packet.subdata(in:25..<packet.count)}
}
final class RDPFrameBuffer {
 private(set) var width=0,height=0,pixels=Data()
 func apply(_ tile:RDPTile){if width != tile.width || height != tile.height {width=tile.width;height=tile.height;pixels=Data(count:width*height*4)};pixels.withUnsafeMutableBytes{destination in tile.pixels.withUnsafeBytes{source in guard let dest=destination.baseAddress,let src=source.baseAddress else{return};for row in 0..<tile.tileHeight{memcpy(dest.advanced(by:((tile.y+row)*width+tile.x)*4),src.advanced(by:row*tile.tileWidth*4),tile.tileWidth*4)}}}}
 func image()->CGImage? {guard width>0,height>0,let provider=CGDataProvider(data:pixels as CFData) else{return nil};return CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGBitmapInfo.byteOrder32Little.rawValue|CGImageAlphaInfo.noneSkipFirst.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)}
 func clear(){width=0;height=0;pixels=Data()}
}

enum RDPWorkerPacket {case message([String:Any]);case tile(RDPTile)
 static func decode(_ data:Data)throws->RDPWorkerPacket {guard let type=data.first else{throw SFTPError.message("RDP 内核返回空数据")};if type==2{return .tile(try RDPTile(packet:data))};guard type==1,data.count<=4194305,let value=try JSONSerialization.jsonObject(with:data.dropFirst()) as? [String:Any],let name=value["type"] as? String,name.utf8.count<=64,(data.count<=524289 || ["clipboardReadResult","clipboardOfferResult"].contains(name)) else{throw SFTPError.message("RDP 内核消息格式无效")};return .message(value)}
}
final class RDPWorkerReader {
 private let lock=NSLock();private var cancelled=false;private let fd:Int32
 let onPacket:(RDPWorkerPacket)->Void,onEnd:(Error?)->Void
 init(fd:Int32,onPacket:@escaping(RDPWorkerPacket)->Void,onEnd:@escaping(Error?)->Void)throws {self.fd=dup(fd);guard self.fd>=0 else{throw SFTPError.message("无法创建 RDP 输出通道")};guard fcntl(self.fd,F_SETFD,FD_CLOEXEC)>=0 else{Darwin.close(self.fd);throw SFTPError.message("无法隔离 RDP 输出通道")};self.onPacket=onPacket;self.onEnd=onEnd}
 private var active:Bool {lock.lock();defer{lock.unlock()};return !cancelled}
 func cancel(){lock.lock();cancelled=true;lock.unlock()}
 private func read(_ count:Int)throws->Data? {var data=Data(count:count);var offset=0;try data.withUnsafeMutableBytes{bytes in guard let base=bytes.baseAddress else{return};while offset<count && active {var item=pollfd(fd:fd,events:Int16(POLLIN),revents:0);let result=Darwin.poll(&item,1,100);if result<0&&errno==EINTR{continue};if result<0{throw SFTPError.message("RDP 输出通道读取失败")};if result==0{continue};let n=Darwin.read(fd,base.advanced(by:offset),count-offset);if n<0&&errno==EINTR{continue};if n<0{throw SFTPError.message("RDP 输出通道读取失败")};if n==0{if offset>0{throw SFTPError.message("RDP 内核输出被截断")};return};offset+=n}};return offset==count ? data : nil}
 func start(){DispatchQueue.global(qos:.userInitiated).async{[self] in defer{Darwin.close(fd)};var issue:Error?;do{while active {guard let header=try read(4) else{break};let count=header.reduce(0){($0<<8)|Int($1)};guard (1...4194329).contains(count) else{throw SFTPError.message("RDP 内核输出超过限制")};guard let data=try read(count) else{if active{throw SFTPError.message("RDP 内核消息不完整")};break};let packet=try RDPWorkerPacket.decode(data);DispatchQueue.main.sync{if self.active{self.onPacket(packet)}}}}catch{issue=error};DispatchQueue.main.async{if self.active{self.onEnd(issue)}}}}
}
final class RDPWorkerWriter {
 private let queue=DispatchQueue(label:"local.macterm.rdp-input"),lock=NSLock();private var fd:Int32,pending=0,regularPending=0,finishing=false,failed=false
 let onError:(String)->Void
 init(fd:Int32,onError:@escaping(String)->Void)throws {self.fd=dup(fd);guard self.fd>=0 else{throw SFTPError.message("无法创建 RDP 输入通道")};guard fcntl(self.fd,F_SETFD,FD_CLOEXEC)>=0 else{Darwin.close(self.fd);self.fd = -1;throw SFTPError.message("无法隔离 RDP 输入通道")};signal(SIGPIPE,SIG_IGN);self.onError=onError}
 func send(_ object:[String:Any]){do{let data=try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]);let clipboard=object["type"] as? String == "clipboardOffer";guard !data.isEmpty,data.count<=(clipboard ? 4194304 : 65536) else{failure("RDP 输入消息过大");return};var size=UInt32(data.count).bigEndian;var packet=withUnsafeBytes(of:&size){Data($0)};packet.append(data);lock.lock();guard fd>=0,!finishing else{lock.unlock();return};guard pending+packet.count<=8388608,(clipboard || regularPending+packet.count<=1048576) else{lock.unlock();failure("RDP 输入队列超过限制，连接已停止");return};pending+=packet.count;if !clipboard{regularPending+=packet.count};lock.unlock();queue.async{[self] in defer{lock.lock();pending-=packet.count;if !clipboard{regularPending-=packet.count};lock.unlock()};lock.lock();let target=fd>=0 ? dup(fd) : -1;lock.unlock();guard target>=0 else{return};guard fcntl(target,F_SETFD,FD_CLOEXEC)>=0 else{Darwin.close(target);failure("无法隔离 RDP 输入操作");return};defer{Darwin.close(target)};var ok=true;packet.withUnsafeBytes{bytes in guard let base=bytes.baseAddress else{return};var offset=0;while offset<packet.count {let n=Darwin.write(target,base.advanced(by:offset),packet.count-offset);if n<0&&errno==EINTR{continue};if n<=0{ok=false;break};offset+=n}};if !ok{failure("RDP 输入通道已关闭")}}}catch{failure("无法编码 RDP 输入")}}
 private func failure(_ message:String){lock.lock();let report = !failed && !finishing;failed=true;if fd>=0{Darwin.close(fd);fd = -1};lock.unlock();if report{DispatchQueue.main.async{[onError] in onError(message)}}}
 func finish(){lock.lock();guard !finishing else{lock.unlock();return};finishing=true;lock.unlock();queue.async{[self] in lock.lock();if fd>=0{Darwin.close(fd);fd = -1};lock.unlock()}}
 deinit{if fd>=0{Darwin.close(fd)}}
}
