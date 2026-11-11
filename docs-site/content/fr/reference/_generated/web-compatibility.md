## API web [#web-apis]

`navigator.serial`, `window.EyeDropper` et `window.documentPictureInPicture` n'existent que dans les
contextes sécurisés, comme dans Chrome, mais Safari n'en a aucune : une page qui teste leur présence peut distinguer un onglet Lilo de
Safari, dont Lilo affiche l'agent utilisateur.

### API Web Serial (`navigator.serial`) [#web-serial-api-navigatorserial]
- **État :** implémenté (`Lilo/Engine/SerialBridge.swift`)
- **Prise en charge par WebKit :** aucune - Chrome/Edge uniquement ; Lilo fournit un polyfill
- **Fonctionnement :** un polyfill dans le monde de la page pour les documents sécurisés de premier niveau (`requestPort` avec filtres USB de fabricant et
  de produit, `getPorts`, `open` avec débit en bauds, bits de données, bits d'arrêt, parité et contrôle de flux
  matériel, flux `readable`/`writable`, `setSignals`, `getSignals`, `forget`) au-dessus d'un pont natif
  vers les périphériques série que liste IOKit. `requestPort` affiche un sélecteur natif ; un port n'atteint que
  l'origine pour laquelle l'utilisateur l'a choisi, pour la durée de la session. Une page rechargée ou fermée libère ses ports.
- **Limites :** aucun événement `connect` lorsqu'un périphérique est branché (`disconnect` se déclenche lorsqu'il disparaît) ;
  les iframes d'origine différente n'obtiennent pas `navigator.serial` ; les lectures ne sont pas soumises à un contrôle de flux par la page.

### API EyeDropper (`window.EyeDropper`) [#eyedropper-api-windoweyedropper]

- **État :** implémenté (`Lilo/Engine/EyeDropperBridge.swift`)
- **Prise en charge par WebKit :** aucune - Chrome/Edge uniquement ; Lilo fournit un polyfill dans les contextes sécurisés
- **Fonctionnement :** `open()` affiche la pipette de couleurs du système (la loupe du panneau de couleurs de macOS) et se résout
  avec `{ sRGBHex }` ; Échap rejette avec `AbortError`.

### API File System Access (`showOpenFilePicker`, `showSaveFilePicker`, `showDirectoryPicker`) [#file-system-access-api-showopenfilepicker-showsavefilepicker-showdirectorypicker]

- **État :** non implémenté, volontairement pour l'instant
- **Prise en charge par WebKit :** aucune - Chrome/Edge uniquement (WebKit ne fournit que le système de fichiers privé de l'origine)
- **Conséquences :** les applications détectent sa présence et se rabattent sur les champs de fichier et les téléchargements, qui fonctionnent. Un polyfill
  partiel ferait basculer ces applications sur un chemin auquel il manque des éléments (des handles qui ne survivent pas à
  IndexedDB, les écritures dans des dossiers), ce qui est pire que la solution de repli.

### Gestionnaires de protocole (`navigator.registerProtocolHandler`) [#protocol-handlers-navigatorregisterprotocolhandler]

- **État :** non implémenté, volontairement
- **Prise en charge par WebKit :** aucune sur macOS - `'registerProtocolHandler' in navigator` vaut false dans une WKWebView
  (vérifié sur macOS 27) ; Chrome permet à un site de gérer un schéma, comme Gmail pour les liens `mailto:`
- **Conséquences :** les sites détectent sa présence et renoncent à le proposer. Un lien `mailto:` que suit l'utilisateur ouvre aussitôt
  l'app que macOS attribue au schéma ; tout autre lien non web l'ouvre après une demande de Lilo. Les pages voient
  Lilo comme Safari, à qui l'API manque aussi : l'ajouter distinguerait Lilo de Safari, et une
  trace visible par la page signale Lilo comme un robot.

### Clics sur les notifications de service worker [#service-worker-notification-clicks]

- **État :** partiel - un clic exécute le `notificationclick` du worker, et `client.focus()` ramène une page qu'il a ouverte
- **Conséquences :** une notification sur laquelle on clique après le redémarrage de Lilo n'atteint aucun worker : le clic ne fait que ramener Lilo au premier plan.
  `clients.openWindow()` ouvre son onglet dans un espace du profil du worker, celui qui est à l'écran lorsqu'il a ce profil.
  Les notifications propres à une page (`new Notification`) ramènent leur onglet comme dans Chrome.

### Clés d'accès / WebAuthn [#passkeys--webauthn]

- **État :** nécessite l'habilitation `com.apple.developer.web-browser.public-key-credential`, qu'Apple
  accorde par identifiant d'app. Sans elle, la vérification `getCanCurrentProcessAccessPasskeysForRelyingParty`
  de WebKit échoue : `PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable()` vaut false et
  `navigator.credentials.create()` / `.get()` rejettent aussitôt avec `NotAllowedError` (vérifié sur
  macOS 27). Apple ne l'a pas encore accordée, donc les versions publiées ne la portent pas : aucun WebAuthn n'y
  fonctionne, clés d'accès comme clés de sécurité USB/NFC. Une requête échoue aussitôt avec `NotAllowedError`,
  sans aucune invite, et ressemble à une annulation par l'utilisateur ; un compte dont le seul second facteur est une clé
  matérielle ne peut pas se connecter. Une fois l'habilitation accordée, les builds de publication la portent par l'intermédiaire d'un profil d'approvisionnement, voir
  [docs/RELEASING.md](https://github.com/Alexays/Lilo/blob/main/docs/RELEASING.md#browser-passkey-entitlement) ; les builds ad hoc et Debug ne la portent jamais.
- **Pistes écartées :** une intégration sur mesure de `ASAuthorizationPlatformPublicKeyCredentialProvider` ne ferait
  que dupliquer WebKit. `com.apple.developer.associated-domains` (`webcredentials:`) régit les
  domaines *propres* à l'app et ne peut pas couvrir des sites web arbitraires - ce n'est pas ainsi qu'un navigateur héberge WebAuthn.

### DRM - FairPlay (fonctionne) et Widevine/PlayReady (impossible) [#drm---fairplay-works-vs-widevineplayready-impossible]

- **FairPlay Streaming (`com.apple.fps`, `1_0`, `2_0`, `3_0`) : pris en charge, aucune configuration nécessaire.**
  Mesuré dans une WKWebView configurée comme les onglets de Lilo : `requestMediaKeySystemAccess` est accordé pour
  les données d'initialisation `cenc`, `sinf` et `skd` avec H.264 et HEVC 10 bits, et `createMediaKeys` fonctionne. L'ancien
  `window.WebKitMediaKeys` est également présent. ClearKey est accordé.
- **Aucune session à licence persistante :** les téléchargements hors ligne dans les applications web de streaming ne sont pas disponibles.
- **Widevine / PlayReady : rejetés (`NotSupportedError`), sans correction possible.** WebKit sur les plateformes
  Apple n'implémente EME que pour FairPlay et n'expose aucune API permettant d'enregistrer un autre CDM ;
  `libwidevinecdm` ne se branche que sur l'hôte CDM de Chromium. Obtenir Widevine supposerait d'embarquer un
  second moteur pour les origines à DRM, ce qui est délibérément hors des objectifs.
- **Codecs (MSE et ManagedMediaSource) :** H.264, HEVC Main/Main10, Dolby Vision, VP9 profils 0
  et 2 (10 bits), AV1, Opus et Vorbis dans WebM, AAC, E-AC-3. Le décodage 4K HDR est fluide.
- **Agent utilisateur :** une simple identité Safari (sans jeton `Lilo`), si bien que les services servent leur variante
  Safari/FairPlay (voir [Agent utilisateur et Chrome Web Store](/reference/extension-compatibility#user-agent-and-the-chrome-web-store)).
- **Services de streaming** (d'après leurs pages d'assistance publiques pour Safari, pas encore testés à la main dans Lilo) :
  - *Devraient fonctionner :* Netflix (4K non vérifiée), Prime Video, Disney+, Max, Apple TV+, lecteur web
    Spotify, Apple Music web, Crunchyroll, YouTube (4K HDR), YouTube Music, Twitch.
  - *Qualité réduite :* Canal+ (720p signalé dans Safari), Tidal (pas de lossless, qui nécessite Widevine).
  - *Inconnu :* Deezer, films achetés et loués sur YouTube.

### Image dans l'image - PiP `<video>` et Document PiP (shim Lilo) [#picture-in-picture---video-pip-and-document-pip-lilo-shim]

- **Image dans l'image pour une seule `<video>` : pris en charge.** Le PiP d'élément de WebKit fonctionne
  (`video.webkitSetPresentationMode('picture-in-picture')` / `requestPictureInPicture()`), et Lilo
  y entre automatiquement lorsqu'un onglet dont un média est actif passe à l'arrière-plan (`PiPController`). Cela détache *une seule* vidéo
  dans la fenêtre PiP du système (sans les commandes de la page) - ce qui convient au PiP à flux unique du type YouTube/Netflix.
- **Document Picture-in-Picture (`window.documentPictureInPicture`) : pris en charge par un shim Lilo.**
  WebKit ne fournit aucune implémentation. Un module dans le monde de la page (`DocumentPiPBridge`) définit l'API dans
  les documents sécurisés de premier niveau des onglets ordinaires ; `requestWindow` fait du prochain `window.open` de l'onglet une
  fenêtre contextuelle de même origine qu'héberge `DocumentPiPController` : ancrée à sa propre taille dans la barre latérale tant que
  Lilo est au premier plan et que son onglet n'est pas affiché, flottante sinon (toujours au premier plan, dans tous les espaces, exclue du
  partage d'écran, non activante, calée dans un coin mémorisé pour chaque écran, boutons de retour et de fermeture
  au survol). La fenêtre se ferme lorsque sa page navigue ou que son onglet se ferme. Un onglet d'appel dont la page
  enregistre l'action Media Session `enterpictureinpicture` obtient sa fenêtre PiP lorsqu'on quitte
  l'onglet (elle se referme au retour) ; sans fenêtre dans un délai de 1,5 s, la page entière passe dans le dock ou le
  panneau flottant comme auparavant. Les onglets d'agent reçoivent une `NotAllowedError`.
- **Google Meet :** Meet ne propose son Document PiP qu'à Chrome, d'après la lecture de `navigator.userAgent` (il
  ne lit jamais `userAgentData`), et fixe au chargement l'identité que suit sa pile WebRTC. Lilo n'affiche un
  agent utilisateur Chrome sur `meet.google.com` que dans la microtâche qui suit une lecture de
  `documentPictureInPicture` : les vérifications PiP de Meet réussissent, son appel reste sur le chemin multimédia de Safari. Une identité
  Chrome complète casse la caméra et le micro (`createEncodedStreams` et `MediaStreamTrackGenerator` audio,
  propres à Chromium). `defaults write <bundle id> LiloMeetDocumentPiPDisabled -bool true`
  désactive la partie Meet (nouveaux onglets).

### Partage d'écran - capture d'onglet (navette d'images Lilo) [#screen-sharing---tab-capture-lilo-frame-ferry]

- **Le partage d'onglet est pris en charge par un shim Lilo.** Le pipeline de capture de WebKit n'énumère que les écrans
  et les fenêtres du système (la capture d'onglet est une surface `getDisplayMedia` propre à Chromium), donc Lilo intercepte
  `getDisplayMedia` dans le monde de la page : un sélecteur de l'interface du navigateur liste les onglets ouverts, et en choisir un
  renvoie un véritable `MediaStream` construit côté page à partir d'un canvas alimenté par une navette d'images native
  (`TabShareSessionController` : instantanés à 30 ips du moteur de l'onglet partagé, encodés en H.264 par le
  matériel et décodés côté page avec WebCodecs ; les images identiques sont ignorées, si bien qu'un contenu statique
  ne coûte presque rien). Un onglet partagé
  passé à l'arrière-plan reste attaché sous la vue active à la taille complète du contenu (le principe de
  rétention utilisé pour l'inspecteur), de sorte qu'il conserve sa mise en page de bureau et continue d'être rendu ; l'indicateur de capture de la barre latérale
  le signale comme partagé.
- **Réserves par rapport à Chrome :** le flux transporté est uniquement vidéo (pas d'audio de l'onglet : WebKit n'expose aucune
  prise audio par page) et plafonné à 30 ips / 1920 pixels de large.
- **Choisir « partager plutôt un écran ou une fenêtre »** exécute le `getDisplayMedia` propre à WebKit et son
  sélecteur système (le choix lui-même vaut consentement ; aucune autorisation Enregistrement de l'écran), invoqué par le
  code natif avec un nouveau geste utilisateur, puisque le sélecteur d'onglets asynchrone a quitté celui de la page.
- **Les extensions** (`chrome.tabCapture`, `chrome.desktopCapture`) empruntent la même navette (voir
  tabCapture et desktopCapture sous [Différences d'API](/reference/extension-compatibility#api-differences)). Un choix de bureau utilise
  directement le `SCContentSharingPicker` du système, et un `SCStream` alimente la navette tant que le flux vit.
- **Remarque :** les utilitaires qui maintiennent une fenêtre de superposition transparente en plein écran (LanguageTool for
  Desktop, certains outils de capture ou de gestion de fenêtres) interceptent les clics destinés au sélecteur de fenêtres du système :
  le sélecteur s'ouvre mais aucune fenêtre ne peut être sélectionnée, dans tous les navigateurs, Safari compris. Quittez
  l'app de superposition pendant le partage.

### Gel des onglets inactifs [#idle-tab-freezing]

- **Épargnés comme dans la politique de gel de Chrome :** les onglets qui lisent ou capturent un média, qui chargent, qui sont autorisés à notifier, qui détiennent une
  `RTCPeerConnection` connectée (y compris avec de simples canaux de données) ou un Web Lock.
- **Réserve :** WebKit ne signale à l'app ni les pairs ni les verrous, donc Lilo suit les pairs dans le monde de la page du document principal
  et demande au document principal ses verrous lorsque l'onglet doit être gelé : un pair ou un verrou détenu par un cadre ou un worker
  n'empêche pas son onglet d'être gelé.

## Limitations connues (niveau WebKit/macOS - aucune correction possible dans Lilo) [#known-limitations-webkitmacos-level---no-fix-possible-in-lilo]

### Extension Mots de passe iCloud [#icloud-passwords-extension]

- **Symptôme :** l'extension Chrome « Mots de passe iCloud » ne parvient pas à se connecter à son assistant natif dans Lilo.
- **Cause profonde :** l'hôte de messagerie native `com.apple.passwordmanager`
  (`/System/Cryptexes/App/System/Library/CoreServices/PasswordManagerBrowserExtensionHelper.app`)
  porte des **contraintes de lancement sur le parent** dans sa signature de code, indépendantes des
  `allowed_origins` du manifeste. Son parent doit soit correspondre à une liste fixe de paires identifiant de signature
  et identifiant d'équipe de navigateurs connus, soit détenir l'habilitation
  `com.apple.developer.web-browser.public-key-credential`. Lilo n'a ni l'un ni l'autre, donc
  l'extension ne peut pas joindre son assistant.
- **Correction :** impossible dans le code de Lilo : elle nécessite cette habilitation, demandée à Apple (demande « macOS
  Browsers Passkeys »).

### Médiation conditionnelle des clés d'accès (remplissage automatique) [#passkey-conditional-mediation-autofill]

- **Symptôme :** `navigator.credentials.get({ mediation: "conditional" })` /
  `PublicKeyCredential.isConditionalMediationAvailable()` (suggestions de clés d'accès dans les champs de nom d'utilisateur)
  peuvent s'annoncer indisponibles depuis un hôte WKWebView tiers.
- **Cause profonde :** la prise en charge de la médiation conditionnelle par WebKit en dehors de Safari. Il n'existe aucun remède côté app.
  Les flux de clés d'accès explicites (non conditionnels) nécessitent eux aussi l'habilitation décrite dans
  [Clés d'accès / WebAuthn](#passkeys--webauthn), que les versions publiées ne portent pas encore : aucune
  requête WebAuthn n'y fonctionne.

### Apple Pay sur le web [#apple-pay-on-the-web]

- **Symptôme :** `window.PaymentRequest` est indéfini et `ApplePaySession`, lorsqu'il est présent, est le
  substitut du SDK Apple Pay JS, qui paie au moyen d'un code scanné avec un iPhone (vérifié sur macOS 27).
- **Cause profonde :** WebKit n'expose les deux qu'avec le réglage privé `_applePayEnabled`, désactivé sur macOS
  en dehors de Safari. Une fois activé, `canMakePayments()` vaut true mais la feuille système se ferme aussitôt :
  PassKit refuse un hôte dépourvu des habilitations privées de Safari `com.apple.private.in-app-payments` et
  `com.apple.payment.all-access` (« not entitled for merchant session »), qu'Apple
  n'accorde à aucune app tierce. `com.apple.developer.in-app-payments` couvre les identifiants de marchand propres à une app,
  pas ceux d'un site web.
- **Traitement par Lilo :** le réglage reste désactivé : un `ApplePaySession` natif prendrait la place du
  substitut du SDK, puis échouerait.

### Web Push [#web-push]

- **Symptôme :** `PushManager` et `registration.pushManager` sont indéfinis, si bien qu'un site ne peut pas notifier lorsqu'aucune de ses pages n'est ouverte. Les notifications qu'affiche une page ou son service worker (`new Notification`, `registration.showNotification`) fonctionnent.
- **Cause profonde :** WebKit n'active Web Push que pour une app détenant l'habilitation web push d'Apple, que Lilo n'a pas.
- **Traitement par Lilo :** aucun.

### `Notification.permission` précoce [#early-notificationpermission]

- **Symptôme :** les scripts d'une page qui s'exécutent avant `DOMContentLoaded` peuvent lire `Notification.permission` comme `'default'` sur un site que vous avez autorisé ou bloqué.
- **Cause profonde :** WebKit ne donne à un processus web les décisions du magasin de données que lorsqu'il le lance pour ce magasin ; un processus préchauffé, que prennent souvent les nouveaux onglets et les navigations intersites, démarre sans aucune. Il lit aussi un site bloqué comme `'default'` tant que le site n'a pas demandé, pour contrer le pistage par empreinte.
- **Traitement par Lilo :** à `DOMContentLoaded`, la page apprend la décision enregistrée. Un processus lancé pour son magasin, ainsi que tout service worker, la connaît dès le premier script.

### Qualité du micro pendant les appels [#microphone-quality-during-calls]
- **Symptôme :** le micro d'un appel sonne plus terne et plus traité que dans Chrome : rien au-dessus de 12 kHz n'atteint la page.
- **Cause profonde :** avec l'annulation d'écho activée (la valeur par défaut, et ce que demandent les sites d'appel), WebKit fait passer le micro par le traitement de la voix d'Apple, qui le plafonne à 12 kHz ; Chrome annule l'écho, supprime le bruit et règle le gain de façon logicielle sur le signal brut. WebKit n'expose séparément ni `noiseSuppression` ni `autoGainControl`, et sa capture avec `echoCancellation: false` sort de 14 à 26 dB sous le niveau du périphérique, avec des coupures, si bien que la désactiver n'est pas un remède. La liaison d'un casque Bluetooth plafonne son micro à 12 kHz dans tous les navigateurs.
- **Traitement par Lilo :** aucun ; égaler Chrome exigerait une pile de traitement audio propre à Lilo.

### Favicons qu'une page modifie par script [#favicons-a-page-changes-by-script]

- **Symptôme :** un onglet conserve l'icône avec laquelle sa page s'est chargée lorsque la page remplace ensuite son `<link rel=icon>` (une pastille de non-lus, un état de build).
- **Cause profonde :** WebKit propose à l'app les icônes de lien d'un document une seule fois, au chargement du document, et plus jamais pour un `<link rel=icon>` ajouté ou modifié par la suite (vérifié sur macOS 27). Chrome suit ces changements.
- **Traitement par Lilo :** aucun ; les suivre exigerait un script surveillant le `<head>` de chaque page dans un monde isolé, un chargement d'icône propre à Lilo en dehors de celui de WebKit, et une icône par onglet distincte de celle par site que Lilo met en cache.

### Référent d'un téléchargement depuis le menu contextuel [#referrer-of-a-context-menu-download]

- **Symptôme :** « Télécharger l'image » ou « Télécharger le fichier lié » depuis un cadre isolé en bac à sable sans `allow-popups` envoie l'origine du cadre (aucune de https vers http), quelle que soit la politique de référent du cadre ; avec « Empêcher le suivi entre sites » activé, ou dans un espace privé, un téléchargement vers un autre site envoie au plus l'origine de la page, même sous `unsafe-url`.
- **Cause profonde :** les éléments de téléchargement propres à WebKit n'envoient aucun Referer, donc Lilo fait ouvrir l'adresse par WebKit dans une nouvelle fenêtre depuis le cadre cliqué, comme le ferait un lien, et prend le Referer dans la décision de politique de cette requête avant de l'annuler ; un cadre en bac à sable sans `allow-popups` ne peut pas en ouvrir. La prévention du suivi de WebKit réduit tout Referer intersite à son origine dans le processus réseau, y compris celui d'un téléchargement. Chrome applique la politique du cadre dans les deux cas.
- **Traitement par Lilo :** le cadre en bac à sable obtient strict-origin-when-cross-origin à partir de son adresse ; la réduction intersite est celle de WebKit, comme pour toute requête.

### Erreurs de certificat sur les sites qui définissent eux-mêmes HSTS [#certificate-errors-on-sites-that-set-hsts-themselves]

- **Symptôme :** une erreur de certificat sur un site qui a envoyé un en-tête `Strict-Transport-Security` lors d'une visite antérieure propose toujours « Continuer quand même », et l'exception charge la page. Chrome n'offre aucun moyen de passer outre. Les hôtes de la liste de préchargement HSTS (tout `.app` et `.dev`, de nombreux grands sites) n'obtiennent pas « Continuer quand même », comme dans Chrome.
- **Cause profonde :** les hôtes HSTS qu'enregistrent les pages d'un profil résident dans le processus réseau de WebKit. La seule vue que WebKit donne à l'app, ses enregistrements de données de sites web `_WKWebsiteDataTypeHSTSCache`, nomme chacun par domaine enregistrable (`example.com` pour `www.example.com`), sans l'hôte ni `includeSubDomains`, si bien qu'elle ne peut pas distinguer un hôte HSTS d'un hôte voisin sans HSTS (vérifié sur macOS 27). CFNetwork respecte bel et bien l'exception sur un hôte HSTS.
- **Traitement par Lilo :** la liste de préchargement provient de la recherche de CFNetwork dans le processus propre à Lilo ; une règle par site interdirait aussi aux utilisateurs l'accès à un hôte voisin doté d'un certificat auto-signé (un serveur domestique sous un domaine personnel), donc Lilo continue d'y proposer l'exception.
