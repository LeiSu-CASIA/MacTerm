"""Test independent event/transport wakeups without any network or desktop data."""
import json,os,struct,threading,time
from types import SimpleNamespace
from rdp_reader import Reader

def pipe():
    read,write=os.pipe()
    file=os.fdopen(read,'rb',buffering=0)
    return Reader(SimpleNamespace(stdout=file)),file,write

reader,file,write=pipe()
try:
    event=threading.Event();timer=threading.Timer(.15,event.set);timer.start()
    started=time.monotonic();assert reader.until(event.is_set,timeout=1)==[]
    assert event.is_set() and time.monotonic()-started<1
    timer.join()
    started=time.monotonic()
    try:reader.until(lambda:False,timeout=.2);raise AssertionError('Missing deadline')
    except TimeoutError:assert .15<=time.monotonic()-started<1.5
finally:file.close();os.close(write)
reader,file,write=pipe()
try:
    body=b'\x02'+struct.pack('!IIIIII',1,1,0,0,1,1)+bytes([17,34,51,0]);packet=struct.pack('!I',len(body))+body
    def delayed():
        os.write(write,packet[:2]);time.sleep(.15)
        os.write(write,packet[2:12]);time.sleep(.15)
        os.write(write,packet[12:])
    sender=threading.Thread(target=delayed);sender.start()
    messages=reader.until(lambda:reader.pixel(0,0)==(17,34,51),timeout=2);sender.join()
    assert messages==[{'type':'frame'}] and reader.w==reader.h==1
    os.close(write);write=-1
    try:reader.until(lambda:False,timeout=1);raise AssertionError('EOF ignored')
    except AssertionError as error:assert error.args[0]==[None]
finally:
    file.close()
    if write>=0:os.close(write)
print('PASS: RDP test reader observes independent event-file changes without network traffic, retains fragmented packets across poll timeouts, honors total deadlines and rejects EOF')
