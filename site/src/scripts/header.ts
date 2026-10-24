try {
  const theme = localStorage.getItem("lilo-theme");

  if (theme === "light" || theme === "dark") {
    document.documentElement.dataset.theme = theme;
  }
} catch {
  // Storage can be unavailable in private browsing.
}

document.documentElement.dataset.themeReady = "";

document.addEventListener("click", (event) => {
  if (!(event.target instanceof Element)) {
    return;
  }

  if (event.target.closest(".theme-toggle")) {
    const root = document.documentElement;

    const dark = root.dataset.theme
      ? root.dataset.theme === "dark"
      : matchMedia("(prefers-color-scheme: dark)").matches;

    const theme = dark ? "light" : "dark";
    root.dataset.theme = theme;

    try {
      localStorage.setItem("lilo-theme", theme);
    } catch {
      // The toggle still works when the preference cannot be saved.
    }
  }

  const menu = document.querySelector<HTMLDetailsElement>(".mobile-nav");

  if (
    menu?.open &&
    (!menu.contains(event.target) || event.target.closest("a"))
  ) {
    menu.open = false;
  }
});

document.addEventListener("keydown", (event) => {
  const menu = document.querySelector<HTMLDetailsElement>(".mobile-nav");

  if (event.key === "Escape" && menu?.open) {
    menu.open = false;
    menu.querySelector<HTMLElement>("summary")?.focus();
  }
});
