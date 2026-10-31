<div align="center">

# Lilo

**De Mac-browser in de stijl van Arc, op WebKit en niet op Chromium.**

Je Chrome-extensies, terminaltabbladen naast je pagina's en een ingebouwde MCP-server voor je AI-agents. Gratis, open source, zonder account.

[![Download voor macOS](https://img.shields.io/badge/Download%20voor%20macOS-6a4be0?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/Alexays/Lilo/releases/latest/download/Lilo.dmg)

`brew install --cask alexays/tap/lilo` · macOS 26 of nieuwer

[![Release](https://img.shields.io/github/v/release/Alexays/Lilo?color=e07a4b)](https://github.com/Alexays/Lilo/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/Alexays/Lilo/total?color=6a4be0)](https://github.com/Alexays/Lilo/releases)
[![Stars](https://img.shields.io/github/stars/Alexays/Lilo?color=6a4be0)](https://github.com/Alexays/Lilo/stargazers)
[![Licentie: MIT](https://img.shields.io/badge/License-MIT-6a4be0.svg)](../../LICENSE)

[Website](https://getlilo.app) ·
[Discord](https://discord.gg/NyJRAapk76) ·
[Overstappen van Arc](#overstappen-van-arc) ·
[Documentatie](../README.md) ·
[Bijdragen](../../CONTRIBUTING.md)

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../assets/lilo-dark.png">
  <img src="../assets/lilo-light.png" alt="Lilo met de ruimte Werk geopend: navigatiekolom met vastgemaakte websites, mappen en tabbladen, naast een webpagina en een terminaltabblad" width="900">
</picture>

<sub>[English](../../README.md) · [Français](README_fr.md) · [Español](README_es.md) · [简体中文](README_zh-Hans.md) · [Português (Brasil)](README_pt-BR.md) · [Русский](README_ru.md) · [Українська](README_uk.md) · [Deutsch](README_de.md) · [日本語](README_ja.md) · [Italiano](README_it.md) · [한국어](README_ko.md) · [繁體中文](README_zh-Hant.md) · [Polski](README_pl.md) · [Türkçe](README_tr.md) · **Nederlands**</sub>

</div>

Lilo is een Mac-browser voor mensen die vanuit een navigatiekolom werken, en geen nieuwe Chromium-fork.
De browser is gebouwd met native Swift en AppKit, op de WebKit-engine die al in macOS zit, en kan toch
de Chrome-extensies uitvoeren waarop je vertrouwt. Terminaltabbladen staan naast je pagina's, en de
AI-agents die je al gebruikt kunnen de browser via een ingebouwde MCP-server bedienen, in een eigen
ruimte. Gratis, met MIT-licentie, zonder account. Stap je over van Arc, dan importeert Lilo je ruimtes,
vastgemaakte tabbladen en mappen in een paar klikken.

> **Status: openbare bèta.** Lilo is geschikt voor dagelijks gebruik, maar is nog een bèta: verwacht
> onvolkomenheden en een interface die nog verandert. [Meld wat er misgaat](https://github.com/Alexays/Lilo/issues).
> [ROADMAP.md](../../ROADMAP.md) beschrijft de prioriteiten en wat buiten de plannen valt.

Sluit je aan bij de [Discord-community](https://discord.gg/NyJRAapk76) om feedback te geven en hulp bij Lilo te krijgen.

## Overstappen van Arc

Arc stopt op 22 december 2026. Lilo houdt vast aan browsen vanuit een zijbalk en importeert wat je in Arc hebt rechtstreeks vanaf je Mac, zonder er iets in te veranderen:

- **Spaces, tabbladen en gesplitste weergaven**: elke Arc-space wordt een Lilo-space met zijn icoon en kleur, vastgezette en geopende tabbladen, mappen en gesplitste weergaven. Favorieten worden bladwijzertabbladen.
- **Geschiedenis en aanmeldingen**: je recente pagina's verschijnen in de opdrachtbalk en cookies worden gekopieerd, zodat je aangemeld blijft.
- **Extensies**: die uit de Chrome Web Store worden opnieuw uit de store geïnstalleerd. Jij kiest welke.
- **Sneltoetsen**: begin met de Arc-voorinstelling en wijs daarna toe wat je wilt.

Wat verandert is de engine: WebKit in plaats van Chromium. Met dezelfde tabbladen verbruikt Chrome ongeveer 3 keer zoveel energie als Lilo ([gemeten](../ENERGY.md)), en een paar API's voor Chrome-extensies verschillen nog ([COMPATIBILITY.md](../../COMPATIBILITY.md)). [De pagina over het Arc-alternatief](https://getlilo.app/arc-alternative/) vergelijkt ze functie voor functie.

## Waarom Lilo

De meeste Arc-alternatieven zijn Chromium met een nieuwe navigatiekolom. Lilo houdt de navigatiekolom en verandert de rest.

- **Geen Chromium.** Geen meegeleverde browserengine, geen Electron: Swift, AppKit en de systeemversie
  van WebKit, met de navigatiekolom en instellingen in Svelte. Minder geheugengebruik, een batterij die
  de dag meegaat en de beveiligingsupdates van Apple bij elke macOS-versie.
- **Standaard privé.** Geen account, telemetrie, analyses of server: niets wat je doet wordt naar het
  project gestuurd. Advertenties en trackers worden direct geblokkeerd, tracking tussen websites is
  geblokkeerd zoals in Safari en Global Privacy Control staat aan (macOS 27). Elk verzoek dat Lilo
  zelf doet, staat [vermeld, met uitleg om het uit te schakelen](../../PRIVACY.md#requests-lilo-makes-on-its-own).
- **Toch Chrome-extensies.** Chromium verlaten betekent meestal ook zijn extensies achterlaten. In
  Lilo installeer je Chrome Web Store-extensies met één klik op 'Voeg toe aan Lilo', in de native
  runtime van WebKit ([COMPATIBILITY.md](../../COMPATIBILITY.md)).
- **Jouw agents bedienen de browser, zelf heeft hij geen AI.** Geen toegevoegde chatbot: de agents die
  je al draait (Claude Code, Codex, Cursor of elke MCP-client) gebruiken een echte browser via de
  ingebouwde MCP-server, in een eigen ruimte en tijdelijk profiel. Ze vragen je voordat ze iets
  versturen, betalen of verwijderen.
- **Een terminal naast je pagina's.** Terminaltabbladen op basis van Ghostty staan bij je websites in
  de navigatiekolom, met de branch en openstaande wijzigingen van hun repository.
- **Van jou.** MIT-licentie. De hele interface is een Svelte-laag boven WebKit die je kunt aanpassen
  en binnen enkele seconden opnieuw kunt bouwen.

## Functies

**Surfen**

- **Ruimtes en profielen**: ruimtes met een emoji en een kleur, elk aangemeld met een eigen profiel;
  veeg om ertussen te wisselen. Privéruimtes vergeten alles wanneer je ze sluit.
- **Navigatiekolom**: vastgemaakte tabbladen, favorieten, mappen tot vijf niveaus diep (vergrendelbaar),
  slepen om te ordenen en bediening voor audio en afspelen.
- **Commandobalk** (`Cmd+T`): tabbladen, geschiedenis, bladwijzers, ruimtes en elke actie in één veld,
  gerangschikt op basis van je gebruik.
- **Recente tabbladen** (`Ctrl+Tab`): wissel tussen je laatste tabbladen uit alle ruimtes, in de
  volgorde waarin je ze gebruikte.
- **Voorvertoning**: een link van een vastgemaakt tabblad naar een andere website, of elke link
  waarop je met `Shift` klikt, opent boven de pagina.
- **Klein venster** (`Cmd+Option+N`, vanuit elke app): een klein venster voor één link of zoekopdracht,
  dat je naar een ruimte stuurt zodra je ermee verder wilt.
- **Tabbladen die zichzelf opruimen**: niet-vastgemaakte tabbladen die je niet meer gebruikt, worden
  gearchiveerd na een periode die je per ruimte kiest; `Cmd+Shift+K` wist ze, en het archief is één
  toetsaanslag weg.
- **Linkregels**: links uit andere apps gaan naar de ruimte of het kleine venster dat een regel kiest.
- **Gesplitste weergave**: maximaal vier tabbladen naast elkaar, hersteld bij opnieuw openen.
- **Sneltoetsen**: elke sneltoets kan worden aangepast, met de voorinstelling van Lilo of Arc als basis.
- **Importeren**: bladwijzers, geopende tabbladen en ruimtes, geschiedenis, cookies en extensies uit
  Safari, Firefox, Zen en Chromium-browsers (Chrome, Arc, Brave, Edge, Vivaldi, Opera, Dia, Comet,
  Chromium), rechtstreeks gelezen van je Mac.

**Extensies en het web**

- **Chrome-extensies**: Manifest V3 via de native extensieruntime van WebKit, plus kleine
  Swift-handlers voor API's die WebKit mist ([COMPATIBILITY.md](../../COMPATIBILITY.md)).
- **Wachtwoordmanagers**: tijdens de configuratie kun je kiezen welke je gebruikt (1Password,
  Bitwarden, Dashlane, KeePassXC, NordPass, Proton Pass).
- **Streaming**: beveiligde video en muziek via FairPlay; YouTube in 4K HDR.
- **Materiaalblokkering**: actuele lijsten van EasyList, EasyPrivacy en uBlock Origin, met
  cosmetische filtering en scriptlets.
- **Schermafbeeldingen**: een opname zweeft als kaart boven de pagina, klaar om te bewerken met
  markeringen, te bewaren of te sluiten.
- **En meer**: Reader, beeld in beeld (gesprekken zweven in een paneel dat altijd vooraan staat),
  paginavertaling, Web Serial, AppleScript, Opdrachten-acties en een focusfilter.

**Voor ontwikkelaars**

- **Terminaltabbladen**: libghostty-vt-terminals met Metal-weergave naast je pagina's
  (`Cmd+D` ernaast, `Cmd+Shift+D` eronder), met de branch en openstaande wijzigingen in de navigatiekolom.
- **Wijzigingenweergave**: alle verschillen in de repository, inclusief afbeeldingen.
- **Blijft wakker tijdens het werken**: een lang commando houdt de Mac wakker, ook met gesloten klep,
  en laat hem daarna weer sluimeren.
- **Agents via MCP**: de ingebouwde MCP-server, zie [Voor AI-agents](#voor-ai-agents).

## Voor AI-agents

Lilo heeft een ingebouwde MCP-server. Zet die aan en de agents die je al gebruikt (Claude Code,
Claude Desktop, Codex, Cursor of elke MCP-client) bedienen een echte WebKit-browser naast je.
Lilo heeft zelf geen AI.

- **Een eigen ruimte.** Agents openen hun tabbladen in een map van de Agents-ruimte, in een tijdelijk
  profiel dat na elke sessie wordt gewist. Ze nemen nooit je toetsenbord, muis of tabbladen over en
  zien nooit een privéruimte. Een agent kan met jouw toestemming een van je profielen gebruiken.
- **Jij geeft eerst toestemming.** Lilo vraagt voordat een agent iets verstuurt, betaalt, verwijdert
  of publiceert (Sta één keer toe, Sta altijd toe op deze website of Weiger), en voordat hij een
  bestand van jou aan een pagina geeft. Elke client wordt één keer goedgekeurd, gekoppeld aan het
  achterliggende programma en niet aan de naam die de client opgeeft.
- **Verbinden met één klik.** Zet in Instellingen > AI-agents 'Laat AI-agents Lilo gebruiken' aan en
  druk op Verbind naast Claude Code, Claude Desktop, Codex of Cursor: Lilo voegt zichzelf toe aan de
  MCP-servers van die client. Voor andere clients kopieer je de configuratie uit 'Andere agents'.

Vraag je agent daarna bijvoorbeeld:

```text
Open localhost:3000/checkout in Lilo, betaal met de testkaart en zoek uit waarom de bestelling mislukt.
Controleer de console en het netwerk.
```

De tools omvatten:

- **Tabbladen en navigatie** in de map van de agent, en geïsoleerde tabbladen zonder gedeelde cookies of aanmeldingen.
- **Invoer**: klikken, typen, toetsen, scrollen, slepen, formulieren invullen en bestanden of afbeeldingen uploaden.
- **Pagina's lezen**: de toegankelijkheidsboom met elementverwijzingen, tekst zoeken en de paginatekst.
- **Schermafbeeldingen** van een volledige pagina of één element, en gif-opnamen.
- **Console en netwerk**: berichten, verzoeken met volledige antwoorden, HAR-export en cookies.
- **Netwerksimulatie en emulatie**: gesimuleerde, mislukte of vertraagde verzoeken; useragent, kleurenschema,
  minder beweging, afdrukmedia, extra headers, initialisatiescripts en viewportgrootte.
- **Prestaties**: laad- en weergavemetingen, geheugen en tijdlijnprofielen.
- **Webinfovenster**: het eigen inspectorprotocol van WebKit, met commando's en gebeurtenissen.
- **Scripts**: JavaScript in de pagina, `fetch` vanuit een tabblad met de bijbehorende cookies en
  `run` of `browser_batch` om meerdere aanroepen in één uitwisseling te combineren.
- **Profielen**: opvragen, er een gebruiken na jouw toestemming of het tijdelijke profiel opnieuw instellen.

[docs/AI-AGENTS.md](../AI-AGENTS.md) beschrijft de details: wanneer er toestemming wordt gevraagd,
wanneer niet en welke fouten jouw aandacht vereisen.

## Installeren

Je kunt:

- de DMG downloaden via [Releases](https://github.com/Alexays/Lilo/releases/latest), of
- installeren met Homebrew:

  ```bash
  brew install --cask alexays/tap/lilo
  ```

Lilo werkt zichzelf bij via ondertekende Sparkle-updates.

### Vereisten

- macOS 26 of nieuwer. Global Privacy Control vereist macOS 27.

## Bouwen vanuit broncode

Met Xcode 27 en Node.js 22.6+ geïnstalleerd ([alle vereisten](../../CONTRIBUTING.md#requirements)):

```bash
git clone https://github.com/Alexays/Lilo.git && cd Lilo
make bootstrap                  # controleert vereisten en haalt of bouwt wat de app nodig heeft
make install                    # Release-build naar /Applications; vervangt een geïnstalleerde versie
open /Applications/Lilo.app
```

`make bootstrap` geeft aan wat er ontbreekt en hoe je het installeert. Om alleen aan de interface te
werken, is Node.js voldoende: `make ui-preview` opent die in je browser met direct herladen
([CONTRIBUTING.md](../../CONTRIBUTING.md#interface-only)).

Een Apple Developer-account is niet nodig. Builds vanuit broncode worden standaard ad hoc
ondertekend; [CONTRIBUTING.md](../../CONTRIBUTING.md#signing) legt de afwegingen uit en hoe je met een
gratis Apple ID kunt ondertekenen.

## Documentatie

- [docs/](../README.md): architectuur, debuggen, lokalisatie, releases en AI-agents
- [COMPATIBILITY.md](../../COMPATIBILITY.md): wat voor extensies en websites nog afwijkt van Chrome
- [PRIVACY.md](../../PRIVACY.md): elk verzoek dat Lilo zelf doet
- [ROADMAP.md](../../ROADMAP.md): wat klaar is, wat er volgt en wat buiten de plannen valt

## Bijdragen

Pull requests zijn welkom. [CONTRIBUTING.md](../../CONTRIBUTING.md) beschrijft de configuratie, de
ontwikkelwerkwijze en de checklist voor pull requests. Vragen kun je stellen in
[Discussions](https://github.com/Alexays/Lilo/discussions) ([SUPPORT.md](../../SUPPORT.md));
kwetsbaarheden meld je privé ([SECURITY.md](../../SECURITY.md)). Iedereen die meedoet volgt de
[gedragscode](../../CODE_OF_CONDUCT.md).

## Licentie

MIT, zie [LICENSE](../../LICENSE). Meegeleverde onderdelen van derden staan in
[THIRD-PARTY-NOTICES.md](../../THIRD-PARTY-NOTICES.md).
