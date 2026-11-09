# Installing Kvačica: notes for coding agents

You are probably here because someone asked you to install this app. The user-facing docs are in [README.md](README.md).

## Install the released app (the default)

No Xcode needed. The release is signed with Developer ID and notarized, so it opens without warnings.

1. `sw_vers -productVersion` must be 14 or later.
2. Download, copy into Applications, unmount:

   ```bash
   curl -fL -o "$TMPDIR/Kvacica.dmg" https://github.com/egoshingeorgii-eng/kvacica/releases/latest/download/Kvacica.dmg
   hdiutil attach -nobrowse -quiet -mountpoint "$TMPDIR/kvacica-dmg" "$TMPDIR/Kvacica.dmg"
   osascript -e 'quit app "Kvačica"' 2>/dev/null || true
   ditto "$TMPDIR/kvacica-dmg/"Kva*ica.app "/Applications/$(basename "$TMPDIR/kvacica-dmg/"Kva*ica.app)"
   hdiutil detach -quiet "$TMPDIR/kvacica-dmg"
   ```

   Keep the app's file name as it is in the DMG: its "č" is spelled as c + a combining caron, and the widgets are found by that exact name. If `/Applications` isn't writable, use `~/Applications`.
3. `codesign --verify --deep --strict /Applications/Kva*ica.app` should be silent. Open it with `open /Applications/Kva*ica.app`, or ask the user to.

The app is a menu-bar app: on first launch a welcome window asks the user's level; after that it lives behind a menu-bar icon (⌥⌘S). Tell the user what was installed and where, and that the first use of dictation asks for microphone and speech recognition access. Updating is the same steps; the user's words stay.

## Build from source (only if asked)

1. **Check the Mac.** `xcodebuild -version` must print Xcode 26 or later. If it fails with "requires Xcode, but active developer directory … is a command line tools instance", Xcode is installed but not selected: ask the user to run `sudo xcode-select -s /Applications/Xcode.app` (it needs their password). If Xcode isn't installed, ask them to install it from the App Store and open it once. Don't try to download Xcode yourself.
2. **Clone** `https://github.com/egoshingeorgii-eng/kvacica.git` and `cd` into it.
3. **Run `./scripts/install.sh`.** It installs XcodeGen with Homebrew if missing, generates the Xcode project, builds a Release copy (the first build fetches the `swift-fsrs` package from GitHub and takes a few minutes), signs it, copies it to `/Applications/Kvačica.app` and opens it. Run it in the background or with a long timeout.
   - By default the build is signed ad-hoc and has no widgets. Add `--signed` if the user wants the widgets and has an "Apple Development" certificate (`security find-identity -v -p codesigning`).
   - Add `--mcp` if the user uses Claude Desktop and wants to add words from it locally. Claude Desktop must be quit (⌘Q) while it runs, or it may overwrite its config.
   - Add `--no-open` if you shouldn't bring a window up in front of the user.
4. **Verify.** The script ends with `Installed /Applications/Kvačica.app`; `codesign --verify --deep --strict` on it should be silent.

## If building from source fails

| Symptom | Cause and fix |
|---|---|
| `sandbox-exec: sandbox_apply: Operation not permitted` | Your own command sandbox. Swift Package Manager runs `sandbox-exec` inside `xcodebuild`, and sandboxes can't nest: run the script outside your sandbox. |
| Package resolution fails / can't reach github.com | `swift-fsrs` comes from GitHub. Allow network access to `github.com` for the build. |
| `brew: command not found` | Homebrew is missing. Ask the user to install it from https://brew.sh (it needs their password), or install XcodeGen another way (`mint install yonaskolb/XcodeGen`, or a release binary from GitHub) and make sure `xcodegen` is on PATH. |
| `xcodebuild: error: … license` | `sudo xcodebuild -license accept` (user's password). |
| Build errors about unknown APIs or symbols | Xcode is older than 26. Update Xcode. |
| `No "Apple Development" certificate` | Only with `--signed`. Drop the flag, or have the user add their Apple ID in Xcode → Settings → Accounts and create the certificate there. |
| Widget missing from the widget gallery | Only `--signed` builds have widgets. |
| `open` fails with -10822 or similar | Your sandbox blocks Launch Services. The app is installed; ask the user to open it from Applications. |

## Things not to do

- Don't use `sudo` for the build or the install. The app installs into `~/Applications` when `/Applications` isn't writable.
- Don't touch `~/Library/Application Support/Srpski/` on a Mac where the app was used before: that's the user's words and progress. Updating the app keeps them.
- Don't edit `claude_desktop_config.json` beyond the `srpski` entry `install-mcp.sh` adds.

## Working on the code

- `xcodegen generate` after adding or removing files; the `.xcodeproj` isn't in git.
- `cd Packages/SrbCore && swift test` runs the logic tests (no UI, no app launch).
- UI strings: English keys in code, Russian in `Shared/Localizable.xcstrings`. Every new string needs its Russian translation.
