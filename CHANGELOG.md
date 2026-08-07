# Changelog V8 → V9

## Refonte structurelle
- Monolithe unique de 7743 lignes → découpé en modules (`lib/*.sh`, un fichier = une responsabilité)
- Dashboard web : bash→Python→HTML→CSS→JS imbriqué dans un seul heredoc → fichiers séparés (`web/dashboard_server.py`, `web/static/{index.html,style.css,app.js}`)
- Configuration centralisée dans `config/defaults.conf` (plus de valeurs codées en dur éparpillées)
- Plus de chemin de données par défaut figé — toujours demandé explicitement (`configure_infra()`)

## Bugs corrigés (présents dans la V8 d'origine)
- `printf '"%%s",'` (double `%`) cassait l'affichage du plan d'installation dans le JSON de progression
- Le dashboard Python parsait mal `config.env` (format `CFG[clé]=valeur`) → ne lisait jamais la vraie config utilisateur
- `IFS=$'\n\t'` global cassait toutes les boucles `for x in $variable` séparées par espaces (validation de port, sélection multiple dans le menu de mise à jour)
- 5 endroits chargeaient `config.env` sans déclarer tous les tableaux (`HW`, `PLAN`, `PLAN_DESC`, `PLAN_REBOOT`) → sortie silencieuse du script sous `set -u`
- Fuite de `CURRENT_STEP` entre menus → une erreur bénigne dans un menu quelconque pouvait déclencher l'écran d'erreur critique et quitter le programme

## Nouvelles fonctionnalités serveur (`ia-local-automatique`)
- **Bouton d'annulation** d'installation depuis le dashboard web (SIGTERM puis SIGKILL du groupe de process)
- **Progression fine** en temps réel pour `ollama pull` et `docker pull` (pourcentage réel, plus seulement des étapes macro)
- **Confirmations relayées au dashboard web** : toute question `confirm()` du script apparaît aussi en popup web avec Oui/Non, en plus du terminal
- **Qdrant** ajouté comme composant installable (base vectorielle pour la mémoire IA)
- Dashboard : nouvel onglet **"Accès & Notes"**
  - Cartes de statut en direct (Ollama, Open WebUI, lien GitHub)
  - **Notes** avec liste individuelle, suppression → corbeille, restauration, vidage définitif
  - Carte **"Connecter un éditeur"** (Android Studio/IntelliJ) avec URL API prête à copier
  - Carte **"Connecter Momory CLI"** — config auto-calculée (IP LAN, port, modèles installés, Qdrant)
  - **Téléchargement direct de momory-cli** depuis le dashboard (`/download/momory-cli.zip`) avec commandes d'installation Windows/Mac/Linux prêtes à copier
- Header du dashboard refait : marque "Momory · IA Local" avec logo animé

## Nouveau projet : `momory-cli/`
Assistant IA personnel local (CLI), connecté au serveur Ollama :
- `momory` — conversation + accès fichiers automatique selon la demande (lecture/écriture/suppression/téléchargement, avec diff affiché et confirmation)
- Mode réflexion (`think`) activé automatiquement si le modèle le supporte
- Mode auto-approbation optionnel par session (une seule question au démarrage)
- `momory doctor`, `momory models`, `momory config [--setup|--auto <ip>]`
- **Config automatique** : `momory config --auto <ip>` récupère tout depuis le dashboard du serveur, sans saisie manuelle
- **Détection de dérive** au démarrage : prévient si la config serveur a changé depuis la dernière synchro locale, avec la commande exacte pour corriger
