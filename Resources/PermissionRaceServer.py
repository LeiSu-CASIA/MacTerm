"""Test-only SFTP relay: swap one disposable path immediately before lsetstat."""
import os, struct, subprocess, sys
selected,target=sys.argv[1:]
assert os.path.dirname(selected)==os.path.dirname(target)
server=subprocess.Popen(['/usr/libexec/sftp-server'],stdin=subprocess.PIPE,stdout=subprocess.PIPE)

def exact(stream,count):
    data=b''
    while len(data)<count:
        piece=stream.read(count-len(data))
        if not piece: raise EOFError
        data+=piece
    return data

def string(data,offset):
    length=struct.unpack('>I',data[offset:offset+4])[0]
    return data[offset+4:offset+4+length],offset+4+length

try:
    while True:
        header=exact(sys.stdin.buffer,4);size=struct.unpack('>I',header)[0]
        assert 0<size<=16*1024*1024
        data=exact(sys.stdin.buffer,size)
        if data[0]==200:
            name,offset=string(data,5)
            if name==b'lsetstat@openssh.com':
                path,_=string(data,offset)
                assert path.decode()==selected
                os.unlink(selected);os.symlink(target,selected)
        server.stdin.write(header+data);server.stdin.flush()
        response=exact(server.stdout,4);payload=exact(server.stdout,struct.unpack('>I',response)[0])
        sys.stdout.buffer.write(response+payload);sys.stdout.buffer.flush()
except EOFError:
    pass
finally:
    server.stdin.close()
    try: server.wait(timeout=2)
    except subprocess.TimeoutExpired: server.terminate();server.wait(timeout=2)
