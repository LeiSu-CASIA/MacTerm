#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
RDP_PREFIX="$PWD/build/rdp-deps/prefix"
clang -std=c11 -O1 -g -Wall -Wextra -Werror -I"$RDP_PREFIX/include/freerdp3" -I"$RDP_PREFIX/include/winpr3" -I"$RDP_PREFIX/include" Tests/rdp_clipboard_core.c Sources/RDPClipboardCore.c -o build/rdp-clipboard-core-test -L"$RDP_PREFIX/lib" -lfreerdp3 -lwinpr3 -lssl -lcrypto -lcjson -lz -lm -lpthread -framework CoreFoundation -framework CoreMedia -framework CoreVideo -framework VideoToolbox -framework Security -framework Foundation -framework IOKit
build/rdp-clipboard-core-test
