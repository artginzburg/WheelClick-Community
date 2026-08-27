<div align="center">

# WheelClick

**The middle click your Mac never had.** Three-finger click or tap, fn+click, or Force Click — on the trackpad and the Magic Mouse.

[![Latest release](https://img.shields.io/github/v/release/artginzburg/WheelClick-Community?label=latest&color=0071e3)](https://github.com/artginzburg/WheelClick-Community/releases/latest)
[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-lightgrey)](https://wheelclick.app/?ref=community-readme)

### [→ wheelclick.app](https://wheelclick.app/?ref=community-readme)

*What it does, what it costs, and every gesture it adds — the site explains it properly.*

</div>

---

## Install

```sh
brew install artginzburg/tap/wheelclick
```

Or [download the .dmg](https://github.com/artginzburg/WheelClick-Community/releases/latest/download/WheelClick.dmg) — notarized, signed, and the same build.

Three-finger click and three-finger tap are **free forever**, with no account and no countdown. A licence unlocks what WheelClick adds on top: fn+click, Force Click, the Magic Mouse gestures, middle-drag for CAD, autoscroll and per-app rules.

## What's here — and what isn't

WheelClick's source is closed, so **there is no app code in this repository**. What lives here is everything that benefits from being public:

- **Releases** — every version, signed and notarized. The Homebrew cask installs from here.
- **Issues** — bugs, read by the person who writes the app.
- **Discussions** — the gestures you wish existed, and anything you're trying to work out.
- **Localizations**, once there are any to keep.

## Closed app, open parts

When a piece of WheelClick turns out to be useful beyond WheelClick, it gets extracted and open-sourced instead of staying buried in the app:

- **[Tiptoe](https://github.com/artginzburg/Tiptoe)** — the Swift package WheelClick updates itself through. It holds an update until the Mac is quiet, then installs it with no UI — over Sparkle or GitHub Releases. MIT, ready for your app too.

## Something broken, or missing?

**Broken** — [open an issue](https://github.com/artginzburg/WheelClick-Community/issues/new). Please say which macOS version and which Mac; trackpad behaviour differs more between models than it has any right to.

**Missing** — [start a discussion](https://github.com/artginzburg/WheelClick-Community/discussions/new/choose): *Ideas* for a gesture or a feature you want, *Q&A* for anything you're trying to figure out. Requests live there rather than in Issues so that an open issue always means something is actually wrong.

## Watching this repo does something concrete

Homebrew's own cask index accepts a third-party app once its repository clears **75 stars or 30 watchers**. WheelClick has one of each today.

That is the entire difference between

```sh
brew install artginzburg/tap/wheelclick    # today
brew install wheelclick                    # after
```

so if the app earned it, the Watch button is the most useful thing you can click here.

## Coming from MiddleClick?

WheelClick is its successor, by the same author — and the middle click MiddleClick gave you, three-finger click and three-finger tap, is free in WheelClick permanently. MiddleClick itself stays where it is: free, GPL-3.0, still on Homebrew, nothing removed.

The full version of that, in writing and dated: **[what stays free →](https://wheelclick.app/middleclick-vs-wheelclick?ref=community-readme)**
