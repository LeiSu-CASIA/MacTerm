#!/usr/bin/env python3
"""Disposable loopback Telnet peers; never contacts a configured user server."""
import contextlib,fcntl,json,os,pathlib,select,signal,socket,struct,subprocess,tempfile,termios,threading,time,tty,uuid
ROOT=pathlib.Path(__file__).resolve().parent.parent
HELPER=ROOT/'build/MacTermTelnet'
IAC=255

def wire(data): return data.replace(b'\xff',b'\xff\xff')
def exact(conn,count):
    data=bytearray()
    while len(data)<count:
        part=conn.recv(count-len(data))
        assert part,('early EOF',len(data),count)
        data.extend(part)
    return bytes(data)
def expect(conn,data):
    received=exact(conn,len(data));assert received==data,(received,data)
@contextlib.contextmanager
def listener(family=socket.AF_INET):
    with socket.socket(family,socket.SOCK_STREAM) as service:
        service.bind(('::1' if family==socket.AF_INET6 else '127.0.0.1',0));service.listen(2);service.settimeout(10)
        yield service
@contextlib.contextmanager
def helper(service,**options):
    host=service.getsockname()[0];port=service.getsockname()[1]
    process=subprocess.Popen([str(HELPER),host,str(port),'5','xterm-256color','automatic'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,**options)
    try: yield process
    finally:
        if process.poll() is None:
            process.terminate()
            try:process.wait(timeout=2)
            except subprocess.TimeoutExpired:process.kill();process.wait(timeout=2)
        for stream in [process.stdin,process.stdout,process.stderr]:
            if stream:
                try:stream.close()
                except OSError:pass

def handshake(conn):
    conn.settimeout(10)
    for request,response in [(bytes([IAC,251,1]),bytes([IAC,253,1])),(bytes([IAC,253,0]),bytes([IAC,251,0])),(bytes([IAC,251,0]),bytes([IAC,253,0])),(bytes([IAC,253,24]),bytes([IAC,251,24]))]:
        conn.sendall(request);expect(conn,response)
    conn.sendall(bytes([IAC,250,24,1,IAC,240]));expect(conn,bytes([IAC,250,24,0])+b'xterm-256color'+bytes([IAC,240]))
    conn.sendall(bytes([IAC,253,31]));expect(conn,bytes([IAC,251,31,IAC,250,31,0,80,0,24,IAC,240]))
    conn.sendall(bytes([IAC,253,31]));assert not select.select([conn],[],[],0.08)[0], 'duplicate DO generated a loop'
    conn.sendall(bytes([IAC,253,42]));expect(conn,bytes([IAC,252,42]))

def duplex():
    with listener() as service,helper(service) as process:
        conn,_=service.accept()
        with conn:
            handshake(conn)
            payload=(bytes(range(256))*4096)+"中文终端\r\n".encode();stuffed=wire(payload)
            output=[];failures=[]
            def receive_output():output.append(process.stdout.read())
            def send_input():
                try:process.stdin.write(payload);process.stdin.close()
                except Exception as error:failures.append(error)
            def send_peer():
                try:conn.sendall(stuffed)
                except Exception as error:failures.append(error)
            reader=threading.Thread(target=receive_output,daemon=True);writer=threading.Thread(target=send_input,daemon=True);peer=threading.Thread(target=send_peer,daemon=True)
            reader.start();writer.start();peer.start();received=exact(conn,len(stuffed));assert received==stuffed
            writer.join(10);peer.join(10);assert not writer.is_alive() and not peer.is_alive() and not failures,failures
            conn.shutdown(socket.SHUT_WR);assert process.wait(timeout=10)==0;reader.join(3);assert output==[payload],(len(output[0]) if output else 0,len(payload))
    print('PASS: actual Telnet negotiation, TTYPE/NAWS, duplicate suppression, concurrent 1 MB all-byte/UTF-8 fidelity, IAC stuffing and EOF drain',flush=True)

def backpressure():
    with listener() as service,helper(service) as process:
        conn,_=service.accept()
        with conn:
            handshake(conn);finished=threading.Event()
            def flood():
                try:conn.sendall(b'R'*(32*1024*1024))
                except OSError:pass
                finally:finished.set()
            sender=threading.Thread(target=flood,daemon=True);sender.start();time.sleep(0.25);assert not finished.is_set(),'receive backpressure was not established'
            message=b'TX-WHILE-RX-BLOCKED';process.stdin.write(message);process.stdin.flush();expect(conn,message)
            start=time.monotonic();process.terminate();process.wait(timeout=2);assert time.monotonic()-start<1.5
            try:conn.shutdown(socket.SHUT_RDWR)
            except OSError:pass
            sender.join(2)
    print('PASS: receive backpressure does not block outgoing input; stop stays responsive with a full terminal output queue',flush=True)

def terminal_resize():
    master,slave=os.openpty();original=termios.tcgetattr(slave)
    fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',24,80,0,0))
    process=None
    try:
        with listener() as service:
            process=subprocess.Popen([str(HELPER),'127.0.0.1',str(service.getsockname()[1]),'5','vt100','off'],stdin=slave,stdout=slave,stderr=subprocess.PIPE,start_new_session=True)
            conn,_=service.accept()
            with conn:
                conn.settimeout(5);conn.sendall(bytes([IAC,253,31]));expect(conn,bytes([IAC,251,31,IAC,250,31,0,80,0,24,IAC,240]))
                fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',511,255,0,0));process.send_signal(signal.SIGWINCH);expect(conn,bytes([IAC,250,31,0,255,255,1,255,255,IAC,240]))
                conn.sendall(bytes([IAC,254,31]));expect(conn,bytes([IAC,252,31]));fcntl.ioctl(slave,termios.TIOCSWINSZ,struct.pack('HHHH',30,100,0,0));process.send_signal(signal.SIGWINCH);assert not select.select([conn],[],[],0.15)[0]
                os.write(master,b'X\r\n\x03');expect(conn,b'X\r\n\x03');assert process.poll() is None
                process.terminate();assert process.wait(timeout=2)==0
                restored=termios.tcgetattr(slave);restored[3]&=~getattr(termios,'PENDIN',0);original[3]&=~getattr(termios,'PENDIN',0);assert restored==original
    finally:
        if process:
            if process.poll() is None:process.kill();process.wait(timeout=2)
            process.stderr.close()
        os.close(master);os.close(slave)
    print('PASS: raw PTY Ctrl-C delivery, fragmented CRLF, resize/IAC-255 escaping, NAWS disable and terminal restoration',flush=True)

def ipv6_and_errors():
    try:service=socket.socket(socket.AF_INET6,socket.SOCK_STREAM);service.bind(('::1',0))
    except OSError as error:
        print('SKIP: loopback IPv6 unavailable:',error,flush=True)
        try:service.close()
        except Exception:pass
    else:
        with service:
            service.listen(1);service.settimeout(5)
            with helper(service) as process:
                conn,_=service.accept()
                with conn:conn.sendall(b'IPv6-OK\r\n');conn.shutdown(socket.SHUT_WR);assert process.wait(timeout=5)==0;assert process.stdout.read()==b'IPv6-OK\r\n'
        print('PASS: real IPv6 loopback Telnet connection and final output',flush=True)
    with socket.socket() as unused:unused.bind(('127.0.0.1',0));port=unused.getsockname()[1]
    refused=subprocess.run([str(HELPER),'127.0.0.1',str(port),'1','vt100','off'],capture_output=True,timeout=3);assert refused.returncode==1 and '连接失败'.encode() in refused.stderr
    invalid=subprocess.run([str(HELPER),'127.0.0.1','0','5','vt100','off'],capture_output=True,timeout=2);assert invalid.returncode==2
    print('PASS: connection refusal and invalid port return errors',flush=True)

def resolver_deadline():
    subprocess.run(['/usr/bin/clang','-dynamiclib','-Wall','-Wextra','-Werror',str(ROOT/'Tests/TelnetResolverDelay.c'),'-o',str(ROOT/'build/telnet-resolver-delay.dylib')],check=True,capture_output=True)
    subprocess.run(['/usr/bin/codesign','--force','--sign','-',str(ROOT/'build/telnet-resolver-delay.dylib')],check=True,capture_output=True)
    environment=dict(os.environ,DYLD_INSERT_LIBRARIES=str(ROOT/'build/telnet-resolver-delay.dylib'))
    start=time.monotonic();result=subprocess.run([str(HELPER),'127.0.0.1','9','1','vt100','off'],capture_output=True,timeout=3,env=environment)
    assert result.returncode==1 and '名称解析超时'.encode() in result.stderr,result.stderr
    assert 0.8<time.monotonic()-start<2.5
    master,slave=os.openpty();original=termios.tcgetattr(slave);process=None
    try:
        process=subprocess.Popen([str(HELPER),'127.0.0.1','9','15','vt100','off'],stdin=slave,stdout=slave,stderr=subprocess.PIPE,env=environment)
        deadline=time.monotonic()+2
        while termios.tcgetattr(slave)[3]&termios.ICANON and time.monotonic()<deadline:time.sleep(0.01)
        assert process.poll() is None and not termios.tcgetattr(slave)[3]&termios.ICANON
        start=time.monotonic();process.terminate();assert process.wait(timeout=2)==0;assert time.monotonic()-start<1.5
        restored=termios.tcgetattr(slave);restored[3]&=~getattr(termios,'PENDIN',0);original[3]&=~getattr(termios,'PENDIN',0);assert restored==original
    finally:
        if process:
            if process.poll() is None:process.kill();process.wait(timeout=2)
            process.stderr.close()
        os.close(master);os.close(slave)
    print('PASS: stalled system resolver obeys total deadline; close during DNS restores the terminal without waiting for the resolver',flush=True)

class Decoder:
    def __init__(self):self.state=0;self.verb=0;self.sub=bytearray();self.data=bytearray();self.frames=[]
    def feed(self,chunk):
        for byte in chunk:
            if self.state==0:
                if byte==IAC:self.state=1
                else:self.data.append(byte)
            elif self.state==1:
                if byte==IAC:self.data.append(byte);self.state=0
                elif byte in (251,252,253,254):self.verb=byte;self.state=2
                elif byte==250:self.sub=bytearray();self.state=3
                else:self.state=0
            elif self.state==2:self.frames.append((self.verb,byte));self.state=0
            elif self.state==3:
                if byte==IAC:self.state=4
                else:self.sub.append(byte)
            elif self.state==4:
                if byte==240:self.frames.append(bytes(self.sub));self.state=0
                elif byte==IAC:self.sub.append(byte);self.state=3
                else:raise AssertionError('invalid Telnet frame')

def app_fixture():
    with tempfile.TemporaryDirectory(prefix='macterm-telnet-') as folder,listener() as service:
        folder=pathlib.Path(folder);fixture=folder/'session.json';fixture.write_text(json.dumps(dict(name='Telnet fixture',host='127.0.0.1',user='',port=service.getsockname()[1],key='',connectionTimeout=5,id=str(uuid.uuid4()),kind='telnet',telnet=dict(terminalType='xterm-256color',echo='automatic'))));fixture.chmod(0o600)
        records=[];failures=[];connections=[]
        def serve():
            try:
                for index in range(2):
                    conn,_=service.accept();connections.append(conn)
                    with conn:
                        conn.settimeout(12);decoder=Decoder();records.append(decoder);first=macro=resize=broadcast=False
                        conn.sendall(bytes([IAC,251,1,IAC,253,0,IAC,251,0,IAC,253,24,IAC,253,31,IAC,250,24,1,IAC,240])+b'GREETING '+"中文".encode()+b'\r\n')
                        while True:
                            part=conn.recv(8192)
                            if not part:break
                            decoder.feed(part)
                            if index==0:
                                if not first and b'FIRST '+"中文".encode()+b'\r\n\x03' in decoder.data:conn.sendall(b'ACK_FIRST\r\n');first=True
                                if not macro and b'MACRO TWO\r\n' in decoder.data:conn.sendall(b'MACRO_DONE\r\n');macro=True
                                if not resize and bytes([31,0,255,1,255]) in decoder.frames:conn.sendall(b'RESIZE_OK\r\n');resize=True
                                if not broadcast and b'TELNET_BROADCAST\r\n' in decoder.data:conn.sendall(b'BROADCAST_ACK\r\n');broadcast=True
                            elif b'SECOND\r\n' in decoder.data:conn.sendall(b'SECOND_ACK\r\n');conn.shutdown(socket.SHUT_WR);break
                        if index==0:assert first and macro and resize and broadcast,(first,macro,resize,broadcast)
                        assert bytes([24,0])+b'xterm-256color' in decoder.frames,decoder.frames
            except BaseException as error:failures.append(error)
        server=threading.Thread(target=serve,daemon=True);server.start()
        try:
            result=subprocess.run([str(ROOT/'build/telnet-test'),'--telnet-fixture',str(fixture)],capture_output=True,timeout=35)
            if result.returncode:raise AssertionError(result.stderr.decode(errors='replace')[-10000:]+result.stdout.decode(errors='replace'))
            server.join(3);assert not server.is_alive() and not failures,failures;assert len(records)==2 and all(b'STALE' not in record.data for record in records)
            assert b'PASS: real Telnet profile launch' in result.stdout
        finally:
            for conn in connections:
                try:conn.shutdown(socket.SHUT_RDWR)
                except OSError:pass
                conn.close()
    print('PASS: AppKit profile launch/reconnect, UTF-8 and Ctrl-C, actual PTY NAWS, logging, macro/broadcast replay, stale-input isolation and disconnect',flush=True)

if __name__=='__main__':
    duplex();backpressure();terminal_resize();ipv6_and_errors();resolver_deadline();app_fixture()
