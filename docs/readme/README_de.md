<div align="center">

[English](../../README.md) · [Français](README_fr.md) · [Español](README_es.md) · [简体中文](README_zh-Hans.md) · [Português (Brasil)](README_pt-BR.md) · [Русский](README_ru.md) · [Українська](README_uk.md) · **Deutsch** · [日本語](README_ja.md) · [Italiano](README_it.md)

# Lilo

**Dein Internet blüht auf.**

Leicht auf deinem Mac, schnell im Web, von Anfang an privat. Kostenlos und Open Source.

[![CI](https://github.com/Alexays/Lilo/actions/workflows/build.yml/badge.svg)](https://github.com/Alexays/Lilo/actions/workflows/build.yml)
[![Lizenz: MIT](https://img.shields.io/badge/License-MIT-6a4be0.svg)](../../LICENSE)
[![Status: öffentliche Beta](https://img.shields.io/badge/status-public%20beta-e07a4b.svg)](#installation)

[Website](https://getlilo.app) ·
[Discord](https://discord.gg/NyJRAapk76) ·
[Installieren](#installation) ·
[Aus dem Quellcode bauen](#aus-dem-quellcode-bauen) ·
[Dokumentation](../../docs/README.md) ·
[Mitwirken](../../CONTRIBUTING.md)

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../../docs/assets/lilo-dark.png">
  <img src="../../docs/assets/lilo-light.png" alt="Lilo mit geöffnetem Space „Arbeit“: Seitenleiste mit angehefteten Websites, Ordnern und Tabs neben einer Webseite und einem Terminal-Tab" width="900">
</picture>

</div>

Lilo ist ein Mac-Browser für Menschen, die in einer Seitenleiste zu Hause sind. Er ist kein weiterer
Chromium-Fork. Lilo ist nativ mit Swift und AppKit gebaut und nutzt die bereits in macOS enthaltene
WebKit-Engine. Trotzdem laufen die Chrome-Erweiterungen, auf die du dich verlässt. Terminal-Tabs
stehen neben deinen Seiten. Die KI-Agenten, die du bereits nutzt, können Lilo über einen integrierten
MCP-Server steuern – in einem eigenen Space. Kostenlos, MIT-lizenziert, ohne Konto. Wenn du von Arc
wechselst, importiert Lilo deine Spaces, angehefteten Tabs und Ordner mit wenigen Klicks.

> **Status: öffentliche Beta.** Lilo lässt sich im Alltag nutzen, ist aber noch eine Beta. Rechne
> mit Ecken und Kanten und einer Oberfläche, die sich noch verändert. Bitte
> [melde Probleme](https://github.com/Alexays/Lilo/issues).
> [ROADMAP.md](../../ROADMAP.md) nennt die Prioritäten und die Dinge, die bewusst nicht geplant sind.

Tritt der [Discord-Community](https://discord.gg/NyJRAapk76) bei, um Feedback zu teilen und Hilfe zu Lilo zu erhalten.

## Warum Lilo

Die meisten Arc-Alternativen sind Chromium mit einer neuen Seitenleiste. Lilo behält die Seitenleiste und ändert den Rest.

- **Kein Chromium.** Keine mitgelieferte Browser-Engine, kein Electron: Swift, AppKit und das WebKit
  des Systems, mit Seitenleiste und Einstellungen in Svelte. Weniger Speicherbedarf, eine Batterie,
  die den Tag über hält, und Apples Sicherheitsupdates mit jeder macOS-Version.
- **Von Anfang an privat.** Kein Konto, keine Telemetrie, keine Analysedaten, kein Server: Nichts von
  dem, was du tust, wird an das Projekt gesendet. Werbung und Tracker werden von Anfang an blockiert,
  websiteübergreifendes Tracking wird wie in Safari verhindert, und Global Privacy Control ist aktiv
  (macOS 27). Alle Anfragen, die Lilo selbstständig stellt, sind
  [aufgelistet, einschließlich einer Anleitung zum Abschalten](../../PRIVACY.md#requests-lilo-makes-on-its-own).
- **Chrome-Erweiterungen bleiben.** Wer Chromium verlässt, muss meist auch auf seine Erweiterungen
  verzichten. In Lilo lassen sich Erweiterungen aus dem Chrome Web Store mit einem Klick auf
  „Zu Lilo hinzufügen“ installieren. Sie laufen auf der nativen WebKit-Laufzeitumgebung
  ([COMPATIBILITY.md](../../COMPATIBILITY.md)).
- **Deine Agenten steuern Lilo, es hat keine eigene KI.** Kein aufgesetzter Chatbot: Die Agenten,
  die du bereits ausführst (Claude Code, Codex, Cursor oder jeder andere MCP-Client), nutzen über
  den integrierten MCP-Server einen echten Browser. Sie arbeiten in ihrem eigenen Space und einem
  temporären Profil und fragen dich, bevor sie etwas senden, bezahlen oder löschen.
- **Ein Terminal neben deinen Seiten.** Terminal-Tabs auf Ghostty-Basis stehen mit deinen Websites
  in der Seitenleiste und zeigen den Branch und ausstehende Änderungen ihres Repositorys an.
- **Dein Browser.** MIT-lizenziert. Die gesamte Oberfläche ist eine Svelte-Schicht über WebKit, die
  du ändern und in Sekunden neu bauen kannst.

## Funktionen

**Surfen**

- **Spaces und Profile**: Spaces mit Emoji und Farbe, jeweils mit eigenem Profil angemeldet.
  Wechsle per Wischgeste zwischen ihnen. Private Spaces vergessen beim Schließen alles.
- **Seitenleiste**: angeheftete Tabs, Favoriten, bis zu fünf Ebenen tief verschachtelte und sperrbare
  Ordner, Anordnen per Ziehen sowie Steuerelemente für Audio und die aktuelle Wiedergabe.
- **Befehlsleiste** (`Cmd+T`): Tabs, Verlauf, Lesezeichen, Spaces und alle Aktionen in einem Feld,
  nach deiner Nutzung sortiert.
- **Zuletzt verwendete Tabs** (`Ctrl+Tab`): Wechsle durch deine letzten Tabs aus allen Spaces in
  der Reihenfolge, in der du sie verwendet hast.
- **Vorschau**: Ein Link von einem angehefteten Tab zu einer anderen Website oder jeder mit
  `Shift` angeklickte Link öffnet sich über der Seite.
- **Kleines Fenster** (`Cmd+Option+N`, aus jeder App): ein kleines Fenster für einen Link oder eine
  Suche. Wenn mehr daraus wird, kannst du es in einen Space verschieben.
- **Tabs, die selbst aufräumen**: Nicht angeheftete Tabs, die du nicht mehr nutzt, werden nach einer
  pro Space festgelegten Zeit archiviert. `Cmd+Shift+K` leert sie, und das Archiv ist nur einen
  Tastendruck entfernt.
- **Linkregeln**: Links aus anderen Apps öffnen sich in dem Space oder kleinen Fenster, das eine
  Regel festlegt.
- **Geteilte Ansicht**: bis zu vier Tabs nebeneinander, beim Neustart wiederhergestellt.
- **Kurzbefehle**: Jeder Kurzbefehl lässt sich ändern, ausgehend von der Lilo- oder Arc-Vorlage.
- **Import**: Lesezeichen, offene Tabs und Spaces, Verlauf, Cookies und Erweiterungen aus Safari,
  Firefox, Zen und Chromium-Browsern (Chrome, Arc, Brave, Edge, Vivaldi, Opera, Dia, Comet,
  Chromium), direkt von deinem Mac gelesen.

**Erweiterungen und das Web**

- **Chrome-Erweiterungen**: Manifest V3 über WebKits native Erweiterungslaufzeitumgebung sowie kleine
  Swift-Handler für APIs, die WebKit fehlen ([COMPATIBILITY.md](../../COMPATIBILITY.md)).
- **Passwortmanager**: Die Einrichtung bietet den Manager an, den du bereits nutzt (1Password,
  Bitwarden, Dashlane, KeePassXC, NordPass, Proton Pass).
- **Streaming**: geschützte Videos und Musik über FairPlay; YouTube in 4K HDR.
- **Inhaltsblocker**: stets aktuelle Listen von EasyList, EasyPrivacy und uBlock Origin, mit
  kosmetischen Filtern und Scriptlets.
- **Bildschirmfotos**: Eine Aufnahme schwebt als Karte über der Seite und lässt sich mit Markierungen
  bearbeiten, sichern oder schließen.
- **Und mehr**: Reader-Modus, Bild-in-Bild (Anrufe schweben in einem dauerhaft sichtbaren Fenster),
  Seitenübersetzung, Web Serial, AppleScript, Kurzbefehle-Aktionen und ein Fokusfilter.

**Für alle, die entwickeln**

- **Terminal-Tabs**: libghostty-vt-Terminals mit Metal-Renderer neben deinen Seiten
  (`Cmd+D` daneben, `Cmd+Shift+D` darunter), mit Branch und ausstehenden Änderungen in der Seitenleiste.
- **Änderungsansicht**: alle Unterschiede im Repository, einschließlich Bildern.
- **Bleibt beim Arbeiten wach**: Ein langer Befehl hält den Mac wach, auch bei geschlossenem Deckel,
  und lässt ihn danach wieder schlafen.
- **Agenten über MCP**: der integrierte MCP-Server, siehe [Für KI-Agenten](#für-ki-agenten).

## Für KI-Agenten

Lilo hat einen integrierten MCP-Server. Aktiviere ihn, und die Agenten, die du bereits ausführst
(Claude Code, Claude Desktop, Codex, Cursor oder jeder andere MCP-Client), steuern neben dir einen
echten WebKit-Browser. Lilo bringt keine eigene KI mit.

- **Ihr eigener Space.** Agenten öffnen ihre Tabs in einem Ordner des Spaces „Agenten“, in einem
  temporären Profil, das nach jeder Sitzung gelöscht wird. Sie übernehmen weder deine Tastatur noch
  deine Maus oder deine Tabs und sehen nie einen privaten Space. Mit deiner Erlaubnis kann ein Agent
  eines deiner Profile verwenden.
- **Du stimmst zuerst zu.** Lilo fragt, bevor ein Agent etwas sendet, bezahlt, löscht oder veröffentlicht
  („Einmal erlauben“, „Auf dieser Website immer erlauben“ oder „Ablehnen“) und bevor er einer Seite
  eine deiner Dateien übergibt. Jeder Client wird einmal zugelassen. Die Erlaubnis ist an das
  dahinterstehende Programm gebunden, nicht an den Namen, den es angibt.
- **Mit einem Klick verbinden.** Aktiviere unter Einstellungen > KI-Agenten die Option „KI-Agenten
  die Nutzung von Lilo erlauben“. Klicke dann neben Claude Code, Claude Desktop, Codex oder Cursor auf
  „Verbinden“. Lilo trägt sich in die MCP-Server dieses Clients ein. Für andere Clients kopierst du
  die Konfiguration unter „Andere Agenten“.

Bitte deinen Agenten dann zum Beispiel um Folgendes:

```text
Öffne localhost:3000/checkout in Lilo, bezahle mit der Testkarte und finde heraus, warum die Bestellung fehlschlägt.
Prüfe die Konsole und das Netzwerk.
```

Die Werkzeuge decken Folgendes ab:

- **Tabs und Navigation** im Ordner des Agenten sowie isolierte Tabs ohne gemeinsame Cookies oder Anmeldungen.
- **Eingabe**: klicken, tippen, Tasten drücken, scrollen, ziehen, Formulare ausfüllen, Dateien und Bilder hochladen.
- **Seiten lesen**: der Bedienungshilfenbaum mit Elementreferenzen, Textsuche und Seitentext.
- **Bildschirmfotos** einer ganzen Seite oder eines Elements sowie GIF-Aufnahmen.
- **Konsole und Netzwerk**: Meldungen, Anfragen mit vollständigen Antworten, HAR-Export, Cookies.
- **Netzwerksimulation und Emulation**: simulierte, fehlgeschlagene oder verzögerte Anfragen; User-Agent,
  Farbschema, reduzierte Bewegung, Druckmedien, zusätzliche Header, Initialisierungsskripte; Viewport-Größe.
- **Leistung**: Lade- und Darstellungsmetriken, Speicher und Zeitleistenprofile.
- **Webinformationen**: WebKits eigenes Inspector-Protokoll, Befehle und Ereignisse.
- **Skripte**: JavaScript in der Seite, `fetch` aus einem Tab mit dessen Cookies sowie `run` oder
  `browser_batch`, um viele Aufrufe in einem einzigen Austausch zu verketten.
- **Profile**: auflisten, mit deiner Erlaubnis eines verwenden oder das temporäre Profil zurücksetzen.

[docs/AI-AGENTS.md](../../docs/AI-AGENTS.md) erklärt die Details: wofür nachgefragt wird, wofür nicht und
bei welchen Fehlern du eingreifen musst.

## Installation

Du kannst entweder:

- die DMG-Datei von [Releases](https://github.com/Alexays/Lilo/releases/latest) herunterladen oder
- mit Homebrew installieren:

  ```bash
  brew install --cask alexays/tap/lilo
  ```

Lilo aktualisiert sich selbst über signierte Sparkle-Updates.

### Voraussetzungen

- macOS 26 oder neuer. Global Privacy Control benötigt macOS 27.

## Aus dem Quellcode bauen

Mit installiertem Xcode 27 und Node.js 22.6+ ([alle Voraussetzungen](../../CONTRIBUTING.md#requirements)):

```bash
git clone https://github.com/Alexays/Lilo.git && cd Lilo
make bootstrap                  # prüft Voraussetzungen und lädt oder baut, was die App benötigt
make install                    # Release-Build nach /Applications, ersetzt eine installierte Kopie
open /Applications/Lilo.app
```

`make bootstrap` nennt fehlende Komponenten und erklärt, wie du sie installierst. Um nur an der
Oberfläche zu arbeiten, genügt Node.js: `make ui-preview` öffnet sie mit automatischem Neuladen im Browser
([CONTRIBUTING.md](../../CONTRIBUTING.md#interface-only)).

Du brauchst keinen Apple-Developer-Account. Selbst gebaute Versionen werden standardmäßig ad hoc signiert.
[CONTRIBUTING.md](../../CONTRIBUTING.md#signing) erklärt die Vor- und Nachteile und die Signierung mit
einer kostenlosen Apple-ID.

## Dokumentation

- [docs/](../../docs/README.md): Architektur, Fehlersuche, Lokalisierung, Veröffentlichungen, KI-Agenten
- [COMPATIBILITY.md](../../COMPATIBILITY.md): verbleibende Unterschiede zu Chrome bei Erweiterungen und Websites
- [PRIVACY.md](../../PRIVACY.md): alle Anfragen, die Lilo selbstständig stellt
- [ROADMAP.md](../../ROADMAP.md): was verfügbar ist, was als Nächstes kommt und was bewusst nicht geplant ist

## Mitwirken

Pull Requests sind willkommen. [CONTRIBUTING.md](../../CONTRIBUTING.md) beschreibt die Einrichtung,
den Entwicklungsablauf und die Checkliste für Pull Requests. Fragen gehören in die
[Discussions](https://github.com/Alexays/Lilo/discussions) ([SUPPORT.md](../../SUPPORT.md)),
Sicherheitslücken werden vertraulich gemeldet ([SECURITY.md](../../SECURITY.md)). Alle Beteiligten
halten sich an den [Verhaltenskodex](../../CODE_OF_CONDUCT.md).

## Lizenz

MIT, siehe [LICENSE](../../LICENSE). Mitgelieferte Komponenten von Drittanbietern sind in
[THIRD-PARTY-NOTICES.md](../../THIRD-PARTY-NOTICES.md) aufgeführt.
