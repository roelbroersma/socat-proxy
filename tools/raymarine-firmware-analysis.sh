#!/usr/bin/env bash
set -uo pipefail

ROOT="${RUNNER_TEMP:-/tmp}/raymarine-analysis"
OUT="${GITHUB_WORKSPACE:-$PWD}/report"
mkdir -p "$ROOT" "$OUT"

YSL_URL="https://teledyne.app.box.com/public/static/hfmbusrqondj2u7zgxevdejrtzxtgcqn.zip"
AXIOM_URL="https://teledyne.app.box.com/public/static/18w6yebq78srqv88gl4exetufg1b0o77.zip"
PATTERN='Yacht.?Sense|Yacht Sense|YSL|E70640|GetHubInfo|GetHomeStatus|LanConfigure|198\.18\.|Internet.?Source|preferred.?internet|default.?gateway|DHCP.?option|option.?43|option.?60|vendor.?class|vendorclass|LLDP|lldpd|mDNS|avahi|SSDP|UPnP|RayNet|discovery|discover|cloudconnector|protobuf|proto2|proto3|7778|9999'
DIRECT='Yacht.?Sense|Yacht Sense|E70640|GetHubInfo'

section() {
  printf '\n===== %s =====\n' "$*"
}

download() {
  local url="$1" output="$2"
  curl -L --fail --retry 8 --retry-delay 5 --retry-all-errors \
    --connect-timeout 30 --max-time 7200 -o "$output" "$url"
}

section "DOWNLOAD"
cd "$ROOT"
download "$YSL_URL" yachtsense-v5.30.zip
download "$AXIOM_URL" axiom-lh4.11.133.zip
sha256sum *.zip | tee "$OUT/sha256.txt"
ls -lh *.zip | tee "$OUT/downloads.txt"
file *.zip | tee "$OUT/download-types.txt"

section "YACHTSENSE EXTRACT"
mkdir -p "$ROOT/ysl" "$ROOT/ysl-binwalk"
7z x -y "$ROOT/yachtsense-v5.30.zip" -o"$ROOT/ysl" >"$OUT/ysl-unzip.log" 2>&1 || true
find "$ROOT/ysl" -printf '%y %s %p\n' | sort >"$OUT/ysl-filelist.txt"
find "$ROOT/ysl" -type f -print0 | xargs -0 -r file >"$OUT/ysl-filetypes.txt" 2>&1 || true

# Expand normal nested archives without touching the original files.
for round in 1 2 3; do
  while IFS= read -r -d '' f; do
    marker="$f.analysis-expanded"
    [ -e "$marker" ] && continue
    touch "$marker"
    dest="$f.expanded"
    mkdir -p "$dest"
    7z x -y "$f" -o"$dest" >/dev/null 2>&1 || rmdir "$dest" 2>/dev/null || true
  done < <(find "$ROOT/ysl" -type f \( -iname '*.zip' -o -iname '*.tar' -o -iname '*.tgz' -o -iname '*.tar.gz' -o -iname '*.tar.bz2' -o -iname '*.tar.xz' -o -iname '*.gz' -o -iname '*.bz2' -o -iname '*.xz' \) -print0)
done

: >"$OUT/ysl-binwalk.txt"
find "$ROOT/ysl" -type f -size +256k -print0 | while IFS= read -r -d '' f; do
  echo "===== $f =====" >>"$OUT/ysl-binwalk.txt"
  binwalk "$f" >>"$OUT/ysl-binwalk.txt" 2>&1 || true
done

# Let binwalk extract embedded filesystems; failures are retained in the report.
find "$ROOT/ysl" -type f -size +1M -print0 | while IFS= read -r -d '' f; do
  safe="$(basename "$f" | tr -c 'A-Za-z0-9._-' '_')"
  dest="$ROOT/ysl-binwalk/$safe"
  mkdir -p "$dest"
  (cd "$dest" && binwalk -eM --run-as=root "$f") >"$OUT/binwalk-extract-$safe.log" 2>&1 || true
done
find "$ROOT/ysl-binwalk" -printf '%y %s %p\n' | sort >"$OUT/ysl-binwalk-filelist.txt"

section "AXIOM EXTRACT"
mkdir -p "$ROOT/axiom-zip" "$ROOT/axiom-iso" "$ROOT/axiom-rk1" "$ROOT/axiom-rk2" "$ROOT/axiom-system"
7z x -y "$ROOT/axiom-lh4.11.133.zip" -o"$ROOT/axiom-zip" >"$OUT/axiom-unzip.log" 2>&1 || true
find "$ROOT/axiom-zip" -printf '%y %s %p\n' | sort >"$OUT/axiom-zip-filelist.txt"

ISO="$(find "$ROOT/axiom-zip" -type f -iname '*.iso' | head -n1)"
printf 'ISO=%s\n' "$ISO" >"$OUT/axiom-selected.txt"
if [ -n "$ISO" ]; then
  7z x -y "$ISO" -o"$ROOT/axiom-iso" >"$OUT/axiom-iso-extract.log" 2>&1 || true
fi
find "$ROOT/axiom-iso" -printf '%y %s %p\n' | sort >"$OUT/axiom-iso-filelist.txt"

IMG="$(find "$ROOT/axiom-iso" "$ROOT/axiom-zip" -type f -iname 'raymarine_axiom_upgrade-*.img' 2>/dev/null | head -n1)"
printf 'IMG=%s\n' "$IMG" >>"$OUT/axiom-selected.txt"
[ -n "$IMG" ] && file "$IMG" >"$OUT/axiom-img-filetype.txt" 2>&1 || true

if [ -n "$IMG" ]; then
  git clone --depth 1 https://github.com/suyulin/afptool-rs.git "$ROOT/afptool-rs" >"$OUT/afptool-clone.log" 2>&1 || true
  (cd "$ROOT/afptool-rs" && cargo build --release) >"$OUT/afptool-build.log" 2>&1 || true
  AFP="$ROOT/afptool-rs/target/release/afptool-rs"
  if [ -x "$AFP" ]; then
    "$AFP" unpack "$IMG" "$ROOT/axiom-rk1" >"$OUT/axiom-rk-unpack1.log" 2>&1 || true
    INNER="$(find "$ROOT/axiom-rk1" -type f \( -iname 'embedded-update.img' -o -iname '*update*.img' \) | head -n1)"
    printf 'INNER=%s\n' "$INNER" >>"$OUT/axiom-selected.txt"
    [ -n "$INNER" ] && "$AFP" unpack "$INNER" "$ROOT/axiom-rk2" >"$OUT/axiom-rk-unpack2.log" 2>&1 || true
  fi
fi
find "$ROOT/axiom-rk1" "$ROOT/axiom-rk2" -printf '%y %s %p\n' | sort >"$OUT/axiom-rk-filelist.txt" 2>/dev/null || true

SYSTEM="$(find "$ROOT/axiom-rk1" "$ROOT/axiom-rk2" -type f -iname 'system.img' 2>/dev/null | head -n1)"
printf 'SYSTEM=%s\n' "$SYSTEM" >>"$OUT/axiom-selected.txt"
if [ -n "$SYSTEM" ]; then
  file "$SYSTEM" >"$OUT/axiom-system-filetype.txt" 2>&1 || true
  if file -b "$SYSTEM" | grep -qi squashfs; then
    unsquashfs -f -d "$ROOT/axiom-system" "$SYSTEM" >"$OUT/axiom-unsquashfs.log" 2>&1 || true
  elif file -b "$SYSTEM" | grep -Eqi 'ext[234] filesystem'; then
    debugfs -R "rdump / $ROOT/axiom-system" "$SYSTEM" >"$OUT/axiom-debugfs.log" 2>&1 || true
  else
    7z x -y "$SYSTEM" -o"$ROOT/axiom-system" >"$OUT/axiom-system-7z.log" 2>&1 || true
  fi
fi
find "$ROOT/axiom-system" -printf '%y %s %p\n' | sort >"$OUT/axiom-system-filelist.txt" 2>/dev/null || true

section "CONTENT SEARCH"
ROOTS=("$ROOT/ysl" "$ROOT/ysl-binwalk" "$ROOT/axiom-system")
: >"$OUT/content-hits.txt"
: >"$OUT/direct-files.txt"
: >"$OUT/direct-context.txt"
: >"$OUT/archive-context.txt"
: >"$OUT/relevant-filenames.txt"

for d in "${ROOTS[@]}"; do
  [ -d "$d" ] || continue
  echo "===== ROOT $d =====" >>"$OUT/content-hits.txt"
  rg -a -i -n --no-messages --max-columns 800 --max-columns-preview "$PATTERN" "$d" >>"$OUT/content-hits.txt" || true
  find "$d" -type f | grep -Eai '(yacht|sense|ysl|raynet|router|network|gateway|dhcp|lldp|discover|avahi|mdns|ssdp|upnp|connect|ethernet)' >>"$OUT/relevant-filenames.txt" || true

done
sort -u "$OUT/relevant-filenames.txt" -o "$OUT/relevant-filenames.txt"

# Inspect native binaries/configs containing direct YachtSense identity strings.
find "${ROOTS[@]}" -type f -size -100M -print0 2>/dev/null | while IFS= read -r -d '' f; do
  if strings -a -n 5 "$f" 2>/dev/null | grep -Eqi "$DIRECT"; then
    echo "$f" >>"$OUT/direct-files.txt"
    echo "===== $f =====" >>"$OUT/direct-context.txt"
    file "$f" >>"$OUT/direct-context.txt" 2>&1 || true
    strings -a -n 4 "$f" 2>/dev/null | grep -Eai -C 35 "$PATTERN" >>"$OUT/direct-context.txt" || true
    strings -el -n 4 "$f" 2>/dev/null | grep -Eai -C 35 "$PATTERN" >>"$OUT/direct-context.txt" || true
    readelf -h -d -s "$f" >>"$OUT/direct-context.txt" 2>/dev/null || true
  fi
done
sort -u "$OUT/direct-files.txt" -o "$OUT/direct-files.txt"

# APK/JAR content is compressed, so inspect the decompressed byte stream too.
find "$ROOT/axiom-system" -type f \( -iname '*.apk' -o -iname '*.jar' -o -iname '*.zip' \) -print0 2>/dev/null | while IFS= read -r -d '' f; do
  if unzip -p "$f" 2>/dev/null | strings -a -n 4 | grep -Eqi "$DIRECT"; then
    echo "===== $f =====" >>"$OUT/archive-context.txt"
    unzip -p "$f" 2>/dev/null | strings -a -n 4 | grep -Eai -C 35 "$PATTERN" >>"$OUT/archive-context.txt" || true
    unzip -p "$f" 2>/dev/null | strings -el -n 4 | grep -Eai -C 35 "$PATTERN" >>"$OUT/archive-context.txt" || true
  fi
done

# Keep committed text files within GitHub limits while retaining the earliest hits.
for f in "$OUT/content-hits.txt" "$OUT/direct-context.txt" "$OUT/archive-context.txt"; do
  if [ -f "$f" ] && [ "$(stat -c %s "$f")" -gt 20000000 ]; then
    head -c 20000000 "$f" >"$f.truncated"
    mv "$f.truncated" "$f"
    printf '\n[TRUNCATED AT 20 MB]\n' >>"$f"
  fi
done

{
  echo "Raymarine firmware recognition analysis"
  echo "Generated: $(date -u +%FT%TZ)"
  echo
  cat "$OUT/downloads.txt" 2>/dev/null || true
  echo
  cat "$OUT/axiom-selected.txt" 2>/dev/null || true
  echo
  echo "Direct identity files: $(wc -l < "$OUT/direct-files.txt" 2>/dev/null || echo 0)"
  echo "YachtSense/E70640/GetHubInfo content hits: $(grep -Eic 'Yacht.?Sense|E70640|GetHubInfo' "$OUT/content-hits.txt" 2>/dev/null || true)"
  echo "LLDP hits: $(grep -Eic 'LLDP|lldpd' "$OUT/content-hits.txt" 2>/dev/null || true)"
  echo "DHCP vendor-option hits: $(grep -Eic 'option.?43|option.?60|vendor.?class|DHCP.?option' "$OUT/content-hits.txt" 2>/dev/null || true)"
  echo "RayNet/discovery hits: $(grep -Eic 'RayNet|discover' "$OUT/content-hits.txt" 2>/dev/null || true)"
  echo
  echo "Direct files:"
  cat "$OUT/direct-files.txt" 2>/dev/null || true
} >"$OUT/summary.txt"

cat "$OUT/summary.txt"
