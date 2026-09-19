# Setting up ATLAS


ATLAS is a personal command centre for macOS. It runs entirely on your own
machine: your notes, calendar, money, contacts and chat transcripts stay in
encrypted databases in your home folder and are never uploaded anywhere.

It is a Swift package you build yourself. There is no installer and no signed
release — you clone it, build it, and it becomes an app in your Applications
folder.

---

## What you need

**Required**

- A Mac running **macOS 14 (Sonoma) or later**
- **Xcode** or the Command Line Tools — `xcode-select --install`

That is genuinely all that is required. Everything below is optional and turns
on one feature each.

**Optional, per feature**

| You want | You need |
|---|---|
| Assistant (chat) | A [Featherless](https://featherless.ai) API key |
| Cinema artwork and metadata | A free [TMDB](https://www.themoviedb.org/settings/api) API key |
| Cinema playback | A [Jellyfin](https://jellyfin.org) server with your own media |
| Notes and search | [Obsidian](https://obsidian.md) with at least one vault |
| Calendar and tasks | Nothing — it uses the Calendar and Reminders already on your Mac |
| Voice / Presence | Python 3 and an MLX TTS model (see §6) |

Nothing is required for the app to launch. Anything you skip shows an empty
state rather than an error.

---

## 1. Build it

```bash
git clone <repository-url>
cd atlas
swift build
scripts/build_app.sh
```

The last line produces `dist/Atlas.app`. Drag it to `/Applications`, or run it
in place:

```bash
open dist/Atlas.app
```

**Run the app bundle, not `swift run AtlasApp`.** Several screens are web pages
inside the app, and WebKit gives them storage based on the app's bundle
identifier. A bare executable has no bundle identifier, so those screens open
against an empty database and look like your data vanished. Use `swift run` for
quick code checks only.

### About code signing

`build_app.sh` signs the app with the first signing identity it finds, and falls
back to ad-hoc signing if you have none. Ad-hoc works, with one annoyance:
macOS treats every rebuild as a brand-new app, so it re-asks for folder access
and your login password for the Keychain after each build.

If you have an Apple Developer certificate, that stops. Point the script at it:

```bash
ATLAS_SIGN_IDENTITY="Apple Development: you@example.com (XXXXXXXXXX)" scripts/build_app.sh
```

---

## 2. First run

On first launch macOS will ask for **Calendar** and **Reminders** access. Both
are optional; decline and those tabs stay empty.

Then open **Settings** and fill in whatever you want to use. Everything starts
blank — ATLAS ships knowing nothing about your machine, deliberately.

---

## 3. Settings, one by one

Everything in this section lives under **Workspace · Folders on this Mac** in
Settings, except where noted.

### Project folders

Folders ATLAS scans for git repositories. Click **Add folder…** and pick your
code directory — `~/Developer`, `~/Code`, whatever you use. ATLAS walks it,
finds git repos, and reads each one's branch and status. It only reads.

Add nothing and the Projects tab stays empty. That is the default.

### Companion scope — read this one properly

The Companion can run shell commands and read files for you. It is guarded two
ways:

**One boundary guards it: a list of folders.** Nothing outside them is read and
nothing outside them is run. Paths are canonicalised first, so `../` cannot walk
out of a permitted folder, and a sibling named `Documents-evil` does not match an
allowed `Documents`.

**That list starts empty, which means the Companion can do nothing at all.**
That is intentional, and it is the only lock. Commands themselves are not
filtered — inside a permitted folder, whatever the Companion is handed runs.

So: add only folders you are genuinely willing to have an agent work in. Do not
add your home directory.

### Assistant

Direct chat against [Featherless](https://featherless.ai), which hosts open
models, including uncensored ones. Paste your API key in Settings; it goes
straight to the macOS Keychain and is never written to disk in the clear.

Pick a model, and optionally write a persona — the standing instruction the
model gets before every conversation. Transcripts are stored encrypted and never
leave your Mac.

This talks to Featherless directly, with no proxy in between. Your prompts go to
them; read their privacy policy if that matters to you.

### Cinema

Three separate things, each optional:

- **TMDB key** — artwork, cast, episode lists, trailers. Free, takes two minutes
  to get. Without it Cinema works but looks bare.
- **Jellyfin** — your own media server, your own files. Enter the server URL and
  sign in. This is the playback path.
- **Archive.org** — public-domain titles, needs nothing.

### Notes

ATLAS reads Obsidian's own vault registry, so if you use Obsidian your vaults
appear by themselves. Nothing to configure. Read-only apart from journal
entries, which it writes as ordinary Markdown files.

### Hermes (optional, probably skip)

An integration with a separate self-hosted agent runtime. Two fields: a gateway
URL and a path to the `hermes` binary. Leave both blank — which is the default —
and the integration stays off. You do not need it.

### Voice

Two fields, both blank by default: a Python interpreter and a downloaded MLX
model directory. Voice stays off until both point at something real. See §6.

---

## 4. Where your data lives

```
~/Library/Application Support/ATLAS/
    chat.db         Assistant transcripts
    crm.db          Companies, contacts, opportunities
    expenses.db     Bills, spend, credit accounts
    cinema.db       Library, playlists, watch state
```

All four are **SQLCipher-encrypted**. The encryption keys are generated on first
run and stored in your login Keychain — not in the files, not in the repo, not
in any config file.

Practical consequences:

- **Back up that folder** and you have everything.
- **A backup is useless without the Keychain item.** Copying the `.db` files to
  another Mac gets you an encrypted blob you cannot open. Export from inside the
  app if you want portable data.
- **Delete the Keychain items and the data is gone.** There is no recovery path
  and that is the point.

API keys live in the same Keychain under `atlas.featherless.api.key` and
`atlas.tmdb.key`.

---

## 5. How it is built, in one page

Worth knowing before you change anything.

**A Swift package, three products:**

- `AtlasCore` — the library. State, stores, integrations, the security model.
- `AtlasApp` — the SwiftUI app.
- `atlasctl` — a command-line helper that ships inside the app bundle so it
  signs with the same identity.

**Some screens are web pages, not SwiftUI.** Calendar, Canvas, Chat, Cinema,
CRM, Finances, HUD and the Board are HTML in a `WKWebView`. They are the parts
that change most, and HTML iterates faster than SwiftUI.

Each of those screens has three layers, and the split is strict:

1. **The page** owns what is on screen. It never touches storage.
2. **A bridge** owns everything that touches the database. The page sends a
   named action from a fixed set; anything that does not decode is dropped, and
   anything that does is validated again in Swift before a row is written.
3. **A store** is the encrypted database.

Two rules the pages follow, both learned painfully:

- **Money never goes through JavaScript arithmetic.** Amounts cross the bridge
  as whole cents with a pre-formatted string beside them. What you type goes
  back as *text* for Swift to parse. `Number("21.28") * 100` is
  `2127.9999999999998`.
- **Nothing important goes in `localStorage`.** WebKit partitions it by bundle
  identifier, so the same page run a different way gets a different, empty
  container. Page state belongs in a store.

### Editing a page

Two ways.

**In a browser** — fastest for layout and styling, reloads on save:

```bash
python3 scripts/dev_pages.py   # http://localhost:8787
```

Serves every page with fake data and a mocked bridge. Writes are acknowledged
and thrown away, and video embeds refuse an unknown origin, so playback and
saving still need the real app.

**In the app, against your real data** — point the app at the repo's copy of the
page:

```bash
ATLAS_FINANCES_PAGE=$PWD/Sources/AtlasCore/Resources/finances.html \
  dist/Atlas.app/Contents/MacOS/AtlasApp
```

**The page reloads itself when you save it.** No rebuild, no restart. One
variable per page:

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

Without the variable there is no file to watch and live reload is off.

### Tests

```bash
swift test
swift test --filter PageBootTests
```

`PageBootTests` is the one that matters. It loads every bundled page in a real
`WKWebView` and checks it actually came up — that it exposes its API, renders
what the bridge sent, escapes user text instead of executing it, and lays out at
several widths. Static HTML always *renders*; only booting it catches a page
that came up dead.

---

## 6. Voice (advanced, skip on first pass)

The Presence layer speaks replies using a local MLX text-to-speech model. It
needs a Python environment and a downloaded model, and it is off until you point
Settings at both. Everything else in ATLAS works without it.

---

## 7. Troubleshooting

**My data disappeared.** You probably ran `swift run AtlasApp` instead of the app
bundle. No bundle identifier means a different WebKit storage container. Run
`dist/Atlas.app/Contents/MacOS/AtlasApp`.

**macOS asks for my Keychain password after every build.** You are ad-hoc
signing, so every build looks like a new app. Set `ATLAS_SIGN_IDENTITY` (§1).

**A page edit does nothing.** The env var for that page is not set, so nothing
is being watched. And reloads load the file fresh rather than calling
`reload()`, because on a `file://` URL WebKit will happily serve you its cached
copy — which looks exactly like your change not working.

**The Companion refuses everything.** Its folder list is empty until you fill it
in, and an empty list permits nothing. Working as designed — add a folder in
Settings.

**Projects is empty.** Same reason: no search folder configured yet.

---

## What it does not do

No telemetry. No analytics. No crash reporting. No account, no sign-in, no sync.
It makes network calls only to services you configure yourself — Featherless if
you set a key, TMDB if you set a key, your own Jellyfin server, Archive.org.
Nothing else leaves the machine.
