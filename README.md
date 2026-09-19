# ATLAS

A private, native macOS personal command-center. ATLAS is a local-first Swift
app that brings your projects, calendar, notes, money, media and a Sovereign
presence layer together in one place. Everything it stores is encrypted on
your own disk, and the one part that can run commands is confined to folders
you name yourself.

Built with **Swift 5.9** and **SwiftUI** for **macOS 14+**.

**Architecture map:** [`docs/architecture.html`](docs/architecture.html) — open it
in a browser for an interactive diagram of how the modules connect.

## What it is

ATLAS runs locally, keeps its own encrypted state, and asks before it acts.
There is no account, no sync and no telemetry; it makes network calls only to
services you configure yourself.

New here? [`SETUP.md`](SETUP.md) walks through building it and filling in the
settings, and assumes nothing. If a coding agent is doing the work,
[`AGENTS.md`](AGENTS.md) is written for it: the architecture it must not break,
the rules that look arbitrary, and what to run before saying a change works.

| Surface | What it does |
|---|---|
| **Overview / HUD** | The landing surface and the live presence display. |
| **Assistant** | Direct chat, including uncensored models, with encrypted transcripts. |
| **Projects · Board · Journal** | Local project, kanban and journalling surfaces. |
| **Notes & Search** | Reads and works against your Obsidian vault. |
| **Calendar & Tasks** | Calendar and reminders over EventKit. |
| **Business** | A local CRM: companies, contacts, opportunities, activity. |
| **Finances** | Bills, spend, credit accounts, debt payoff, and a read-only Stripe view. |
| **Canvas** | An infinite canvas over JSON Canvas files. |
| **Cinema** | A media library and player. |
| **Automations · Connections · Activity** | Cron, integrations, and an append-only audit ledger. |

Underneath: **Presence** (local voice and visuals), **Hermes** (an optional
integration with a self-hosted agent runtime), **Security and Keychain**
(approval flow, risk tiers, and secrets in the macOS Keychain), and
**Companion** (the local companion process).

### What the Companion is allowed to do

The Companion can read files and run commands. One boundary enforces that: a
list of folders, set in Settings, **empty until you fill it in**. Paths are
canonicalised before the check, so `../` cannot walk out and a sibling named
`Documents-evil` does not match an allowed `Documents`. Outside that list
nothing is read and nothing is run.

That is the whole boundary. Commands themselves are *not* filtered against an
allowlist — anything you hand the Companion, inside a permitted folder, runs.
Add only folders you are willing to have an agent work in, and do not add your
home directory.

## Architecture

A Swift package with three products and a test target:

```
Sources/
  AtlasCore/   Calendar Canvas Chat Cinema Companion Connections CRM Cron
               Diagrams Finances Hermes HUD Journal Keychain Ledger Models
               Notifications Obsidian Presence Projects Resources Security
               Sessions System
  AtlasApp/    SwiftUI app: DesignSystem, Navigation, Views
  AtlasCtl/    atlasctl — ships inside Atlas.app so it signs with the same identity
Tests/
  AtlasCoreTests/
```

- `AtlasCore` — the library: state, integrations, stores, and the authority model.
- `AtlasApp` — the SwiftUI application (uses the Luminare UI library).

### HTML surfaces

Several surfaces are not SwiftUI. They are HTML pages in a `WKWebView`, and
they are the ones that change most often:

```
Sources/AtlasCore/Resources/
  calendar.html  canvas.html  chat.html   cinema.html
  crm.html       finances.html  hud.html  kanban.html
```

Each page that writes data has three parts:

1. **The page** — owns everything on screen. Never touches storage.
2. **A bridge** (`CRMBridge`, `CalendarBridge`, `CinemaBridge`, `FinancesBridge`)
   — owns everything that touches the database. The page posts a *named action
   from a fixed set*; anything that does not decode is dropped, and everything
   that does is validated again in Swift before a row is written.
3. **A store** (`CRMStore`, `ChatStore`, `CinemaStore`, `CanvasStore`,
   `ExpenseStore`) — SQLCipher-encrypted, keyed from the Keychain, in
   `~/Library/Application Support/ATLAS/`.

Two rules the pages follow, both learned the hard way:

- **Money never goes through JavaScript arithmetic.** Amounts cross as integer
  minor units with a pre-formatted string beside them; what the user types goes
  back as *text* for `Money.minorUnits` to parse. `Number("21.28") * 100` is
  `2127.9999999999998`.
- **Nothing important lives in `localStorage`.** WebKit partitions it by bundle
  identifier, so running the binary without one hands the page a different,
  empty container. Cinema's library looked deleted once for exactly this reason.
  Page state belongs in a store.

## Build and run

```bash
swift build          # build
swift run AtlasApp   # run from source
swift test           # run the AtlasCore tests
scripts/build_app.sh # package and sign dist/Atlas.app
```

Requires macOS 14 or later and the Swift toolchain. Build output (`.build/`,
`dist/`), credentials, local databases and vault contents are gitignored and
never committed.

### Iterating on an HTML surface

Two ways, depending on what you are changing.

**In a browser**, for layout and styling — fastest loop, live reload on save:

```bash
python3 scripts/dev_pages.py     # http://localhost:8787
```

It serves every page with the shared stylesheet injected, a mocked bridge
carrying fixture data, and a relaxed CSP so images and APIs load. Writes are
acknowledged and then discarded, and third-party video embeds refuse an unknown
origin, so playback and persistence still need the real app.

**In the app**, against real data — point the page at the repo copy:

```bash
ATLAS_FINANCES_PAGE=$PWD/Sources/AtlasCore/Resources/finances.html \
  dist/Atlas.app/Contents/MacOS/AtlasApp
```

**The page reloads itself when you save it.** Every surface watches the file it
was told to load and redraws on write — no rebuild, no restart, no switching off
the tab and back.

One variable per page, all eight:

| Page | Variable |
|---|---|
| finances.html | `ATLAS_FINANCES_PAGE` |
| cinema.html | `ATLAS_CINEMA_PAGE` |
| crm.html | `ATLAS_CRM_PAGE` |
| calendar.html | `ATLAS_CALENDAR_PAGE` |
| kanban.html | `ATLAS_BOARD_PAGE` |
| canvas.html | `ATLAS_CANVAS_PAGE` |
| chat.html | `ATLAS_CHAT_PAGE` |
| hud.html | `ATLAS_HUD_PAGE` |

`ATLAS_HUD_PAGE` also accepts a bundled page *name* rather than a path, which
swaps the HUD's visual for another shipped page. Only the path form is watched —
a file inside the bundle cannot change while the app runs.

Watching survives an editor's save-and-rename, and reloads by loading the file
again rather than calling `reload()`, which on a `file://` URL can serve
WebKit's cached copy — indistinguishable from the change not appearing.

Without the variable there is no file to watch and nothing is armed.

Run the bundled binary rather than `swift run` when you need real data: a bare
executable has no bundle identifier, and WebKit gives it a different, empty
storage container.

## Testing

```bash
swift test
swift test --filter PageBootTests
```

`PageBootTests` is the one worth knowing about. It loads each bundled page in a
real `WKWebView` and checks it actually wired itself up — that the page exposes
its API, renders the payload the bridge sends, escapes user text rather than
executing it, and lays out correctly at several widths. Static HTML always
*renders*; only booting it catches a page that came up inert.

## Known issues

- `swift run AtlasApp` works, but surfaces that persist through WebKit see an
  empty store, because the bare executable has no bundle identifier. Use
  `dist/Atlas.app/Contents/MacOS/AtlasApp` when data matters.

## Licence

MIT. See [`LICENSE`](LICENSE).

Bundled third-party code keeps its own licence: three.js (MIT) under
`Sources/AtlasCore/Vendor/three`, and the HUD particle field, which is
["Celestial Transmutation" by VoXelo](https://codepen.io/VoXelo/pen/yygKOVy),
vendored with one line changed and credited in its header.

## Status

Under active development. Interfaces move.
