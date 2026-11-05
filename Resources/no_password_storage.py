from pathlib import Path
import subprocess
binary=Path(__file__).resolve().parents[1]/'build/MacTerm.app/Contents/MacOS/MacTerm'
symbols=subprocess.run(['nm','-u',str(binary)],capture_output=True,text=True,check=True).stdout
for forbidden in ('_SecItemAdd','_SecItemCopyMatching','_SecItemUpdate','_SecItemDelete','_SecKeychain'):
    assert forbidden not in symbols,forbidden
print('PASS: built application imports no password keychain read/write/delete APIs')
