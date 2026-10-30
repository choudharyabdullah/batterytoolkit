#!/bin/zsh
#
# Builds Battery Toolkit with only the Command Line Tools installed.
#
# Storyboards and asset catalogs need Xcode to compile, so this script reuses
# the compiled resources of the official 1.8 release bundle (the UI sources
# have not changed since) and replaces its four executables with freshly
# compiled ones. The result is signed with a self-signed certificate that the
# daemon trusts via BT_CODESIGN_CERT_SHA1.
#
# Environment:
#   BT_BASE_APP   Path to an official "Battery Toolkit.app" (1.8). Downloaded
#                 from GitHub if unset.
#   BT_SIGN_DIR   Directory holding cert.pem/key.pem and the keychain password.
#                 Created with a fresh self-signed identity if missing.
#                 Default: ~/.batterytoolkit-signing
#   BT_OUT        Output directory. Default: <repo>/build/no-xcode
#
set -euo pipefail

REPO="${0:A:h:h}"
OUT="${BT_OUT:-$REPO/build/no-xcode}"
SIGN_DIR="${BT_SIGN_DIR:-$HOME/.batterytoolkit-signing}"
KEYCHAIN="$HOME/Library/Keychains/batterytoolkit-signing.keychain-db"
IDENTITY="Battery Toolkit Local Signing"
TARGET="arm64-apple-macos13.0"
SDK="$(xcrun --show-sdk-path)"
PBXPROJ="$REPO/Battery Toolkit.xcodeproj/project.pbxproj"
VERSION="$(grep -m1 'MARKETING_VERSION = ' "$PBXPROJ" | sed 's/.*= //; s/;//')"
CN="$(grep -m1 'BT_CODESIGN_CN = ' "$PBXPROJ" | sed 's/.*= "//; s/";$//')"
APP="$OUT/Battery Toolkit.app"

#
# Signing identity.
#
if [[ ! -f "$SIGN_DIR/cert.pem" ]]; then
    echo "== creating self-signed signing identity in $SIGN_DIR"
    mkdir -p "$SIGN_DIR"; chmod 700 "$SIGN_DIR"
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "$SIGN_DIR/key.pem" -out "$SIGN_DIR/cert.pem" \
        -subj "/CN=$IDENTITY" \
        -addext "keyUsage=critical,digitalSignature" \
        -addext "extendedKeyUsage=critical,codeSigning" \
        -addext "basicConstraints=critical,CA:false" 2>/dev/null
    openssl rand -hex 16 > "$SIGN_DIR/keychain-password"
    chmod 600 "$SIGN_DIR/key.pem" "$SIGN_DIR/keychain-password"
    openssl pkcs12 -export -out "$SIGN_DIR/identity.p12" -inkey "$SIGN_DIR/key.pem" \
        -in "$SIGN_DIR/cert.pem" -passout pass:p12pass 2>/dev/null
fi
KEYCHAIN_PASSWORD="$(cat "$SIGN_DIR/keychain-password")"
if [[ ! -f "$KEYCHAIN" ]]; then
    security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
    security set-keychain-settings "$KEYCHAIN"
    security import "$SIGN_DIR/identity.p12" -k "$KEYCHAIN" -P p12pass \
        -T /usr/bin/codesign -T /usr/bin/security -A >/dev/null
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
        -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
    security list-keychains -d user -s $(security list-keychains -d user | tr -d '"') "$KEYCHAIN"
fi
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
PIN="$(openssl x509 -in "$SIGN_DIR/cert.pem" -noout -fingerprint -sha1 | sed 's/.*=//; s/://g' | tr 'A-F' 'a-f')"

#
# Base bundle with compiled resources.
#
BASE="${BT_BASE_APP:-}"
if [[ -z "$BASE" ]]; then
    BASE_DIR="$OUT/base"
    BASE="$BASE_DIR/Battery Toolkit.app"
    if [[ ! -d "$BASE" ]]; then
        echo "== downloading official 1.8 release for its compiled resources"
        mkdir -p "$BASE_DIR"
        curl -fsSL -o "$BASE_DIR/Battery-Toolkit-1.8.zip" \
            "https://github.com/mhaeuser/Battery-Toolkit/releases/download/1.8/Battery-Toolkit-1.8.zip"
        ditto -x -k "$BASE_DIR/Battery-Toolkit-1.8.zip" "$BASE_DIR"
    fi
fi
codesign --verify --deep --strict "$BASE"

#
# Compile.
#
rm -rf "$OUT/obj" "$OUT/bin" "$OUT/log" "$APP"
mkdir -p "$OUT/obj" "$OUT/bin" "$OUT/log" "$OUT/mcache"
cd "$REPO"

DEFS=(
    -DBT_APP_ID_='"me.mhaeuser.BatteryToolkit"'
    -DBT_SERVICE_ID_='"me.mhaeuser.BatteryToolkitService"'
    -DBT_DAEMON_ID_='"me.mhaeuser.batterytoolkitd"'
    -DBT_DAEMON_CONN_='"EMH49F8A2Y.me.mhaeuser.batterytoolkitd"'
    -DBT_AUTOSTART_ID_='"me.mhaeuser.BatteryToolkitAutostart"'
    "-DBT_CODESIGN_CN_=\"$CN\""
    "-DBT_CODESIGN_CERT_SHA1_=\"$PIN\""
)
CFLAGS=(-c -O2 -target "$TARGET" -isysroot "$SDK")
echo "== compiling C/Objective-C modules"
clang "${CFLAGS[@]}" -fobjc-arc -I Modules/BTPreprocessor "${DEFS[@]}" \
    Modules/BTPreprocessor/BTPreprocessor.m -o "$OUT/obj/BTPreprocessor.o"
clang "${CFLAGS[@]}" -I Modules/SecCodeEx Modules/SecCodeEx/SecCodeEx.c -o "$OUT/obj/SecCodeEx.o"
clang "${CFLAGS[@]}" -I Modules/MachTaskSelf Modules/MachTaskSelf/MachTaskSelf.c -o "$OUT/obj/MachTaskSelf.o"

SWIFT=(xcrun swiftc -O -wmo -parse-as-library -swift-version 6 -strict-concurrency=complete
    -target "$TARGET" -sdk "$SDK" -module-cache-path "$OUT/mcache"
    -I Modules -I Modules/BTPreprocessor -I Modules/SecCodeEx -I Modules/MachTaskSelf
    -I Modules/IOPMPrivate -I Modules/SMCParamStruct -I "Modules/NSXPCConnection+AuditToken")

build() {
    local name="$1"; shift
    echo "== compiling $name"
    if ! "${SWIFT[@]}" "$@" >"$OUT/log/$name.txt" 2>&1; then
        grep -E 'error:' "$OUT/log/$name.txt" | head -30
        echo "FAILED: $name (see $OUT/log/$name.txt)"
        exit 1
    fi
}

sed -e 's|\$(PRODUCT_BUNDLE_IDENTIFIER)|me.mhaeuser.batterytoolkitd|' \
    -e 's|\$(BT_APP_ID)|me.mhaeuser.BatteryToolkit|' \
    -e "s|\\\$(BT_CODESIGN_CN)|$CN|" \
    me.mhaeuser.batterytoolkitd/Info.plist > "$OUT/obj/daemon-Info.plist"
build daemon -module-name me_mhaeuser_batterytoolkitd \
    Common/BTDaemonCommProtocol.swift Common/BTError.swift Common/BTStateInfo.swift \
    Common/BTXPCValidation.swift Common/BTLegacyHelperInfo.swift Common/BTSettingsInfo.swift \
    Common/BTAuthorizationRights.swift Libraries/PowerEvents.swift Libraries/GlobalSleep.swift \
    Libraries/SimpleAuth.swift Libraries/SMCComm+MagSafe.swift Libraries/SMCComm+Power.swift \
    Libraries/IOPSPrivate.swift Libraries/CSIdentification.swift Libraries/SMCComm.swift \
    me.mhaeuser.batterytoolkitd/*.swift \
    "$OUT/obj/BTPreprocessor.o" "$OUT/obj/SecCodeEx.o" "$OUT/obj/MachTaskSelf.o" \
    -framework CoreFoundation -framework Foundation -framework Security -framework IOKit \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$OUT/obj/daemon-Info.plist" \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __launchd_plist \
    -Xlinker "$REPO/me.mhaeuser.batterytoolkitd/launchd.plist" \
    -o "$OUT/bin/me.mhaeuser.batterytoolkitd"

build app -module-name Battery_Toolkit \
    BatteryToolkit/**/*.swift \
    Common/BTDaemonCommProtocol.swift Common/BTError.swift Common/BTSettingsInfo.swift \
    Common/BTAuthorizationRights.swift Common/BTXPCValidation.swift Common/BTLegacyHelperInfo.swift \
    Common/BTStateInfo.swift Libraries/CSIdentification.swift Libraries/SimpleAuth.swift \
    BatteryToolkitService/BTServiceCommProtocol.swift \
    "$OUT/obj/BTPreprocessor.o" "$OUT/obj/SecCodeEx.o" \
    -framework Cocoa -framework ServiceManagement -framework Foundation \
    -o "$OUT/bin/Battery Toolkit"

build service -module-name Battery_Toolkit_Service \
    BatteryToolkitService/*.swift Common/BTXPCValidation.swift Libraries/SimpleAuth.swift \
    Common/BTAuthorizationRights.swift \
    "$OUT/obj/BTPreprocessor.o" "$OUT/obj/SecCodeEx.o" -framework Foundation \
    -o "$OUT/bin/Battery Toolkit Service"

build autostart -module-name AutostartHelper AutostartHelper/AutostartHelper.swift \
    -framework Cocoa -o "$OUT/bin/AutostartHelper"

#
# Assemble and sign.
#
echo "== assembling bundle"
ditto "$BASE" "$APP"
HELPER="$APP/Contents/Library/LoginItems/AutostartHelper.app"
SERVICE="$APP/Contents/XPCServices/Battery Toolkit Service.xpc"
DAEMON="$APP/Contents/Library/LaunchServices/me.mhaeuser.batterytoolkitd"
rm -rf "$APP/Contents/_CodeSignature" "$APP/Contents/Frameworks" \
    "$HELPER/Contents/_CodeSignature" "$HELPER/Contents/Frameworks" "$SERVICE/Contents/_CodeSignature"
cp "$OUT/bin/Battery Toolkit" "$APP/Contents/MacOS/Battery Toolkit"
cp "$OUT/bin/me.mhaeuser.batterytoolkitd" "$DAEMON"
cp "$OUT/bin/Battery Toolkit Service" "$SERVICE/Contents/MacOS/Battery Toolkit Service"
cp "$OUT/bin/AutostartHelper" "$HELPER/Contents/MacOS/AutostartHelper"
for plist in "$APP/Contents/Info.plist" "$HELPER/Contents/Info.plist" "$SERVICE/Contents/Info.plist"; do
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" \
        -c "Set :CFBundleVersion $VERSION" "$plist"
    /usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion 13.0" "$plist" 2>/dev/null || true
done

echo "== signing"
SIGN=(codesign --force --timestamp=none --keychain "$KEYCHAIN" -s "$IDENTITY"
    -o hard,kill,restrict,enforcement,library-validation,runtime)
"${SIGN[@]}" --entitlements "$REPO/AutostartHelper/AutostartHelper.entitlements" "$HELPER"
"${SIGN[@]}" "$SERVICE"
"${SIGN[@]}" "$DAEMON"
"${SIGN[@]}" "$APP"

echo "== verifying"
codesign --verify --deep --strict "$APP"
ENTITLEMENTS='!(entitlement["com.apple.security.cs.allow-dyld-environment-variables"] /* exists */) and !(entitlement["com.apple.security.cs.disable-library-validation"] /* exists */) and !(entitlement["com.apple.security.cs.allow-unsigned-executable-memory"] /* exists */) and !(entitlement["com.apple.security.cs.allow-jit"] /* exists */) and !(entitlement["com.apple.security.get-task-allow"] /* exists */)'
for pair in "me.mhaeuser.BatteryToolkit|$APP" "me.mhaeuser.batterytoolkitd|$DAEMON" \
    "me.mhaeuser.BatteryToolkitService|$SERVICE" "me.mhaeuser.BatteryToolkitAutostart|$HELPER"; do
    codesign -v -R="identifier \"${pair%%|*}\" and certificate leaf = H\"$PIN\" and $ENTITLEMENTS" "${pair#*|}"
done
echo "OK: $APP"
