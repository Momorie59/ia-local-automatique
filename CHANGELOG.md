# Changelog — ia-local

Toutes les modifications notables de ce projet sont documentées ici.
Format basé sur [Keep a Changelog](https://keepachangelog.com/fr/1.0.0/).

---

## [V9] — 2026-03-02

### Corrigé
- **`menu_status()` — `gpu_brand: unbound variable` (ligne 6718)**
  La fonction `menu_status()` pouvait être appelée directement depuis le menu
  principal sans que le tableau associatif `HW[]` ait été initialisé au préalable
  par `analyse_hardware()`. Cela provoquait une erreur Bash fatale :
  ```
  /run/media/.../install_ia_local_V8.sh: line 6718: gpu_brand: unbound variable
  ```
  **Correction** : ajout d'un bloc de détection GPU légère et silencieuse en
  début de `menu_status()`. Si `HW[gpu_brand]` n'est pas défini, le bloc
  interroge `lspci` pour détecter NVIDIA, AMD ou Intel Arc et initialise les
  clés minimales (`gpu_brand`, `gpu_model`) sans déclencher l'affichage verbeux
  de `analyse_hardware()`.

### Modifié
- En-tête du script mis à jour : `install_ia_local_V8.sh` → `install_ia_local_V9.sh`

---

## [V8] — antérieur

### Ajouté
- Détection matérielle complète via `analyse_hardware()` (CPU, RAM, GPU NVIDIA/AMD/Intel)
- Gestion multi-distro : Arch/CachyOS, Debian/Ubuntu, Fedora, OpenSUSE, Alpine
- Installation automatique Docker + Ollama + Open-WebUI
- Menu interactif : installation, mise à jour, désinstallation, état du système
- Support GPU : CUDA (NVIDIA), ROCm (AMD), CPU fallback
- Configuration persistante via fichier CFG
- Vérification d'intégrité SHA256 du script
- Menus : `menu_install`, `menu_reinstall`, `menu_updates`, `menu_status`, `menu_uninstall`
- Affichage état en temps réel : services, modèles Ollama, disques, RAM/Swap
- Support réseau LAN Ollama (exposition `0.0.0.0`)
- Licence GNU GPL v3
