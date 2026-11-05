"""Virtual macOS serial devices only. Never enumerates or opens physical hardware."""
import os,pty,select,subprocess,termios,threading,time,uuid
from pathlib import Path
ROOT=Path(__file__).resolve().parent.parent
HELPER=ROOT/'build/MacTerm.app/Contents/MacOS/MacTermSerial'

def read_exact(fd,size,timeout=8):
    data=bytearray();end=time.monotonic()+timeout
    while len(data)<size:
        left=end-time.monotonic()
        assert left>0 and select.select([fd],[],[],left)[0],f'timed out after {len(data)}/{size} bytes'
        chunk=os.read(fd,min(65536,size-len(data)))
        assert chunk,'unexpected EOF';data.extend(chunk)
    return bytes(data)

def ready(process):
    data=bytearray();end=time.monotonic()+4
    while b'\n' not in data:
        left=end-time.monotonic();assert left>0 and select.select([process.stderr],[],[],left)[0],'no serial status'
        chunk=os.read(process.stderr.fileno(),2048);assert chunk,(process.poll(),data);data.extend(chunk)
    assert '串口已连接'.encode() in data,data

def same_settings(left,right):
    # Darwin sets PENDIN when returning from raw to canonical mode. It is a
    # transient kernel input state, not a serial communication setting.
    left=list(left);right=list(right);left[3]&=~termios.PENDIN;right[3]&=~termios.PENDIN
    return left==right

def start(name,*settings):
    return subprocess.Popen([str(HELPER),name,*settings],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)

def stop(process):
    if process.poll() is None: process.terminate()
    process.wait(timeout=3)
    for stream in (process.stdin,process.stdout,process.stderr): stream.close()

def write_all(fd,payload):
    offset=0
    while offset<len(payload): offset+=os.write(fd,payload[offset:])

master,slave=pty.openpty();name=os.ttyname(slave);original=termios.tcgetattr(slave);process=None;threads=[];errors=[]
try:
    process=start(name,'115200','8','none','1','none');ready(process)
    applied=termios.tcgetattr(slave);assert applied[4]==termios.B115200 and applied[5]==termios.B115200
    assert not applied[3]&(termios.ICANON|termios.ECHO|termios.ISIG)
    blocked=start(name,'9600','8','none','1','none');_,message=blocked.communicate(timeout=3);assert blocked.returncode!=0 and message
    assert termios.tcgetattr(slave)==applied
    print('PASS: real termios speed/raw mode and exclusive ownership',flush=True)
    outgoing=bytes(range(256))*4096;incoming='中文 串口\r\n'.encode()+bytes(reversed(range(256)))*4096
    received={}
    def job(action):
        try: action()
        except BaseException as error: errors.append(error)
    actions=[lambda:write_all(process.stdin.fileno(),outgoing),lambda:write_all(master,incoming),lambda:received.update(device=read_exact(master,len(outgoing))),lambda:received.update(terminal=read_exact(process.stdout.fileno(),len(incoming)))]
    for action in actions:
        thread=threading.Thread(target=job,args=(action,),daemon=True);threads.append(thread);thread.start()
    for thread in threads: thread.join(timeout=10)
    assert not any(thread.is_alive() for thread in threads) and not errors,errors
    assert received['device']==outgoing and received['terminal']==incoming
    print('PASS: concurrent 1 MB each direction, all byte values, NUL/control bytes and UTF-8 fidelity',flush=True)
    # Saturate receive output without reading it: transmit must remain independent.
    flood=b'R'*262144;flood_thread=threading.Thread(target=lambda:job(lambda:write_all(master,flood)),daemon=True);flood_thread.start();time.sleep(.1)
    marker=b'TX_WHILE_RX_FULL';write_all(process.stdin.fileno(),marker);assert read_exact(master,len(marker),2)==marker
    assert read_exact(process.stdout.fileno(),len(flood))==flood;flood_thread.join(timeout=3);assert not flood_thread.is_alive() and not errors
    closing=process;closing.terminate()
    process=start(name,'57600','8','none','1','none');ready(process);stop(closing)
    stop(process);process=None;assert same_settings(termios.tcgetattr(slave),original)
    print('PASS: receive backpressure does not stall transmit; immediate reconnect waits for ownership and close restores original device settings',flush=True)
    process=start(name,'9600','8','none','2','software');ready(process);configured=termios.tcgetattr(slave);assert configured[2]&termios.CSTOPB;assert configured[0]&termios.IXON and configured[0]&termios.IXOFF
    write_all(master,b'\x13');time.sleep(.05);write_all(process.stdin.fileno(),b'pending');started=time.monotonic();stop(process);process=None;assert time.monotonic()-started<2 and same_settings(termios.tcgetattr(slave),original)
    print('PASS: software flow control and two stop bits; disconnect stays responsive when output is paused',flush=True)
    process=start(name,'57600','8','none','1','none');ready(process);os.close(master);master=-1;process.wait(timeout=3);assert process.returncode!=0 and '串口已断开'.encode() in process.stderr.read();stop(process);process=None
    print('PASS: reconnect reopens the released device and device loss reports disconnection',flush=True)
finally:
    if process is not None: stop(process)
    if master>=0: os.close(master)
    os.close(slave)
for settings in [('/etc/passwd','9600','8','none','1','none'),('/dev/tty','9600','8','none','1','none'),('/dev/cu.nonexistent-'+uuid.uuid4().hex,'9600','8','none','1','none'),('/dev/ttys000','999999','8','none','1','none')]:
    result=subprocess.run([str(HELPER),*settings],stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=3)
    assert result.returncode!=0 and result.stderr
print('PASS: invalid paths, missing devices and unsupported rates fail without writes',flush=True)
