# Shrinker Pro — Suffix Discoverability, a Settings Regroup, and an Overwrite Guard on Both Surfaces

**Date:** 2026-09-14

Two requests from one user. The first turns out to be already built and simply unfindable,
which makes it a wording problem rather than a feature. The second is real, and paying for
it properly means the engine has to be able to answer a question it currently cannot:
*where would this file land, without landing it?*

Both surfaces are covered. The window gets a sheet; `shrinker` gets `--if-exists`, because
the hazard is identical on the command line and currently unguarded there — and shipping the
guard on one surface only would leave the product holding two opposite opinions about what a
collision means.

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

## 5. The same guard on the command line

The §3 refactor reaches the CLI not at all: `main.swift:170` calls
`engine.shrink(file, settings:)`, which the convenience overload keeps compiling unchanged,
and the CLI never touches `OutputPathResolver`. `CommandLineOptions.swift:417` builds its own
`OutputSettings` and never reads `Settings`, so no preference of the app's leaks into a
headless run.

But "the CLI is untouched" was the wrong conclusion, because **the hazard is unguarded
here too**. `shrinker photo.jpg` run twice replaces `photo.min.jpg` without a word — which is
precisely the quality-testing loop that prompted this spec.

### What the CLI refuses today, and what it doesn't

`OutputCollision` (`CommandLineOptions.swift:141`) catches *input-vs-input* collisions: two
inputs that would land on the same name inside `--out`. It refuses the run at exit 65 rather
than disambiguating, and `main.swift:137-140` is explicit about why — *"inventing
`logo-1.min.png` would invent a name nobody asked for, and picking a winner is exactly what
the bug already did."*

Nothing compares a destination against a file **already on disk**. That is the gap.

### `--if-exists <what>`

| Mode | Behaviour |
|---|---|
| **`replace`** (default) | Overwrite it — today's behaviour, byte for byte |
| `skip` | Leave it; name it on stderr; the run continues and exits 0 |
| `keep-both` | Write `photo.min 2.jpg`, via the same `uniqueDestination` the sheet uses |
| `fail` | Refuse the run before any work starts; exit 65 |

**The default is `replace` because exit codes and stdout are a compatibility surface this
project already treats as one** — `CommandLineOptions.swift:126` says so, and the tests pin
every code. Making refusal the default would close the gap by breaking every existing script
and cron job on upgrade. The gap is closed by making the choice *available and documented*,
which is all a non-interactive tool can honestly offer.

### The principle that reconciles `keep-both` with the CLI's refusal

> A person looking at a sheet can be **offered** a name. A tool running unattended must not
> **invent** one.

The app's Keep Both button and the CLI's "refused rather than disambiguated" stance are the
same rule under that principle, not a contradiction: numbering is fine when a human asked for
it, and wrong when nobody did. `--if-exists keep-both` *is* asking for it.

Which resolves the older refusal too: with `keep-both` explicitly set, the input-vs-input
collision at `main.swift:144` stops being a refusal and becomes numbering. Under `replace`,
`skip` and `fail` it still refuses exactly as it does today — picking a winner remains the bug
it always was.

### `--in-place` is its own consent

Without it, `keepOriginal` is true (`:417`), so the destination is always the `.min` name and
never the input — category A simply cannot arise. With it, replacing the original is the
entire point of the flag. So `--if-exists` has nothing to govern under `--in-place`, and any
non-default combination of the two is **refused at the door** as contradictory, following the
`--in-place` + `--out` precedent at `:539`. Silently ignoring a flag the user took the trouble
to type is how precedence rules nobody can guess get born.

### `--json` gains a `status`

`ShrinkReport` (`:230`) has five non-optional fields built from a `ShrinkResult`, so a skipped
file has no `output` and no `shrunkBytes` to report. Reusing the existing "nothing happened"
idiom — `output == input`, `savedPercent: 0`, as a never-grow decline reports at `:244` —
would need no schema change, and is rejected: a script could not then distinguish *"skipped,
something was already there"* from *"declined, compressing would have made it bigger."* Those
are different facts and a caller may reasonably act differently on each.

So `ShrinkReport` grows one field, `status`, with exactly three values: `shrunk`, `declined`,
`skipped`. The change is additive — `.sortedKeys` places it deterministically and existing
consumers reading the five known keys are unaffected — and it pays a second dividend by making
`declined` explicit, which today can only be inferred by string-comparing two paths.

### Help text

`--if-exists` joins OPTIONS with its four values, and EXAMPLES gains one line showing the
quality-testing loop the flag exists for.

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

And for the CLI:

- `--if-exists` parses its four values and rejects anything else through the existing
  `invalidValue` path; the flag is absent from a parse with no `--if-exists` at all.
- **The default reproduces 1.2.0 exactly** — a re-run with no flag still replaces, with no
  extra stat, no stderr line, and identical stdout.
- `--in-place --if-exists skip` is refused as contradictory, and `--in-place --if-exists
  replace` (the default, stated explicitly) is not.
- `keep-both` numbering comes from the *same* `uniqueDestination` as the sheet — one
  implementation, asserted from both surfaces, so they cannot drift apart.
- `keep-both` resolves an input-vs-input group that `replace` still refuses at exit 65.
- `status` is pinned to its three spellings alongside the existing JSON contract tests, and a
  never-grow decline reports `declined` while an untouched skip reports `skipped`.
- Exit 65 for `fail` sits alongside the pinned `ShrinkError` codes and stays distinct from
  them.

## 7. Out of scope

- A suffix control in the window footer (section 1).
- Per-format, per-folder, or per-category warning preferences — one checkbox, or the escape
  hatch becomes its own settings problem.
- Remembering an answer across drops ("don't ask again for this folder").
- Moving replaced files to the Trash instead of overwriting them, and any form of undo.
- Splitting Settings into tabs. The regroup buys enough legibility for 1.2.1; tabs are the
  answer if the panel grows again.
- An interactive `--if-exists ask`. A tool that blocks on a question cannot be run from a
  script, a build step, or an agent, which is most of why `shrinker` exists.
- Changing the CLI's default to anything but `replace`. If that is ever wanted it is a major
  version, announced, not a point release.
