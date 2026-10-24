# Lilo : navigateur Mac natif avec espaces et extensions Chrome

> Navigateur Mac gratuit et open source, alternative à Arc : des espaces avec leurs propres connexions, les extensions Chrome et un serveur MCP pour vos agents IA.

Web page: https://getlilo.app/fr/

**Votre internet, en fleur.**

Léger pour votre Mac, rapide sur le web. Gratuit et open source. Des espaces avec leurs propres connexions, les extensions Chrome dont vous avez besoin, une place pour vos agents IA, et une batterie qui tient toute la journée.

- [Télécharger pour Mac](https://github.com/Alexays/Lilo/releases/latest/download/Lilo.dmg)
- [Une étoile sur GitHub](https://github.com/Alexays/Lilo)

```sh
brew install --cask alexays/tap/lilo
```

Vous êtes installé en cinq minutes. [Voir le guide](https://getlilo.app/fr/moving/)

Lilo est en bêta : attendez-vous à quelques imperfections, et [signalez-nous ce qui ne marche pas](https://github.com/Alexays/Lilo/issues).

## Basé sur WebKit. Pas sur un Chrome de plus.

Écrit en Swift, Lilo utilise le moteur déjà présent dans macOS. Pas de Chromium embarqué, pas d'Electron. Votre Mac consacre son énergie à vos pages.

### Le moteur de Safari

Apple optimise WebKit pour les puces Apple, le décodage vidéo et la sandbox. Lilo profite gratuitement de chaque mise à jour de macOS.

### Économe en batterie

Les onglets inactifs sont gelés, puis mis en veille. Les espaces en arrière-plan se mettent au repos quand vous ne les regardez pas.

### Léger en mémoire

La mémoire des onglets s'adapte à la RAM réelle de votre Mac, et se libère quand elle vient à manquer.

### Énergie et mémoire

**Mesures à venir**

Lilo, Safari et Chrome, avec les mêmes 20 onglets pendant 30 minutes sur le même Mac. La méthode sera publiée avec les chiffres.

## Le Chrome Web Store, avec un bouton « Ajouter à Lilo ».

Parcourez la boutique que vous connaissez et installez en un clic. Lilo exécute les extensions Manifest V3 sur WebKit, les tient à jour et donne à chaque profil les siennes.

- Gestionnaires de mots de passe
- Bloqueurs de pub
- Mode sombre
- Outils de développement
- Aide à l'écriture
- Suivi des prix

## Ce que vous faites dans Lilo reste sur votre Mac.

Pas de compte, pas de télémétrie, pas de mesure d'audience. Le projet n'a aucun serveur : votre navigation n'a nulle part où aller. Et vous pouvez vérifier chaque ligne de code.

Dans les Réglages, d'un seul interrupteur : le mode HTTPS uniquement et Global Privacy Control.

### Traqueurs bloqués d'office

Publicités, traqueurs et bannières de cookies sont filtrés grâce à des listes communautaires tenues à jour. Rien à installer.

### Des connexions bien séparées

Chaque espace peut avoir son propre profil, avec ses cookies et son stockage. Les espaces privés oublient tout à la fermeture.

### Des agents tenus en laisse

Les agents ne voient jamais vos onglets privés, et Lilo vous demande votre accord avant qu'un agent envoie, paie, supprime ou publie quoi que ce soit.

### Le moteur et la sandbox d'Apple

Les pages tournent dans les processus isolés de WebKit et reçoivent les correctifs de sécurité d'Apple à chaque mise à jour de macOS.

## Chaque chose dans son espace.

La barre latérale que vous connaissez, avec les détails qui la rendent vôtre. Importez tout depuis Safari, Chrome, Brave, Edge, Vivaldi, Opera, Arc, Dia, Comet, Chromium, Firefox ou Zen en cinq minutes, directement sur votre Mac. [Comment passer à Lilo](https://getlilo.app/fr/moving/)

### Des espaces avec leurs propres connexions

Pro et Perso côte à côte dans une même fenêtre, chacun avec ses cookies et ses extensions. Passez de l'un à l'autre d'un simple balayage.

`⌃1` `⌃2`

### Aperçu

Les liens de vos onglets épinglés s'ouvrent par-dessus la page. Poursuivez votre lecture, ouvrez l'aperçu dans un onglet ou placez-le en vue partagée.

`⇧ clic`

### Petite fenêtre

Une fenêtre rapide depuis n'importe quelle app, pour un lien ou une recherche. Envoyez-la dans un espace si elle prend de l'importance.

`⌘⌥N`

### Des onglets qui se rangent seuls

Les onglets non épinglés que vous n'utilisez plus sont archivés au bout de 12 heures, ou quand vous le décidez. Retrouvez-les d'un raccourci.

`⌘⇧K`

### Barre de commande

Onglets, historique, favoris et toutes les actions dans un seul champ, classés selon votre usage. Ouvrez un résultat en vue partagée ou en aperçu.

`⌘T` `⌥↩`

### Vos raccourcis

Chaque raccourci peut être modifié. Partez d'un préréglage : les conflits sont signalés pendant la saisie.

### Chaque lien dans le bon espace

Les liens ouverts depuis Mail ou Slack suivent vos règles : ce domaine vers Pro, le reste vers la petite fenêtre.

### Vue partagée

Jusqu'à quatre onglets côte à côte, un terminal à côté de votre doc, restaurés exactement comme vous les avez laissés.

## Votre terminal, dans la barre latérale.

Les onglets terminal côtoient votre doc et votre localhost, avec un rendu Metal natif basé sur libghostty. Placez-en un à côté d'une page : la barre latérale affiche d'un coup d'œil sa branche et ses modifications en attente.

- **Reste éveillé pendant le travail.** Une longue compilation ou un agent au travail garde votre Mac éveillé, même écran rabattu, puis le laisse se mettre en veille à la fin de la commande.
- **Vous prévient quand c'est fini.** Une commande terminée ou en attente fait briller son espace : vous naviguez pendant qu'elle tourne.
- **Relisez avant le commit.** La vue des modifications affiche tous les diffs du dépôt, images comprises.
- **Parle à vos outils.** AppleScript, Raccourcis et filtres de concentration, plus Web Serial pour les cartes comme Arduino et ESP.

## Vos agents ont leur propre espace.

Lilo intègre un serveur MCP. Claude Code, Codex, Cursor ou tout client MCP ouvrent des onglets, cliquent, tapent, lisent les pages, la console et le réseau, dans un vrai navigateur, à côté de vous.

- **Leur propre espace.** Les agents ouvrent leurs onglets dans un dossier de l'espace Agents, connectés nulle part par défaut. Votre clavier, votre souris et vos onglets restent à vous.
- **Rien sans votre accord.** Lilo vous demande avant qu'un agent envoie, paie, supprime ou publie. Chaque agent est autorisé une seule fois, et aucun ne voit jamais un espace privé.
- **Connexion en un clic.** Dans les réglages, Connecter ajoute Lilo à Claude Code, Claude Desktop, Codex ou Cursor. Tout autre client copie la configuration.
- [Fonctionnement des agents](https://github.com/Alexays/Lilo/blob/main/docs/AI-AGENTS.md)

Aucune IA dans Lilo : utilisez l'agent que vous avez déjà.

## Bon à savoir.

### Lilo est-il gratuit ?

Oui. Lilo est gratuit et open source, sous [licence MIT](https://github.com/Alexays/Lilo/blob/main/LICENSE). Pas de formule payante, pas de compte à créer.

### Sur quoi Lilo est-il basé ?

Sur WebKit, le moteur de Safari, avec une app native écrite en Swift. Aucun Chromium n'est embarqué. Par-dessus, Lilo exécute les extensions Chrome du Chrome Web Store.

### Quelles extensions fonctionnent ?

Les extensions Manifest V3 du Chrome Web Store s'installent en un clic et restent à jour. Les extensions Manifest V2 et le blocage via `webRequest` ne sont pas pris en charge, et quelques extensions dépendent d'autres fonctions propres à Chrome. Les [notes de compatibilité](https://github.com/Alexays/Lilo/blob/main/COMPATIBILITY.md) détaillent précisément les différences.

### Netflix, Spotify et les autres services de streaming fonctionnent-ils ?

Lilo lit la vidéo et la musique protégées grâce à FairPlay d'Apple, le même système que Safari : les services compatibles avec Safari, comme Netflix, Prime Video, Disney+, Apple TV+ et Spotify, devraient fonctionner comme dans Safari. YouTube est diffusé en 4K HDR. Widevine n'est pas disponible dans WebKit : un service qui l'exige est lu en qualité réduite, voire pas du tout, et les téléchargements hors ligne dans le navigateur ne sont pas pris en charge.

### Puis-je récupérer mes données d'un autre navigateur ?

Oui. Lilo importe les favoris, l'historique et les connexions de Safari, Chrome, Brave, Edge, Vivaldi, Opera, Arc, Dia, Comet, Chromium, Firefox et Zen, les onglets ouverts quand le navigateur les conserve, et propose de réinstaller vos extensions du Chrome Web Store. [Voir ce que vous emportez](https://getlilo.app/fr/moving/).

### Et mes mots de passe ?

Lilo ne conserve aucun mot de passe et ne les lit jamais dans les autres navigateurs. La configuration vous propose le gestionnaire que vous utilisez déjà, comme NordPass, Bitwarden, 1Password, Proton Pass, Dashlane ou KeePassXC. Les mots de passe iCloud arriveront dès qu'Apple aura donné son accord.

### Y a-t-il une synchronisation, ou une app mobile ?

Non, et c'est voulu : Lilo n'a ni compte ni serveur, il n'y a donc rien par où synchroniser. C'est une app pour Mac uniquement. Votre gestionnaire de mots de passe continue de synchroniser vos mots de passe partout, et l'import ne change rien à votre autre navigateur : sa synchronisation avec votre téléphone continue de fonctionner.

### Lilo intègre-t-il de l'IA ?

Non. Si vous l'activez, les agents que vous utilisez déjà, comme Claude Code, Codex ou Cursor, peuvent piloter Lilo via un serveur MCP local, dans leur propre espace. Chaque agent est autorisé une seule fois, ne voit jamais vos espaces privés, et Lilo vous demande votre accord avant qu'il envoie, paie ou supprime quoi que ce soit. [Fonctionnement des agents](https://github.com/Alexays/Lilo/blob/main/docs/AI-AGENTS.md).

### Où sont mes données ?

Sur votre Mac, séparées par profil. Pas de compte, pas de télémétrie, et le projet n'a aucun serveur : rien de ce que vous faites ne nous est envoyé. [Lire les notes de confidentialité](https://github.com/Alexays/Lilo/blob/main/PRIVACY.md).

### Pourquoi uniquement sur Mac ?

Lilo repose sur le moteur WebKit fourni avec macOS et il est écrit en Swift. C'est ce qui le rend léger et économe en batterie. Il nécessite macOS 26 ou version ultérieure.

### Comment contribuer ?

Mettez une étoile au dépôt, signalez ce qui ne marche pas, ou proposez une pull request. Toute l'interface est une couche Svelte que vous pouvez modifier et recompiler en quelques secondes.

## Open source, pour de bon.

Lisez le code, forkez-le, modifiez la barre latérale en Svelte et recompilez en quelques secondes. Votre navigateur reste le vôtre.

- [Télécharger pour Mac](https://github.com/Alexays/Lilo/releases/latest/download/Lilo.dmg)
- [Une étoile sur GitHub](https://github.com/Alexays/Lilo)

Lilo, conçu sur Mac pour le Mac. macOS 26 ou version ultérieure.

- [Passer à Lilo](https://getlilo.app/fr/moving/)
- [Confidentialité](https://github.com/Alexays/Lilo/blob/main/PRIVACY.md)
- [GitHub](https://github.com/Alexays/Lilo)
- [English](https://getlilo.app/)
