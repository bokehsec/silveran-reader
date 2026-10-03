# Reader customization

The reader's Customize sheet (Aa in the reader toolbar) and its More Options screen. Technical shape: [ARCHITECTURE.md › Reader appearance and Customize Reader](../ARCHITECTURE.md#reader-appearance-and-customize-reader).

## Product decisions

| Date | Decision | Status |
| --- | --- | --- |
| 2026-10-02 | The main sheet keeps only what people change while reading: text size, font, Light/Dark/System, theme, Pages/Scroll. Everything else goes one level down, in More Options. | Settled (owner) |
| 2026-10-02 | Text size changes with A− / A+ buttons in fixed steps, shown as a percentage of the default. No slider, no number entry. | Settled (owner) |
| 2026-10-02 | The reader has its own System / Light / Dark choice, so it no longer flips with the time of day unless set to System. The choice applies to the reader only; the library keeps following the device. | Settled (owner); reader-only scope chosen in implementation |
| 2026-10-02 | Built-in themes, each with a light and a dark version: Original, Paper, Calm (sepia), Quiet (soft grey). You pick a theme once; Light/Dark picks the version. | Settled (owner) |
| 2026-10-02 | Themes change colours only. Font and size stay the reader's own choice. | Settled (owner) |
| 2026-10-02 | Bold was proposed but dropped: with colours only, it would look the same as Original in light mode. It can return if themes ever include text weight. | Settled in implementation; owner may revisit |
| 2026-10-02 | New installs start on Paper. Existing installs keep their current theme. | Settled (owner) |
| 2026-10-02 | The theme and the Light/Dark choice both sync to the person's other devices. Font, size and layout stay per device class, as before. | Font part superseded 2026-10-03 |
| 2026-10-03 | The font is one choice for every book, and it follows the person to all their devices (iPhone, iPad, Mac). Text size, spacing and margins stay per device class, because they depend on the screen. No per-book fonts for now. | Settled (owner) |
| 2026-10-03 | When the chosen font isn't on a device (usually an imported font), that device shows System Default and keeps the choice; the font picker says "Not on this device. Showing System Default." Adding the font there switches to it. | Settled (owner) |
| 2026-10-02 | Highlight colour names (e.g. "Quotes") apply to every theme; only the colours belong to a theme (BF-058). | Settled in implementation |
| 2026-10-02 | Line spacing and margins are three presets each (Compact/Normal/Relaxed, Narrow/Normal/Wide). One margin choice sets both the side and the top/bottom margins. Word and letter spacing stay as sliders under Accessibility. Right-aligned text is no longer offered; "Justify Text" switches between justified and left-aligned. | Settled in implementation |
| 2026-10-02 | "Tap Margins to Turn Pages" and "Animate During Read-Aloud" moved to Display Options (…), because they change behaviour, not appearance. | Settled in implementation |
| 2026-10-02 | Reset is "Reset Text & Layout" in More Options, with a confirmation. It resets only what that screen and the main sheet show, never the theme or Display Options (BF-057). | Settled in implementation |

## Compatibility

- An older build that receives a theme selection it doesn't know (e.g. `builtin-paper`) rejects the whole synced appearance unit. It keeps its own appearance until it is updated, and the cloud value is preserved.
- Older builds ignore `reading.readerAppearance`. They still copy a theme's highlight names when switching themes, which can sync names back. Updated devices then keep those names.
- Font sharing (2026-10-03) uses a new shared key. After updating, nothing changes until someone picks a font; that choice then reaches every updated device. Older builds keep their per-device-class font and ignore the shared key, and updated builds ignore the old per-class key, which stays in iCloud unused. "Reset Text & Layout" resets the font too, so on an updated device it now resets the font everywhere. Restoring a backup made on another kind of device now brings its font along, as it already did for the theme.
- Values set before this change that fall between presets (e.g. 23 pt text, line spacing 1.55) stay as they are. The preset control shows none selected, and the size buttons step to the nearest neighbouring step.

## Acceptance record

Implementation and automated verification are complete. Simulator usability is partly accepted. Real-device and signed multi-device iCloud acceptance have not been done.

- Automated: `swift test` (portable suite plus Apple-hosted Kit tests on macOS) passes 468 tests, including 17 new ones in `ReaderDisplayPresetsTests.swift`: appearance decode/sync, size steps, presets, theme pairs, WCAG AA contrast for every built-in, Paper default, keeping existing selections, and theme switching keeping highlight names.
- Simulator, iPhone: unsigned Debug build on "Silveran Customize QA iPhone" (`1136C814-…`, a clone of the Phase 5 QA iPhone, iOS 18.6), with the synthetic "Phase 5 Field Notes" EPUB. Checked: the main sheet fits at its default height; Dark, Light and System (including live device light/dark changes); every theme swatch; A+ steps (100 → 108 → 117%); the font list (each name in its own typeface, Charter applied); More Options presets apply live; Reset restored defaults and kept the theme; choices survived an app relaunch; the library stayed in the device appearance while the reader was pinned to Dark; Display Options shows Page Turning and stays open (BF-059).
- Simulator, iPad: unsigned Debug build on "Silveran Customize QA iPad" (`D84BB6EE-…`, a clone of the Phase 5 QA iPad, iOS 18.6). An existing install kept Original. A fractional sheet height clipped the menu; the iPad now uses the full form sheet. The re-check shows every row, and choosing Paper applied it.
- QA hook: debug builds accept `-SilveranOpenCustomizeReader` and `-SilveranOpenDisplayOptions`, which open those sheets once the reader loads. Simulator taps arrive after the bars auto-hide, so the toolbar buttons cannot be tapped reliably there.

- Shared font (2026-10-03): `scripts/test --filter "ConfigurationPatchTests|ConfigurationSync"` passes 27 tests, including the new `typefaceIsSharedAcrossDeviceClassesButSizeIsNot` (a phone's font applies on a tablet, its text size does not, and a tablet font change publishes to the shared key). Simulator, iPhone: unsigned Debug build on the Customize QA iPhone (iOS 18.6) with the font set to a name not installed there. The book rendered in the System Default fallback; the Customize sheet showed the stored name; the font picker listed it under Your Fonts, selected, with "Not on this device. Showing System Default." The QA simulator's original font (Charter) was restored afterwards. Not checked: iPad, VoiceOver reading of the note, and real two-device iCloud delivery.

### Pending

- iPad landscape and Split View.
- VoiceOver: text-size adjustable action, swatch selected state, preset controls. Large Dynamic Type on the main sheet.
- Real device: rapid A+ taps (OD-030), the unexplained reader close (OD-031), the feel of each theme on a real display, and Pencil use with each theme.
- Signed multi-device: theme and Light/Dark choice syncing between iPhone and iPad, and the older-build behaviour described under Compatibility.
- The app-level Settings › Reading screen still has separate light and dark theme pickers. Aligning it with the family model is not scheduled.
