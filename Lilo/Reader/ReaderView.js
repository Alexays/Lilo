/*
 * Lilo reader view: renders the article parsed by the bundled Mozilla Readability.js into a clean,
 * themable reading surface with in-page controls (text size, theme, width). Injected together with
 * Readability.js by ReaderMode.swift, which reads `true` back once the page shows the article. Exiting
 * reader mode is a plain reload, handled natively.
 */
(function () {
  "use strict";
  var CSS = [
    ":root{",
    "--lilo-reader-font:19px;--lilo-reader-bg:Canvas;--lilo-reader-fg:CanvasText;",
    "--lilo-reader-muted:color-mix(in srgb,CanvasText 55%,Canvas);",
    "--lilo-reader-rule:color-mix(in srgb,CanvasText 16%,Canvas);",
    "--lilo-reader-accent:LinkText;--lilo-reader-width:40rem;}",
    'html[data-lilo-theme="light"]{--lilo-reader-bg:#fdfdfb;--lilo-reader-fg:#1c1c1e;--lilo-reader-accent:#0066cc;}',
    'html[data-lilo-theme="sepia"]{--lilo-reader-bg:#f6ecd9;--lilo-reader-fg:#5b4636;--lilo-reader-accent:#9a5a2c;}',
    'html[data-lilo-theme="dark"]{--lilo-reader-bg:#1c1c1e;--lilo-reader-fg:#e6e6e6;--lilo-reader-accent:#6cb6ff;}',
    'html[data-lilo-width="narrow"]{--lilo-reader-width:32rem;}',
    'html[data-lilo-width="wide"]{--lilo-reader-width:50rem;}',
    "html.lilo-reader-active,html.lilo-reader-active body{margin:0!important;padding:0!important;",
    "background:var(--lilo-reader-bg)!important;color:var(--lilo-reader-fg)!important;}",
    "#lilo-reader{display:block;max-width:var(--lilo-reader-width);margin:0 auto;padding:4.5rem 1.5rem 8rem;",
    "font:var(--lilo-reader-font)/1.7 -apple-system,system-ui,'Segoe UI',sans-serif;color:var(--lilo-reader-fg);-webkit-font-smoothing:antialiased;}",
    "#lilo-reader .lilo-reader-head{margin:0 0 2rem;}",
    "#lilo-reader h1{font-size:1.9em;line-height:1.2;margin:0 0 .6rem;font-weight:700;}",
    "#lilo-reader .lilo-reader-meta{margin:0;color:var(--lilo-reader-muted);font-size:.82em;}",
    "#lilo-reader .lilo-reader-content>*:first-child{margin-top:0;}",
    "#lilo-reader p{margin:0 0 1.2em;}",
    "#lilo-reader a{color:var(--lilo-reader-accent);text-underline-offset:2px;}",
    "#lilo-reader img,#lilo-reader figure,#lilo-reader video,#lilo-reader svg{max-width:100%;height:auto;border-radius:6px;}",
    "#lilo-reader figure{margin:1.6em 0;}",
    "#lilo-reader figcaption{font-size:.8em;color:var(--lilo-reader-muted);text-align:center;margin-top:.5em;}",
    "#lilo-reader h2{font-size:1.4em;margin:2em 0 .6em;line-height:1.25;}",
    "#lilo-reader h3{font-size:1.15em;margin:1.6em 0 .5em;}",
    "#lilo-reader blockquote{margin:1.4em 0;padding:0 0 0 1.2em;border-left:3px solid var(--lilo-reader-rule);color:var(--lilo-reader-muted);}",
    "#lilo-reader pre{overflow-x:auto;padding:1em;border-radius:8px;background:color-mix(in srgb,var(--lilo-reader-fg) 7%,var(--lilo-reader-bg));font-size:.85em;}",
    "#lilo-reader code{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;}",
    "#lilo-reader hr{border:0;border-top:1px solid var(--lilo-reader-rule);margin:2.5em 0;}",
    "#lilo-reader ul,#lilo-reader ol{padding-left:1.4em;margin:0 0 1.2em;}",
    "#lilo-reader li{margin:.3em 0;}",
    "#lilo-reader table{border-collapse:collapse;max-width:100%;font-size:.9em;}",
    "#lilo-reader th,#lilo-reader td{border:1px solid var(--lilo-reader-rule);padding:.4em .6em;}",
    "#lilo-reader-bar{position:fixed;top:12px;right:16px;z-index:2147483647;display:flex;align-items:center;gap:2px;padding:4px;",
    "background:color-mix(in srgb,var(--lilo-reader-fg) 8%,var(--lilo-reader-bg));border:1px solid var(--lilo-reader-rule);",
    "border-radius:10px;-webkit-backdrop-filter:saturate(1.2) blur(8px);backdrop-filter:saturate(1.2) blur(8px);opacity:.35;transition:opacity .15s;",
    "font:13px -apple-system,system-ui,sans-serif;}",
    "#lilo-reader-bar:hover{opacity:1;}",
    "#lilo-reader-bar button{appearance:none;-webkit-appearance:none;border:0;background:transparent;color:var(--lilo-reader-fg);",
    "min-width:30px;height:28px;border-radius:7px;cursor:pointer;font-size:13px;}",
    "#lilo-reader-bar button:hover{background:color-mix(in srgb,var(--lilo-reader-fg) 14%,transparent);}",
    "#lilo-reader-bar .sep{width:1px;height:18px;background:var(--lilo-reader-rule);margin:0 3px;}",
    "@media print{#lilo-reader-bar{display:none;}}"
  ].join("");
  try {
    var DOCEL = document.documentElement;
    if (DOCEL.classList.contains("lilo-reader-active")) return true; // already in reader
    if (typeof Readability !== "function") return;                  // engine failed to load

    // Parse a CLONE so the live DOM is untouched until we know parsing succeeded.
    var article = new Readability(document.cloneNode(true), { charThreshold: 200 }).parse();
    if (!article || !article.content) return;                       // not an article: leave the page as-is

    var THEMES = ["auto", "light", "sepia", "dark"];
    var WIDTHS = ["narrow", "normal", "wide"];

    function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)); }
    function esc(s) { var d = document.createElement("div"); d.textContent = s == null ? "" : String(s); return d.innerHTML; }

    // Settings live in Lilo, never in the site's storage: ReaderMode.swift passes them in and keeps what changes.
    var prefs = typeof liloReaderPrefs === "object" && liloReaderPrefs || {};
    var fontSize = clamp(prefs.fontSize || 19, 14, 28);
    var theme = THEMES.indexOf(prefs.theme) >= 0 ? prefs.theme : "auto";
    var width = WIDTHS.indexOf(prefs.width) >= 0 ? prefs.width : "normal";
    function savePrefs() {
      try { webkit.messageHandlers.liloReaderPrefs.postMessage({ fontSize: fontSize, theme: theme, width: width }); } catch (e) {}
    }

    var words = (article.textContent || "").trim().split(/\s+/).filter(Boolean).length;
    var minutes = Math.max(1, Math.round(words / 200));
    var meta = [];
    if (article.siteName) meta.push(esc(article.siteName));
    if (article.byline) meta.push(esc(article.byline));
    meta.push(minutes + " min read");
    if (article.publishedTime) { var d = new Date(article.publishedTime); if (!isNaN(d.getTime())) meta.push(d.toLocaleDateString()); }

    DOCEL.classList.add("lilo-reader-active");
    DOCEL.setAttribute("data-lilo-theme", theme);
    DOCEL.setAttribute("data-lilo-width", width);
    document.body.innerHTML = "";

    var bar = document.createElement("div");
    bar.id = "lilo-reader-bar";
    bar.innerHTML =
      '<button data-act="dec" aria-label="Smaller text" title="Smaller text">A&#8722;</button>' +
      '<button data-act="inc" aria-label="Larger text" title="Larger text">A+</button>' +
      '<span class="sep"></span>' +
      '<button data-act="theme" aria-label="Theme" title="Theme">&#9680;</button>' +
      '<button data-act="width" aria-label="Width" title="Column width">&#8596;</button>';

    var root = document.createElement("article");
    root.id = "lilo-reader";
    root.dir = article.dir || "auto";
    root.innerHTML =
      '<header class="lilo-reader-head">' +
        '<h1>' + esc(article.title || document.title) + '</h1>' +
        (meta.length ? '<p class="lilo-reader-meta">' + meta.join(" &middot; ") + '</p>' : '') +
      '</header>' +
      '<div class="lilo-reader-content">' + article.content + '</div>';

    document.body.appendChild(bar);
    document.body.appendChild(root);

    var style = document.createElement("style");
    style.id = "lilo-reader-style";
    style.textContent = CSS;
    document.head.appendChild(style);

    function applyFont() { DOCEL.style.setProperty("--lilo-reader-font", fontSize + "px"); }
    applyFont();

    bar.addEventListener("click", function (e) {
      var b = e.target.closest("button");
      if (!b) return;
      switch (b.getAttribute("data-act")) {
        case "dec": fontSize = clamp(fontSize - 1, 14, 28); applyFont(); break;
        case "inc": fontSize = clamp(fontSize + 1, 14, 28); applyFont(); break;
        case "theme": theme = THEMES[(THEMES.indexOf(theme) + 1) % THEMES.length]; DOCEL.setAttribute("data-lilo-theme", theme); break;
        case "width": width = WIDTHS[(WIDTHS.indexOf(width) + 1) % WIDTHS.length]; DOCEL.setAttribute("data-lilo-width", width); break;
      }
      savePrefs();
    });

    window.scrollTo(0, 0);
    return true;
  } catch (e) {
    /* leave the page untouched on any failure */
  }
})();
