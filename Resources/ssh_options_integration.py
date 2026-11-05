"""Disposable loopback SSH + agent; never uses the user's SSH configuration or keys."""
import contextlib, getpass, json, os, pathlib, select, socket, subprocess, tempfile, time
ROOT=pathlib.Path(__file__).resolve().parent.parent

def port():
    with socket.socket() as s:
        s.bind(('127.0.0.1',0)); return s.getsockname()[1]

def checked(args,**kwargs):
    result=subprocess.run(args,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=25,**kwargs)
    if result.returncode:
        detail=result.stderr.decode(errors='replace')
        raise RuntimeError(f'Test command failed ({result.returncode}): {args[0]}\n'+detail[:4000]+'\n'+result.stdout.decode(errors='replace')[-1000:])
    return result

with tempfile.TemporaryDirectory(prefix='mt-ssh-options-',dir='/private/tmp') as temporary:
    folder=pathlib.Path(temporary); processes=[]; handles=[]
    try:
        for name in ('host','client'):
            checked(['/usr/bin/ssh-keygen','-q','-t','ed25519','-N','','-f',str(folder/name)])
        number=port(); public=(folder/'host.pub').read_text().split()
        (folder/'known_hosts').write_text(f'[127.0.0.1]:{number} '+ ' '.join(public[:2])+'\n')
        config=folder/'sshd_config'
        config.write_text(f'Port {number}\nListenAddress 127.0.0.1\nHostKey {folder}/host\nPidFile {folder}/pid\nAuthorizedKeysFile {folder}/client.pub\nStrictModes no\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nUsePAM no\nAllowAgentForwarding yes\nPermitTTY yes\nSubsystem sftp /usr/libexec/sftp-server -d {folder}\n')
        server_log=open(folder/'server.log','wb');handles.append(server_log)
        server=subprocess.Popen(['/usr/sbin/sshd','-D','-e','-f',str(config)],stdout=subprocess.DEVNULL,stderr=server_log);processes.append(server)
        for _ in range(100):
            if server.poll() is not None: raise RuntimeError((folder/'server.log').read_text())
            try:
                s=socket.create_connection(('127.0.0.1',number),.1);s.close();break
            except OSError: time.sleep(.03)
        agent_socket=folder/'agent.sock';agent=subprocess.Popen(['/usr/bin/ssh-agent','-D','-a',str(agent_socket)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL);processes.append(agent)
        for _ in range(100):
            if agent.poll() is not None: raise RuntimeError('Disposable agent exited')
            if agent_socket.exists(): break
            time.sleep(.03)
        environment=dict(os.environ,SSH_AUTH_SOCK=str(agent_socket));checked(['/usr/bin/ssh-add',str(folder/'client')],env=environment)
        fixture=folder/'session.json'
        base=dict(name='SSH integration',host='127.0.0.1',user=getpass.getuser(),port=number,key=str(folder/'client'),compression=True,forwardAgent=True,commandTTY=True)
        def arguments(**changes):
            session=dict(base,**changes);fixture.write_text(json.dumps(session))
            result=checked([str(ROOT/'build/session-test'),'--emit-arguments',str(fixture)])
            return json.loads(result.stdout)
        options=['-F','/dev/null','-o','IdentitiesOnly=yes','-o',f'UserKnownHostsFile={folder}/known_hosts','-o','StrictHostKeyChecking=yes','-o','BatchMode=yes']
        command='test -t 0 && test -t 1 && test -n "${SSH_AUTH_SOCK-}" && /usr/bin/ssh-add -l >/dev/null && printf "TTY_AGENT_COMPRESS_OK\\n"'
        result=checked(['/usr/bin/ssh','-vv']+options+arguments(remoteCommand=command),env=environment,stdin=subprocess.DEVNULL)
        assert b'TTY_AGENT_COMPRESS_OK' in result.stdout,result.stdout
        assert b'compression: zlib@openssh.com' in result.stderr,result.stderr[-3000:]
        print('PASS: actual remote command, forced PTY, disposable forwarded agent usable and compression negotiated',flush=True)
        command='test ! -t 0 && test -z "${SSH_AUTH_SOCK-}" && printf "NO_TTY_NO_AGENT_OK\\n"'
        result=checked(['/usr/bin/ssh','-vv']+options+arguments(remoteCommand=command,compression=False,forwardAgent=False,commandTTY=False),env=environment,stdin=subprocess.DEVNULL)
        assert result.stdout==b'NO_TTY_NO_AGENT_OK\n',result.stdout
        assert b'compression: none' in result.stderr
        print('PASS: explicit no-PTY, no-agent and no-compression settings',flush=True)
        control=folder/'mux';master_log=open(folder/'master.log','wb');handles.append(master_log)
        master=subprocess.Popen(['/usr/bin/ssh','-M','-S',str(control)]+options+arguments(remoteCommand='printf "MASTER_READY\\n"; sleep 20'),stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=master_log,env=environment);processes.append(master)
        readable,_,_=select.select([master.stdout],[],[],12)
        assert readable and b'MASTER_READY' in master.stdout.readline(),(folder/'master.log').read_text()
        assert control.exists()
        file_test=checked([str(ROOT/'build/sftp-test')],env=dict(environment,MACTERM_TEST_SOCKET=str(control)))
        assert b'SFTP passed' in file_test.stdout
        print('PASS: independent SFTP subsystem over the authenticated master while remote command occupies a PTY',flush=True)
        editor=checked([str(ROOT/'build/editorsearch-test'),'--ssh-fixture',str(fixture)],env=dict(environment,MACTERM_EDITOR_TEST_SOCKET=str(control)))
        assert b'real SSH editor regex/capture replacement' in editor.stdout
        print(editor.stdout.decode().strip(),flush=True)
        permissions=checked([str(ROOT/'build/permissions-test')],env=dict(environment,MACTERM_TEST_SOCKET=str(control)))
        assert b'PASS:' in permissions.stdout
        print('PASS: permission changes and conflict protection over the live SSH SFTP subsystem',flush=True)
        fixture.write_text(json.dumps(dict(base,remoteCommand='exec /usr/bin/env LC_ALL=en_US.UTF-8 /bin/sh -i')))
        state=checked([str(ROOT/'build/connectionstatus-test'),'--ssh-fixture',str(fixture)],env=environment)
        assert b'real SSH mux PID verification' in state.stdout
        print(state.stdout.decode().strip(),flush=True)
        promises=checked([str(ROOT/'build/filepromises-test'),'--ssh-fixture',str(fixture)],env=environment)
        assert b'real SSH + AppKit file promise' in promises.stdout
        print(promises.stdout.decode().strip(),flush=True)
        macro=checked([str(ROOT/'build/macros-test'),'--ssh-fixture',str(fixture)],env=environment)
        assert b'macro manager executes imported archive over authenticated SSH' in macro.stdout
        print('PASS: imported macro archive replay over a disposable SSH session stays bound while tabs switch; import does not autoplay',flush=True)
        navigation=checked([str(ROOT/'build/directoryhistory-test'),'--ssh-fixture',str(fixture)],env=environment)
        assert b'PASS: real SSH directory symlink navigation/history' in navigation.stdout
        print('PASS: directory history, symlink browsing, cancellation isolation and resolved-target saving over real SSH',flush=True)
        broadcast=checked([str(ROOT/'build/broadcast-test'),'--ssh-fixture',str(fixture)],env=environment)
        assert b'broadcast over two real SSH sessions' in broadcast.stdout
        print('PASS: broadcast to two SSH sessions, UTF-8, target snapshot, tab switch isolation and per-target disconnect skip',flush=True)
        recording=checked([str(ROOT/'build/macrorecording-test'),'--ssh-fixture',str(fixture)],env=environment)
        assert b'real SSH WebKit recording' in recording.stdout
        print('PASS: WebKit records one SSH session and replays the saved input macro on another SSH session',flush=True)
        creation=checked([str(ROOT/'build/remotecreate-test'),'--ssh-fixture',str(fixture)],env=environment)
        assert b'real SSH create/edit/save' in creation.stdout
        print('PASS: remote file creation/edit/save over SSH, overwrite/conflict protection and cancellation isolation',flush=True)
        bookmarks=checked([str(ROOT/'build/directorybookmarks-test'),'--ssh-fixture',str(fixture)],env=environment)
        assert b'real SSH bookmark navigation/history' in bookmarks.stdout
        print('PASS: persisted directory bookmarks over SSH, reconnect/history, stale and missing targets, cancellation isolation',flush=True)
        sync=checked([str(ROOT/'build/inputsync-test'),'--ssh-fixture',str(fixture)],env=environment)
        assert b'real SSH/WebKit synchronized' in sync.stdout
        print('PASS: real-time WebKit user input synchronized to two SSH targets, controls, DSR exclusion and fixed-target lifecycle',flush=True)
    finally:
        for process in reversed(processes):
            if process.poll() is None:
                process.terminate()
                try: process.wait(timeout=3)
                except subprocess.TimeoutExpired: process.kill();process.wait(timeout=3)
        for handle in handles: handle.close()
