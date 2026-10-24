interface Space {
  icon: string;
  name: string;
  color: string;
  addr: [host: string, path: string];
  page: keyof typeof pages;
  favs: [icon: string, color: string][];
  folders: [name: string, locked?: boolean][];
  tabs: [name: string, color: string, icon: string, state?: "on" | "agent"][];
}

const fr = document.documentElement.lang === "fr";

const pages = {
  article: `<div class="article"><div class="cover"><span>${fr ? "Lisbonne<br>sans se presser" : "Three slow days<br>in Lisbon"}</span></div><div class="body"><span class="meta">${fr ? "Carnet de voyage, 6 min de lecture" : "Travel notes, 6 min read"}</span><p>${fr ? "Commencez par le fleuve avant que les trams se remplissent, montez aux belvédères en fin d'après-midi, et gardez une soirée pour les bars à fado de l'Alfama." : "Start at the river before the trams fill up, climb to the viewpoints by late afternoon, and keep one evening free for the fado bars of Alfama."}</p><div class="days"><div><b>${fr ? "Jour 1</b>Belém et le Tage" : "Day 1</b>Belem and the river"}</div><div><b>${fr ? "Jour 2</b>Alfama, belvédères" : "Day 2</b>Alfama, viewpoints"}</div><div><b>${fr ? "Jour 3</b>Sintra en train" : "Day 3</b>Sintra by train"}</div></div></div></div>`,
  issues: `<div class="split"><div class="issues"><b class="ttl">${fr ? "Boîte de réception" : "Inbox"}</b><div class="issue"><i class="prog"></i><span>${fr ? "Le paiement échoue avec une carte enregistrée" : "Checkout fails on saved cards"}</span><small>WEB-482</small></div><div class="issue"><i></i><span>${fr ? "Textes de l'étape d'import" : "Onboarding copy for the import step"}</span><small>WEB-479</small></div><div class="issue"><i class="done"></i><span>${fr ? "Mode sombre de la page Tarifs" : "Pricing page dark mode"}</span><small>WEB-471</small></div><div class="issue"><i></i><span>${fr ? "Test de connexion instable en CI" : "Flaky login test on CI"}</span><small>WEB-468</small></div><div class="issue"><i class="done"></i><span>${fr ? "Publier les nouveautés du T4" : "Ship the Q4 changelog"}</span><small>WEB-460</small></div></div><div class="term"><div><b>~/shop</b> claude</div><div class="dim">${fr ? "connecté à Lilo" : "connected to Lilo"}</div><div class="ag">navigate localhost:3000/checkout</div><div class="ag">click "${fr ? "Payer" : "Pay now"}"</div><div class="ok">${fr ? "bug reproduit, console : 1 erreur" : "bug reproduced, console: 1 error"}</div><div class="ag">screenshot</div><div class="ok">${fr ? "correctif prêt dans src/cart.ts" : "fix ready in src/cart.ts"}</div></div></div>`,
  player: `<div class="player"><div class="art"></div><div class="now"><small>${fr ? "En écoute" : "Now playing"}</small><b>${fr ? "Mix de fin de soirée" : "Late night mix"}</b><span style="font-size:13px;color:#6b6b80">${fr ? "42 titres" : "42 tracks"}, 2 h 51 min</span><div class="prog"><i></i></div><div class="ctrl"><span>&#9198;</span><span class="pp">&#10073;&#10073;</span><span>&#9197;</span></div><ol><li>Night drive</li><li>Soft focus</li><li>After hours</li></ol></div></div>`,
};

const spaces = [
  {
    addr: ["slowtravel.blog", fr ? "/lisbonne" : "/lisbon"],
    color: "#c3a5ea",
    favs: [
      ["&#9993;", "#5b8def"],
      ["31", "#e5534b"],
      ["&#9673;", "#f4a93b"],
      ["&#8982;", "#34a853"],
    ],
    folders: fr
      ? [["Maison"], ["Travaux"], ["Voyages", true]]
      : [["Home"], ["Renovation"], ["Trips", true]],
    icon: "🏠",
    name: "Perso",
    page: "article",
    tabs: [
      [
        fr ? "Lisbonne sans se presser" : "Three slow days in Lisbon",
        "#f4bb8c",
        "&#10022;",
        "on",
      ],
      [fr ? "Recettes enregistrées" : "Recipes, saved", "#9bd3b4", "&#9752;"],
      [
        fr ? "Travaux de l'appartement" : "Flat renovation",
        "#92a8ff",
        "&#8962;",
      ],
      ["~/Projects/lilo", "#1a1a2e", "$"],
    ],
  },
  {
    addr: ["tracker.team", "/web/inbox"],
    color: "#92a8ff",
    favs: [
      ["&#9993;", "#5b8def"],
      ["&#9719;", "#6a4be0"],
      ["&#9636;", "#2f9e8f"],
      ["&#9998;", "#e0825f"],
    ],
    folders: fr
      ? [["Lancement T4"], ["Recrutement"], ["Revues design"]]
      : [["Q4 launch"], ["Hiring"], ["Design reviews"]],
    icon: "💼",
    name: fr ? "Pro" : "Work",
    page: "issues",
    tabs: [
      [
        fr ? "Réception, tracker" : "Inbox, tracker",
        "#6a4be0",
        "&#9719;",
        "on",
      ],
      [fr ? "Revue de la PR #482" : "PR #482 review", "#24292f", "&#10070;"],
      [fr ? "Test du paiement" : "Checkout test", "#d97757", "A", "agent"],
      ["~/shop", "#1a1a2e", "$"],
    ],
  },
  {
    addr: ["radio.fm", "/late-night"],
    color: "#f0a8c8",
    favs: [
      ["&#9835;", "#e5534b"],
      ["&#9834;", "#34a853"],
      ["&#9673;", "#629aa9"],
      ["&#9733;", "#a238ff"],
    ],
    folders: fr ? [["Setlists"], ["Matériel"]] : [["Setlists"], ["Gear"]],
    icon: "🎧",
    name: fr ? "Musique" : "Music",
    page: "player",
    tabs: [
      [
        fr ? "Mix de fin de soirée" : "Late night mix",
        "#b39df4",
        "&#9835;",
        "on",
      ],
      [fr ? "Billets de concert" : "Concert tickets", "#026cdf", "&#9733;"],
      [fr ? "Manuels de synthé" : "Synth manuals", "#555", "&#9783;"],
    ],
  },
] satisfies Space[];

const element = (id: string): HTMLElement => {
  const node = document.querySelector<HTMLElement>(`#${id}`);

  if (!node) {
    throw new Error(`Missing demo element: ${id}`);
  }

  return node;
};

const root = document.documentElement;
const plus = document.querySelector("#spacebar .plus");

if (!plus) {
  throw new Error("Missing demo Space button");
}

const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");

let current = 0;

const escapeHTML = (text: string): string =>
  text
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");

const slideIn = (from: number, to: number) => {
  if (from === to || reducedMotion.matches) {
    return;
  }

  const forward = (to - from + spaces.length) % spaces.length === 1;
  const dx = forward ? 36 : -36;

  for (const [index, id] of [
    "sname",
    "favs",
    "folders",
    "tabs",
    "view",
  ].entries()) {
    element(id).animate(
      [
        { opacity: 0, transform: `translateX(${dx}px)` },
        { opacity: 1, transform: "none" },
      ],
      {
        delay: index * 35,
        duration: 420,
        easing: "cubic-bezier(0.22, 1, 0.36, 1)",
        fill: "backwards",
      }
    );
  }
};

const buttons = spaces.map((space) => {
  const button = document.createElement("button");
  button.type = "button";
  button.setAttribute(
    "aria-label",
    fr ? `Espace ${space.name}` : `${space.name} space`
  );
  button.textContent = space.icon;
  plus.before(button);

  return button;
});

const show = (index: number) => {
  const space = spaces[index];
  root.style.setProperty("--tint", space.color);
  element("addr").innerHTML =
    `<span><b>${escapeHTML(space.addr[0])}</b>${escapeHTML(space.addr[1])}</span>`;
  element("sname").innerHTML =
    `${space.icon} ${escapeHTML(space.name)}<em>&#9788;</em>`;
  element("favs").innerHTML = space.favs
    .map(
      ([icon, color]) =>
        `<span><i style="background:${color}">${icon}</i></span>`
    )
    .join("");
  element("folders").innerHTML = space.folders
    .map(
      ([name, locked]) =>
        `<div class="row-item"><span class="fi"></span><span class="tt">${escapeHTML(name)}</span>${locked ? '<span class="lock">&#128274;</span>' : ""}</div>`
    )
    .join("");
  element("tabs").innerHTML = space.tabs
    .map(([name, color, icon, state]) => {
      let extra = "";

      if (state === "on") {
        extra = '<span class="x">&#10005;</span>';
      } else if (state === "agent") {
        extra = '<span class="who">agent</span>';
      }

      return `<div class="row-item ${state ?? ""}"><span class="fav" style="background:${color}">${icon}</span><span class="tt">${escapeHTML(name)}</span>${extra}</div>`;
    })
    .join("");
  element("view").innerHTML = pages[space.page];

  for (const [buttonIndex, button] of buttons.entries()) {
    button.setAttribute("aria-pressed", String(buttonIndex === index));
  }

  slideIn(current, index);
  current = index;
};

for (const [index, button] of buttons.entries()) {
  button.addEventListener("click", () => {
    show(index);
  });
}

show(0);

const toast = element("toast");

for (const button of document.querySelectorAll<HTMLButtonElement>(".add")) {
  button.addEventListener("click", () => {
    button.textContent = fr ? "Ajoutée à Lilo" : "Added to Lilo";
    button.classList.add("done");
    const name = button.parentElement?.querySelector("b")?.textContent;
    toast.textContent = `${name}${fr ? " est installée dans votre profil Perso." : " installed in your Perso profile."}`;
  });
}
