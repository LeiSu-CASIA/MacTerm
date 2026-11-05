import fs from 'node:fs';
import path from 'node:path';
import { build } from 'esbuild';
import { execFileSync } from 'node:child_process';
const root=process.cwd(),source=path.join(root,'build/novnc-source'),output=path.join(root,'build/MacTerm.app/Contents/Resources');
if(JSON.parse(fs.readFileSync('node_modules/@novnc/novnc/package.json')).version!=='1.7.0')throw Error('Unexpected noVNC version');
fs.rmSync(source,{recursive:true,force:true});fs.cpSync('node_modules/@novnc/novnc',source,{recursive:true});
const file=path.join(source,'core/display.js');let code=fs.readFileSync(file,'utf8');const needle='    resize(width, height) {';
if(code.split(needle).length!==2)throw Error('noVNC display patch target changed');
code=code.replace(needle,needle+'\n        // MacTerm: bound framebuffer allocation from an untrusted server.\n        if (!Number.isInteger(width) || !Number.isInteger(height) || width < 1 || height < 1 || width > 16384 || height > 16384 || width * height > 32000000) { throw new Error("VNC framebuffer exceeds MacTerm limit (32 million pixels)"); }');
fs.writeFileSync(file,code);
const rfbFile=path.join(source,'core/rfb.js');let rfb=fs.readFileSync(rfbFile,'utf8');
function patch(before,after){if(rfb.split(before).length!==2)throw Error('noVNC clipboard patch target changed: '+before.slice(0,60));rfb=rfb.replace(before,after);}
// Explicit local submissions remain available until replaced or disconnected. A delayed
// remote Provide must not erase a newer local Notify before the server requests it.
patch('                // Ignore what we had in our clipboard client side.\n                this._clipboardText = null;', '                // MacTerm: incoming remote data does not revoke an explicit local offer.');
patch('    disconnect() {','    disconnect() {\n        this._clipboardText = null; // MacTerm: release pending text on disconnect.');
patch('        if (this._sock.rQwait("ServerCutText content", Math.abs(length), 8)) { return false; }','        if (Math.abs(length) > 4194304 || (length < 0 && length > -4)) { throw new Error("VNC clipboard wire limit"); }\n        if (this._sock.rQwait("ServerCutText content", Math.abs(length), 8)) { return false; }');
patch('            let isCaps = (!!(actions & extendedClipboardActionCaps));', '            let isCaps = (!!(actions & extendedClipboardActionCaps));\n            let formatCount = 0; for (let i = 0; i < 16; i++) { if (formats & (1 << i)) formatCount++; }\n            if ((isCaps && length !== 4 + 4 * formatCount) || (!isCaps && actions !== extendedClipboardActionProvide && length !== 4) || (!isCaps && actions === extendedClipboardActionProvide && !(formats & extendedClipboardFormatText))) { throw new Error("VNC clipboard malformed envelope"); }');
patch('                for (let i = 0; i <= 15; i++) {\n                    let format = 1 << i;', '                let clipboardBytes = 0; // MacTerm: limit total decompressed text before allocation.\n                for (let i = 0; i <= 15; i++) {\n                    let format = 1 << i;');
patch('                        let chunk = streamInflator.inflate(size);', '                        if (size < 0 || size > 2097153 || clipboardBytes + size > 2097153) { throw new Error("VNC clipboard decompression limit"); }\n                        clipboardBytes += size;\n                        let chunk = streamInflator.inflate(size);');
patch('                    code = 0x3f;', '                    throw new Error("VNC_CLIPBOARD_LATIN1_ONLY"); // MacTerm: never silently replace Unicode.');
patch('            RFB.messages.extendedClipboardNotify(this._sock, [extendedClipboardFormatText]);\n        } else {', '            RFB.messages.extendedClipboardNotify(this._sock, [extendedClipboardFormatText]);\n            return "notified"; // MacTerm: server still needs to request the text.\n        } else {');
patch('            RFB.messages.clientCutText(this._sock, data);\n        }\n    }', '            RFB.messages.clientCutText(this._sock, data);\n            return "sent"; // MacTerm: protocol has no delivery receipt.\n        }\n    }');
fs.writeFileSync(rfbFile,rfb);
fs.writeFileSync(path.join(source,'MACTERM-PATCHES.txt'),'noVNC 1.7.0; MacTerm modifications:\n- Display.resize: maximum 32,000,000 pixels and 16,384 pixels per side.\n- RFB clipboard: validated extension envelopes, 4 MiB wire and 2 MiB + NUL decompression bound (allows CRLF normalization of 1 MiB text), reject lossy Latin-1 sends, return submission status, preserve explicit local offers across delayed remote updates, release pending clipboard text on disconnect.\nAll corresponding modified source and third-party license notices are included.\nUpstream: https://github.com/novnc/noVNC/tree/v1.7.0\nLicense: MPL-2.0.\n');
const result=await build({stdin:{contents:"import RFB from './core/rfb.js'; window.MacTermVNC={RFB};",resolveDir:source},bundle:true,format:'esm',write:false,target:['safari15'],legalComments:'eof'});
fs.writeFileSync(path.join(output,'novnc.js'),"window.macTermVNCLibraryReady=(async()=>{\n"+result.outputFiles[0].text+"\n})();\n");
fs.copyFileSync(path.join(source,'LICENSE.txt'),path.join(output,'noVNC-LICENSE.txt'));
execFileSync('/usr/bin/tar',['-czf',path.join(output,'noVNC-source.tar.gz'),'-C',path.dirname(source),path.basename(source)]);
