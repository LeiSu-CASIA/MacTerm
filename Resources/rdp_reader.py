import json,os,select,struct,time

class Reader:
 def __init__(self,process):self.process=process;self.buffer=bytearray();self.pixels=bytearray();self.w=self.h=0
 def packet(self,timeout=10):
  end=time.monotonic()+timeout
  while True:
   if len(self.buffer)>=4:
    length=struct.unpack('!I',self.buffer[:4])[0];assert 0<length<=4194329
    if len(self.buffer)>=4+length:
     packet=bytes(self.buffer[4:4+length]);del self.buffer[:4+length]
     if packet[0]==1:return json.loads(packet[1:])
     assert packet[0]==2 and len(packet)>=25
     w,h,x,y,rw,rh=struct.unpack('!IIIIII',packet[1:25]);assert 0<w<=8192 and 0<h<=8192 and w*h<=16000000 and x+rw<=w and y+rh<=h and len(packet)==25+rw*rh*4
     if (w,h)!=(self.w,self.h):self.w,self.h=w,h;self.pixels=bytearray(w*h*4)
     for row in range(rh):self.pixels[((y+row)*w+x)*4:((y+row)*w+x+rw)*4]=packet[25+row*rw*4:25+(row+1)*rw*4]
     return {'type':'frame'}
   left=end-time.monotonic()
   if left<=0:raise TimeoutError('RDP worker packet timeout')
   ready,_,_=select.select([self.process.stdout],[],[],left)
   if not ready:raise TimeoutError('RDP worker data timeout')
   data=os.read(self.process.stdout.fileno(),65536)
   if not data:return None
   self.buffer+=data
 def pixel(self,x,y):return tuple(self.pixels[(y*self.w+x)*4:(y*self.w+x)*4+3]) if self.pixels else None
 def until(self,predicate,timeout=12):
  end=time.monotonic()+timeout;messages=[]
  # Predicates also observe a server event file. That file can change after the
  # last frame, without another network packet to wake select(). Keep checking
  # both channels within the original deadline; packet() retains partial data.
  while not predicate():
   remaining=end-time.monotonic()
   if remaining<=0:raise TimeoutError(messages)
   try:item=self.packet(min(.1,remaining))
   except TimeoutError:continue
   messages.append(item)
   if item is None or item.get('type')=='failed':raise AssertionError(messages)
  return messages
