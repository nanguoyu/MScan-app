#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
mode="${1:---local}"
case "$mode" in
    --topology|--development|--local) ;;
    *) echo "Usage: Scripts/build-app.sh [--local|--development|--topology]" >&2; exit 2 ;;
esac

output="$root/dist"
mkdir -p "$output"
staging="$(mktemp -d "$output/.build-app.XXXXXX")"
trap 'rm -rf "$staging"' EXIT

# A normal public build uses ad hoc signing. Apple development signing and
# topology observation require an explicitly configured developer account.
settings=("ONLY_ACTIVE_ARCH=NO" "ARCHS=arm64 x86_64"
          "GCC_GENERATE_DEBUGGING_SYMBOLS=NO" "DEBUG_INFORMATION_FORMAT=dwarf"
          "SWIFT_SERIALIZE_DEBUGGING_OPTIONS=NO")
if [[ "$mode" == "--local" ]]; then
    settings+=("CODE_SIGNING_ALLOWED=NO")
else
    : "${MSCAN_TEAM:?Set MSCAN_TEAM to the ID of your Apple Developer team.}"
    : "${MSCAN_BUNDLE_ID:?Set MSCAN_BUNDLE_ID to your registered app identifier.}"
    settings+=("DEVELOPMENT_TEAM=$MSCAN_TEAM" "PRODUCT_BUNDLE_IDENTIFIER=$MSCAN_BUNDLE_ID"
               "CODE_SIGN_IDENTITY=Apple Development")
    if [[ "$mode" == "--topology" ]]; then
        settings+=(-allowProvisioningUpdates "CODE_SIGN_STYLE=Automatic"
                   "CODE_SIGN_ENTITLEMENTS=Packaging/MScan.entitlements")
    else
        settings+=("CODE_SIGN_STYLE=Manual" "CODE_SIGN_ENTITLEMENTS=" "PROVISIONING_PROFILE_SPECIFIER=")
    fi
fi
derived="$root/.build/xcode${mode}"
xcodebuild -project "$root/MScan.xcodeproj" -scheme "MScan Mac" -configuration Release \
    -destination "platform=macOS" -derivedDataPath "$derived" "${settings[@]}" build
product="$derived/Build/Products/Release/MScan.app"
app="$staging/MScan.app"
/usr/bin/ditto "$product" "$app"
if [[ "$mode" == "--local" ]]; then
    /usr/bin/codesign --force --sign "-" --options runtime --timestamp=none "$app"
fi
/usr/bin/codesign --verify --strict --deep "$app"
if [[ "$mode" == "--topology" ]]; then
    test -s "$app/Contents/embedded.provisionprofile"
    /usr/bin/codesign -d --entitlements "$staging/signed-entitlements.plist" --xml "$app"
    /usr/bin/security cms -D -i "$app/Contents/embedded.provisionprofile" -o "$staging/authorizations.plist"
    authorized=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.networking.topology-observation' "$staging/authorizations.plist")
    [[ "$authorized" == true ]] || { echo "Profile does not authorize topology observation" >&2; exit 1; }
    enabled=$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.networking.topology-observation' "$staging/signed-entitlements.plist")
    [[ "$enabled" == true ]] || { echo "Missing signed topology entitlement" >&2; exit 1; }
fi
test -s "$app/Contents/Resources/MScan.icns"
if [[ -e "$output/MScan.app" ]]; then mv "$output/MScan.app" "$staging/previous.app"; fi
if ! mv "$app" "$output/MScan.app"; then
    if [[ -e "$staging/previous.app" ]]; then mv "$staging/previous.app" "$output/MScan.app"; fi
    exit 1
fi
echo "$output/MScan.app"
