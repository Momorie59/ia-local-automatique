import chalk from "chalk";
import { MomoryConfig } from "../config.js";
import { chatWithTools, ChatMessage } from "../ollama.js";
import { TOOL_DEFS, executeTool, ToolCall, setAutoApprove } from "../tools.js";
import { fetchServerMomoryInfo, configDrift } from "../serverConfig.js";
import { getRl } from "../rl.js";

const MAX_TOOL_ROUNDS = 12;

/** Extrait le premier objet JSON syntaxiquement complet (accolades équilibrées,
 * en respectant les chaînes) présent dans un texte, où qu'il se trouve. */
function extractJsonObjects(text: string): string[] {
  const results: string[] = [];
  let i = 0;
  while (i < text.length) {
    if (text[i] !== "{") { i++; continue; }
    let depth = 0, inString = false, escape = false;
    let j = i;
    for (; j < text.length; j++) {
      const ch = text[j];
      if (inString) {
        if (escape) escape = false;
        else if (ch === "\\") escape = true;
        else if (ch === '"') inString = false;
        continue;
      }
      if (ch === '"') { inString = true; continue; }
      if (ch === "{") depth++;
      else if (ch === "}") {
        depth--;
        if (depth === 0) { results.push(text.slice(i, j + 1)); break; }
      }
    }
    i = j + 1;
  }
  return results;
}

/**
 * Certains modèles (ex: qwen2.5-coder via certains templates Ollama) écrivent
 * l'appel d'outil en JSON texte brut dans `content` au lieu de remplir le
 * vrai champ `tool_calls` de l'API — parfois seul, parfois noyé dans de la
 * prose ("D'accord, je vais... {JSON}"). On extrait et parse ce cas en secours.
 */
function parseFallbackToolCall(
  content: string
): { name: string; arguments: Record<string, unknown> } | null {
  for (const candidate of extractJsonObjects(content)) {
    try {
      const parsed = JSON.parse(candidate);
      const fn = parsed.function ?? parsed;
      if (typeof fn?.name === "string" && fn.arguments && typeof fn.arguments === "object") {
        return { name: fn.name, arguments: fn.arguments };
      }
    } catch {
      // Pas du JSON valide à cet endroit, on essaie le suivant.
    }
  }
  return null;
}

const SYSTEM_PROMPT = `Tu es Momory, l'assistant IA personnel local de l'utilisateur — l'équivalent
local de Gemini CLI / Claude Code. Tu peux discuter normalement, ET tu as accès à des
outils pour lire, lister, créer, modifier, supprimer et télécharger (depuis une URL)
des fichiers du dossier dans lequel tu es lancé (jamais en dehors).

Règles impératives :
- N'utilise les outils fichiers QUE quand la demande porte vraiment sur le projet/les
  fichiers courants (lire, corriger, créer, analyser du code...). Pour une question
  générale ou une simple discussion, réponds directement en texte, sans outil.
- Explore toujours le projet (list_dir, read_file) avant de proposer une modification
  si tu n'as pas encore assez de contexte.
- N'utilise write_file/delete_file que pour de vrais changements utiles — jamais pour
  "essayer". L'utilisateur voit un diff et doit confirmer chaque écriture/suppression :
  ce n'est donc jamais toi qui décides seul, mais explique clairement ce que tu proposes
  et pourquoi avant de le faire.
- Réponds en français, de façon directe et utile.
- Une fois les modifications faites (ou refusées), résume ce qui a changé.`;

export async function runAssistant(cfg: MomoryConfig): Promise<void> {
  const rl = getRl();
  console.log(
    chalk.bold(`\nMomory`) +
      chalk.dim(`  (modèle: ${cfg.models.coder} · ${cfg.server.host}:${cfg.server.port})`)
  );
  console.log(chalk.dim(`Répertoire : ${process.cwd()}`));

  // Vérification rapide (non bloquante si le serveur ne répond pas) : des
  // mises à jour de modèle (ou de config) sont-elles disponibles sur le serveur ?
  try {
    const serverInfo = await fetchServerMomoryInfo(cfg.server.host, 1500);
    const diffs = configDrift(cfg, serverInfo);
    if (diffs.length > 0) {
      console.log(chalk.yellow("\n💡 Des mises à jour de modèle IA sont disponibles sur le serveur :"));
      for (const d of diffs) console.log(chalk.yellow(`  • ${d}`));
      console.log(chalk.dim(`  → Pour mettre à jour : momory config --auto ${cfg.server.host}\n`));
    }
  } catch {
    // Dashboard injoignable/pas encore à jour : on ignore silencieusement,
    // ce n'est qu'une vérification de confort, pas une dépendance dure.
  }

  const auto = await rl.question(
    chalk.yellow(
      "  >>> Autoriser Momory à créer/modifier/supprimer des fichiers sans " +
        "redemander confirmation à chaque fois, pour cette session ? [oui/NON] : "
    )
  );
  setAutoApprove(/^oui$/i.test(auto.trim()));
  if (/^oui$/i.test(auto.trim())) {
    console.log(
      chalk.dim(
        "  → Auto-approuvé pour cette session (chaque action reste affichée, " +
          "mais plus de confirmation individuelle). Relance sans répondre 'oui' pour repasser en mode confirmé.\n"
      )
    );
  } else {
    console.log("");
  }
  console.log(chalk.dim('Tape "exit" ou Ctrl+D pour quitter.\n'));

  const history: ChatMessage[] = [{ role: "system", content: SYSTEM_PROMPT }];

  for (;;) {
    let userInput: string;
    try {
      userInput = await rl.question(chalk.cyan("› "));
    } catch {
      break;
    }
    const trimmed = userInput.trim();
    if (!trimmed) continue;
    if (["exit", "quit", "q"].includes(trimmed.toLowerCase())) break;

    history.push({ role: "user", content: trimmed });

    try {
      await runToolLoop(cfg, history);
    } catch (err) {
      console.log(chalk.red(`\n✗ ${(err as Error).message}`));
      console.log(chalk.dim("  (momory doctor pour vérifier la connexion au serveur)"));
      history.pop();
    }
  }

  rl.close();
  console.log(chalk.dim("\nÀ bientôt.\n"));
}

/** Boucle d'appels d'outils : le modèle peut enchaîner plusieurs actions
 * (lire, puis proposer une écriture, puis relire, etc.) avant sa réponse finale. */
async function runToolLoop(cfg: MomoryConfig, history: ChatMessage[]): Promise<void> {
  for (let round = 0; round < MAX_TOOL_ROUNDS; round++) {
    const result = await chatWithTools(cfg, cfg.models.coder, history, TOOL_DEFS);

    if (result.toolCalls.length === 0) {
      const fallback = parseFallbackToolCall(result.content);
      if (fallback) {
        // Affiche la prose du modèle (avant le JSON) pour la transparence,
        // sans montrer le bloc JSON brut lui-même à l'utilisateur.
        const prose = result.content.split(/\{/)[0].trim();
        if (prose) console.log(chalk.dim("Momory: ") + prose);
        console.log(chalk.dim(`  🔧 outil détecté (format texte) : ${fallback.name}`));
        history.push({ role: "assistant", content: result.content });
        const toolResult = await executeTool(fallback);
        history.push({ role: "tool", content: `[${toolResult.name}] ${toolResult.content}` });
        continue;
      }

      // Réponse finale en texte — fin du tour. Normal pour une simple
      // discussion (le modèle n'a pas besoin d'outil pour ça).
      console.log(chalk.dim("Momory: ") + result.content + "\n");
      history.push({ role: "assistant", content: result.content });
      return;
    }

    console.log(chalk.dim(`  🔧 ${result.toolCalls.length} outil(s) appelé(s) : ${result.toolCalls.map(t=>t.function.name).join(", ")}`));

    // Le modèle veut utiliser un ou plusieurs outils.
    history.push({
      role: "assistant",
      content: result.content || "(appel d'outil)",
    });

    for (const raw of result.toolCalls) {
      const call: ToolCall = { name: raw.function.name, arguments: raw.function.arguments };
      const toolResult = await executeTool(call);
      history.push({
        role: "tool",
        content: `[${toolResult.name}] ${toolResult.content}`,
      });
    }
  }

  console.log(
    chalk.yellow(
      `\n⚠ Trop d'étapes enchaînées (${MAX_TOOL_ROUNDS}) — arrêt de sécurité. Précise ta demande.\n`
    )
  );
}
