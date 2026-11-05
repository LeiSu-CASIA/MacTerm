# Third-party components

MacTerm original source is GPL-3.0-only. The following dependencies retain their own licenses; no third-party code is relicensed by the root LICENSE.

| Component | Version | License | Source |
| --- | --- | --- | --- |
| xterm.js | 5.5.0 | MIT | https://github.com/xtermjs/xterm.js/tree/5.5.0 |
| xterm addon-fit | 0.10.0 | MIT | https://www.npmjs.com/package/@xterm/addon-fit/v/0.10.0 |
| xterm addon-search | 0.15.0 | MIT | https://www.npmjs.com/package/@xterm/addon-search/v/0.15.0 |
| noVNC | 1.7.0 | MPL-2.0 | https://github.com/novnc/noVNC/tree/v1.7.0 |
| FreeRDP / WinPR | 3.33.0 | Apache-2.0 | https://github.com/FreeRDP/FreeRDP/tree/3.33.0 |
| OpenSSL | 3.5.9 | Apache-2.0 | https://github.com/openssl/openssl/tree/openssl-3.5.9 |
| cJSON | 1.7.19 | MIT | https://github.com/DaveGamble/cJSON/tree/v1.7.19 |
| esbuild (build tool) | 0.28.2 | MIT | https://github.com/evanw/esbuild/tree/v0.28.2 |

`package-lock.json` pins the JavaScript dependency artifacts. RDP archive URLs and SHA-256 hashes are pinned in `tools/fetch-rdp-deps.py`.

## Local modifications

- `tools/build-vnc.mjs` copies noVNC 1.7.0 and applies bounded framebuffer and clipboard handling, lossless text submission, submission status, pending-offer retention and disconnect cleanup. It packages the complete modified noVNC source and MPL-2.0 license alongside the application. Those modified noVNC files remain MPL-2.0.
- `tools/patch-rdp-clipboard.py` adds cliprdr fragmented-message and queue limits to FreeRDP's `channels/client/addin.c`. The patch is reproducible, retains Apache-2.0 licensing, and is distributed with the application notices. Build configuration is in `tools/build-rdp-deps.sh`.
- xterm.js and its addons are bundled from the pinned npm artifacts; their license texts are copied into application resources.
- The RDP helper statically links FreeRDP, OpenSSL and cJSON. Their license texts, notices, fixed source records and patch explanation are included in application resources by `build.sh`.

macOS frameworks and system OpenSSH / curl are provided by the operating system and are not copied into this source repository.

Copyright notices for third-party code remain in the original dependency sources and license files fetched during the build. See also `Resources/RDP-THIRD-PARTY-NOTICES.txt`.
