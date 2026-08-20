#!/usr/bin/env bash
set -uo pipefail

ROOT="${RUNNER_TEMP:-/tmp}/raymarine-deep"
OUT="${GITHUB_WORKSPACE:-$PWD}/report"
mkdir -p "$ROOT" "$OUT"

YSL_URL="https://teledyne.app.box.com/public/static/hfmbusrqondj2u7zgxevdejrtzxtgcqn.zip"
AXIOM_URL="https://teledyne.app.box.com/public/static/18w6yebq78srqv88gl4exetufg1b0o77.zip"
PATTERN='Yacht.?Sense|Yacht Sense|YSL|E70640|GetHubInfo|GetHomeStatus|LanConfigure|198\.18\.|Internet.?Source|preferred.?internet|default.?gateway|DHCP.?option|option.?43|option.?60|vendor.?class|vendorclass|LLDP|lldpd|mDNS|avahi|SSDP|UPnP|RayNet|SeaTalk|NMEA.?2000|discovery|discover|cloudconnector|protobuf|proto2|proto3|7778|9999'
DIRECT='Yacht.?Sense|Yacht Sense|E70640|GetHubInfo'

log_section() { printf '\n===== %s =====\n' "$*"; }
download() {
  curl -L --fail --retry 8 --retry-delay 5 --retry-all-errors \
    --connect-timeout 30 --max-time 7200 -o "$2" "$1"
}

log_section "DOWNLOAD"
cd "$ROOT"
download "$YSL_URL" yachtsense-v5.30.zip
download "$AXIOM_URL" axiom-lh4.11.133.zip
sha256sum *.zip > "$OUT/sha256.txt"
ls -lh *.zip > "$OUT/downloads.txt"

log_section "YACHTSENSE CUSTOM PACKAGE"
mkdir -p "$ROOT/ysl-outer" "$ROOT/ysl-tar" "$ROOT/ysl-extracted" "$ROOT/ysl-binwalk"
7z x -y yachtsense-v5.30.zip -o"$ROOT/ysl-outer" > "$OUT/ysl-outer-unzip.log" 2>&1
YSL_PACKAGE="$(find "$ROOT/ysl-outer" -type f | head -n1)"
printf 'YSL_PACKAGE=%s\n' "$YSL_PACKAGE" > "$OUT/selected-files.txt"

python3 - "$YSL_PACKAGE" "$ROOT/ysl-tar/payload.bz2" "$OUT/ysl-header.bin" "$OUT/ysl-header.txt" <<'PY'
import pathlib, sys
src, payload_out, header_bin, header_txt = map(pathlib.Path, sys.argv[1:])
data = src.read_bytes()
off = data.find(b'BZh')
if off < 0:
    raise SystemExit('No BZip2 stream found')
pathlib.Path(payload_out).write_bytes(data[off:])
header = data[:off]
pathlib.Path(header_bin).write_bytes(header)
printable = ''.join(chr(b) if 32 <= b < 127 else '.' for b in header)
pathlib.Path(header_txt).write_text(
    f'payload_offset_decimal={off}\npayload_offset_hex=0x{off:x}\nheader_length={len(header)}\n'
    f'header_ascii={printable}\nheader_hex={header.hex()}\n'
)
print(off)
PY

bzip2 -tvv "$ROOT/ysl-tar/payload.bz2" > "$OUT/ysl-bzip-test.log" 2>&1 || true
bzip2 -dc "$ROOT/ysl-tar/payload.bz2" > "$ROOT/ysl-tar/payload.tar" 2> "$OUT/ysl-bzip-decompress.log" || true
file "$ROOT/ysl-tar/payload.tar" > "$OUT/ysl-payload-filetype.txt" 2>&1 || true
tar -tvf "$ROOT/ysl-tar/payload.tar" > "$OUT/ysl-tar-list.txt" 2>&1 || true
tar -xf "$ROOT/ysl-tar/payload.tar" -C "$ROOT/ysl-extracted" > "$OUT/ysl-tar-extract.log" 2>&1 || \
  7z x -y "$ROOT/ysl-tar/payload.tar" -o"$ROOT/ysl-extracted" >> "$OUT/ysl-tar-extract.log" 2>&1 || true
find "$ROOT/ysl-extracted" -printf '%y %s %p\n' | sort > "$OUT/ysl-extracted-filelist.txt"
find "$ROOT/ysl-extracted" -type f -print0 | xargs -0 -r file > "$OUT/ysl-extracted-filetypes.txt" 2>&1 || true

# Extract embedded filesystems from every significant YachtSense payload.
find "$ROOT/ysl-extracted" -type f -size +256k -print0 | while IFS= read -r -d '' f; do
  safe="$(printf '%s' "$f" | sha256sum | cut -c1-16)"
  dest="$ROOT/ysl-binwalk/$safe"
  mkdir -p "$dest"
  echo "===== $f =====" >> "$OUT/ysl-binwalk-index.txt"
  binwalk "$f" >> "$OUT/ysl-binwalk-index.txt" 2>&1 || true
  (cd "$dest" && sudo binwalk -eM --run-as=root "$f") > "$OUT/ysl-binwalk-$safe.log" 2>&1 || true
done
sudo chown -R "$(id -u):$(id -g)" "$ROOT/ysl-binwalk" 2>/dev/null || true
find "$ROOT/ysl-binwalk" -printf '%y %s %p\n' | sort > "$OUT/ysl-binwalk-filelist.txt"

log_section "AXIOM ROCKCHIP PACKAGE"
mkdir -p "$ROOT/axiom-zip" "$ROOT/axiom-iso" "$ROOT/axiom-rk1" "$ROOT/axiom-rk2" "$ROOT/axiom-system"
7z x -y axiom-lh4.11.133.zip -o"$ROOT/axiom-zip" > "$OUT/axiom-zip-extract.log" 2>&1
ISO="$(find "$ROOT/axiom-zip" -type f -iname '*.iso' | head -n1)"
printf 'AXIOM_ISO=%s\n' "$ISO" >> "$OUT/selected-files.txt"
7z x -y "$ISO" -o"$ROOT/axiom-iso" > "$OUT/axiom-iso-extract.log" 2>&1
IMG="$(find "$ROOT/axiom-iso" -type f -iname 'raymarine_axiom_upgrade-*.img' | head -n1)"
printf 'AXIOM_IMG=%s\n' "$IMG" >> "$OUT/selected-files.txt"

# afptool-rs does not create parent directories for Rockchip full_path entries.
# Patch that omission locally before building, otherwise Raymarine's ../raymarine.axiom_mfg path aborts extraction.
git clone --depth 1 https://github.com/suyulin/afptool-rs.git "$ROOT/afptool-rs" > "$OUT/afptool-clone.log" 2>&1
python3 - "$ROOT/afptool-rs/src/unpack.rs" <<'PY'
from pathlib import Path
p = Path(__import__('sys').argv[1])
s = p.read_text()
old = '    let mut fp_out = File::create(full_path)?;'
new = '''    if let Some(parent) = Path::new(full_path).parent() {
        std::fs::create_dir_all(parent)?;
    }
    let mut fp_out = File::create(full_path)?;'''
if old not in s:
    raise SystemExit('afptool extraction function changed; patch not applied')
p.write_text(s.replace(old, new, 1))
PY
(cd "$ROOT/afptool-rs" && cargo build --release) > "$OUT/afptool-build.log" 2>&1
AFP="$ROOT/afptool-rs/target/release/afptool-rs"
"$AFP" unpack "$IMG" "$ROOT/axiom-rk1" > "$OUT/axiom-rk-unpack1.log" 2>&1
INNER="$(find "$ROOT/axiom-rk1" -type f -iname 'embedded-update.img' | head -n1)"
printf 'AXIOM_INNER=%s\n' "$INNER" >> "$OUT/selected-files.txt"
"$AFP" unpack "$INNER" "$ROOT/axiom-rk2" > "$OUT/axiom-rk-unpack2.log" 2>&1 || true
find "$ROOT/axiom-rk2" -name package-file -exec cp {} "$OUT/axiom-package-file.txt" \; 2>/dev/null || true
find "$ROOT/axiom-rk2" -name partition-metadata.txt -exec cp {} "$OUT/axiom-partition-metadata.txt" \; 2>/dev/null || true
find "$ROOT/axiom-rk1" "$ROOT/axiom-rk2" -printf '%y %s %p\n' | sort > "$OUT/axiom-rk-filelist.txt"
find "$ROOT/axiom-rk1" "$ROOT/axiom-rk2" -type f -print0 | xargs -0 -r file > "$OUT/axiom-rk-filetypes.txt" 2>&1 || true

SYSTEM="$(find "$ROOT/axiom-rk1" "$ROOT/axiom-rk2" -type f -iname 'system.img' | head -n1)"
printf 'AXIOM_SYSTEM=%s\n' "$SYSTEM" >> "$OUT/selected-files.txt"
if [ -n "$SYSTEM" ]; then
  file "$SYSTEM" > "$OUT/axiom-system-filetype.txt"
  if file -b "$SYSTEM" | grep -qi squashfs; then
    unsquashfs -f -d "$ROOT/axiom-system" "$SYSTEM" > "$OUT/axiom-system-extract.log" 2>&1 || true
  elif file -b "$SYSTEM" | grep -Eqi 'ext[234] filesystem'; then
    debugfs -R "rdump / $ROOT/axiom-system" "$SYSTEM" > "$OUT/axiom-system-extract.log" 2>&1 || true
  elif command -v simg2img >/dev/null && file -b "$SYSTEM" | grep -qi sparse; then
    simg2img "$SYSTEM" "$ROOT/axiom-system.raw.img"
    debugfs -R "rdump / $ROOT/axiom-system" "$ROOT/axiom-system.raw.img" > "$OUT/axiom-system-extract.log" 2>&1 || true
  else
    7z x -y "$SYSTEM" -o"$ROOT/axiom-system" > "$OUT/axiom-system-extract.log" 2>&1 || true
  fi
fi
find "$ROOT/axiom-system" -printf '%y %s %p\n' | sort > "$OUT/axiom-system-filelist.txt"

log_section "STATIC RECOGNITION SEARCH"
SEARCH_ROOTS=("$ROOT/ysl-extracted" "$ROOT/ysl-binwalk" "$ROOT/axiom-system")
: > "$OUT/text-content-hits.txt"
: > "$OUT/direct-files.txt"
: > "$OUT/direct-context.txt"
: > "$OUT/network-files.txt"
: > "$OUT/network-strings.txt"

for d in "${SEARCH_ROOTS[@]}"; do
  [ -d "$d" ] || continue
  echo "===== ROOT $d =====" >> "$OUT/text-content-hits.txt"
  rg -a -i -n --no-messages --max-columns 1000 --max-columns-preview "$PATTERN" "$d" >> "$OUT/text-content-hits.txt" || true
  find "$d" -type f | grep -Eai '(yacht|sense|ysl|raynet|router|network|gateway|dhcp|lldp|discover|avahi|mdns|ssdp|upnp|connect|ethernet|nmea|seatalk)' >> "$OUT/network-files.txt" || true
done
sort -u "$OUT/network-files.txt" -o "$OUT/network-files.txt"

# Scan all manageable binaries and archives, not just suggestive filenames.
find "${SEARCH_ROOTS[@]}" -type f -size -150M -print0 2>/dev/null | while IFS= read -r -d '' f; do
  ascii="$(strings -a -n 4 "$f" 2>/dev/null | grep -Eai "$DIRECT|Internet.?Source|198\.18\.|vendor.?class|option.?43|option.?60|LLDP|RayNet|discover" | head -n 80 || true)"
  utf16="$(strings -el -n 4 "$f" 2>/dev/null | grep -Eai "$DIRECT|Internet.?Source|198\.18\.|vendor.?class|option.?43|option.?60|LLDP|RayNet|discover" | head -n 80 || true)"
  if [ -n "$ascii$utf16" ]; then
    echo "$f" >> "$OUT/direct-files.txt"
    echo "===== $f =====" >> "$OUT/direct-context.txt"
    file "$f" >> "$OUT/direct-context.txt" 2>&1 || true
    printf '%s\n%s\n' "$ascii" "$utf16" >> "$OUT/direct-context.txt"
  fi
done
sort -u "$OUT/direct-files.txt" -o "$OUT/direct-files.txt"

while IFS= read -r f; do
  [ -f "$f" ] || continue
  [ "$(stat -c %s "$f")" -le 157286400 ] || continue
  echo "===== $f =====" >> "$OUT/network-strings.txt"
  strings -a -n 4 "$f" 2>/dev/null | grep -Eai -C 20 "$PATTERN" >> "$OUT/network-strings.txt" || true
  strings -el -n 4 "$f" 2>/dev/null | grep -Eai -C 20 "$PATTERN" >> "$OUT/network-strings.txt" || true
done < "$OUT/network-files.txt"

# Preserve small files containing the strongest hits for later decompilation.
mkdir -p "$OUT/relevant-files"
while IFS= read -r f; do
  [ -f "$f" ] || continue
  [ "$(stat -c %s "$f")" -le 25000000 ] || continue
  rel="$(printf '%s' "$f" | sed "s#^$ROOT/##")"
  mkdir -p "$OUT/relevant-files/$(dirname "$rel")"
  cp "$f" "$OUT/relevant-files/$rel" 2>/dev/null || true
done < "$OUT/direct-files.txt"

# Keep text output sizes practical.
for f in "$OUT"/*.txt; do
  [ -f "$f" ] || continue
  if [ "$(stat -c %s "$f")" -gt 30000000 ]; then
    head -c 30000000 "$f" > "$f.cut"
    mv "$f.cut" "$f"
    printf '\n[TRUNCATED AT 30 MB]\n' >> "$f"
  fi
done

{
  echo "Raymarine deep firmware analysis"
  echo "Generated: $(date -u +%FT%TZ)"
  echo
  cat "$OUT/selected-files.txt"
  echo
  cat "$OUT/ysl-header.txt" 2>/dev/null || true
  echo
  echo "Direct/network-relevant binary files: $(wc -l < "$OUT/direct-files.txt" 2>/dev/null || echo 0)"
  echo "YachtSense identity hits: $(grep -Eic 'Yacht.?Sense|E70640|GetHubInfo' "$OUT/text-content-hits.txt" 2>/dev/null || true)"
  echo "LLDP hits: $(grep -Eic 'LLDP|lldpd' "$OUT/text-content-hits.txt" 2>/dev/null || true)"
  echo "DHCP vendor-option hits: $(grep -Eic 'option.?43|option.?60|vendor.?class|DHCP.?option' "$OUT/text-content-hits.txt" 2>/dev/null || true)"
  echo "RayNet/discovery hits: $(grep -Eic 'RayNet|discover' "$OUT/text-content-hits.txt" 2>/dev/null || true)"
  echo
  echo "Direct files:"
  cat "$OUT/direct-files.txt" 2>/dev/null || true
} > "$OUT/summary.txt"
cat "$OUT/summary.txt"
