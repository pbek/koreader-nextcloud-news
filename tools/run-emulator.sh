#!/usr/bin/env bash
#
# Launch the KOReader desktop emulator (Linux/SDL) with this plugin loaded,
# using `nix run nixpkgs#koreader` so KOReader is NOT a dev-shell dependency.
#
# How it works:
#   - KOReader honours $KO_HOME for its (writable) data directory. We point it
#     at a scratch dir under .devenv/ since the Nix store is read-only.
#   - KOReader's pluginloader automatically treats <data_dir>/plugins/ as an
#     extra plugin path, so we symlink our plugin there.
#   - The nixpkgs koreader package bundles newsdownloader.koplugin, which this
#     plugin soft-depends on for the EPUB backend.
#
# Usage:
#   tools/run-emulator.sh [extra koreader args...]
#
# Requirements: a graphical session (X11/Wayland) and `nix` with flakes.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
plugin_src="$repo_root/nextcloudnews.koplugin"

if [[ ! -d "$plugin_src" ]]; then
  echo "error: plugin directory not found: $plugin_src" >&2
  exit 1
fi

ko_home="${KO_HOME:-$repo_root/.devenv/koreader-home}"
mkdir -p "$ko_home/plugins" "$ko_home/settings"

# (Re)create the symlink to the plugin under the emulator's extra plugin path.
link="$ko_home/plugins/nextcloudnews.koplugin"
rm -f "$link"
ln -s "$plugin_src" "$link"

# If present, use the repo-local ignored settings file for emulator runs. This
# avoids typing long app passwords into the emulator while keeping secrets out of
# tracked files.
repo_settings="$repo_root/settings/nextcloud_news.lua"
emu_settings="$ko_home/settings/nextcloud_news.lua"
if [[ -f "$repo_settings" ]]; then
  lua_settings_path="${repo_settings//\\/\\\\}"
  lua_settings_path="${lua_settings_path//\"/\\\"}"
  printf 'return dofile("%s")\n' "$lua_settings_path" >"$emu_settings"
fi

echo "KOReader emulator:"
echo "  KO_HOME      = $ko_home"
echo "  plugin link  = $link -> $plugin_src"
if [[ -f "$repo_settings" ]]; then
  echo "  settings     = $emu_settings -> $repo_settings"
fi
echo "  starting via 'nix run nixpkgs#koreader' ..."
echo

# Pass a starting directory (the repo) so the file manager opens somewhere useful.
KO_HOME="$ko_home" exec nix run nixpkgs#koreader -- "$@" "$repo_root"
