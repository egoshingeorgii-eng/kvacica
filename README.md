# Kvačica

Learn Serbian words (Latin script) from Russian, right from your Mac's menu bar.

> The words are taught from Russian, so Kvačica is for Russian speakers. The app itself speaks English and Russian, following your Mac's language.

## Download

**[Download Kvačica for Mac](https://github.com/egoshingeorgii-eng/kvacica/releases/latest/download/Kvacica.dmg)**: open the file and drag Kvačica into Applications. Needs macOS 14 Sonoma or later, on any Mac (Apple silicon or Intel).

On first launch Kvačica asks your level and gives you the built-in words up to it. Then it lives in the menu bar: click its icon or press ⌥⌘S from anywhere.

Kvačica keeps itself up to date: it checks for a new version once a day and offers to install it, or you can check any time from the menu bar icon → Check for Updates…. Your words and progress stay. (If you have version 1.0, download the new version once by hand; it updates itself from then on.)

## What it does

- **Brings words back just before you'd forget them**, so each one sticks with as few repeats as possible.
- **Lessons by topic.** About 860 built-in words from A1 to B1: food, travel, health, home, work and more, with word forms and example sentences. Take as many lessons a day as you like.
- **Gets harder as you learn.** A new word starts with picking the right answer, then you build it from letters, then type it or say it.
- **Keyboard-first.** Everything works from the keyboard, and Serbian letters (č, ć, š, ž, đ) type even in the Russian layout.
- **Answer out loud.** Press Tab and say the word: Kvačica listens with the Mac's own speech recognition in Serbian (or Croatian, where macOS has no Serbian).
- **Words from your chat.** Ask Claude or ChatGPT to "add the words from this text to Kvačica", and they arrive in your deck with forms and examples.
- **Widgets** for your desktop: how many words to review, and a word to look at.

## Adding words from a chat

1. In Kvačica: Settings → *Words from chat* → *Create my link*.
2. Add that link to your chat as a connector, named Kvačica:
   - **Claude:** Settings → Connectors → Add custom connector.
   - **ChatGPT:** Settings → Apps & Connectors → turn on developer mode → create a connector.
3. Ask, for example, "Give me 20 words for a visit to the doctor and add them to Kvačica".

It works from your phone too, even when the Mac is off: the words wait and arrive the next time Kvačica is open. Anyone with your link can add words to your deck, so keep it to yourself.

You can also add a word yourself with **+** on the Words tab, or import a list of words as a file ([format](docs/deck-format.md)).

## Your data

Your words and progress stay on your Mac, in `~/Library/Application Support/Srpski`. Only if you create a chat link, the words you add from a chat pass through Kvačica's small cloud service, which also keeps a list of your words so the chat knows what you already have. [Privacy policy](https://srpski.egoshin.workers.dev/privacy).

## Uninstall

Quit Kvačica (menu bar icon → Quit Kvačica) and move it from Applications to the Trash. To remove your words as well, also delete the folder `~/Library/Application Support/Srpski`.

## For developers

Kvačica is a SwiftUI app. You can build it from source with Xcode 26 or later: `./scripts/install.sh` builds and installs it ([AGENTS.md](AGENTS.md) has the details and options). `./scripts/install-mcp.sh` adds a local MCP server for Claude Desktop. The study logic is in `Packages/SrbCore` (`swift test`).

There is also an iPhone app with iCloud sync between the two; it isn't part of this repo. This repo is the Mac part of a private one, published from time to time, so pull requests are welcome but get applied by hand.

## License

[MIT](LICENSE).
