{ pkgs, lib, ... }:

let
  # Syntax-check the files passed as arguments with luac (Lua 5.1) and luajit.
  luaSyntaxHook = pkgs.writeShellScript "lua-syntax-hook" ''
    set -euo pipefail
    status=0
    for f in "$@"; do
      if ! ${pkgs.lua5_1}/bin/luac -p "$f"; then
        echo "luac syntax error: $f" >&2
        status=1
      fi
      if ! ${pkgs.luajit}/bin/luajit -bl "$f" >/dev/null; then
        echo "luajit syntax error: $f" >&2
        status=1
      fi
    done
    exit $status
  '';
in
{
  # KOReader runs on LuaJIT (Lua 5.1 semantics). We provide the reference
  # Lua 5.1 interpreter/compiler (luac) for syntax checks plus LuaJIT for
  # parity with the target runtime.
  languages.lua = {
    enable = true;
    package = pkgs.lua5_1;
  };

  packages = [
    pkgs.luajit
    # Lua 5.1 test/lint tooling. (KOReader itself is NOT added here; run the
    # emulator with `./tools/run-emulator.sh`, which uses `nix run nixpkgs#koreader`,
    # to keep this dev shell lightweight.)
    pkgs.lua51Packages.busted
    pkgs.lua51Packages.luacheck
  ];

  # Syntax-check every Lua file in the plugin using both luac (Lua 5.1) and
  # luajit's bytecode dumper. Either failing means a syntax error.
  scripts.syntax.exec = ''
    set -euo pipefail
    status=0
    for f in nextcloudnews.koplugin/*.lua; do
      if luac -p "$f" 2>/tmp/luac.err; then
        echo "OK (luac)    $f"
      else
        echo "FAIL (luac)  $f"; cat /tmp/luac.err; status=1
      fi
      if luajit -bl "$f" >/dev/null 2>/tmp/luajit.err; then
        echo "OK (luajit)  $f"
      else
        echo "FAIL (luajit) $f"; cat /tmp/luajit.err; status=1
      fi
    done
    exit $status
  '';

  # Static analysis (uses .luacheckrc to declare KOReader globals).
  scripts.lint.exec = ''
    set -euo pipefail
    luacheck nextcloudnews.koplugin spec
  '';

  # Headless unit tests (busted). These stub KOReader modules via package.preload
  # so the plugin's pure logic can be exercised without the KOReader runtime.
  scripts.test.exec = ''
    set -euo pipefail
    busted --verbose spec
  '';

  # Full gate: syntax + lint + tests.
  scripts.check.exec = ''
    set -euo pipefail
    syntax
    lint
    test
  '';

  # Alias so `devenv shell build` works too.
  scripts.build.exec = ''
    check
  '';

  # Git commit hooks (devenv's git-hooks integration). Installed into
  # .git/hooks on `devenv shell`; run automatically on `git commit`.
  git-hooks.hooks = {
    # Built-in luacheck hook (uses .luacheckrc).
    luacheck.enable = true;

    # Syntax-check staged Lua with luac (Lua 5.1) and luajit.
    lua-syntax = {
      enable = true;
      name = "lua-syntax (luac + luajit)";
      entry = "${luaSyntaxHook}";
      files = "\\.lua$";
      language = "system";
    };

    # Run the busted unit tests before allowing a commit.
    busted = {
      enable = true;
      name = "busted unit tests";
      entry = "${pkgs.lua51Packages.busted}/bin/busted spec";
      files = "\\.lua$";
      pass_filenames = false;
      language = "system";
    };
  };

  enterShell = ''
    echo "koreader-nextcloud-news dev shell"
    echo "  luajit:   $(luajit -v 2>&1 | head -n1)"
    echo "  lua:      $(lua -v 2>&1 | head -n1)"
    echo "  busted:   $(busted --version 2>&1 | head -n1)"
    echo "  luacheck: $(luacheck --version 2>&1 | head -n1)"
    echo ""
    echo "Commands: syntax | lint | test | check (all three) | build (= check)"
    echo "Emulator: ./tools/run-emulator.sh   (uses 'nix run nixpkgs#koreader')"
  '';
}
