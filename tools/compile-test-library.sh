#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
mkdir -p build/generated-tests build/module-cache
SWIFT_SOURCES=(Sources/*.swift)
swiftc -D TESTING -enable-testing -parse-as-library -whole-module-optimization -emit-module -emit-library -module-name MacTermTesting -emit-module-path "$PWD/build/MacTermTesting.swiftmodule" -module-cache-path "$PWD/build/module-cache" "${SWIFT_SOURCES[@]}" -Xlinker "$PWD/build/PTY.o" -o "$PWD/build/libMacTermTesting.dylib" -framework Cocoa -framework WebKit -framework Security -framework Network
