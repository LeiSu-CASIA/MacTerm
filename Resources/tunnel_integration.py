"""Real loopback-only SSH tunnel tests; no user SSH keys/configuration are used."""
import contextlib, getpass, os, pathlib, socket, socketserver, struct, subprocess, tempfile, threading, time
ROOT=pathlib.Path(__file__).resolve().parent.parent
BINARY=ROOT/'build/tunnel-test'
class Echo(socketserver.BaseRequestHandler):
    def handle(self):
        while data:=self.request.recv(65536): self.request.sendall(data)
class Server(socketserver.ThreadingTCPServer): daemon_threads=True

def port():
    with socket.socket() as s: s.bind(('127.0.0.1',0)); return s.getsockname()[1]
def command(*args): return subprocess.run(args,check=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
def exact(s,n):
    data=b''
    while len(data)<n:
        part=s.recv(n-len(data))
        if not part: raise AssertionError('unexpected EOF')
        data+=part
    return data
def wait_closed(p):
    for _ in range(100):
        try:
            s=socket.create_connection(('127.0.0.1',p),.1);s.close()
        except OSError: return
        time.sleep(.03)
    raise AssertionError(f'port {p} still listening')
with tempfile.TemporaryDirectory(prefix='mt-tunnel-',dir='/private/tmp') as folder, Server(('127.0.0.1',0),Echo) as echo:
    folder=pathlib.Path(folder); processes=[]; echo_port=echo.server_address[1]
    threading.Thread(target=echo.serve_forever,daemon=True).start()
    try:
        for name in ('host','client'): command('/usr/bin/ssh-keygen','-q','-t','ed25519','-N','','-f',str(folder/name))
        ssh_port=port();hostkey=(folder/'host.pub').read_text().split();(folder/'known_hosts').write_text(f'[127.0.0.1]:{ssh_port} '+ ' '.join(hostkey[:2])+'\n')
        (folder/'sshd_config').write_text(f'Port {ssh_port}\nListenAddress 127.0.0.1\nHostKey {folder}/host\nPidFile {folder}/pid\nAuthorizedKeysFile {folder}/client.pub\nStrictModes no\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nUsePAM no\nAllowTcpForwarding yes\nGatewayPorts no\n')
        sshd=subprocess.Popen(['/usr/sbin/sshd','-D','-e','-f',str(folder/'sshd_config')],stdout=subprocess.DEVNULL,stderr=subprocess.PIPE);processes.append(sshd)
        for _ in range(100):
            if sshd.poll() is not None: raise RuntimeError(sshd.stderr.read().decode())
            try: s=socket.create_connection(('127.0.0.1',ssh_port),.1);s.close();break
            except OSError: time.sleep(.03)
        control=folder/'mux'; master=subprocess.Popen(['/usr/bin/ssh','-F','/dev/null','-M','-S',str(control),'-N','-p',str(ssh_port),'-i',str(folder/'client'),'-o','IdentitiesOnly=yes','-o',f'UserKnownHostsFile={folder}/known_hosts','-o','StrictHostKeyChecking=yes','-o','BatchMode=yes',f'{getpass.getuser()}@127.0.0.1'],stdout=subprocess.DEVNULL,stderr=subprocess.PIPE);processes.append(master)
        for _ in range(200):
            if master.poll() is not None: raise RuntimeError(master.stderr.read().decode())
            if control.exists(): break
            time.sleep(.03)
        assert control.exists(),'SSH control socket missing'
        def tunnel(action,kind,listen,expected=True):
            result=subprocess.run([str(BINARY),action,kind,str(listen),str(echo_port),str(control),'integration'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=25)
            assert (result.returncode==0)==expected, result.stderr.decode()
            return result
        payload=('隧道数据验证'.encode()+bytes(range(256)))*400
        active=[]
        for kind in ('local','remote','dynamic'):
            listen=port();tunnel('forward',kind,listen);active.append((kind,listen))
            with socket.create_connection(('127.0.0.1',listen),3) as s:
                s.settimeout(5)
                if kind=='dynamic':
                    s.sendall(b'\x05\x01\x00');assert exact(s,2)==b'\x05\x00'
                    s.sendall(b'\x05\x01\x00\x01'+socket.inet_aton('127.0.0.1')+struct.pack('>H',echo_port));head=exact(s,4);assert head[:2]==b'\x05\x00';assert head[3]==1;exact(s,6)
                s.sendall(payload);assert exact(s,len(payload))==payload
            print('PASS actual data:',kind,flush=True)
        for kind,listen in active: tunnel('cancel',kind,listen);wait_closed(listen)
        print('PASS cancellation releases local, remote and SOCKS listeners',flush=True)
        with socket.socket() as occupied:
            occupied.bind(('127.0.0.1',0));occupied.listen();listen=occupied.getsockname()[1]
            result=tunnel('forward','local',listen,False);assert result.stderr,'failure should include diagnostic'
        print('PASS occupied port reports failure',flush=True)
        active=[]
        for kind in ('local','remote','dynamic'):
            listen=port();tunnel('forward',kind,listen);active.append(listen)
        master.terminate();master.wait(timeout=5)
        for listen in active: wait_closed(listen)
        print('PASS SSH disconnect releases all listeners',flush=True)
    finally:
        echo.shutdown()
        for p in reversed(processes):
            if p.poll() is None:
                p.terminate()
                try: p.wait(timeout=5)
                except subprocess.TimeoutExpired: p.kill();p.wait()
