# German review — every key, English beside German

Task 6 of the Phase 2 localisation work. German is the pilot: the first of
36 languages, and the one whose wording can actually be checked before the
pattern is repeated 34 more times. This note exists so that check can happen
by reading, without running anything.

Source: `translations/de.json` (123 keys, 12 of them plural). Merged into
`Sources/ShrinkerPro/Resources/Localizable.xcstrings` by
`scripts/merge-translations.py` — never by hand.

**Awaiting review.** Nothing here has been read by a German speaker yet.

## How to read this

Each entry shows the catalog key's English value, then the German. Where the
catalog key differs from the English value — the plural entries, and the few
flat entries whose value carries positional specifiers — the key is shown on
its own line above them. The grey line beneath is the catalog comment, which
is the context the translation was made against.

`⍽` marks a **no-break space** (U+00A0). It appears only before an ellipsis,
which is what macOS German itself does: AppKit's own `Einstellungen⍽…` and
`Wählen⍽…`, and Sparkle's bundled `Nach Updates suchen⍽…`. It is deliberate,
not a stray character.

## Conventions this translation follows

**Register: informal `du`.** Not a stylistic preference — Sparkle's own German
localisation ships inside this app ("Möchtest du %1$@ jetzt aktualisieren?",
"Bitte versuche es später erneut"), and Apple's German system software has
addressed the user informally for years. A `Sie` here would change register
halfway through the app's own update dialog. Most strings describe rather than
instruct, so they stay impersonal and the question rarely arises; where English
uses an imperative, German does too.

**Platform vocabulary, taken from macOS itself** rather than translated. Each
of these was read out of the system's own localised resources on this machine,
not recalled:

| English | German | Where macOS says it |
| --- | --- | --- |
| Reveal | Im Finder zeigen | Finder `ServicesMenu.strings`, key `Finder/Reveal` |
| Keep Both | Beide behalten | AppKit `Revisions.loctable` |
| Replace | Ersetzen | AppKit `SavePanel.loctable`, `Document.loctable` |
| Done | Fertig | AppKit `Toolbar.loctable`, `TouchBar.loctable` |
| Settings | Einstellungen | AppKit `Localizable.loctable` |
| Quit | Beenden | AppKit `Document.loctable` |
| Open Recent | Benutzte Dokumente | AppKit `MenuCommands.loctable` |
| Clear Menu | Einträge löschen | AppKit `MenuCommands.loctable` |
| Choose… | Wählen⍽… | AppKit `Common.loctable` |
| Check for Updates… | Nach Updates suchen⍽… | Sparkle `de.lproj/Sparkle.strings` |
| Skip | Überspringen | AppKit `LocalizableMerged.strings` |

**Glossary terms, fixed once and used everywhere:**

| Term | German | Note |
| --- | --- | --- |
| shrink | verkleinern | The core verb, never varied. `merge-translations.py`'s own docstring already used "Bild verkleinert" as its worked example. "komprimieren" appears once, in the launch-failure alert, because English says "compress" there too. |
| minified | `minified` | Left in English: it is the literal name of the subfolder written to disk (`OutputPathResolver.swift`). |
| `.min` | `.min` | A filename suffix. |
| session | Sitzung | Kept distinct from the stored default, which is Vorgabe or Einstellung. |
| original | Original | Never "Datei". The overwrite sheet's whole point is that the two are different things. |
| crop | Zuschnitt, zuschneiden | Distinct from "Größe ändern" and from "skalieren". |

**Left in English:** "Shrinker Pro", the format names (JPEG, WebP, AVIF, PNG,
HEIC, HEIF, GIF, SVG), `px`, `.min` and `minified`.

## Judgement calls

Four places where the obvious German was not the one chosen. All four would
benefit from a second opinion.

1. **`ratio` → `Form`, not `Verhältnis`.** The crop-mode segmented control is a
   hardcoded 88pt (`SessionBarState.CropRow.modeWidth`), with a comment saying
   anything narrower clips "ratio". Measured with a real `NSSegmentedControl`
   at the control size the view uses: `ratio | px` is 82pt, `Verhältnis | px`
   is 115pt — it would be clipped, and that width is not measured per language
   the way the max-size field and the Settings window are. `Form | px` is 86pt
   and fits. "Form" also matches the help text, which calls it a shape
   ("Crops the center of each image to this shape"), so the control and the
   prose say the same word; the two help strings that mention the mode were
   written to agree ("auf diese Form zu", "auf eine Form um"). `Verh.`
   (86.5pt) fits too, but reads as an abbreviation of something the user has
   to guess.

2. **`Convert all to` → `Konvertieren in`, dropping "all".** The session bar's
   label column is a fixed 104pt (`SessionBarState.labelColumnWidth`).
   "Alle konvertieren in" measures 112pt at the row's own 12.5pt font and
   would wrap to a second line; "Konvertieren in" is 88pt. The picker's help
   text still says "jede Rasterdatei", so the scope is not lost.

3. **`App default` → `App-Vorgabe`, not `App-Standard`.** `ConversionQuality`
   explains that the quality level is called "Standard" and not "Default"
   precisely because the neighbouring menu offers "App default" — the two must
   not collide. "App-Standard" would put "Standard" into both menus and undo
   that. "Vorgabe" is the ordinary German word for a default and keeps them
   apart; the collapsed summary then reads
   "App-Vorgabe · Standard · Keine Begrenzung".

4. **`Skip This` / `Skip These` → `Diese Datei überspringen` /
   `Diese Dateien überspringen`.** AppKit's own term for Skip is
   "Überspringen", but the English pair is deliberately demonstrative —
   this/these, not a count — and a bare "Diese überspringen" is identical for
   both in German, since "diese" serves feminine singular and plural alike.
   Naming the noun keeps the two forms apart, and keeps the button from
   reading as "Abbrechen", which is the distinction the glossary says is the
   whole point of it. The cost is a button roughly twice the English width.

Two smaller ones, noted rather than argued:

- **`Encode at` → `Kodieren mit`.** The section header directly above it is
  already "Qualität", so the row label cannot be that too.
- **`Reveal` → `Im Finder zeigen`** makes the result row's pill button about
  three times as wide as the English one, so the filename beside it truncates
  sooner at narrow window widths. Taking the platform's term was the
  instruction and is the right call; this is simply where it costs something.

## Plural categories

`LocalizationGuardTests.pluralCategories(for: "de")` — the runtime probe, not
a table — reports `one` and `other` for German. Every one of the 12 plural
entries supplies exactly those two. Where English's `one` form omits the count
("Image shrunk"), German does the same ("Bild verkleinert"); the union of
specifiers across a key's variants still matches English's union, which is
what the placeholder guard checks.

---

## Menu bar

- EN &nbsp; About Shrinker Pro
- DE &nbsp; Über Shrinker Pro

- EN &nbsp; Check for Updates…
- DE &nbsp; Nach Updates suchen⍽…

- EN &nbsp; Settings
- DE &nbsp; Einstellungen

- EN &nbsp; Quit
- DE &nbsp; Beenden

- EN &nbsp; Open Files…
- DE &nbsp; Dateien öffnen⍽…

- EN &nbsp; Open Recent
- DE &nbsp; Benutzte Dokumente

- EN &nbsp; No Recent Files
- DE &nbsp; Keine benutzten Dokumente

- EN &nbsp; Clear Menu
- DE &nbsp; Einträge löschen

- EN &nbsp; Clear History
- DE &nbsp; Verlauf löschen

- EN &nbsp; Shrinker Pro
- DE &nbsp; Shrinker Pro

## Main window — drop zone and results

- EN &nbsp; Drag files here
- DE &nbsp; Dateien hierher ziehen

- EN &nbsp; PNG, JPG, HEIC, WebP, AVIF, GIF and SVG — or press ⌘O
- DE &nbsp; PNG, JPG, HEIC, WebP, AVIF, GIF und SVG — oder ⌘O drücken

- EN &nbsp; RECENT
- DE &nbsp; ZULETZT

- EN &nbsp; Clear
- DE &nbsp; Leeren
- <sub>Recent header button that empties the result list.</sub>

- EN &nbsp; Reveal
- DE &nbsp; Im Finder zeigen
- <sub>Result row button that reveals the shrunk file in Finder.</sub>

**Key** `%@ → %@`

- EN &nbsp; %1$@ → %2$@
- DE &nbsp; %1$@ → %2$@
- <sub>A result row's before-and-after sizes. The arrow points from the original size to the shrunk size; in right-to-left languages it should point the other way (←).</sub>

**Key** `%lld files · %@ saved`

- *one* &nbsp; EN &nbsp; 1 file · %2$@ saved
- *one* &nbsp; DE &nbsp; 1 Datei · %2$@ eingespart
- *other* &nbsp; EN &nbsp; %1$lld files · %2$@ saved
- *other* &nbsp; DE &nbsp; %1$lld Dateien · %2$@ eingespart
- <sub>Recent header aggregate. First placeholder is the file count, second is a size such as '1.2 MB'. The one-file form reads '1 file' with no number of its own.</sub>

**Key** `%lld files · %@ larger`

- *one* &nbsp; EN &nbsp; 1 file · %2$@ larger
- *one* &nbsp; DE &nbsp; 1 Datei · %2$@ größer
- *other* &nbsp; EN &nbsp; %1$lld files · %2$@ larger
- *other* &nbsp; DE &nbsp; %1$lld Dateien · %2$@ größer
- <sub>Recent header aggregate when this session's outputs grew overall. First placeholder is the file count, second is a size such as '1.2 MB'. The one-file form reads '1 file' with no number of its own.</sub>

## Session bar

- EN &nbsp; This session
- DE &nbsp; Diese Sitzung

- EN &nbsp; This session: %@
- DE &nbsp; Diese Sitzung: %@

- EN &nbsp; App default
- DE &nbsp; App-Vorgabe

- EN &nbsp; No limit
- DE &nbsp; Keine Begrenzung
- <sub>Collapsed session-bar summary when no max size is set.</sub>

- EN &nbsp; Max %@px
- DE &nbsp; Max. %@ px
- <sub>Collapsed session-bar summary of the max size. Placeholder is a pixel count; 'px' placement varies by language.</sub>

**Key** `Crop %@×%@`

- EN &nbsp; Crop %1$@×%2$@
- DE &nbsp; Zuschnitt %1$@×%2$@
- <sub>Collapsed session-bar summary of a pixel crop. Placeholders are width and height in pixels; the × is the same glyph the field shows.</sub>

**Key** `Crop %@:%@`

- EN &nbsp; Crop %1$@:%2$@
- DE &nbsp; Zuschnitt %1$@:%2$@
- <sub>Collapsed session-bar summary of a ratio crop. Placeholders are the two sides of the ratio.</sub>

- EN &nbsp; Adjust
- DE &nbsp; Anpassen
- <sub>Button that opens the session settings panel.</sub>

- EN &nbsp; Done
- DE &nbsp; Fertig
- <sub>Button that closes the session settings panel.</sub>

- EN &nbsp; Reset
- DE &nbsp; Zurücksetzen

- EN &nbsp; SESSION SETTINGS
- DE &nbsp; SITZUNGSEINSTELLUNGEN

- EN &nbsp; Convert all to
- DE &nbsp; Konvertieren in

- EN &nbsp; Quality
- DE &nbsp; Qualität

- EN &nbsp; Max size
- DE &nbsp; Max. Größe
- <sub>Session bar row label for the max-dimension field.</sub>

- EN &nbsp; Crop to
- DE &nbsp; Zuschnitt auf
- <sub>Session bar row label for the crop width/height fields.</sub>

- EN &nbsp; W
- DE &nbsp; B
- <sub>One-letter placeholder for the crop WIDTH field. Keep it to a single character if the language allows.</sub>

- EN &nbsp; H
- DE &nbsp; H
- <sub>One-letter placeholder for the crop HEIGHT field. Keep it to a single character if the language allows.</sub>

- EN &nbsp; px
- DE &nbsp; px

- EN &nbsp; ratio
- DE &nbsp; Form

- EN &nbsp; Applies to this session only. Defaults live in Settings.
- DE &nbsp; Gilt nur für diese Sitzung. Die Vorgaben stehen in den Einstellungen.

## Session bar — help text

- EN &nbsp; Converts every raster file for the rest of this session. SVG and GIF are always left in their own format.
- DE &nbsp; Konvertiert für den Rest dieser Sitzung jede Rasterdatei. SVG und GIF bleiben immer in ihrem eigenen Format.

- EN &nbsp; PNG is lossless — photos will usually get larger.
- DE &nbsp; PNG ist verlustfrei — Fotos werden dadurch meist größer.
- <sub>Warning when the session's format override is PNG, which usually grows photographs.</sub>

- EN &nbsp; Applies to JPEG, WebP, AVIF and HEIC. PNG and GIF are optimised by tools with no comparable setting, so they look the same whichever you choose.
- DE &nbsp; Gilt für JPEG, WebP, AVIF und HEIC. PNG und GIF werden von Werkzeugen optimiert, die keine vergleichbare Einstellung haben, und sehen deshalb bei jeder Wahl gleich aus.

- EN &nbsp; Shrinks images so the longest side is at most this many pixels. Smaller images are left alone. SVG is unaffected.
- DE &nbsp; Verkleinert Bilder so, dass die längste Seite höchstens so viele Pixel hat. Kleinere Bilder bleiben unverändert. SVG bleibt unberührt.
- <sub>Help text for the max size field when it is live.</sub>

**Key** `The crop already sets the size — every image comes out %@×%@. Switch the crop to a ratio, or clear it, to use a max size.`

- EN &nbsp; The crop already sets the size — every image comes out %1$@×%2$@. Switch the crop to a ratio, or clear it, to use a max size.
- DE &nbsp; Der Zuschnitt legt die Größe bereits fest — jedes Bild kommt mit %1$@×%2$@ heraus. Stelle den Zuschnitt auf eine Form um oder entferne ihn, um eine Maximalgröße zu nutzen.
- <sub>Help text when a pixel crop makes the max size field irrelevant. Placeholders are the crop's width and height in pixels.</sub>

- EN &nbsp; Crops the center of each image to this shape and leaves the size alone. The session's max size, if set, still applies.
- DE &nbsp; Schneidet die Mitte jedes Bildes auf diese Form zu und lässt die Größe unangetastet. Die Maximalgröße der Sitzung gilt weiterhin, sofern eine gesetzt ist.
- <sub>Crop help in ratio mode, where the crop sets shape but not size.</sub>

- EN &nbsp; Crops the center of each image to this shape, then scales it down to this size. Images already smaller are cropped but never enlarged, so a mixed batch may not come out all one size. This sets the output size outright, so the max size above does not apply.
- DE &nbsp; Schneidet die Mitte jedes Bildes auf diese Form zu und skaliert es dann auf diese Größe herunter. Bereits kleinere Bilder werden zugeschnitten, aber nie vergrößert — ein gemischter Stapel kommt deshalb womöglich nicht in einer einheitlichen Größe heraus. Damit steht die Ausgabegröße fest, und die Maximalgröße darüber gilt nicht.
- <sub>Crop help in pixel mode, where the crop states the output size outright.</sub>

- EN &nbsp; Both sides are needed. The shape is used exactly as typed, so a portrait photo cropped to 16:9 comes out as a landscape strip. SVG is unaffected. Not saved — it resets when you quit.
- DE &nbsp; Beide Seiten werden gebraucht. Die Form wird genau so verwendet, wie sie eingetippt ist: Ein Hochformat-Foto auf 16:9 zugeschnitten ergibt einen querformatigen Streifen. SVG bleibt unberührt. Wird nicht gesichert — beim Beenden setzt sie sich zurück.
- <sub>Shared tail of both crop help texts.</sub>

- EN &nbsp; A crop needs both sides. Fill in the other number, or clear this one — files cannot be shrunk until you do.
- DE &nbsp; Ein Zuschnitt braucht beide Seiten. Ergänze die andere Zahl oder entferne diese — bis dahin lassen sich keine Dateien verkleinern.
- <sub>Help text for the warning glyph shown while a crop has only one side filled in.</sub>

- EN &nbsp; Finish the crop, or clear it, before closing.
- DE &nbsp; Vor dem Schließen muss der Zuschnitt vervollständigt oder entfernt werden.
- <sub>Help text on the disabled Done button while the crop is missing a side.</sub>

- EN &nbsp; Returns format, quality, max size and crop to the app's defaults
- DE &nbsp; Setzt Format, Qualität, Maximalgröße und Zuschnitt auf die Vorgaben der App zurück

## Session bar — accessibility

- EN &nbsp; Adjust session settings
- DE &nbsp; Sitzungseinstellungen anpassen

- EN &nbsp; Close session settings
- DE &nbsp; Sitzungseinstellungen schließen

- EN &nbsp; Done adjusting session settings
- DE &nbsp; Anpassen der Sitzungseinstellungen abschließen

- EN &nbsp; Shows the format, quality and max size controls
- DE &nbsp; Zeigt die Bedienelemente für Format, Qualität und Maximalgröße

- EN &nbsp; Max size in pixels
- DE &nbsp; Maximale Größe in Pixeln

- EN &nbsp; Crop mode
- DE &nbsp; Zuschnittmodus

- EN &nbsp; Crop width
- DE &nbsp; Breite des Zuschnitts

- EN &nbsp; Crop height
- DE &nbsp; Höhe des Zuschnitts

## Settings — Output

- EN &nbsp; Output
- DE &nbsp; Ausgabe

- EN &nbsp; Where
- DE &nbsp; Wohin

- EN &nbsp; Same folder as original
- DE &nbsp; Gleicher Ordner wie das Original

- EN &nbsp; Choose folder…
- DE &nbsp; Ordner wählen⍽…

- EN &nbsp; Choose…
- DE &nbsp; Wählen⍽…

- EN &nbsp; No folder chosen
- DE &nbsp; Kein Ordner gewählt
- <sub>Shown in place of a path when no output folder has been picked yet.</sub>

- EN &nbsp; Put them in a "minified" subfolder
- DE &nbsp; In einen Unterordner „minified“ legen

- EN &nbsp; Files
- DE &nbsp; Dateien
- <sub>Settings row label when outputs land beside the originals, so the choice is about the files themselves.</sub>

- EN &nbsp; Filenames
- DE &nbsp; Dateinamen
- <sub>Settings row label when outputs land in a separate folder, so the choice is only about naming.</sub>

**Key** `%@  —  %@`

- EN &nbsp; %1$@  —  %2$@
- DE &nbsp; %1$@  —  %2$@
- <sub>One radio option's label in the Files/Filenames setting: the choice, then the filename it produces, in secondary text. Placeholders are the option's own title and the example filename it produces.</sub>

- EN &nbsp; Keep originals, save a .min copy
- DE &nbsp; Originale behalten, .min-Kopie sichern
- <sub>Output option: write alongside the original and leave it in place. '.min' is a filename suffix and stays as-is.</sub>

- EN &nbsp; Replace originals
- DE &nbsp; Originale ersetzen
- <sub>Output option: overwrite the original file in place.</sub>

- EN &nbsp; Add .min
- DE &nbsp; .min anhängen
- <sub>Output option: add the '.min' suffix to the written filename. '.min' stays as-is.</sub>

- EN &nbsp; Leave as is
- DE &nbsp; Unverändert lassen
- <sub>Output option: write the file under its original name, with no suffix added.</sub>

- EN &nbsp; Warn before replacing a file
- DE &nbsp; Vor dem Ersetzen einer Datei warnen

- EN &nbsp; Your originals will be overwritten and cannot be recovered. Converted files keep a separate extension, so those originals are left alone.
- DE &nbsp; Deine Originale werden überschrieben und können nicht wiederhergestellt werden. Konvertierte Dateien behalten eine eigene Dateiendung — diese Originale bleiben also unangetastet.

## Settings — Conversion, Quality, Metadata, General

The `Quality` section header is the same catalog key as the session bar's own `Quality` row label, and is listed under **Session bar** above.

- EN &nbsp; Conversion
- DE &nbsp; Konvertierung

- EN &nbsp; Keep
- DE &nbsp; Behalten
- <sub>Conversion rule option meaning 'leave this format alone'.</sub>

- EN &nbsp; Keep %@
- DE &nbsp; %@ behalten
- <sub>Conversion rule option meaning 'do not convert'. The placeholder is a format name such as PNG, which stays English.</sub>

- EN &nbsp; SVG and GIF files are always optimised in their own format. SVG is vector, and GIF is usually animated — converting either would lose what makes it useful.
- DE &nbsp; SVG- und GIF-Dateien werden immer in ihrem eigenen Format optimiert. SVG ist vektorbasiert, GIF meist animiert — eine Konvertierung würde jeweils genau das zerstören, was sie nützlich macht.

- EN &nbsp; Encode at
- DE &nbsp; Kodieren mit

- EN &nbsp; Super Low
- DE &nbsp; Sehr niedrig
- <sub>Quality level: the most aggressive of the four.</sub>

- EN &nbsp; Low
- DE &nbsp; Niedrig
- <sub>Quality level, between Super Low and Standard.</sub>

- EN &nbsp; Standard
- DE &nbsp; Standard
- <sub>Quality level: the default. Not 'Default' — a neighbouring menu already offers 'App default'.</sub>

- EN &nbsp; High
- DE &nbsp; Hoch
- <sub>Quality level: the gentlest of the four.</sub>

- EN &nbsp; Applies to JPEG, WebP, AVIF and HEIC. PNG and GIF are optimised by tools with no comparable setting, so they look the same whichever you choose. Standard matches what earlier versions of Shrinker Pro produced. Every session starts here; the window's session bar can change it for one session without changing this.
- DE &nbsp; Gilt für JPEG, WebP, AVIF und HEIC. PNG und GIF werden von Werkzeugen optimiert, die keine vergleichbare Einstellung haben, und sehen deshalb bei jeder Wahl gleich aus. Standard entspricht dem, was frühere Versionen von Shrinker Pro erzeugt haben. Jede Sitzung beginnt hier; die Sitzungsleiste im Fenster kann den Wert für eine Sitzung ändern, ohne diese Einstellung zu ändern.

- EN &nbsp; Metadata
- DE &nbsp; Metadaten

- EN &nbsp; When shrinking, keep
- DE &nbsp; Beim Verkleinern behalten

- EN &nbsp; All metadata
- DE &nbsp; Alle Metadaten
- <sub>Metadata policy: keep everything the original carried.</sub>

- EN &nbsp; Copyright and credit only
- DE &nbsp; Nur Copyright und Urheber
- <sub>Metadata policy: keep only the copyright and creator fields.</sub>

- EN &nbsp; No metadata
- DE &nbsp; Keine Metadaten
- <sub>Metadata policy: strip everything.</sub>

- EN &nbsp; Rotation is always applied to the image itself, so photos stay upright in any app whichever option you choose.
- DE &nbsp; Die Drehung wird immer auf das Bild selbst angewendet — Fotos stehen deshalb in jeder App aufrecht, welche Option du auch wählst.

- EN &nbsp; General
- DE &nbsp; Allgemein

- EN &nbsp; Enable notifications
- DE &nbsp; Mitteilungen aktivieren

- EN &nbsp; Notifications are turned off for Shrinker Pro in System Settings, so none will appear.
- DE &nbsp; Mitteilungen sind für Shrinker Pro in den Systemeinstellungen deaktiviert — es wird also keine geben.

- EN &nbsp; Open Notification Settings…
- DE &nbsp; Mitteilungseinstellungen öffnen⍽…

- EN &nbsp; Clear result list when shrinking new images
- DE &nbsp; Ergebnisliste beim Verkleinern neuer Bilder leeren

## Overwrite sheet

**Key** `Replace %lld originals?`

- *one* &nbsp; EN &nbsp; Replace 1 original?
- *one* &nbsp; DE &nbsp; 1 Original ersetzen?
- *other* &nbsp; EN &nbsp; Replace %lld originals?
- *other* &nbsp; DE &nbsp; %lld Originale ersetzen?
- <sub>Overwrite sheet title when the user's own originals would be destroyed and they are not all in one folder.</sub>

**Key** `Replace %lld originals in “%@”?`

- *one* &nbsp; EN &nbsp; Replace 1 original in “%2$@”?
- *one* &nbsp; DE &nbsp; 1 Original in „%2$@“ ersetzen?
- *other* &nbsp; EN &nbsp; Replace %1$lld originals in “%2$@”?
- *other* &nbsp; DE &nbsp; %1$lld Originale in „%2$@“ ersetzen?
- <sub>Overwrite sheet title for originals sharing one folder. Second placeholder is the folder name.</sub>

**Key** `Replace %lld files?`

- *one* &nbsp; EN &nbsp; Replace 1 file?
- *one* &nbsp; DE &nbsp; 1 Datei ersetzen?
- *other* &nbsp; EN &nbsp; Replace %lld files?
- *other* &nbsp; DE &nbsp; %lld Dateien ersetzen?
- <sub>Overwrite sheet title when existing files would be replaced and they are not all in one folder.</sub>

**Key** `Replace %lld files in “%@”?`

- *one* &nbsp; EN &nbsp; Replace 1 file in “%2$@”?
- *one* &nbsp; DE &nbsp; 1 Datei in „%2$@“ ersetzen?
- *other* &nbsp; EN &nbsp; Replace %1$lld files in “%2$@”?
- *other* &nbsp; DE &nbsp; %1$lld Dateien in „%2$@“ ersetzen?
- <sub>Overwrite sheet title for existing files sharing one folder. Second placeholder is the folder name.</sub>

**Key** `%lld originals will be overwritten: %@`

- *one* &nbsp; EN &nbsp; %2$@ will be overwritten and cannot be recovered.
- *one* &nbsp; DE &nbsp; %2$@ wird überschrieben und kann nicht wiederhergestellt werden.
- *other* &nbsp; EN &nbsp; These %1$lld originals will be overwritten and cannot be recovered: %2$@
- *other* &nbsp; DE &nbsp; Diese %1$lld Originale werden überschrieben und können nicht wiederhergestellt werden: %2$@
- <sub>Overwrite sheet body for originals. First placeholder is the file count and drives the plural; the singular form does not print it. Second is the filename list.</sub>

**Key** `%lld files are already there: %@`

- *one* &nbsp; EN &nbsp; %2$@ is already there and will be replaced.
- *one* &nbsp; DE &nbsp; %2$@ ist bereits vorhanden und wird ersetzt.
- *other* &nbsp; EN &nbsp; These %1$lld files are already there and will be replaced: %2$@
- *other* &nbsp; DE &nbsp; Diese %1$lld Dateien sind bereits vorhanden und werden ersetzt: %2$@
- <sub>Overwrite sheet body for existing files. First placeholder is the file count and drives the plural; the singular form does not print it. Second is the filename list.</sub>

**Key** `The other %lld files are unaffected.`

- *one* &nbsp; EN &nbsp; The other file is unaffected.
- *one* &nbsp; DE &nbsp; Die übrige Datei ist nicht betroffen.
- *other* &nbsp; EN &nbsp; The other %lld files are unaffected.
- *other* &nbsp; DE &nbsp; Die übrigen %lld Dateien sind nicht betroffen.
- <sub>Reassurance that the rest of the batch still runs.</sub>

- EN &nbsp; %@, …and %lld more
- DE &nbsp; %@, …und %lld weitere
- <sub>Tail of a truncated filename list. First placeholder is the listed names, second is how many were not listed.</sub>

**Key** `filename list separator`

- EN &nbsp; , 
- DE &nbsp; , 
- <sub>Separates filenames in the overwrite sheet's list. English uses a comma and a space; CJK languages use 、</sub>

- EN &nbsp; Keep Both
- DE &nbsp; Beide behalten

- EN &nbsp; Replace
- DE &nbsp; Ersetzen

- EN &nbsp; Skip This
- DE &nbsp; Diese Datei überspringen
- <sub>Overwrite sheet's cancel-role button when exactly one file is affected. Declines these files; the rest of the batch still runs.</sub>

- EN &nbsp; Skip These
- DE &nbsp; Diese Dateien überspringen
- <sub>Overwrite sheet's cancel-role button when more than one file is affected. Declines these files; the rest of the batch still runs.</sub>

## Errors and alerts

- EN &nbsp; Something went wrong
- DE &nbsp; Etwas ist schiefgelaufen

- EN &nbsp; OK
- DE &nbsp; OK

- EN &nbsp; Only SVG, PNG, GIF, JPEG, WebP, AVIF, HEIC and HEIF are supported (got "%@").
- DE &nbsp; Nur SVG, PNG, GIF, JPEG, WebP, AVIF, HEIC und HEIF werden unterstützt (erhalten: „%@“).
- <sub>Alert body when a dropped file is a format the app cannot read.</sub>

- EN &nbsp; The crop is missing a side, so it is not clear what these files should be cropped to. Fill in both numbers, or clear the crop, and drop them again.
- DE &nbsp; Dem Zuschnitt fehlt eine Seite, daher ist unklar, worauf diese Dateien zugeschnitten werden sollen. Gib beide Zahlen ein oder entferne den Zuschnitt und lege die Dateien erneut ab.
- <sub>Alert body when a whole drop is refused because the crop has only one of its two sides filled in.</sub>

- EN &nbsp; %@ failed with exit code %d
- DE &nbsp; %@ ist mit Exit-Code %d fehlgeschlagen
- <sub>Alert body when a compressor exits non-zero and said nothing else. Placeholders: tool name, exit code.</sub>

- EN &nbsp; %@ failed with exit code %d: %@
- DE &nbsp; %@ ist mit Exit-Code %d fehlgeschlagen: %@
- <sub>Alert body when a compressor exits non-zero with a message of its own. Placeholders: tool name, exit code, the tool's message.</sub>

- EN &nbsp; No output was written to %@.
- DE &nbsp; Nach %@ wurde keine Ausgabe geschrieben.
- <sub>Alert body when a compressor reported success but produced no file.</sub>

- EN &nbsp; Image conversion failed: %@
- DE &nbsp; Die Bildkonvertierung ist fehlgeschlagen: %@
- <sub>Alert body when an ImageIO decode or encode step fails.</sub>

- EN &nbsp; SVG optimization failed: %@
- DE &nbsp; Die SVG-Optimierung ist fehlgeschlagen: %@
- <sub>Alert body when svgo fails.</sub>

- EN &nbsp; The bundled %@ tool is missing. The app may be damaged — try reinstalling.
- DE &nbsp; Das mitgelieferte Werkzeug %@ fehlt. Die App ist möglicherweise beschädigt — installiere sie neu.
- <sub>Alert body when a bundled compressor binary is absent. The placeholder is a tool name such as cjpeg.</sub>

- EN &nbsp; Shrinker Pro can't start
- DE &nbsp; Shrinker Pro kann nicht starten

- EN &nbsp; Shrinker Pro couldn't start.
- DE &nbsp; Shrinker Pro konnte nicht starten.
- <sub>Fallback body of the launch-failure screen when the error carried no message of its own.</sub>

**Key** `Shrinker Pro Can't Open %lld Files`

- *one* &nbsp; EN &nbsp; Shrinker Pro Can't Open This File
- *one* &nbsp; DE &nbsp; Shrinker Pro kann diese Datei nicht öffnen
- *other* &nbsp; EN &nbsp; Shrinker Pro Can't Open These %lld Files
- *other* &nbsp; DE &nbsp; Shrinker Pro kann diese %lld Dateien nicht öffnen
- <sub>Title of the alert shown when files are opened but the app failed to start. The one-file form reads 'This File' with no number.</sub>

**Key** `Shrinker Pro failed to start, so it can't compress the %lld files you opened. Quit and relaunch to try again.`

- *one* &nbsp; EN &nbsp; Shrinker Pro failed to start, so it can't compress the file you opened. Quit and relaunch to try again.
- *one* &nbsp; DE &nbsp; Shrinker Pro konnte nicht starten und kann die geöffnete Datei deshalb nicht komprimieren. Beende die App und starte sie neu, um es erneut zu versuchen.
- *other* &nbsp; EN &nbsp; Shrinker Pro failed to start, so it can't compress the %lld files you opened. Quit and relaunch to try again.
- *other* &nbsp; DE &nbsp; Shrinker Pro konnte nicht starten und kann die %lld geöffneten Dateien deshalb nicht komprimieren. Beende die App und starte sie neu, um es erneut zu versuchen.
- <sub>Body of the alert shown when files are opened but the app failed to start. The one-file form reads 'the file' with no number.</sub>

## Notifications

**Key** `%lld images shrunk`

- *one* &nbsp; EN &nbsp; Image shrunk
- *one* &nbsp; DE &nbsp; Bild verkleinert
- *other* &nbsp; EN &nbsp; %lld images shrunk
- *other* &nbsp; DE &nbsp; %lld Bilder verkleinert
- <sub>Notification title after a batch finishes. The one-file form reads 'Image shrunk' with no number.</sub>

- EN &nbsp; %@ saved
- DE &nbsp; %@ eingespart
- <sub>Notification body after a batch of two or more files. The placeholder is an already-formatted size such as '1.2 MB'.</sub>

