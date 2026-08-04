#!/bin/zsh
set -euo pipefail

project_root="${0:A:h:h}"
source_app="$project_root/Build/Applications/Oasis Lights.app"

if [[ ! -d "$source_app" ]]; then
  "$project_root/Scripts/build-apps.sh"
fi
codesign --verify --deep --strict "$source_app"

install_local() {
  local destination="$HOME/Applications/Oasis Lights.app"
  local backup_dir="$HOME/Applications/.Oasis Backups"
  local stamp
  stamp=$(date +%Y%m%d-%H%M%S)
  mkdir -p "$backup_dir"
  pkill -f "^$destination/Contents/MacOS/OasisController$" 2>/dev/null || true
  if [[ -d "$destination" ]]; then
    mv "$destination" "$backup_dir/Oasis Lights-$stamp.app"
  fi
  ditto "$source_app" "$destination"
  codesign --verify --deep --strict "$destination"
  echo "$destination"
}

install_remote() {
  local remote=$1
  local archive_dir archive
  archive_dir=$(mktemp -d /tmp/oasis-controller-install.XXXXXX)
  archive="$archive_dir/Oasis-Lights.zip"
  ditto -c -k --keepParent "$source_app" "$archive"
  scp -q "$archive" "$remote:/tmp/Oasis-Lights-controller.zip"
  ssh -o BatchMode=yes "$remote" 'zsh -s' <<'OASIS_REMOTE'
set -euo pipefail
stage=$(mktemp -d /tmp/oasis-controller.XXXXXX)
ditto -x -k /tmp/Oasis-Lights-controller.zip "$stage"
codesign --verify --deep --strict "$stage/Oasis Lights.app"
destination="$HOME/Applications/Oasis Lights.app"
backup_dir="$HOME/Applications/.Oasis Backups"
stamp=$(date +%Y%m%d-%H%M%S)
mkdir -p "$backup_dir"
pkill -f "^$destination/Contents/MacOS/OasisController$" 2>/dev/null || true
if [[ -d "$destination" ]]; then
  mv "$destination" "$backup_dir/Oasis Lights-$stamp.app"
fi
mv "$stage/Oasis Lights.app" "$destination"
codesign --verify --deep --strict "$destination"
echo "$destination"
OASIS_REMOTE
}

case "${1:---local}" in
  --local) install_local ;;
  --remote)
    [[ $# -eq 2 ]] || { echo "Usage: $0 --remote user@host" >&2; exit 2; }
    install_remote "$2"
    ;;
  *) echo "Usage: $0 [--local | --remote user@host]" >&2; exit 2 ;;
esac
