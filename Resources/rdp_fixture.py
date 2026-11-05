"""Prepare a private TLS fixture and exec the pattern-only loopback RDP peer."""
import os,subprocess,sys
from pathlib import Path
root=Path(sys.argv[1]);mode=sys.argv[2];root.mkdir(parents=True,exist_ok=True);os.chmod(root,0o700)
def run(args):subprocess.run(['/usr/bin/openssl']+args,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,check=True)
(root/'root.conf').write_text('[req]\nprompt=no\ndistinguished_name=dn\nx509_extensions=ext\n[dn]\nCN=MacTerm isolated RDP test root\n[ext]\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n')
run(['req','-new','-newkey','rsa:2048','-nodes','-x509','-sha256','-days','2','-config',str(root/'root.conf'),'-keyout',str(root/'root.key'),'-out',str(root/'root.crt')])
run(['req','-new','-newkey','rsa:2048','-nodes','-subj','/CN=localhost','-keyout',str(root/'server.key'),'-out',str(root/'server.csr')])
(root/'server.ext').write_text('basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:localhost,IP:127.0.0.1\n')
run(['x509','-req','-in',str(root/'server.csr'),'-CA',str(root/'root.crt'),'-CAkey',str(root/'root.key'),'-CAcreateserial','-days','1','-sha256','-extfile',str(root/'server.ext'),'-out',str(root/'leaf.crt')])
(root/'server.crt').write_bytes((root/'leaf.crt').read_bytes()+(root/'root.crt').read_bytes())
for name in ['root.key','server.key']:os.chmod(root/name,0o600)
os.execv('build/rdp-test-server',['build/rdp-test-server',str(root),mode])
