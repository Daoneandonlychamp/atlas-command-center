# Working on ATLAS

Notes for a coding agent asked to change this repository. Not an overview —
[`README.md`](README.md) is the overview and [`SETUP.md`](SETUP.md) is how a
person gets it running. This file is the things that are expensive to learn by
discovering them.

## Orientation

```
Sources/
  AtlasCore/   the library: stores, integrations, the authority model
  AtlasApp/    the SwiftUI app: DesignSystem, Navigation, Views
  AtlasCtl/    atlasctl, shipped inside the bundle so it signs with one identity
Tests/
  AtlasCoreTests/   XCTest, including PageBootTests
  *.js              node suites for the HTML surfaces
```

```bash
swift build                     # compile
swift test                      # 372 tests, all of which pass — keep it that way
swift test --filter PageBootTests
node Tests/cinema_test.js       # and the other five beside it
scripts/build_app.sh            # package and sign dist/Atlas.app
python3 scripts/dev_pages.py    # pages in a browser with fixture data, :8787
```

**Run both suites before claiming a change works.** The node files are not
wired into `swift test` and will not run themselves; one of them had been
failing for weeks because nobody executed it.

## The architecture that matters

Eight surfaces are HTML in a `WKWebView`, not SwiftUI: `calendar`, `canvas`,
`chat`, `assistant`, `cinema`, `crm`, `finances`, `hud`, `kanban`. Each one
that persists anything is split three ways, and the split is not decorative:

1. **The page** owns what is on screen and touches no storage.
2. **A bridge** (`CRMBridge`, `CalendarBridge`, `CinemaBridge`, `FinancesBridge`)
   owns everything that reaches a database. The page posts a *named action from
   a fixed set*; anything that fails to decode is dropped, and anything that
   decodes is validated again in Swift before a row is written.
3. **A store** (`CRMStore`, `ChatStore`, `CinemaStore`, `CanvasStore`,
   `ExpenseStore`) is SQLCipher-encrypted, keyed from the Keychain, living in
   `~/Library/Application Support/ATLAS/`.

Do not let a page reach storage directly, and do not let a bridge accept an
action that is not already in its switch.

## Rules that look arbitrary and are not

**Money never goes through JavaScript arithmetic.** Amounts cross the bridge as
integer minor units with a pre-formatted string beside them; what the user types
goes back as *text* for `Money.minorUnits` to parse. `Number("21.28") * 100` is
`2127.9999999999998`.

**Nothing important lives in `localStorage`.** WebKit partitions it by bundle
identifier, so the same page run a different way gets a different, empty
container. Page state goes through the store. Cinema's library appeared deleted
once for exactly this reason.

**Never hardcode a path.** Anything machine-specific belongs in
`WorkspaceSettings` (`Sources/AtlasCore/System/WorkspaceSettings.swift`), is
empty by default, and is filled in by the user in Settings. This repository had
50 hardcoded home-directory paths and every one was a bug waiting for a second
machine.

**Never write a test that reads a real home directory.** Build a fixture in
`NSTemporaryDirectory()` and clean it up. `AtlasCoreTests` has `makeTempRoot`
and `makeGitRepo` for this. A test asserting against `~/Documents` reports a
moved folder as a code failure.

**`swift run AtlasApp` has no bundle identifier**, so every WebKit surface opens
against an empty store. Use `dist/Atlas.app/Contents/MacOS/AtlasApp` whenever
data matters. A bug that only reproduces under `swift run` is usually this.

## Editing a page

Point the app at the repo's copy and it reloads on save — no rebuild, no
restart:

```bash
ATLAS_FINANCES_PAGE=$PWD/Sources/AtlasCore/Resources/finances.html \
  dist/Atlas.app/Contents/MacOS/AtlasApp
```

One variable per page: `ATLAS_FINANCES_PAGE`, `ATLAS_CINEMA_PAGE`,
`ATLAS_CRM_PAGE`, `ATLAS_CALENDAR_PAGE`, `ATLAS_BOARD_PAGE`,
`ATLAS_CANVAS_PAGE`, `ATLAS_CHAT_PAGE`, `ATLAS_HUD_PAGE`. Without the variable
nothing is watched and nothing reloads.

Reloads re-load the file rather than calling `reload()`: on a `file://` URL
WebKit will serve its cached copy, which is indistinguishable from the change
not appearing.

## Styling

`atlas-theme.css` and `atlas-components.css` are **injected** at document start
(`AtlasResources.sharedStyles`), never linked — these pages run from `file://`
under a CSP with no `'self'` in `style-src`. Because injection lands before each
page's own `<style>`, any rule there is a default a page overrides by declaring
the same property.

Tokens live in `:root` in `atlas-theme.css`. `--gold` is **white**
(`rgba(255,255,255,.94)`), not gold — the name is historical. `--cyan` exists;
check before introducing accent colour, the interface is deliberately
monochrome. Typography is the system stack (`--sans`, `--mono`); the SwiftUI
side uses `Font.system` sizes in `AtlasTheme.swift`.

`cinema.html` deliberately wears none of it and defines its own tokens. That is
a decision, not drift: every other surface is an instrument panel, and Cinema is
full-bleed artwork that stays black regardless of appearance. Do not "fix" it by
making it match.

## The security model, stated exactly

The Companion (`LocalCompanion`) can read files and run commands. **One
boundary enforces that: a list of folders**, from `WorkspaceSettings`, empty
until the user adds one. `PathValidator` canonicalises before comparing, so
`../` cannot escape and `Documents-evil` does not match `Documents`.

**Commands are not filtered.** Inside a permitted folder, whatever the Companion
is handed runs. There was once an `allowlistedCommands` property that was never
read; it was deleted rather than left to imply a lock that did not exist. If you
add command filtering, say so in the README — the README's description of this
boundary is expected to stay exact.

Secrets live in the macOS Keychain (`KeychainManager`, service
`com.atlas.app.keychain`), never in a file, never in the repo. Encryption keys
for the four stores are generated on first run and kept there too.

## Before you claim it works

- `swift test` — 372, zero failures.
- All six `Tests/*.js`.
- `PageBootTests` specifically if you touched a page. It boots each page in a
  real `WKWebView` and checks it wired itself up, rendered the bridge's payload,
  escaped user text instead of executing it, and laid out at several widths.
  **Static HTML always renders; only booting it catches a page that came up
  inert.** Measure in the WebView rather than reasoning about the CSS — three
  layout bugs in one night were diagnosed wrongly by reasoning and correctly by
  measuring.
- If you changed anything machine-specific, confirm a fresh install still starts:
  every `WorkspaceSettings` value empty must give empty states, not crashes.

## Things not to do

- Do not re-add third-party video embed hosts to `cinema.html`. They were
  removed deliberately; the sources that ship are the user's own Jellyfin server
  and the Internet Archive.
- Do not put a real name, address, or personal detail in fixtures or comments.
  `scripts/dev_pages.py` fixtures are invented on purpose.
- Do not reintroduce a hardcoded developer path, including in a test.
- Do not change the bundle identifier. It keys both the Keychain service and
  WebKit's storage container; changing it reads to an existing install as every
  database being empty.
