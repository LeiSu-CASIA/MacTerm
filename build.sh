#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
./tools/prepare-build-directory.sh
APP="$PWD/build/MacTerm.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/module-cache
if [[ ! -f node_modules/@xterm/xterm/lib/xterm.js || ! -f node_modules/@xterm/addon-search/lib/addon-search.js || ! -f node_modules/@novnc/novnc/core/rfb.js || ! -f node_modules/esbuild/bin/esbuild ]]; then
 npm ci --cache "$PWD/build/npm-cache"
fi
node tools/build-vnc.mjs
cp Resources/vnc.html "$APP/Contents/Resources/"
cp LICENSE "$APP/Contents/Resources/LICENSE-GPL-3.0.txt"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp Resources/AppIcon.icns "$APP/Contents/Resources/MacTermIcon.icns"
node -e 'process.stdout.write("window.MacTermXtermVersion="+JSON.stringify(require("./node_modules/@xterm/xterm/package.json").version)+";\n")' > "$APP/Contents/Resources/xterm-version.js"
cp Resources/terminal-interaction.js "$APP/Contents/Resources/"
cp Resources/terminal-recording.js "$APP/Contents/Resources/"
cp Resources/terminal-highlights.js "$APP/Contents/Resources/"
cp Resources/terminal-settings.js "$APP/Contents/Resources/"
cp Resources/terminal.html "$APP/Contents/Resources/"
cp node_modules/@xterm/xterm/lib/xterm.js node_modules/@xterm/xterm/css/xterm.css node_modules/@xterm/addon-fit/lib/addon-fit.js "$APP/Contents/Resources/"
cp node_modules/@xterm/addon-search/lib/addon-search.js "$APP/Contents/Resources/"
cp node_modules/@xterm/addon-search/LICENSE "$APP/Contents/Resources/addon-search-LICENSE"
cp node_modules/@xterm/xterm/LICENSE "$APP/Contents/Resources/xterm-LICENSE"
cp node_modules/@xterm/addon-fit/LICENSE "$APP/Contents/Resources/addon-fit-LICENSE"
clang -O2 -Wall -Wextra -Werror Sources/SerialRelay.c -o "$APP/Contents/MacOS/MacTermSerial"
cp "$APP/Contents/MacOS/MacTermSerial" build/MacTermSerial
codesign --force --sign - "$APP/Contents/MacOS/MacTermSerial"
clang -O2 -Wall -Wextra -Werror -pthread Sources/TelnetRelay.c Sources/TelnetProtocol.c -o "$APP/Contents/MacOS/MacTermTelnet"
cp "$APP/Contents/MacOS/MacTermTelnet" build/MacTermTelnet
codesign --force --sign - "$APP/Contents/MacOS/MacTermTelnet"
./tools/prepare-rdp.sh
./tools/build-rdp-relay.sh
cp build/MacTermRDP "$APP/Contents/MacOS/"
codesign --force --sign - "$APP/Contents/MacOS/MacTermRDP"
mkdir -p "$APP/Contents/Resources/RDP-Licenses"
cp build/rdp-deps/src/FreeRDP-3.33.0/LICENSE "$APP/Contents/Resources/RDP-Licenses/FreeRDP-LICENSE"
cp build/rdp-deps/src/openssl-openssl-3.5.9/LICENSE.txt "$APP/Contents/Resources/RDP-Licenses/OpenSSL-LICENSE"
cp build/rdp-deps/src/cJSON-1.7.19/LICENSE "$APP/Contents/Resources/RDP-Licenses/cJSON-LICENSE"
cp build/rdp-deps/sources.json "$APP/Contents/Resources/RDP-Licenses/sources.json"
cp tools/patch-rdp-clipboard.py "$APP/Contents/Resources/RDP-Licenses/patch-rdp-clipboard.py"
cp Resources/RDP-THIRD-PARTY-NOTICES.txt "$APP/Contents/Resources/RDP-Licenses/README.txt"
cp build/rdp-deps/src/FreeRDP-3.33.0/winpr/libwinpr/sysinfo/cpufeatures/NOTICE "$APP/Contents/Resources/RDP-Licenses/WinPR-cpufeatures-NOTICE"
clang -c Sources/PTY.c -o build/PTY.o
swiftc -module-cache-path "$PWD/build/module-cache" Sources/Main.swift Sources/SFTP.swift Sources/Editor.swift Sources/EditorSearch.swift Sources/Transfer.swift Sources/FilePromises.swift Sources/TerminalSupport.swift Sources/TerminalInteraction.swift Sources/ConnectionStatus.swift Sources/SSHMasterProbe.swift Sources/TerminalPreferences.swift Sources/KeywordHighlights.swift Sources/KeywordRuleGroups.swift Sources/WorkspaceTabs.swift Sources/TerminalLog.swift Sources/Macros.swift Sources/MacroRecording.swift Sources/Broadcast.swift Sources/InputSync.swift Sources/Serial.swift Sources/VNCSession.swift Sources/VNCWorkspace.swift Sources/VNCClipboard.swift Sources/RDPSession.swift Sources/RDPWorkspace.swift Sources/RDPSurface.swift Sources/RDPWorkerIO.swift Sources/RDPClipboard.swift Sources/RDPCertificate.swift Sources/Telnet.swift Sources/FTPBackend.swift Sources/FTPDirectory.swift Sources/FTPDrop.swift Sources/FTPUploadSource.swift Sources/FTP.swift Sources/FTPNavigation.swift Sources/FTPText.swift Sources/FTPProperties.swift Sources/FTPFileActions.swift Sources/FTPTransfers.swift Sources/DirectoryHistory.swift Sources/DirectoryBookmarks.swift Sources/DirectoryBookmarkTransfer.swift Sources/SessionManager.swift Sources/SSHConfigImport.swift Sources/SessionEditor.swift Sources/Tunnels.swift build/PTY.o -o "$APP/Contents/MacOS/MacTerm" -framework Cocoa -framework WebKit -framework Security -framework Network
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>MacTerm</string><key>CFBundleIdentifier</key><string>local.macterm.app</string><key>CFBundleName</key><string>MacTerm</string><key>CFBundleIconFile</key><string>MacTermIcon.icns</string><key>CFBundleVersion</key><string>46</string><key>CFBundleShortVersionString</key><string>0.3.43</string><key>NSHighResolutionCapable</key><true/><key>LSMinimumSystemVersion</key><string>12.0</string></dict></plist>
PLIST
codesign --force --deep --sign - "$APP"
echo "已生成：$APP"
