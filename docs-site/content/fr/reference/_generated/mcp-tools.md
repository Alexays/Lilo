## Onglets et pages [#tabs-and-pages]

### `tabs_context_mcp` [#tabs_context_mcp]

Liste les onglets du dossier de l'agent (son groupe d'onglets), et peut créer le dossier avec un onglet vide lorsqu'il n'existe pas encore.

| Paramètre | Type | Requis | Description |
| --- | --- | --- | --- |
| `createIfEmpty` | `boolean` | non | Crée votre groupe d'onglets avec un onglet vide s'il n'en existe aucun. |
| `title` | `string` | non | Ce sur quoi vous travaillez, en 2 à 4 mots (« Parcours d'inscription », « Bug d'export CSV ») : le nom de votre groupe que voit l'utilisateur, et le groupe qui est listé. |

### `tabs_create_mcp` [#tabs_create_mcp]

Ouvre un nouvel onglet vide dans le dossier de l'agent, en arrière-plan, éventuellement dans un espace privé propre à l'agent qui ne partage ni cookies ni connexions avec ses autres onglets.

| Paramètre | Type | Requis | Description |
| --- | --- | --- | --- |
| `title` | `string` | non | Ce sur quoi vous travaillez, en 2 à 4 mots : le nom de votre groupe que voit l'utilisateur, et le groupe dans lequel va l'onglet. |
| `isolated` | `boolean` | non | True pour un onglet dans votre propre espace privé : il ne partage ni cookie, ni stockage, ni connexion avec vos autres onglets, comme un nouveau visiteur ou un second utilisateur. Vos onglets isolés partagent un même ensemble de cookies, qui disparaît lorsque vous vous déconnectez. |

### `tabs_close_mcp` [#tabs_close_mcp]

Ferme l'un des onglets de l'agent.

| Paramètre | Type | Requis | Description |
| --- | --- | --- | --- |
| `tabId` | `number` | oui | L'onglet à fermer. |

### `navigate` [#navigate]

Charge une URL dans un onglet, ou revient en arrière, avance ou recharge, puis attend les redirections et la stabilisation de la page avant de donner son URL et son titre définitifs.

| Paramètre | Type | Requis | Description |
| --- | --- | --- | --- |
| `url` | `string` | oui | L'URL à charger (le schéma par défaut est https://), ou « back », « forward » ou « reload ». |
| `tabId` | `number` | oui | L'onglet dans lequel naviguer. |

### `read_page` [#read_page]

Renvoie l'arbre d'accessibilité de la page, chaque élément avec une ref que les autres outils acceptent, éventuellement limité aux éléments interactifs ou à un seul sous-arbre.

| Paramètre | Type | Requis | Description |
| --- | --- | --- | --- |
| `tabId` | `number` | oui | L'onglet à lire. |
| `filter` | `string` : `interactive`, `all` | non | « all » (par défaut) ou « interactive ». |
| `ref_id` | `string` | non | Lire uniquement le sous-arbre de cet élément. |
| `depth` | `number` | non | Profondeur maximale de l'arbre (15 par défaut). |
| `max_chars` | `number` | non | Nombre maximal de caractères en sortie (50000 par défaut). |

### `find` [#find]

Trouve jusqu'à 20 éléments affichés dont le rôle, le nom ou le texte contient une requête, sans tenir compte de la casse.

| Paramètre | Type | Requis | Description |
| --- | --- | --- | --- |
| `query` | `string` | oui | Texte à rechercher. |
| `tabId` | `number` | oui | L'onglet dans lequel chercher. |

### `wait_for` [#wait_for]

Attend qu'un texte, un élément ou un rôle s'affiche ou disparaisse, qu'un contrôle devienne actif, ou que l'onglet atteigne une URL, pendant 50 secondes au maximum.

| Paramètre | Type | Requis | Description |
| --- | --- | --- | --- |
| `text` | `string` | non | Texte qui doit s'afficher, sans tenir compte de la casse. |
| `selector` | `string` | non | Un sélecteur CSS, à la place du texte. |
| `role` | `string` | non | Le rôle d'un élément tel que read\_page le donne (button, link, textbox, heading...), à la place du texte. |
| `name` | `string` | non | Avec role : une partie du nom de l'élément tel que read\_page le donne, sans tenir compte de la casse. |
| `url` | `string` | non | Une partie de l'URL de l'onglet, ou, avec \* pour toute suite de caractères, un motif pour l'URL entière (\*/orders/\*), en tenant compte de la casse. N'accepte pas de state. |
| `state` | `string` : `visible`, `hidden`, `enabled` | non | visible (par défaut) : jusqu'à ce qu'il s'affiche ; hidden : jusqu'à ce qu'il ait disparu ; enabled : jusqu'à ce que l'élément du sélecteur ou du rôle s'affiche, non désactivé. |
| `timeout` | `number` | non | Secondes, 10 par défaut, jusqu'à 50. |
| `tabId` | `number` | oui | L'onglet. |

### `get_page_text` [#get_page_text]

Extrait le texte visible de la page, en commençant par son article ou son contenu principal.

| Paramètre | Type | Requis | Description |
| --- | --- | --- | --- |
| `tabId` | `number` | oui | L'onglet à lire. |
| `max_chars` | `number` | non | Nombre maximal de caractères en sortie (50000 par défaut). |

### `form_input` [#form_input]

Définit la valeur d'un champ de saisie, d'une zone de texte, d'une liste de sélection, d'une case à cocher ou d'un élément modifiable à partir de sa ref, et indique ce que l'élément contient ensuite.

| Paramètre | Type | Requis | Description |
| --- | --- | --- | --- |
| `ref` | `string` | oui | La ref de l'élément, issue de read\_page ou de find. |
| `value` | `string` ou `boolean` ou `number` | oui | La valeur ; un booléen pour une case à cocher. |
| `tabId` | `number` | oui | L'onglet. |

### `javascript_tool` [#javascript_tool]

Exécute du JavaScript dans la page et renvoie la valeur de sa dernière expression ; l'await de premier niveau fonctionne.

| Paramètre | Type | Requis | Description |
| --- | --- | --- | --- |
| `action` | `string` : `javascript_exec` | oui | Toujours « javascript\_exec ». |
| `text` | `string` | oui | Le code JavaScript à exécuter. |
| `timeout` | `number` | non | Secondes avant l'arrêt de l'appel, 55 par défaut, jusqu'à 600 : pour un fetch ou une attente de longue durée. Au-delà de 60 s, votre client MCP peut cesser d'attendre le premier, sauf s'il accepte les notifications de progression. |
| `tabId` | `number` | oui | L'onglet. |

### `fetch` [#fetch]

Envoie une requête HTTP depuis un onglet comme le ferait sa page, avec son origine et ses cookies ; une requête autre que GET ou HEAD dans l'un de vos profils attend votre approbation.

| Paramètre | Type | Requis | Description |
| --- | --- | --- | --- |
| `url` | `string` | oui | L'URL à requêter. |
| `method` | `string` | non | GET par défaut. |
| `headers` | `object` | non | En-têtes de la requête, par nom. Le navigateur définit lui-même Cookie. |
| `body` | `string` ou `object` ou `array` | non | Le corps de la requête : une chaîne, ou du JSON pour un objet. |
| `credentials` | `string` : `same-origin`, `include`, `omit` | non | Quelles requêtes transportent des cookies, comme l'option de fetch : same-origin par défaut, include pour une API d'une autre origine qui les autorise. |
| `responseType` | `string` : `text`, `json`, `base64` | non | La forme sous laquelle le corps revient : text (par défaut), json analysé, ou base64 pour du binaire. |
| `maxBytes` | `number` | non | Nombre maximal d'octets du corps lus, 1048576 (1 Mo) par défaut, jusqu'à 10485760. |
| `tabId` | `number` | oui | L'onglet dont la page envoie la requête. |

## Interaction [#interaction]

### `computer` [#computer]

Clique, saisit du texte, appuie sur des touches, fait défiler, fait glisser et survole dans un onglet, prend des captures d'écran, et capture une zone avec tous ses détails ; un clic ou la touche Entrée sur un contrôle dont le libellé contient un mot tel que envoyer, payer, commander, supprimer ou publier attend votre approbation.

| Paramètre | Type | Requis | Description |
| --- | --- | --- | --- |
| `action` | `string` : `left_click`, `right_click`, `double_click`, `triple_click`, `type`, `insert_text`, `key`, `screenshot`, `wait`, `scroll`, `left_click_drag`, `zoom`, `scroll_to`, `hover` | oui |  |
| `coordinate` | `array` de `number` | non | (x, y) pour les clics, le défilement, le survol et la fin d'un glissement. |
| `ref` | `string` | non | Une ref d'élément issue de read\_page ou de find, à la place de coordinate ; pour screenshot, l'élément à capturer. |
| `selector` | `string` | non | screenshot : un sélecteur CSS de l'élément à capturer, à la place de ref. |
| `margin` | `number` | non | screenshot d'un élément : pixels CSS conservés autour de lui, 0 par défaut. |
| `fullPage` | `boolean` | non | screenshot : la page entière, contenu différé chargé, sans redimensionner la zone d'affichage. |
| `fullResolution` | `boolean` | non | screenshot : au rapport de pixels de l'appareil de la page au lieu d'un pixel par point. |
| `savePath` | `string` | non | screenshot : un chemin .png absolu où l'écrire, les dossiers étant créés ; la réponse donne le chemin, pas l'image. |
| `text` | `string` | non | Le texte à saisir ou à insérer, ou pour key les touches : séparées par des espaces, les modificateurs étant reliés par + (cmd+a, Return). |
| `modifiers` | `string` | non | Touches de modification maintenues pendant un clic, reliées par + (cmd, shift, alt, ctrl). |
| `scroll_direction` | `string` : `up`, `down`, `left`, `right` | non |  |
| `scroll_amount` | `number` | non | Crans de molette, 3 par défaut. |
| `start_coordinate` | `array` de `number` | non | (x, y) où commence un glissement. |
| `region` | `array` de `number` | non | (x0, y0, x1, y1) sur lesquels zoomer. |
| `duration` | `number` | non | Secondes d'attente, 10 au maximum. |
| `repeat` | `number` | non | Combien de fois appuyer sur les touches d'une action key. |
| `tabId` | `number` | oui | L'onglet. |

### `resize_window` [#resize_window]

Définit la taille de la zone d'affichage d'un onglet pour tester une mise en page à une autre largeur, sans redimensionner la fenêtre de Lilo.

| Paramètre | Type | Requis | Description |
| --- | --- | --- | --- |
| `width` | `number` | oui | Largeur en pixels. |
| `height` | `number` | oui | Hauteur en pixels. |
| `tabId` | `number` | oui | L'onglet. |

### `read_console_messages` [#read_console_messages]

Renvoie la sortie de la console de la page actuelle de l'onglet, éventuellement uniquement les erreurs ou les messages contenant un texte.

| Paramètre | Type | Requis | Description |
| --- | --- | --- | --- |
| `tabId` | `number` | oui | L'onglet. |
| `onlyErrors` | `boolean` | non | Uniquement les erreurs. |
| `pattern` | `string` | non | Uniquement les messages contenant ce texte. |
| `limit` | `number` | non | Nombre de messages les plus récents à renvoyer, 50 par défaut, 200 au maximum. |

### `read_network_requests` [#read_network_requests]

Liste les requêtes réseau de l'onglet avec leur méthode, leur statut, leur URL, leur type, leur taille et leur durée ; une fois qu'un outil de développement a été exécuté sur l'onglet, une requête peut être lue en entier, corps compris.

| Paramètre | Type | Requis | Description |
| --- | --- | --- | --- |
| `tabId` | `number` | oui | L'onglet. |
| `urlPattern` | `string` | non | Uniquement les requêtes dont l'URL contient ce texte, tel quel : pas une expression régulière, contrairement à celui de network\_mock. |
| `exclude` | `array` de `string` | non | Écarter les requêtes dont l'URL contient l'un de ces textes, comme \["/node\_modules/", "/@vite/", "/src/"\] pour les modules d'un serveur de développement. |
| `requestId` | `string` | non | Une requête en entier, son id sous forme de chaîne : « 0.16620 ». |
| `limit` | `number` | non | Nombre de requêtes les plus récentes à renvoyer, 50 par défaut. |

### `file_upload` [#file_upload]

Choisit des fichiers pour un champ de fichier sans afficher de panneau de sélection de fichiers, une fois que vous avez autorisé chaque fichier.

| Paramètre | Type | Requis | Description |
| --- | --- | --- | --- |
| `paths` | `array` de `string` | oui | Chemins absolus des fichiers. |
| `ref` | `string` | oui | La ref du champ de fichier. |
| `tabId` | `number` | oui | L'onglet. |

### `upload_image` [#upload_image]

Dépose une image sur un élément ou la définit sur un champ de fichier, à partir d'une capture d'écran prise par l'agent ou d'un fichier que vous autorisez.

| Paramètre | Type | Requis | Description |
| --- | --- | --- | --- |
| `imageId` | `string` | non | L'id d'une capture d'écran prise avec computer. |
| `path` | `string` | non | Un chemin absolu vers un fichier image, que l'utilisateur autorise d'abord. |
| `ref` | `string` | non | La ref de l'élément cible. |
| `coordinate` | `array` de `number` | non | (x, y) de la cible à la place de ref. |
| `filename` | `string` | non | Le nom de fichier que voit la page. |
| `tabId` | `number` | oui | L'onglet. |

### `gif_creator` [#gif_creator]

Enregistre les actions effectuées dans un onglet et les exporte sous forme de GIF animé dans le dossier Téléchargements.

| Paramètre | Type | Requis | Description |
| --- | --- | --- | --- |
| `action` | `string` : `start_recording`, `stop_recording`, `export`, `clear` | oui |  |
| `filename` | `string` | non | Nom de fichier pour export. |
| `tabId` | `number` | oui | L'onglet. |

### `browser_batch` [#browser_batch]

Exécute plusieurs appels d'outils dans l'ordre en un seul aller-retour, en s'arrêtant à la première erreur.

| Paramètre | Type | Requis | Description |
| --- | --- | --- | --- |
| `actions` | `array` de `object` | oui | Chaque élément est \{name, input\} : un nom d'outil et ses arguments. |
| `actions[].name` | `string` | oui |  |
| `actions[].input` | `object` | oui |  |

### `run` [#run]

Exécute un programme JavaScript qui appelle lui-même les autres outils, pour des boucles et des branchements sur de nombreuses étapes en un seul aller-retour, avec 200 appels d'outils au maximum.

| Paramètre | Type | Requis | Description |
| --- | --- | --- | --- |
| `code` | `string` | oui | Le corps d'une fonction asynchrone : await et return fonctionnent. Par exemple : for (const u of urls) \{ await tool('navigate', \{tabId: 1, url: u\}); out.push(await tool('get\_page\_text', \{tabId: 1\})) \} return out |
| `timeout` | `number` | non | Secondes avant l'arrêt de l'exécution, 55 par défaut, jusqu'à 600. Au-delà de 60 s, votre client MCP peut cesser d'attendre le premier, sauf s'il accepte les notifications de progression. |

### `list_profiles` [#list_profiles]

Liste les profils de Lilo, en signalant celui qu'utilisent les onglets de l'agent (le profil Agents par défaut) et celui dans lequel vous travaillez.

Aucun paramètre.

### `switch_profile` [#switch_profile]

Déplace les onglets de l'agent vers un autre profil afin qu'il puisse agir avec les connexions de ce profil, une fois que vous avez autorisé ce profil.

| Paramètre | Type | Requis | Description |
| --- | --- | --- | --- |
| `profile` | `string` | oui | Le nom ou l'id du profil, issu de list\_profiles. |

### `reset_profile` [#reset_profile]

Efface les cookies, le stockage, le cache et l'historique du profil Agents et recharge les onglets de l'agent ; il ne touche jamais à vos propres profils.

| Paramètre | Type | Requis | Description |
| --- | --- | --- | --- |
| `wait` | `number` | non | Secondes d'attente pour que les autres agents ferment leurs onglets, jusqu'à 600 (0 par défaut). |

## Outils de développement [#developer-tools]

### `devtools_command` [#devtools_command]

Envoie une commande du protocole de l'inspecteur web de WebKit à un onglet et renvoie son résultat, ou liste toutes les commandes que ce WebKit prend en charge.

| Paramètre | Type | Requis | Description |
| --- | --- | --- | --- |
| `method` | `string` | non | Domain.command, par exemple Runtime.evaluate ou DOM.getDocument. |
| `params` | `object` | non | Les paramètres de la commande. |
| `tabId` | `number` | oui | L'onglet. |

### `devtools_events` [#devtools_events]

Lit les événements du protocole de l'inspecteur web d'un onglet, issus des domaines auxquels l'agent a envoyé des commandes.

| Paramètre | Type | Requis | Description |
| --- | --- | --- | --- |
| `prefix` | `string` | non | Uniquement les événements dont le nom commence par ceci, comme Network. ou Console.messageAdded. |
| `limit` | `number` | non | Nombre d'événements les plus récents à renvoyer, 50 par défaut. |
| `clear` | `boolean` | non | Vider le tampon après la lecture. |
| `tabId` | `number` | oui | L'onglet. |

### `network_mock` [#network_mock]

Intercepte les requêtes d'un onglet dont l'URL correspond à une expression régulière pour les simuler, les faire échouer, les réécrire ou les retarder.

| Paramètre | Type | Requis | Description |
| --- | --- | --- | --- |
| `action` | `string` : `add`, `remove`, `list`, `clear` | oui |  |
| `id` | `number` | non | La règle à supprimer. |
| `urlPattern` | `string` | non | Une expression régulière JavaScript testée sur l'URL complète. |
| `methods` | `array` de `string` | non | Uniquement les requêtes utilisant ces méthodes HTTP, comme \["POST"\]. |
| `bodyPattern` | `string` | non | Uniquement les requêtes dont le corps, en tant que texte, correspond à cette expression régulière JavaScript. |
| `bodyJson` | `object` | non | Uniquement les requêtes dont le corps JSON comporte tous ces champs de premier niveau. Une chaîne est une expression régulière appliquée à la valeur du champ : \{operationName: "\^GetUser$"\} pour une seule opération GraphQL, \{query: "\^\\s\*mutation\\b"\} pour toutes les mutations. Les autres valeurs doivent être égales. Un lot (un tableau JSON) correspond lorsque l'un de ses éléments correspond. |
| `stage` | `string` : `request`, `response` | non | request (par défaut) : avant son envoi. response : remplacer la réponse réelle. |
| `response` | `object` | non | La simulation : status (200), statusText, headers, mimeType (text/plain, ou celui du fichier), et l'un de body (texte), bodyBase64 ou path : un chemin local absolu, lu à chaque requête. $1 et les suivants dans path reprennent les groupes de urlPattern, pour servir un dossier : /assets/(\[\^?\]\*) avec /abs/dist/assets/$1. Un fichier manquant répond 404. L'utilisateur autorise d'abord le fichier, ou le dossier. |
| `error` | `string` : `General`, `AccessControl`, `Cancellation`, `Timeout` | non | Faire échouer la requête à la place. |
| `modify` | `object` | non | Envoyer la requête modifiée à la place : url, method, headers, postData. |
| `delayMs` | `number` | non | Attendre cette durée avant d'appliquer le résultat. |
| `tabId` | `number` | oui | L'onglet. |

### `network_response` [#network_response]

Renvoie les requêtes d'un onglet en entier, avec en-têtes, corps, chronométrages et tailles, ou les enregistre dans un fichier HAR.

| Paramètre | Type | Requis | Description |
| --- | --- | --- | --- |
| `url` | `string` | non | L'URL, ou une partie de celle-ci ; pour une seule requête, la plus récente ayant exactement cette URL l'emporte, sinon la plus récente qui la contient. |
| `requestId` | `string` | non | Une requête par son id, issu de read\_network\_requests ou de all, sous forme de chaîne : « 0.16620 ». |
| `responseBody` | `boolean` | non | false écarte le corps de la réponse, pour obtenir le seul corps de la requête. |
| `method` | `string` | non | Uniquement les requêtes utilisant cette méthode, comme POST. |
| `all` | `boolean` | non | Toutes les requêtes correspondantes (les 200 dernières), pas seulement la plus récente. |
| `har` | `boolean` | non | Enregistrer toutes les requêtes correspondantes, corps entiers, dans un fichier HAR et renvoyer son chemin. |
| `max_chars` | `number` | non | Nombre maximal de caractères de chaque corps (5000 par défaut pour une seule requête, 2000 avec all). Un corps JSON plus long est aussi accompagné de bodyShape : ses clés et ses types, et la longueur de chaque tableau. |
| `tabId` | `number` | oui | L'onglet. |

### `cookies` [#cookies]

Lit et modifie les cookies du profil d'un onglet, y compris les cookies HttpOnly ; la lecture et la suppression n'atteignent que les cookies des sites qu'affichent les onglets de l'agent.

| Paramètre | Type | Requis | Description |
| --- | --- | --- | --- |
| `action` | `string` : `get`, `set`, `delete`, `clear` | oui |  |
| `url` | `string` | non | get : les cookies qu'enverrait une requête vers cette URL. |
| `domain` | `string` | non | get, delete, clear : ce domaine et ses sous-domaines. |
| `name` | `string` | non | delete : le nom du cookie. |
| `cookie` | `object` | non | set : name, value, domain, path (/), expires (secondes unix, un cookie de session en son absence), httpOnly, secure, sameSite (Lax, Strict ou None). |
| `tabId` | `number` | oui | L'onglet. |

### `emulate` [#emulate]

Fait passer un onglet pour un autre environnement : agent utilisateur, rapport de pixels, jeu de couleurs, réduction des animations, contraste, type de média, JavaScript, images, cache, en-têtes supplémentaires, un script exécuté avant chaque page, remplacement de texte et gel.

| Paramètre | Type | Requis | Description |
| --- | --- | --- | --- |
| `userAgent` | `string` ou `null` | non | L'en-tête User-Agent et navigator.userAgent, à partir du prochain chargement. |
| `deviceScaleFactor` | `number` ou `null` | non | devicePixelRatio, comme 2 ou 3. |
| `colorScheme` | `string` ou `null` : `light`, `dark`, `null` | non | prefers-color-scheme : le thème clair ou sombre d'un site qui suit le système. |
| `reducedMotion` | `string` ou `null` : `reduce`, `no-preference`, `null` | non | prefers-reduced-motion. |
| `contrast` | `string` ou `null` : `more`, `no-preference`, `null` | non | prefers-contrast : more pour un thème à contraste élevé, avec l'un ou l'autre colorScheme. |
| `media` | `string` ou `null` : `print`, `screen`, `null` | non | Le type de média CSS. |
| `javascript` | `boolean` ou `null` | non | false exécute les pages sans JavaScript. |
| `images` | `boolean` ou `null` | non | false ne charge aucune image. |
| `cache` | `boolean` ou `null` | non | false contourne le cache HTTP. |
| `extraHeaders` | `object` ou `null` | non | En-têtes ajoutés à chaque requête, par nom. |
| `initScript` | `string` ou `null` | non | JavaScript exécuté dans le cadre principal de chaque page avant ses propres scripts, à partir du prochain chargement (navigate reload ; le changement de route d'une application monopage n'est pas un chargement) : observateurs de performance, marques de chronométrage, substituts d'API. |
| `textReplace` | `array` de `array` de `string` ou `null` | non | \[\[motif, remplacement\], ...\] appliqués en continu pendant le rendu de la page, pour des captures anonymisées : texte, valeurs de champs, placeholder, title, alt et aria-label, shadow DOM, chaque cadre et le titre de l'onglet, maintenant et à chaque chargement. Un motif est un texte littéral recherché par mots entiers quelle que soit la casse, ou /une regex/flags ($1 dans le remplacement). Le texte réparti sur plusieurs éléments, les canvas et les images ne sont pas atteints. null rétablit le texte de la page. |
| `textReplaceGuard` | `boolean` ou `array` de `string` ou `null` | non | true, ou d'autres motifs qui ne doivent pas apparaître, comme le prénom seul : screenshot et zoom de computer échouent tant qu'un motif de textReplace ou de garde correspond au texte rendu, y compris un nom scindé par le balisage, ou à un champ. |
| `frozen` | `boolean` ou `null` | non | true gèle l'onglet comme Lilo gèle l'onglet d'un utilisateur laissé en arrière-plan (page suspendue, informée qu'elle est masquée, médias en pause). Votre prochain appel sur l'onglet le réveille, comme lorsque l'utilisateur y revient. |
| `reset` | `boolean` | non | Annuler toutes les émulations de l'onglet. |
| `tabId` | `number` | oui | L'onglet. |

### `performance` [#performance]

Mesure un onglet : métriques de chargement et d'affichage et mémoire, un profil chronologique avec un résumé, instantanés du tas et ramasse-miettes.

| Paramètre | Type | Requis | Description |
| --- | --- | --- | --- |
| `action` | `string` : `metrics`, `start`, `stop`, `summary`, `heap_snapshot`, `gc` | oui |  |
| `fromMs` | `number` | non | stop, summary : uniquement ce qui s'est passé à partir de ce nombre de ms après le début. |
| `toMs` | `number` | non | stop, summary : uniquement ce qui s'est passé jusqu'à ce nombre de ms après le début. |
| `focus` | `string` | non | stop, summary : les chemins d'appel menant aux fonctions dont le nom contient ceci, comme appendChild. |
| `screenshots` | `boolean` | non | start : enregistrer aussi une capture d'écran à chaque image, ce qui coûte du temps à la page (désactivé par défaut). |
| `className` | `string` | non | heap\_snapshot : lister ce qui retient les objets de cette classe, et un chemin vers l'un d'eux depuis une racine. |
| `tabId` | `number` | oui | L'onglet. |

## Sélection du navigateur [#browser-selection]

| Outil | Paramètres | Résumé |
| --- | --- | --- |
| `list_connected_browsers` | aucun | Liste les navigateurs que ce serveur peut piloter, c'est-à-dire uniquement le Lilo en cours d'exécution. |
| `select_browser` | `deviceId` | Sélectionne le navigateur à piloter ; Lilo est le seul. |
| `switch_browser` | aucun | Se connecte à un navigateur ; Lilo est déjà connecté. |
