# Contribuer

QuotaBar garde une interface native et compacte pour OpenAI et Claude. Les nouvelles fonctions doivent servir le suivi des quotas sans ajouter de télémétrie, de navigateur caché ni de dépendance inutile.

## Vérifier

```sh
swift run QuotaCoreChecks
sh build.sh
dist/QuotaBar.app/Contents/MacOS/QuotaBar --verify-panel
sh verify-standalone.sh --offline
```

Ces contrôles utilisent des données synthétiques et vérifient les ressources embarquées sans lire de compte. Les rendus `--render-demo /tmp/quotabar.png --forecast --light` et `--settings` aident à vérifier la mise en page. Une modification de l’interaction avec la barre de menu doit aussi être essayée sur un Mac.

`--check` et `verify-standalone.sh` sans `--offline` lisent les quotas des comptes connectés. N’enregistrez aucune réponse brute dans un rapport ou un commit.

## Publier une modification

Décrivez le comportement changé, les contrôles exécutés et leurs limites. Aucun compte, secret, cookie, jeton, historique local ou capture de compte réel ne doit entrer dans le dépôt. Gardez `.build/`, `.vendor/` et `dist/` hors de Git.

Le code propre à QuotaBar est sous MIT. Conservez `LICENSE`, `CodexBar-LICENSE.txt` et `Reader-Provenance.txt`. Une mise à jour du lecteur doit préciser la release officielle, les empreintes vérifiées et la signature attendue. La signature locale du build ne vaut pas notarisation.
