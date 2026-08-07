<div align="center">

# 🧠 Momory · IA Local

**Ton infrastructure IA locale, entièrement privée, avec son propre assistant CLI.**

Installe un serveur IA complet (Ollama, Open WebUI, Qdrant, dashboard web) sur ta machine,
puis pilote-le depuis n'importe où avec **Momory CLI** — ton équivalent local de
Gemini CLI / Claude Code, connecté à ton serveur, pas à un cloud.

[![Bash](https://img.shields.io/badge/bash-5.x-4EAA25?logo=gnubash&logoColor=white)](.)
[![Python](https://img.shields.io/badge/python-3-3776AB?logo=python&logoColor=white)](.)
[![TypeScript](https://img.shields.io/badge/node-%3E%3D18-339933?logo=nodedotjs&logoColor=white)](.)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE.md)

</div>

---

## ✨ Ce que tu obtiens

| | |
|---|---|
| 🖥️ **Installeur intelligent** | Détecte ton matériel (CPU/GPU/RAM/disques), choisit le meilleur backend, construit un plan d'installation sur mesure |
| 🦙 **Ollama + Open WebUI** | Moteur d'inférence local + interface de chat web, GPU NVIDIA/AMD ou CPU fallback |
| 🧩 **Qdrant** | Base vectorielle en option, pour la mémoire longue durée / RAG |
| 📊 **Dashboard web** | Stats temps réel (CPU/RAM/GPU/réseau), gestion des modèles, logs, installation pilotable depuis le navigateur — **annulable en un clic** |
| 📝 **Notes intégrées** | Bloc-notes du dashboard avec corbeille (suppression récupérable, vidage explicite) |
| 🤖 **Momory CLI** | Assistant IA en ligne de commande — discute, lit/écrit/supprime/télécharge des fichiers dans ton projet, avec confirmation systématique |
| 🔁 **Reprise automatique** | Coupure de courant, reboot, erreur réseau — l'installation reprend là où elle s'est arrêtée |

---

## 🚀 Installation du serveur

```bash
git clone https://github.com/Momorie59/ia-local-automatique.git
cd ia-local-automatique
sudo bash Momory-ia_local_v9.sh
```

Le script analyse ta machine, te propose un plan d'installation, et te guide pas à pas
(confirmation avant chaque action sensible — jamais d'accès système silencieux).

Une fois terminé, le dashboard est accessible sur `http://<IP-du-serveur>:7842`.

## 💻 Installation de Momory CLI (sur ta machine de tous les jours)

Directement depuis le dashboard web (onglet **Accès & Notes**) — bouton de téléchargement
+ commande prête à copier, adaptée à ton OS.

Ou en ligne de commande :

```bash
# Linux / Mac
git clone https://github.com/Momorie59/ia-local-automatique.git
cd ia-local-automatique/momory-cli
npm install && npm run build && npm link
```

```powershell
# Windows (PowerShell)
git clone https://github.com/Momorie59/ia-local-automatique.git
cd ia-local-automatique/momory-cli
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

## 🔒 Sécurité

Aucun accès système sans confirmation explicite. Chaque action sensible (installation,
modification de fichier, suppression) est affichée avant d'être appliquée — en terminal
et dans le dashboard web, où tu peux valider Oui/Non à distance.

## 📜 Licence

Voir [LICENSE.md](LICENSE.md).

---

<div align="center">
<sub>Développé pour tourner entièrement en local — aucune donnée n'envoie vers un cloud tiers.</sub>
</div>
