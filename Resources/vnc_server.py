"""Independent loopback RFB 3.8 fixture; no noVNC code is used here."""
import json, socket, struct, subprocess, sys, time, zlib
from pathlib import Path
root=Path(sys.argv[1]);mode=sys.argv[2]
def note(kind,**values):
 with (root/'events.jsonl').open('a') as f:f.write(json.dumps(dict(kind=kind,**values))+'\n')
def recv(n):
 data=b''
 while len(data)<n:
  chunk=client.recv(n-len(data))
  if not chunk:raise EOFError()
  data+=chunk
 return data
def fragmented(data):
 for i in range(0,len(data),3):client.sendall(data[i:i+3])
def cut_text(data,extended=False):
 length=-len(data) if extended else len(data)
 client.sendall(b'\x03\x00\x00\x00'+struct.pack('!i',length)+data)
def extended(flags,data=b''):
 cut_text(struct.pack('!I',flags)+data,True)
def provide(text):
 data=text.encode('utf-8')+b'\0'
 extended(0x10000001,zlib.compress(struct.pack('!I',len(data))+data))
server=socket.socket();server.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);server.bind(('127.0.0.1',0));server.listen(1);server.settimeout(20);(root/'port.tmp').write_text(str(server.getsockname()[1]));(root/'port.tmp').replace(root/'port')
try:
 client,_=server.accept();client.settimeout(15)
 with client:
  if mode=='timeout':time.sleep(6);raise EOFError()
  fragmented(b'RFB 003.008\n');assert recv(12)==b'RFB 003.008\n'
  if mode=='earlyclose':raise EOFError()
  if mode=='unsupported':client.sendall(b'\x01\xfa');time.sleep(.5);raise EOFError()
  auth=2 if mode in ('auth','wrong') else 1;client.sendall(bytes((1,auth)));assert recv(1)==bytes((auth,))
  if auth==2:
   challenge=bytes(range(16));fragmented(challenge);response=recv(16)
   password=b'TestPass';key=bytes(int(f'{x:08b}'[::-1],2) for x in password)
   expected=subprocess.run(['/usr/bin/openssl','enc','-des-ecb','-K',key.hex(),'-nopad','-nosalt'],input=challenge,capture_output=True,check=True).stdout
   valid=response==expected and mode!='wrong';note('auth',valid=valid)
   if not valid:
    reason=b'Fixture rejected credentials';client.sendall(struct.pack('!II',1,len(reason))+reason);time.sleep(.2);raise EOFError()
  client.sendall(b'\0\0\0\0');assert recv(1)==b'\x01';note('clientinit')
  width,height=(16385,2) if mode=='oversize' else (8192,4096) if mode=='pixelcap' else (4,3)
  pixel=struct.pack('!BBBBHHHBBBxxx',32,24,0,1,255,255,255,16,8,0);name='MacTerm 测试桌面'.encode();fragmented(struct.pack('!HH',width,height)+pixel+struct.pack('!I',len(name))+name)
  updates=0;cut=0;caps=False
  while True:
   kind=recv(1)[0]
   if kind==0:
    recv(3);pixel=recv(16);note('pixel',format=list(pixel))
   elif kind==2:
    recv(1);count=struct.unpack('!H',recv(2))[0];assert count<1024;values=struct.unpack('!'+'i'*count,recv(count*4));note('encodings',values=values)
   elif kind==3:
    request=recv(9);note('request',incremental=request[0]);updates+=1
    if updates==1 and mode!='oversize':
     # Red at x=0; blue at x>0. Pixel format must be 32bpp truecolour.
     bpp,depth,big,true,rm,gm,bm,rs,gs,bs=struct.unpack('!BBBBHHHBBBxxx',pixel);assert bpp==32 and true==1
     colors=[(255,0,0) if x==0 else (0,0,255) for y in range(3) for x in range(4)]
     payload=b''.join(((r<<rs)|(g<<gs)|(b<<bs)).to_bytes(4,'big' if big else 'little') for r,g,b in colors)
     client.sendall(b'\x00\x00\x00\x01'+struct.pack('!HHHHi',0,0,4,3,0)+payload);note('frame')
     if mode=='clipboardLegacy':cut_text('café\n<script>remote</script>'.encode('latin-1'))
     elif mode=='clipboardOversize':cut_text(b'x'*(1048576+1))
     elif mode=='clipboardWire':client.sendall(b'\x03\x00\x00\x00'+struct.pack('!I',4194305))
     elif mode=='clipboardMalformed':extended(0x1f000001)
     elif mode.startswith('clipboard'):
      extended(0x1f000001,struct.pack('!I',0))

    elif updates==2 and mode=='resize':
     client.sendall(b'\x00\x00\x00\x02'+struct.pack('!HHHHi',0,0,6,2,-223)+struct.pack('!HHHHi',0,0,6,2,0)+b'\x00\xff\x00\x00'*12);note('resize')
   elif kind==4:
    down,_,_,key=struct.unpack('!BBBI',recv(7));note('key',down=down,key=key)
   elif kind==5:
    mask,x,y=struct.unpack('!BHH',recv(5));note('pointer',mask=mask,x=x,y=y)
   elif kind==6:
    recv(3);length=struct.unpack('!I',recv(4))[0]
    is_extended=bool(length & 0x80000000)
    if is_extended:length=0x100000000-length
    assert length<=4194304;data=recv(length)
    if not is_extended:
     note('clipboardText',text=data.decode('latin-1'),bytes=len(data));cut+=1
     if mode=='clipboardLegacy':cut_text(('remote update '+str(cut)).encode('latin-1'))
    else:
     assert len(data)>=4;flags=struct.unpack('!I',data[:4])[0];action=flags&0xff000000;note('clipboardAction',flags=flags)
     if action&0x01000000:
      assert flags&1, 'Client must advertise text support';caps=True
      if mode=='clipboardRequestExtra':extended(0x02000001,b'x')
      elif mode=='clipboardNoText':extended(0x10000002,zlib.compress(struct.pack('!I',1)+b'x'))
      elif mode=='clipboardBomb':extended(0x10000001,zlib.compress(struct.pack('!I',2097154)))
      elif mode=='clipboardNegative':extended(0x10000001,zlib.compress(struct.pack('!I',0xffffffff)))
      else:
       # A server cannot pull local contents before the user has submitted any.
       extended(0x02000001);extended(0x08000001)
     elif action==0x02000000:
      provide('远程 😀\r\n<script>text only</script>')
     elif action==0x08000000:
      if mode!='clipboardNoRequest':extended(0x02000001)
     elif action==0x10000000:
      assert caps
      inflator=zlib.decompressobj();decoded=inflator.decompress(data[4:],2097160);assert not inflator.unconsumed_tail;count=struct.unpack('!I',decoded[:4])[0];assert count==len(decoded)-4 and decoded[-1:]==b'\0'
      text=decoded[4:-1].decode('utf-8');note('clipboardText',text=text,bytes=len(decoded)-5);cut+=1
      if mode=='clipboardExtended' and cut==2:time.sleep(.15) # Delayed old remote update races a newer manual empty offer.
      provide('remote update '+str(cut))
   elif kind==248: # Fence extension, only if client sends an initial support probe.
    recv(3);flags=recv(4);length=recv(1)[0];recv(length);note('fence')
   else:raise AssertionError(f'Unexpected client message {kind}')
except EOFError:note('closed')
except Exception as error:note('error',message=repr(error));raise
finally:server.close()
