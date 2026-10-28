<div align="center">

[English](../../README.md) · [Français](README_fr.md) · [Español](README_es.md) · [简体中文](README_zh-Hans.md) · **Português (Brasil)** · [Русский](README_ru.md) · [Українська](README_uk.md) · [Deutsch](README_de.md) · [日本語](README_ja.md)

# Lilo

**Sua internet, em flor.**

Leve no seu Mac, rápido na web e privado por padrão. Gratuito e de código aberto.

[![CI](https://github.com/Alexays/Lilo/actions/workflows/build.yml/badge.svg)](https://github.com/Alexays/Lilo/actions/workflows/build.yml)
[![Licença: MIT](https://img.shields.io/badge/License-MIT-6a4be0.svg)](../../LICENSE)
[![Status: beta público](https://img.shields.io/badge/status-public%20beta-e07a4b.svg)](#instalação)

[Site](https://getlilo.app) ·
[Discord](https://discord.gg/NyJRAapk76) ·
[Instalação](#instalação) ·
[Compilar a partir do código-fonte](#compilar-a-partir-do-código-fonte) ·
[Documentação](../README.md) ·
[Contribuir](../../CONTRIBUTING.md)

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../assets/lilo-dark.png">
  <img src="../assets/lilo-light.png" alt="Lilo com o espaço Trabalho aberto: barra lateral com sites fixados, pastas e abas, ao lado de uma página web e uma aba de terminal" width="900">
</picture>

</div>

Lilo é um navegador para Mac feito para quem vive na barra lateral. Ele não é mais um fork do
Chromium: usa Swift e AppKit nativos, com o motor WebKit que já vem no macOS, e ainda executa as
extensões do Chrome das quais você depende. Coloca abas de terminal ao lado das suas páginas e
permite que os agentes de IA que você já usa o controlem pelo servidor MCP integrado, em um espaço
próprio. Gratuito, com licença MIT e sem conta. Se você está saindo do Arc, ele importa seus
espaços, abas fixadas e pastas em poucos cliques.

> **Status: beta público.** Lilo pode ser usado no dia a dia, mas ainda está em beta: espere
> alguns detalhes por ajustar e uma interface que continua mudando. Por favor,
> [relate os problemas](https://github.com/Alexays/Lilo/issues).
> [ROADMAP.md](../../ROADMAP.md) lista as prioridades e o que está fora do escopo do projeto.

Entre na [comunidade do Discord](https://discord.gg/NyJRAapk76) para compartilhar sugestões e obter ajuda com o Lilo.

## Por que Lilo

A maioria das alternativas ao Arc é Chromium com uma barra lateral nova. Lilo mantém a barra
lateral e muda o resto.

- **Sem Chromium.** Sem motor de navegador empacotado nem Electron: Swift, AppKit e o WebKit do
  sistema, com a barra lateral e os ajustes em Svelte. Menor uso de memória, bateria que dura o
  dia todo e as atualizações de segurança da Apple a cada versão do macOS.
- **Privado por padrão.** Sem conta, telemetria, análise de uso ou servidor: nada do que você faz
  é enviado ao projeto. Anúncios e rastreadores são bloqueados desde o início, o rastreamento
  entre sites é bloqueado como no Safari e o Global Privacy Control fica ativado (macOS 27).
  Cada requisição que Lilo faz por conta própria está
  [listada, junto com a forma de desativá-la](../../PRIVACY.md#requests-lilo-makes-on-its-own).
- **Com extensões do Chrome.** Sair do Chromium geralmente significa deixar suas extensões.
  No Lilo, as extensões da Chrome Web Store são instaladas com um clique em “Adicionar ao Lilo”,
  pelo ambiente de execução nativo do WebKit ([COMPATIBILITY.md](../../COMPATIBILITY.md)).
- **Seus agentes o controlam; ele não tem IA própria.** Sem chatbot acoplado: os agentes que
  você já executa (Claude Code, Codex, Cursor ou qualquer cliente MCP) usam um navegador real pelo
  servidor MCP integrado, no próprio espaço e em um perfil temporário. Eles pedem sua permissão
  antes de enviar, pagar ou excluir.
- **Um terminal ao lado das suas páginas.** As abas de terminal baseadas no Ghostty ficam na
  barra lateral junto dos seus sites, mostrando a branch e as alterações pendentes do repositório.
- **Seu.** Com licença MIT. Toda a interface é uma camada Svelte sobre o WebKit que você pode
  modificar e recompilar em segundos.

## Recursos

**Navegação**

- **Espaços e perfis**: espaços com emoji e cor, cada um com a sessão do próprio perfil;
  alterne entre eles deslizando. Espaços privados esquecem tudo ao fechar.
- **Barra lateral**: abas fixadas, favoritos, pastas aninhadas em até cinco níveis (com opção
  de bloqueio), reordenação por arrastar e controles de áudio e reprodução.
- **Barra de comandos** (`Cmd+T`): abas, histórico, favoritos, espaços e todas as ações em um
  campo, ordenados conforme seu uso.
- **Abas recentes** (`Ctrl+Tab`): percorra as últimas abas de todos os espaços na ordem em que
  você as usou.
- **Peek**: um link de uma aba fixada para outro site, ou qualquer link aberto com `Shift`+clique,
  aparece sobre a página.
- **Minijanela** (`Cmd+Option+N`, a partir de qualquer app): uma janela para um link ou uma
  busca, que pode ser enviada a um espaço quando você quiser continuar.
- **Abas que se organizam sozinhas**: abas não fixadas que você deixa de usar são arquivadas
  após um intervalo escolhido por espaço; `Cmd+Shift+K` limpa essas abas, e o arquivo fica a
  um atalho de distância.
- **Regras de links**: links abertos de outros apps vão para o espaço ou a minijanela que
  uma regra escolher.
- **Visualização dividida**: até quatro abas lado a lado, restauradas ao reabrir.
- **Atalhos**: todos os atalhos podem ser remapeados, a partir do padrão do Lilo ou do Arc.
- **Importação**: favoritos, abas abertas e espaços, histórico, cookies e extensões do Safari,
  Firefox, Zen e de navegadores Chromium (Chrome, Arc, Brave, Edge, Vivaldi, Opera, Dia, Comet,
  Chromium), lidos diretamente do seu Mac.

**Extensões e web**

- **Extensões do Chrome**: Manifest V3 pelo ambiente de extensões nativo do WebKit, com pequenos
  handlers Swift para as APIs que faltam ([COMPATIBILITY.md](../../COMPATIBILITY.md)).
- **Gerenciadores de senhas**: a configuração oferece o que você usa (1Password, Bitwarden,
  Dashlane, KeePassXC, NordPass, Proton Pass).
- **Streaming**: vídeo e música protegidos via FairPlay; YouTube em 4K HDR.
- **Bloqueio de conteúdo**: listas EasyList, EasyPrivacy e uBlock Origin atualizadas, com
  filtragem cosmética e scriptlets.
- **Capturas de tela**: a captura flutua como um cartão sobre a página, pronta para receber
  anotações, ser salva ou descartada.
- **E mais**: modo de leitura, Picture-in-Picture (chamadas flutuam em um painel sempre no topo),
  tradução de páginas, Web Serial, AppleScript, ações do Atalhos e um filtro de Foco.

**Para quem desenvolve**

- **Abas de terminal**: terminais libghostty-vt com renderização em Metal, ao lado das suas
  páginas (`Cmd+D` ao lado, `Cmd+Shift+D` abaixo), com a branch e as alterações pendentes na
  barra lateral.
- **Visualização de alterações**: todas as diferenças do repositório, incluindo imagens.
- **Acordado enquanto trabalha**: um comando longo mantém o Mac acordado, mesmo com a tampa
  fechada, e permite que volte a repousar quando termina.
- **Agentes via MCP**: o servidor MCP integrado; veja [Para agentes de IA](#para-agentes-de-ia).

## Para agentes de IA

Lilo tem um servidor MCP integrado. Ative-o e os agentes que você já usa (Claude Code, Claude
Desktop, Codex, Cursor ou qualquer cliente MCP) controlam um navegador WebKit real ao seu lado.
Lilo não inclui IA própria.

- **O próprio espaço.** Os agentes abrem abas em uma pasta do espaço Agentes, em um perfil
  temporário apagado após cada sessão. Eles nunca tomam seu teclado, mouse ou abas, e nunca
  enxergam um espaço privado. Um agente pode usar um dos seus perfis com sua autorização.
- **Você permite primeiro.** Lilo pergunta antes de um agente enviar, pagar, excluir ou publicar
  (permitir uma vez, permitir sempre no site ou negar), e antes de entregar um dos seus arquivos
  a uma página. Cada cliente é aprovado uma única vez, vinculado ao programa que o executa em
  vez do nome que ele informa.
- **Conexão em um clique.** Em Ajustes > Agentes de IA, ative “Permitir que agentes de IA usem
  o Lilo” e clique em “Conectar” ao lado de Claude Code, Claude Desktop, Codex ou Cursor:
  Lilo se adiciona aos servidores MCP desse cliente. Para outros clientes, copie a configuração
  de “Outros agentes”.

Depois, peça ao seu agente algo como:

```text
Abra localhost:3000/checkout no Lilo, pague com o cartão de teste e descubra por que o pedido falha.
Verifique o console e a rede.
```

As ferramentas cobrem:

- **Abas e navegação** na pasta do agente, além de abas isoladas que não compartilham cookies
  nem sessões.
- **Entrada**: cliques, digitação, teclas, rolagem, arrastar, preenchimento de formulários e
  envio de arquivos e imagens.
- **Leitura de páginas**: árvore de acessibilidade com referências a elementos, busca de texto
  e texto da página.
- **Capturas de tela** de uma página inteira ou de um elemento, e gravações GIF.
- **Console e rede**: mensagens, requisições com respostas completas, exportação HAR e cookies.
- **Simulação de rede e emulação**: requisições simuladas, com falha ou atrasadas; agente de
  usuário, esquema de cores, movimento reduzido, mídia de impressão, cabeçalhos extras, scripts
  de inicialização e tamanho da área de visualização.
- **Desempenho**: métricas de carregamento e pintura, memória e perfis da linha do tempo.
- **Inspetor web**: o protocolo de inspeção do próprio WebKit, seus comandos e eventos.
- **Scripts**: JavaScript na página, `fetch` de uma aba com seus cookies e `run` ou
  `browser_batch` para encadear várias chamadas em uma única ida e volta.
- **Perfis**: listá-los, usar um com sua autorização ou redefinir o temporário.

[docs/AI-AGENTS.md](../AI-AGENTS.md) explica quais permissões são solicitadas, quais não são e
quais erros precisam da sua intervenção.

## Instalação

Você pode:

- baixar o DMG nas [versões publicadas](https://github.com/Alexays/Lilo/releases/latest), ou
- instalar com o Homebrew:

  ```bash
  brew install --cask alexays/tap/lilo
  ```

Lilo se atualiza automaticamente por meio de atualizações assinadas do Sparkle.

### Requisitos

- macOS 26 ou posterior. Global Privacy Control requer macOS 27.

## Compilar a partir do código-fonte

Com Xcode 27 e Node.js 22.6+ instalados ([pré-requisitos completos](../../CONTRIBUTING.md#requirements)):

```bash
git clone https://github.com/Alexays/Lilo.git && cd Lilo
make bootstrap                  # checks the prerequisites and fetches or builds what the app needs
make install                    # Release build into /Applications, replacing an installed copy
open /Applications/Lilo.app
```

`make bootstrap` informa o que está faltando e como instalar. Para trabalhar apenas na interface,
Node.js basta: `make ui-preview` abre a interface no navegador com recarga automática
([CONTRIBUTING.md](../../CONTRIBUTING.md#interface-only)).

Não é necessária uma conta Apple Developer. As compilações a partir do código-fonte usam
assinatura ad hoc por padrão; [CONTRIBUTING.md](../../CONTRIBUTING.md#signing) explica as
limitações e como assinar com um ID Apple gratuito.

## Documentação

- [docs/](../README.md): arquitetura, depuração, tradução, publicação e agentes de IA
- [COMPATIBILITY.md](../../COMPATIBILITY.md): diferenças restantes em relação ao Chrome para extensões e sites
- [PRIVACY.md](../../PRIVACY.md): cada requisição que Lilo faz por conta própria
- [ROADMAP.md](../../ROADMAP.md): o que já foi lançado, o que vem a seguir e o que está fora do escopo

## Contribuir

Pull requests são bem-vindas. [CONTRIBUTING.md](../../CONTRIBUTING.md) cobre a preparação, o
fluxo de desenvolvimento e a lista de verificação de pull requests. Tire dúvidas em
[Discussions](https://github.com/Alexays/Lilo/discussions) ([SUPPORT.md](../../SUPPORT.md)) e
relate vulnerabilidades em particular ([SECURITY.md](../../SECURITY.md)). Todas as pessoas que
participam seguem o [código de conduta](../../CODE_OF_CONDUCT.md).

## Licença

MIT; veja [LICENSE](../../LICENSE). Os componentes de terceiros incluídos estão listados em
[THIRD-PARTY-NOTICES.md](../../THIRD-PARTY-NOTICES.md).
