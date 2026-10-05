# Localization

`Localizable.xcstrings` is every word of WheelClick's interface — menus, windows, the welcome
tour, the Buy window — in English and 15 more languages: German, Spanish (Spain and Latin
America), French, Italian, Japanese, Korean, Polish, Portuguese (Brazil), Russian, Turkish,
Ukrainian, Vietnamese and Chinese (Simplified and Traditional). The app builds straight from
this file, so a fix merged here ships in the next release.

The translations were written with AI assistance and then reviewed the same way, against
Apple's own wording for every macOS setting the app mentions. A native speaker will still
catch what that missed — that is what this folder is public for.

## Fixing a translation

1. Open `Localizable.xcstrings` (it is JSON) and find the English text — every entry is keyed
   by it, and carries a `comment` saying where it appears.
2. Change the `value` under your language. Keep every `%@`, `%lld` and `%.1f` exactly as it is:
   they are filled in by the app (a name, a count, a number).
3. Open a pull request. One sentence on why helps.

Xcode opens the file as a table, if you have it; any text editor works just as well.

## The few rules

- **Names of macOS settings use Apple's wording in your language** — "Three Finger Drag",
  "Force Click", "Tap to click", "Accessibility". The app points people at those settings, so
  the name has to match what is on their screen.
- **WheelClick's own feature names are translated the way Apple translates its own**:
  a gesture that describes an action gets a name in your language; WheelClick, MiddleClick,
  Magic Mouse and the `fn` key stay as they are.
- A missing language is welcome too: open an issue and say which one.
