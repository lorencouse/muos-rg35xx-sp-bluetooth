#!/bin/sh
# Build the muOS Archive Manager package: dist/muOS-BT-USB-WiFi-<version>.muxzip
# A .muxzip's top-level folders map onto muOS storage: application/ and init/
# extract to wherever MUOS/application and MUOS/init live (SD1 or SD2).
set -eu
cd "$(dirname "$0")"
VERSION="${1:-$(git describe --tags --always 2>/dev/null || echo dev)}"
OUT="dist/muOS-BT-USB-WiFi-$VERSION.muxzip"
mkdir -p dist
rm -f "$OUT"
(cd MUOS && zip -r -X -9 "../$OUT" application init -x '*.DS_Store' -x '*__pycache__*' -x '*/state/*')
# launch overrides: Archive Manager's "override" extractor lands them in MUOS/info/override
(cd MUOS/info && zip -r -X -9 "../../$OUT" override -x '*.DS_Store')
echo "built $OUT"
unzip -l "$OUT" | tail -1
