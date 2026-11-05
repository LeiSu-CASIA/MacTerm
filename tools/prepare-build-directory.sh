#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
# Keep development applications and recovery copies out of Spotlight. The stable
# build path remains available to compilers, tests, old manifests and download links.
if [[ -L build ]]; then
 [[ "$(readlink build)" == "build.noindex" && -d build.noindex ]] || { print -u2 'Unexpected build link; no files moved.'; exit 1; }
elif [[ -e build ]]; then
 [[ -d build && ! -e build.noindex && ! -L build.noindex ]] || { print -u2 'Conflicting build paths; no files moved.'; exit 1; }
 mv build build.noindex
 ln -s build.noindex build
else
 [[ ! -e build.noindex && ! -L build.noindex ]] || { print -u2 'Existing build.noindex needs its build link restored; no files moved.'; exit 1; }
 mkdir build.noindex
 ln -s build.noindex build
fi
