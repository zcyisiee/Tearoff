<img src=".github/assets/Tearoff.svg" alt="Tearoff" width="128" align="left" />

<b><font>Tearoff</font></b>

 Jot down thoughts, grab your files.

<br clear="all" />

<p align="center">
  <a href="README.md">简体中文</a> · <b>English</b>
</p>

<p align="center">
  <a href="https://github.com/zcyisiee/Tearoff/releases"><img src="https://img.shields.io/github/v/release/zcyisiee/Tearoff?label=Latest%20Release&color=green" alt="Latest Release" /></a>
  <a href="https://github.com/zcyisiee/Tearoff/releases"><img src="https://img.shields.io/github/downloads/zcyisiee/Tearoff/total?color=green" alt="Total Downloads" /></a>
  <br />
  <img src="https://img.shields.io/badge/Swift-6.2-orange?logo=swift" alt="Swift" />
  <img src="https://img.shields.io/badge/macOS-15.7+-black?logo=apple" alt="macOS" />
  <a href="LICENSE"><img src="https://img.shields.io/github/license/zcyisiee/Tearoff?color=blue" alt="License" /></a>
</p>

**Tearoff** aims to bring back the feel of jotting things down on paper. Slide your mouse to the screen edge to summon it; move away and it tucks itself away. Grab it, use it, done. If you need it to stay put for a while, click the pin in the top-right corner.

The core object in Tearoff is the card. A **file card** maps to a markdown file. A **folder card** lets you browse and work with files right inside the panel. There's also a special kind of file card: the **Daily card** — one per day, for planning that day's to-dos. Use cards as a schedule, a memo pad, a journal, or a scratch pad. I've tuned the schedule use case specifically: click a to-do (`- [ ]`) right on the card to check or uncheck it. Very handy.

<p align="center">
  <img alt="Tearoff Card View" src=".github/assets/screenshot-cards.gif" width="800" />
</p>

---

## Installation

**Homebrew** (recommended):

```bash
brew tap zcyisiee/tap
brew install --cask tearoff
```

Or download the latest `.dmg` from [Releases](https://github.com/zcyisiee/Tearoff/releases) and drag it into Applications. The app is not signed, so with a manual install, run this in Terminal before the first launch:

```bash
xattr -cr /Applications/Tearoff.app
```

---

## Why I Built Tearoff

Before I switched to CS, my desk was always piled with reference books and scratch paper. When an idea hit, I'd tear off a sheet and write it down. It never interrupted what I was doing, and that felt freeing.

On a computer, jotting something down means opening an app, creating a file, naming it. Editors like Typora and Obsidian are excellent, but they're too "formal" — every time you open one, it takes over your workspace and forces you into another context. For quick, spontaneous notes, that kind of intrusive interaction isn't friendly. Worse, the constant context switching distracts me, and I end up in decision paralysis 🥲

Tearoff's goal is to bring the "tear off a sheet and write" feeling to the screen. Slide to the edge and start writing; click elsewhere and it tucks away — never interrupting whatever you're working on.

---

## Features

- **Non-intrusive**: Slides out from the screen edge, disappears when you click elsewhere. Doesn't interrupt your work or occupy the Dock and desktop.
- **Frictionless**: From "I want to note something" to "it's written down" — no creating files, picking paths, or naming things in between.
- **Daily card**: Automatically generates a card named after the current date, dedicated to that day's to-dos. Check items off as you go and see the day at a glance.
- **Folder card**: Put your frequently used folders in a card — browse, open, rename, and drag files in and out, all without opening Finder.
- **ADHD-friendly**: Doesn't steal focus, doesn't pop up dialogs, doesn't ask you to leave your workspace. Write and go, come back anytime.
- **Local storage**: Notes are plain `.md` files on disk. No proprietary format, no account. Open them with any editor, sync and back up however you like.
- **Beautiful UI**: Native SwiftUI interface with carefully tuned colors, animations, and gestures — designed to feel like a built-in part of macOS.

---

## How It's Organized

Tearoff has just two levels of interface: the main view and the editor view.

The core object of the main view is the card, which currently comes in two kinds: file cards and folder cards. A file card maps to a markdown file; a folder card maps to a folder on disk. The Daily card is a special file card — it maps to the markdown file named after the current date.

Each card has three states. By default it's in card state, showing a content preview. Click the blank area to the right of the title to enter quick-edit state, where you can write a few lines in place. Double-click the same area to enter the editor view, for longer writing.

The main view is divided into three zones from top to bottom: the pinned zone at the top, holding the cards you've pinned manually; the Daily zone in the middle, which always shows today's Daily card; and the timeline at the bottom, where the remaining cards are arranged by time.

Once you're in the editor view, Tearoff behaves like a full-featured Markdown editor: WYSIWYG rendering, code highlighting, and LaTeX formula rendering are all built in.

---

## Quick Start

Slide your mouse to the screen edge to summon Tearoff; move away and it hides automatically.

The top row holds folder tabs; on the right are search, new folder, new card, and settings. The pin button on the far right keeps the panel open — by default Tearoff auto-hides when your mouse leaves, but pinning it keeps the panel expanded, handy for copy-pasting back and forth between windows. Click the pin again to restore auto-hide.

Click a to-do item directly on a card to check or uncheck it — no need to enter the editor. Right-click empty space (or right-click the "New Card" button) to create a folder card, then drag a frequently used folder onto the card's top bar to bookmark it.

<p align="center">
  <img alt="Tearoff Editor" src=".github/assets/screenshot-editor.png" width="800" />
</p>

---

## What's Next

The focus going forward is the editor view's user experience and features — the goal is to match Typora's writing feel. Planned work includes visual table editing, image drag-and-drop with preview, a more complete keyboard shortcut system, and multi-window and multi-monitor support.

---

## Known Issues

Folder cards currently have one unresolved bug: if you drag a folder too quickly, the card may go blank and freeze. When this happens, drag the folder card to a different position and it recovers on its own. I'm working on a fix.

---

## Tech Stack

Swift 6.2 + SwiftUI. The editor is built on TextKit 2, with no dependency on WebKit or JavaScript. Beyond functionality, a significant amount of effort went into animation curves, gesture response, and transition effects — these details determine whether the app feels right in hand.

For architecture overview, source tree, key patterns, and dev environment setup, see [CONTRIBUTING.md](CONTRIBUTING.md).

---

## Acknowledgements

Thanks to [EdgeMark](https://github.com/dev-vasu/EdgeMark) for the inspiration — this project was built on top of EdgeMark. Also thanks to [SideNotes](https://www.apptorium.com/sidenotes), which nailed the edge-triggered interaction, though it's closed-source and paid.

Tearoff also builds upon these open-source projects:

| Project | License | Description |
| --- | --- | --- |
| [swift-markdown-engine](https://github.com/nodes-app/swift-markdown-engine) | Apache 2.0 | WYSIWYG Markdown editor based on TextKit 2, powering the entire editing experience |
| [HighlighterSwift](https://github.com/smittytone/HighlighterSwift) | MIT | Syntax highlighting for code blocks |
| [SwiftMath](https://github.com/mgriebling/SwiftMath) | MIT | LaTeX formula rendering |
| [SwiftFormat](https://github.com/nicklockwood/SwiftFormat) | MIT | Code formatting in the build pipeline |

---

## License

This project is licensed under the [GNU General Public License v3.0](LICENSE).
