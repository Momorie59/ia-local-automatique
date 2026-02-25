# IA Local Installer v8 – Installation intelligente d'une IA locale complète

[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0)
[![Tested on](https://img.shields.io/badge/Tested%20on-Ubuntu%20%7C%20Pop!_OS%20%7C%20Fedora%20%7C%20Arch%20%7C%20Debian-brightgreen)](https://github.com/Momorie59/ia-local-automatique)
[![Current version](https://img.shields.io/badge/version-v8.0-orange)](https://github.com/Momorie59/ia-local-Automatique)

**Installe en une seule commande une stack IA locale moderne et performante :**
Ollama + Open WebUI + (éventuellement Docker)  
→ interface web élégante, modèles locaux, GPU accéléré (NVIDIA / AMD / Intel)

## ✨ Fonctionnalités principales

- **Détection automatique** du matériel (GPU NVIDIA/AMD/Intel, RAM, VRAM)
- **Choix intelligent** du backend et des pilotes en fonction de la config
- **Installation multi-distro** : Ubuntu, Pop!_OS, Debian, Fedora, Arch, openSUSE, Void, Alpine…
- **Interface web complète** (port 7842) avec :
  - progression en direct
  - stats CPU/GPU/RAM/disque
  - gestion des modèles
  - administration (changement mot de passe, redémarrages…)
- **Reprise après reboot / erreur** grâce à systemd
- **Réparation rapide** d’Open WebUI en cas de perte de données après mise à jour
- **Sauvegardes automatiques** avant mises à jour majeures
- **Mode dry-run** pour tester sans rien casser

## Prérequis

- Linux x86_64 ou arm64 (Raspberry Pi 5 / Orange Pi 5+ support partiel)
- **Accès root** (sudo)
- Connexion internet (au moins pour la première installation)
- Espace disque recommandé : 2 disques: 1 Systeme et 1 pour les modeles **≥ 100 Go** libres (modèles + cache)

<img width="658" height="630" alt="image" src="https://github.com/user-attachments/assets/a26f29e2-f79e-499e-b480-8a3f7cdd5986" />

<img width="1656" height="741" alt="image" src="https://github.com/user-attachments/assets/65c61fa2-c378-4e8f-bcc0-d0a2d97727a9" />

<img width="1673" height="536" alt="image" src="https://github.com/user-attachments/assets/122d288d-7fdf-406e-8e51-74d0d6977dcd" />

## Installation en 1 ligne

```bash
# Méthode recommandée (la plus simple)
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Momorie59/ia-local-automatique/main/install_ia_local_V8.sh)"


