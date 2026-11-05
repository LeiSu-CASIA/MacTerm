"""Fetch fixed upstream sources for the project-local RDP build."""
from pathlib import Path
import hashlib,json,subprocess,tarfile
root=Path(__file__).resolve().parent.parent
base=root/'build/rdp-deps';downloads=base/'downloads';sources=base/'src'
items=[('freerdp-3.33.0.tar.gz','https://codeload.github.com/FreeRDP/FreeRDP/tar.gz/refs/tags/3.33.0'),('openssl-git-3.5.9.tar.gz','https://codeload.github.com/openssl/openssl/tar.gz/refs/tags/openssl-3.5.9'),('cJSON-1.7.19.tar.gz','https://codeload.github.com/DaveGamble/cJSON/tar.gz/refs/tags/v1.7.19')]
expected={'freerdp-3.33.0.tar.gz': '3b5e7733e667ad66f54e0db51d952268c9d08b2e71a4fade44c716ab29dd5657', 'openssl-git-3.5.9.tar.gz': '796831ec533bf41998eaaee9d632d921b8a69f57394fa4086ff01a941113d26d', 'cJSON-1.7.19.tar.gz': '7fa616e3046edfa7a28a32d5f9eacfd23f92900fe1f8ccd988c1662f30454562'}
records=[]
for name,url in items:
 target=downloads/name
 if not target.exists():
  part=target.with_suffix(target.suffix+'.part')
  subprocess.run(['/usr/bin/curl','--fail','--location','--retry','2','--connect-timeout','15','--max-time','180','--output',str(part),url],check=True);part.rename(target)
 digest=hashlib.sha256(target.read_bytes()).hexdigest()
 if digest!=expected[name]:raise RuntimeError('Pinned source SHA-256 mismatch: '+name)
 if name=='openssl-3.5.9.tar.gz':
  expected=downloads/(name+'.sha256')
  if not expected.exists():subprocess.run(['/usr/bin/curl','--fail','--location','--output',str(expected),url+'.sha256'],check=True)
  words=expected.read_text().strip().split();assert digest in words,'OpenSSL source SHA-256 mismatch'
 with tarfile.open(target) as archive:
  top=archive.getmembers()[0].name.split('/')[0]
  if not (sources/top).exists():
   for member in archive.getmembers():
    path=Path(member.name)
    if path.is_absolute() or '..' in path.parts or member.issym() or member.islnk():raise RuntimeError('Unsafe source archive member: '+member.name)
   archive.extractall(sources)
 records.append(dict(name=name,url=url,sha256=digest,source=top))
 print(name,digest,flush=True)
(base/'sources.json').write_text(json.dumps(records,indent=2)+'\n')
