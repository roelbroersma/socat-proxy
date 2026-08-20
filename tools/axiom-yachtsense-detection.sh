#!/usr/bin/env bash
set -uo pipefail

ROOT="${RUNNER_TEMP:-/tmp}/axiom-yachtsense"
OUT="${GITHUB_WORKSPACE:-$PWD}/report"
mkdir -p "$ROOT" "$OUT"
AXIOM_URL="https://teledyne.app.box.com/public/static/18w6yebq78srqv88gl4exetufg1b0o77.zip"
DIRECT='Yacht.?Sense|Yacht Sense|E70640|IO_Settings|channels-monitoring\.html|_http\._tcp|start-avahi-ysl|Raymarine YachtSense Link'
BROAD='Yacht.?Sense|E70640|IO_Settings|channels-monitoring\.html|_http\._tcp|mDNS|MDNS|avahi|NsdManager|NsdServiceInfo|DNS.?SD|service.?discover|Internet.?Source|preferred.?internet|default.?gateway|198\.18\.|DHCP.?option|option.?43|option.?60|vendor.?class|LLDP|RayNet|SeaTalk|GetHubInfo|GetHomeStatus|LanConfigure'

download() {
  curl -L --fail --retry 8 --retry-delay 5 --retry-all-errors \
    --connect-timeout 30 --max-time 7200 -o "$2" "$1"
}

cd "$ROOT"
download "$AXIOM_URL" axiom.zip
sha256sum axiom.zip > "$OUT/axiom-sha256.txt"
ls -lh axiom.zip > "$OUT/axiom-download.txt"

mkdir -p zip iso rk1 rk2 system
7z x -y axiom.zip -ozip > "$OUT/zip-extract.log" 2>&1
ISO="$(find zip -type f -iname '*.iso' | head -n1)"
7z x -y "$ISO" -oiso > "$OUT/iso-extract.log" 2>&1
IMG="$(find iso -type f -iname 'raymarine_axiom_upgrade-*.img' | head -n1)"
printf 'ISO=%s\nIMG=%s\n' "$ISO" "$IMG" > "$OUT/axiom-selected.txt"

git clone --depth 1 https://github.com/suyulin/afptool-rs.git afptool-rs > "$OUT/afptool-clone.log" 2>&1
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
(cd afptool-rs && cargo build --release) > "$OUT/afptool-build.log" 2>&1
AFP="$ROOT/afptool-rs/target/release/afptool-rs"
"$AFP" unpack "$IMG" "$ROOT/rk1" > "$OUT/rk-unpack1.log" 2>&1
INNER="$(find rk1 -type f -iname 'embedded-update.img' | head -n1)"
printf 'INNER=%s\n' "$INNER" >> "$OUT/axiom-selected.txt"
"$AFP" unpack "$INNER" "$ROOT/rk2" > "$OUT/rk-unpack2.log" 2>&1

SYSTEM="$(find "$ROOT" -type f -path '*/raymarine.axiom_mfg/system.img' | head -n1)"
printf 'SYSTEM=%s\n' "$SYSTEM" >> "$OUT/axiom-selected.txt"
file "$SYSTEM" > "$OUT/system-filetype.txt"
find "$ROOT/raymarine.axiom_mfg" -maxdepth 1 -type f -printf '%s %p\n' | sort -n > "$OUT/partition-files.txt"

if file -b "$SYSTEM" | grep -qi squashfs; then
  unsquashfs -f -d "$ROOT/system" "$SYSTEM" > "$OUT/system-extract.log" 2>&1
elif file -b "$SYSTEM" | grep -Eqi 'ext[234] filesystem'; then
  debugfs -R "rdump / $ROOT/system" "$SYSTEM" > "$OUT/system-extract.log" 2>&1
elif file -b "$SYSTEM" | grep -qi sparse; then
  simg2img "$SYSTEM" "$ROOT/system.raw.img"
  debugfs -R "rdump / $ROOT/system" "$ROOT/system.raw.img" > "$OUT/system-extract.log" 2>&1
else
  7z x -y "$SYSTEM" -o"$ROOT/system" > "$OUT/system-extract.log" 2>&1 || true
fi

find "$ROOT/system" -printf '%y %s %p\n' | sort > "$OUT/system-filelist.txt"
find "$ROOT/system" -type f -print0 | xargs -0 -r file > "$OUT/system-filetypes.txt" 2>&1 || true

: > "$OUT/raw-content-hits.txt"
rg -a -i -n --no-messages --max-columns 1200 --max-columns-preview "$BROAD" "$ROOT/system" > "$OUT/raw-content-hits.txt" || true

: > "$OUT/direct-hit-files.txt"
: > "$OUT/direct-hit-context.txt"
: > "$OUT/archive-hit-files.txt"
: > "$OUT/archive-hit-context.txt"

# Direct strings in every manageable native/data file.
find "$ROOT/system" -type f -size -250M -print0 | while IFS= read -r -d '' f; do
  a="$(strings -a -n 4 "$f" 2>/dev/null | grep -Eai "$DIRECT" | head -n 120 || true)"
  u="$(strings -el -n 4 "$f" 2>/dev/null | grep -Eai "$DIRECT" | head -n 120 || true)"
  if [ -n "$a$u" ]; then
    echo "$f" >> "$OUT/direct-hit-files.txt"
    echo "===== $f =====" >> "$OUT/direct-hit-context.txt"
    file "$f" >> "$OUT/direct-hit-context.txt" 2>&1 || true
    printf '%s\n%s\n' "$a" "$u" >> "$OUT/direct-hit-context.txt"
  fi
done
sort -u "$OUT/direct-hit-files.txt" -o "$OUT/direct-hit-files.txt"

# Search decompressed APK/JAR/APEX/ZIP contents and DEX string pools.
find "$ROOT/system" -type f \( -iname '*.apk' -o -iname '*.jar' -o -iname '*.apex' -o -iname '*.zip' \) -size -250M -print0 | while IFS= read -r -d '' f; do
  a="$(unzip -p "$f" 2>/dev/null | strings -a -n 4 | grep -Eai "$DIRECT|NsdManager|NsdServiceInfo|DNS.?SD|Internet.?Source|preferred.?internet|198\.18\.' | head -n 180 || true)"
  u="$(unzip -p "$f" 2>/dev/null | strings -el -n 4 | grep -Eai "$DIRECT|NsdManager|NsdServiceInfo|DNS.?SD|Internet.?Source|preferred.?internet|198\.18\.' | head -n 180 || true)"
  if [ -n "$a$u" ]; then
    echo "$f" >> "$OUT/archive-hit-files.txt"
    echo "===== $f =====" >> "$OUT/archive-hit-context.txt"
    printf '%s\n%s\n' "$a" "$u" >> "$OUT/archive-hit-context.txt"
  fi
done
sort -u "$OUT/archive-hit-files.txt" -o "$OUT/archive-hit-files.txt"

# Broad strings for only files already implicated by an exact discovery hit.
: > "$OUT/implicated-broad-strings.txt"
cat "$OUT/direct-hit-files.txt" "$OUT/archive-hit-files.txt" | sort -u | while IFS= read -r f; do
  [ -f "$f" ] || continue
  echo "===== $f =====" >> "$OUT/implicated-broad-strings.txt"
  strings -a -n 4 "$f" 2>/dev/null | grep -Eai -C 30 "$BROAD" >> "$OUT/implicated-broad-strings.txt" || true
  strings -el -n 4 "$f" 2>/dev/null | grep -Eai -C 30 "$BROAD" >> "$OUT/implicated-broad-strings.txt" || true
  case "$f" in
    *.apk|*.jar|*.apex|*.zip)
      unzip -p "$f" 2>/dev/null | strings -a -n 4 | grep -Eai -C 30 "$BROAD" >> "$OUT/implicated-broad-strings.txt" || true
      ;;
  esac
done

# Copy implicated binaries/packages for local reverse engineering.
mkdir -p "$OUT/axiom-relevant-files"
cat "$OUT/direct-hit-files.txt" "$OUT/archive-hit-files.txt" | sort -u | while IFS= read -r f; do
  [ -f "$f" ] || continue
  [ "$(stat -c %s "$f")" -le 80000000 ] || continue
  rel="${f#${ROOT}/system/}"
  mkdir -p "$OUT/axiom-relevant-files/$(dirname "$rel")"
  cp "$f" "$OUT/axiom-relevant-files/$rel"
done

# Useful related filenames even if symbols are stripped.
find "$ROOT/system" -type f | grep -Eai '(yacht|sense|raynet|network|mdns|dns.?sd|avahi|nsd|internet|gateway|dhcp|discovery|discover|service)' > "$OUT/related-filenames.txt" || true

for f in "$OUT"/*.txt; do
  [ -f "$f" ] || continue
  if [ "$(stat -c %s "$f")" -gt 40000000 ]; then
    head -c 40000000 "$f" > "$f.cut"
    mv "$f.cut" "$f"
    printf '\n[TRUNCATED AT 40 MB]\n' >> "$f"
  fi
done

{
  echo "Axiom YachtSense recognition analysis"
  echo "Generated: $(date -u +%FT%TZ)"
  cat "$OUT/axiom-selected.txt"
  cat "$OUT/system-filetype.txt"
  echo
  echo "Direct hit files: $(wc -l < "$OUT/direct-hit-files.txt" 2>/dev/null || echo 0)"
  echo "Archive hit files: $(wc -l < "$OUT/archive-hit-files.txt" 2>/dev/null || echo 0)"
  echo "Raw YachtSense/E70640 hits: $(grep -Eic 'Yacht.?Sense|E70640' "$OUT/raw-content-hits.txt" 2>/dev/null || true)"
  echo "mDNS/DNS-SD/NSD hits: $(grep -Eic 'mDNS|avahi|DNS.?SD|NsdManager|NsdServiceInfo|_http\._tcp' "$OUT/raw-content-hits.txt" 2>/dev/null || true)"
  echo "DHCP vendor-option hits: $(grep -Eic 'option.?43|option.?60|vendor.?class|DHCP.?option' "$OUT/raw-content-hits.txt" 2>/dev/null || true)"
  echo
  echo "Direct files:"
  cat "$OUT/direct-hit-files.txt"
  echo
  echo "Archive files:"
  cat "$OUT/archive-hit-files.txt"
} > "$OUT/axiom-summary.txt"
cat "$OUT/axiom-summary.txt"
