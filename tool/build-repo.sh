#!/bin/bash
# Builds a static Cydia repo layout from dist/*.deb
#
# usage: tool/build-repo.sh [path-to-repo]
#   (default: <repo>/dist/stable/main/binary-iphoneos-arm/)
#
# After running, point Cydia at the repo URL. Serve the repo root over any
# HTTP server (GitHub Pages works): Cydia needs:
#   dist/stable/main/binary-iphoneos-arm/Packages[.gz]
#   dist/stable/Release
set -e

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="${1:-$ROOT/cydia-repo}"
ARCH=iphoneos-arm
DIST_DIR="$REPO/dists/stable/main/binary-$ARCH"

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

mkdir -p "$DIST_DIR"
cp "$ROOT"/dist/*.deb "$DIST_DIR/" || { echo "no .deb in $ROOT/dist - run tool/build-deb.sh first" >&2; exit 1; }

cd "$REPO"
for f in dists/stable/main/binary-$ARCH/*.deb; do
  dpkg-deb -f "$f" Package Version Architecture Description \
    > /dev/null 2>&1 || continue
  PKG_NAME=$(dpkg-deb -f "$f" Package)
  PKG_VER=$(dpkg-deb -f "$f" Version)
  PKG_SIZE=$(stat -f%z "$f" 2>/dev/null || stat -c%s "$f")
  PKG_SHA=$(openssl dgst -sha256 "$f" | awk '{print $2}')
  # emit every control field verbatim, then repo metadata
  dpkg-deb -f "$f" | sed 's/^$/./' >> "$DIST_DIR/Packages" 2>/dev/null
  echo "Filename: ${f#./}" >> "$DIST_DIR/Packages"
  echo "Size: $PKG_SIZE" >> "$DIST_DIR/Packages"
  echo "SHA256: $PKG_SHA" >> "$DIST_DIR/Packages"
  echo "" >> "$DIST_DIR/Packages"
done

gzip -f "$DIST_DIR/Packages"

# Release file (Cydia requires this; origin/label show up in Cydia UI)
cat > dists/stable/Release <<EOF
Origin: quietriot
Label: quietriot
Suite: stable
Version: 1.0
Codename: stable
Architectures: $ARCH
Components: main
Description: QuietRiot local package repo
EOF

say "repo ready at $REPO"
echo "Serve it (e.g. GitHub Pages) and add the URL in Cydia:"
echo "  http://<host>/            -> Cydia -> Sources -> Add"
echo "Then install quietriot from the source."
