<div align="center">

[English](../../README.md) · [Français](README_fr.md) · **Español** · [简体中文](README_zh-Hans.md) · [Português (Brasil)](README_pt-BR.md) · [Русский](README_ru.md) · [Українська](README_uk.md) · [Deutsch](README_de.md) · [日本語](README_ja.md) · [Italiano](README_it.md)

# Lilo

**Tu internet, en flor.**

Ligero en tu Mac, rápido en la web y privado por defecto. Gratis y de código abierto.

[![CI](https://github.com/Alexays/Lilo/actions/workflows/build.yml/badge.svg)](https://github.com/Alexays/Lilo/actions/workflows/build.yml)
[![Licencia: MIT](https://img.shields.io/badge/License-MIT-6a4be0.svg)](../../LICENSE)
[![Estado: beta pública](https://img.shields.io/badge/status-public%20beta-e07a4b.svg)](#instalación)

[Sitio web](https://getlilo.app) ·
[Discord](https://discord.gg/NyJRAapk76) ·
[Instalación](#instalación) ·
[Compilar desde el código fuente](#compilar-desde-el-código-fuente) ·
[Documentación](../README.md) ·
[Contribuir](../../CONTRIBUTING.md)

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../assets/lilo-dark.png">
  <img src="../assets/lilo-light.png" alt="Lilo con el espacio Trabajo abierto: barra lateral con sitios fijados, carpetas y pestañas, junto a una página web y una pestaña de terminal" width="900">
</picture>

</div>

Lilo es un navegador para Mac pensado para quienes viven en una barra lateral. No es otro
derivado de Chromium: está escrito con Swift y AppKit nativos, usa el motor WebKit que ya incluye
macOS y ejecuta las extensiones de Chrome que necesitas. Coloca pestañas de terminal junto a tus
páginas y permite que los agentes de IA que ya usas lo controlen mediante un servidor MCP
integrado, en su propio espacio. Gratis, con licencia MIT y sin cuenta. Si dejas Arc, importa tus
espacios, pestañas fijadas y carpetas en unos pocos clics.

> **Estado: beta pública.** Lilo se puede usar a diario, pero sigue en beta: habrá detalles por
> pulir y una interfaz que aún cambia. Por favor,
> [informa de los problemas](https://github.com/Alexays/Lilo/issues).
> [ROADMAP.md](../../ROADMAP.md) recoge las prioridades y lo que queda fuera del alcance del proyecto.

Únete a la [comunidad de Discord](https://discord.gg/NyJRAapk76) para compartir comentarios y recibir ayuda con Lilo.

## Por qué Lilo

La mayoría de las alternativas a Arc son Chromium con una nueva barra lateral. Lilo conserva
la barra lateral y cambia el resto.

- **Sin Chromium.** Sin motor de navegador incluido ni Electron: Swift, AppKit y el WebKit del
  sistema, con la barra lateral y los ajustes en Svelte. Menor consumo de memoria, una batería
  que dura todo el día y las actualizaciones de seguridad de Apple con cada versión de macOS.
- **Privado por defecto.** Sin cuenta, telemetría, analítica ni servidor: nada de lo que haces se
  envía al proyecto. Los anuncios y rastreadores se bloquean desde el principio, se impide el
  seguimiento entre sitios como en Safari y Global Privacy Control está activado (macOS 27).
  Cada petición que Lilo realiza por su cuenta está
  [documentada, junto con cómo desactivarla](../../PRIVACY.md#requests-lilo-makes-on-its-own).
- **Con extensiones de Chrome.** Dejar Chromium suele significar dejar sus extensiones. En Lilo,
  las extensiones de Chrome Web Store se instalan con un clic en «Añadir a Lilo», mediante el
  entorno de ejecución nativo de WebKit ([COMPATIBILITY.md](../../COMPATIBILITY.md)).
- **Tus agentes lo controlan; no incluye su propia IA.** Sin chatbot añadido: los agentes que ya
  ejecutas (Claude Code, Codex, Cursor o cualquier cliente MCP) usan un navegador real mediante
  el servidor MCP integrado, en su propio espacio y un perfil temporal. Te piden permiso antes
  de enviar, pagar o borrar.
- **Un terminal junto a tus páginas.** Las pestañas de terminal basadas en Ghostty aparecen en la
  barra lateral junto a tus sitios y muestran la rama y los cambios pendientes de su repositorio.
- **Tuyo.** Con licencia MIT. Toda la interfaz es una capa de Svelte sobre WebKit que puedes
  modificar y volver a compilar en segundos.

## Funciones

**Navegación**

- **Espacios y perfiles**: espacios con un emoji y un color, cada uno con la sesión de su propio
  perfil; cambia entre ellos con un gesto de deslizamiento. Los espacios privados lo olvidan todo
  al cerrarse.
- **Barra lateral**: pestañas fijadas, favoritos, carpetas anidadas hasta cinco niveles
  (bloqueables), reordenación al arrastrar y controles de audio y reproducción.
- **Barra de comandos** (`Cmd+T`): pestañas, historial, marcadores, espacios y todas las acciones
  en un solo campo, ordenados según tu uso.
- **Pestañas recientes** (`Ctrl+Tab`): recorre las últimas pestañas de todos los espacios en el
  orden en que las usaste.
- **Peek**: un enlace desde una pestaña fijada a otro sitio, o cualquier enlace abierto con
  `Mayús`+clic, se abre sobre la página.
- **Ventana pequeña** (`Cmd+Option+N`, desde cualquier app): una ventana para un enlace o una
  búsqueda, que puedes enviar a un espacio cuando quieras continuar.
- **Pestañas que se ordenan solas**: las pestañas sin fijar que dejas de usar se archivan tras
  un plazo que eliges por espacio; `Cmd+Shift+K` las limpia, y el archivo queda a una pulsación.
- **Reglas de enlaces**: los enlaces abiertos desde otras apps van al espacio o a la ventana
  pequeña que elija una regla.
- **Vista dividida**: hasta cuatro pestañas en paralelo, restauradas al volver a abrir Lilo.
- **Atajos**: todos los atajos se pueden reasignar, partiendo del preajuste de Lilo o de Arc.
- **Importación**: marcadores, pestañas abiertas y espacios, historial, cookies y extensiones de
  Safari, Firefox, Zen y navegadores Chromium (Chrome, Arc, Brave, Edge, Vivaldi, Opera, Dia,
  Comet, Chromium), leídos directamente de tu Mac.

**Extensiones y web**

- **Extensiones de Chrome**: Manifest V3 mediante el entorno de extensiones nativo de WebKit,
  más pequeños controladores en Swift para las API que faltan
  ([COMPATIBILITY.md](../../COMPATIBILITY.md)).
- **Gestores de contraseñas**: la configuración ofrece el que usas (1Password, Bitwarden,
  Dashlane, KeePassXC, NordPass, Proton Pass).
- **Streaming**: vídeo y música protegidos mediante FairPlay; YouTube en 4K HDR.
- **Bloqueo de contenido**: listas EasyList, EasyPrivacy y uBlock Origin actualizadas, con
  filtrado cosmético y scriptlets.
- **Capturas de pantalla**: cada captura flota como una tarjeta sobre la página, lista para
  anotar, guardar o descartar.
- **Y más**: modo de lectura, imagen dentro de imagen (las llamadas flotan en un panel siempre
  visible), traducción de páginas, Web Serial, AppleScript, acciones de Atajos y un filtro de
  concentración.

**Para quienes desarrollan**

- **Pestañas de terminal**: terminales libghostty-vt con renderizado en Metal, junto a tus páginas
  (`Cmd+D` al lado, `Cmd+Shift+D` debajo), con la rama y los cambios pendientes en la barra lateral.
- **Vista de cambios**: todas las diferencias del repositorio, incluidas las imágenes.
- **Despierto mientras trabaja**: un comando largo mantiene el Mac despierto, incluso con la
  tapa cerrada, y permite que vuelva a reposar cuando termina.
- **Agentes mediante MCP**: el servidor MCP integrado; consulta [Para agentes de IA](#para-agentes-de-ia).

## Para agentes de IA

Lilo incluye un servidor MCP. Actívalo y los agentes que ya usas (Claude Code, Claude Desktop,
Codex, Cursor o cualquier cliente MCP) controlarán un navegador WebKit real a tu lado. Lilo no
incorpora su propia IA.

- **Su propio espacio.** Los agentes abren sus pestañas en una carpeta del espacio Agentes,
  en un perfil temporal que se borra tras cada sesión. Nunca toman tu teclado, ratón ni pestañas,
  y nunca ven un espacio privado. Un agente puede usar uno de tus perfiles con tu autorización.
- **Primero das tu permiso.** Lilo pregunta antes de que un agente envíe, pague, borre o publique
  (permitir una vez, permitir siempre en el sitio o denegar), y antes de entregar uno de tus
  archivos a una página. Cada cliente se aprueba una sola vez, vinculado al programa que lo
  ejecuta en vez de al nombre que declara.
- **Conexión en un clic.** En Ajustes > Agentes de IA, activa «Permitir que agentes de IA usen
  Lilo» y pulsa «Conectar» junto a Claude Code, Claude Desktop, Codex o Cursor: Lilo se
  añade a los servidores MCP de ese cliente. Para otros clientes, copia la configuración desde
  «Otros agentes».

Después, pídele a tu agente algo como:

```text
Abre localhost:3000/checkout en Lilo, paga con la tarjeta de prueba y averigua por qué falla el pedido.
Revisa la consola y la red.
```

Las herramientas cubren:

- **Pestañas y navegación** en la carpeta del agente, y pestañas aisladas que no comparten
  cookies ni sesiones.
- **Entrada**: clics, escritura, teclas, desplazamiento, arrastre, formularios y carga de archivos
  e imágenes.
- **Lectura de páginas**: árbol de accesibilidad con referencias a elementos, búsqueda de texto
  y texto de la página.
- **Capturas de pantalla** de una página completa o de un elemento, y grabaciones GIF.
- **Consola y red**: mensajes, peticiones con sus respuestas completas, exportación HAR y cookies.
- **Simulación de red y emulación**: peticiones simuladas, fallidas o retrasadas; agente de
  usuario, esquema de colores, movimiento reducido, medio de impresión, cabeceras adicionales,
  scripts de inicialización y tamaño del área de visualización.
- **Rendimiento**: métricas de carga y pintado, memoria y perfiles de la línea de tiempo.
- **Inspector web**: el protocolo de inspección de WebKit, sus comandos y eventos.
- **Scripts**: JavaScript en la página, `fetch` desde una pestaña con sus cookies y `run` o
  `browser_batch` para encadenar varias llamadas en un solo viaje de ida y vuelta.
- **Perfiles**: enumerarlos, usar uno con tu autorización o restablecer el temporal.

[docs/AI-AGENTS.md](../AI-AGENTS.md) detalla qué permisos se piden, cuáles no y qué errores
requieren tu intervención.

## Instalación

Puedes:

- descargar el DMG desde las [versiones publicadas](https://github.com/Alexays/Lilo/releases/latest), o
- instalar con Homebrew:

  ```bash
  brew install --cask alexays/tap/lilo
  ```

Lilo se actualiza automáticamente mediante actualizaciones firmadas de Sparkle.

### Requisitos

- macOS 26 o posterior. Global Privacy Control requiere macOS 27.

## Compilar desde el código fuente

Con Xcode 27 y Node.js 22.6+ instalados ([requisitos completos](../../CONTRIBUTING.md#requirements)):

```bash
git clone https://github.com/Alexays/Lilo.git && cd Lilo
make bootstrap                  # checks the prerequisites and fetches or builds what the app needs
make install                    # Release build into /Applications, replacing an installed copy
open /Applications/Lilo.app
```

`make bootstrap` indica qué falta y cómo instalarlo. Para trabajar solo en la interfaz basta con
Node.js: `make ui-preview` la abre en tu navegador con recarga en caliente
([CONTRIBUTING.md](../../CONTRIBUTING.md#interface-only)).

No necesitas una cuenta de Apple Developer. Las compilaciones desde el código fuente usan firma
ad hoc por defecto; [CONTRIBUTING.md](../../CONTRIBUTING.md#signing) explica las limitaciones y cómo
firmar con un ID de Apple gratuito.

## Documentación

- [docs/](../README.md): arquitectura, depuración, traducción, publicación y agentes de IA
- [COMPATIBILITY.md](../../COMPATIBILITY.md): diferencias restantes con Chrome para extensiones y sitios
- [PRIVACY.md](../../PRIVACY.md): cada petición que Lilo realiza por su cuenta
- [ROADMAP.md](../../ROADMAP.md): lo disponible, lo próximo y lo que queda fuera del alcance

## Contribuir

Las pull requests son bienvenidas. [CONTRIBUTING.md](../../CONTRIBUTING.md) cubre la preparación,
el flujo de desarrollo y la lista de comprobaciones para una pull request. Puedes plantear
preguntas en [Discussions](https://github.com/Alexays/Lilo/discussions)
([SUPPORT.md](../../SUPPORT.md)) y comunicar vulnerabilidades en privado
([SECURITY.md](../../SECURITY.md)). Quienes participan siguen el
[código de conducta](../../CODE_OF_CONDUCT.md).

## Licencia

MIT; consulta [LICENSE](../../LICENSE). Los componentes de terceros incluidos aparecen en
[THIRD-PARTY-NOTICES.md](../../THIRD-PARTY-NOTICES.md).
