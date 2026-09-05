#!/bin/bash
# Build tiny-dfr with the slider patch and install it to /usr/local/bin.
#
# Optional. Without it everything still works on the packaged tiny-dfr; the
# contextual layers just use a stepped 25/50/75/100 row instead of a draggable
# slider. See patches/tiny-dfr-slider.patch for what the patch adds.
#
# /usr/local/bin, not /usr/bin: the tiny-dfr package owns /usr/bin/tiny-dfr and
# `pacman -Syu` replaces it silently, with no .pacnew and nothing in the log.
# A systemd drop-in (installed by install.sh when this binary exists) points
# tiny-dfr.service at the /usr/local copy, so the package can update freely and
# its binary simply goes unused.
#
#   ./build-tiny-dfr.sh            build against the commit the patch was made on
#   ./build-tiny-dfr.sh --head     try upstream HEAD instead (the patch may need work)

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH="$REPO/patches/tiny-dfr-slider.patch"
BASE="$(cut -d' ' -f1 "$REPO/patches/base-commit.txt")"
SRC="${TINY_DFR_SRC:-$HOME/src/tiny-dfr}"
UPSTREAM="https://github.com/AsahiLinux/tiny-dfr.git"
REF="$BASE"
[[ ${1:-} == --head ]] && REF="origin/main"

for tool in git cargo; do
  command -v "$tool" >/dev/null || { echo "need $tool (pacman -S rust git)" >&2; exit 1; }
done

if [[ ! -d $SRC/.git ]]; then
  git clone "$UPSTREAM" "$SRC"
fi
cd "$SRC"
git fetch -q origin
if [[ -n $(git status --porcelain) ]]; then
  echo "$SRC has local changes; refusing to reset it. Commit or stash them, or set TINY_DFR_SRC." >&2
  exit 1
fi
git checkout -q --detach "$REF"

if git apply --check "$PATCH" 2>/dev/null; then
  git apply "$PATCH"
else
  echo "patch does not apply cleanly at $(git rev-parse --short HEAD)." >&2
  echo "Upstream has moved; re-run without --head to build at the known-good base," >&2
  echo "or rebase patches/tiny-dfr-slider.patch by hand." >&2
  exit 1
fi

cargo build --release
sudo install -Dm755 target/release/tiny-dfr /usr/local/bin/tiny-dfr
echo "installed /usr/local/bin/tiny-dfr ($(git rev-parse --short HEAD) + slider patch)"
echo "now run ./install.sh (again) so the service drop-in and SLIDER=1 are applied"
