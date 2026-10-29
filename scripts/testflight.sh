#!/bin/zsh
# Builds the iPhone app (Factory) for release and uploads it to App Store Connect for TestFlight's
# internal testing (Config/ExportOptions-TestFlight.plist). Its widgets go with it.
#   scripts/testflight.sh                  (builds and uploads)
#   scripts/testflight.sh --archive-only   (builds and signs, uploads nothing)
# It signs and uploads with the App Store Connect API key when ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH
# are set (in ~/.zshrc, as for Emanata), and with the account in Xcode › Settings › Accounts otherwise.
# The key can only make profiles once Xcode has linked the iCloud container and app group to the app
# IDs, which building the SoftwareFactoryPhone scheme in Xcode once does (README › iPhone). Each upload
# is numbered by when it was made: 0.1.0 (20261029.590) is October 29, 2026, 590 minutes into the day.
set -euo pipefail
cd "${0:A:h}/.."

auth=()
if [[ -n ${ASC_KEY_ID:-} && -n ${ASC_ISSUER_ID:-} && -r ${ASC_KEY_PATH:-} ]]; then
  auth=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi
upload=1
for arg in $@; do
  case $arg in
    --archive-only) upload=0 ;;
    *) print -u2 "Usage: scripts/testflight.sh [--archive-only]"; exit 2 ;;
  esac
done

read day hour minute <<< "$(date '+%Y%m%d %H %M')"
build="$day.$(( 10#$hour * 60 + 10#$minute ))"
version=$(sed -nE 's/^ *MARKETING_VERSION: *"?([^"]*)"?$/\1/p' project.yml | head -1)
out="build/TestFlight/$build"
mkdir -p $out
if [[ -n $(git status --porcelain) ]]; then
  print "The folder has uncommitted changes, and they're in this build."
fi
xcodegen generate --quiet

# Runs xcodebuild with its output in a log ($1), showing the errors if it fails.
run() {
  local log=$1
  shift
  if ! xcodebuild "$@" > $log 2>&1; then
    grep -E '(error|Error):' $log | grep -v 'failed with exit code 0' | head -20 >&2
    print -u2 "That failed. The whole log is $log."
    exit 1
  fi
}

print "Building Factory $version ($build) for iPhone…"
run "$out/build.log" archive -project SoftwareFactory.xcodeproj -scheme SoftwareFactoryPhone -configuration Release \
  -destination "generic/platform=iOS" -archivePath "$out/Factory.xcarchive" CURRENT_PROJECT_VERSION=$build \
  -allowProvisioningUpdates "${auth[@]}"
if (( ! upload )); then
  print "Archived Factory $version ($build) in $out. Nothing was uploaded."
  exit 0
fi
print "Uploading it…"
run "$out/upload.log" -exportArchive -archivePath "$out/Factory.xcarchive" -exportPath "$out/export" \
  -exportOptionsPlist Config/ExportOptions-TestFlight.plist -allowProvisioningUpdates "${auth[@]}"
print "Uploaded Factory $version ($build). It shows in TestFlight once App Store Connect has processed it, usually within 10–30 minutes."
