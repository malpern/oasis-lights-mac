#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
remote="${OASIS_BRIDGE_REMOTE:-mini}"
source_app="$project_root/Build/Applications/Oasis Bridge.app"
source_plist="$project_root/Scripts/com.malpern.oasis-bridge.plist"

if [[ ! -d "$source_app" ]]; then
  "$project_root/Scripts/build-apps.sh"
fi
codesign --verify --deep --strict "$source_app"

stage=$(mktemp -d /tmp/oasis-bridge-deploy.XXXXXX)
ditto -c -k --keepParent "$source_app" "$stage/Oasis-Bridge.zip"
cp "$source_plist" "$stage/com.malpern.oasis-bridge.plist"
scp -q "$stage/Oasis-Bridge.zip" "$stage/com.malpern.oasis-bridge.plist" "$remote:/tmp/"

ssh -o BatchMode=yes "$remote" 'zsh -s' <<'OASIS_REMOTE'
set -euo pipefail
if [[ "$(id -un)" != "clawd" ]]; then
  echo "Refusing to deploy Oasis Bridge outside the clawd account" >&2
  exit 1
fi
uid_value=$(id -u)
stamp=$(date +%Y%m%d-%H%M%S)
stage=$(mktemp -d /tmp/oasis-bridge.XXXXXX)
ditto -x -k /tmp/Oasis-Bridge.zip "$stage"
codesign --verify --deep --strict "$stage/Oasis Bridge.app"
current_app="$HOME/Applications/Oasis Bridge.app"
agent_plist="$HOME/Library/LaunchAgents/com.malpern.oasis-bridge.plist"
backup_dir="$HOME/Applications/.Oasis Backups"
mkdir -p "$backup_dir"
launchctl bootout "gui/$uid_value/com.malpern.oasis-bridge" 2>/dev/null || true
if [[ -d "$current_app" ]]; then
  mv "$current_app" "$backup_dir/Oasis Bridge-$stamp.app"
fi
if [[ -f "$agent_plist" ]]; then
  cp "$agent_plist" "$backup_dir/com.malpern.oasis-bridge-$stamp.plist"
fi
mv "$stage/Oasis Bridge.app" "$current_app"
cp /tmp/com.malpern.oasis-bridge.plist "$agent_plist"
bridge_executable="$current_app/Contents/MacOS/OasisBridge"
# The controller often runs in a different account than the bridge, and a home
# directory is not readable across accounts, so a log under $HOME cannot be
# opened by the app that offers to show it. Keep it where both can reach it.
bridge_log_directory="/Users/Shared/OasisBridge"
bridge_log="$bridge_log_directory/OasisBridge.log"
mkdir -p "$bridge_log_directory"
chmod 755 "$bridge_log_directory"
legacy_log="$HOME/Library/Logs/OasisBridge.log"
if [[ -f "$legacy_log" && ! -f "$bridge_log" ]]; then
  mv "$legacy_log" "$bridge_log"
fi
touch "$bridge_log"
chmod 644 "$bridge_log"
/usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 $bridge_executable" "$agent_plist"
/usr/libexec/PlistBuddy -c "Set :StandardOutPath $bridge_log" "$agent_plist"
/usr/libexec/PlistBuddy -c "Set :StandardErrorPath $bridge_log" "$agent_plist"
launchctl bootstrap "gui/$uid_value" "$agent_plist"
launchctl kickstart "gui/$uid_value/com.malpern.oasis-bridge"
launchctl print "gui/$uid_value/com.malpern.oasis-bridge" | grep -m1 'state = running'
OASIS_REMOTE

echo "Bridge deployed only to $remote under clawd. Bluetooth authorization may be required after the first stable-signature migration."
