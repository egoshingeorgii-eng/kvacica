# Kvačica

A macOS menu-bar app for learning Serbian vocabulary (Latin script) **from Russian**. Spaced repetition on FSRS-6, answers typed or spoken, everything from the keyboard.

> Prompts and translations are in Russian: the app is made for Russian speakers. The interface itself is in English and Russian (it follows the system language).

## What it does

- **Two things to study.** *Review* brings back words just before you'd forget them. A *Lesson* takes N new words (10 by default) from a topic you pick and drills them until they stick. No daily limits: take as many lessons as you like.
- **Exercises that grow with the word.** A new word starts with multiple choice, true/false and matching pairs, moves on to building it from letter tiles, and ends with typing or saying it whole. Words that are easy to confuse (lekar / lekarka) are mixed into the same lesson, never back to back.
- **Sentences and forms.** Known words come back in example sentences with a gap ("Nema \_\_\_.") and as forms from their tables: cases, conjugations, comparatives. Forms you got wrong recently come up more often.
- **About 860 built-in words**, A1 to B1, in 18 topics (Food & Drink, City & Travel, Body & Health…), each with forms and example sentences. The first launch asks your level; the rest of the library is under *New words*.
- **Keyboard-first.** Serbian letters sit where they are on a Serbian keyboard, in any layout, even Russian: `;` č, `'` ć, `[` š, `]` đ, `\` ž (Shift for capitals). `?` means "I don't know", Enter goes on, Esc leaves a lesson. Missing diacritics are forgiven by default (a setting makes them strict).
- **Dictation.** Tap Tab (or the mic button), say the answer; a pause stops listening and checks it.
- **Lives in the menu bar.** ⌥⌘S opens it from anywhere. The menu bar can also show a new word every few minutes.
- **Words from a chat.** Ask Claude or ChatGPT "add the words from this text to Kvačica" and they show up in your deck with forms and examples (see [Adding words](#adding-words)).
- **Widgets** for "how many to review" and "a word" (only in a build signed with a team, see below).

## Install

You need a Mac with **macOS 14 Sonoma or later** and **Xcode 26 or later** (free in the App Store; open it once after installing). There is no prebuilt download yet, so the app is built from source. It takes a few minutes, mostly the first build.

```bash
git clone https://github.com/egoshingeorgii-eng/kvacica.git
cd kvacica
./scripts/install.sh
```

The script installs [XcodeGen](https://github.com/yonaskolb/XcodeGen) with Homebrew if it's missing, builds the app, puts it in `/Applications/Kvačica.app` (or `~/Applications` if `/Applications` isn't writable) and opens it.

| Option | What it does |
|---|---|
| `--signed` | Signs with your *Apple Development* certificate instead of ad-hoc, which turns on the widgets. A free Apple ID is enough: Xcode → Settings → Accounts → add it, then *Manage Certificates… → + → Apple Development*. |
| `--mcp` | Also installs the local MCP server for Claude Desktop (see below). |
| `--no-open` | Installs without opening the app. |
| `--build-only` | Builds and signs into `build/`, doesn't install. |

No Apple developer account is needed. By default the app is signed to run locally (ad-hoc): everything works except the widgets, because macOS shares a folder between an app and its widget only for apps signed by a team.

To update, `git pull` and run `./scripts/install.sh` again. Your words and progress stay.

### Install with an AI agent

Point Claude Code, Codex or another coding agent at this repo:

> Clone https://github.com/egoshingeorgii-eng/kvacica and install the app following its AGENTS.md.

[AGENTS.md](AGENTS.md) tells the agent what to check, what to run and how to fix the usual problems.

### First launch

A welcome window asks your level and puts the built-in words up to it into your deck. The app then sits in the menu bar; the main window is under its icon or ⌥⌘S. When you first use dictation, macOS asks for the microphone and speech recognition. An ad-hoc build is a new app to macOS each time it's rebuilt, so after an update it may ask again.

## Adding words

**From a chat (Claude or ChatGPT).** Settings → *Words from chat* → *Create my link*. Add the link as a custom connector: in Claude, Settings → Connectors → Add custom connector; in ChatGPT, Settings → Apps & Connectors → developer mode → create a connector. Then ask, for example, "Add the words from this text to Kvačica" or "Give me 20 words for the doctor's". This works from your phone too, while the Mac is off: the words wait in the cloud and come in the next time the app is open. Anyone with the link can add words to your deck, so keep it to yourself.

**From Claude Desktop, locally.** `./scripts/install-mcp.sh` (or `install.sh --mcp`) builds a small MCP server and registers it in Claude Desktop's config. Quit Claude Desktop (⌘Q) first: while running, it can overwrite its config. The server has `add_words`, `delete_words`, `add_examples`, `add_forms`, `list_words` and `get_mistakes`. It doesn't touch the database: it drops decks into `~/Library/Application Support/Srpski/Inbox/`, and the app imports them right away.

**By hand.** **+** on the Words tab, or paste a deck in JSON with ⌘⇧V (File → Paste Deck; a ```` ```json ```` fence and text around it are ignored), or import a file with ⌘O.

### Deck format

```json
{
  "version": 1,
  "notes": [
    {"id": "stric", "kind": "word", "cue": "дядя (брат отца)", "answer": "stric",
     "level": "A1", "topic": "Family", "cluster": "uncles-aunts"},
    {"id": "sad", "kind": "word", "cue": "сейчас", "answer": "sad", "accept": ["sada"]},
    {"id": "hleb", "kind": "word", "cue": "хлеб", "answer": "hleb",
     "forms": {"gen.sg": "hleba", "ins.sg": "hlebom"},
     "examples": [{"sr": "Kupio sam *hleba* u pekari.", "ru": "Я купил хлеба в пекарне."}]}
  ]
}
```

| Field | Required | Meaning |
|---|---|---|
| `id` | yes | Stable unique id. Importing a note with an existing id updates it and keeps its progress. |
| `kind` | yes | `word` and `phrase` are studied both ways; `form` and `sentence` only Russian → Serbian. |
| `cue` | yes | The prompt, in Russian. |
| `answer` | yes | The Serbian answer, Latin script with č ć š ž đ. |
| `accept` | no | Other correct answers. |
| `info` | no | A note shown after answering. |
| `level` | no | `A1` … `C2`, default `A1`. |
| `topic` | no | One of the built-in topics (Phrases, Small words, Verbs, People & Jobs, Character & Feelings, Family, Body & Health, Food & Drink, Clothes, Shopping, Home, City & Travel, Nature & Weather, Free time, Language & Study, Time, Numbers & Colors, Opinions & Ideas, Grammar, Sentences). |
| `cluster` | no | Words that are easy to confuse share a cluster (2–6 words). |
| `forms` | no | Form table: nouns `nom.sg` … `loc.pl`; adjectives `f.gen`, `m.loc`, `comp`, `sup`; verbs `pres.1sg` … `pres.3pl`, `past.m.sg` … `past.n.pl`, `imp.2sg`, `imp.1pl`, `imp.2pl`. A second spelling after `/`. |
| `examples` | no | 1–5 sentences with the word marked by asterisks, exactly one per sentence. |

At the top level, `"delete": ["id", …]` removes notes with their history, `"examples": {"id": [...]}` and `"forms": {"id": {...}}` add sentences or forms to existing notes without touching anything else.

## Your data

Everything lives in `~/Library/Application Support/Srpski/`: the database (`Srpski.store`), the MCP inbox and a few files the app keeps up to date for the MCP server (`notes.json`, `tutor-report.md`). Nothing leaves your Mac unless you create a chat link: then the words you add from a chat pass through the app's small cloud service (srpski.egoshin.workers.dev), and the app sends it the list of your words so the chat can see what you already have. [Privacy](https://srpski.egoshin.workers.dev/privacy).

## Uninstall

Quit Kvačica (menu bar icon → Quit), move `/Applications/Kvačica.app` to the Trash, and if you want your words gone too, `~/Library/Application Support/Srpski`. If you installed the MCP server, remove the `srpski` entry from `~/Library/Application Support/Claude/claude_desktop_config.json`.

## Not in this repo

Kvačica also has an iPhone app with iCloud sync between the two. That part is not open source; a build from this repo studies on its own Mac (the Settings section about iCloud shows it as off).

## Development

```bash
xcodegen generate && open Srpski.xcodeproj   # scheme Srpski, Run
cd Packages/SrbCore && swift test             # the study logic
```

- `Packages/SrbCore` — everything without UI: SwiftData models, the FSRS scheduler, lesson and exercise picking, grading, deck import, statistics. `Sources/SrpskiMCP` is the MCP server (stdio, no dependencies).
- `App` — the SwiftUI app: windows, menu bar, settings, speech and dictation.
- `Widget` — the WidgetKit extension; the app writes `widget.json` to the shared app group after every change.
- `Shared` — strings (English keys, Russian in `Localizable.xcstrings`) and the widget's data model.

The Xcode project is generated from `project.yml` and isn't kept in git. Builds from Xcode are signed ad-hoc; use `./scripts/install.sh --signed` for the widgets.

This repo is a copy of the Mac part of a private one, published from time to time, so pull requests are welcome but get applied by hand.

## License

[MIT](LICENSE).
