#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
./build.sh
python3 Tests/no_password_storage.py
clang Tests/ProtocolServer.c -o build/protocol-server
./tools/build-rdp-test-server.sh
./tools/compile-test-library.sh
for suite in Tunnel SFTP Permissions Session Serial VNC VNCClipboard RDP RDPClipboard Telnet FTP FTPQueue FTPDirectory FTPUploadSource FTPUpload FTPDrop FTPNavigation FTPFilePromises FTPText Credentials SessionStore SessionEditor SSHConfig Editor EditorSearch Transfer FilePromises RemoteCreate FileBrowser DirectoryHistory DirectoryBookmarks DirectoryBookmarkTransfer WorkspaceTabs ConnectionStatus TerminalLog Macros MacroArchive MacroRecording Broadcast InputSync TerminalPreferences KeywordHighlights KeywordRuleGroups Protocol Terminal TerminalInteraction; do
 ./tools/run-swift-test.sh "$suite"
done
# Real local RFB traffic and WKWebView pixels are required for VNC changes.
build/keywordhighlights-test --renderer
build/vnc-test --renderer
build/vncclipboard-test --renderer
build/rdp-test --renderer
build/rdpclipboard-test --renderer
./tools/test-rdp-clipboard-core.sh
python3 Tests/rdp_clipboard_engine.py
python3 Tests/rdp_reader_test.py
python3 Tests/rdp_engine.py
clang Tests/pty_test.c Sources/PTY.c -o build/pty-test
build/pty-test
clang -Wall -Wextra -Werror Tests/telnet_protocol_test.c Sources/TelnetProtocol.c -o build/telnet-protocol-test
build/telnet-protocol-test
codesign --verify --deep --strict build/MacTerm.app
plutil -lint build/MacTerm.app/Contents/Info.plist

python3 Tests/serial_integration.py
