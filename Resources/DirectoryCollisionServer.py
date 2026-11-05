"""Test-only SFTP relay: expose a colliding directory entry from a real server."""
import struct,subprocess,sys
alias=sys.argv[1].encode();server=subprocess.Popen(['/usr/libexec/sftp-server'],stdin=subprocess.PIPE,stdout=subprocess.PIPE)
def exact(stream,size):
    result=b''
    while len(result)<size:
        chunk=stream.read(size-len(result))
        if not chunk: raise EOFError
        result+=chunk
    return result
def number(data,offset): return struct.unpack('>I',data[offset:offset+4])[0],offset+4
def string(data,offset):
    size,start=number(data,offset);return data[start:start+size],start+size
def attributes_end(data,offset):
    flags,offset=number(data,offset)
    for bit,size in [(1,8),(2,8),(4,4),(8,8)]:
        if flags&bit: offset+=size
    if flags&0x80000000:
        count,offset=number(data,offset)
        for _ in range(count): _,offset=string(data,offset);_,offset=string(data,offset)
    return offset
try:
    while True:
        header=exact(sys.stdin.buffer,4);body=exact(sys.stdin.buffer,struct.unpack('>I',header)[0]);server.stdin.write(header+body);server.stdin.flush()
        response_header=exact(server.stdout,4);response=exact(server.stdout,struct.unpack('>I',response_header)[0])
        if body[0]==12 and response[0]==104:
            count,offset=number(response,5);entries=[];injected=None
            for _ in range(count):
                start=offset;name,after_name=string(response,offset);_,after_longname=string(response,after_name);offset=attributes_end(response,after_longname);entries.append(response[start:offset])
                if name==b'collision.txt': injected=struct.pack('>I',len(alias))+alias+response[after_name:offset]
            if injected is not None: entries.append(injected)
            response=response[:5]+struct.pack('>I',len(entries))+b''.join(entries)
        sys.stdout.buffer.write(struct.pack('>I',len(response))+response);sys.stdout.buffer.flush()
except EOFError: pass
finally:
    server.stdin.close()
    try: server.wait(timeout=2)
    except subprocess.TimeoutExpired: server.terminate();server.wait(timeout=2)
