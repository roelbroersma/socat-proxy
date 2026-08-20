#!/usr/bin/env bash
set -euo pipefail

ROOT="${RUNNER_TEMP}/axiom-export"
OUT="${GITHUB_WORKSPACE}/axiom-export"
URL="https://teledyne.app.box.com/public/static/18w6yebq78srqv88gl4exetufg1b0o77.zip"
mkdir -p "$ROOT" "$OUT"
cd "$ROOT"

curl -L --fail --retry 8 --retry-delay 5 --retry-all-errors \
  --connect-timeout 30 --max-time 7200 -o axiom.zip "$URL"
mkdir -p zip iso rk1 rk2 system
7z x -y axiom.zip -ozip >/dev/null
ISO="$(find zip -type f -iname '*.iso' | head -n1)"
7z x -y "$ISO" -oiso >/dev/null
IMG="$(find iso -type f -iname 'raymarine_axiom_upgrade-*.img' | head -n1)"

git clone --depth 1 https://github.com/suyulin/afptool-rs.git afptool-rs >/dev/null 2>&1
python3 - afptool-rs/src/unpack.rs <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
old = '    let mut fp_out = File::create(full_path)?;'
new = '''    if let Some(parent) = Path::new(full_path).parent() {
        std::fs::create_dir_all(parent)?;
    }
    let mut fp_out = File::create(full_path)?;'''
if old not in s:
    raise SystemExit('afptool source changed')
p.write_text(s.replace(old, new, 1))
PY
(cd afptool-rs && cargo build --release >/dev/null)
AFP="$ROOT/afptool-rs/target/release/afptool-rs"
"$AFP" unpack "$IMG" "$ROOT/rk1" >/dev/null
INNER="$(find rk1 -type f -iname 'embedded-update.img' | head -n1)"
"$AFP" unpack "$INNER" "$ROOT/rk2" >/dev/null
SYSTEM="$(find "$ROOT" -type f -path '*/raymarine.axiom_mfg/system.img' | head -n1)"

unsquashfs -f -no-xattrs -d "$ROOT/system" "$SYSTEM" \
  app/AxiomMFD/lib/arm/libSystemFunctions_armeabi-v7a.so \
  app/AxiomMFD/lib/arm/libCommonPresentation_armeabi-v7a.so \
  app/AxiomMFD/lib/arm/libMFDApplication_armeabi-v7a.so \
  app/AxiomMFD/lib/arm/libqml_Applications_RDS_RDS_armeabi-v7a.so \
  app/AxiomMFD/AxiomMFD.apk \
  lib/libserviceutility.so >/dev/null

for f in \
  app/AxiomMFD/lib/arm/libSystemFunctions_armeabi-v7a.so \
  app/AxiomMFD/lib/arm/libCommonPresentation_armeabi-v7a.so \
  app/AxiomMFD/lib/arm/libMFDApplication_armeabi-v7a.so \
  app/AxiomMFD/lib/arm/libqml_Applications_RDS_RDS_armeabi-v7a.so \
  app/AxiomMFD/AxiomMFD.apk \
  lib/libserviceutility.so; do
  src="$ROOT/system/$f"
  mkdir -p "$OUT/$(dirname "$f")"
  cp "$src" "$OUT/$f"
  file "$src" >> "$OUT/filetypes.txt"
  sha256sum "$src" >> "$OUT/sha256.txt"
done

LIB="$ROOT/system/app/AxiomMFD/lib/arm/libSystemFunctions_armeabi-v7a.so"
readelf -Ws "$LIB" > "$OUT/libSystemFunctions-symbols.txt"
readelf -d "$LIB" > "$OUT/libSystemFunctions-dynamic.txt"
strings -a -t x -n 3 "$LIB" > "$OUT/libSystemFunctions-strings-offsets.txt"
llvm-objdump --demangle --disassemble --dynamic-syms --reloc "$LIB" \
  > "$OUT/libSystemFunctions-disassembly.txt" 2>&1 || true

for term in YachtSenseLinkDiscovery ServiceDiscoverer ServiceInfo _http._tcp E70640 model= id=; do
  printf '\n===== %s =====\n' "$term" >> "$OUT/key-symbols-and-strings.txt"
  grep -F -i "$term" "$OUT/libSystemFunctions-symbols.txt" >> "$OUT/key-symbols-and-strings.txt" || true
  grep -F -i "$term" "$OUT/libSystemFunctions-strings-offsets.txt" >> "$OUT/key-symbols-and-strings.txt" || true
done
