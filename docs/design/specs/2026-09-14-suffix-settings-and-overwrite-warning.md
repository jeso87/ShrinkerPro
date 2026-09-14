# Shrinker Pro — Suffix Discoverability, Settings Regroup, and an Overwrite Warning

**Date:** 2026-09-14

Two requests from one user. The first turns out to be already built and simply unfindable,
which makes it a wording problem rather than a feature. The second is real, and paying for
it properly means the engine has to be able to answer a question it currently cannot:
*where would this file land, without landing it?*

## 1. The request that was already shipped

> "The option 'Reduced copies are saved together with originals with a .min suffix' is super
> convenient, but it would be fantastic to have a toggle switch to enable or disable it at will."

That toggle exists, and has since 1.0.0 — as `Toggle("Keep original files", …)` at
`SettingsView.swift:34`. The sentence being quoted is not a setting; it is the *caption
underneath that toggle*, at `SettingsView.swift:36`. The user was looking directly at the
control they were asking for.

So there is nothing to add. A control nobody can see is a control that does not exist, and
the fix is to make the panel legible — not to grow it.

**A footer control was considered and rejected.** Quality earned its place in the window
footer in 1.2.0 because it is a thing you change *between one drop and the next*. Whether
you keep your originals is a standing policy, not a per-drop choice, and putting a
destructive switch one click away from the drop zone would manufacture exactly the accident
that section 4 of this spec exists to prevent.

## 2. The panel

Today: eleven controls in five sections, **two of which have no header at all**
(`SettingsView.swift:14` and `:42`), in a `.fixedSize` 420pt column that never scrolls. The
output controls — the ones that decide whether you still have your files afterwards — are in
the unlabelled group at the top.

```
── OUTPUT ──────────────────────────────────────
  Where   (•) Same folder as original
          ( ) Choose folder…   ~/Desktop/shrunk
          [ ] Put them in a "minified" subfolder

  Files   (•) Keep originals, save a .min copy
          ( ) Replace originals

          [✓] Warn before replacing a file

── CONVERSION ──   unchanged — five rows, SVG/GIF footer
── QUALITY ─────   unchanged
── METADATA ────   unchanged
── GENERAL ─────   Notifications · Clear list · Check for updates
```

`OUTPUT` leads because it is what people open this panel to change. `GENERAL` collects the
three loose behaviour toggles that are currently headerless.

**The radios are pure presentation.** `Where` binds the existing `saveInSameFolder` Bool;
`Files` binds `keepOriginal`. No new keys, no migration, and in particular no change to the
`"suffix"` key, whose deliberate non-renaming is argued at length in `Settings.swift:14-19`.
A radio pair is used rather than a checkbox because both branches then state their own
consequence, which is the whole defect being fixed: a checkbox says what happens when it is
ticked and leaves the other half to be inferred.

### "Replace originals", and a claim the app currently makes that isn't true

The caption at `SettingsView.swift:36` asserts that with the toggle off, "Originals are
overwritten in place." That is only true when the resolved output path *is* the input path.

| Files | Where | Subfolder | Is an original replaced? |
|---|---|---|---|
| Keep originals | any | any | No — `.min` makes the name differ |
| Replace originals | Same folder | off | **Yes** |
| Replace originals | Same folder | on | No — written into `minified/` |
| Replace originals | Chosen folder | any | No — written elsewhere |

Three of those four combinations are being warned about something that will not happen. So
the radio reads **"Replace originals"** (what you chose), and the warning line renders only
in the row that earns it, from a pure function —
`OutputWarning.replacesOriginals(keepOriginal:saveInSameFolder:savePath:useSubfolder:)` —
tested the way `NotificationPermission.showsDeniedNotice(toggleIsOn:)` is at
`SettingsTests.swift:190`, since this project carries no view-tree testing dependency.

### One new setting

`warnBeforeOverwrite`, stored as `"warnBeforeOverwrite"`, default **`true`**. CamelCase like
`"conversionPNG"` and `"quality"`, not the lowercase Electron-era keys — this one is ours.

**This is the one deliberate behaviour change for existing users.** Every other default in
this app was picked so upgrading changes nothing: `quality` defaults to `.standard` because
it reproduces the constants 1.1.0 shipped, `metadata` to `.all` because anything else would
start deleting EXIF from files the app round-trips intact today. This default breaks that
pattern knowingly. Someone re-shrinking a folder will see a sheet they have never seen.

It is accepted because the two failures are not comparable: the cost of the new default is an
interruption, and the cost of the old behaviour is a file that is gone. Unticking the box
restores 1.2.0 behaviour exactly — including skipping the scan, so it costs nothing to have
turned off.

## 3. Knowing where a file will land

`ShrinkEngine.shrink` computes its destination at `:91-94` — `plan(…)` first, because the
output extension depends on the routing decision, then `OutputPathResolver.resolve(…)` — and
does so *inside* the method that then writes the file. Nothing in the app can currently
answer "where would this land?" without landing it. Worse, `resolve` creates the destination
directory as a side effect (`OutputPathResolver.swift:78`, already flagged at
`ShrinkEngine.swift:77`), so scanning with it would create `minified/` folders before the
user has agreed to anything.

Two separations fix both:

- **`OutputPathResolver.resolve` splits** into a pure `destination(input:settings:targetExtension:)`
  that builds a path and creates nothing, and a `prepareDirectory(for:)` that does the
  `createDirectory` call. The resolver has exactly one production caller, so this is cheap.
- **The private `Plan` struct at `ShrinkEngine.swift:274` is promoted** to an internal
  `ShrinkPlan` that also carries its input and its resolved `destination`.

```swift
func plan(_ input: URL, settings: OutputSettings) throws -> ShrinkPlan
func shrink(_ plan: ShrinkPlan) throws -> ShrinkResult
func shrink(_ input: URL, settings: OutputSettings) throws -> ShrinkResult  // plans, then executes
```

The convenience overload keeps the CLI's call site unchanged. Directory creation moves into
`shrink(_ plan:)`, which is to say: after consent.

**Why not the cheaper options.** Adding a read-only `destination(for:settings:)` and leaving
`shrink` alone would plan every file twice — a second orientation read per file per drop —
and, more importantly, the path that was checked would not be the path that gets written,
only one computed the same way. Pushing an overwrite *policy* into `OutputSettings` and
letting the engine call back on collision would put UI inside a synchronous, UI-free engine
that runs in a detached task, and would prompt file-by-file mid-batch.

## 4. The warning

### Classifying a collision

Per plan, comparing `standardizedFileURL`:

| | Condition | Meaning |
|---|---|---|
| **A** | `destination == input` | The file being read is the file being written. Irreversible. |
| **B** | `destination` exists, `≠ input` | Something else is already at that path. |
| — | otherwise | No collision. |

**Category B deliberately does not claim to know what that file is.** Earlier drafts of this
dialog called it "an earlier `.min` copy from a previous run", which is the common case and
still a lie: with a chosen save folder, the file sitting at the destination may be an
unrelated file that merely shares a name, and replacing it is just as destructive. A dialog
that guesses wrong about what it is destroying is worse than one that simply names the path.

This also classifies the subtle case correctly: "Replace originals" *plus* a chosen save
folder lands in B, not A, because the original genuinely is not at risk.

### Two sheets, in order of stakes

A first, then B, each shown only if its category is non-empty. Each carries its own
independent answer, so "keep both of my originals but replace the stale copies" is
expressible — which is the argument for two sheets rather than one.

```
 ⚠  Replace 1 original?                      Replace 1 file in ~/Desktop/shrunk?

    photo.jpg will be overwritten and         logo.png is already there and will
    cannot be recovered.                      be replaced.

    The other 48 files are unaffected.        The other 48 files are unaffected.

    [Skip This] [Keep Both] [Replace]         [Skip This] [Keep Both] [Replace]
```

### What the buttons mean

- **Skip** — those files are left alone. No row, no error, nothing written; every
  non-colliding file in the drop still shrinks. Dismissing the sheet (Esc, or closing it) is
  Skip, which is why the button is not called Cancel: it is not cancelling the drop. The
  label follows the count — "Skip This" for one file, "Skip These" for more — as do the
  sheet titles ("Replace 1 original?" / "Replace 3 originals?").
- **Keep Both** — `OutputPathResolver.uniqueDestination(for:)`, Finder's convention: the first
  free integer from 2, skipping gaps. `photo.min.jpg` → `photo.min 2.jpg`; under "Replace
  originals", `photo.jpg` → `photo 2.jpg`, so the original survives beside a numbered sibling.
  The check-then-write gap is a benign race — the write is a plain `moveItem` to a path
  observed free, and losing it requires another process to create that exact name in the
  intervening moment.
- **Replace** — today's behaviour, the `replaceItemAt` path at `ShrinkEngine.swift:257`.

### Mechanism

`AppModel` gains a `pendingOverwrite` request that `process(urls:)` awaits through a checked
continuation, resumed exactly once on every path including window close. `ContentView` gains
a second alert bound to it, deliberately parallel to the `errorMessage` alert at
`ContentView.swift:61`, so there is one pattern for "the model wants the window to say
something" rather than two.

The settings snapshot is already taken once per batch before the loop
(`AppModel.swift:132`); plans are built from that same snapshot, so nothing can shift between
what was scanned and what is written. One sheet per batch per category — never one per file.

With `warnBeforeOverwrite` off there is no scan and no sheet.

## 5. The CLI is untouched

`CommandLineOptions.swift:417` builds its own `OutputSettings` with `keepOriginal: !inPlace`
and never reads `Settings`, so none of this reaches `shrinker`. No prompt, no new flag,
`--in-place` keeps meaning exactly what it means. A non-interactive tool that stopped to ask
a question would be a bug.

## 6. Testing

- `warnBeforeOverwrite` gets the five-part contract the other keys have: non-regressing
  default, persistence, unrecognised-value fallback, **pinned on-disk spelling**, and proof it
  reaches the engine snapshot.
- `destination(…)` creates **no** directory — an explicit assertion, because creating one is
  what that code does today and it is the regression most likely to come back.
- `uniqueDestination` numbering, including gaps (`photo 2.jpg` missing but `photo 3.jpg`
  present) and the "Replace originals" stem with no `.min` in it.
- Classification: A vs B vs no-collision, including "Replace originals + chosen save folder"
  landing in B.
- `OutputWarning.replacesOriginals` over all four rows of the table in section 2.
- `AppModel`: sheet suppressed when the setting is off; Skip leaves those files untouched and
  still processes the rest; Keep Both writes the numbered name; the continuation is resumed
  exactly once.
- Existing `ShrinkEngineTests` migrate to whichever overload reads clearest; the convenience
  overload keeps most of them unchanged.

## 7. Out of scope

- A suffix control in the window footer (section 1).
- Per-format, per-folder, or per-category warning preferences — one checkbox, or the escape
  hatch becomes its own settings problem.
- Remembering an answer across drops ("don't ask again for this folder").
- Moving replaced files to the Trash instead of overwriting them, and any form of undo.
- Splitting Settings into tabs. The regroup buys enough legibility for 1.2.1; tabs are the
  answer if the panel grows again.
