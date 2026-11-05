"""FTP/FTPS fixture in an isolated optional venv; only localhost and temporary files."""
import json, os, pathlib, shutil, subprocess, sys, tempfile, time
ROOT=pathlib.Path(__file__).resolve().parent.parent
if '--server' in sys.argv:
    from pyftpdlib.authorizers import DummyAuthorizer
    from pyftpdlib.handlers import FTPHandler, TLS_FTPHandler, ThrottledDTPHandler
    from pyftpdlib.servers import FTPServer
    config=json.loads(pathlib.Path(sys.argv[-1]).read_text())
    class Handler(TLS_FTPHandler if config['tls'] else FTPHandler):
        changed=False
        def ftp_MKD(self,path):
            result=super().ftp_MKD(path)
            if config.get('case')=='refresh-failure':Handler.changed=True
            return result
        def ftp_SIZE(self,path):
            if config.get('case')=='text-oversize' and pathlib.Path(path).name=='edit.txt':self.respond('213 1');return
            return super().ftp_SIZE(path)
        def ftp_MLSD(self,path):
            if config.get('case')=='text-oversize' and (pathlib.Path(path)/'edit.txt').is_file():
                self.push_dtp_data(b'type=file;size=1;modify=20260101000000; edit.txt\r\n',isproducer=False,cmd='MLSD');return
            if config.get('case')=='refresh-failure' and Handler.changed:self.respond('550 DIRECTORY_REFRESH_DENIED');return
            if config.get('case')=='directory-collision' and pathlib.Path(path).name=='case-clash':
                self.push_dtp_data(b'type=file;size=200000; Case\r\ntype=file;size=200000; case\r\n',isproducer=False,cmd='MLSD');return
            return super().ftp_MLSD(path)
        def ftp_RETR(self,path):
            if config.get('case')=='directory-failure' and pathlib.Path(path).name=='blocked.bin':self.respond('550 RETR_DENIED');return
            if config.get('case')=='directory-collision' and pathlib.Path(path).parent.name=='case-clash':path=str(pathlib.Path(config['files'])/'payload.bin')
            return super().ftp_RETR(path)
        def ftp_STOR(self,path,mode='w'):
            if config.get('case') in ('upload-failure','upload-cleanup-failure') and pathlib.Path(path).name=='blocked.bin':self.respond('550 STOR_DENIED');return
            return super().ftp_STOR(path,mode)
        def ftp_DELE(self,path):
            if config.get('case')=='upload-cleanup-failure' and '.macterm-directory-' in path:self.respond('550 CLEANUP_DENIED');return
            return super().ftp_DELE(path)
        def ftp_RMD(self,path):
            if config.get('case')=='upload-cleanup-failure' and '.macterm-directory-' in path:self.respond('550 CLEANUP_DENIED');return
            return super().ftp_RMD(path)
        def on_file_received(self,path):
            if pathlib.Path(path).name.startswith('.macterm-editor-'):
                if config.get('case')=='text-conflict':(pathlib.Path(path).parent/'edit.txt').write_bytes(b'external writer')
                if config.get('case')=='text-tamper':pathlib.Path(path).write_bytes(b'server tampered')
            if config.get('case')=='upload-foreign':
                for parent in pathlib.Path(path).parents:
                    if parent.name.startswith('.macterm-directory-'):(parent/'foreign').write_text('do not remove');break
        def on_connect(self):
            if config.get('implicit'):self.secure_connection(self.get_ssl_context())
        def ftp_RNTO(self,path):
            if config.get('case') in ('upload-uncertain','text-uncertain'):
                source=self._rnfr;self._rnfr=None
                self.run_as_current_user(self.fs.rename,source,path);self.respond('451 RENAME_RESULT_UNCONFIRMED');return
            if config.get('case')=='rename-failure':self.respond('550 RENAME_DENIED');return
            return super().ftp_RNTO(path)
    auth=DummyAuthorizer();auth.add_user('demo',config['password'],config['files'],perm='elradfmwMT');Handler.authorizer=auth
    if config['tls']:
        Handler.certfile=config['cert'];Handler.keyfile=config['key'];Handler.tls_control_required=True;Handler.tls_data_required=True
    if config.get('case') in ('cancel','race','upload-cancel','text-cancel'):
        class SlowData(ThrottledDTPHandler):
            write_limit=8192 if config.get('case')=='cancel' else 65536
            read_limit=8192 if config.get('case') in ('upload-cancel','text-cancel') else 0
        Handler.dtp_handler=SlowData
    server=FTPServer(('127.0.0.1',0),Handler)
    print(json.dumps({'port':server.socket.getsockname()[1]}),flush=True)
    server.serve_forever(timeout=.05)
    raise SystemExit
with tempfile.TemporaryDirectory(prefix='mt-ftp-',dir='/private/tmp') as temporary:
    folder=pathlib.Path(temporary);files=folder/'files';files.mkdir();nested=files/'中文 目录';nested.mkdir();(nested/'space \' " $;[].txt').write_text('中文内容')
    (files/'payload.bin').write_bytes(bytes(i%251 for i in range(200000)))
    cert=folder/'server.crt';key=folder/'server.key';openssl=folder/'openssl.cnf'
    openssl.write_text('[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=localhost\n[ext]\nsubjectAltName=DNS:localhost\nbasicConstraints=critical,CA:TRUE\nkeyUsage=digitalSignature,keyEncipherment,keyCertSign\n')
    subprocess.run(['/usr/bin/openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','1','-keyout',str(key),'-out',str(cert),'-config',str(openssl)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    tree=files/'download-tree';(tree/'nested').mkdir(parents=True);(tree/'empty').mkdir();(tree/'.hidden').write_text('hidden contents');(tree/'nested'/'zero').touch();(tree/'nested'/'二进制 \' " $;[].bin').write_bytes((files/'payload.bin').read_bytes())
    (files/'slow-tree').mkdir();(files/'slow-tree'/'slow.bin').write_bytes((files/'payload.bin').read_bytes())
    (files/'failure-tree').mkdir();(files/'failure-tree'/'first.bin').write_bytes(b'completed first');(files/'failure-tree'/'blocked.bin').write_bytes(b'must fail')
    (files/'case-clash').mkdir()
    (files/'slow.bin').write_bytes(b'x'*(2*1024*1024));(files/'existing.bin').write_bytes(b'keep original')
    for security,case in [('plain','normal'),('explicitTLS','normal'),('implicitTLS','normal'),('plain','cancel'),('plain','rename-failure'),('plain','refresh-failure'),('plain','race'),('plain','directory-failure'),('plain','directory-collision'),('plain','upload-failure'),('plain','upload-cleanup-failure'),('plain','upload-uncertain'),('plain','upload-foreign'),('plain','upload-cancel'),('plain','text-conflict'),('plain','text-tamper'),('plain','text-uncertain'),('plain','text-cancel'),('plain','text-oversize')]:
        if ('--drop-only' in sys.argv or '--status-only' in sys.argv or '--navigation-only' in sys.argv or '--promises-only' in sys.argv) and case!='normal':continue
        if '--text-only' in sys.argv and case!='normal' and not case.startswith('text-') and case!='rename-failure':continue
        tls=security!='plain'
        password='p:a"ss\\word#$;'
        config=folder/'server.json';config.write_text(json.dumps(dict(tls=tls,implicit=security=="implicitTLS",case=case,password=password,files=str(files),cert=str(cert),key=str(key))))
        with open(folder/'server.log','wb') as log:
            server=subprocess.Popen([sys.executable,__file__,'--server',str(config)],stdout=subprocess.PIPE,stderr=log,text=True)
            try:
                line=server.stdout.readline();assert line,(folder/'server.log').read_text();port=json.loads(line)['port']
                fixture=folder/'fixture.json';fixture.write_text(json.dumps(dict(session=dict(name='FTPS fixture' if tls else 'FTP fixture',host='localhost' if tls else '127.0.0.1',user='demo',port=port,key='',connectionTimeout=5,kind='ftp',ftp=dict(security=security,initialPath='/')),password=password,root=str(folder),caFile=str(cert) if tls else None)))
                if case.startswith('text-') or case=='normal' and not any(flag in sys.argv for flag in ('--status-only','--drop-only','--navigation-only','--promises-only')) or case=='rename-failure':
                    flag='--fixture' if case=='normal' else '--'+case.removeprefix('text-')+'-fixture'
                    text_result=subprocess.run([str(ROOT/'build/ftptext-test'),flag,str(fixture)],capture_output=True,text=True,timeout=70)
                    if text_result.returncode:raise RuntimeError(text_result.stderr[-4000:]+'\n'+text_result.stdout[-2000:]+'\nSERVER:\n'+(folder/'server.log').read_text()[-2500:])
                    assert 'PASS:' in text_result.stdout,text_result.stdout
                    print(text_result.stdout.strip(),flush=True)
                    if case.startswith('text-') or '--text-only' in sys.argv:continue
                if case=='normal' and '--status-only' not in sys.argv and '--drop-only' not in sys.argv and '--navigation-only' not in sys.argv:
                    promises=subprocess.run([str(ROOT/'build/ftpfilepromises-test'),'--fixture',str(fixture)],capture_output=True,text=True,timeout=50)
                    if promises.returncode:raise RuntimeError(promises.stderr[-4000:]+'\n'+promises.stdout[-2000:]+'\nSERVER:\n'+(folder/'server.log').read_text()[-2500:])
                    assert 'FTP file promise registration' in promises.stdout,promises.stdout
                    print(promises.stdout.strip(),flush=True)
                    if '--promises-only' in sys.argv:continue
                if '--status-only' in sys.argv:
                    status=subprocess.run([str(ROOT/'build/ftp-test'),'--fixture',str(fixture)],capture_output=True,text=True,timeout=50)
                    if status.returncode:raise RuntimeError(status.stderr[-4000:]+'\n'+status.stdout[-2000:])
                    assert 'PASS: real ' in status.stdout,status.stdout
                    print(status.stdout.strip(),flush=True);continue
                if case=='normal':
                    navigation=subprocess.run([str(ROOT/'build/ftpnavigation-test'),'--fixture',str(fixture)],capture_output=True,text=True,timeout=50)
                    if navigation.returncode:raise RuntimeError(navigation.stderr[-4000:]+'\n'+navigation.stdout[-2000:]+'\nSERVER:\n'+(folder/'server.log').read_text()[-2500:])
                    assert 'FTP navigation' in navigation.stdout,navigation.stdout
                    print(navigation.stdout.strip(),flush=True)
                    if '--navigation-only' in sys.argv:continue
                    drop=subprocess.run([str(ROOT/'build/ftpdrop-test'),'--fixture',str(fixture)],capture_output=True,text=True,timeout=50)
                    if drop.returncode:raise RuntimeError(drop.stderr[-4000:]+'\n'+drop.stdout[-2000:]+'\nSERVER:\n'+(folder/'server.log').read_text()[-2500:])
                    assert 'Finder-style drag delegate' in drop.stdout,drop.stdout
                    print(drop.stdout.strip(),flush=True)
                    if '--drop-only' in sys.argv:continue
                if case.startswith('upload-') or case in ('normal','rename-failure'):
                    flag={'normal':'--fixture','rename-failure':'--rename-failure-fixture','upload-failure':'--upload-failure-fixture','upload-cleanup-failure':'--cleanup-failure-fixture','upload-uncertain':'--uncertain-fixture','upload-foreign':'--foreign-fixture','upload-cancel':'--cancel-fixture'}[case]
                    upload=subprocess.run([str(ROOT/'build/ftpupload-test'),flag,str(fixture)],capture_output=True,text=True,timeout=65)
                    if upload.returncode:raise RuntimeError(upload.stderr[-4000:]+'\n'+upload.stdout[-2000:]+'\nSERVER:\n'+(folder/'server.log').read_text()[-2500:])
                    assert 'PASS:' in upload.stdout,upload.stdout
                    print(upload.stdout.strip(),flush=True)
                    if case in ('upload-cleanup-failure','upload-foreign'):
                        # These cases deliberately leave server-owned fixture paths.
                        for stage in files.glob('.macterm-directory-*'):shutil.rmtree(stage)
                    if case.startswith('upload-'):continue
                if case.startswith('directory-'):
                    flag='--failure-fixture' if case=='directory-failure' else '--collision-fixture'
                    directory=subprocess.run([str(ROOT/'build/ftpdirectory-test'),flag,str(fixture)],capture_output=True,text=True,timeout=50)
                    if directory.returncode:raise RuntimeError(directory.stderr[-4000:]+'\n'+directory.stdout[-2000:]+'\nSERVER:\n'+(folder/'server.log').read_text()[-2500:])
                    assert 'PASS: FTP' in directory.stdout,directory.stdout
                    print(directory.stdout.strip(),flush=True);continue
                if case in ('normal','cancel','race'):
                    flag='--fixture' if case=='normal' else '--'+case+'-fixture'
                    directory=subprocess.run([str(ROOT/'build/ftpdirectory-test'),flag,str(fixture)],capture_output=True,text=True,timeout=50)
                    if directory.returncode:raise RuntimeError(directory.stderr[-4000:]+'\n'+directory.stdout[-2000:]+'\nSERVER:\n'+(folder/'server.log').read_text()[-2500:])
                    assert 'PASS:' in directory.stdout,directory.stdout
                    print(directory.stdout.strip(),flush=True)
                result=subprocess.run([os.environ.get('MACTERM_FTP_TEST_EXECUTABLE',str(ROOT/'build/ftp-test')),'--fixture' if case=='normal' else '--'+case+'-fixture',str(fixture)],capture_output=True,text=True,timeout=50)
                if result.returncode:
                    raise RuntimeError(result.stderr[-4000:]+'\n'+result.stdout[-2000:]+'\nSERVER:\n'+(folder/'server.log').read_text()[-2500:])
                expected={'normal':'PASS: real '+security+' curl','cancel':'PASS: active throttled FTP','rename-failure':'PASS: FTP publication refusal','refresh-failure':'PASS: confirmed FTP mutation','race':'PASS: FTP atomic exclusive publication'}[case]
                assert expected in result.stdout,result.stdout
                print(result.stdout.strip(),flush=True)
                if case=='normal':
                    batch=subprocess.run([os.environ.get('MACTERM_FTP_QUEUE_TEST_EXECUTABLE',str(ROOT/'build/ftpqueue-test')),'--fixture',str(fixture)],capture_output=True,text=True,timeout=50)
                    if batch.returncode:raise RuntimeError(batch.stderr[-3000:]+'\n'+batch.stdout[-1000:])
                    assert 'FTP serial batch' in batch.stdout
                    print(batch.stdout.strip(),flush=True)
            finally:
                if server.poll() is None:server.terminate()
                server.wait(timeout=5)
