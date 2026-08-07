# Momory CLI

Assistant IA personnel local — équivalent local de Gemini CLI / Claude Code,
entièrement contrôlé par vous et connecté à votre propre serveur IA (Ollama).

## Statut

Étape 1/N : squelette CLI + configuration + mode conversation. Voir
[roadmap](#roadmap) pour la suite.

## Installation (développement local)

```bash
npm install
npm run build
npm link          # rend la commande `momory` disponible globalement
```

## Premier lancement

```bash
momory
```

Aucune configuration n'existe encore → l'assistant de configuration se lance
automatiquement : adresse du serveur, port, modèles. Le résultat est écrit
dans `~/.momory/config.yaml`.

## Commandes disponibles

| Commande | Rôle |
|---|---|
| `momory` / `momory chat` | Conversation avec le modèle configuré (streaming) |
| `momory doctor` | Diagnostic : config, serveur, modèles présents/absents |
| `momory config` | Afficher la configuration actuelle |
| `momory config --setup` | Relancer l'assistant de configuration |
| `momory models` | Lister les modèles disponibles sur le serveur |

Prévues, pas encore implémentées : `momory code`, `momory analyse <chemin>`,
`momory remember <fichier>`.

## Configuration

`~/.momory/config.yaml` :

```yaml
server:
  host: 192.168.1.16
  port: 11434
models:
  chat: llama3.1:8b
  coder: qwen2.5-coder:7b
  embed: nomic-embed-text
memory:
  enabled: true
  qdrant:
    host: 192.168.1.16
    port: 6333
```

Aucune valeur n'est codée en dur dans le code — tout passe par ce fichier,
régénérable via `momory config --setup`.

## Architecture du code

```
src/
  index.ts              Point d'entrée CLI (commander), routage des commandes
  config.ts              Lecture/écriture de ~/.momory/config.yaml
  ollama.ts               Client Ollama (ping, liste modèles, chat en streaming)
  commands/
    setup.ts              Assistant de configuration (premier lancement / --setup)
    chat.ts                Mode conversation (REPL, streaming token par token)
    doctor.ts              Diagnostic
    models.ts              Liste des modèles
    configCmd.ts           Affichage de la configuration
```

## Roadmap

1. ✅ Squelette CLI + config + conversation de base
2. ⬜ `momory code` — analyse de projet + proposition de patch avec validation
3. ⬜ Mémoire longue durée (Qdrant + embeddings + RAG)
4. ⬜ Système multi-agents (Momory-Core, Momory-Code, Momory-NAS, Momory-Home, Momory-Admin)
5. ⬜ Publication npm (`npm install -g momory-cli`)
