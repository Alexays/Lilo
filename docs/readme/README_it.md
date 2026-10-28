<div align="center">

[English](../../README.md) · [Français](README_fr.md) · [Español](README_es.md) · [简体中文](README_zh-Hans.md) · [Português (Brasil)](README_pt-BR.md) · [Русский](README_ru.md) · [Українська](README_uk.md) · [Deutsch](README_de.md) · [日本語](README_ja.md) · **Italiano** · [한국어](README_ko.md)

# Lilo

**Il tuo internet, in fiore.**

Leggero sul Mac, veloce sul web, riservato per natura. Gratuito e open source.

[![CI](https://github.com/Alexays/Lilo/actions/workflows/build.yml/badge.svg)](https://github.com/Alexays/Lilo/actions/workflows/build.yml)
[![Licenza: MIT](https://img.shields.io/badge/License-MIT-6a4be0.svg)](../../LICENSE)
[![Stato: beta pubblica](https://img.shields.io/badge/status-public%20beta-e07a4b.svg)](#installazione)

[Sito web](https://getlilo.app) ·
[Discord](https://discord.gg/NyJRAapk76) ·
[Installazione](#installazione) ·
[Compilazione dal sorgente](#compilazione-dal-sorgente) ·
[Documentazione](../README.md) ·
[Contribuire](../../CONTRIBUTING.md)

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../assets/lilo-dark.png">
  <img src="../assets/lilo-light.png" alt="Lilo con lo spazio Lavoro aperto: barra laterale con siti fissati, cartelle e schede, accanto a una pagina web e a una scheda del terminale" width="900">
</picture>

</div>

Lilo è un browser per Mac pensato per chi vive nella barra laterale, e non è un altro fork di Chromium.
È scritto in Swift e AppKit nativi e usa il motore WebKit già presente in macOS, pur eseguendo le
estensioni Chrome su cui fai affidamento. Mette le schede del terminale accanto alle pagine e consente
agli agenti IA che usi già di controllarlo tramite un server MCP integrato, in uno spazio tutto loro.
Gratuito, con licenza MIT, senza account. Se lasci Arc, importa spazi, schede fissate e cartelle in pochi clic.

> **Stato: beta pubblica.** Lilo si può usare ogni giorno, ma è ancora in beta: aspettati qualche
> imperfezione e un'interfaccia ancora in evoluzione. Ti invitiamo a [segnalare ciò che non funziona](https://github.com/Alexays/Lilo/issues).
> [ROADMAP.md](../../ROADMAP.md) elenca priorità e obiettivi esclusi.

Unisciti alla [community su Discord](https://discord.gg/NyJRAapk76) per condividere opinioni e ricevere aiuto con Lilo.

## Perché Lilo

La maggior parte delle alternative ad Arc è Chromium con una nuova barra laterale. Lilo mantiene la barra laterale e cambia il resto.

- **Senza Chromium.** Nessun motore di navigazione incluso, niente Electron: Swift, AppKit e WebKit
  di sistema, con barra laterale e impostazioni in Svelte. Meno memoria occupata, una batteria che dura
  tutto il giorno e gli aggiornamenti di sicurezza Apple a ogni versione di macOS.
- **Riservato per natura.** Nessun account, telemetria, analisi o server: nulla di ciò che fai viene
  inviato al progetto. Pubblicità e tracker sono bloccati fin dall'inizio, il tracciamento tra siti è
  bloccato come in Safari e Global Privacy Control è attivo (macOS 27). Ogni richiesta che Lilo effettua
  autonomamente è [elencata, con le istruzioni per disattivarla](../../PRIVACY.md#requests-lilo-makes-on-its-own).
- **Con le estensioni Chrome.** Lasciare Chromium di solito significa rinunciare alle sue estensioni.
  In Lilo, le estensioni del Chrome Web Store si installano con un clic su «Aggiungi a Lilo», nel
  runtime nativo di WebKit ([COMPATIBILITY.md](../../COMPATIBILITY.md)).
- **Lo guidano i tuoi agenti, senza una propria IA.** Nessun chatbot aggiunto: gli agenti che usi già
  (Claude Code, Codex, Cursor o qualsiasi client MCP) usano un browser vero tramite il server MCP
  integrato, nel proprio spazio e profilo temporaneo, e chiedono prima di inviare, pagare o eliminare.
- **Un terminale accanto alle pagine.** Le schede del terminale basate su Ghostty convivono con i siti
  nella barra laterale, mostrando il branch e le modifiche in sospeso del loro repository.
- **Tuo.** Con licenza MIT. L'intera interfaccia è uno strato Svelte sopra WebKit, che puoi modificare
  e ricompilare in pochi secondi.

## Funzionalità

**Navigazione**

- **Spazi e profili**: spazi con un'emoji e un colore, ognuno con il proprio profilo di accesso;
  passa dall'uno all'altro con uno scorrimento. Gli spazi privati dimenticano tutto alla chiusura.
- **Barra laterale**: schede fissate, preferiti, cartelle annidate fino a cinque livelli (con blocco),
  trascinamento per riordinare, controlli audio e di riproduzione.
- **Barra dei comandi** (`Cmd+T`): schede, cronologia, segnalibri, spazi e tutte le azioni in un unico
  campo, ordinati in base all'uso.
- **Schede recenti** (`Ctrl+Tab`): passa tra le ultime schede di tutti gli spazi nell'ordine in cui
  le hai usate.
- **Anteprima**: un link da una scheda fissata a un altro sito, o qualsiasi link su cui fai clic con
  `Maiuscole` premuto, si apre sopra la pagina.
- **Finestra piccola** (`Cmd+Option+N`, da qualsiasi app): una piccola finestra per un link o una
  ricerca, da inviare a uno spazio quando diventa qualcosa di più.
- **Schede che si riordinano da sole**: le schede non fissate che smetti di usare vengono archiviate
  dopo un intervallo scelto per ogni spazio; `Cmd+Shift+K` le rimuove e l'archivio è a un tasto di distanza.
- **Regole dei link**: i link aperti da altre app vanno allo spazio o alla finestra piccola scelti da una regola.
- **Vista divisa**: fino a quattro schede affiancate, ripristinate al riavvio.
- **Abbreviazioni**: tutte le abbreviazioni possono essere riassegnate, partendo dal preset di Lilo o Arc.
- **Importazione**: segnalibri, schede aperte e spazi, cronologia, cookie ed estensioni da Safari,
  Firefox, Zen e browser Chromium (Chrome, Arc, Brave, Edge, Vivaldi, Opera, Dia, Comet,
  Chromium), letti direttamente dal Mac.

**Estensioni e web**

- **Estensioni Chrome**: Manifest V3 tramite il runtime nativo delle estensioni di WebKit, più piccoli
  gestori Swift per le API mancanti in WebKit ([COMPATIBILITY.md](../../COMPATIBILITY.md)).
- **Gestori di password**: la configurazione propone quello che usi (1Password, Bitwarden, Dashlane,
  KeePassXC, NordPass, Proton Pass).
- **Streaming**: video e musica protetti tramite FairPlay; YouTube in 4K HDR.
- **Blocco dei contenuti**: elenchi EasyList, EasyPrivacy e uBlock Origin sempre aggiornati, con
  filtri cosmetici e scriptlet.
- **Istantanee**: l'acquisizione appare come una scheda sopra la pagina, pronta da annotare, salvare
  o chiudere.
- **E altro ancora**: modalità Lettura, Picture in Picture (le chiamate restano in un pannello sempre
  in primo piano), traduzione delle pagine, Web Serial, AppleScript, azioni di Comandi Rapidi e un
  filtro per Full immersion.

**Per chi sviluppa**

- **Schede del terminale**: terminali libghostty-vt con rendering Metal, accanto alle pagine
  (`Cmd+D` accanto, `Cmd+Shift+D` sotto), con il branch e le modifiche in sospeso nella barra laterale.
- **Vista delle modifiche**: tutte le differenze del repository, immagini incluse.
- **Resta attivo mentre lavora**: un comando lungo mantiene il Mac attivo, anche a coperchio chiuso,
  poi gli consente di entrare in stop.
- **Agenti tramite MCP**: il server MCP integrato, vedi [Per gli agenti IA](#per-gli-agenti-ia).

## Per gli agenti IA

Lilo ha un server MCP integrato. Attivalo e gli agenti che usi già (Claude Code, Claude Desktop,
Codex, Cursor o qualsiasi client MCP) controlleranno un vero browser WebKit al tuo fianco.
Lilo non include una propria IA.

- **Il loro spazio.** Gli agenti aprono le schede in una cartella dello spazio Agenti, in un profilo
  temporaneo cancellato dopo ogni sessione. Non prendono mai il controllo della tastiera, del mouse
  o delle tue schede e non vedono mai gli spazi privati. Un agente può usare uno dei tuoi profili con
  il tuo consenso.
- **Decidi prima tu.** Lilo chiede prima che un agente invii, paghi, elimini o pubblichi (Consenti una
  volta, Consenti sempre su questo sito o Nega) e prima di passare a una pagina uno dei tuoi file.
  Ogni client viene approvato una volta, legandolo al programma che lo esegue anziché al nome che dichiara.
- **Un clic per connettersi.** In Impostazioni > Agenti IA, attiva «Consenti agli agenti IA di usare
  Lilo», poi premi Connetti accanto a Claude Code, Claude Desktop, Codex o Cursor: Lilo si aggiunge
  ai server MCP di quel client. Per qualsiasi altro client, copia la configurazione da «Altri agenti».

Poi chiedi al tuo agente qualcosa come:

```text
Apri localhost:3000/checkout in Lilo, paga con la carta di prova e scopri perché l'ordine non riesce.
Controlla la console e la rete.
```

Gli strumenti coprono:

- **Schede e navigazione** nella cartella dell'agente e schede isolate che non condividono cookie o accessi.
- **Input**: clic, digitazione, tasti, scorrimento, trascinamento, compilazione di moduli, caricamento di file e immagini.
- **Lettura delle pagine**: albero di accessibilità con riferimenti agli elementi, ricerca di testo e testo della pagina.
- **Istantanee** di una pagina intera o di un elemento e registrazioni GIF.
- **Console e rete**: messaggi, richieste con risposte complete, esportazione HAR e cookie.
- **Simulazione della rete ed emulazione**: richieste simulate, non riuscite o ritardate; user agent,
  combinazione colori, movimento ridotto, supporto di stampa, intestazioni aggiuntive, script di
  inizializzazione; dimensioni dell'area visibile.
- **Prestazioni**: metriche di caricamento e disegno, memoria e profili temporali.
- **Inspector web**: protocollo di ispezione di WebKit, con comandi ed eventi.
- **Scripting**: JavaScript nella pagina, `fetch` da una scheda con i suoi cookie e `run` o
  `browser_batch` per concatenare più chiamate in un unico scambio.
- **Profili**: elencarli, usarne uno con il tuo consenso o reimpostare quello temporaneo.

[docs/AI-AGENTS.md](../AI-AGENTS.md) spiega i dettagli: quando viene chiesta conferma, quando no e
quali errori richiedono il tuo intervento.

## Installazione

Puoi:

- scaricare il DMG dalle [release](https://github.com/Alexays/Lilo/releases/latest), oppure
- installare con Homebrew:

  ```bash
  brew install --cask alexays/tap/lilo
  ```

Lilo si aggiorna automaticamente tramite aggiornamenti Sparkle firmati.

### Requisiti

- macOS 26 o successivo. Global Privacy Control richiede macOS 27.

## Compilazione dal sorgente

Con Xcode 27 e Node.js 22.6+ installati ([tutti i prerequisiti](../../CONTRIBUTING.md#requirements)):

```bash
git clone https://github.com/Alexays/Lilo.git && cd Lilo
make bootstrap                  # verifica i prerequisiti e scarica o compila ciò che serve all'app
make install                    # compila in Release in /Applications, sostituendo una copia installata
open /Applications/Lilo.app
```

`make bootstrap` indica cosa manca e come installarlo. Per lavorare solo sull'interfaccia basta
Node.js: `make ui-preview` la apre nel browser con ricaricamento automatico
([CONTRIBUTING.md](../../CONTRIBUTING.md#interface-only)).

Non serve un account Apple Developer. Le compilazioni dal sorgente usano per impostazione
predefinita una firma ad hoc; [CONTRIBUTING.md](../../CONTRIBUTING.md#signing) spiega i compromessi
e come firmare con un Apple ID gratuito.

## Documentazione

- [docs/](../README.md): architettura, debug, localizzazione, rilascio, agenti IA
- [COMPATIBILITY.md](../../COMPATIBILITY.md): cosa differisce ancora da Chrome per estensioni e siti
- [PRIVACY.md](../../PRIVACY.md): ogni richiesta che Lilo effettua autonomamente
- [ROADMAP.md](../../ROADMAP.md): cosa è disponibile, cosa arriverà e quali obiettivi sono esclusi

## Contribuire

Le pull request sono benvenute. [CONTRIBUTING.md](../../CONTRIBUTING.md) descrive la configurazione,
il flusso di sviluppo e la lista di controllo per le pull request. Per le domande, usa
[Discussions](https://github.com/Alexays/Lilo/discussions) ([SUPPORT.md](../../SUPPORT.md)); le
vulnerabilità vanno segnalate privatamente ([SECURITY.md](../../SECURITY.md)). Tutti i partecipanti
rispettano il [codice di condotta](../../CODE_OF_CONDUCT.md).

## Licenza

MIT, vedi [LICENSE](../../LICENSE). I componenti di terze parti inclusi sono elencati in
[THIRD-PARTY-NOTICES.md](../../THIRD-PARTY-NOTICES.md).
