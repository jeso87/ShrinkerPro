Hi everyone,

Shrinker Pro 1.9.1 is out. All three of the main changes came straight from your feedback this week, so thank you to everyone who writes in.

**[Download Shrinker Pro](https://github.com/jeso87/ShrinkerPro/releases/latest/download/ShrinkerPro.dmg)**. Already have it? Choose **Check for Updates…**, or `brew upgrade --cask shrinker-pro`.

## Sharpen is a real unsharp mask

One user was running every batch through Studio, then through Affinity just to sharpen. Fair point: Studio's Sharpen was too gentle to match. Now it's a full unsharp mask:

- **Amount** up to 400%
- **Radius** from 0.2 to 100 px
- **Threshold** from 0 to 50, so skies and skin stay smooth

I measured Radius against Affinity's own Unsharp Mask, so your Affinity numbers carry straight over. A factor of 2.84 with a 29 px radius is Amount 284%, Radius 29. It sharpens brightness only, so edges don't pick up colour fringes. The Shortcuts action has all three settings too.

## Rounded corners, no frame

Rounded used to always come with a thin border. Now you can set the **Border** step's Rounded width to **0%** and only the photo's corners get rounded. With a clear colour the corners are transparent in PNG and WebP. Save it as a recipe and every photo in the batch gets the same corners.

## Save to ▸ Ask when exporting

A new choice in **Save to**: Export asks you for a folder each time instead of always using the same one. It opens where you last exported, and Cancel cancels the export. Watch folders, the clipboard and Shortcuts can't ask, so they save beside the originals.

## Also new

Every slider in a step's popover now has a box you can type the exact number into.

Shrinker Pro is still free. Studio comes with it, every tool works for your first 10 exports, and a one-time licence is at [shrinkerstudio.app](https://shrinkerstudio.app).
