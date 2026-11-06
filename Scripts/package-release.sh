#!/bin/bash
# Produce the same archive name consumed by the in-app update checker.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
"$root/Scripts/build-app.sh" --local
dist="$root/dist"
app="$dist/MScan.app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Expected a three-part release version." >&2; exit 1; }
binary="$app/Contents/MacOS/MScan"
architectures="$(/usr/bin/lipo -archs "$binary")"
for required in arm64 x86_64; do
    [[ " $architectures " == *" $required "* ]] || { echo "Missing $required in $binary" >&2; exit 1; }
done
[[ ! -e "$app/Contents/embedded.provisionprofile" ]] || { echo "Archive contains a provisioning profile." >&2; exit 1; }
/usr/bin/codesign --verify --strict --deep "$app"
signature="$(/usr/bin/codesign --display --verbose=4 "$app" 2>&1)"
[[ "$signature" == *Signature=adhoc* ]] || { echo "This public archive requires ad-hoc signing." >&2; exit 1; }
file="MScan-$version-macOS-universal.zip"
work="$(mktemp -d "$dist/.release.XXXXXX")"
trap 'rm -rf "$work"' EXIT
(cd "$dist"; /usr/bin/zip -q -X -y -r "$work/$file" MScan.app -x '*/.DS_Store' '*/._*')
(cd "$work"; /usr/bin/shasum -a 256 "$file" > "$file.sha256")
mv "$work/$file" "$work/$file.sha256" "$dist/"
printf '%s\n' "$dist/$file" "$dist/$file.sha256"
