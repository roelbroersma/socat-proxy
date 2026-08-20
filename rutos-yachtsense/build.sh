#!/usr/bin/env bash
set -euo pipefail

SDK_URL="https://firmware.teltonika-networks.com/7.24.1/RUTX/RUTX_R_GPL_00.07.24.1.tar.gz"
SDK_MD5="16efcff8ccb26a6c8ab7b7636da45b64"
VERSION="2.0.0-1"
RUTOS="7.24.1"

ROOT="${RUNNER_TEMP:-/tmp}/yachtsense-rutos-build"
WORKSPACE="${GITHUB_WORKSPACE:-$PWD}"
DIST="$WORKSPACE/dist"
rm -rf "$ROOT" "$DIST"
mkdir -p "$ROOT/source" "$ROOT/sdk" "$DIST/ipks" "$DIST/inspection"

log() { printf '\n===== %s =====\n' "$*"; }

log "Loading package source"
cp "$WORKSPACE/rutos-yachtsense/source.tar.gz" "$ROOT/source.tar.gz"
gzip -t "$ROOT/source.tar.gz"
tar -xzf "$ROOT/source.tar.gz" -C "$ROOT/source"
find "$ROOT/source" -type f -print | sort | tee "$DIST/source-files.txt"

log "Downloading official RUTX RutOS ${RUTOS} GPL SDK"
curl -L --fail --retry 8 --retry-delay 5 --retry-all-errors \
  --connect-timeout 30 --max-time 7200 -o "$ROOT/sdk.tar.gz" "$SDK_URL"
echo "$SDK_MD5  $ROOT/sdk.tar.gz" | md5sum -c -
tar -xzf "$ROOT/sdk.tar.gz" -C "$ROOT/sdk" --strip-components=1
SDK="$ROOT/sdk"
test -x "$SDK/scripts/dockerbuild"
test -d "$SDK/package/feeds/vuci"

log "Installing YachtSense packages into SDK"
cp -a "$ROOT/source/yachtsense-emulator" "$SDK/package/"
cp -a "$ROOT/source/vuci-app-yachtsense-emulator-api" "$SDK/package/feeds/vuci/"
cp -a "$ROOT/source/vuci-app-yachtsense-emulator-ui" "$SDK/package/feeds/vuci/"

# Register the UI package for RutOS Package Manager metadata.
if [ -f "$SDK/ipk_packages.json" ]; then
  jq '. + {
    "vuci-app-yachtsense-emulator-ui": {
      "name": "yachtsense_link_emulator",
      "vuci_dep": "vuci-app-yachtsense-emulator-api",
      "base_dep": "yachtsense-emulator",
      "third_party": true
    }
  }' "$SDK/ipk_packages.json" > "$SDK/ipk_packages.json.new"
  mv "$SDK/ipk_packages.json.new" "$SDK/ipk_packages.json"
fi

for package in \
  yachtsense-emulator \
  vuci-app-yachtsense-emulator-api \
  vuci-app-yachtsense-emulator-ui; do
  sed -i "/^CONFIG_PACKAGE_${package}=/d;/^# CONFIG_PACKAGE_${package} is not set/d" "$SDK/.config"
  printf 'CONFIG_PACKAGE_%s=m\n' "$package" >> "$SDK/.config"
done

log "Normalizing SDK configuration"
cd "$SDK"
./scripts/dockerbuild make defconfig

grep -E '^CONFIG_PACKAGE_(yachtsense-emulator|vuci-app-yachtsense-emulator-(api|ui))=' .config \
  | tee "$DIST/selected-packages.txt"

log "Building native emulator"
./scripts/dockerbuild make package/yachtsense-emulator/clean V=s
./scripts/dockerbuild make package/yachtsense-emulator/compile V=s -j2

log "Building VuCI API"
./scripts/dockerbuild make package/vuci-app-yachtsense-emulator-api/clean V=s
./scripts/dockerbuild make package/vuci-app-yachtsense-emulator-api/compile V=s -j2

log "Building VuCI web interface"
./scripts/dockerbuild make package/vuci-app-yachtsense-emulator-ui/clean V=s
./scripts/dockerbuild make package/vuci-app-yachtsense-emulator-ui/compile V=s -j2

find bin/packages -type f -name '*.ipk' | sort > "$DIST/all-built-ipks.txt"
BASE_IPK="$(find bin/packages -type f -name 'yachtsense-emulator_*.ipk' | head -n1)"
API_IPK="$(find bin/packages -type f -name 'vuci-app-yachtsense-emulator-api_*.ipk' | head -n1)"
UI_IPK="$(find bin/packages -type f -name 'vuci-app-yachtsense-emulator-ui_*.ipk' | head -n1)"

for ipk in "$BASE_IPK" "$API_IPK" "$UI_IPK"; do
  test -n "$ipk"
  test -s "$ipk"
  cp "$ipk" "$DIST/ipks/"
done

ipk_control() {
  local ipk="$1"
  if tar -tzf "$ipk" >/dev/null 2>&1; then
    tar -xOzf "$ipk" ./control.tar.gz | tar -xzO ./control
  else
    ar p "$ipk" control.tar.gz | tar -xzO ./control
  fi
}

ipk_extract_data() {
  local ipk="$1" dest="$2"
  mkdir -p "$dest"
  if tar -tzf "$ipk" >/dev/null 2>&1; then
    tar -xOzf "$ipk" ./data.tar.gz | tar -xz -C "$dest"
  else
    ar p "$ipk" data.tar.gz | tar -xz -C "$dest"
  fi
}

log "Inspecting generated packages"
ipk_control "$BASE_IPK" > "$DIST/inspection/base-control.txt"
ipk_control "$API_IPK" > "$DIST/inspection/api-control.txt"
ipk_control "$UI_IPK" > "$DIST/inspection/ui-control.txt"
ipk_extract_data "$BASE_IPK" "$DIST/inspection/base"
ipk_extract_data "$API_IPK" "$DIST/inspection/api"
ipk_extract_data "$UI_IPK" "$DIST/inspection/ui"

# Verify the files that make the application functional.
test -x "$DIST/inspection/base/usr/sbin/yachtsense-emulator"
test -x "$DIST/inspection/base/etc/init.d/yachtsense-emulator"
test -f "$DIST/inspection/base/etc/config/yachtsense_emulator"
test -f "$DIST/inspection/api/usr/share/vuci/path.d/yachtsense-emulator.json"
test -f "$DIST/inspection/api/usr/share/rpcd/acl.d/yachtsense-emulator.json"
test -f "$DIST/inspection/ui/usr/share/vuci/menu.d/yachtsense-emulator.json"

# A compiled VuCI page must result in at least one deployed JavaScript asset/view.
if ! find "$DIST/inspection/ui/www" -type f \( -name '*.js' -o -name '*.mjs' \) -print -quit 2>/dev/null | grep -q .; then
  echo "No compiled VuCI JavaScript found in UI package" >&2
  find "$DIST/inspection/ui" -type f -print >&2
  exit 1
fi

file "$DIST/inspection/base/usr/sbin/yachtsense-emulator" > "$DIST/inspection/base-binary.txt"
readelf -h "$DIST/inspection/base/usr/sbin/yachtsense-emulator" >> "$DIST/inspection/base-binary.txt"
find "$DIST/inspection" -type f -printf '%P\n' | sort > "$DIST/inspection/package-file-list.txt"

log "Creating single uploadable RutOS package"
BUNDLE="$ROOT/bundle"
mkdir -p "$BUNDLE"
cp "$BASE_IPK" "$API_IPK" "$UI_IPK" "$BUNDLE/"
BASE_NAME="$(basename "$BASE_IPK")"
API_NAME="$(basename "$API_IPK")"
UI_NAME="$(basename "$UI_IPK")"

UI_CONTROL="$(ipk_control "$UI_IPK")"
PACKAGE="$(printf '%s\n' "$UI_CONTROL" | sed -n 's/^Package: *//p' | head -n1)"
PKG_VERSION="$(printf '%s\n' "$UI_CONTROL" | sed -n 's/^Version: *//p' | head -n1)"
ROUTER="$(printf '%s\n' "$UI_CONTROL" | sed -n 's/^Router: *//p' | head -n1)"
TLT_NAME="$(printf '%s\n' "$UI_CONTROL" | sed -n 's/^tlt_name: *//p' | head -n1)"
[ -n "$PACKAGE" ] || PACKAGE="vuci-app-yachtsense-emulator-ui"
[ -n "$PKG_VERSION" ] || PKG_VERSION="$VERSION"
[ -n "$ROUTER" ] || ROUTER="RUTX"
[ -n "$TLT_NAME" ] || TLT_NAME="YachtSense Link Emulator"

{
  printf 'Package: %s\n' "$PACKAGE"
  printf 'Version: %s\n' "$PKG_VERSION"
  printf 'Router: %s\n' "$ROUTER"
  printf 'tlt_name: %s\n' "$TLT_NAME"
  printf 'Description: Raymarine YachtSense Link mDNS and HTTP emulator with VuCI control page\n'
  printf 'Third-Party: True\n'
  printf 'ipk_file: %s:unsigned\n' "$UI_NAME"
  printf 'ipk_deps: %s:unsigned %s:unsigned\n' "$API_NAME" "$BASE_NAME"
} > "$BUNDLE/main"

BUNDLE_NAME="YachtSense-Link-Emulator-RUTX14-RutOS-${RUTOS}.tar.gz"
tar -czf "$DIST/$BUNDLE_NAME" -C "$BUNDLE" .

cat > "$DIST/README.txt" <<README
YachtSense Link Emulator for Teltonika RUTX14 / RutOS ${RUTOS}

Preferred installation:
1. Open System > Package Manager in RutOS.
2. Upload ${BUNDLE_NAME}.
3. Continue when RutOS reports that this custom package is unsigned/unverified.
4. Open Services > YachtSense Link.

The page contains master enable, separate mDNS and HTTP switches, interface
selection, RayNet address settings, Start/Stop/Restart buttons and recent logs.

Direct SSH fallback:
opkg install /tmp/${BASE_NAME} /tmp/${API_NAME} /tmp/${UI_NAME}
README

(
  cd "$DIST/ipks"
  zip -9 "$DIST/YachtSense-Link-Emulator-RUTX14-RutOS-${RUTOS}-IPKs.zip" \
    "$BASE_NAME" "$API_NAME" "$UI_NAME"
)

{
  echo "Built from official RUTX RutOS ${RUTOS} GPL SDK"
  echo "SDK URL: $SDK_URL"
  echo
  echo "Package controls:"
  echo "--- Base ---"
  cat "$DIST/inspection/base-control.txt"
  echo "--- API ---"
  cat "$DIST/inspection/api-control.txt"
  echo "--- UI ---"
  cat "$DIST/inspection/ui-control.txt"
  echo
  sha256sum "$DIST/$BUNDLE_NAME" "$DIST/"*.zip "$DIST/ipks/"*.ipk
} > "$DIST/build-manifest.txt"

# Do not duplicate all extracted package contents in the downloadable artifact.
rm -rf "$DIST/inspection/base" "$DIST/inspection/api" "$DIST/inspection/ui"

log "Build complete"
ls -lh "$DIST"
cat "$DIST/build-manifest.txt"
