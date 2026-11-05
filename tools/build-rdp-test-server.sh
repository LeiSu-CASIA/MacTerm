#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
RDP_PREFIX="$PWD/build/rdp-deps/prefix"
clang -std=c11 -O2 -Wall -Wextra -Werror -mmacosx-version-min=12.0 -I"$RDP_PREFIX/include/freerdp3" -I"$RDP_PREFIX/include/winpr3" -I"$RDP_PREFIX/include" Tests/rdp_server.c -o build/rdp-test-server -L"$RDP_PREFIX/lib" -lfreerdp-server3 -lfreerdp3 -lwinpr3 -lssl -lcrypto -lcjson -lz -lm -lpthread -framework CoreFoundation -framework CoreMedia -framework CoreVideo -framework VideoToolbox -framework Security -framework Foundation -framework IOKit
