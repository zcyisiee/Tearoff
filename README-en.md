![Tearoff](.github/assets/Tearoff.svg)

**Tearoff**

 A sticky note app for jotting things down on the fly.

[简体中文](README.md) · **English**

![Latest Release](https://img.shields.io/github/v/release/zcyisiee/Tearoff?label=Latest%20Release&color=green)![Total Downloads](https://img.shields.io/github/downloads/zcyisiee/Tearoff/total?color=green)  
![Swift](https://img.shields.io/badge/Swift-6.2-orange?logo=swift)![macOS](https://img.shields.io/badge/macOS-15.7+-black?logo=apple)![License](https://img.shields.io/github/license/zcyisiee/Tearoff?color=blue)

**Tearoff's goal**: bring back the feel of scribbling on a torn-off piece of paper. Its biggest advantage is convenience — just slide your mouse to the screen edge to summon Tearoff. Each card is a markdown file — single-click to edit in place, double-click to open the full editor.

You can use cards as a schedule, memo pad, journal, or scratch pad. I've optimized for the schedule use case — click a to-do (`- [ ]`) directly on a card to check or uncheck it.

![Tearoff Card View](.github/assets/screenshot-cards.png)

---



## Installation

Download the latest `.dmg` from [Releases](https://github.com/zcyisiee/Tearoff/releases) and drag it into Applications. The app is not signed, so before the first launch, run this in Terminal:

```bash
xattr -cr /Applications/Tearoff.app
```

---



## Why I Built Tearoff

Before I switched to CS, my desk was always piled with books and paper. When an idea hit, I'd just tear off a sheet and write it down. It never interrupted what I was doing — and that felt freeing.

On a computer, jotting something down means opening an app, creating a file, picking a folder, naming it. Editors like Typora and Obsidian are great, but they're too "formal" — every time you open one, it takes over your workspace and forces you into a different context. For quick, spontaneous notes, that kind of intrusive interaction isn't friendly at all.

Tearoff is my attempt to bring the "tear off a sheet and write" feeling to the screen. Slide to the edge and start writing; click elsewhere and it tucks away — never interrupting whatever you're working on.

---



## Features

- **Non-intrusive**: Slides out from the screen edge, disappears when you click elsewhere. Doesn't take over your workflow or occupy the Dock.
- **Frictionless**: From "I want to note something" to "it's written down" — no creating files, picking paths, or naming things.
- **ADHD-friendly**: Doesn't steal focus, doesn't pop up dialogs, doesn't ask you to leave your workspace. Write and go, come back anytime.
- **Local storage**: Notes are plain `.md` files on disk. No proprietary format, no account. Open them with any editor, sync and back up however you like.
- **Beautiful UI**: Native SwiftUI interface with carefully tuned colors, animations, and gestures — designed to feel like a built-in part of macOS.

---



## Quick Start

Tearoff has just two levels of interface.

The **main view** is a card list — each card corresponds to a markdown file and shows a content preview.

- Click the blank area **to the right of a card's title** to enter **quick edit** — an inline input field, great for a one-liner.
- Double-click **to the right of the title** to open the **editor** for longer writing.
- Click a to-do item directly on a card to check or uncheck it without entering the editor — this is my optimization for the schedule use case.
- Drag the left edge of a card to adjust Tearoff's width.
- Click the pin at the top to keep the panel open.

The top row has folder tabs; on the right are search, new folder, new card, and settings. The **pin** button on the far right keeps the panel open — by default Tearoff auto-hides when your mouse leaves, but pinning it lets you copy-paste between windows. Click the pin again to restore auto-hide.

![Tearoff Editor](.github/assets/screenshot-editor.png)

Tearoff also provides a rich set of keyboard shortcuts covering both app-level and Markdown shortcuts. For example, `Cmd + N` creates a new note, `Cmd + B` bolds text, and so on. See Settings for the full list.

---



## TODO

The current focus is on the editor experience — the goal is to match Typora's writing feel. Specific directions:

- Visual table editing
- Image drag-and-drop with preview
- A more complete keyboard shortcut system
- Multi-window / multi-monitor support

---



## Tech Stack

Swift 6.2 + SwiftUI. The editor is built on TextKit 2, with no dependency on WebKit or JavaScript. Beyond functionality, a significant amount of effort went into animation curves, gesture response, and transition effects — these details determine whether the app feels "right."

For architecture overview, source tree, key patterns, and dev environment setup, see [CONTRIBUTING.md](CONTRIBUTING.md).

---



## Acknowledgements

Thanks to [EdgeMark](https://github.com/dev-vasu/EdgeMark) for the inspiration — this project was built on top of EdgeMark. Also thanks to [SideNotes](https://www.apptorium.com/sidenotes), which nailed the edge-triggered interaction, though it's closed-source and paid.

Tearoff also builds upon these open-source projects:


| Project                                                                     | License    | Description                                                                    |
| --------------------------------------------------------------------------- | ---------- | ------------------------------------------------------------------------------ |
| [swift-markdown-engine](https://github.com/nodes-app/swift-markdown-engine) | Apache 2.0 | WYSIWYG Markdown editor based on TextKit 2, powering the entire editing experience |
| [HighlighterSwift](https://github.com/smittytone/HighlighterSwift)          | MIT        | Syntax highlighting for code blocks                                            |
| [SwiftMath](https://github.com/mgriebling/SwiftMath)                        | MIT        | LaTeX formula rendering                                                        |
| [SwiftFormat](https://github.com/nicklockwood/SwiftFormat)                  | MIT        | Code formatting in the build pipeline                                          |


---



## License

This project is licensed under the [GNU General Public License v3.0](LICENSE).
