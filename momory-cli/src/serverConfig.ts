import { DASHBOARD_PORT, MomoryConfig } from "./config.js";

export interface ServerMomoryInfo {
  host: string;
  port: number;
  chat_model: string | null;
  coder_model: string | null;
  qdrant_port?: number;
}

/** Interroge le dashboard du serveur (ia-local-automatique) pour récupérer
 * la config Momory prête à l'emploi, calculée côté serveur. */
export async function fetchServerMomoryInfo(
  dashboardHost: string,
  timeoutMs = 4000
): Promise<ServerMomoryInfo> {
  const controller = new AbortController();
  const t = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetch(`http://${dashboardHost}:${DASHBOARD_PORT}/api/stats`, {
      signal: controller.signal,
    });
    if (!res.ok) throw new Error(`Dashboard injoignable : HTTP ${res.status}`);
    const data = (await res.json()) as { momory?: ServerMomoryInfo };
    if (!data.momory) throw new Error("Le dashboard ne renvoie pas d'infos Momory (version du serveur trop ancienne ?).");
    return data.momory;
  } catch (err) {
    if ((err as Error).name === "AbortError") {
      throw new Error(`Aucune réponse du dashboard à http://${dashboardHost}:${DASHBOARD_PORT} (délai dépassé).`);
    }
    throw new Error(`Impossible de joindre le dashboard du serveur (${dashboardHost}:${DASHBOARD_PORT}) : ${(err as Error).message}`);
  } finally {
    clearTimeout(t);
  }
}

export function serverInfoToConfig(info: ServerMomoryInfo, existing?: MomoryConfig): MomoryConfig {
  return {
    server: { host: info.host, port: info.port },
    models: {
      chat: info.chat_model || existing?.models.chat || "llama3.1:8b",
      coder: info.coder_model || existing?.models.coder || "qwen2.5-coder:7b",
      embed: existing?.models.embed || "nomic-embed-text",
    },
    memory: {
      enabled: !!info.qdrant_port,
      qdrant: {
        host: info.host,
        port: info.qdrant_port || existing?.memory.qdrant.port || 6333,
      },
    },
  };
}

/** Compare la config locale à l'état actuel du serveur — retourne une liste
 * de différences lisibles, vide si tout est déjà à jour. */
export function configDrift(local: MomoryConfig, server: ServerMomoryInfo): string[] {
  const diffs: string[] = [];
  if (local.server.host !== server.host) {
    diffs.push(`Adresse serveur : ${local.server.host} → ${server.host}`);
  }
  if (server.chat_model && local.models.chat !== server.chat_model) {
    diffs.push(`Modèle chat : ${local.models.chat} → ${server.chat_model}`);
  }
  if (server.coder_model && local.models.coder !== server.coder_model) {
    diffs.push(`Modèle coder : ${local.models.coder} → ${server.coder_model}`);
  }
  const serverHasQdrant = !!server.qdrant_port;
  if (serverHasQdrant && !local.memory.enabled) {
    diffs.push(`Qdrant maintenant disponible sur le serveur (port ${server.qdrant_port}) mais pas activé localement`);
  }
  if (serverHasQdrant && local.memory.enabled && local.memory.qdrant.port !== server.qdrant_port) {
    diffs.push(`Port Qdrant : ${local.memory.qdrant.port} → ${server.qdrant_port}`);
  }
  return diffs;
}
