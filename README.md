# QuotaBar

Une app macOS volontairement réduite à l’essentiel : suivre ses quotas OpenAI et Claude et ajuster son rythme de consommation. Ce projet indépendant utilise le lecteur open source [CodexBarCLI](https://github.com/steipete/CodexBar), avec une interface native compacte.

Le code de QuotaBar est sous [licence MIT](LICENSE). Le lecteur et les logos de CodexBar conservent leur [licence et attribution propres](Sources/QuotaBar/Resources/CodexBar-LICENSE.txt).

QuotaBar affiche les logos OpenAI et Claude avec leur quota hebdomadaire restant dans la barre de menu macOS. Un clic ouvre un panneau compact aux couleurs des fournisseurs, sans barres de progression, avec les limites disponibles et le jour et l’heure locale de remise à zéro. Le nom de chaque limite, sa date de reset et son pourcentage partagent une ligne ; le rythme de consommation apparaît juste dessous. L’adresse du compte est alignée à droite du fournisseur. La fenêtre adapte sa hauteur au contenu, y compris lorsque les réglages ou les données changent. Le défilement n’est utilisé que si le contenu dépasse la hauteur disponible de l’écran. Les réglages permettent d’afficher les pourcentages restants ou consommés, dans le panneau et dans la barre de menu.

Au premier lancement, un écran explique les connexions utilisées. La lecture commence uniquement après un clic sur « Vérifier les connexions ». « Plus tard » laisse l’app en attente ; un clic sur son icône rouvre cet écran. Après cette étape, l’app effectue une lecture au lancement. Les réglages proposent ensuite à l’ouverture du panneau, ou toutes les 1, 5, 15 ou 30 minutes avec lecture à l’ouverture. Le choix est conservé ; 15 minutes reste le réglage initial. Les réglages permettent aussi d’activer ou désactiver OpenAI et Claude. Seuls les fournisseurs sélectionnés sont interrogés ; seuls ceux dont un quota récent est disponible apparaissent dans la barre de menu. Une icône QuotaBar donne accès aux réglages lorsqu’aucun quota n’est disponible. Une ouverture pendant une lecture en cours réutilise cette lecture. Chaque refresh repousse le prochain refresh automatique de l’intervalle choisi. Pendant la veille, l’app annule la lecture et suspend son minuteur. Au réveil, un mode périodique effectue au plus une lecture due ou interrompue ; le mode à l’ouverture attend son déclencheur explicite.

Les valeurs expirent après 16 minutes, ou 31 minutes avec la fréquence de 30 minutes, et au reset de la fenêtre hebdomadaire. Un événement local masque les anciennes valeurs dans la barre, même en mode à l’ouverture, sans déclencher de lecture réseau. Une erreur sur un fournisseur n’empêche pas l’autre de fonctionner. Le panneau affiche une erreur et peut conserver une dernière lecture atténuée ; une session absente et une panne réseau ne sont pas distinguées par le lecteur de QuotaBar.

## Installer l’app

QuotaBar fonctionne sur macOS 14 ou plus récent, sur Mac Intel et Apple Silicon. Les paquets de distribution sont un `.dmg` à ouvrir puis à glisser dans Applications, ou un `.zip` contenant `QuotaBar.app`. Ils incluent le lecteur : aucune compilation ni installation de CodexBar n’est nécessaire.

Le premier écran permet de vérifier les connexions, puis d’utiliser l’app même si une seule IA est disponible. La vérification peut aussi être relancée depuis les réglages. Une connexion Codex locale et une session claude.ai dans un navigateur pris en charge par le lecteur restent nécessaires. Une connexion au site ChatGPT seule, ou à Claude Code seul, ne suffit pas. La source Codex du lecteur figé utilise le fichier de connexion local par défaut ; une session stockée uniquement dans le trousseau ou dans un dossier Codex personnalisé peut ne pas être détectée.

Pour Claude dans Chrome, Brave ou un autre navigateur Chromium, le lecteur doit pouvoir lire la clé de chiffrement des cookies de ce navigateur dans le trousseau macOS. Il ne demande jamais cette autorisation en arrière-plan. Un clic sur « Vérifier les connexions » la demande si Claude est indisponible : macOS affiche alors l’accès à l’élément « Safe Storage » du navigateur. Vérifiez que la demande vient de `CodexBarCLI` avant de l’accepter ; « Toujours autoriser » évite de la revoir lorsque la session claude.ai est renouvelée. Le lecteur n’affiche aucune valeur de cookie.

Le build actuel utilise une signature locale, sans validation Apple. macOS peut donc bloquer une app téléchargée. Consultez l’[aide Apple sur l’ouverture d’une app hors App Store](https://support.apple.com/fr-fr/102445) avant de décider de l’autoriser. QuotaBar ne modifie pas les protections du Mac.

## Prérequis pour compiler

- macOS 14 ou plus récent.
- Les outils en ligne de commande Apple, avec Swift 6.
- Une connexion internet au premier build pour télécharger le lecteur officiel figé en version 0.72.0.

CodexBar.app n’a pas besoin d’être installé. QuotaBar contient son propre exemplaire du lecteur open source CodexBarCLI et de ses ressources. Le build les extrait d’une archive officielle dont le SHA-256 est figé, vérifie la signature du lecteur et conserve celle-ci. Il ne copie rien depuis une installation locale de CodexBar.

QuotaBar ne cherche jamais de lecteur dans Applications, Downloads ou un ancien chemin mémorisé. Si son lecteur intégré manque, elle signale un paquet incomplet. Les connexions Codex et Claude restent nécessaires, comme pour tout lecteur de leurs quotas.

Le compte Codex lu est la session locale native. Une sélection de compte géré dans CodexBar n’est pas une sélection de compte dans QuotaBar. L’adresse renvoyée par chaque source apparaît dans le panneau pour vérifier le compte utilisé. Les réponses contenant plusieurs comptes sont refusées.

## Construire et ouvrir

```sh
git clone https://github.com/Monsieur-Loulou/QuotaBar.git
cd QuotaBar
swift run QuotaCoreChecks
sh build.sh
open dist/QuotaBar.app
```

Pour produire les paquets Intel et Apple Silicon :

```sh
sh build.sh --universal
sh package-release.sh
```

Les archives et leurs empreintes SHA-256 sont créées dans `dist/release-0.3.0/`. Le script refuse de remplacer un dossier de release existant.

Le script de build produit une app avec une signature locale dans `dist/QuotaBar.app`. Cette signature permet un usage personnel ; elle n’est pas une notarisation pour distribuer publiquement l’app.

Pour une installation durable, copiez l’app dans `~/Applications`. Le lancement automatique reste désactivé tant que vous ne l’activez pas dans les réglages de QuotaBar. QuotaBar ne désinstalle aucune autre application.

## Vérifier sans connexion

```sh
swift run QuotaCoreChecks
dist/QuotaBar.app/Contents/MacOS/QuotaBar --verify-panel
sh verify-standalone.sh --offline
open -n dist/QuotaBar.app --args --demo --preview
```

Les checks utilisent des réponses synthétiques et des petits processus locaux. Ils ne lisent aucun compte. La démo affiche explicitement des données fictives et n’appelle pas le lecteur.

Le toolchain Command Line Tools utilisé pour ce projet ne fournit ni Swift Testing ni XCTest. `QuotaCoreChecks` est donc un exécutable Swift sans dépendance, qui renvoie un code non nul si une assertion échoue.

Les checks de ressources et de panneau, ainsi que `verify-standalone.sh --offline`, fonctionnent sans lire de compte. Le mode par défaut de `verify-standalone.sh` lit les quotas réels.

Pour vérifier les comptes connectés avec le même lecteur et la même configuration que l’app :

```sh
dist/QuotaBar.app/Contents/MacOS/QuotaBar --check
```

Cette commande affiche uniquement le pourcentage hebdomadaire, le nombre de limites et la durée de lecture. Elle ne journalise pas les identifiants, les réponses brutes ou les erreurs du fournisseur.

Pour vérifier l’autonomie sans désinstaller ni déplacer votre CodexBar existant :

```sh
sh verify-standalone.sh
```

Le script copie QuotaBar dans un dossier temporaire, puis utilise le sandbox macOS pour interdire au processus de test tout accès à un dossier `CodexBar.app` ainsi qu’aux dossiers de build du projet. Il vérifie que cette interdiction fonctionne, puis lance les checks de ressources et la lecture réelle. Le sandbox concerne uniquement ces processus de test.

## Réduire le travail de fond

L’interface repose sur AppKit et SwiftUI. Elle ne lance ni navigateur caché, serveur, télémétrie, scan de conversations, mise à jour automatique ni animation continue. Un seul minuteur non répétitif déclenche le prochain refresh. Les états du panneau se recalculent à l’ouverture, à la réception des données et à l’expiration locale d’une mesure.

Le lecteur intégré conserve le code des autres fournisseurs de CodexBar ; QuotaBar ne les appelle pas. Cela occupe de l’espace disque, sans lancer ces fournisseurs en arrière-plan. L’interface complète, le watchdog, le widget et le programme de mise à jour CodexBar ne sont pas inclus.

Chaque refresh lance au plus un lecteur par fournisseur, en parallèle :

| Fournisseur | Source explicite | Limites affichées |
|---|---|---|
| OpenAI | `--source oauth` | Quota Codex / ChatGPT Work et fenêtres supplémentaires renvoyées |
| Claude | `--source web` | Appels HTTP directs pour session, semaine et limites par modèle |

Le mode automatique et les fallbacks du lecteur ne sont pas utilisés. La source web Codex, qui utilise une WebView, est exclue. Le lecteur conserve ses propres traitements internes d’authentification et de requêtes ; QuotaBar borne sa durée totale à 45 secondes et sa sortie à 256 Kio, puis termine son groupe de processus. Une erreur attend le prochain refresh normal ou une action de l’utilisateur, sans boucle de retry ajoutée par QuotaBar.

Le refresh peut effectuer plusieurs requêtes internes. Le nombre de lancements du lecteur ne constitue pas une mesure de batterie. Comparez l’impact énergétique sur le même Mac, avec une charge similaire et une seule app de barre active à la fois, avant de conclure à un gain.

## Interpréter les valeurs

Les pourcentages représentent la part restante par défaut, ou la part consommée selon le réglage, arrondie vers le bas. Le choix est conservé entre les lancements. Une valeur absente reste indisponible, elle ne devient jamais 100 %. Le logo du fournisseur est masqué dans la barre après un échec, sans quota hebdomadaire ou pour une lecture trop ancienne. Si aucun quota n’est disponible, une petite icône QuotaBar ouvre les réglages. Le panneau peut garder en mémoire la dernière lecture, atténuée et marquée comme ancienne, avec son compte. L’historique local conserve des mesures de quotas nécessaires au rythme de consommation sur 7 jours, avec une empreinte du compte qui évite de mélanger les sessions. Les adresses en clair et les réponses brutes ne sont pas sauvegardées.

La pastille du rythme projette la consommation jusqu’au reset, en supposant que le rythme horaire observé continue sans interruption. Vert (« Marge confortable ») : plus de 20 % du quota actuellement restant sera encore disponible. Jaune (« Marge faible ») : de 0 à 20 %. Rouge (« Surconsommation ») : la consommation projetée dépasse le quota restant. Un quota déjà nul indique « Quota épuisé ». Le calcul utilise toujours la part restante, quel que soit le mode d’affichage. Les estimations exigent au moins deux intervalles totalisant 30 minutes. Sans mesures suffisantes, la ligne reste neutre ; un rythme nul indique « Aucune conso observée », sans prédire l’avenir. Les mesures anciennes ou en erreur ne donnent pas de prévision. La projection utilise le rythme mesuré sur les intervalles observés des 7 derniers jours, sans compter les périodes de veille comme du temps sans consommation. Elle ne connaît pas les futurs horaires d’utilisation.

La ligne « revue de code » issue des données web supplémentaires de CodexBar n’est pas récupérée. Elle nécessiterait une source distincte compatible avec l’objectif de faible consommation. Les fenêtres supplémentaires effectivement renvoyées par la source sélectionnée sont affichées.

## Données et maintenance

Le code propre à QuotaBar n’ouvre pas les fichiers d’authentification, les cookies ou le trousseau. Le lecteur signé intégré gère ses propres connexions et permissions macOS. QuotaBar reçoit sa réponse en mémoire, puis n’en décode que les quotas et l’adresse d’affichage. La sortie brute et les messages d’erreur du lecteur ne sont ni enregistrés ni affichés. Aucun chemin externe de lecteur n’est sauvegardé ou réutilisé.

La configuration du lecteur est propre à QuotaBar et ne contient que les deux fournisseurs activés, sans compte enregistré, secret, plugin utilisateur ou hook. Elle ne modifie pas la configuration de CodexBar.

Une évolution des formats ou de l’authentification chez les fournisseurs peut nécessiter une adaptation. Le lecteur intégré reste à sa version figée jusqu’à une mise à jour explicite du projet. Refaites les checks synthétiques et `verify-standalone.sh` après une telle mise à jour. Les archives téléchargées, builds et captures de validation restent exclus de Git.

## Provenance

Les deux logos proviennent de [CodexBar](https://github.com/steipete/CodexBar/tree/03f4b68881930269793320d68776fd5f4f76d453), commit `03f4b68881930269793320d68776fd5f4f76d453`. Le lecteur provient de la [release officielle 0.72.0](https://github.com/steipete/CodexBar/releases/tag/v0.72.0). Sa signature d’origine et la [licence MIT](Sources/QuotaBar/Resources/CodexBar-LICENSE.txt) sont conservées. Les empreintes et le contenu embarqué sont détaillés dans [Reader-Provenance.txt](Sources/QuotaBar/Resources/Reader-Provenance.txt). Le reste du code de QuotaBar est propre à ce projet.
