"""Exercise real TLS/NLA RDP traffic through the bounded worker protocol."""
import json,os,select,shutil,struct,subprocess,tempfile,time
from pathlib import Path
base=Path(tempfile.mkdtemp(prefix='macterm-rdp-engine-',dir='build')).resolve();keep=False
from rdp_reader import Reader
def send(process,message):
 data=json.dumps(message,ensure_ascii=False).encode();process.stdin.write(struct.pack('!I',len(data))+data);process.stdin.flush()
def events(root):
 try:return [json.loads(line) for line in (root/'events.jsonl').read_text().splitlines()]
 except FileNotFoundError:return []
try:
 for name,server_mode,require_nla,password,accept,readonly in [
  ('tls','tls',False,'RdpTestPass',True,False),('nla','nla',True,'RdpTestPass',True,False),('wrong','nla',True,'wrong-password',True,False),('certificate-denied','nla',True,'RdpTestPass',False,False),('nla-required','tls',True,'RdpTestPass',True,False),('readonly','nla',True,'RdpTestPass',True,True),('resize','resize',True,'RdpTestPass',True,False),('resize-oversize','resize-oversize',True,'RdpTestPass',True,False)]:
  root=base/name;root.mkdir();serverlog=(root/'server.log').open('wb');workerlog=(root/'worker.log').open('wb');server=subprocess.Popen(['/usr/bin/python3','Tests/rdp_fixture.py',str(root),server_mode],stdout=serverlog,stderr=serverlog);worker=None
  try:
   end=time.monotonic()+12
   while not (root/'port').exists() and time.monotonic()<end:
    assert server.poll() is None,'Fixture terminated';time.sleep(.01)
   port=int((root/'port').read_text());worker=subprocess.Popen(['build/MacTermRDP'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=workerlog);reader=Reader(worker)
   assert reader.packet()['type']=='hello'
   config=dict(type='connect',host='127.0.0.1',port=port,user='testuser',domain='',password=password,configPath=str(root/'client-config'),width=320,height=240,timeout=5,requireNLA=require_nla,viewOnly=readonly)
   send(worker,config);send(worker,dict(type='key',code=32,down=True,extended=False))
   connected=False;certificates=0;failure=None;end=time.monotonic()+12
   while time.monotonic()<end:
    item=reader.packet()
    if item is None:break
    if item['type']=='certificate':
     certificates+=1;assert item['host']=='127.0.0.1' and item['port']==port and 'BEGIN CERTIFICATE' in item['pem'];send(worker,dict(type='certificateReply',id=item['id']+1,accept=True));send(worker,dict(type='certificateReply',id=item['id'],accept=accept))
    elif item['type']=='connected':
     assert item['security']==('TLS' if name=='tls' else 'NLA');connected=True
    elif item['type']=='failed':failure=item;break
    if connected and reader.pixel(5,5)==(0,0,255) and reader.pixel(40,5)==(255,0,0) and reader.pixel(5,40)==(0,255,0):break
   if name in ('wrong','certificate-denied','nla-required'):
    assert not connected and failure,(name,connected,failure)
    if name=='certificate-denied':assert not any(x['type']=='logon' for x in events(root))
    print('PASS:',name,'fails without a false connected state',flush=True);continue
   assert connected and certificates==1 and reader.pixel(40,40)==(0,255,255),(name,connected,certificates,reader.pixel(5,5))
   assert not any(x['type']=='key' for x in events(root)), 'Pre-authentication input leaked'
   send(worker,dict(type='text',text='中😀'));send(worker,dict(type='mouse',flags=0x9000,x=12,y=20));send(worker,dict(type='key',code=0x2e,down=True,extended=False));send(worker,dict(type='key',code=0x2e,down=False,extended=False));send(worker,dict(type='ctrlaltdel'))
   if readonly:
    time.sleep(.2);assert not any(x['type'] in ('key','mouse','unicode') for x in events(root))
   else:
    reader.until(lambda:any(x['type']=='mouse' for x in events(root)) and len([x for x in events(root) if x['type']=='unicode'])>=6 and reader.pixel(82,2)==(0,255,0))
    values=events(root);codes=[x['code'] for x in values if x['type']=='unicode' and not(x['flags']&0x8000)];assert codes==[0x4e2d,0xd83d,0xde00],codes
    assert any(x['type']=='mouse' and x['x']==12 and x['y']==20 for x in values)
   if name.startswith('resize'):
    send(worker,dict(type='key',code=0x13,down=True,extended=False))
    if name=='resize-oversize':
     while True:
      message=reader.packet()
      assert message is not None
      if message.get('type')=='failed':break
     assert reader.w<=480 and reader.h<=320
     print('PASS: negotiated desktop oversize rejected before framebuffer allocation',flush=True);continue
    reader.until(lambda:reader.w==480 and reader.h==320 and reader.pixel(5,5)==(0,0,255))
    assert reader.pixel(82,2)==(0,0,0)
    send(worker,dict(type='key',code=0x13,down=False,extended=False))
   send(worker,dict(type='stop'))
   while reader.packet(timeout=5) is not None:pass
   worker.wait(timeout=5);assert worker.returncode==0
   for file in root.rglob('*'):
    if file.is_file():assert b'RdpTestPass' not in file.read_bytes(), 'Plaintext credential file: '+str(file)
   print('PASS:',name,'real TLS/NLA, bitmap colours/orientation, Unicode/keyboard/mouse and bounded process shutdown',flush=True)
  finally:
   for process in [worker,server]:
    if process is not None and process.poll() is None:
     process.terminate()
     try:process.wait(timeout=3)
     except subprocess.TimeoutExpired:process.kill();process.wait()
   serverlog.close();workerlog.close()
 # Invalid local worker input must fail before any network or large allocation.
 for mode in ['oversize-header','invalid-image']:
  worker=subprocess.Popen(['build/MacTermRDP'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL);reader=Reader(worker)
  try:
   assert reader.packet()['type']=='hello'
   if mode=='oversize-header':worker.stdin.write(struct.pack('!I',65537));worker.stdin.flush()
   else:send(worker,dict(type='connect',host='127.0.0.1',port=9,user='u',domain='',password='fake',configPath=str(base/'invalid'),width=8192,height=8192,timeout=1,requireNLA=True,viewOnly=False))
   assert reader.packet()['type']=='failed';worker.stdin.close()
   while reader.packet(timeout=3) is not None:pass
   worker.wait(timeout=3);assert worker.returncode!=0
   print('PASS:',mode,'local IPC fails with bounded allocation and no connection',flush=True)
  finally:
   if worker.poll() is None:worker.terminate();worker.wait(timeout=3)
except BaseException:
 keep=True;print('Kept failing fixture:',base,flush=True);raise
finally:
 if not keep:shutil.rmtree(base)
