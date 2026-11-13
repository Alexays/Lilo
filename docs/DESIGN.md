# Consistency rules

The rules every Lilo screen follows, whatever the tab layout or appearance. They make the design bar in [AGENTS.md](../AGENTS.md) (Apple and Arc) concrete: a screen that breaks one is not done. The tokens named here live in `lilo-ui/src/styles/`.

## Fixed landmarks

Four elements keep the same place in all twelve layouts (tabs left, right, top, bottom; address with the tabs, above the page, hidden):

| Landmark | Place |
|---|---|
| Sidebar toggle | Top left, next to the traffic lights, even with the tabs on the right |
| Back, Forward, Reload | Attached to the address, never anywhere else |
| Space switcher | At the start of the tab collection: bottom of the column, start of the strip |
| Update card | At the bottom of the tab collection, with its animation: it is meant to make people want to update |

- With the sidebar hidden, nothing stays over the page: the left edge slides the sidebar back with its landmarks, and ⇧⌘S toggles it.
- Back and Reload never leave their line; on a narrow sidebar only an unavailable Forward gives way. Each layout has a minimum sidebar width that keeps its top line whole, nothing past the edge: 203 pt with the address in the sidebar, 243 pt with the address hidden and Agents on, 215 pt without Agents.
- With the tabs on the left or the right, dragging the sidebar's edge under 150 pt folds it to an 84 pt icon rail, wide enough to center the traffic lights with 15 pt on either side, and back past 150 pt unfolds it at its width; the minimums above hold only outside the rail. Top to bottom, centered: the traffic lights' row, the toggle, Search (the command bar carries the address, the history and Agents), the favorites, pinned and today's tabs as 16 pt icons in 30 pt targets (the active one on the selected surface, its badges kept), folders by their icon, then the update and the Spaces as dots at the bottom. Each icon has its tooltip.
- The rail never unfolds on hover. A folder opens its tabs in a popover beside the rail, toward the page, sleeping ones included; a locked one offers to unfold the sidebar to unlock it. With the sidebar hidden, the window's edge reveals the rail over the page, not the full sidebar.
- With the address hidden, the page's buttons (site controls, content blocking, screenshot, copy link, extensions) wait behind one button at the end of the top line and open in a row under it.
- Every layout setting changes the screen. A combination with no effect is disabled, with a sentence saying why.
- Tabs at the bottom: navigation and address share that bottom bar. The top of the window is the page.

## Surface families

A piece of information takes the form of its family, never another.

| Family | Form | Examples | Dismissed by |
|---|---|---|---|
| Status | Badge on a fixed landmark, or for a passing confirmation a word in the address field itself for 1.4 s, a new one replacing the last | Download in progress, agent waiting; link copied, zoom level, extension installed | Clears itself |
| Toast | Capsule at the bottom center of the page, one at a time, queued, 5 s (6 s for a notice to read) | Tab closed, screenshot copied or saved, capture cut short | Time, or its action |
| Drawer | Floats over the content, anchored to its source by an arrow | Site permissions, agent or extension requests | Its buttons, Esc |
| Popover | Anchored to its button | Extensions, Agents, archived tabs | Esc, click outside |
| Modal | Centered on the page area, dimming it, blocking, no close button | Clear browsing data, agent connection, What's New; an unresponsive page | Its buttons, Esc |
| System screen | With a sidebar, the sidebar becomes its navigation and the page area its content; with tabs at the top or bottom, a tab with the same navigation inside | Settings, History, Downloads, Processes | Its close button, Esc |
| Sidebar editor | Inside the sidebar alone; the page stays visible and the sidebar repaints live as its own preview | New Space, Space editor | Its buttons, Esc |

- Nothing pushes the tab list or the page: a drawer or a popover covers, it never inserts itself.
- A download joins a stack of cards above the downloads button as it starts (progress, Pause, Cancel) and comes back to its front as it ends: drag the file out or click to open it. The stack leaves after 6 s, shows at most three cards, the older ones as slivers behind the newest until the pointer or the keyboard fans them out. It covers the end of the tab list and takes no focus.
- A system screen in the sidebar is one navigation level: a close button on the right of the traffic lights line, then the title, the search field and the navigation list, in the same places for every system screen. It slides in from the side and back; nothing else in the sidebar changes shape.
- The page area of a system screen holds its content: a 20 px semibold title top left, a short count or note top right, then the content. It is never left blank or showing an unrelated page.
- A system screen edits live: no Cancel and Save pair. Its sidebar holds only places; its commands sit behind one "..." button at the end of the page header, a destructive one last, in red, under a separator.
- A setting that only matters under a switch is a nested row in the same box, indented 38 px, and disappears when the switch is off.
- A switch whose two states look different (calls docked or floating) is chosen from two thumbnails.
- A visual choice shows itself: a material, theme or layout is picked from thumbnails of the result, as macOS does for Light and Dark, never from a word in a menu. Beside a live preview that already shows the result, a segmented control with a small icon per choice is enough.
- One object, one row, everywhere: a 32 to 40 px visual (favicon, file icon, image preview), the name, one line of detail under it, and one accessory on the right.
- Nothing repeats what sits beside it: no initial avatar next to a name, no count next to the items it counts. A profile shows its color as a dot, the same dot everywhere it is chosen.
- One banner at a time; the next ones collapse into "N more notices" in the same capsule.

## Buttons

- The default button is last, on the right. Cancel sits just before it. A destructive action stands apart, on the left, in the `danger` style.
- Labels are verbs: "Allow", "Don't Allow", "Close Tab". Never "Deny", and never "Cancel" for stopping something ("Stop Debugging"). "OK" only closes an alert that just informs and has no other button, as the HIG allow.
- A variant of a choice ("always", "for this site") is a menu attached to the default button, not a third button.
- Segmented-control labels are Title Case, like buttons.
- ⌘↩ triggers the default button of a drawer or modal; Esc triggers Cancel.

## Badges

| Meaning | Form |
|---|---|
| Unread items | 14 px count badge, accent color |
| Your action is awaited | 6 px system orange dot |
| Working | Small spinner badge on the icon |

Nothing else. A badge sits on a fixed landmark or a tab row, never on a navigation button.

- The Agents button is the only entry point to Agents in the chrome: a 28 px square beside Reload, shown whenever Agents are on. A ring turns around the mascot while an agent works; the 6 px orange dot says one waits for you, its label and tooltip say how many; both can show at once. Its popover starts with New; with no conversation to list, the button opens New directly. When the top line can no longer hold it beside Reload with the address in the sidebar, it moves into the address field as a 24 px button at its trailing end, ring and dot included: ask an agent about this page.

## Tab rows

A web, terminal or agent tab has the same row:

- a 16 px icon in a `--radius-xs` square: the favicon, else the domain's first letter on its derived color, everywhere (sidebar, strip, switcher, command bar); an agent shows its provider's icon;
- the title;
- one accessory slot on the right, holding the most useful information for the type (audio for a site, the running command for a terminal, the diff for an agent), replaced by ✕ on hover;
- a state (unresponsive page, agent waiting) is added as a badge on the icon, never replacing it;
- the same context menu: Duplicate, Pin, Move to Space, Close.

A request tied to a tab lives in a single drawer; the row keeps only the orange dot.

## Text

- Title Case for menu items, buttons and window titles, as macOS does; sentence case everywhere else (labels, descriptions, section headers, notices).
- An ellipsis only when the action asks for more input before it runs: `...` in the web chrome's strings, the single ellipsis character (U+2026) in native menu items, as AppKit writes them.
- Type scale, nothing off it: 16 px semibold for the sidebar panel title, 20 px semibold for a system screen's page title, 17 px semibold for a modal title and 13 px semibold for a popover title, 17 px regular for a large search field (command bar, empty window), 13 px (`--font-size-md`) medium for a row title and regular for body text, 12 px for details, buttons and menus, 11 px (`--font-size-xs`) semibold uppercase with 0.04em tracking for section headers and regular for counts, 10 px (`--font-size-2xs`) only inside thumbnails. Onboarding alone uses 28 px semibold headlines and 15 px body.

## Spacing and sizes

- Spacing sits on a 4 px grid: 4, 8, 12, 16, 20, 24, 28, 40. A page area is padded 28 px at the top and 40 px at the sides; a section header has 22 px above it and 8 px below.
- A grouped row is padded 11 px by 14 px, a nested row is indented 38 px; an icon sits 14 px from its text in an object row, 8 px in a navigation row.
- Heights: 24 px for buttons, selects and segmented controls, 28 px for a navigation row, 32 px for a plain list row and the sidebar search field, 52 to 58 px for a row with a detail line; a switch is 32 by 19 px.
- Visuals: 16 px inline and navigation icons, 32 px favicons in lists (24 px in the command bar's 40 px rows, 20 px in its bookmark strip), 40 px file or image visuals (a finished download shows Quick Look's thumbnail of the file, else its type's icon), 44 px app tiles. Thumbnails offered as one choice share one size.
- The same element has the same metrics on every screen: a section header, a grouped row or a page title never varies from one screen to the next.
- One concept, one name:

| Say | Not |
|---|---|
| Agents (the feature), "Ask an agent" (the action) | AI agents, Ask AI |
| Space | space |
| Archived | Archive, Recently archived |
| Command bar | Omnibox, URL bar |
| Settings | Preferences |

## The Space color

The sidebar paints the Space's effective color as is, never toned down: the chosen color, or what its color mode makes of it (lit by the time of day, taken from the page or the wallpaper). Everything on it derives from that effective color and its text color, so it stays legible on any color, at any time of day, on Glass or Grain:

- Contrast is measured with APCA (the perceptual model of the WCAG 3 drafts), not the WCAG 2 ratio, which picks dark text on a medium blue or a saturated red where white reads far better. The same holds everywhere a color is picked for legibility: the native window frame, extension badges, favicons on the sidebar and the terminal palette (Lc 60, Lc 45 for its grays on dark).
- Text is `#1d1d1f` or `#f8f9fd`, whichever reads better by APCA; under Lc 60, pure black or white of that polarity, the best the color allows. Secondary text stays at Lc 60 and icons at Lc 45 where the color allows it, else they take the text color.
- In dark mode, the sidebar darkens in the Space's hue until its text reaches Lc 75 on the selected and pressed rows.
- Hover, pressed, separators and quiet fields are translucent layers of the text color, never a new hue.
- The selected tab, the update card and the pinned tiles are a lighter shade of the Space color, never a white chip: they belong to the sidebar.
- The accent (count badges, the update card's button) is the Space's own hue, darker or lighter until it reaches Lc 45 against the sidebar and the selected surface, and Lc 60 for its label.
- A badge that sits on the color (the orange dot, a count) gets a 2 px ring in the sidebar color.

## Loading and empty states

- No "Loading" text in the chrome. Past 300 ms, a quiet centered indicator; before that, nothing.
- An empty state has a 32 px icon, one sentence and one action. A window with no tab shows the command bar in place, with frequent sites and recent conversations.
- A counter ("unresponsive for") appears only from 5 s.

## Panel headers

A panel's title is 13 px semibold and a system screen's page title 20 px semibold, the main action on the right as a text button, a search field only when the list can exceed twenty items. Section headers are small caps alone; a colored icon appears only in a navigation list.

## Shapes

| Element | Radius |
|---|---|
| Controls, square chips | `--radius-sm` (6 px) |
| Page, cards, highlighted rows, thumbnails | `--radius-md` (10 px) |
| Grouped boxes, app tiles | 12 px |
| Popovers, drawers, modals | `--radius-lg` (14 px) |
| Capsules, toasts | `--radius-chip` |

## Motion

| Surface | In | Out |
|---|---|---|
| Popover, drawer | `--motion-duration-overlay` with `--motion-ease-spring` from its source, scale 0.96 to 1 | `--motion-duration-fast` fade |
| Modal | `--motion-duration-overlay` with `--motion-ease-spring`, scale 0.96 to 1 while the page dims | `--motion-duration-fast` fade |
| Toast | `--motion-duration-normal`, rises 8 px while fading in | `--motion-duration-fast` fade |
| Space change | Horizontal slide | The same |

Nothing else animates. With Reduce motion, everything becomes a 150 ms fade. A surface that can open and close within 150 ms (the tab switcher) shows nothing before that delay.

## Keyboard and focus

- A surface that opens moves focus to its first useful control and returns it to its trigger on close; Tab stays inside an open drawer or modal.
- A shortcut is shown as keycaps 20 px high, 6 px radius, 11 px text (the shared `.keycap` class); a tooltip fits its shortcut on its line as a 16 px keycap. In a palette footer the Return action comes first.
- A shortcut shown anywhere (command bar footer, menus, ⌘? help) comes from the same table as the one that runs.

## First run

One full-bleed container from start to finish. Welcome stays almost empty: the mark, one line and Get Started. Then one question per screen: How will you use Lilo (thumbnails of each answer's result), Import (passwords included), Your Lilo (a live preview beside rows of settings for its look), Agents when that path is chosen. Tips arrive in context, the first time the user does the thing.
