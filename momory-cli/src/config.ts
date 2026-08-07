import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import yaml from "js-yaml";

export interface MomoryConfig {
  server: {
    host: string;
    port: number;
  };
  models: {
    chat: string;
    coder: string;
    embed: string;
  };
  memory: {
    enabled: boolean;
    qdrant: {
      host: string;
      port: number;
    };
  };
}

export const CONFIG_DIR = join(homedir(), ".momory");
export const CONFIG_PATH = join(CONFIG_DIR, "config.yaml");
export const DASHBOARD_PORT = 7842;

/** Valeurs par défaut proposées lors du premier lancement — jamais utilisées
 * telles quelles sans passer par l'assistant de configuration. */
export const DEFAULT_CONFIG: MomoryConfig = {
  server: { host: "127.0.0.1", port: 11434 },
  models: {
    chat: "llama3.1:8b",
    coder: "qwen2.5-coder:7b",
    embed: "nomic-embed-text",
  },
  memory: {
    enabled: true,
    qdrant: { host: "127.0.0.1", port: 6333 },
  },
};

export function configExists(): boolean {
  return existsSync(CONFIG_PATH);
}

export function loadConfig(): MomoryConfig | null {
  if (!configExists()) return null;
  try {
    const raw = readFileSync(CONFIG_PATH, "utf-8");
    const parsed = yaml.load(raw) as Partial<MomoryConfig>;
    // Fusion défensive avec les défauts pour tolérer un fichier incomplet
    // (ex: édité manuellement par l'utilisateur, ou ancienne version du schéma).
    return {
      server: { ...DEFAULT_CONFIG.server, ...parsed.server },
      models: { ...DEFAULT_CONFIG.models, ...parsed.models },
      memory: {
        ...DEFAULT_CONFIG.memory,
        ...parsed.memory,
        qdrant: { ...DEFAULT_CONFIG.memory.qdrant, ...parsed.memory?.qdrant },
      },
    };
  } catch (err) {
    throw new Error(
      `Config illisible (${CONFIG_PATH}) : ${(err as Error).message}\n` +
        `Relance "momory config --setup" pour la régénérer.`
    );
  }
}

export function saveConfig(cfg: MomoryConfig): void {
  mkdirSync(dirname(CONFIG_PATH), { recursive: true });
  const header =
    "# Configuration Momory — générée par l'assistant d'installation.\n" +
    "# Modifiable à la main, ou via `momory config --setup`.\n\n";
  writeFileSync(CONFIG_PATH, header + yaml.dump(cfg, { indent: 2 }), "utf-8");
}

export function ollamaBaseUrl(cfg: MomoryConfig): string {
  return `http://${cfg.server.host}:${cfg.server.port}`;
}
