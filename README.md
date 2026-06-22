# koreader-nextcloud-news

A [KOReader](https://github.com/koreader/koreader) plugin that synchronizes
RSS/Atom articles from a [Nextcloud News](https://github.com/nextcloud/news)
server and saves them as EPUB files, with **two-way read/starred state sync**.

Device-agnostic (works on PocketBook, Kobo, Kindle, Android); PocketBook is the
primary target.

> **Status:** early development. The M0/M1 skeleton (settings, menu, API client,
> connection test) is in place. Download/render and status sync are upcoming.
> See [`PROJECT_PLAN.md`](PROJECT_PLAN.md) for the roadmap.

## Naming

|                      |                           |
| -------------------- | ------------------------- |
| Repository / project | `koreader-nextcloud-news` |
| Plugin folder        | `nextcloudnews.koplugin`  |
| Plugin id (`name`)   | `nextcloud_news`          |
| Display name         | Nextcloud News            |

## Install (development)

KOReader loads plugins from its `plugins/` directory. Symlink or copy the
plugin folder there:

```sh
ln -s "$(pwd)/nextcloudnews.koplugin" /path/to/koreader/plugins/nextcloudnews.koplugin
```

For on-device use, copy `nextcloudnews.koplugin/` into the `koreader/plugins/`
directory on the device.

## Configuration

1. In KOReader: **Tools → Nextcloud News → Configure server**.
2. Enter:
   - **Server URL** — your Nextcloud base URL, e.g. `https://cloud.example.com`
     (the `/index.php/apps/news/api/v1-3/` path is appended automatically; a
     full API URL is also accepted).
   - **Username** — your Nextcloud username.
   - **App password** — create one under Nextcloud **Settings → Security →
     Devices & sessions**. Do **not** use your main account password.
3. Use **Test connection** to verify. HTTPS is strongly recommended, since
   HTTP Basic auth sends credentials on every request.

### Usage

- **Synchronize** (Tools → Nextcloud News → Synchronize, or a bound gesture):
  uploads reading statuses, then downloads new/updated articles as EPUBs.
- **Sync from** (Tools → Nextcloud News → _Sync from: …_): choose whether to
  download **all articles**, a single **folder**, or a single **feed**. The
  current selection is shown in the menu; changing it re-fetches that scope on
  the next sync.
- Reading an article to the end marks it **read** on the server on the next
  sync (toggle in settings).
- While reading an article, **Star/Unstar current article** (in the menu, or
  the _Nextcloud News: toggle star_ gesture action) flags it; the change is
  queued and pushed on the next sync.

## Layout

```
nextcloudnews.koplugin/
  _meta.lua     -- plugin metadata (name, fullname, description)
  main.lua      -- plugin entry: menu, settings, sync, star toggle
  newsapi.lua   -- Nextcloud News REST API v1.3 client
  epub.lua      -- renders an item's HTML body to an EPUB
```

## Building / Development

A [devenv](https://devenv.sh) environment provides the Lua toolchain
(LuaJIT + Lua 5.1 `luac` for syntax checks, plus `busted` and `luacheck`):

```sh
devenv shell          # enter the dev shell
check                 # syntax + lint + tests (alias: build)
```

Individual steps (available as devenv scripts and `just` recipes):

| Command  | What it does                                              |
| -------- | --------------------------------------------------------- |
| `syntax` | `luac -p` (Lua 5.1) + `luajit -bl` over every plugin file |
| `lint`   | `luacheck` (config in `.luacheckrc`)                      |
| `test`   | `busted` headless unit tests in `spec/`                   |
| `check`  | all three; `build` is an alias                            |

With [`just`](https://github.com/casey/just) installed you can also run
`just check`, `just test`, `just lint`, `just syntax`, or `just emu`.

The unit tests stub KOReader's runtime modules via `package.preload`
(`spec/koreader_stubs.lua`) so the plugin's logic is exercised without the
KOReader runtime. Syntax/lint/tests are all headless; runtime behavior is
validated in the emulator (below).

**Commit hooks:** `devenv.nix` configures git hooks (via `git-hooks.hooks`)
that run `luacheck`, a Lua syntax check (`luac` + `luajit`), and the `busted`
suite. They are installed into `.git/hooks` when you enter `devenv shell` and
run automatically on `git commit`.

### Running in the KOReader emulator (Linux)

The desktop (SDL) build of KOReader runs the plugin natively on Linux. A
launcher fetches it on demand via `nix run nixpkgs#koreader` (KOReader is **not**
added to the dev shell), points `KO_HOME` at a writable scratch dir, and
symlinks the plugin into KOReader's extra plugin path:

```sh
just emu
# or directly:
tools/run-emulator.sh
```

The nixpkgs `koreader` package bundles `newsdownloader.koplugin`, whose EPUB
backend this plugin reuses, so the emulator has everything needed. (Requires a
graphical session.)

## API

Targets the stable **Nextcloud News REST API v1.3**:
<https://nextcloud.github.io/news/api/api-v1-3/>

## License

AGPL-3.0-or-later, to match KOReader. See [`LICENSE`](LICENSE).
