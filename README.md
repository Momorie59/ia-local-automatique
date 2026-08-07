# ia-local-automatique — V9 (réécriture complète)

## Comment démarrer

```bash
sudo bash install_ia_local_V9.sh
```

Au premier lancement (ou via `configure_infra` lors d'une réinstallation),
le script te demande explicitement quel disque/point de montage utiliser
pour les données — **aucun chemin n'est codé en dur**, contrairement à la
V8 qui avait `/mnt/ia_toshiba` en dur à plusieurs endroits.

## Ce qui a changé par rapport à la V8

### Structure
Le fichier unique de 7743 lignes est éclaté en modules à responsabilité
unique (`lib/*.sh`), plus un dossier `web/` pour le dashboard (HTML/CSS/JS
séparés au lieu d'un heredoc bash→Python→HTML→CSS→JS imbriqué).

### Bugs réels trouvés et corrigés (présents dans la V8 d'origine)
1. **`lib/dashboard.sh`** : le JSON de progression utilisait
   `printf '"%%s",'` (double `%`) au lieu de `printf '"%s",'` — le champ
   `plan` affiché dans le dashboard contenait littéralement le texte
   `%s` répété au lieu du nom des étapes.
2. **`web/dashboard_server.py`** : le parseur de config Python lisait
   `config.env` comme du `clé=valeur` plat, alors que le bash y écrit du
   `CFG[clé]=valeur` (tableau bash sérialisé). Résultat : `cfg.get("webui_dir")`
   ne matchait jamais et retombait toujours sur une valeur par défaut,
   quelle que soit ta config réelle.
3. Deux `cd` sans gestion d'échec dans `lib/execute_plan.sh` (compilation
   llama.cpp) — un `cd` silencieusement échoué aurait pu faire compiler/
   installer des fichiers au mauvais endroit.
4. Plusieurs `local var="$(commande)"` qui masquaient le code de retour de
   la commande (`local` réussit toujours, donc un échec de la commande
   passait inaperçu) — corrigés en déclarant puis assignant séparément.

### Nettoyage structurel
- Suppression du chemin de données codé en dur (`/mnt/ia_toshiba`) — le
  point de montage est maintenant toujours demandé via `configure_infra()`
  (`lib/interactive_config.sh`), qui existait déjà en V8 et fait déjà ça
  bien : elle liste les disques et **propose** un point de montage calculé
  à partir du disque choisi, sans jamais imposer de valeur figée.
- `config/defaults.conf` centralise les constantes (port du dashboard,
  TTL de session, rate limiting, identifiants par défaut, chemins d'état/logs).
- Résolution d'une collision de noms : deux fonctions `load_config`
  existaient (une pour charger les réglages fixes, une pour restaurer
  l'état complet d'une installation interrompue) et l'une écrasait
  silencieusement l'autre. Renommé la première en `load_settings`.
- Toutes les anciennes variables (`STATE_DIR`, `LOG_DIR`, `CONFIG_FILE`,
  `CREDS_FILE`, `PROGRESS_FILE`, `STATE_FILE`) sont désormais nommées
  `IA_STATE_DIR`, `IA_LOG_DIR`, etc. de façon cohérente dans tout le projet.
- Vérifié avec `shellcheck` (sévérité *error* : 0 problème) sur l'ensemble
  du projet.

### Structure des fichiers

| Fichier | Rôle |
|---|---|
| `install_ia_local_V9.sh` | Point d'entrée : charge les modules, gère la reprise après reboot/erreur |
| `config/defaults.conf` | Toutes les constantes (chemins d'état, port dashboard, TTL, etc.) |
| `lib/common.sh` | Logging, couleurs, privilèges, chargement des réglages |
| `lib/os_detect.sh` | Détection distro + abstraction paquets/services |
| `lib/gpu_drivers.sh` | Drivers NVIDIA/ROCm, Docker, Ollama sécurisé, Container Toolkit |
| `lib/dashboard.sh` | Déploiement de `web/` + service systemd du dashboard |
| `lib/hud.sh` | Panneau HUD terminal (stats temps réel) |
| `lib/state.sh` | Reprise après reboot/erreur (save_state/load_state/save_config) |
| `lib/hardware_analysis.sh` | Analyse GPU/RAM/VRAM/disques |
| `lib/backend_choice.sh` | Choix du backend d'inférence |
| `lib/plan.sh` | Construction du plan d'installation |
| `lib/models_catalog.sh` | Catalogue et sélection des modèles |
| `lib/execute_plan.sh` | Exécution des étapes du plan |
| `lib/interactive_config.sh` | `configure_infra()` — demande disque/points de montage/ports |
| `lib/full_install.sh` | Orchestration de l'installation complète |
| `lib/menus.sh` | Menus secondaires |
| `lib/update.sh` | Vérification et application des mises à jour |
| `lib/cleanup.sh` | Nettoyage complet / réinstallation |
| `lib/repair_webui.sh` | Réparation rapide Open WebUI |
| `web/dashboard_server.py` | Serveur HTTP (stdlib, zéro dépendance) |
| `web/static/{index.html,style.css,app.js}` | Interface du dashboard |

## Limites connues (non bloquantes)

- Le style de nommage des variables locales (majuscules `$VAR` au lieu de
  minuscules) vient de la V8 et n'a pas été uniformisé partout — cosmétique,
  sans impact fonctionnel.
- `shellcheck -S warning` remonte encore des faux positifs (`SC2034`,
  `SC2154`) sur les tableaux associatifs `HW`/`CFG` partagés entre fichiers
  — normal pour un projet multi-fichiers, shellcheck ne corrèle pas les
  définitions entre modules sourcés séparément.
- Les autres services systemd (`ollama.service`, `open-webui.service`,
  `ia-installer-resume.service`) restent en toutes lettres dans le code au
  lieu d'utiliser les variables `OLLAMA_SERVICE`/`OPEN_WEBUI_SERVICE`/
  `RESUME_SERVICE` ajoutées à `config/defaults.conf` — centralisation
  possible plus tard si tu veux, mais zéro impact fonctionnel aujourd'hui.

## Test recommandé avant usage réel

Comme pour toute réécriture, teste sur une VM jetable avant de lancer sur
ta machine de production :
```bash
sudo bash install_ia_local_V9.sh
```
Compare le comportement à ta V8 (menus, détection matériel, dashboard sur
le port 7842) — la logique métier n'a volontairement pas été réinventée,
seulement réorganisée et débuggée, donc le comportement doit être identique
à la V8 en mieux (bugs corrigés ci-dessus).
