<div align="center">

<img src="assets/logo.svg" alt="Logo Momory" width="120" height="120">

# Momory · IA Local

**Ton infrastructure IA locale, entièrement privée, avec son propre assistant CLI.**

Installe un serveur IA complet (Ollama, Open WebUI, Qdrant, dashboard web) sur ta machine,
puis pilote-le depuis n'importe où avec **Momory CLI** — ton équivalent local de
Gemini CLI / Claude Code, connecté à ton serveur, pas à un cloud.

[![Bash](https://img.shields.io/badge/bash-5.x-4EAA25?logo=gnubash&logoColor=white)](.)
[![Python](https://img.shields.io/badge/python-3-3776AB?logo=python&logoColor=white)](.)
[![TypeScript](https://img.shields.io/badge/node-%3E%3D18-339933?logo=nodedotjs&logoColor=white)](.)
[![License](https://img.shields.io/badge/license-GPL--3.0-blue)](LICENSE.md)

</div>

---

## ✨ Ce que tu obtiens

| | |
|---|---|
| 🖥️ **Installeur intelligent** | Détecte ton matériel (CPU/GPU/RAM/disques), choisit le meilleur backend, construit un plan d'installation sur mesure |
| 🦙 **Ollama + Open WebUI** | Moteur d'inférence local + interface de chat web, GPU NVIDIA/AMD ou CPU fallback |
| 🧩 **Qdrant** | Base vectorielle en option, pour la mémoire longue durée / RAG |
| 📊 **Dashboard web** | Stats temps réel (CPU/RAM/GPU/réseau), gestion des modèles, logs, installation pilotable depuis le navigateur — **annulable en un clic** |
| ⚡ **Suivi énergie** | Consommation instantanée (mesure réelle CPU/GPU, estimée pour le reste), historique 24h/7j/30j, coût en € selon ton tarif |
| 📝 **Notes intégrées** | Bloc-notes du dashboard avec corbeille (suppression récupérable, vidage explicite) |
| 🤖 **Momory CLI** | Assistant IA en ligne de commande — discute, lit/écrit/supprime/télécharge des fichiers dans ton projet, avec confirmation systématique |
| 📱 **Momory Android** | App mobile (chat + vocal complet) pour parler à ton IA depuis ton téléphone — [dépôt séparé](https://github.com/Momorie59/MomoryAndroid), APK prêt à installer |
| 🔁 **Reprise automatique** | Coupure de courant, reboot, erreur réseau — l'installation reprend là où elle s'est arrêtée |

---

## 🚀 Installation du serveur

Le dépôt contient l'archive `momory-ia-local.zip` — télécharge-la et lance l'installeur :

```bash
wget https://github.com/Momorie59/ia-local-automatique/raw/main/momory-ia-local.zip
unzip momory-ia-local.zip
cd momory-ia-local
chmod +x Momory-ia_local_v9.sh
sudo bash Momory-ia_local_v9.sh
```
ou
```bash
git clone https://github.com/Momorie59/ia-local-automatique.git
cd ia-local-automatique
sudo bash Momory-ia_local_v9.sh
```

*(`curl -LO ...` fonctionne aussi si `wget` n'est pas installé.)*

Ou manuellement : ouvre le dépôt sur GitHub, clique sur `momory-ia-local.zip` puis
**Download**, décompresse l'archive, et lance la commande `sudo bash Momory-ia_local_v9.sh`
depuis le dossier extrait.

Le script analyse ta machine, te propose un plan d'installation, et te guide pas à pas
(confirmation avant chaque action sensible — jamais d'accès système silencieux).

Une fois terminé, le dashboard est accessible sur `http://<IP-du-serveur>:7842`.

## 💻 Installation de Momory CLI (sur ta machine de tous les jours)

Directement depuis le dashboard web (onglet **Accès & Notes**) — bouton de téléchargement
+ commande prête à copier, adaptée à ton OS.

Ou depuis le dépôt GitHub (même zip que pour le serveur, `momory-cli/` est dedans) :

```bash
# Linux / Mac
wget https://github.com/Momorie59/ia-local-automatique/raw/main/momory-ia-local.zip
unzip momory-ia-local.zip && cd momory-ia-local/momory-cli
npm install && npm run build && npm link
```

```powershell
# Windows (PowerShell)
Invoke-WebRequest https://github.com/Momorie59/ia-local-automatique/raw/main/momory-ia-local.zip -OutFile momory-ia-local.zip
Expand-Archive momory-ia-local.zip -Force; cd momory-ia-local/momory-cli
npm install; npm run build; npm link
```

Puis connecte-le à ton serveur — la config se récupère automatiquement, rien à taper à la main :

```bash
momory config --auto 192.168.1.16
momory
```

---

## 🧠 Momory CLI — usage

```
momory
```

Une seule commande pour tout : discussion normale **et** actions sur tes fichiers, selon
ce que tu demandes — pas besoin de choisir un mode.

```
› crée un fichier hello.sh qui affiche "hello world"

  🔧 outil détecté : write_file

📝 Momory propose de créer : ./hello.sh
+ #!/bin/bash
+ echo "hello world"
  >>> Appliquer cette création ? [oui/NON] :
```

- **Lecture, création, modification, suppression, téléchargement** de fichiers — toujours
  avec diff affiché et confirmation (ou auto-approbation activable une fois par session)
- **Réflexion visible** automatique si le modèle la supporte
- **Détection de dérive** : si la config du serveur change (nouveau modèle, Qdrant installé...),
  Momory te prévient au démarrage avec la commande exacte pour te resynchroniser
- Protection anti-évasion : impossible de toucher un fichier hors du dossier courant

Autres commandes : `momory doctor` (diagnostic), `momory models` (modèles disponibles),
`momory config --setup` (configuration manuelle).

---

## 📱 Application Android

Dépôt séparé : **[github.com/Momorie59/MomoryAndroid](https://github.com/Momorie59/MomoryAndroid)**

Un `Momory.apk` prêt à installer y est disponible directement — pas besoin de compiler
avec Android Studio. Télécharge-le sur ton téléphone et installe-le (autorise
"sources inconnues" si Android le demande).

L'app permet de discuter avec ton IA en texte **ou entièrement à la voix** (tu parles,
elle transcrit, répond, et te lit sa réponse à voix haute), avec la même configuration
automatique que le CLI : entre juste l'IP de ton serveur, le reste se récupère tout seul
depuis le dashboard.

---

## 📂 Structure du projet

```
Momory-ia_local_v9.sh    Point d'entrée — orchestration, reprise après erreur/reboot
config/defaults.conf     Constantes centralisées (ports, chemins d'état, TTL...)
lib/                     Modules bash (un fichier = une responsabilité)
  ├─ common.sh             Logging, privilèges, configuration
  ├─ os_detect.sh           Détection distro + abstraction paquets/services
  ├─ hardware_analysis.sh   Analyse GPU/RAM/VRAM/disques
  ├─ execute_plan.sh        Exécution des étapes d'installation
  ├─ dashboard.sh           Déploiement du dashboard web + service systemd
  └─ ...
web/                     Dashboard web
  ├─ dashboard_server.py   Serveur HTTP (Python stdlib, zéro dépendance)
  └─ static/                HTML/CSS/JS
momory-cli/              Assistant IA en ligne de commande (TypeScript/Node)
```

## 🖥️ Distributions supportées

Ubuntu · Pop!_OS · Debian · Fedora · Arch · openSUSE · Void · Alpine — toute distro
Linux x86_64/arm64. GPU NVIDIA (CUDA), AMD (ROCm), ou CPU.

## 🛠️ Commandes utiles

### Menu principal du script

Une fois installé, relance simplement `sudo bash Momory-ia_local_v9.sh` (ou le lien créé
dans ton `$HOME` : `sudo bash ~/Momory-ia_local_v9.sh`) pour retrouver ce menu :

| Touche | Action |
|---|---|
| `1` | Installation complète |
| `2` | Gérer les modèles IA |
| `3` | Vérifier & appliquer les mises à jour |
| `4` | Réinstaller un composant (drivers, Docker, Ollama, WebUI, Dashboard, Qdrant) |
| `5` | État du système |
| `6` | Nettoyage complet (clean install) |
| `7` | Réparer Open WebUI ← si conversations perdues ou modèles inaccessibles |
| `8` | Voir les logs |
| `s` | Stats système en temps réel (CPU · RAM · GPU · Services · Réseau) |
| `d` | Ouvrir/relancer le dashboard web |
| `0` | Effacer l'état d'erreur ← si tout fonctionne mais une erreur reste affichée |
| `9` | Quitter |

### Services (systemd)

```bash
# État / logs
sudo systemctl status ollama
sudo systemctl status ia-dashboard
sudo journalctl -u ollama -n 50 --no-pager

# Redémarrer
sudo systemctl restart ollama
sudo systemctl restart ia-dashboard

# Conteneurs Docker (Open WebUI, Qdrant)
docker ps
docker logs open-webui
docker restart open-webui
docker logs qdrant
docker restart qdrant
```

### Ollama

```bash
ollama list                 # modèles installés
ollama pull <modèle>        # télécharger un modèle
ollama rm <modèle>          # supprimer un modèle
ollama ps                   # modèles actuellement chargés en mémoire
```

### Logs du script

```bash
sudo tail -80 /var/log/ia-installer/install-latest.log
sudo grep -n "ERR\|error\|introuvable" /var/log/ia-installer/install-latest.log
```

### Momory CLI

```bash
momory                      # lancer l'assistant (chat + fichiers + vocal via l'app Android)
momory doctor                # diagnostic (config, serveur, modèles)
momory models                 # modèles disponibles sur le serveur
momory config --auto <ip>      # config automatique depuis le dashboard
momory config --setup           # configuration manuelle
```

## 🔒 Sécurité

Aucun accès système sans confirmation explicite. Chaque action sensible (installation,
modification de fichier, suppression) est affichée avant d'être appliquée — en terminal
et dans le dashboard web, où tu peux valider Oui/Non à distance.

Identifiants par défaut du dashboard (onglet ⚙️ Administration) : `admin` /
`ia-local-admin` — **à changer dès la première connexion**, ce mot de passe par défaut
est visible dans le code source.

## 🆘 Dépannage

**Mot de passe du dashboard oublié** — pas besoin de le retrouver, il suffit de
réinitialiser aux identifiants par défaut directement sur le serveur :

```bash
sudo rm /var/lib/ia-installer/admin-credentials
sudo systemctl restart ia-dashboard
```

Reconnecte-toi avec `admin` / `ia-local-admin`, puis change-le immédiatement dans
l'onglet Administration → Sécurité.

## 📜 Licence

Voir [LICENSE.md](LICENSE.md).

---

<div align="center">
<sub>Développé pour tourner entièrement en local — aucune donnée n'envoie vers un cloud tiers.</sub>
</div>
