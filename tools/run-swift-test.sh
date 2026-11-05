#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
SUITE="$1"
[[ "$SUITE" =~ '^[A-Za-z]+$' ]] || { print -u2 'Invalid test suite name'; exit 2; }
{ print '@testable import MacTermTesting'; cat "Tests/${SUITE}Test.swift"; } > "build/generated-tests/${SUITE}Test.swift"
swiftc -D TESTING -parse-as-library -module-cache-path "$PWD/build/module-cache" -I "$PWD/build" -L "$PWD/build" -lMacTermTesting -Xlinker -rpath -Xlinker @executable_path "build/generated-tests/${SUITE}Test.swift" -o "build/${SUITE:l}-test"
shift
"build/${SUITE:l}-test" "$@"
