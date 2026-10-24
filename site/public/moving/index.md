# Switch to Lilo from Safari, Chrome, Arc or Firefox

> Bring your bookmarks, open tabs, history, sign-ins and extensions to Lilo from Safari, Chrome, Arc, Firefox and eight more Mac browsers, in five minutes.

Web page: https://getlilo.app/moving/

**Moving to Lilo.**

Lilo reads your bookmarks, tabs, history, sign-ins and extensions straight from the browsers on your Mac. Nothing leaves your Mac, and your other browser stays exactly as it was.

- [Download for Mac](https://github.com/Alexays/Lilo/releases/latest/download/Lilo.dmg)
- [See what comes with you](https://getlilo.app/moving/#what)

## Twelve browsers, read on your Mac.

Lilo finds every browser and every profile on this Mac, and lists first the one that opens your links today.

| Browser | Bookmarks | Open tabs | History | Sign-ins | Extensions |
|---|---|---|---|---|---|
| Safari | Yes | Last session | Yes | Yes | No |
| **Chromium browsers** |  |  |  |  |  |
| Chrome | Yes | Last session | Yes | Yes | Yes |
| Brave | Yes | Last session | Yes | Yes | Yes |
| Edge | Yes | Last session | Yes | Yes | Yes |
| Vivaldi | Yes | Last session | Yes | Yes | Yes |
| Opera | Yes | Last session | Yes | Yes | Yes |
| Arc | Yes | Spaces and tabs | Yes | Yes | Yes |
| Dia | Yes | Last session | Yes | Yes | Yes |
| Comet | Yes | Last session | Yes | Yes | Yes |
| Chromium | Yes | Last session | Yes | Yes | Yes |
| **Firefox browsers** |  |  |  |  |  |
| Firefox | Yes | Last session | Yes | Yes | No |
| Zen | Yes | Last session | Yes | Yes | No |

- **Bookmarks.** The bookmarks bar becomes pinned tabs in your Space. Every other bookmark goes into one folder, and a folder inside a folder becomes its own folder, named by its path.
- **Open tabs.** The tabs of your last Safari, Firefox, Zen or Chromium browser session open in your Space, one window after the other. From Chrome and the other Chromium browsers, pinned tabs stay pinned and each tab group becomes a folder with its name and color. From Arc, each space comes in as a Lilo Space with its icon and color, its pinned and open tabs, folders and splits of up to four tabs. Arc favorites become bookmarked tabs.
- **History.** Up to your 50,000 most recent pages, so the command bar knows the sites you visit.
- **Sign-ins.** Cookies are copied, so you stay signed in to your sites. Expired ones are left out.
- **Extensions.** The ones from the Chrome Web Store are installed again from the store, up to date. You pick which.
- **Profiles.** The first profile you pick lands in your current Space. Each other one gets its own Lilo profile and Space, so its sign-ins stay apart. Extensions go to the first one.

## A few clicks, then you are home.

Import is part of the welcome tour. Skip it and come back whenever you like.

### 1. Pick your browser

On first launch, "Bring your favorites" lists the browsers on your Mac. Pick one, or open "Choose what to import" to select profiles, data and extensions.

### 2. Say yes to macOS

For a Chromium browser, macOS asks to let Lilo use its "Safe Storage" key, to read your sign-ins: click Allow. Safari needs Full Disk Access, one switch in System Settings.

### 3. Import again anytime

Settings, General, Import from another browser. Running it again adds only what is new: links already in a Space and pages already in your history are not doubled.

## Some things are better left where they are.

Lilo only reads what it needs and changes nothing in your other browser.

### Passwords and cards

Lilo never reads them and keeps no passwords itself. They stay in your password manager or iCloud Keychain, and setup offers to add your manager's extension.

### Extension data

Extensions arrive fresh from the store, so sign in to them or set them up again. Safari and Firefox extensions are not Chrome extensions and do not come along.

### Closed and private tabs

Only the tabs still open in your last session come in, each at the page it shows. Closed tabs, back history, private windows and the browser's own pages are left out.

### Site data beyond cookies

Site permissions, local storage and form data are not copied. A site that keeps you signed in with more than a cookie may ask you to sign in once.

### Reading List and other extras

Safari's Reading List, and anything in Arc's sidebar that is not a tab, a folder or a split, are skipped. Only web links (http and https) come in, and local files from a Chromium session.

### Settings

Search engine, downloads, themes and other preferences are not read. Set them once in Lilo's Settings.

## Your first week in Lilo.

A few things worth setting up once you have moved in.

### Keep your shortcuts

Settings, General, Shortcuts. Start from the Lilo or the Arc preset, then remap anything. Conflicts are flagged as you type.

### A profile per Space

Give Work and Perso their own profile, with their own cookies and extensions, side by side in one window.

`⌃1` `⌃2`

### Little window

A quick window from any app, for one link or one search. Send it to a Space when it turns into something.

`⌘⌥N`

### Peek

Links from pinned tabs open over the page. Shift-click any link to peek at it.

`⇧ click`

### Link rules

Settings, General, Links from other apps. Send this domain to Work, the rest to the Little window.

### Command bar

Your imported history and bookmarks are one search away, with tabs and every action.

`⌘T`

### Your password manager

Setup offers the one you use, such as Bitwarden, 1Password, Proton Pass, Dashlane, NordPass or KeePassXC.

### Open links in Lilo

Make Lilo your default browser in Settings, so links from Mail and Slack land here.

## About switching.

### Will my other browser change?

No. Lilo only reads its files and writes nothing back. Its bookmarks, its sync and its passwords stay as they are, so you can keep it around as long as you like.

### Do I need to quit it first?

No. Lilo copies its databases before reading them, along with changes the running browser has not written out yet.

### Why does macOS ask about "Safe Storage"?

Chromium browsers encrypt their cookies with a key kept in your keychain. Lilo needs that key to keep you signed in. If you say no, everything else still imports.

### Why does Safari need Full Disk Access?

macOS protects Safari's folder. Lilo shows an "Allow access" button that opens the right page in System Settings, and finds Safari again when you come back.

### I have several profiles. What happens?

Each one is listed. The first you pick fills your current Space; each other one gets its own Lilo profile and Space, named after it. Importing the same profile again reuses them.

### Some of my extensions did not come.

Lilo reinstalls extensions from the Chrome Web Store only, and runs Manifest V3. Extensions installed by hand are left out, and Manifest V2 ones or the few that need Chrome-only features do not install. The [compatibility notes](https://github.com/Alexays/Lilo/blob/main/COMPATIBILITY.md) list what differs.

### What about sync and my phone?

Lilo has no sync and no mobile app. Your other browser and your password manager keep syncing to your phone as before, since importing changes nothing in them.

## Ready to move in?

Download Lilo, pick your browser, and your things are there in a few minutes.

- [Download for Mac](https://github.com/Alexays/Lilo/releases/latest/download/Lilo.dmg)
- [Back to Lilo](https://getlilo.app/)

Lilo, made on a Mac for Macs. macOS 26 or later.

- [Moving to Lilo](https://getlilo.app/moving/)
- [Privacy](https://github.com/Alexays/Lilo/blob/main/PRIVACY.md)
- [GitHub](https://github.com/Alexays/Lilo)
- [Français](https://getlilo.app/fr/moving/)
