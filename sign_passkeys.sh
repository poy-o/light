#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENTITLEMENTS_PLIST="${SCRIPT_DIR}/chrome/app/app-entitlements.plist"
OUT_DIR="${SCRIPT_DIR}/out/Release_GN_arm64"
APP_PATHS=()

usage() {
  cat <<EOF
Usage: $(basename "$0") [--app /path/to/App.app ...]

Ad-hoc signs one or more Light/Chromium .app bundles with the native Apple
Passkeys entitlements (com.apple.developer.web-browser.public-key-credential,
com.apple.application-identifier, keychain-access-groups, associated-domains)
and registers all their cdhashes together with amfi-allow
(https://github.com/Lakr233/amfi-allow), auto-installing amfi-allow if missing.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      APP_PATHS+=("${2:-}")
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ ${#APP_PATHS[@]} -eq 0 ]]; then
  if [[ -d "${OUT_DIR}/Light.app" ]]; then
    APP_PATHS+=("${OUT_DIR}/Light.app")
  elif [[ -d "${OUT_DIR}/Chromium.app" ]]; then
    APP_PATHS+=("${OUT_DIR}/Chromium.app")
  else
    echo "Error: Could not find Light.app or Chromium.app in ${OUT_DIR}" >&2
    echo "Pass --app /path/to/Your.app explicitly." >&2
    exit 1
  fi
fi

if [[ ! -f "$ENTITLEMENTS_PLIST" ]]; then
  echo "Error: Entitlements plist not found at: $ENTITLEMENTS_PLIST" >&2
  exit 1
fi

find_amfi_allow() {
  if command -v amfi-allow >/dev/null 2>&1; then
    command -v amfi-allow
    return 0
  fi
  for candidate in "/usr/local/bin/amfi-allow" "/opt/homebrew/bin/amfi-allow" "${HOME}/.local/bin/amfi-allow"; do
    if [[ -x "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

install_amfi_allow() {
  echo "==> amfi-allow not found; installing from https://github.com/Lakr233/amfi-allow ..."
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' RETURN

  git clone --depth 1 https://github.com/Lakr233/amfi-allow.git "${tmp_dir}/amfi-allow"
  make -C "${tmp_dir}/amfi-allow"

  local built_bin
  built_bin="$(find "${tmp_dir}/amfi-allow" -maxdepth 3 -type f -name "amfi-allow" -perm -111 | head -n 1 || true)"
  if [[ -z "$built_bin" ]]; then
    echo "Error: Built amfi-allow binary not found after make." >&2
    exit 1
  fi

  if [[ -w "/usr/local/bin" ]]; then
    install -m 755 "$built_bin" /usr/local/bin/amfi-allow
    echo "/usr/local/bin/amfi-allow"
  else
    echo "==> Installing amfi-allow to /usr/local/bin (requires sudo)..."
    sudo mkdir -p /usr/local/bin
    sudo install -m 755 "$built_bin" /usr/local/bin/amfi-allow
    echo "/usr/local/bin/amfi-allow"
  fi
}

write_app_entitlements() {
  local bundle_id="$1"
  local out_plist="$2"
  local team_id="0000000000"
  cat > "$out_plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.application-identifier</key>
	<string>${team_id}.${bundle_id}</string>
	<key>keychain-access-groups</key>
	<array>
		<string>${team_id}.${bundle_id}.devicetrust</string>
		<string>${team_id}.${bundle_id}.secure-payment-confirmation</string>
		<string>${team_id}.${bundle_id}.unexportable-keys</string>
		<string>${team_id}.${bundle_id}.webauthn</string>
		<string>${team_id}.${bundle_id}.webauthn-uvk</string>
	</array>
	<key>com.apple.developer.associated-domains.applinks.read-write</key>
	<true/>
	<key>com.apple.developer.web-browser.public-key-credential</key>
	<true/>
	<key>com.apple.security.device.audio-input</key>
	<true/>
	<key>com.apple.security.device.bluetooth</key>
	<true/>
	<key>com.apple.security.device.camera</key>
	<true/>
	<key>com.apple.security.device.print</key>
	<true/>
	<key>com.apple.security.device.usb</key>
	<true/>
	<key>com.apple.security.personal-information.location</key>
	<true/>
	<key>com.apple.security.personal-information.photos-library</key>
	<true/>
</dict>
</plist>
EOF
}

AMFI_ALLOW_BIN="$(find_amfi_allow || true)"
if [[ -z "$AMFI_ALLOW_BIN" ]]; then
  AMFI_ALLOW_BIN="$(install_amfi_allow)"
fi

WORK_TMP="$(mktemp -d)"
trap 'rm -rf "$WORK_TMP"' EXIT

APP_BINARIES=()
IDX=0
for APP_PATH in "${APP_PATHS[@]}"; do
  if [[ ! -d "$APP_PATH" ]]; then
    echo "Error: App bundle not found at: $APP_PATH" >&2
    exit 1
  fi

  APP_EXEC_NAME="$(defaults read "${APP_PATH}/Contents/Info.plist" CFBundleExecutable 2>/dev/null || true)"
  if [[ -z "$APP_EXEC_NAME" ]]; then
    APP_EXEC_NAME="$(basename "$APP_PATH" .app)"
  fi
  APP_BINARY="${APP_PATH}/Contents/MacOS/${APP_EXEC_NAME}"

  if [[ ! -f "$APP_BINARY" ]]; then
    echo "Error: Executable not found at: $APP_BINARY" >&2
    exit 1
  fi

  BUNDLE_ID="$(defaults read "${APP_PATH}/Contents/Info.plist" CFBundleIdentifier 2>/dev/null || echo "org.chromium.Chromium")"
  APP_ENTITLEMENTS="${WORK_TMP}/entitlements_${IDX}.plist"
  write_app_entitlements "$BUNDLE_ID" "$APP_ENTITLEMENTS"
  IDX=$((IDX + 1))

  echo "==> Ad-hoc signing ${APP_PATH} (bundleId=${BUNDLE_ID}) ..."
  codesign --force --sign - \
    --entitlements "$APP_ENTITLEMENTS" \
    --preserve-metadata=identifier,requirements \
    "$APP_PATH"

  APP_BINARIES+=("$APP_BINARY")
done

echo "==> Registering ${#APP_BINARIES[@]} binary cdhash(es) with amfi-allow (requires sudo) ..."
sudo "$AMFI_ALLOW_BIN" allow "${APP_BINARIES[@]}"

echo "==> Done! Native Apple Passkeys entitlements are signed and allowed."
echo "    AMFI status: sudo \"$AMFI_ALLOW_BIN\" status"
