import chalk from "chalk";
import { MomoryConfig, ollamaBaseUrl } from "./config.js";

export interface ChatMessage {
  role: "system" | "user" | "assistant" | "tool";
  content: string;
}

export interface OllamaModel {
  name: string;
  size: number;
  modified_at: string;
}

/** Vérifie que le serveur Ollama répond. Utilisé par `momory doctor`. */
export async function pingServer(
  cfg: MomoryConfig,
  timeoutMs = 3000
): Promise<{ ok: boolean; error?: string }> {
  const controller = new AbortController();
  const t = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetch(`${ollamaBaseUrl(cfg)}/api/tags`, {
      signal: controller.signal,
    });
    return { ok: res.ok, error: res.ok ? undefined : `HTTP ${res.status}` };
  } catch (err) {
    return { ok: false, error: (err as Error).message };
  } finally {
    clearTimeout(t);
  }
}

/** Liste les modèles disponibles sur le serveur Ollama configuré. */
export async function listModels(cfg: MomoryConfig): Promise<OllamaModel[]> {
  const res = await fetch(`${ollamaBaseUrl(cfg)}/api/tags`);
  if (!res.ok) throw new Error(`Serveur Ollama : HTTP ${res.status}`);
  const data = (await res.json()) as { models: OllamaModel[] };
  return data.models ?? [];
}

/**
 * Envoie une conversation au modèle et diffuse la réponse token par token
 * via onToken. Résout avec le texte complet une fois la réponse terminée.
 */
export interface ToolCallRaw {
  function: { name: string; arguments: Record<string, unknown> };
}

export interface ChatWithToolsResult {
  content: string;
  toolCalls: ToolCallRaw[];
}

/**
 * Variante non-streamée avec support des tools (function calling). Ollama
 * renvoie soit du texte (`message.content`), soit une liste d'appels d'outils
 * (`message.tool_calls`) — jamais les deux en même temps en pratique.
 */
export async function chatWithTools(
  cfg: MomoryConfig,
  model: string,
  messages: ChatMessage[],
  tools: unknown[]
): Promise<ChatWithToolsResult> {
  const call = async (think: boolean) => {
    const res = await fetch(`${ollamaBaseUrl(cfg)}/api/chat`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ model, messages, tools, think, stream: false }),
    });
    return res;
  };

  // On active la réflexion automatiquement quand le modèle la supporte.
  // Si le serveur refuse le paramètre (modèle/version incompatible), on
  // retente une seule fois sans — transparent pour l'utilisateur.
  let res = await call(true);
  if (!res.ok) {
    res = await call(false);
  }

  if (!res.ok) {
    const detail = await res.text().catch(() => "");
    throw new Error(`Le serveur Ollama a répondu HTTP ${res.status}. ${detail}`.trim());
  }

  const data = (await res.json()) as {
    message?: { content?: string; thinking?: string; tool_calls?: ToolCallRaw[] };
  };
  if (data.message?.thinking) {
    console.log(chalk.dim(`  🧠 ${data.message.thinking.trim().replace(/\n/g, "\n     ")}`));
  }
  return {
    content: data.message?.content ?? "",
    toolCalls: data.message?.tool_calls ?? [],
  };
}

export async function chatStream(
  cfg: MomoryConfig,
  model: string,
  messages: ChatMessage[],
  onToken: (token: string) => void
): Promise<string> {
  const res = await fetch(`${ollamaBaseUrl(cfg)}/api/chat`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ model, messages, stream: true }),
  });

  if (!res.ok || !res.body) {
    const detail = await res.text().catch(() => "");
    throw new Error(
      `Le serveur Ollama a répondu HTTP ${res.status}. ${detail}`.trim()
    );
  }

  const reader = res.body.getReader();
  const decoder = new TextDecoder();
  let full = "";
  let buffer = "";

  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });

    // Ollama renvoie du NDJSON : une ligne JSON complète par token/étape.
    let newlineIdx: number;
    while ((newlineIdx = buffer.indexOf("\n")) >= 0) {
      const line = buffer.slice(0, newlineIdx).trim();
      buffer = buffer.slice(newlineIdx + 1);
      if (!line) continue;
      const chunk = JSON.parse(line) as {
        message?: { content?: string };
        done?: boolean;
      };
      const token = chunk.message?.content ?? "";
      if (token) {
        full += token;
        onToken(token);
      }
    }
  }
  return full;
}
