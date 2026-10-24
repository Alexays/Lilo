# Styles

`global.css` holds the theme: every color, size and timing token, declared on `:root` and
redeclared for dark mode, Increase contrast and Reduce transparency. `utilities.css` holds the
accent and text tints and the few classes shared across components. Components use these
tokens instead of literal values. The yardstick is macOS: when in doubt, match what a
first-party app does.

`src/styles/tokens.test.ts` (run by `make ui-test`) fails when a component's `<style>` block
has a literal hex/`rgb()`/`hsl()` color, a px `border-radius` or a px `font-size`. Files
that paint fixed artwork (onboarding illustrations, theme previews, the always-dark screenshot
surfaces) are allowlisted there by name.

## Type

| Token | Size | Use |
| --- | --- | --- |
| `--font-size-3xs` | 9px | Counters on an icon badge |
| `--font-size-2xs` | 10px | Keycaps, tiny meta labels |
| `--font-size-xs` | 11px | Section headers, captions, secondary meta |
| `--font-size-sm` | 12px | Row descriptions, compact rows, menus |
| `--font-size-md` | 13px | Body text, buttons, fields (the macOS body size) |
| `--font-size-lg` | 14px | Emphasized rows, onboarding rows |
| `--font-size-xl` | 16px | Panel and editor titles |
| `--font-size-2xl` | 20px | Page and settings titles |
| `--font-size-3xl` | 22px | Onboarding step titles |
| `--font-size-display` | 56px | The onboarding wordmark only |

Weights: `--font-weight-regular` (400), `-medium` (500, titles of rows and buttons),
`-semibold` (600, headings and emphasis), `-bold` (700, badges and section labels).

## Spacing

`--space-2`, `-4`, `-6`, `-8`, `-10`, `-12`, `-16`, `-20`, `-24`, `-32`: the name is the
value. Paddings, margins and gaps stay on this 2px grid; odd values are reserved for 1px
hairlines.

## Radii

| Token | Value | Use |
| --- | --- | --- |
| `--radius-2xs` | 2px | Progress bars, thin indicators |
| `--radius-xs` | 4px | Keycaps, small favicons, chips inside a row |
| `--radius-sm` | 6px | Icon buttons and icon tiles up to 30px, tooltips |
| `--radius-md` | 10px | Controls, rows, fields, banners, cards inside a panel |
| `--radius-lg` | 14px | Cards and floating bars, containers of `md` rows |
| `--radius-xl` | 16px | Overlay panels and sheets |
| `--radius-chip` | 999px | Pills and round badges |

A box nested in a padded one takes its parent's radius less the padding, as
`calc(var(--radius-md) - var(--space-2))` in `UiSegmented`. The popover family keeps its own
`--float-radius-*` tokens (`tip` and `card` alias `sm` and `md`).

## Controls

`--control-height-sm` (24px: compact buttons, segmented options, popover buttons),
`--control-height-md` (28px: `UiButton`, `UiSelect`, the segmented track, header icon buttons,
popover rows), `--control-height-lg` (32px: `UiTextField`, `UiSearchField`). Icons are 12px
(in rows and buttons), 14px (row icons) or 16px (panel headers and toolbars), drawn with a
stroke of about 1.5px on screen.

States share one recipe:

- hover `--bg-hover`, pressed `--bg-active`; a filled neutral button hovers to
  `--text-primary-tint-12`, a primary one to `--accent-hover`
- disabled `opacity: var(--disabled-opacity)` and `cursor: default`
- focus `outline: var(--focus-outline)` with `outline-offset: 1px`, or `-2px` on a box that
  clips its painting; text fields show the ring too, not an accent border

Prefer the `components/ui/Ui*` building blocks over hand-rolled controls.

## Color

Text: `--text-primary`, `--text-secondary` (descriptions), `--text-muted` (placeholders,
hints). Surfaces: `--bg-primary`, `--bg-secondary`, `--bg-elevated`, hover and active as
above. Lines: `--border` around controls, `--separator` between rows. Status:
`--accent`/`--accent-ink`, `--danger`/`--danger-text`, `--success`/`--success-text`,
`--warning`, `--attention`. Fixed roles: `--on-color` for text on a saturated fill (white),
`--accent-text` on the accent, `--on-pastel` for dark ink on a light fill, the
`--terminal-tile-*` set for terminal tab icons, `--diff-added`/`--diff-removed`,
`--chart-2`/`--chart-3`, `--hue-wheel`.

Tints mix a token with `transparent` (`color-mix(in srgb, var(--accent) 12%, transparent)`);
`utilities.css` names the common ones (`--accent-tint-*`, `--text-primary-tint-*`). A white or
black sheen uses the same notation with the `white`/`black` keyword. Floating surfaces
(`.float-surface`) reset the text and hover tokens to the app palette, since the sidebar tints
them per Space.

## Elevation

`--shadow-control` (a toggle knob, the segmented pill), `--shadow-sm` (a raised chip or
badge), `--shadow-md` (a floating card or menu; `--chrome-floating-shadow` aliases it).
Panels and popovers use `--chrome-overlay-shadow` and `--float-shadow`, which add the hairline
and inner highlight their surfaces need.

## Motion

Durations: `--motion-duration-fast` (120ms, hover and press; `--transition-fast` is it with
`ease`), `-normal` (200ms, appearing content), `-overlay` (220ms), `-slow` (280ms, panels).
Easings: `--motion-ease-standard`, `-organic`, `-spring`, `-bounce`. Reduce motion and
Low Power Mode collapse every animation and transition globally in `global.css`, so a
component only adds its own rule when it needs a still alternative rather than an instant one.
