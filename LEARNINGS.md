# Monsters & Memories — Mac (M4) Launcher Investigation

Running log, updated after each investigation step. The goal is twofold:

1. Figure out why `Monsters & Memories.app.tar.gz` opens to "corrupted" on macOS and get the Mac patcher actually running.
2. Figure out the CrossOver route (in case the Mac launcher is only a stub, or we need the Windows game client anyway).

The end goal is a small tool that automates this setup.

---

## Environment

- Mac mini M4 (Apple Silicon, arm64), macOS Darwin 25.2.0.
- Working directory: `/Users/grins/git/monstersandmemories/`.
- Starting artifact: `Monsters & Memories.app.tar.gz` (10,346,769 bytes).

---

## Step 1 — Inspect the archive

### What I ran

```
file "Monsters & Memories.app.tar.gz"
gzip -tv "Monsters & Memories.app.tar.gz"
tar -tzvf "Monsters & Memories.app.tar.gz"
```

### What I found

- It is a valid gzip-compressed tar (gzip `-t` passes, last modified 2026-03-05). **No bit-rot — the file itself is not corrupted.** macOS's "corrupted" dialog is misleading.
- Contents (7 entries total, extracted size ~19 MB):

  ```
  mnm_patcher_app.app/
  mnm_patcher_app.app/Contents/
  mnm_patcher_app.app/Contents/Info.plist
  mnm_patcher_app.app/Contents/MacOS/
  mnm_patcher_app.app/Contents/MacOS/mnm_launcher       (18.9 MB, exec)
  mnm_patcher_app.app/Contents/Resources/
  mnm_patcher_app.app/Contents/Resources/icon.icns
  ```

- `Info.plist` key points:
  - `CFBundleExecutable = mnm_launcher`
  - `CFBundleIdentifier = com.monstersandmemories.mnm-patcher-app`
  - `CFBundleShortVersionString = 0.20.3`
  - `LSMinimumSystemVersion = 10.13`
  - Bundle name ends in `_patcher_app` — so this is a **patcher/launcher**, not the game itself. It almost certainly downloads the actual game payload on first run.

- Archive was created by user `stephenswann` on `Jan 15` (likely the dev's build machine — keep in mind, not a signing cert).

### Why macOS says "corrupted"

Extracted the archive and checked signing/xattrs:

```
codesign -dvvv mnm_patcher_app.app
xattr -lr        mnm_patcher_app.app
```

- Code signature: `Signature=adhoc`, `TeamIdentifier=not set`. This is a **linker-signed ad-hoc signature**, not a Developer ID signature.
- Every entry in the bundle has `com.apple.quarantine` set (`0281;...`).
- Binary is `Mach-O 64-bit executable arm64` — native Apple Silicon, so no Rosetta needed.

**Root cause**: when a tar.gz is extracted, macOS propagates the archive's quarantine attribute onto the contents. Gatekeeper then sees an ad-hoc-signed app with quarantine set, and because it can't verify a Developer ID / notarization ticket, it shows the generic "app is damaged and can't be opened" dialog. The file isn't actually damaged — it's just untrusted.

### Fix (to apply in Step 2)

```
xattr -dr com.apple.quarantine /path/to/mnm_patcher_app.app
```

(Alternative, noisier: `xattr -cr` which clears *all* xattrs.) This does not require disabling Gatekeeper system-wide.

---

## Step 2 — Strip quarantine and re-sign

### What I ran

```
xattr -dr com.apple.quarantine mnm_patcher_app.app
codesign --verify --verbose=2 mnm_patcher_app.app
codesign --force --deep --sign - mnm_patcher_app.app
codesign --verify --verbose=2 mnm_patcher_app.app
spctl -a -vv mnm_patcher_app.app
```

### What I found — and the second bug

Removing the quarantine was necessary but **not sufficient**. The first `codesign --verify` after stripping the xattr failed with:

```
mnm_patcher_app.app: code has no resources but signature indicates they must be present
```

The bundle ships with an ad-hoc signature that claims the resources are sealed, but the `Contents/_CodeSignature/CodeResources` file was never included in the tar. That seal mismatch will also trip Gatekeeper even when quarantine is gone. So the full fix is two steps:

1. `xattr -dr com.apple.quarantine <app>` — remove the quarantine flag.
2. `codesign --force --deep --sign - <app>` — re-sign ad-hoc. This regenerates `_CodeSignature/CodeResources` so the seal matches reality, and updates the bundle identifier from the placeholder `mnm_launcher-a10e0a5edc6ddba9` to the `Info.plist` value `com.monstersandmemories.mnm-patcher-app`.

After both steps:

- `codesign --verify`: `valid on disk` / `satisfies its Designated Requirement` — pass.
- `spctl -a -vv`: still says `rejected`. This is expected — `spctl` is the Gatekeeper policy assessor and will never accept an ad-hoc signature, only Developer ID + notarization. For the user this just means a first-launch dialog; opening the app from Finder (right-click → Open once) will whitelist it.
- Only `com.apple.provenance` xattr remains, which is harmless (it's a macOS-internal flag tracking where the file came from).

### Takeaways for the automation tool

The tool must do **both** `xattr -d` *and* `codesign --force --deep --sign -` and should re-verify with `codesign --verify` before declaring success. Just removing the quarantine (which is what 90% of online "fix it" guides suggest) leaves a broken seal that will still be flagged.

---

## Step 3 — Reverse-engineer the launcher flow

### Method

Straight-up `strings` on the Mach-O binary, then `grep` for URLs, file paths, SQL, env vars, and Tauri command names. The binary is a Tauri (Rust + embedded webview) app, so the frontend is bundled HTML/JS and the backend is a set of `#[tauri::command]` functions exposed to the webview.

### Framework / build fingerprint

- **Framework**: Tauri 2.x (`tauri-plugin-updater/2.9.0`, `tao::platform_impl::platform::app_delegate`, standard Tauri command-scope strings).
- **Language**: Rust. Binary is built from `stephenswann`'s Cargo registry — paths like `/Users/stephenswann/.cargo/registry/...` are embedded in debug metadata.
- **Notable crates in the binary**: `reqwest`, `rustls`, `h2`, `brotli-decompressor`, `zstd-safe`, `minisign-verify` (for Tauri updater signatures), `sqlite3`.

### Tauri commands exposed to the webview

Found via string grep — these are the backend functions the embedded UI calls:

- `gamePath` — get/set the game install directory
- `validate` — checksum-verify existing files against the manifest
- `start_game` — launch the game binary
- `check_for_updates` — fetch launcher self-update
- `fetch_rss` — fetch the patch/release feed (see below)
- `save_database`, `save_variable` — persist state to sqlite

### Endpoints

- **Hardcoded, plaintext in binary**:
  - `https://account.monstersandmemories.com/api/launcher/update?target={{target}}&current_version={{current_version}}` — **launcher self-update** endpoint. `target` is a Tauri target triple (e.g. `darwin-aarch64`), `current_version` is `0.20.3`.
- **Discovered dynamically**: the manifest URL and chunks URL are **not** hardcoded in the binary. They come from the RSS feed that `fetch_rss` retrieves. Feed entries have fields `url`, `patch`, `app`, `version`, `manifestUrl`, `chunksUrl`, `update_state` — so the UI fetches the feed, picks a channel/version, and the backend uses the URLs it provides to download the game.
- **Dev mode override**: environment variable `MNM_LOCAL_SERVER` flips the manifest+chunks URLs to `http://localhost:8080/local.manifest` and `http://localhost:8080/chunks`. Nice to know for testing.
- **CLI dev flag**: `--stinky-cheese` skips the startup update check (author's easter-egg flag).
- **User-Agent**: the launcher sends `Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36` when fetching RSS/manifests. Not a platform signal — just a generic UA to look like a browser.

### Content-addressable patcher design

This is a chunk-based patcher (like Steam, or Epic/roblox-style).

- sqlite schema inside `launcher.db`:
  - `bundle_cache(bundle_id TEXT PRIMARY KEY, …)` — tracks which bundles are already on disk.
  - `chunks(path_id, offset, length, crc, …)` — chunk layout per file.
  - `files(path_id, path, size, timestamp, file_hash)` — file table for validate.
  - `variables(variable, value)` — key/value config, including `gamePath`.
- Compression: **zstd** (confirmed from `zstd-safe` crate), with brotli available for HTTP decoding.
- Integrity: sha256 file hashes, crc per chunk; launcher self-update signatures via minisign (ed25519+blake2b). An embedded public-key hash `sha256-o8CA1OmqqGtTDHkY5EnHkdUKruOqCkqwTY8b5bJggeU=` is the trust root for the Tauri updater.
- Workflow strings: `Bundles already cached`, `Bundles to download`, `Stale bundles cleaned`, `[Worker N] Assembled bundle …`, `[Worker N] Deleted bundle … (last file completed)` — parallel worker pool that downloads bundles, decompresses chunks, assembles target files via mmap, commits to sqlite in one transaction.

### On-disk layout

- App support dir: `APP_DATA_DIR = ~/Library/Application Support/com.monstersandmemories.mnm-patcher-app/`.
- Inside that: `launcher.db` (sqlite) and almost certainly the bundle cache.
- `gamePath` (the actual game install location) is **user-chosen** and persisted in the `variables` table. The launcher does *not* bundle the game; it downloads it on first run.

### Implications for the CrossOver question

The Mac launcher being native arm64 doesn't settle whether you can actually *play* on a Mac — that depends on whether the RSS feed returns a manifest for `darwin-aarch64` / `darwin-universal`. If the backend only publishes a Windows manifest, the Mac launcher would either fail, do nothing, or (most likely) still download Windows game files it can't execute. So two routes remain:

1. **Native Mac route**: Run the now-properly-signed `mnm_patcher_app.app`. If the server serves a Mac build, it just works. If not, the launcher will surface an error.
2. **CrossOver route**: Install a Windows version of the launcher inside a CrossOver bottle and let it download the Windows game client as normal. Works whether or not the Mac build exists on the backend.

### Implications for the automation tool

The tool we eventually write should at minimum:
1. Untar `Monsters & Memories.app.tar.gz` to `/Applications` (or a user-chosen dir).
2. `xattr -dr com.apple.quarantine <app>`.
3. `codesign --force --deep --sign - <app>` (the critical step most guides miss).
4. `codesign --verify --verbose=2 <app>` to confirm.
5. Optionally `open <app>` and surface first-run output.
6. As a fallback: if the Mac launcher fails to retrieve a playable manifest, fall through to a CrossOver install flow (to be defined in Step 4).

---

## Step 4 — CrossOver research

### Ground truth from the official download page

`https://account.monstersandmemories.com/launcher` offers three assets:

- **Windows**: `Monsters & Memories setup.exe` — native installer.
- **macOS**: `Monsters & Memories.app.tar.gz` — the tarball we already have. Page explicitly says **"Requires compatibility layer (Wine, CrossOver, Proton)"** despite the launcher itself being a native arm64 Mac app.
- **Linux amd64 / aarch64**: `MonstersAndMemories_{amd64,aarch64}.AppImage` — Tauri AppImage, needs `webkit2gtk-4.1` and `umu-launcher` or similar Proton runner.

### What "launcher only" actually means

The Mac and Linux launchers are native Tauri apps — the patcher UI *itself* is native on Mac/Linux — but the **game binaries** it downloads and hands off to `start_game` are Windows executables. The dev team has not yet done the "rewrite the launcher to support platforms other than Windows" work that a native game on Mac would require. The Mac launcher is effectively a nice native UI that wraps a Windows game you still need Wine/CrossOver to run.

That means there are two sensible routes on an M4 Mac, and they differ in which layer Wine is sitting under:

1. **Native launcher + Wine for game (what the dev page seems to intend)**: run `mnm_patcher_app.app` natively, let it download/patch the Windows game, and configure `gamePath`/`start_game` to hand off to Wine or a bottle. In practice this is fiddly because the Mac launcher doesn't have a first-class "pick a Wine runner" UI yet.
2. **Full CrossOver route (what most people actually do)**: ignore the Mac tar entirely. Install `Monsters & Memories setup.exe` in a CrossOver bottle; the Windows launcher runs inside Wine, downloads the Windows game inside the bottle, and launches it through CrossOver's graphics translation. This is the battle-tested path.

### Known-good CrossOver recipe (M1 Air / CrossOver 25 — should work on M4 even better)

Source: the Fires of Heaven thread. Tested by a community member on Apple Silicon.

- **Bottle type**: new Windows bottle (Windows 10 or Windows 11).
- **Install target**: run `Monsters & Memories setup.exe` as an unlisted application inside the bottle.
- **Sync mode**: **Default** or **Esync**. **Do not** use **Msync** — the launcher crashes.
- **Graphics translation layer**: **DXVK** works best.
  - **D3DMetal**: crashes the game client. Don't use it.
  - **DXMT**: produces graphical glitches in offline/login scenes.
  - **Wine/Auto**: causes stuttering.
  - (DXMT may improve if/when the client goes back to DX11; the alpha test clients have been mostly DX12.)
- **Patch first, switch modes after**: let the patcher fully download the game under whatever default mode, *then* switch to DXVK.
- **Known UX quirk**: the Tauri launcher window shows as a **black box** inside the bottle for ~a minute on first open. Wait. If it still looks black, click where the Play button "should" be — the game will launch and renders normally once loaded.
- **Performance expectation on M1 Air**: 20–25 FPS in Night Harbor empty. M4 should be significantly higher.

### What the automation tool has to decide

Given everything, the tool should support both flows:

- **Mac launcher flow** (works *today* only to get the patcher UI running — actually playing still needs a Wine setup wired in):
  1. Extract `Monsters & Memories.app.tar.gz`.
  2. `xattr -dr com.apple.quarantine`.
  3. `codesign --force --deep --sign -` (critical — see Step 2).
  4. `codesign --verify` to confirm.
  5. Optional: drop it into `/Applications`.
  6. Open it and let the user walk through the UI.

- **CrossOver flow** (the real path for actually playing on an M4 today):
  1. Detect CrossOver (`/Applications/CrossOver.app`) — if missing, surface a link to download the trial.
  2. Download `Monsters & Memories setup.exe` (probably via a user-provided URL or scraping the launcher page; the exact URL may be login-gated).
  3. Create a new Windows 11 bottle named e.g. `monsters-and-memories`.
  4. Apply bottle settings: sync = Esync, DXVK enabled.
  5. Run the installer inside the bottle, then register the resulting `mnm_patcher_app.exe` as the bottle's entry point.
  6. Surface the "black box at first launch — click where Play should be" warning in the UI.

### Local environment note

`/Applications/Whisky.app` is present on this Mac; `/Applications/CrossOver.app` is not. Whisky is a free Wine frontend that uses Apple's Game Porting Toolkit (D3DMetal) under the hood. Relevant caveat: the known-good M&M recipe explicitly says **D3DMetal crashes the client** — so Whisky's default path is the worst combination for this game. A functional Whisky bottle would need DXVK added manually, and even then sync/other settings aren't as granular as CrossOver's UI. Practical recommendation: use CrossOver for the playing path (trial available), keep Whisky for other titles.

### Open questions / risks

- The installer URL on the download page is probably behind a logged-in account. The tool may need to prompt the user to either paste a cookie or download the `setup.exe` manually first — we should check the auth model before designing a fully-headless install path.
- D3DMetal support is moving fast; the DXVK recommendation may age out in a release or two. The tool should treat the graphics setting as configurable, not hard-coded.
- The launcher's `gamePath` sqlite variable is in `~/Library/Application Support/com.monstersandmemories.mnm-patcher-app/launcher.db`. If we ever want the native Mac launcher to hand off to Wine for `start_game`, we'd likely need to patch that row or provide a wrapper script.

---

## Step 6 — Aligning with the community guide (final `mnm.sh`)

Found a community-written Mac/CrossOver setup guide that validated the hybrid direction and filled in three specifics we missed:

1. **`--stinky-cheese` isn't a dev easter egg — it's mandatory on the Mac launcher.** Without it the launcher enters an infinite self-update loop on Mac. We saw the string in Step 3 but didn't connect it.
2. **The token lives in sqlite:** `SELECT value FROM settings WHERE variable='token';`. Pass it to the game with `--token "$TOKEN"`. (Confirmed schema by inspecting `launcher.db` on disk: table `settings(variable TEXT PRIMARY KEY, value TEXT)`.)
3. **`--workdir` matters** for Unity asset loading — CWD has to be the game directory.

Things the guide does worse than us, kept from our version:
- Two-step quarantine fix (`xattr -dr com.apple.quarantine` + `codesign --force --deep --sign -`) instead of `xattr -cr` alone. The simple form leaves the `_CodeSignature/CodeResources` seal mismatch we hit in Step 2.
- Programmatic CrossOver detection at both `/Applications/CrossOver.app` and `~/Applications/CrossOver.app`.
- Reading `gamePath` dynamically from sqlite instead of hardcoding `~/Downloads/mnm`.

Things from earlier iterations the new script **drops** (they turned out to be dead ends):
- Windows installer (`Monsters & Memories setup.exe`) — never needed; the Mac launcher handles patching.
- Microsoft Edge WebView2 bootstrapper install into the bottle — not needed; the bottle only runs the game, not the launcher.
- `run-cx` search for `mnm_launcher.exe` inside the bottle — was solving the wrong problem.
- `MNM_INSTALL_INTERACTIVE=1` toggle — no installer to be interactive about.

### Final subcommand surface

```
doctor        Check env, installs, token, game files
mac           Download + xattr fix + re-sign + install Mac launcher
bottle        Create the CrossOver bottle (win10_64, DXVK)
patch         Open Mac launcher with --stinky-cheese
play          Read token from launcher.db → cxstart mnm.exe in the bottle
all           doctor + mac + bottle
clean         Remove cached downloads
nuke-bottle   Destroy the CrossOver bottle (confirms first)
```

Workflow becomes:
```
./mnm.sh all       # doctor + mac + bottle, one time
./mnm.sh patch     # opens the launcher, log in + download
./mnm.sh play      # play (reads token, launches mnm.exe under DXVK)
```

### Token expiry is the hidden failure mode

First real `./mnm.sh play` hit an in-game modal: *"Login failed: No authentication token received."* The message is misleading — the game *did* receive a token, the M&M server just rejected it as expired. Decoding the stored JWT confirmed:

```
exp: 1775962601   iat: 1773543401   typ: access   version: 21
```

Token lifetime is ~28 days (`iat → exp` delta). In practice that means `patch` needs to be re-run monthly even if no game patch is out. The launcher refreshes the stored `token` in `launcher.db` on successful login.

`doctor` and `play` now base64-decode the JWT payload (pure shell, no `jq`) and surface a friendly `valid ~Nd` / `expiring in Nh` / `expired Nd ago` status. `play` aborts if expired so you don't discover the bad token by reading it off a game error screen.

### Closed-beta entitlement is gated in the server, not the Mac binary

When the in-game "Patch Required" kept firing for a user whose account page clearly showed the `PVP Only Closed Tester` badge, the next instinct was "the Mac launcher is too old; force an upgrade." The update endpoint

```
GET https://account.monstersandmemories.com/api/launcher/update?target=darwin-aarch64&current_version=0.20.3
  -> { "version": "0.22.13", "url": "…/launcher_v2/0.22.13/mnm_patcher_app_0.22.13_aarch64.app.tar.gz", … }
```

advertised `0.22.13`, three ahead of the `0.20.3` on disk, which looked like the smoking gun. Downloaded it, SHA-compared to the public-page tar, and the update-API tar, and the extracted `.tar.gz` on disk from yesterday:

```
3ef88c1566acccb6e3abad871017568dce3295ffcc0779e7ec2a671401b86571   dl/mnm_launcher_0.22.13.app.tar.gz
3ef88c1566acccb6e3abad871017568dce3295ffcc0779e7ec2a671401b86571   dl/Monsters & Memories.app.tar.gz
3ef88c1566acccb6e3abad871017568dce3295ffcc0779e7ec2a671401b86571   Monsters & Memories.app.tar.gz
```

Byte-identical. The `version` field in the update API is a release label that's outpaced the actual Mac rebuild — nobody has cut a new Mac launcher binary since 0.20.3 even though the index advertises 0.22.13. So a Mac-launcher upgrade can't unlock a beta channel, because there is no newer Mac launcher to upgrade to.

Which leaves only one explanation: the channel dropdown `fetch_channel_data` returns a list filtered server-side by the user's token, and for this user the server is only returning the public channel despite the account being marked `PVP Only Closed Tester`. That's a backend entitlement linkage issue (account flag ↔ launcher channel list) that needs to be fixed by the M&M team; there's no client-side knob that bypasses it.

Also updated `doctor`: comparing `CFBundleShortVersionString` across installs is misleading because the update API's version field drifts independently of the actual binary. `mac` now writes `dl/.installed_tar.sha256` at install time and `doctor` compares that against the SHA of the latest tar the API advertises. "Same binary" shows a ✓; only a real byte-diff triggers the "run mac to update" warning.

### “Patch Required” from the server is often a lie

Saw *"Patch Required. Please exit game and update."* at the server list screen. Initially assumed it meant the client was stale, and shipped `mnm.sh repatch` to force a fresh manifest check. Re-running repatch and reopening the launcher produced no new downloads — the launcher rewrote the same `publish-0.22.0.1-…` version record and reported up-to-date. File mtimes stayed March 28.

Then re-read the in-game Notice panel on the same screen:

> SERVERS ARE CURRENTLY CLOSED. You WILL NOT be able to log in, but you can create a character and run around in the local campfire scene by clicking the flame icon…

That’s the real answer. Between scheduled public playtests, the server returns a generic *"Patch Required"* to every connection regardless of client version. Public playtests are announced on Discord / the mailing list; outside them the only way in is opting into closed testing, which is invite-gated.

So: the Mac launcher was never actually split-brain here. Our client slug `publish-0.22.0.1-b032449…` is *newer* than the public `0.22.0.0` shown in the patch notes (looks like a hotfix), and the baked-in display string *"Public Build 0.21.2.0"* is just a stale label inside mnm.exe — the chunk hashes still match whatever the manifest says is current. `repatch` stays in the tool as a safety net for the rare case where a bundle cache really does desync, but the first guess should now be "server’s closed, not the client."

Surfaced in the site troubleshooting table.

### The launcher can get "split-brain" on game version

Hit on first successful login: the game client booted fine, connected to the server, and got *"Patch Required. Please exit game and update."* — but the launcher insisted everything was up to date, and the in-UI Repair button didn't help either.

What was actually happening:

| Source | Claim |
| --- | --- |
| `launcher.db` → `game_versions.version` | `publish-0.22.0.1-b032449…` |
| `~/Downloads/mnm/mnm.exe` reported build | `Public Build 0.21.2.0` (March 28 mtime) |
| `~/Downloads/mnm/.bundles/` | empty |
| `bundle_cache` table | didn't exist at all |
| Latest public patch (per patch notes) | `0.22.0.0` (2026-04-07) |

The launcher had written the version record once (on first full install), then every subsequent open — and Repair — short-circuited on that record and never downloaded anything, even when newer bundles were available. The server correctly rejected the stale client.

Fix: delete the row in `game_versions` and reopen the launcher. It re-fetches the manifest, diffs against what's on disk, and downloads only the changed chunks (no 6.9 GB redo). Added this as `mnm.sh repatch` — it refuses to run if the launcher is still up, then clears the row and invokes `patch`.

Schema gotcha worth pinning: the column in `game_versions` is `version`, not `value` (I typoed `SELECT value FROM game_versions …` first). Full schema:

```
CREATE TABLE game_versions (slug TEXT PRIMARY KEY, version TEXT);
CREATE TABLE settings     (variable TEXT PRIMARY KEY, value TEXT);
```

### Doctor now reports the whole pipeline

Reads `launcher.db` to show who's logged in, whether a token is present, what `gamePath` the launcher has, and whether `mnm.exe` is actually on disk. Makes it obvious which of the three user-gated steps (install launcher / log in / download game) you're missing.

---

## Step 5 — Earlier automation (`mnm.sh`, superseded)

Shipped a bash script `mnm.sh` with subcommands: `doctor`, `mac`, `crossover`, `all`, `run-mac`, `run-cx`, `clean`.

### Key facts the tool relies on (discovered earlier, pinned here)

- **Public download URLs** (no auth): `https://pub-f06cad9ebbcd412bb0f4ff64f0f6a3d7.r2.dev/launcher_v2/installer/`
  - `Monsters%20%26%20Memories%20setup.exe` (Windows)
  - `Monsters%20%26%20Memories.app.tar.gz` (Mac)
  - `MonstersAndMemories_{amd64,aarch64}.AppImage` (Linux — not used here)
- **CrossOver CLIs** live in `$CX.app/Contents/SharedSupport/CrossOver/bin/`. CrossOver is searched at both `/Applications/CrossOver.app` and `~/Applications/CrossOver.app` (this user has it in the latter).
- **Bottle creation**:
  `cxbottle --bottle NAME --create --template win11_64 --param 'EnvironmentVariables:CX_GRAPHICS_BACKEND=dxvk'`
  The `--param SECTION:KEY=VALUE` form writes straight into `cxbottle.conf`. The `CX_GRAPHICS_BACKEND` env var is how CrossOver 26's template layer selects DXVK vs D3DMetal vs DXMT (confirmed in `bottle_templates/win11_64/CXBT_win11_64.pm`).
- **Running installers**: `cxstart --bottle NAME -- <path-to-exe>`. Paths with spaces are handled by the tool's native-to-Windows path conversion.
- **Sync is NOT forced** — community recommendation is to leave defaults because forcing `WINEMSYNC=1` crashes the M&M launcher. The CrossOver win11_64 template will auto-select a safe default.
- **Mac-app install**: the tool replicates the two-step fix (`xattr -dr com.apple.quarantine` → `codesign --force --deep --sign -`). Extraction happens into `mktemp -d` so the working dir stays clean.

### Idempotency

- Downloads cached in `./dl/` with `curl -C -` resume.
- `doctor` detects prior installs/bottles and skips over them where appropriate.
- `mac` removes and replaces an existing `/Applications/mnm_patcher_app.app`.
- `crossover` refuses to clobber an existing bottle of the same name.
- `clean` wipes `./dl/` and `./extracted/` but leaves the bottle and the installed `.app` alone (destructive actions need to stay opt-in).

### Verified end-to-end

- `doctor`: detects CrossOver 26.0 at `~/Applications`, arm64 macOS 26.2.
- `mac`: downloads fresh tar.gz (~10 MB), extracts, strips quarantine, re-signs, installs to `/Applications`. `codesign --verify` reports `valid on disk` / `satisfies its Designated Requirement` on the installed bundle. Only xattr left is the benign `com.apple.provenance`.
- `crossover`: ran end-to-end. Bottle created cleanly with `cxbottle --create --template win11_64 --param EnvironmentVariables:CX_GRAPHICS_BACKEND=dxvk`. Installer ran via `cxstart`; **interactive UI never rendered a visible window** on arm64 / CrossOver 26 — the NSIS installer process stayed alive for ~5 min doing nothing visible. Killed the hung process, re-ran with the NSIS `/S` silent flag, install completed in seconds.

### Installer UI bug on arm64 CrossOver 26

The Tauri-built NSIS installer appears to open its wizard window off-screen or unmapped under CrossOver 26 + arm64. Diagnostic signs: `ps` shows `Monsters & Memories setup.exe` running for minutes with zero progress, `drive_c/Program Files` stays empty, nothing lands in `AppData/Local`. Fix: pass `/S` (NSIS silent install) — it dumps files and exits immediately. The tool now defaults to `/S`; set `MNM_INSTALL_INTERACTIVE=1` to opt back into the wizard (e.g. when debugging, or once CrossOver/Tauri fixes this).

### Installed launcher path

After a silent install, the Windows launcher lands at:

```
C:\Users\crossover\AppData\Local\Monsters & Memories\mnm_launcher.exe
```

(That's `~/Library/Application Support/CrossOver/Bottles/monsters-and-memories/drive_c/users/crossover/AppData/Local/Monsters & Memories/mnm_launcher.exe` on the host.) The binary name is **`mnm_launcher.exe`**, not `mnm_patcher_app.exe` — `run-cx` searches for that specific filename.

### Launcher-in-Wine is a dead end on CrossOver 26 / wine-11.0

After the silent install, launching `mnm_launcher.exe` inside the bottle reliably crashes with:

```
Unhandled exception: page fault on read access to 0x...  in 64-bit code (0x006ffffe6541ab).
=>0 0x006ffffe6541ab in ole32 (+0x341ab)
  1 0x000001402fa0d6 in mnm_launcher (+0x2fa0d6)
  ...
  3 0x006fffff62f63f in user32 (+0x5f63f)           <- DispatchMessage-ish
  4 0x006fffff5fd3c1 in user32 (+0x2d3c1)           <- SendMessage-ish
```

The crash is deterministic at `ole32+0x341ab` (`movq (%rax), %rax`) and happens *after* WebView2 child processes (`msedgewebview2.exe` with `CrBrowserMain`, `CrRendererMain`, `network.CrUtilityMain`) have successfully spawned. So the crash isn't about WebView2 loading — it's the launcher's window proc dispatching a message that reaches into ole32 with a stale/null COM interface pointer.

Things that did **not** help:
- Installing Microsoft Edge WebView2 Runtime (v147.0) via the evergreen bootstrapper (`MicrosoftEdgeWebview2Setup.exe /silent /install`). Necessary but not sufficient — WebView2 was definitely missing before, confirmed by `embeddedbrowserwebview.dll` loaded but `msedgewebview2.exe` not running; after install, `msedgewebview2.exe` runs, but the main process still crashes in ole32.
- `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS="--no-sandbox --disable-gpu"` — didn't affect the crash (it fires before WebView2 is fully initialized on the main thread).
- `cxstart --desktop 1280x720` to force a Wine virtual desktop and bypass the mac driver's window management — same crash.

### The real fix: hybrid Mac-launcher + CrossOver-game

The Miraheze wiki's *MnM on Linux* page documents the canonical community workaround, and it applies to Mac too:

1. Use the **native launcher** (Linux AppImage on Linux, Mac `.app` on Mac) to download+patch the game. This is the same Tauri binary, but runs natively, so no Wine/WebView2 path.
2. Close the launcher after patching.
3. Run the **game client** (`mnm.exe`, not the launcher) directly in Wine with `--popupwindow --token <TOKEN>`. On Linux the wiki suggests adding it as a non-Steam game with Proton Experimental; on Mac the equivalent is `cxstart --bottle X -- mnm.exe --popupwindow --token ...`.

So the CrossOver bottle's role is reduced: it doesn't run the launcher, it only runs the downloaded game client binary. The launcher stays on the Mac side (where we already fixed the tar/quarantine/codesign issues in Step 2).

### Future nice-to-haves

- `run-cx` currently `find`s the installed .exe under the bottle's `drive_c`. If a future launcher version changes install path, this may return stale or missing paths — could be replaced by reading `cxmenu.conf` which CrossOver writes after an install that registers Start Menu entries.
- We could surface the known-good graphics backend as a flag (`--dxmt`, `--d3dmetal`) for when the M&M dev team switches the game back to DX11 and DXMT becomes viable again.
- Launcher self-update fires on every open; if you want to pin a version, we'd need to pass `--stinky-cheese` at exec time (flag discovered in Step 3).

---

## Summary so far

- The tar is **not** corrupted. macOS says so because the app is ad-hoc signed, quarantined, *and* missing `Contents/_CodeSignature/CodeResources`. Two-step fix: `xattr -dr com.apple.quarantine` + `codesign --force --deep --sign -`.
- The launcher is a **Tauri 2.x** app in Rust that content-addressably downloads the game via manifest+chunks (zstd-compressed, sha256-checksummed, stored in `launcher.db` sqlite) into a user-chosen `gamePath`.
- It still downloads **Windows** game binaries. Native macOS play isn't a thing yet; `launcher only` on the download page means exactly that.
- The practical path on M4 is **CrossOver with DXVK + Esync**, running the Windows `setup.exe`, not the Mac tarball.
- The Mac tarball is useful if you just want the patcher UI native on your Mac and plan to wire in Wine yourself for `start_game`.

