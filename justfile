# koreader-nextcloud-news — task runner
#
# Most recipes assume the devenv dev shell is active (so luac/luajit/busted/
# luacheck are on PATH). Run `devenv shell` first, or prefix with
# `devenv shell -- just <recipe>`.

import ".shared/common.just"

plugin_dir := "nextcloudnews.koplugin"

# List available recipes.
default:
    @just --list

# Syntax-check every plugin Lua file with luac (Lua 5.1) and luajit.
syntax:
    #!/usr/bin/env bash
    set -euo pipefail
    status=0
    for f in {{ plugin_dir }}/*.lua; do
        if luac -p "$f" 2>/tmp/luac.err; then echo "OK (luac)    $f";
        else echo "FAIL (luac)  $f"; cat /tmp/luac.err; status=1; fi
        if luajit -bl "$f" >/dev/null 2>/tmp/luajit.err; then echo "OK (luajit)  $f";
        else echo "FAIL (luajit) $f"; cat /tmp/luajit.err; status=1; fi
    done
    exit $status

# Static analysis with luacheck (uses .luacheckrc).
lint:
    luacheck {{ plugin_dir }} spec

# Headless unit tests with busted.
test:
    busted --verbose spec

# Full gate: syntax + lint + tests.
check: syntax lint test

# Alias for check.
build: check

# Launch the KOReader emulator with this plugin loaded (Linux/SDL).
# Uses `nix run nixpkgs#koreader`; does not add KOReader to the dev shell.
emu *ARGS:
    ./tools/run-emulator.sh {{ ARGS }}

# Remove the emulator scratch home and other generated artifacts.
clean:
    rm -rf .devenv/koreader-home
