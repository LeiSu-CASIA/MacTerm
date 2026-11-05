"""Real NLA/cliprdr traffic with a synthetic loopback peer and no OS clipboard."""
import base64,json,os,struct,subprocess,tempfile,time,shutil
from pathlib import Path
from rdp_reader import Reader
base=Path(tempfile.mkdtemp(prefix='macterm-rdp-clipboard-',dir='build')).resolve();keep=False

def send(worker,obj):
 data=json.dumps(obj,ensure_ascii=False).encode();worker.stdin.write(struct.pack('!I',len(data))+data);worker.stdin.flush()
def events(root):
 try:return [json.loads(line) for line in (root/'events.jsonl').read_text().splitlines()]
 except FileNotFoundError:return []
class Inbox:
 def __init__(self,worker):self.reader=Reader(worker);self.messages=[]
 def wait(self,predicate,timeout=14,allow_failure=False):
  end=time.monotonic()+timeout
  while True:
   if predicate(self.messages):return
   try:item=self.reader.packet(max(.01,end-time.monotonic()))
   except TimeoutError:raise TimeoutError(self.messages[-10:])
   assert item is not None,'Worker closed before expected clipboard event'
   self.messages.append(item)
   if item.get('type')=='certificate':send(self.reader.process,dict(type='certificateReply',id=item['id'],accept=True))
   if not allow_failure:assert item.get('type')!='failed',item
   assert time.monotonic()<end,self.messages[-10:]
 def result(self,kind,id):
  self.wait(lambda values:any(v.get('type')==kind and v.get('id')==id for v in values))
  return next(v for v in self.messages if v.get('type')==kind and v.get('id')==id)
try:
 modes=['normal','large','bad','oversize','stale','unsupported','readonly','reject','read-timeout','offer-timeout','bomb']
 if '--quick' in os.sys.argv:modes=['normal']
 for mode in modes:
  root=base/mode;root.mkdir();serverlog=(root/'server.log').open('wb');workerlog=(root/'worker.log').open('wb');worker=None;server=subprocess.Popen(['/usr/bin/python3','Tests/rdp_fixture.py',str(root),'clipboard-'+mode],stdout=serverlog,stderr=serverlog)
  try:
   end=time.monotonic()+12
   while not (root/'port').exists() and time.monotonic()<end:
    assert server.poll() is None,'Fixture stopped';time.sleep(.01)
   port=int((root/'port').read_text());worker=subprocess.Popen(['build/MacTermRDP'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=workerlog);inbox=Inbox(worker);hello=inbox.reader.packet();assert hello['type']=='hello' and hello.get('clipboardProtocol')==1
   send(worker,dict(type='connect',host='127.0.0.1',port=port,user='testuser',domain='',password='RdpTestPass',configPath=str(root/'client-config'),width=320,height=240,timeout=5,requireNLA=True,viewOnly=mode=='readonly',clipboard=True))
   inbox.wait(lambda v:any(x.get('type')=='connected' for x in v) and any(x.get('type')=='clipboardState' and x.get('ready') and x.get('revision',0)>=1 for x in v))
   assert not any(e['type'] in ('clipRead','clipOffer') for e in events(root)),'Clipboard fetched/offered without user action'
   send(worker,dict(type='clipboardRead',id=1))
   if mode=='bomb':
    inbox.wait(lambda values:any(v.get('type')=='failed' for v in values),allow_failure=True)
    print('PASS: oversized cliprdr transport rejected before unbounded fragment allocation',flush=True);continue
   result=inbox.result('clipboardReadResult',1)
   if mode in ['normal','large','readonly','reject','offer-timeout']:
    assert result['ok'],result;decoded=base64.b64decode(result['data']).decode('utf-16-le');expected=('a'*1048576 if mode=='large' else 'remote 中文 😀\r\n')+'\0';assert decoded==expected,(mode,len(decoded))
   else:assert not result['ok'],result
   if mode=='read-timeout':
    inbox.wait(lambda v:any(x.get('type')=='clipboardState' and x.get('readBlocked') for x in v));send(worker,dict(type='clipboardRead',id=3));assert not inbox.result('clipboardReadResult',3)['ok'];assert sum(e['type']=='clipRead' for e in events(root))==1
   if mode=='unsupported':assert not any(e['type']=='clipRead' for e in events(root))
   text=('b'*1048576 if mode=='large' else 'local 中文 😀\r\n');wire=(text+'\0').encode('utf-16-le');send(worker,dict(type='clipboardOffer',id=2,data=base64.b64encode(wire).decode()))
   result=inbox.result('clipboardOfferResult',2)
   if mode in ['readonly','reject','offer-timeout']:assert not result['ok'],result
   else:
    assert result['ok'],result;inbox.reader.until(lambda:any(e['type']=='clipReceived' for e in events(root)));received=next(e for e in events(root) if e['type']=='clipReceived');assert received['flags']==1 and base64.b64decode(received['data'])==wire
   if mode=='readonly':assert not any(e['type']=='clipOffer' for e in events(root))
   if mode=='offer-timeout':
    inbox.wait(lambda v:any(x.get('type')=='clipboardState' and x.get('offerBlocked') for x in v));send(worker,dict(type='clipboardOffer',id=4,data=base64.b64encode(wire).decode()));assert not inbox.result('clipboardOfferResult',4)['ok'];assert sum(e['type']=='clipOffer' for e in events(root))==1
   send(worker,dict(type='stop'))
   while inbox.reader.packet(timeout=5) is not None:pass
   worker.wait(timeout=5);assert worker.returncode==0
   print('PASS:',mode,'real NLA clipboard Unicode/bounds, manual fetch/offer, acknowledgement, stale/timeout/readonly guards and shutdown',flush=True)
  finally:
   for process in [worker,server]:
    if process is not None and process.poll() is None:
     process.terminate()
     try:process.wait(timeout=3)
     except subprocess.TimeoutExpired:process.kill();process.wait()
   serverlog.close();workerlog.close()
except BaseException:
 keep=True;print('Retained RDP clipboard fixture:',base,flush=True);raise
finally:
 if not keep:shutil.rmtree(base)
