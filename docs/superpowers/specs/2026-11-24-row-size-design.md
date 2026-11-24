# Row size for the file list (short design)

Date: 2026-11-24 · Status: approved in conversation · Branch: `improvements`

**Intent:** the user wants to choose how dense the file list is: a compact list that shows more rows, today's list, and a large list that is easier to read and hit. The user approved this design as proposed.

**Today:** every row of the file list (`FileOutlineView`, `style = .fullWidth`) is 24 pt high with a 16 pt icon (`FileNameCellView`, `FileIconProvider.iconSize`) and 13 pt system text. Both panes and archive listings use the same list. View settings live in `ViewSettings` (`viewSettings.v1`, lenient decoding) and reach the list through `FileListController.applySettings()`.

## Approaches

- **More space only** (rows 20 / 24 / 32 pt, icon and text unchanged): cheapest, but a 16 pt icon in a 32 pt row looks empty.
- **Finder-like, bigger icons on Large** (rows 20 / 24 / 36 pt, icon 32 pt on Large): needs icons cached per size. **Picked by the user.**
- Bigger text as well: rejected; macOS has its own text-size settings, and the columns' widths would no longer fit.

## Behavior

| Row size | Row height | Icon | Text |
|---|---|---|---|
| Compact | 20 pt | 16 pt | 13 pt (unchanged) |
| Default | 24 pt | 16 pt | 13 pt (unchanged) |
| Large | 36 pt | 32 pt | 13 pt (unchanged) |

- **Setting:** Settings ▸ View, first row: "Row size" with Compact, Default, Large. Default is **Default**, which is exactly today's list.
- **Stored** in `ViewSettings` next to `showCheckboxColumn`. Settings saved by an older build, or an unknown value, read as Default.
- **Live:** a change applies at once in every open window, in both panes and in archive listings, without losing the selection, expanded folders or the scroll position.
- **Layout:** text, checkbox, tag dots, cloud status and the disclosure triangle stay vertically centered in the row.
- **Icons:** cached per size, so switching never shows a stretched or blurred icon, and icons already loaded for one size aren't thrown away.
- **Strings:** all four languages. de "Zeilenhöhe": Kompakt / Standard / Groß; fr "Hauteur des lignes" : Compacte / Standard / Grande; pl "Wysokość wierszy": Kompaktowa / Standardowa / Duża. *(My call: the label names the height, which is what changes for the user; en "Row size" matches Finder's sizing vocabulary.)*

## Non-goals

- A menu item or keyboard shortcut for the row size.
- Larger text.
- The sidebar's row size.
- Thumbnails instead of icons.

## Left to the builder

The type name and file for the size, how the cell's icon constraints follow the size, and how the list refreshes visible rows on a change.

## Docs

`reference/settings.md` (View) on docs.noix.dev changes with this feature.
