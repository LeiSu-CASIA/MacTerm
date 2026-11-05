#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
if [[ ! -x build/rdp-tools/bin/cmake ]]; then
 python3 -m venv build/rdp-tools
 build/rdp-tools/bin/python -m pip install --cache-dir "$PWD/build/pip-cache" cmake==3.31.10
fi
if [[ ! -f build/rdp-deps/sources.json || ! -d build/rdp-deps/src/FreeRDP-3.33.0 || ! -d build/rdp-deps/src/openssl-openssl-3.5.9 || ! -d build/rdp-deps/src/cJSON-1.7.19 ]]; then
 mkdir -p build/rdp-deps/downloads build/rdp-deps/src
 python3 tools/fetch-rdp-deps.py
fi
RDP_BUILD_HASH=$(cat tools/build-rdp-deps.sh tools/patch-rdp-clipboard.py | shasum -a 256 | cut -d ' ' -f 1)
if [[ ! -f build/rdp-deps/prefix/lib/libfreerdp3.a || ! -f build/rdp-deps/build-script.sha256 || "$(cat build/rdp-deps/build-script.sha256)" != "$RDP_BUILD_HASH" ]]; then
 ./tools/build-rdp-deps.sh
 print -r -- "$RDP_BUILD_HASH" > build/rdp-deps/build-script.sha256
fi
