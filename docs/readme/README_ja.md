<div align="center">

[English](../../README.md) · [Français](README_fr.md) · [Español](README_es.md) · [简体中文](README_zh-Hans.md) · [Português (Brasil)](README_pt-BR.md) · [Русский](README_ru.md) · [Українська](README_uk.md) · [Deutsch](README_de.md) · **日本語** · [Italiano](README_it.md) · [한국어](README_ko.md) · [繁體中文](README_zh-Hant.md)

# Lilo

**あなたのインターネットが、花ひらく。**

Mac には軽く、Web では速く。プライバシーは最初から。無料のオープンソースブラウザです。

[![CI](https://github.com/Alexays/Lilo/actions/workflows/build.yml/badge.svg)](https://github.com/Alexays/Lilo/actions/workflows/build.yml)
[![ライセンス：MIT](https://img.shields.io/badge/License-MIT-6a4be0.svg)](../../LICENSE)
[![ステータス：公開ベータ版](https://img.shields.io/badge/status-public%20beta-e07a4b.svg)](#インストール)

[Web サイト](https://getlilo.app) ·
[Discord](https://discord.gg/NyJRAapk76) ·
[インストール](#インストール) ·
[ソースからビルド](#ソースからビルド) ·
[ドキュメント](../../docs/README.md) ·
[貢献する](../../CONTRIBUTING.md)

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../../docs/assets/lilo-dark.png">
  <img src="../../docs/assets/lilo-light.png" alt="仕事用スペースを開いた Lilo：固定したサイト、フォルダ、タブのあるサイドバーと、その隣の Web ページおよびターミナルタブ" width="900">
</picture>

</div>

Lilo は、サイドバーを中心にブラウザを使う人のための Mac ブラウザです。Chromium の新たなフォークではありません。
macOS に搭載済みの WebKit エンジンの上に、Swift と AppKit でネイティブに作られています。それでも、
いつもの Chrome 機能拡張を使えます。ページの隣にターミナルタブを置けて、普段使っている AI エージェントから
内蔵の MCP サーバーを通じて、エージェント専用のスペースで操作できます。無料、MIT ライセンス、アカウント不要。
Arc から移るなら、スペース、固定タブ、フォルダを数回のクリックで読み込めます。

> **ステータス：公開ベータ版。** Lilo は毎日使えますが、まだベータ版です。細部に不具合があったり、
> インターフェイスが変わったりすることがあります。[問題があれば報告してください](https://github.com/Alexays/Lilo/issues)。
> 優先事項と対象外の項目は [ROADMAP.md](../../ROADMAP.md) に記載しています。

[Discord コミュニティ](https://discord.gg/NyJRAapk76)で、フィードバックの共有や Lilo の使い方の相談ができます。

## Lilo を選ぶ理由

Arc の代替ブラウザの多くは、Chromium に新しいサイドバーを付けたものです。Lilo はサイドバーを残し、そのほかを変えます。

- **Chromium を使いません。** ブラウザエンジンの同梱も Electron もありません。Swift、AppKit、システムの WebKit を使い、
  サイドバーと設定は Svelte で作っています。メモリ使用量を抑え、バッテリーを長持ちさせ、macOS のリリースごとに
  Apple のセキュリティアップデートを受けられます。
- **プライバシーは標準で。** アカウント、テレメトリ、アクセス解析、サーバーはありません。操作内容が
  プロジェクトに送られることもありません。広告とトラッカーは最初からブロックし、Safari と同様にサイト越えトラッキングも
  防ぎます。Global Privacy Control もオンです（macOS 27）。Lilo 自体が送るすべてのリクエストと、
  [それをオフにする方法を公開しています](../../PRIVACY.md#requests-lilo-makes-on-its-own)。
- **Chrome 機能拡張も使えます。** 通常、Chromium を離れると機能拡張も手放すことになります。Lilo では、
  Chrome ウェブストアの「Lilo に追加」を1回クリックするだけで、WebKit のネイティブランタイムにインストールできます
  （[COMPATIBILITY.md](../../COMPATIBILITY.md)）。
- **いつものエージェントで操作。Lilo 自体に AI は搭載しません。** チャットボットを付け足すのではなく、すでに使っている
  エージェント（Claude Code、Codex、Cursor、その他の MCP クライアント）が、内蔵の MCP サーバー経由で本物のブラウザを
  操作します。専用のスペースと一時プロファイルで作業し、送信、支払い、削除の前には確認を求めます。
- **ページの隣にターミナル。** Ghostty ベースのターミナルタブをサイトと同じサイドバーに表示し、
  リポジトリのブランチと未コミットの変更も確認できます。
- **自分のブラウザに。** MIT ライセンスです。インターフェイス全体が WebKit 上の Svelte レイヤーなので、自由に変更して
  数秒で再ビルドできます。

## 機能

**ブラウジング**

- **スペースとプロファイル**：絵文字と色でスペースを分け、それぞれのプロファイルでサインインできます。
  スワイプで切り替えられ、プライベートスペースは閉じるとすべてを消去します。
- **サイドバー**：固定タブ、お気に入り、最大5階層のフォルダ（ロック可能）、ドラッグでの並べ替え、
  オーディオと再生中のメディアのコントロール。
- **コマンドバー**（`Cmd+T`）：タブ、履歴、ブックマーク、スペース、すべてのアクションを1つの入力欄で検索。
  使用状況に応じた順番で表示します。
- **最近使ったタブ**（`Ctrl+Tab`）：すべてのスペースの最近使ったタブを、使用した順に切り替えられます。
- **プレビュー**：固定タブから別のサイトへのリンクや、`Shift` キーを押しながらクリックしたリンクを、
  ページの上に開きます。
- **小さなウインドウ**（どのアプリからでも `Cmd+Option+N`）：リンクや検索を1つ開く小さなウインドウ。
  続けて使いたくなったら、スペースに送れます。
- **タブを自動で整理**：固定されていないタブは、スペースごとに指定した時間使わないとアーカイブされます。
  `Cmd+Shift+K` でまとめて消去でき、アーカイブにもキー操作ひとつでアクセスできます。
- **リンクのルール**：ほかのアプリから開いたリンクを、ルールに応じてスペースや小さなウインドウに振り分けます。
- **分割表示**：最大4つのタブを並べて表示し、再起動後も復元します。
- **ショートカット**：Lilo または Arc のプリセットを基に、すべてのショートカットを変更できます。
- **読み込み**：Safari、Firefox、Zen、Chromium 系ブラウザ（Chrome、Arc、Brave、Edge、Vivaldi、Opera、Dia、Comet、
  Chromium）から、ブックマーク、開いているタブとスペース、履歴、Cookie、機能拡張を Mac 上で直接読み込みます。

**機能拡張と Web**

- **Chrome 機能拡張**：WebKit のネイティブ機能拡張ランタイムで Manifest V3 を実行し、WebKit にない API は小さな Swift
  ハンドラで補います（[COMPATIBILITY.md](../../COMPATIBILITY.md)）。
- **パスワードマネージャ**：初期設定で、いつものマネージャを選べます（1Password、Bitwarden、Dashlane、KeePassXC、
  NordPass、Proton Pass）。
- **ストリーミング**：FairPlay による保護されたビデオと音楽。YouTube は 4K HDR に対応。
- **コンテンツブロック**：EasyList、EasyPrivacy、uBlock Origin のリストを常に更新し、
  要素の非表示とスクリプトレットにも対応します。
- **スクリーンショット**：撮影した画像はページの上にカードとして表示され、マークアップで編集したり、保存したり、
  閉じたりできます。
- **そのほかにも**：リーダーモード、ピクチャ・イン・ピクチャ（通話は最前面のパネルに表示）、ページの翻訳、
  Web Serial、AppleScript、ショートカットのアクション、集中モードフィルタ。

**開発する人のために**

- **ターミナルタブ**：Metal レンダラ上で動作する libghostty-vt ターミナルを、ページの隣に表示します
  （`Cmd+D` で横、`Cmd+Shift+D` で下）。ブランチと未コミットの変更はサイドバーで確認できます。
- **変更ビュー**：画像を含め、リポジトリのすべての差分を表示します。
- **作業中のスリープを防止**：長いコマンドの実行中は蓋を閉じても Mac をスリープさせず、終わったらスリープを許可します。
- **MCP 経由のエージェント操作**：内蔵の MCP サーバー。[AI エージェント向け](#ai-エージェント向け)を参照してください。

## AI エージェント向け

Lilo には MCP サーバーが内蔵されています。オンにすると、いつものエージェント（Claude Code、Claude Desktop、
Codex、Cursor、その他の MCP クライアント）が、あなたの隣で本物の WebKit ブラウザを操作します。
Lilo 自体に AI は搭載していません。

- **専用のスペース。** エージェントはエージェントスペース内のフォルダにタブを開き、セッションごとに消去される
  一時プロファイルを使います。キーボード、マウス、タブを占有せず、プライベートスペースを見ることもありません。
  許可すると、あなたのプロファイルを借りることもできます。
- **必ず確認してから。** エージェントが送信、支払い、削除、公開をする前に Lilo が確認します（「1回だけ許可」、
  「このサイトで常に許可」、または「拒否」）。あなたのファイルをページに渡す前にも確認します。クライアントは初回に承認が必要で、
  自称する名前ではなく、実際に動作するプログラムと結び付けられます。
- **1クリックで接続。** 「設定」>「AI エージェント」で「AI エージェントに Lilo の使用を許可」をオンにし、
  Claude Code、Claude Desktop、Codex、Cursor の横にある「接続」を押してください。そのクライアントの MCP サーバーに
  Lilo を追加します。その他のクライアントは「その他のエージェント」から構成をコピーできます。

あとは、エージェントに次のように依頼してください：

```text
Lilo で localhost:3000/checkout を開き、テスト用カードで支払いをして、注文が失敗する理由を調べて。
コンソールとネットワークを確認して。
```

ツールは以下に対応しています：

- エージェントのフォルダ内の**タブとナビゲーション**、および Cookie やサインインを共有しない分離タブ。
- **入力**：クリック、文字入力、キー操作、スクロール、ドラッグ、フォーム入力、ファイルと画像のアップロード。
- **ページの読み取り**：要素参照を含むアクセシビリティツリー、テキスト検索、ページのテキスト。
- ページ全体または要素1つの**スクリーンショット**、GIF 録画。
- **コンソールとネットワーク**：メッセージ、レスポンス全体を含むリクエスト、HAR 書き出し、Cookie。
- **ネットワークのモックとエミュレーション**：リクエストのモック、失敗、遅延、ユーザエージェント、配色、
  視差効果の軽減、印刷メディア、追加ヘッダ、初期化スクリプト、ビューポートのサイズ。
- **パフォーマンス**：読み込みと描画の指標、メモリ、タイムラインプロファイル。
- **Web インスペクタ**：WebKit 自体のインスペクタプロトコル、コマンド、イベント。
- **スクリプト**：ページ内の JavaScript、タブの Cookie を使う `fetch`、`run` や
  `browser_batch` で複数の呼び出しを1回の通信にまとめる処理。
- **プロファイル**：一覧表示、許可を得て借りる操作、一時プロファイルのリセット。

詳しくは [docs/AI-AGENTS.md](../../docs/AI-AGENTS.md) を参照してください。
確認される内容、確認されない内容、あなたの対応が必要なエラーを説明しています。

## インストール

次のいずれかを選んでください：

- [リリース](https://github.com/Alexays/Lilo/releases/latest)から DMG をダウンロードする、または
- Homebrew でインストールする：

  ```bash
  brew install --cask alexays/tap/lilo
  ```

Lilo は、署名済みの Sparkle アップデートで自動更新します。

### 動作要件

- macOS 26 以降。Global Privacy Control には macOS 27 が必要です。

## ソースからビルド

Xcode 27 と Node.js 22.6 以降をインストールしてから実行してください（[すべての前提条件](../../CONTRIBUTING.md#requirements)）：

```bash
git clone https://github.com/Alexays/Lilo.git && cd Lilo
make bootstrap                  # checks the prerequisites and fetches or builds what the app needs
make install                    # Release build into /Applications, replacing an installed copy
open /Applications/Lilo.app
```

`make bootstrap` は、不足しているものとインストール方法を案内します。前提条件を確認し、必要なものを取得またはビルドします。
`make install` は Release ビルドを `/Applications` に配置し、インストール済みのコピーを置き換えます。
インターフェイスだけを変更するなら Node.js だけで十分です。`make ui-preview` を実行すると、ブラウザでホットリロード付きの
プレビューを開きます（[CONTRIBUTING.md](../../CONTRIBUTING.md#interface-only)）。

Apple Developer アカウントは不要です。ソースからのビルドは、デフォルトでアドホック署名されます。
その制約と、無料の Apple ID で署名する方法は [CONTRIBUTING.md](../../CONTRIBUTING.md#signing) で説明しています。

## ドキュメント

- [docs/](../../docs/README.md)：アーキテクチャ、デバッグ、ローカライズ、リリース、AI エージェント
- [COMPATIBILITY.md](../../COMPATIBILITY.md)：機能拡張とサイトにおける Chrome との差異
- [PRIVACY.md](../../PRIVACY.md)：Lilo 自体が送るすべてのリクエスト
- [ROADMAP.md](../../ROADMAP.md)：実装済みの機能、今後の予定、対象外の項目

## 貢献する

プルリクエストを歓迎します。[CONTRIBUTING.md](../../CONTRIBUTING.md) に、セットアップ、開発の進め方、
プルリクエストのチェックリストをまとめています。質問は [Discussions](https://github.com/Alexays/Lilo/discussions)
（[SUPPORT.md](../../SUPPORT.md)）へ、脆弱性は非公開で報告してください（[SECURITY.md](../../SECURITY.md)）。
参加者は全員、[行動規範](../../CODE_OF_CONDUCT.md)に従います。

## ライセンス

MIT。詳しくは [LICENSE](../../LICENSE) を参照してください。同梱する第三者のコンポーネントは
[THIRD-PARTY-NOTICES.md](../../THIRD-PARTY-NOTICES.md) に記載しています。
