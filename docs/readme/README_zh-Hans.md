<div align="center">

[English](../../README.md) · [Français](README_fr.md) · [Español](README_es.md) · **简体中文** · [Português (Brasil)](README_pt-BR.md) · [Русский](README_ru.md)

# Lilo

**让你的互联网，焕然绽放。**

轻巧不拖累 Mac，上网迅捷，默认保护隐私。免费且开源。

[![CI](https://github.com/Alexays/Lilo/actions/workflows/build.yml/badge.svg)](https://github.com/Alexays/Lilo/actions/workflows/build.yml)
[![许可证：MIT](https://img.shields.io/badge/License-MIT-6a4be0.svg)](../../LICENSE)
[![状态：公开测试版](https://img.shields.io/badge/status-public%20beta-e07a4b.svg)](#安装)

[网站](https://getlilo.app) ·
[Discord](https://discord.gg/NyJRAapk76) ·
[安装](#安装) ·
[从源码构建](#从源码构建) ·
[文档](../README.md) ·
[参与贡献](../../CONTRIBUTING.md)

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../assets/lilo-dark.png">
  <img src="../assets/lilo-light.png" alt="Lilo 打开工作空间：侧边栏中有固定网站、文件夹和标签页，旁边显示网页与终端标签页" width="900">
</picture>

</div>

Lilo 是一款为习惯侧边栏的用户打造的 Mac 浏览器，并非又一个 Chromium 分支。
它使用原生 Swift 和 AppKit，基于 macOS 自带的 WebKit 引擎，同时仍能运行你依赖的 Chrome 扩展。
它将终端标签页放在网页旁边，还让你现有的 AI 智能体通过内置 MCP 服务器操控浏览器，
在各自独立的空间中工作。免费，采用 MIT 许可证，无需账户。如果你准备离开 Arc，
只需点击几下即可导入空间、固定标签页和文件夹。

> **状态：公开测试版。** Lilo 已可用于日常浏览，但仍处于测试阶段，可能存在不完善之处，
> 界面也仍在调整。欢迎[报告遇到的问题](https://github.com/Alexays/Lilo/issues)。
> [ROADMAP.md](../../ROADMAP.md) 列出了优先事项以及项目不打算实现的内容。

加入 [Discord 社区](https://discord.gg/NyJRAapk76)，分享反馈并获取 Lilo 使用帮助。

## 为什么选择 Lilo

多数 Arc 替代品只是在 Chromium 上换了一个侧边栏。Lilo 保留侧边栏，改变其余部分。

- **不依赖 Chromium。** 不捆绑浏览器引擎，不使用 Electron：采用 Swift、AppKit 和系统 WebKit，
  侧边栏与设置使用 Svelte。内存占用更低，电池续航更长，随每次 macOS 更新获得 Apple 的安全更新。
- **默认保护隐私。** 无需账户，没有遥测、使用情况分析或服务器：你的任何操作都不会发送给项目。
  默认拦截广告和跟踪器，像 Safari 一样阻止跨站跟踪，并启用 Global Privacy Control（macOS 27）。
  Lilo 自行发出的每一类请求都[列有说明及关闭方法](../../PRIVACY.md#requests-lilo-makes-on-its-own)。
- **照样使用 Chrome 扩展。** 离开 Chromium 往往意味着放弃扩展。在 Lilo 中，点击“添加到 Lilo”
  即可通过 WebKit 原生扩展运行时安装 Chrome 应用商店扩展
  （[COMPATIBILITY.md](../../COMPATIBILITY.md)）。
- **由你的智能体操控，不内置自己的 AI。** 没有额外塞入的聊天机器人：你已有的智能体
  （Claude Code、Codex、Cursor 或任何 MCP 客户端）通过内置 MCP 服务器使用真正的浏览器，
  在自己的空间和临时配置文件中工作，并在发送、付款或删除前征求你的同意。
- **网页旁的终端。** 基于 Ghostty 的终端标签页与网站一起放在侧边栏中，显示所属仓库的分支和待提交更改。
- **由你掌控。** 采用 MIT 许可证。整个界面是一层基于 WebKit 的 Svelte 界面，你可以修改并在几秒内重新构建。

## 功能

**浏览**

- **空间与配置文件**：每个空间都有表情符号和颜色，并使用各自配置文件中的登录状态；滑动即可切换。
  私密空间关闭后会清除所有浏览数据。
- **侧边栏**：固定标签页、收藏、最多嵌套五层且可锁定的文件夹、拖动排序，以及音频和当前播放控制。
- **命令栏**（`Cmd+T`）：在一个输入框中搜索标签页、历史记录、书签、空间和所有操作，按使用情况排序。
- **最近的标签页**（`Ctrl+Tab`）：按使用顺序切换所有空间中最近访问的标签页。
- **Peek**：从固定标签页打开其他网站的链接，或按住 `Shift` 点击任意链接，都会在当前页面上方打开预览。
- **小窗口**（`Cmd+Option+N`，可从任意应用调用）：用一个小窗口打开链接或搜索，需要继续处理时可移入空间。
- **自动整理标签页**：不再使用的未固定标签页会在你为各空间设置的延迟后归档；
  `Cmd+Shift+K` 可清理这些标签页，按一下快捷键即可打开归档。
- **链接规则**：从其他应用打开的链接，会按规则进入指定空间或小窗口。
- **分屏视图**：最多并排显示四个标签页，重新启动后恢复。
- **快捷键**：每个快捷键都可重新映射，以 Lilo 或 Arc 预设为起点。
- **导入**：直接从 Mac 读取 Safari、Firefox、Zen 和 Chromium 系浏览器
  （Chrome、Arc、Brave、Edge、Vivaldi、Opera、Dia、Comet、Chromium）的书签、已打开的标签页与空间、
  历史记录、Cookie 和扩展。

**扩展与网页**

- **Chrome 扩展**：通过 WebKit 原生扩展运行时支持 Manifest V3，再用小型 Swift 处理程序补齐 WebKit 缺少的 API
  （[COMPATIBILITY.md](../../COMPATIBILITY.md)）。
- **密码管理器**：设置时会提供你正在使用的密码管理器
  （1Password、Bitwarden、Dashlane、KeePassXC、NordPass、Proton Pass）。
- **流媒体**：通过 FairPlay 播放受保护的视频和音乐；支持 YouTube 4K HDR。
- **内容拦截**：持续更新的 EasyList、EasyPrivacy 和 uBlock Origin 规则列表，支持元素隐藏和脚本片段。
- **截图**：截图以卡片形式悬浮在页面上方，可直接标注、保存或关闭。
- **更多功能**：阅读模式、画中画（通话悬浮在始终置顶的面板中）、网页翻译、Web Serial、AppleScript、
  快捷指令操作和专注模式过滤条件。

**开发者功能**

- **终端标签页**：使用 Metal 渲染的 libghostty-vt 终端，与网页并排显示
  （`Cmd+D` 在旁边拆分，`Cmd+Shift+D` 在下方拆分），侧边栏显示分支和待提交更改。
- **更改视图**：查看仓库中的所有差异，包括图片。
- **工作时保持唤醒**：长时间运行的命令会让 Mac 保持唤醒，即使合上屏幕也一样；完成后恢复正常睡眠。
- **通过 MCP 使用智能体**：内置 MCP 服务器，参见 [AI 智能体](#ai-智能体)。

## AI 智能体

Lilo 内置 MCP 服务器。开启后，你已经在使用的智能体（Claude Code、Claude Desktop、Codex、
Cursor 或任何 MCP 客户端）就能与你一起操作真正的 WebKit 浏览器。Lilo 本身不附带 AI。

- **独立的空间。** 智能体在“智能体”空间的文件夹中打开标签页，使用每次会话结束后都会清除的临时配置文件。
  它们不会接管你的键盘、鼠标或标签页，也无法查看私密空间。经你允许，智能体可以借用你的某个配置文件。
- **先征求你的同意。** 智能体发送、付款、删除或发布前，Lilo 会请求授权
  （允许一次、在该网站始终允许或拒绝），向网页提供你的文件前也一样。
  每个客户端只需批准一次，授权绑定到实际运行的程序，而非它自报的名称。
- **一键连接。** 在“设置 > AI 智能体”中，开启“允许 AI 智能体使用 Lilo”，
  然后点击 Claude Code、Claude Desktop、Codex 或 Cursor 旁的“连接”，Lilo 就会加入该客户端的 MCP 服务器列表。
  其他客户端可从“其他智能体”复制配置。

然后可以这样向智能体提出要求：

```text
在 Lilo 中打开 localhost:3000/checkout，用测试卡付款，查明订单失败的原因。
检查控制台和网络。
```

工具涵盖：

- **标签页与导航**：操作智能体文件夹中的标签页，以及不共享 Cookie 或登录状态的隔离标签页。
- **输入**：点击、输入文字、按键、滚动、拖动、填写表单、上传文件和图片。
- **读取页面**：带元素引用的无障碍树、文本搜索和页面文本。
- **截图**：截取整个页面或单个元素，并录制 GIF。
- **控制台与网络**：消息、请求及其完整响应、HAR 导出和 Cookie。
- **网络模拟与环境仿真**：模拟请求、请求失败或延迟；设置用户代理、配色方案、减少动态效果、
  打印媒体、额外请求头、初始化脚本以及视口大小。
- **性能**：加载和绘制指标、内存与时间线性能分析。
- **网页检查器**：WebKit 自身的检查器协议、命令和事件。
- **脚本**：在页面中执行 JavaScript，使用标签页的 Cookie 发起 `fetch` 请求，
  以及通过 `run` 或 `browser_batch` 在一次往返中串联多个调用。
- **配置文件**：列出配置文件，经你允许借用一个，或重置临时配置文件。

[docs/AI-AGENTS.md](../AI-AGENTS.md) 详细说明了哪些操作需要授权、哪些不需要，以及哪些错误需要你介入。

## 安装

任选一种方式：

- 从[发行版页面](https://github.com/Alexays/Lilo/releases/latest)下载 DMG，或
- 使用 Homebrew 安装：

  ```bash
  brew install --cask alexays/tap/lilo
  ```

Lilo 通过经过签名的 Sparkle 更新自动升级。

### 系统要求

- macOS 26 或更高版本。Global Privacy Control 需要 macOS 27。

## 从源码构建

安装 Xcode 27 和 Node.js 22.6+ 后（[完整前提条件](../../CONTRIBUTING.md#requirements)）：

```bash
git clone https://github.com/Alexays/Lilo.git && cd Lilo
make bootstrap                  # checks the prerequisites and fetches or builds what the app needs
make install                    # Release build into /Applications, replacing an installed copy
open /Applications/Lilo.app
```

`make bootstrap` 会列出缺少的依赖及其安装方法。如果只开发界面，安装 Node.js 即可：
`make ui-preview` 会在浏览器中打开界面，并支持热重载
（[CONTRIBUTING.md](../../CONTRIBUTING.md#interface-only)）。

无需 Apple Developer 账户。源码构建默认使用 ad hoc 签名；
[CONTRIBUTING.md](../../CONTRIBUTING.md#signing) 说明了其中的取舍，以及如何使用免费的 Apple ID 签名。

## 文档

- [docs/](../README.md)：架构、调试、本地化、发布和 AI 智能体
- [COMPATIBILITY.md](../../COMPATIBILITY.md)：扩展与网站方面仍与 Chrome 存在的差异
- [PRIVACY.md](../../PRIVACY.md)：Lilo 自行发出的所有请求
- [ROADMAP.md](../../ROADMAP.md)：已发布功能、后续计划和项目不打算实现的内容

## 参与贡献

欢迎提交拉取请求。[CONTRIBUTING.md](../../CONTRIBUTING.md) 介绍了环境设置、开发流程和拉取请求检查清单。
问题可在[讨论区](https://github.com/Alexays/Lilo/discussions)提出
（[SUPPORT.md](../../SUPPORT.md)），安全漏洞请私下报告（[SECURITY.md](../../SECURITY.md)）。
所有参与者都应遵守[行为准则](../../CODE_OF_CONDUCT.md)。

## 许可证

MIT，参见 [LICENSE](../../LICENSE)。随附的第三方组件列于
[THIRD-PARTY-NOTICES.md](../../THIRD-PARTY-NOTICES.md)。
