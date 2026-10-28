<div align="center">

[English](../../README.md) · [Français](README_fr.md) · [Español](README_es.md) · [简体中文](README_zh-Hans.md) · [Português (Brasil)](README_pt-BR.md) · [Русский](README_ru.md) · [Українська](README_uk.md) · [Deutsch](README_de.md) · [日本語](README_ja.md) · [Italiano](README_it.md) · [한국어](README_ko.md) · [繁體中文](README_zh-Hant.md) · **Polski** · [Türkçe](README_tr.md)

# Lilo

**Twój internet rozkwita.**

Lekka dla Maca, szybka w sieci, prywatna od początku. Darmowa i z otwartym kodem.

[![CI](https://github.com/Alexays/Lilo/actions/workflows/build.yml/badge.svg)](https://github.com/Alexays/Lilo/actions/workflows/build.yml)
[![Licencja: MIT](https://img.shields.io/badge/License-MIT-6a4be0.svg)](../../LICENSE)
[![Status: publiczna beta](https://img.shields.io/badge/status-public%20beta-e07a4b.svg)](#instalacja)

[Witryna](https://getlilo.app) ·
[Discord](https://discord.gg/NyJRAapk76) ·
[Instalacja](#instalacja) ·
[Kompilowanie ze źródeł](#kompilowanie-ze-źródeł) ·
[Dokumentacja](../../docs/README.md) ·
[Współtworzenie](../../CONTRIBUTING.md)

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../../docs/assets/lilo-dark.png">
  <img src="../../docs/assets/lilo-light.png" alt="Lilo z otwartą przestrzenią Praca: pasek boczny z przypiętymi witrynami, folderami i kartami, obok strony internetowej i karty terminala" width="900">
</picture>

</div>

Lilo to przeglądarka na Maca dla osób, które najchętniej pracują z paskiem bocznym. Nie jest kolejną
odmianą Chromium. To natywne Swift i AppKit na silniku WebKit już obecnym w macOS, a mimo to
uruchamia rozszerzenia Chrome, na których polegasz. Umieszcza karty terminala obok stron i pozwala
Twoim dotychczasowym agentom AI sterować przeglądarką przez wbudowany serwer MCP, we własnej przestrzeni.
Darmowa, na licencji MIT, bez konta. Jeśli odchodzisz z Arc, zaimportujesz przestrzenie, przypięte karty
i foldery kilkoma kliknięciami.

> **Status: publiczna beta.** Lilo nadaje się do codziennego użytku, ale nadal jest wersją beta: możesz
> napotkać niedociągnięcia i zmieniający się interfejs. [Zgłaszaj to, co nie działa](https://github.com/Alexays/Lilo/issues).
> [ROADMAP.md](../../ROADMAP.md) zawiera priorytety i rzeczy poza zakresem projektu.

Dołącz do [społeczności na Discordzie](https://discord.gg/NyJRAapk76), aby podzielić się opinią i uzyskać pomoc z Lilo.

## Dlaczego Lilo

Większość alternatyw dla Arc to Chromium z nowym paskiem bocznym. Lilo zachowuje pasek boczny i zmienia resztę.

- **Bez Chromium.** Bez dołączonego silnika przeglądarki i bez Electrona: Swift, AppKit i systemowy WebKit,
  z paskiem bocznym i ustawieniami w Svelte. Mniej zajętej pamięci, bateria na cały dzień i poprawki
  bezpieczeństwa Apple z każdym wydaniem macOS.
- **Prywatność od początku.** Bez konta, telemetrii, analityki i serwera: nic, co robisz, nie trafia
  do projektu. Reklamy i śledzenie są blokowane od razu, śledzenie między witrynami jest blokowane
  tak jak w Safari, a Global Privacy Control jest włączone (macOS 27). Każde żądanie wysyłane przez
  samo Lilo jest [opisane wraz ze sposobem wyłączenia](../../PRIVACY.md#requests-lilo-makes-on-its-own).
- **Rozszerzenia Chrome nadal działają.** Odejście od Chromium zwykle oznacza rozstanie z rozszerzeniami.
  W Lilo rozszerzenia z Chrome Web Store instaluje się jednym kliknięciem „Dodaj do Lilo”, w natywnym
  środowisku WebKit ([COMPATIBILITY.md](../../COMPATIBILITY.md)).
- **Sterują nim Twoi agenci, nie ma własnej AI.** Bez doklejonego czatbota: agenci, których już używasz
  (Claude Code, Codex, Cursor lub dowolny klient MCP), korzystają z prawdziwej przeglądarki przez
  wbudowany serwer MCP. Pracują we własnej przestrzeni i profilu tymczasowym oraz pytają przed wysłaniem,
  płatnością lub usunięciem.
- **Terminal obok stron.** Karty terminala oparte na Ghostty są w pasku bocznym razem z witrynami
  i pokazują gałąź oraz niezatwierdzone zmiany w repozytorium.
- **Twoja.** Licencja MIT. Cały interfejs to warstwa Svelte nad WebKit, którą możesz zmienić
  i przebudować w kilka sekund.

## Funkcje

**Przeglądanie**

- **Przestrzenie i profile**: przestrzenie z emoji i kolorem, każda zalogowana we własnym profilu.
  Przełączasz się między nimi gestem. Przestrzenie prywatne po zamknięciu niczego nie zachowują.
- **Pasek boczny**: przypięte karty, ulubione, foldery zagnieżdżone do pięciu poziomów (z możliwością
  blokady), przeciąganie do zmiany kolejności oraz sterowanie dźwiękiem i odtwarzaniem.
- **Pasek poleceń** (`Cmd+T`): karty, historia, zakładki, przestrzenie i każda czynność w jednym polu,
  uporządkowane według tego, z czego korzystasz.
- **Ostatnie karty** (`Ctrl+Tab`): przełączaj ostatnie karty ze wszystkich przestrzeni w kolejności,
  w której były używane.
- **Podgląd**: łącze z przypiętej karty do innej witryny lub dowolne łącze kliknięte z `Shift` otwiera
  się nad stroną.
- **Małe okno** (`Cmd+Option+N`, z dowolnej aplikacji): niewielkie okno na jedno łącze lub wyszukiwanie,
  które można wysłać do przestrzeni, gdy przyda się na dłużej.
- **Karty porządkują się same**: nieużywane, nieprzypięte karty trafiają do archiwum po czasie wybranym
  dla każdej przestrzeni. `Cmd+Shift+K` je czyści, a archiwum jest dostępne jednym skrótem.
- **Reguły łączy**: łącza otwierane z innych aplikacji trafiają do przestrzeni lub małego okna wybranego
  przez regułę.
- **Widok podzielony**: do czterech kart obok siebie, przywracanych po ponownym uruchomieniu.
- **Skróty**: każdy skrót można zmienić, zaczynając od zestawu Lilo lub Arc.
- **Import**: zakładki, otwarte karty i przestrzenie, historia, pliki cookie i rozszerzenia z Safari,
  Firefox, Zen i przeglądarek Chromium (Chrome, Arc, Brave, Edge, Vivaldi, Opera, Dia, Comet,
  Chromium), odczytywane bezpośrednio z Maca.

**Rozszerzenia i sieć**

- **Rozszerzenia Chrome**: Manifest V3 przez natywne środowisko rozszerzeń WebKit oraz małe procedury
  Swift dla API brakujących w WebKit ([COMPATIBILITY.md](../../COMPATIBILITY.md)).
- **Menedżery haseł**: konfiguracja proponuje ten, którego używasz (1Password, Bitwarden, Dashlane,
  KeePassXC, NordPass, Proton Pass).
- **Streaming**: chronione wideo i muzyka przez FairPlay; YouTube w 4K HDR.
- **Blokowanie zawartości**: stale uaktualniane listy EasyList, EasyPrivacy i uBlock Origin,
  z ukrywaniem elementów i skryptletami.
- **Zrzuty ekranu**: zrzut pojawia się jako karta nad stroną, gotowy do edycji z adnotacjami,
  zachowania lub zamknięcia.
- **I więcej**: tryb czytania, obraz w obrazie (rozmowy w panelu zawsze na wierzchu), tłumaczenie
  stron, Web Serial, AppleScript, czynności Skrótów i filtr trybu skupienia.

**Dla twórców**

- **Karty terminala**: terminale libghostty-vt z renderowaniem Metal obok stron
  (`Cmd+D` obok, `Cmd+Shift+D` poniżej), z gałęzią i niezatwierdzonymi zmianami w pasku bocznym.
- **Widok zmian**: wszystkie różnice w repozytorium, również obrazy.
- **Nie zasypia podczas pracy**: długie polecenie nie pozwala Macowi zasnąć, nawet z zamkniętą pokrywą,
  a po zakończeniu przywraca usypianie.
- **Agenci przez MCP**: wbudowany serwer MCP, zobacz [Dla agentów AI](#dla-agentów-ai).

## Dla agentów AI

Lilo ma wbudowany serwer MCP. Włącz go, a Twoi dotychczasowi agenci (Claude Code, Claude Desktop,
Codex, Cursor lub dowolny klient MCP) będą sterować prawdziwą przeglądarką WebKit obok Ciebie.
Lilo nie zawiera własnej AI.

- **Własna przestrzeń.** Agenci otwierają karty w folderze przestrzeni Agenci, w profilu tymczasowym
  czyszczonym po każdej sesji. Nie przejmują klawiatury, myszy ani Twoich kart i nigdy nie widzą
  przestrzeni prywatnych. Za Twoją zgodą agent może skorzystać z jednego z Twoich profili.
- **Najpierw Twoja zgoda.** Lilo pyta, zanim agent coś wyśle, zapłaci, usunie lub opublikuje
  (Zezwól raz, Zawsze zezwalaj na tej witrynie lub Odmów), a także zanim przekaże stronie jeden
  z Twoich plików. Każdy klient wymaga jednorazowej zgody i jest powiązany z rzeczywistym programem,
  a nie z podawaną przez niego nazwą.
- **Połączenie jednym kliknięciem.** W Ustawienia > Agenci AI włącz „Pozwól agentom AI korzystać z Lilo”,
  a potem naciśnij Połącz obok Claude Code, Claude Desktop, Codex lub Cursor. Lilo dopisze się do serwerów
  MCP tego klienta. Dla dowolnego innego klienta skopiuj konfigurację z pozycji „Inni agenci”.

Następnie poproś agenta na przykład:

```text
Otwórz localhost:3000/checkout w Lilo, zapłać kartą testową i sprawdź, dlaczego zamówienie się nie udaje.
Sprawdź konsolę i sieć.
```

Narzędzia obejmują:

- **Karty i nawigację** w folderze agenta oraz odizolowane karty bez wspólnych plików cookie i logowań.
- **Wprowadzanie danych**: klikanie, wpisywanie, klawisze, przewijanie, przeciąganie, wypełnianie
  formularzy oraz przesyłanie plików i obrazów.
- **Czytanie stron**: drzewo dostępności z odwołaniami do elementów, wyszukiwanie tekstu, tekst strony.
- **Zrzuty ekranu** całej strony lub jednego elementu oraz nagrania GIF.
- **Konsolę i sieć**: komunikaty, żądania z pełnymi odpowiedziami, eksport HAR, pliki cookie.
- **Symulacje sieci i emulację**: symulowane, odrzucone lub opóźnione żądania; identyfikator przeglądarki,
  schemat kolorów, ograniczony ruch, tryb druku, dodatkowe nagłówki, skrypty inicjalizacyjne i rozmiar obszaru widoku.
- **Wydajność**: pomiary wczytywania i rysowania, pamięć oraz profile osi czasu.
- **Inspektora WWW**: własny protokół inspektora WebKit, polecenia i zdarzenia.
- **Skrypty**: JavaScript na stronie, `fetch` z karty z użyciem jej plików cookie oraz `run` lub
  `browser_batch` do łączenia wielu wywołań w jedną wymianę z serwerem.
- **Profile**: wyświetlanie listy, korzystanie z profilu za Twoją zgodą lub zerowanie profilu tymczasowego.

Szczegóły opisuje [docs/AI-AGENTS.md](../../docs/AI-AGENTS.md): o co Lilo pyta, o co nie pyta
oraz jakie błędy wymagają Twojej pomocy.

## Instalacja

Do wyboru:

- pobierz DMG z [wydań](https://github.com/Alexays/Lilo/releases/latest) lub
- zainstaluj przez Homebrew:

  ```bash
  brew install --cask alexays/tap/lilo
  ```

Lilo uaktualnia się przez podpisane uaktualnienia Sparkle.

### Wymagania

- macOS 26 lub nowszy. Global Privacy Control wymaga macOS 27.

## Kompilowanie ze źródeł

Z zainstalowanymi Xcode 27 i Node.js 22.6+ ([pełne wymagania](../../CONTRIBUTING.md#requirements)):

```bash
git clone https://github.com/Alexays/Lilo.git && cd Lilo
make bootstrap                  # checks the prerequisites and fetches or builds what the app needs
make install                    # Release build into /Applications, replacing an installed copy
open /Applications/Lilo.app
```

`make bootstrap` wskazuje brakujące elementy i sposób ich instalacji; sprawdza wymagania oraz pobiera lub
buduje to, czego potrzebuje aplikacja. `make install` tworzy wersję Release w `/Applications`, zastępując
zainstalowaną kopię. Do pracy nad samym interfejsem wystarczy Node.js: `make ui-preview` otwiera go
w przeglądarce z automatycznym odświeżaniem ([CONTRIBUTING.md](../../CONTRIBUTING.md#interface-only)).

Konto Apple Developer nie jest potrzebne. Kompilacje ze źródeł są domyślnie podpisywane ad hoc.
[CONTRIBUTING.md](../../CONTRIBUTING.md#signing) wyjaśnia ograniczenia i sposób podpisywania za pomocą
bezpłatnego Apple ID.

## Dokumentacja

- [docs/](../../docs/README.md): architektura, debugowanie, lokalizacja, wydawanie, agenci AI
- [COMPATIBILITY.md](../../COMPATIBILITY.md): pozostałe różnice względem Chrome dla rozszerzeń i witryn
- [PRIVACY.md](../../PRIVACY.md): każde żądanie wysyłane samodzielnie przez Lilo
- [ROADMAP.md](../../ROADMAP.md): gotowe funkcje, dalsze plany i rzeczy poza zakresem projektu

## Współtworzenie

Zapraszamy do przesyłania pull requestów. [CONTRIBUTING.md](../../CONTRIBUTING.md) opisuje konfigurację,
pracę nad projektem i listę kontrolną pull requestu. Pytania kieruj do
[Discussions](https://github.com/Alexays/Lilo/discussions) ([SUPPORT.md](../../SUPPORT.md)), a podatności
zgłaszaj prywatnie ([SECURITY.md](../../SECURITY.md)). Wszystkich uczestników obowiązuje
[Kodeks postępowania](../../CODE_OF_CONDUCT.md).

## Licencja

MIT, zobacz [LICENSE](../../LICENSE). Dołączone komponenty zewnętrzne są wymienione w
[THIRD-PARTY-NOTICES.md](../../THIRD-PARTY-NOTICES.md).
