# QuotaBar

Une app macOS volontairement réduite à l’essentiel : suivre ses quotas OpenAI et Claude et ajuster son rythme de consommation. QuotaBar lit les quotas elle-même, à la source officielle de chaque fournisseur, avec une interface native compacte.

Le code de QuotaBar est sous [licence MIT](LICENSE). Les logos OpenAI et Claude sont des marques de leurs propriétaires.

QuotaBar affiche les logos OpenAI et Claude avec leur quota hebdomadaire restant dans la barre de menu macOS. Un clic ouvre un panneau compact aux couleurs des fournisseurs, sans barres de progression, avec les limites disponibles et le jour et l’heure locale de remise à zéro. Le nom de chaque limite, sa date de reset et son pourcentage partagent une ligne ; le rythme de consommation apparaît juste dessous. L’adresse du compte est alignée à droite du fournisseur. La fenêtre adapte sa hauteur au contenu, y compris lorsque les réglages ou les données changent. Le défilement n’est utilisé que si le contenu dépasse la hauteur disponible de l’écran. Les réglages permettent d’afficher les pourcentages restants ou consommés, dans le panneau et dans la barre de menu.

L’app effectue une lecture au lancement. Les réglages proposent ensuite à l’ouverture du panneau, ou toutes les 1, 5, 15 ou 30 minutes avec lecture à l’ouverture. Le choix est conservé ; 15 minutes reste le réglage initial. Les réglages permettent aussi d’activer ou désactiver OpenAI et Claude. Seuls les fournisseurs sélectionnés sont interrogés ; seuls ceux dont un quota récent est disponible apparaissent dans la barre de menu. Une icône QuotaBar donne accès aux réglages lorsqu’aucun quota n’est disponible. Une ouverture pendant une lecture en cours réutilise cette lecture. Chaque refresh repousse le prochain refresh automatique de l’intervalle choisi. Pendant la veille, l’app annule la lecture et suspend son minuteur. Au réveil, un mode périodique effectue au plus une lecture due ou interrompue ; le mode à l’ouverture attend son déclencheur explicite.

Les valeurs expirent après 16 minutes, ou 31 minutes avec la fréquence de 30 minutes, et au reset de la fenêtre hebdomadaire. Un événement local masque les anciennes valeurs dans la barre, même en mode à l’ouverture, sans déclencher de lecture réseau. Une erreur sur un fournisseur n’empêche pas l’autre de fonctionner. Le panneau affiche une erreur et peut conserver une dernière lecture atténuée ; une connexion absente ou expirée a son propre message.

## Installer l’app

QuotaBar fonctionne sur macOS 14 ou plus récent, sur Mac Intel et Apple Silicon. Les paquets de distribution sont un `.dmg` à ouvrir puis à glisser dans Applications, ou un `.zip` contenant `QuotaBar.app`. Aucune compilation ni autre app de quotas n’est nécessaire.

QuotaBar fonctionne même si une seule IA est disponible. Il faut :

- pour OpenAI, Codex connecté sur ce Mac (il est inclus dans l’app ChatGPT). Une connexion au site ChatGPT seule ne suffit pas ;
- pour Claude, Claude Code connecté sur ce Mac. Une connexion au site claude.ai seule ne suffit pas.

QuotaBar ne demande aucune clé API. Elle lit la connexion de Claude Code dans le trousseau avec l’outil Apple `security` ; sur le Mac de développement, macOS n’a demandé aucune autorisation pour cela. Si une fenêtre du trousseau apparaît, vérifiez qu’elle vient de `security` avant de l’accepter.

Le build actuel utilise une signature locale, sans validation Apple. macOS peut donc bloquer une app téléchargée. Consultez l’[aide Apple sur l’ouverture d’une app hors App Store](https://support.apple.com/fr-fr/102445) avant de décider de l’autoriser. QuotaBar ne modifie pas les protections du Mac.

## Prérequis pour compiler

- macOS 14 ou plus récent.
- Les outils en ligne de commande Apple, avec Swift 6.

Le build n’a besoin d’aucune dépendance externe ni de téléchargement.

L’adresse renvoyée par chaque source apparaît dans le panneau pour vérifier le compte utilisé.

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
open -n dist/QuotaBar.app --args --demo --preview
```

Les checks utilisent des réponses synthétiques et des petits processus locaux. Ils ne lisent aucun compte. Un faux serveur Codex local vérifie le dialogue avec `codex app-server`. La démo affiche explicitement des données fictives et ne lit aucun compte.

Le toolchain Command Line Tools utilisé pour ce projet ne fournit ni Swift Testing ni XCTest. `QuotaCoreChecks` est donc un exécutable Swift sans dépendance, qui renvoie un code non nul si une assertion échoue.

Les checks de ressources et de panneau fonctionnent sans lire de compte.

Pour vérifier les comptes connectés avec les mêmes lectures que l’app :

```sh
dist/QuotaBar.app/Contents/MacOS/QuotaBar --check
```

Cette commande affiche uniquement le pourcentage hebdomadaire, le nombre de limites et la durée de lecture. Elle ne journalise pas les identifiants, les réponses brutes ou les erreurs du fournisseur.

## Réduire le travail de fond

L’interface repose sur AppKit et SwiftUI. Elle ne lance ni navigateur caché, serveur permanent, télémétrie, scan de conversations, mise à jour automatique ni animation continue. Un seul minuteur non répétitif déclenche le prochain refresh. Les états du panneau se recalculent à l’ouverture, à la réception des données et à l’expiration locale d’une mesure.

Chaque refresh lit les fournisseurs sélectionnés, en parallèle :

| Fournisseur | Source | Limites affichées |
|---|---|---|
| OpenAI | `codex app-server`, l’outil officiel de Codex, interrogé en JSON-RPC (`account/read`, `account/rateLimits/read`) | Fenêtres renvoyées par Codex, dont la semaine |
| Claude | Connexion de Claude Code dans le trousseau, lue avec l’outil Apple `security`, puis `GET /api/oauth/usage` et `/api/oauth/profile` d’Anthropic | Session de 5 heures, semaine, limites par modèle |

Le serveur Codex garde son entrée ouverte jusqu’aux deux réponses : il cesse de répondre en fin d’entrée. QuotaBar ferme ensuite cette entrée et le serveur s’arrête seul. Il ne lance aucun processus enfant pour ces deux requêtes. Une lecture est bornée à 30 secondes et sa sortie à 1 Mio. Une erreur attend le prochain refresh normal ou une action de l’utilisateur, sans boucle de retry.

Le nombre de requêtes ne constitue pas une mesure de batterie. Comparez l’impact énergétique sur le même Mac, avec une charge similaire et une seule app de barre active à la fois, avant de conclure à un gain.

## Interpréter les valeurs

Les pourcentages représentent la part restante par défaut, ou la part consommée selon le réglage, arrondie vers le bas. Le choix est conservé entre les lancements. Une valeur absente reste indisponible, elle ne devient jamais 100 %. Le logo du fournisseur est masqué dans la barre après un échec, sans quota hebdomadaire ou pour une lecture trop ancienne. Si aucun quota n’est disponible, une petite icône QuotaBar ouvre les réglages. Le panneau peut garder en mémoire la dernière lecture, atténuée et marquée comme ancienne, avec son compte. L’historique local conserve des mesures de quotas nécessaires au rythme de consommation sur 7 jours, avec une empreinte du compte qui évite de mélanger les sessions. Les adresses en clair et les réponses brutes ne sont pas sauvegardées.

La pastille du rythme projette la consommation jusqu’au reset, en supposant que le rythme horaire observé continue sans interruption. Vert (« Marge confortable ») : plus de 20 % du quota actuellement restant sera encore disponible. Jaune (« Marge faible ») : de 0 à 20 %. Rouge (« Surconsommation ») : la consommation projetée dépasse le quota restant. Un quota déjà nul indique « Quota épuisé ». Le calcul utilise toujours la part restante, quel que soit le mode d’affichage. Les estimations exigent au moins deux intervalles totalisant 30 minutes. Sans mesures suffisantes, la ligne reste neutre ; un rythme nul indique « Aucune conso observée », sans prédire l’avenir. Les mesures anciennes ou en erreur ne donnent pas de prévision. La projection utilise le rythme mesuré sur les intervalles observés des 7 derniers jours, sans compter les périodes de veille comme du temps sans consommation. Elle ne connaît pas les futurs horaires d’utilisation.

Sont affichées : pour OpenAI, les deux fenêtres renvoyées par Codex ; pour Claude, la session de 5 heures, la semaine et les limites hebdomadaires Opus et Sonnet lorsqu’elles existent. Les autres champs des réponses sont ignorés.

## Données et maintenance

QuotaBar n’enregistre, n’affiche et ne renouvelle aucun jeton. Codex garde la gestion de sa connexion. Pour Claude, le jeton de Claude Code reste en mémoire le temps d’une lecture ; s’il a expiré, QuotaBar demande d’ouvrir Claude Code, qui le renouvelle. Les réponses brutes ne sont ni enregistrées ni affichées : seuls les quotas et l’adresse d’affichage sont décodés. Les processus lancés reçoivent un environnement réduit, sans clé API, jeton ou proxy hérité.

Une évolution des formats ou de l’authentification chez les fournisseurs peut nécessiter une adaptation. Refaites les checks synthétiques et `--check` après une telle mise à jour. Les builds et captures de validation restent exclus de Git.

## Provenance

Les logos viennent des sites officiels : `openai.com/favicon.svg` et `claude.ai/favicon.svg`, recolorés pour la barre de menu. Tout le code de QuotaBar est propre à ce projet.
