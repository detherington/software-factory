#!/bin/zsh
# Builds Software Factory (Release) and installs it in ~/Applications, with the factory command
# linked into ~/.local/bin. Stops a running copy first; the board is saved on the way out.
# Usage: scripts/install.sh
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate --quiet
xcodebuild -project SoftwareFactory.xcodeproj -scheme SoftwareFactory -configuration Release \
  -derivedDataPath build/DerivedData -destination 'platform=macOS' build -quiet

built="build/DerivedData/Build/Products/Release/Software Factory.app"
app="$HOME/Applications/Software Factory.app"

if pkill -TERM -x "Software Factory"; then
  for _ in {1..20}; do pgrep -x "Software Factory" >/dev/null || break; sleep 0.25; done
fi

mkdir -p "$HOME/Applications" "$HOME/.local/bin"
rm -rf "$app"
ditto "$built" "$app"
ln -sf "$app/Contents/MacOS/factory" "$HOME/.local/bin/factory"
open "$app"

echo "Installed $app"
echo "Linked ~/.local/bin/factory"
echo "Hooks for Claude Code: Settings › Claude Code › Install, or: factory install-hooks"
