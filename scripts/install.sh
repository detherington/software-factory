#!/bin/zsh
# Builds Software Factory (Release) and installs it in ~/Applications, with the factory command
# linked into ~/.local/bin. Stops a running copy first; the board is saved on the way out.
# Usage: scripts/install.sh
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate --quiet

# Signed with the team in project.yml, so the app can send the board to the iPhone through iCloud.
# Xcode makes or renews the profile with the account in Xcode › Settings › Accounts; without one it
# uses the profile it has. A Mac that can't sign with the team gets a copy signed locally, which
# works the same but doesn't send the board to the iPhone. Why signing failed goes in build/signing.log.
build() {
  xcodebuild -project SoftwareFactory.xcodeproj -scheme SoftwareFactory -configuration Release \
    -derivedDataPath build/DerivedData -destination 'platform=macOS' "$@" build -quiet
}
mkdir -p build
if ! build -allowProvisioningUpdates >build/signing.log 2>&1 && ! build >>build/signing.log 2>&1; then
  echo "Couldn't sign with the team (build/signing.log has why), so this copy won't send the board to the iPhone."
  build CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_ENTITLEMENTS=
fi

built="build/DerivedData/Build/Products/Release/Software Factory.app"
app="$HOME/Applications/Software Factory.app"

# -a: when the app's own updater runs this, the app is one of this script's ancestors, which
# pkill and pgrep otherwise skip.
if pkill -TERM -a -x "Software Factory"; then
  for _ in {1..20}; do pgrep -a -x "Software Factory" >/dev/null || break; sleep 0.25; done
fi

mkdir -p "$HOME/Applications" "$HOME/.local/bin"
rm -rf "$app"
ditto "$built" "$app"
ln -sf "$app/Contents/MacOS/factory" "$HOME/.local/bin/factory"
open "$app"

echo "Installed $app"
echo "Linked ~/.local/bin/factory"
echo "Hooks for Claude Code: Settings › Claude Code › Install, or: factory install-hooks"
