(function () {
  var fr = document.documentElement.lang === "fr";
  var pages = {
    article: '<div class="article"><div class="cover"><span>' + (fr ? "Lisbonne<br>sans se presser" : "Three slow days<br>in Lisbon") + '</span></div><div class="body"><span class="meta">' + (fr ? "Carnet de voyage, 6 min de lecture" : "Travel notes, 6 min read") + '</span><p>' + (fr ? "Commencez par le fleuve avant que les trams se remplissent, montez aux belvédères en fin d'après-midi, et gardez une soirée pour les bars à fado de l'Alfama." : "Start at the river before the trams fill up, climb to the viewpoints by late afternoon, and keep one evening free for the fado bars of Alfama.") + '</p><div class="days"><div><b>' + (fr ? "Jour 1</b>Belém et le Tage" : "Day 1</b>Belem and the river") + '</div><div><b>' + (fr ? "Jour 2</b>Alfama, belvédères" : "Day 2</b>Alfama, viewpoints") + '</div><div><b>' + (fr ? "Jour 3</b>Sintra en train" : "Day 3</b>Sintra by train") + '</div></div></div></div>',
    issues: '<div class="split"><div class="issues"><h4>' + (fr ? "Boîte de réception" : "Inbox") + '</h4><div class="issue"><i class="prog"></i><span>' + (fr ? "Le paiement échoue avec une carte enregistrée" : "Checkout fails on saved cards") + '</span><small>WEB-482</small></div><div class="issue"><i></i><span>' + (fr ? "Textes de l'étape d'import" : "Onboarding copy for the import step") + '</span><small>WEB-479</small></div><div class="issue"><i class="done"></i><span>' + (fr ? "Mode sombre de la page Tarifs" : "Pricing page dark mode") + '</span><small>WEB-471</small></div><div class="issue"><i></i><span>' + (fr ? "Test de connexion instable en CI" : "Flaky login test on CI") + '</span><small>WEB-468</small></div><div class="issue"><i class="done"></i><span>' + (fr ? "Publier les nouveautés du T4" : "Ship the Q4 changelog") + '</span><small>WEB-460</small></div></div><div class="term"><div><b>~/shop</b> claude</div><div class="dim">' + (fr ? "connecté à Lilo" : "connected to Lilo") + '</div><div class="ag">navigate localhost:3000/checkout</div><div class="ag">click "' + (fr ? "Payer" : "Pay now") + '"</div><div class="ok">' + (fr ? "bug reproduit, console : 1 erreur" : "bug reproduced, console: 1 error") + '</div><div class="ag">screenshot</div><div class="ok">' + (fr ? "correctif prêt dans src/cart.ts" : "fix ready in src/cart.ts") + '</div></div></div>',
    player: '<div class="player"><div class="art"></div><div class="now"><small>' + (fr ? "En écoute" : "Now playing") + '</small><b>' + (fr ? "Mix de fin de soirée" : "Late night mix") + '</b><span style="font-size:13px;color:#6b6b80">' + (fr ? "42 titres" : "42 tracks") + ', 2 h 51 min</span><div class="prog"><i></i></div><div class="ctrl"><span>&#9198;</span><span class="pp">&#10073;&#10073;</span><span>&#9197;</span></div><ol><li>Night drive</li><li>Soft focus</li><li>After hours</li></ol></div></div>'
  };
  var spaces = [
    { icon: "🏠", name: "Perso", color: "#c3a5ea", addr: ["slowtravel.blog", fr ? "/lisbonne" : "/lisbon"], page: "article",
      favs: [["&#9993;", "#5b8def"], ["31", "#e5534b"], ["&#9673;", "#f4a93b"], ["&#8982;", "#34a853"]],
      folders: fr ? [["Maison"], ["Travaux"], ["Voyages", true]] : [["Home"], ["Renovation"], ["Trips", true]],
      tabs: [[fr ? "Lisbonne sans se presser" : "Three slow days in Lisbon", "#f4bb8c", "&#10022;", "on"], [fr ? "Recettes enregistrées" : "Recipes, saved", "#9bd3b4", "&#9752;"], [fr ? "Travaux de l'appartement" : "Flat renovation", "#92a8ff", "&#8962;"], ["~/Projects/lilo", "#1a1a2e", "$"]] },
    { icon: "💼", name: fr ? "Pro" : "Work", color: "#92a8ff", addr: ["tracker.team", "/web/inbox"], page: "issues",
      favs: [["&#9993;", "#5b8def"], ["&#9719;", "#6a4be0"], ["&#9636;", "#2f9e8f"], ["&#9998;", "#e0825f"]],
      folders: fr ? [["Lancement T4"], ["Recrutement"], ["Revues design"]] : [["Q4 launch"], ["Hiring"], ["Design reviews"]],
      tabs: [[fr ? "Réception, tracker" : "Inbox, tracker", "#6a4be0", "&#9719;", "on"], [fr ? "Revue de la PR #482" : "PR #482 review", "#24292f", "&#10070;"], [fr ? "Test du paiement" : "Checkout test", "#d97757", "A", "agent"], ["~/shop", "#1a1a2e", "$"]] },
    { icon: "🎧", name: fr ? "Musique" : "Music", color: "#f0a8c8", addr: ["radio.fm", "/late-night"], page: "player",
      favs: [["&#9835;", "#e5534b"], ["&#9834;", "#34a853"], ["&#9673;", "#629aa9"], ["&#9733;", "#a238ff"]],
      folders: fr ? [["Setlists"], ["Matériel"]] : [["Setlists"], ["Gear"]],
      tabs: [[fr ? "Mix de fin de soirée" : "Late night mix", "#b39df4", "&#9835;", "on"], [fr ? "Billets de concert" : "Concert tickets", "#026cdf", "&#9733;"], [fr ? "Manuels de synthé" : "Synth manuals", "#555", "&#9783;"]] }
  ];
  var root = document.documentElement;
  var bar = document.getElementById("spacebar");
  var plus = bar.querySelector(".plus");
  var buttons = spaces.map(function (s, i) {
    var b = document.createElement("button");
    b.type = "button"; b.setAttribute("aria-label", fr ? "Space " + s.name : s.name + " space"); b.textContent = s.icon;
    b.addEventListener("click", function () { show(i); stop(); });
    bar.insertBefore(b, plus);
    return b;
  });
  function esc(t) { return t.replace(/[&<>"]/g, function (c) { return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]; }); }
  function slideIn(from, to) {
    if (from === to || !document.body.animate) return;
    if (window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
    var forward = (to - from + spaces.length) % spaces.length === 1;
    var dx = forward ? 36 : -36;
    ["sname", "favs", "folders", "tabs", "view"].forEach(function (id, n) {
      document.getElementById(id).animate(
        [{ opacity: 0, transform: "translateX(" + dx + "px)" }, { opacity: 1, transform: "none" }],
        { duration: 420, delay: n * 35, easing: "cubic-bezier(0.22, 1, 0.36, 1)", fill: "backwards" }
      );
    });
  }
  function show(i) {
    var s = spaces[i];
    root.style.setProperty("--tint", s.color);
    document.getElementById("addr").innerHTML = "<span><b>" + esc(s.addr[0]) + "</b>" + esc(s.addr[1]) + "</span>";
    document.getElementById("sname").innerHTML = s.icon + " " + esc(s.name) + "<em>&#9788;</em>";
    document.getElementById("favs").innerHTML = s.favs.map(function (f) { return '<span><i style="background:' + f[1] + '">' + f[0] + "</i></span>"; }).join("");
    document.getElementById("folders").innerHTML = s.folders.map(function (f) {
      return '<div class="row-item"><span class="fi"></span><span class="tt">' + esc(f[0]) + "</span>" + (f[1] ? '<span class="lock">&#128274;</span>' : "") + "</div>";
    }).join("");
    document.getElementById("tabs").innerHTML = s.tabs.map(function (t) {
      var extra = t[3] === "on" ? '<span class="x">&#10005;</span>' : t[3] === "agent" ? '<span class="who">agent</span>' : "";
      return '<div class="row-item ' + (t[3] || "") + '"><span class="fav" style="background:' + t[1] + '">' + t[2] + '</span><span class="tt">' + esc(t[0]) + "</span>" + extra + "</div>";
    }).join("");
    document.getElementById("view").innerHTML = pages[s.page];
    buttons.forEach(function (b, j) { b.setAttribute("aria-pressed", j === i ? "true" : "false"); });
    slideIn(current, i);
    current = i;
  }
  var current = 0, timer = null;
  show(0);
  var reduce = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  if (!reduce) timer = setInterval(function () { show((current + 1) % spaces.length); }, 3200);
  function stop() { if (timer) { clearInterval(timer); timer = null; } }

  var toast = document.getElementById("toast");
  document.querySelectorAll(".add").forEach(function (b) {
    b.addEventListener("click", function () {
      b.textContent = fr ? "Ajoutée à Lilo" : "Added to Lilo"; b.classList.add("done");
      toast.textContent = b.parentElement.querySelector("b").textContent + (fr ? " est installée dans votre profil Perso." : " installed in your Perso profile.");
    });
  });
})();
