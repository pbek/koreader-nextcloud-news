# koreader-nextcloud-news — Project Plan

A KOReader plugin (**Nextcloud News**, plugin id `nextcloud_news`, folder
`nextcloudnews.koplugin`) that synchronizes RSS/Atom articles from a
[Nextcloud News](https://github.com/nextcloud/news) server to a PocketBook
(or any KOReader-supported) e-reader, with **two-way read/starred state sync**.

> **Naming**
> - Repository / project: `koreader-nextcloud-news`
> - Plugin folder: `nextcloudnews.koplugin`
> - Plugin id (`name` in `_meta.lua`): `nextcloud_news`
> - Display name: `Nextcloud News`
>
> The plugin is **device-agnostic** (Kobo/Kindle/Android too); PocketBook is the
> primary target, not a limitation. The name deliberately avoids "news
> downloader" to prevent confusion with KOReader's built-in
> `newsdownloader.koplugin`.

## 0. Implementation status (snapshot)

**Working (syntax-checked, linted, unit-tested; not yet runtime-tested on a
physical device):** M0–M4 plus most of M5. The plugin can be configured, tests
its connection, surfaces server `/status` warnings, and runs a full
synchronize: detect finished articles → push read statuses (batched, with an
offline queue) → fetch unread/updated items → render each to a per-article EPUB
→ optionally clean up locally-read files → persist a `lastModified` cursor for
incremental sync.

**Quality gates (all green):**
- `syntax` — `luac -p` + `luajit -bl` on every Lua file.
- `lint` — `luacheck` (0 warnings/errors).
- `test` — `busted`, **53 passing unit tests** across `newsapi.lua` (22),
  `epub.lua` (13), and `main.lua` queue/path/star/filter logic (18). HTTP and
  the EPUB backend are mocked; KOReader modules stubbed via `package.preload`.
- `git-hooks` — commit hooks (luacheck + lua syntax + busted) configured in
  `devenv.nix`, installed on `devenv shell`.
- Runnable in the KOReader desktop emulator on Linux via
  `tools/run-emulator.sh` / `just emu` (uses `nix run nixpkgs#koreader`).

**Not yet done:** on-device/emulator *interactive* runtime testing against a
live Nextcloud server, and the final vendor-vs-soft-depend decision for the
EPUB backend. See §4 (M5).

### Tooling / commands
- Dev shell: `devenv shell` (Lua 5.1 + LuaJIT + busted + luacheck).
- Scripts (devenv) and `just` recipes: `syntax`, `lint`, `test`,
  `check` (= all three), `build` (= `check`), `emu`.
- `devenv.yaml` inputs: `nixpkgs` (rolling) and `shared`
  (`github:pbek/nix-shared`, `flake: false`).

## 1. Goal & Scope

### Problem
Read Nextcloud News feeds on a PocketBook e-reader with a good e-ink reading
experience and read-state that stays in sync with the server.

### Decision (rationale recap)
- **Do not** port `nextcloud/news-android` natively to PocketBook. That means
  reimplementing networking, HTML/EPUB rendering, an e-ink UI, WiFi handling,
  and settings against PocketBook's low-level SDK for a single platform.
- **Do** build a **KOReader plugin**. KOReader runs natively on PocketBook
  (officially supported alongside Kindle/Kobo/Android) and already provides
  HTTP(S), EPUB/HTML rendering, an e-ink reading UI, WiFi management, settings
  storage, a plugin loader, and JSON/XML parsing.
- Model the plugin on the existing **`wallabag.koplugin`** (server REST API,
  OAuth-style auth, download-as-EPUB, two-way status sync, offline queue) and
  reuse the EPUB backend from **`newsdownloader.koplugin`**.

### In scope (MVP)
- Configure server URL + credentials (Nextcloud app password via HTTP Basic).
- Fetch folders, feeds, and unread/starred items.
- Render each item's HTML `body` to an EPUB stored in a dedicated folder.
- Push read/unread and starred/unstarred state back to the server.
- Incremental sync using `GET /items/updated?lastModified=...`.
- Menu integration in KOReader (file manager + reader Tools menu).

### Out of scope (initial)
- Adding/removing/renaming feeds and folders from the device.
- Full-article extraction/readability beyond what the feed `body` provides
  (can reuse NewsDownloader's full-article fetch later).
- Multi-account support.
- API v2 (use stable v1.3).

## 2. Target API

Nextcloud News **REST API v1.3** —
<https://nextcloud.github.io/news/api/api-v1-3/>

- **Base URL**: `https://<host>/index.php/apps/news/api/v1-3/`
- **Auth**: HTTP Basic — `Authorization: Basic base64(USER:PASSWORD)`.
  Recommend a Nextcloud **app password**, not the main account password.
  KOReader already uses the `mime.b64(user..":"..pass)` + custom header pattern
  (see `newsdownloader.koplugin/main.lua`).
- **HTTPS strongly recommended** (Basic auth sends credentials each request).

### Endpoints used

| Purpose | Method | Route |
|---|---|---|
| Sanity check / config validation | GET | `/version`, `/status` |
| List folders | GET | `/folders` |
| List feeds | GET | `/feeds` |
| Unread items (initial) | GET | `/items?type=3&getRead=false&batchSize=-1` |
| Starred items (initial) | GET | `/items?type=2&getRead=true&batchSize=-1` |
| Incremental sync | GET | `/items/updated?lastModified=<ts>&type=3` |
| Mark read (batch) | PUT | `/items/read/multiple` `{"items":[...]}` |
| Mark unread (batch) | PUT | `/items/unread/multiple` `{"items":[...]}` |
| Mark starred (batch) | PUT | `/items/star/multiple` `{"itemIds":[...]}` |
| Mark unstarred (batch) | PUT | `/items/unstar/multiple` `{"itemIds":[...]}` |

### Item fields of interest
`id`, `guid`, `guidHash`, `url`, `title`, `author`, `pubDate` (unix int),
`body` (HTML), `feedId`, `unread` (bool), `starred` (bool),
`lastModified` (string/int), `fingerprint`.

## 3. Architecture

### Build on KOReader primitives
- `socket.http` / `socketutil` / `ltn12` — HTTP requests + timeouts.
- `JSON` (`require("json")`) — encode/decode API payloads.
- `LuaSettings` — persisted plugin settings.
- `NetworkMgr` — gate calls behind WiFi (`runWhenOnline`, `afterWifiAction`).
- `WidgetContainer` + `registerToMainMenu` — menu integration.
- `Dispatcher` — register gestures/quick actions for sync.
- `epubdownloadbackend.lua` (from `newsdownloader.koplugin`) — HTML → EPUB.
  Reuse `createEpub(...)` to render `item.body` to an EPUB; handles images.
- `lib.dateparser` (from `newsdownloader.koplugin`) — parse `lastModified`.
  Note: only available when NewsDownloader is active. Prefer the integer
  `pubDate`/`lastModified` fields to avoid the dependency where possible.

### Files (current)
```
nextcloudnews.koplugin/
  _meta.lua            -- [done] name/fullname/description (translatable)
  main.lua             -- [done] menu, events, settings, sync orchestration,
                       --         /status warnings
  newsapi.lua          -- [done] Nextcloud News API client (callAPI wrappers)
  epub.lua             -- [done] item -> EPUB wrapper (soft-depends backend)
spec/
  koreader_stubs.lua   -- [done] preload stubs, HTTP mock, EPUB backend stub,
                       --         tiny JSON, optional UI stubs (installUI)
  newsapi_spec.lua     -- [done] busted unit tests (22 cases)
  epub_spec.lua        -- [done] busted unit tests (13 cases)
  main_spec.lua        -- [done] busted unit tests (5 cases: queue + path)
tools/
  run-emulator.sh      -- [done] launch KOReader via nix run + KO_HOME symlink
```
Repo root also contains: `devenv.nix`/`devenv.yaml`/`devenv.lock` (Lua
toolchain + `syntax`/`lint`/`test`/`check`/`build` scripts), `justfile`
(same recipes + `emu`/`clean`), `.luacheckrc`, `.busted`, `LICENSE`
(AGPL-3.0), `README.md`, `.gitignore`.

**Decision taken:** **soft-depend** on NewsDownloader's `epubdownloadbackend`
via `pcall(require, "epubdownloadbackend")`, with a clear user-facing error if
unavailable (`epub.lua` / `Epub.isAvailable`). Vendoring is deferred to M5.

### State model
- Local download folder is owned exclusively by the plugin (mirror Wallabag's
  warning: existing files may be deleted).
- Embed the News item `id` in the filename (Wallabag uses `[w-id_<id>] `);
  use e.g. `[nc-id_<id>] <safe-title>.epub` for round-trip mapping.
- A persisted **offline status queue**: list of pending
  `{id, action}` (read/unread/star/unstar) to flush on next online sync —
  mirror Wallabag's `offline_queue` + `uploadStatuses`.
- Persist `last_sync_lastModified` for incremental sync.

### Sync flow (per "Synchronize")
1. Validate config; ensure WiFi (`NetworkMgr:runWhenOnline`).
2. `GET /status` occasionally to surface server misconfiguration warnings.
3. Flush queued local status changes (PUT batch endpoints).
4. Map local reading progress → status changes:
   - finished / 100% read → mark read (configurable, like Wallabag).
   - starred toggles made on device → star/unstar.
5. Fetch updates: initial full unread+starred, or incremental via
   `/items/updated`.
6. For each new item: render `body` → EPUB into download folder (skip if file
   already exists / local copy newer).
7. Optionally remove local files for items now read/removed on server
   (configurable, like Wallabag's "delete remotely archived locally").
8. Update `last_sync_lastModified`; show summary (downloaded/skipped/failed).

## 4. Milestones

### M0 — Project setup  ✅ done
- [x] Repo scaffolding, license (full AGPL-3.0 text in `LICENSE`).
- [x] `_meta.lua` with translatable name/description.
- [x] devenv dev environment (LuaJIT + Lua 5.1 `luac`) with `check`/`build`
      scripts; `devenv shell check` syntax-checks every plugin file under both
      `luac -p` and `luajit -bl`. (Verified passing.)
- [x] Dev loop documented: KOReader emulator via `tools/run-emulator.sh`
      (`nix run nixpkgs#koreader`, `KO_HOME` + plugin symlink); README covers it.

### M1 — API client (`newsapi.lua`)  ✅ done
- [x] `callAPI(method, route, body, filepath, quiet)` (Wallabag-style: sink
      table vs. file, `socketutil` timeouts, error classes
      `not_configured`/`bad_url`/`network_error`/`json_error`/`http_error`+code).
- [x] HTTP Basic auth header builder + `getBaseUrl` URL normalization
      (bare host or full API path accepted).
- [x] `getVersion`, `getStatus`, `getFolders`, `getFeeds`.
- [x] `getItems(params)` + `getUnreadItems`/`getStarredItems` convenience.
- [x] `getUpdatedItems(lastModified, type, id)`.
- [x] `markRead/markUnread/markStarred/markUnstarred` (batch).
- [x] Unit tests with mocked HTTP responses (`spec/newsapi_spec.lua`, 22 cases).

### M2 — Settings + menu (`main.lua`)  ✅ mostly done
- [x] Server settings dialog (URL, username, app password) via
      `MultiInputDialog` (password masked).
- [x] Download folder picker (`DownloadMgr`).
- [x] `LuaSettings` load/save (`onFlushSettings`); `articles_per_sync`
      (`SpinWidget`), `include_images`, `mark_read_on_finished`,
      `remove_read_locally` toggles.
- [x] Menu: Synchronize, Go to download folder, Test connection, Configure
      server, settings toggles, Info.
- [x] `Dispatcher` action `nextcloud_news_sync` → `SynchronizeNextcloudNews`.
- [x] Folder/feed selection ("Sync from"): `chooseFilter` fetches `/folders` +
      `/feeds` into a picker; `setFilter` persists `filter_type`/`filter_id`/
      `filter_label` and resets the incremental cursor so the new scope is
      re-fetched. `synchronize` passes the scope to `getItems`/`getUpdatedItems`.
- [ ] Starred-only filter. (Deferred — out of MVP scope.)

### M3 — Download & render  ✅ done
- [x] `epub.lua`: soft-depends on `epubdownloadbackend`; `buildHTML(item)`
      renders title/byline/body/footer; `createFromItem` calls `createEpub`
      (must run within `Trapper:wrap`).
- [x] Filename scheme with embedded id (`[nc-id_<id>] <title>.epub`);
      skip-existing via `getLocalArticles` id map.
- [x] Image inclusion option; relative→absolute `href` rewriting.

### M4 — Two-way status sync  ✅ done
- [x] Detect finished articles via `DocSettings` `summary.status == "complete"`
      (`queueFinishedArticles`).
- [x] Offline status queue (`status_queue` persisted in settings) +
      `flushStatusQueue` (batched by action; failed entries re-queued).
- [x] Map device → server: finished → mark read (batch PUTs).
- [x] Incremental sync via `/items/updated`; persist `last_modified` cursor.
- [x] Optional local cleanup of server-read items (`remove_read_locally`).
- [x] Surface device-side **star** toggles → server: `toggleStar`/
      `toggleStarCurrentArticle`, a reader menu item ("Star/Unstar current
      article"), and a `ToggleNextcloudNewsStar` dispatcher action. The
      starred state per id is persisted (`starred_state`) and refreshed from
      server items each sync so toggles flip the correct direction.

### M5 — Hardening & release  (in progress)
- [x] Error classification + user-facing messages (`describeError`) for
      network/HTTP/config/JSON failures.
- [x] `GET /status` cron/charset warnings surfaced during sync
      (`checkServerStatus`, best-effort/non-fatal).
- [x] Unit tests (`spec/`, busted), 53 cases: `newsapi.lua` (22),
      `epub.lua` (13), `main.lua` queue/path/star/filter logic (18). HTTP +
      EPUB backend mocked.
- [x] `luacheck` lint clean (`.luacheckrc`).
- [x] Git commit hooks via `devenv.nix` `git-hooks.hooks`: `luacheck`,
      `lua-syntax` (luac + luajit), and `busted`.
- [x] Emulator dev loop on Linux (`tools/run-emulator.sh` via
      `nix run nixpkgs#koreader`); README documents it.
- [ ] Interactive runtime testing against a live Nextcloud server (emulator +
      real PocketBook). Needs a server + app password — cannot be done in CI.
- [ ] Docs: setup screenshots (needs the emulator running interactively).
- [ ] Decide vendoring of EPUB backend/dateparser (currently soft-depend).
- [ ] Optional: PR to upstream KOReader, or distribute as standalone plugin.

## 7. Are we done? (Definition of done)

**Done (code-complete MVP, all automated gates green):** M0–M4 and the
automatable parts of M5 — API client, settings/menu, download+render,
two-way read **and star** status sync, incremental sync, error handling,
`/status` warnings, 49 unit tests, lint, commit hooks, and a Linux emulator
dev loop.

**Not done — and not completable in this sandbox** (each needs a real
Nextcloud server, a display, and/or a device):
1. Interactive end-to-end run against a live Nextcloud News instance
   (configure → Test connection → Synchronize → read → star → status
   round-trip).
2. On-device validation on a physical PocketBook.
3. Setup screenshots for the docs.
4. Final decision: keep soft-depend vs. vendor the EPUB backend (revisit after
   #1/#2 confirm the soft-depend works in practice).

These are the only remaining items for a first release; everything that can be
built and verified headlessly is complete.

## 5. Risks & Open Questions

| Risk / Question | Mitigation / Decision |
|---|---|
| `lib.dateparser` only present if NewsDownloader installed | Prefer integer `pubDate`/`lastModified`; soft-depend, else vendor. |
| EPUB backend is internal to NewsDownloader | Soft-depend for MVP; vendor a pinned copy before release. |
| Basic auth over HTTP leaks credentials | Require/encourage HTTPS; use Nextcloud app passwords. |
| Large unread counts → slow first sync | Use `batchSize` paging; cap via `articles_per_sync`. |
| Conflict: item changed on server and device | Last-write-wins via queue flush before fetch; document behavior. |
| URL form differs per Nextcloud setup (`/index.php` vs pretty URLs) | Accept full base URL from user; validate via `/version`. |
| KOReader API drift across versions | Pin a min KOReader version; test on current stable. |
| Licensing for upstreaming | Use AGPL-3.0 to match KOReader. |

## 6. Reference Material
- Nextcloud News REST API v1.3:
  <https://nextcloud.github.io/news/api/api-v1-3/>
- KOReader `wallabag.koplugin` (architecture template):
  <https://github.com/koreader/koreader/tree/master/plugins/wallabag.koplugin>
- KOReader `newsdownloader.koplugin` (EPUB backend, dateparser, RSS handling):
  <https://github.com/koreader/koreader/tree/master/plugins/newsdownloader.koplugin>
- KOReader plugin/dev docs: <https://koreader.rocks/doc/>
  (modules: `pluginloader`, `luasettings`, `ui.network.*`, `dispatcher`,
  `ui.downloadmgr`, widgets).
- KOReader porting/hacking guides (emulator dev loop):
  <https://koreader.rocks/doc/topics/Hacking.md.html>
