<div align="center">

# Lilo

**Arc 스타일의 Mac 브라우저. Chromium이 아닌 WebKit 기반입니다.**

쓰던 Chrome 확장 프로그램, 페이지 옆의 터미널 탭, AI 에이전트를 위한 내장 MCP 서버까지. 무료, 오픈 소스, 계정 불필요.

[![macOS용 다운로드](https://img.shields.io/badge/macOS%EC%9A%A9%20%EB%8B%A4%EC%9A%B4%EB%A1%9C%EB%93%9C-6a4be0?style=for-the-badge&logo=apple&logoColor=white)](https://github.com/Alexays/Lilo/releases/latest/download/Lilo.dmg)

`brew install --cask alexays/tap/lilo` · macOS 26 이상

[![Release](https://img.shields.io/github/v/release/Alexays/Lilo?color=e07a4b)](https://github.com/Alexays/Lilo/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/Alexays/Lilo/total?color=6a4be0)](https://github.com/Alexays/Lilo/releases)
[![Stars](https://img.shields.io/github/stars/Alexays/Lilo?color=6a4be0)](https://github.com/Alexays/Lilo/stargazers)
[![라이선스: MIT](https://img.shields.io/badge/License-MIT-6a4be0.svg)](../../LICENSE)

[웹사이트](https://getlilo.app) ·
[Discord](https://discord.gg/NyJRAapk76) ·
[Arc에서 옮겨 오기](#arc에서-옮겨-오기) ·
[문서](../../docs/README.md) ·
[기여하기](../../CONTRIBUTING.md)

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../../docs/assets/lilo-dark.png">
  <img src="../../docs/assets/lilo-light.png" alt="업무 스페이스가 열린 Lilo: 고정된 사이트, 폴더, 탭이 있는 사이드바 옆에 웹페이지와 터미널 탭이 표시됨" width="900">
</picture>

<sub>[English](../../README.md) · [Français](README_fr.md) · [Español](README_es.md) · [简体中文](README_zh-Hans.md) · [Português (Brasil)](README_pt-BR.md) · [Русский](README_ru.md) · [Українська](README_uk.md) · [Deutsch](README_de.md) · [日本語](README_ja.md) · [Italiano](README_it.md) · **한국어** · [繁體中文](README_zh-Hant.md) · [Polski](README_pl.md) · [Türkçe](README_tr.md) · [Nederlands](README_nl.md)</sub>

</div>

Lilo는 사이드바가 익숙한 사람들을 위한 Mac 브라우저입니다. 또 하나의 Chromium 포크가 아닙니다.
Swift와 AppKit으로 만든 네이티브 앱으로, macOS에 이미 내장된 WebKit 엔진을 사용하면서도
자주 쓰는 Chrome 확장 프로그램을 실행할 수 있습니다. 페이지 옆에 터미널 탭을 열고, 이미 사용 중인
AI 에이전트가 내장 MCP 서버를 통해 전용 스페이스에서 브라우저를 제어하도록 할 수 있습니다.
무료이며 MIT 라이선스로 제공되고 계정이 필요하지 않습니다. Arc에서 옮겨온다면 몇 번의 클릭으로
스페이스, 고정된 탭, 폴더를 가져올 수 있습니다.

> **상태: 공개 베타.** Lilo는 일상적으로 사용할 수 있지만 아직 베타입니다. 다듬어지지 않은 부분이
> 있고 인터페이스도 계속 바뀔 수 있습니다.
> [문제가 생기면 알려 주세요](https://github.com/Alexays/Lilo/issues).
> [ROADMAP.md](../../ROADMAP.md)에서 우선순위와 개발하지 않을 항목을 확인할 수 있습니다.

[Discord 커뮤니티](https://discord.gg/NyJRAapk76)에서 의견을 나누고 Lilo 사용에 도움을 받으세요.

## Arc에서 옮겨 오기

Arc는 2026년 12월 22일에 서비스를 종료합니다. Lilo는 사이드바 중심의 브라우징 방식을 그대로 유지하고, Arc에 있는 내용을 Mac에서 바로 가져옵니다. Arc에는 아무것도 바꾸지 않습니다.

- **스페이스, 탭, 분할 화면**: 각 Arc 스페이스는 아이콘과 색상, 고정 탭과 열린 탭, 폴더, 분할 화면을 그대로 가진 Lilo 스페이스가 됩니다. 즐겨찾기는 북마크 탭이 됩니다.
- **방문 기록과 로그인**: 최근 페이지가 명령 막대에 나타나고, 쿠키도 복사되어 로그인 상태가 유지됩니다.
- **확장 프로그램**: Chrome 웹 스토어의 확장 프로그램은 스토어에서 다시 설치됩니다. 무엇을 설치할지는 직접 고릅니다.
- **단축키**: Arc 프리셋에서 시작한 뒤 원하는 단축키를 바꿀 수 있습니다.

달라지는 것은 엔진입니다. Chromium 대신 WebKit을 씁니다. 같은 탭을 열었을 때 Chrome은 Lilo보다 약 3배 많은 전력을 쓰며([측정 결과](../ENERGY.md)), 일부 Chrome 확장 프로그램 API는 아직 다릅니다([COMPATIBILITY.md](../../COMPATIBILITY.md)). [Arc 대안 페이지](https://getlilo.app/arc-alternative/)에서 기능별로 비교해 두었습니다.

## Lilo를 선택하는 이유

대부분의 Arc 대안은 Chromium에 새 사이드바를 더한 브라우저입니다. Lilo는 사이드바를 유지하고 나머지를 바꿉니다.

- **Chromium을 사용하지 않습니다.** 브라우저 엔진을 별도로 포함하지 않으며 Electron도 사용하지 않습니다.
  Swift, AppKit, 시스템 WebKit을 바탕으로 사이드바와 설정은 Svelte로 만듭니다. 메모리 사용량을 줄이고
  배터리를 하루 종일 사용할 수 있도록 하며 macOS가 출시될 때마다 Apple의 보안 업데이트를 받습니다.
- **개인정보 보호가 기본입니다.** 계정, 원격 측정, 분석, 서버가 없습니다. 사용자의 활동을 프로젝트로
  전송하지 않습니다. 광고와 추적기는 기본으로 차단하고 Safari처럼 크로스 사이트 추적을 방지하며
  Global Privacy Control도 켜져 있습니다(macOS 27). Lilo가 자체적으로 보내는 모든 요청과 끄는 방법을
  [목록으로 확인할 수 있습니다](../../PRIVACY.md#requests-lilo-makes-on-its-own).
- **Chrome 확장 프로그램은 그대로.** 보통 Chromium을 떠나면 확장 프로그램도 포기해야 합니다.
  Lilo에서는 Chrome 웹 스토어의 ‘Lilo에 추가’를 한 번 클릭하면 확장 프로그램이 설치되어 WebKit의
  네이티브 런타임에서 실행됩니다([COMPATIBILITY.md](../../COMPATIBILITY.md)).
- **사용자의 에이전트가 제어하며 자체 AI는 없습니다.** 챗봇을 덧붙이지 않습니다. 이미 실행 중인
  에이전트(Claude Code, Codex, Cursor 또는 모든 MCP 클라이언트)가 내장 MCP 서버를 통해 실제
  브라우저를 사용합니다. 전용 스페이스와 임시 프로필에서 작업하며 전송, 결제, 삭제 전에 허락을 구합니다.
- **페이지 옆의 터미널.** Ghostty 기반 터미널 탭이 웹사이트와 함께 사이드바에 표시되며 저장소의
  브랜치와 아직 반영하지 않은 변경사항을 보여줍니다.
- **직접 바꿀 수 있는 브라우저.** MIT 라이선스로 제공됩니다. 전체 인터페이스는 WebKit 위의 Svelte
  계층으로, 직접 수정하고 몇 초 만에 다시 빌드할 수 있습니다.

## 기능

**인터넷 사용**

- **스페이스와 프로필**: 이모티콘과 색상을 가진 스페이스마다 별도의 프로필로 로그인하고 스와이프로
  전환합니다. 개인정보 보호 스페이스는 닫을 때 모든 데이터를 지웁니다.
- **사이드바**: 고정된 탭, 즐겨찾기, 최대 5단계까지 중첩할 수 있는 잠금 가능한 폴더, 드래그로
  순서 변경, 오디오 및 현재 재생 제어를 제공합니다.
- **명령 막대**(`Cmd+T`): 탭, 방문 기록, 책갈피, 스페이스, 모든 동작을 하나의 입력란에서 찾고
  사용 빈도에 따라 정렬합니다.
- **최근 탭**(`Ctrl+Tab`): 모든 스페이스에서 최근에 사용한 탭을 사용 순서대로 전환합니다.
- **미리보기**: 고정된 탭에서 다른 사이트로 연결되는 링크나 `Shift`를 누른 채 클릭한 링크가
  페이지 위에 열립니다.
- **작은 창**(`Cmd+Option+N`, 모든 앱에서 사용 가능): 링크나 검색 하나를 위한 작은 창입니다.
  더 큰 작업으로 이어지면 스페이스로 보낼 수 있습니다.
- **스스로 정리되는 탭**: 고정되지 않은 탭을 사용하지 않으면 스페이스별로 정한 시간 후에
  보관합니다. `Cmd+Shift+K`로 한꺼번에 정리하며 보관함도 키 하나로 열 수 있습니다.
- **링크 규칙**: 다른 앱에서 연 링크를 규칙에 따라 스페이스나 작은 창으로 보냅니다.
- **분할 보기**: 최대 4개 탭을 나란히 표시하며 다시 실행할 때 복원합니다.
- **단축키**: Lilo 또는 Arc 프리셋을 바탕으로 모든 단축키를 변경할 수 있습니다.
- **가져오기**: Safari, Firefox, Zen 및 Chromium 브라우저(Chrome, Arc, Brave, Edge, Vivaldi,
  Opera, Dia, Comet, Chromium)에서 책갈피, 열린 탭과 스페이스, 방문 기록, 쿠키, 확장 프로그램을
  Mac에서 직접 읽어 가져옵니다.

**확장 프로그램과 웹**

- **Chrome 확장 프로그램**: WebKit의 네이티브 확장 프로그램 런타임으로 Manifest V3를 실행하고
  WebKit에 없는 API는 작은 Swift 핸들러로 보완합니다([COMPATIBILITY.md](../../COMPATIBILITY.md)).
- **암호 관리자**: 설정 과정에서 사용 중인 관리자를 선택할 수 있습니다(1Password, Bitwarden,
  Dashlane, KeePassXC, NordPass, Proton Pass).
- **스트리밍**: FairPlay로 보호된 비디오와 음악을 재생하며 YouTube를 4K HDR로 시청할 수 있습니다.
- **콘텐츠 차단**: EasyList, EasyPrivacy, uBlock Origin 목록을 최신으로 유지하며 화면 요소 필터링과
  스크립틀릿을 지원합니다.
- **스크린샷**: 캡처한 화면이 페이지 위에 카드로 표시됩니다. 마크업으로 편집하거나 저장하거나
  닫을 수 있습니다.
- **그 밖의 기능**: 읽기 도구 모드, 화면 속 화면(통화는 항상 위에 표시되는 패널로 열림), 페이지 번역,
  Web Serial, AppleScript, 단축어 동작, 집중 모드 필터를 제공합니다.

**개발자를 위한 기능**

- **터미널 탭**: Metal 렌더러를 사용하는 libghostty-vt 터미널을 페이지 옆에 엽니다
  (`Cmd+D`는 옆에, `Cmd+Shift+D`는 아래에). 사이드바에 브랜치와 아직 반영하지 않은 변경사항이 표시됩니다.
- **변경사항 보기**: 이미지를 포함한 저장소의 모든 변경 내역을 확인합니다.
- **작업 중 잠자기 방지**: 오래 걸리는 명령이 실행되는 동안 덮개를 닫아도 Mac이 잠들지 않게
  유지하고 완료되면 다시 잠자기를 허용합니다.
- **MCP 에이전트**: 내장 MCP 서버를 제공합니다. [AI 에이전트](#ai-에이전트)를 참고하세요.

## AI 에이전트

Lilo에는 MCP 서버가 내장되어 있습니다. 켜기만 하면 이미 사용 중인 에이전트(Claude Code,
Claude Desktop, Codex, Cursor 또는 모든 MCP 클라이언트)가 곁에서 실제 WebKit 브라우저를
제어할 수 있습니다. Lilo에는 자체 AI가 없습니다.

- **전용 스페이스.** 에이전트는 에이전트 스페이스의 폴더에서 탭을 엽니다. 매 세션 후 지워지는
  임시 프로필을 사용합니다. 사용자의 키보드, 마우스, 탭을 빼앗지 않으며 개인정보 보호 스페이스를
  볼 수 없습니다. 허용하면 사용자의 프로필을 빌려 쓸 수 있습니다.
- **먼저 허락을 구합니다.** 에이전트가 전송, 결제, 삭제, 게시를 하거나 사용자의 파일을 페이지에
  전달하기 전에 Lilo가 확인합니다(‘한 번 허용’, ‘이 사이트에서 항상 허용’, ‘거부’). 각 클라이언트는
  한 번 승인받으며 클라이언트가 제시하는 이름이 아닌 실제 프로그램을 기준으로 식별합니다.
- **클릭 한 번으로 연결.** 설정 > AI 에이전트에서 ‘AI 에이전트의 Lilo 사용 허용’을 켜고
  Claude Code, Claude Desktop, Codex 또는 Cursor 옆의 ‘연결’을 누르세요. Lilo가 해당 클라이언트의
  MCP 서버에 자신을 추가합니다. 그 밖의 클라이언트는 ‘다른 에이전트’에서 설정을 복사하면 됩니다.

그런 다음 에이전트에 다음과 같이 요청해 보세요.

```text
Lilo에서 localhost:3000/checkout을 열고 테스트 카드로 결제한 뒤 주문이 실패하는 원인을 찾아줘.
콘솔과 네트워크를 확인해 줘.
```

도구는 다음 기능을 제공합니다.

- **탭과 탐색**: 에이전트 폴더의 탭과 쿠키나 로그인을 공유하지 않는 격리된 탭.
- **입력**: 클릭, 텍스트 입력, 키 입력, 스크롤, 드래그, 양식 작성, 파일 및 이미지 업로드.
- **페이지 읽기**: 요소 참조를 포함하는 접근성 트리, 텍스트 검색, 페이지 텍스트.
- **스크린샷**: 전체 페이지 또는 요소 하나의 캡처와 GIF 기록.
- **콘솔과 네트워크**: 메시지, 전체 응답을 포함하는 요청, HAR 내보내기, 쿠키.
- **네트워크 모의 동작과 에뮬레이션**: 모의 응답, 실패하거나 지연된 요청, 사용자 에이전트,
  색 구성표, 동작 줄이기, 인쇄 미디어, 추가 헤더, 초기화 스크립트, 뷰포트 크기.
- **성능**: 로드 및 그리기 지표, 메모리, 타임라인 프로파일.
- **웹 속성**: WebKit 자체 검사 프로토콜, 명령, 이벤트.
- **스크립트**: 페이지의 JavaScript, 탭의 쿠키를 사용하는 `fetch`, 한 번의 왕복으로 여러 호출을
  연결하는 `run` 또는 `browser_batch`.
- **프로필**: 목록 확인, 허용 후 기존 프로필 사용, 임시 프로필 재설정.

[docs/AI-AGENTS.md](../../docs/AI-AGENTS.md)에 자세한 내용이 있습니다. 어떤 작업에서 확인을 요청하는지,
요청하지 않는지, 사용자가 해결해야 하는 오류는 무엇인지 설명합니다.

## 설치

다음 중 한 가지 방법으로 설치하세요.

- [Releases](https://github.com/Alexays/Lilo/releases/latest)에서 DMG를 다운로드하거나
- Homebrew로 설치합니다.

  ```bash
  brew install --cask alexays/tap/lilo
  ```

Lilo는 서명된 Sparkle 업데이트를 통해 자동으로 업데이트됩니다.

### 요구 사항

- macOS 26 이상. Global Privacy Control은 macOS 27이 필요합니다.

## 소스에서 빌드

Xcode 27과 Node.js 22.6+를 설치한 상태에서 시작합니다([전체 요구 사항](../../CONTRIBUTING.md#requirements)).

```bash
git clone https://github.com/Alexays/Lilo.git && cd Lilo
make bootstrap                  # 요구 사항을 확인하고 앱에 필요한 항목을 가져오거나 빌드
make install                    # /Applications에 Release 빌드 설치, 기존 사본 대체
open /Applications/Lilo.app
```

`make bootstrap`은 누락된 항목과 설치 방법을 알려줍니다. 인터페이스만 작업한다면 Node.js만 있으면 됩니다.
`make ui-preview`를 실행하면 브라우저에서 인터페이스가 열리고 변경사항이 바로 반영됩니다
([CONTRIBUTING.md](../../CONTRIBUTING.md#interface-only)).

Apple Developer 계정은 필요하지 않습니다. 소스 빌드는 기본적으로 ad hoc 서명됩니다.
[CONTRIBUTING.md](../../CONTRIBUTING.md#signing)에서 장단점과 무료 Apple ID로 서명하는 방법을 설명합니다.

## 문서

- [docs/](../../docs/README.md): 아키텍처, 디버깅, 현지화, 출시, AI 에이전트
- [COMPATIBILITY.md](../../COMPATIBILITY.md): 확장 프로그램과 사이트에서 Chrome과 다른 부분
- [PRIVACY.md](../../PRIVACY.md): Lilo가 자체적으로 보내는 모든 요청
- [ROADMAP.md](../../ROADMAP.md): 출시된 기능, 다음 계획, 개발하지 않을 항목

## 기여하기

Pull Request를 환영합니다. [CONTRIBUTING.md](../../CONTRIBUTING.md)에서 설정, 개발 과정,
Pull Request 체크리스트를 확인할 수 있습니다. 질문은
[Discussions](https://github.com/Alexays/Lilo/discussions)에 남겨 주세요([SUPPORT.md](../../SUPPORT.md)).
보안 취약점은 비공개로 신고해 주세요([SECURITY.md](../../SECURITY.md)). 모든 참여자는
[행동 강령](../../CODE_OF_CONDUCT.md)을 따릅니다.

## 라이선스

MIT 라이선스이며 [LICENSE](../../LICENSE)에서 확인할 수 있습니다. 포함된 타사 구성요소는
[THIRD-PARTY-NOTICES.md](../../THIRD-PARTY-NOTICES.md)에 나열되어 있습니다.
