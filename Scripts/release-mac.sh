#!/bin/zsh
# The Mac app (the iPad app through Mac Catalyst) as a signed, notarized DMG on this
# repo's GitHub Releases. It never goes to App Store Connect: the archive is exported
# with Developer ID. It shares the iPhone app's ID for pushes, so never upload it.
# Usage: Scripts/release-mac.sh [--notes-file notes.md] [--draft] [--no-publish]
# Needs Config/Local.xcconfig (the team), a "Developer ID Application" certificate in the
# keychain, the asc CLI signed in (it notarizes) and gh signed in (it publishes).
set -euo pipefail
repo=${0:A:h:h}
out=${BIGHELP_MAC_RELEASE_DIR:-/tmp/bighelp-mac-release}
derived=${BIGHELP_MAC_RELEASE_DERIVED:-/tmp/bighelp-mac-release-dd}
publish=1 draft=() notes=()
while (( $# )); do
  case $1 in
    --no-publish) publish=0 ;;
    --draft) draft=(--draft) ;;
    --notes-file) notes=(--notes-file "${2:A}"); shift ;;
    *) print -u2 "Unknown option: $1"; exit 2 ;;
  esac
  shift
done

version=$(awk '/MARKETING_VERSION:/ { print $2; exit }' "$repo/project.yml")
build=$(awk '/CURRENT_PROJECT_VERSION:/ { print $2; exit }' "$repo/project.yml")
team=$(awk -F' *= *' '/^DEVELOPMENT_TEAM/ { print $2 }' "$repo/Config/Local.xcconfig")
identity=$(security find-identity -v -p codesigning | awk -v team="($team)" '/Developer ID Application/ && index($0, team) { print $2; exit }')
[[ -n $team && -n $identity ]] || { print -u2 "Needs DEVELOPMENT_TEAM in Config/Local.xcconfig and its Developer ID Application certificate."; exit 1; }
dmg=$out/bighelp-$version-$build-mac.dmg
tag=mac-v$version-$build

rm -rf "$out"
mkdir -p "$out/dmg"
xcodebuild archive -project "$repo/Bighelp.xcodeproj" -scheme BighelpCatalyst -configuration Release \
  -destination 'generic/platform=macOS,variant=Mac Catalyst' -archivePath "$out/bighelp.xcarchive" \
  -derivedDataPath "$derived" -allowProvisioningUpdates -quiet
cat > "$out/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$team</string>
  <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "$out/bighelp.xcarchive" -exportPath "$out/export" \
  -exportOptionsPlist "$out/ExportOptions.plist" -allowProvisioningUpdates -quiet
app=$out/export/bighelp.app
codesign --verify --deep --strict "$app"

# Drag-to-Applications disk image, signed itself so Gatekeeper checks the download too.
# Stapling fails unless Apple accepted the notarization.
ditto "$app" "$out/dmg/bighelp.app"
ln -s /Applications "$out/dmg/Applications"
hdiutil create -volname bighelp -srcfolder "$out/dmg" -format UDZO -ov "$dmg" -quiet
codesign --sign "$identity" --timestamp "$dmg"
asc notarization submit --file "$dmg" --wait --output table
xcrun stapler staple "$dmg"
spctl --assess --type open --context context:primary-signature --verbose "$dmg"
print "Built $dmg"

(( publish )) || exit 0
(( ${#notes} )) || notes=(--notes "bighelp for Mac $version ($build). Open the disk image and drag bighelp to Applications.")
# The release goes to this checkout's GitHub repo, tagged at the commit that was built.
cd "$repo"
gh release create "$tag" "$dmg" --target "$(git rev-parse HEAD)" \
  --title "bighelp for Mac $version ($build)" "${notes[@]}" "${draft[@]}"
