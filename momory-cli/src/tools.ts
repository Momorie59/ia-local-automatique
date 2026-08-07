import chalk from "chalk";
import { existsSync, mkdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { readdirSync } from "node:fs";
import { dirname, relative, resolve } from "node:path";
import { lineDiff } from "./diff.js";
import { getRl } from "./rl.js";

/** Racine du projet courant — toute opération fichier doit rester dedans. */
const PROJECT_ROOT = process.cwd();

/** Schémas des outils exposés au modèle, format compatible API "tools" d'Ollama. */
export const TOOL_DEFS = [
  {
    type: "function",
    function: {
      name: "list_dir",
      description:
        "Liste les fichiers et dossiers d'un répertoire du projet courant.",
      parameters: {
        type: "object",
        properties: {
          path: {
            type: "string",
            description: "Chemin relatif au projet (ex: '.', 'src')",
          },
        },
        required: ["path"],
      },
    },
  },
  {
    type: "function",
    function: {
      name: "read_file",
      description: "Lit le contenu complet d'un fichier du projet courant.",
      parameters: {
        type: "object",
        properties: {
          path: { type: "string", description: "Chemin relatif au projet" },
        },
        required: ["path"],
      },
    },
  },
  {
    type: "function",
    function: {
      name: "write_file",
      description:
        "Crée ou remplace un fichier avec le contenu donné. Le diff est affiché et " +
        "l'utilisateur doit confirmer avant toute écriture réelle.",
      parameters: {
        type: "object",
        properties: {
          path: { type: "string", description: "Chemin relatif au projet" },
          content: { type: "string", description: "Contenu complet du fichier" },
        },
        required: ["path", "content"],
      },
    },
  },
  {
    type: "function",
    function: {
      name: "download_file",
      description:
        "Télécharge un fichier depuis une URL et l'enregistre dans le projet courant.",
      parameters: {
        type: "object",
        properties: {
          url: { type: "string", description: "URL du fichier à télécharger (http/https)" },
          path: {
            type: "string",
            description: "Chemin relatif où enregistrer le fichier dans le projet",
          },
        },
        required: ["url", "path"],
      },
    },
  },
  {
    type: "function",
    function: {
      name: "delete_file",
      description:
        "Supprime un fichier du projet. Demande toujours confirmation avant suppression.",
      parameters: {
        type: "object",
        properties: {
          path: { type: "string", description: "Chemin relatif au projet" },
        },
        required: ["path"],
      },
    },
  },
];

export interface ToolCall {
  name: string;
  arguments: Record<string, unknown>;
}

export interface ToolResult {
  name: string;
  content: string;
}

/** Résout un chemin relatif fourni par le modèle et refuse toute sortie du projet. */
function safeResolve(userPath: string): string {
  const abs = resolve(PROJECT_ROOT, userPath);
  const rel = relative(PROJECT_ROOT, abs);
  if (rel.startsWith("..") || /^[A-Za-z]:/.test(rel)) {
    throw new Error(
      `Chemin refusé (hors du projet) : ${userPath}. ` +
        `Momory ne touche jamais à des fichiers en dehors du dossier courant.`
    );
  }
  return abs;
}

let autoApprove = false;
export function setAutoApprove(value: boolean): void {
  autoApprove = value;
}

async function askConfirm(question: string): Promise<boolean> {
  if (autoApprove) {
    console.log(chalk.dim(`  (auto-approuvé — ${question})`));
    return true;
  }
  const answer = await getRl().question(chalk.yellow(`  >>> ${question} [oui/NON] : `));
  return /^oui$/i.test(answer.trim());
}

/** Exécute un appel d'outil demandé par le modèle. Les écritures/suppressions
 * sont TOUJOURS confirmées par l'utilisateur avant d'avoir le moindre effet. */
export async function executeTool(call: ToolCall): Promise<ToolResult> {
  try {
    switch (call.name) {
      case "list_dir": {
        const dir = safeResolve(String(call.arguments.path ?? "."));
        if (!existsSync(dir)) return { name: call.name, content: "Dossier introuvable." };
        const entries = readdirSync(dir, { withFileTypes: true })
          .filter((e) => !e.name.startsWith(".") && e.name !== "node_modules")
          .map((e) => (e.isDirectory() ? `${e.name}/` : e.name));
        return { name: call.name, content: entries.join("\n") || "(vide)" };
      }

      case "read_file": {
        const file = safeResolve(String(call.arguments.path));
        if (!existsSync(file) || !statSync(file).isFile()) {
          return { name: call.name, content: "Fichier introuvable." };
        }
        const content = readFileSync(file, "utf-8");
        // Tronqué pour ne pas exploser le contexte du modèle sur un gros fichier.
        return {
          name: call.name,
          content: content.length > 8000 ? content.slice(0, 8000) + "\n[…tronqué…]" : content,
        };
      }

      case "write_file": {
        const relPath = String(call.arguments.path);
        const file = safeResolve(relPath);
        const newContent = String(call.arguments.content ?? "");
        const existed = existsSync(file);
        const oldContent = existed ? readFileSync(file, "utf-8") : "";

        console.log(
          chalk.bold(`\n📝 Momory propose de ${existed ? "modifier" : "créer"} : `) +
            chalk.cyan(relPath)
        );
        console.log(lineDiff(oldContent, newContent) || chalk.dim("  (aucun changement)"));

        const ok = await askConfirm(`Appliquer cette ${existed ? "modification" : "création"} ?`);
        if (!ok) {
          return { name: call.name, content: "Refusé par l'utilisateur — fichier inchangé." };
        }
        mkdirSync(dirname(file), { recursive: true });
        writeFileSync(file, newContent, "utf-8");
        console.log(chalk.green(`  ✓ ${relPath} ${existed ? "modifié" : "créé"}.`));
        return { name: call.name, content: `Écrit avec succès : ${relPath}` };
      }

      case "download_file": {
        const relPath = String(call.arguments.path);
        const url = String(call.arguments.url ?? "");
        const file = safeResolve(relPath);

        let parsed: URL;
        try {
          parsed = new URL(url);
        } catch {
          return { name: call.name, content: "URL invalide." };
        }
        if (!["http:", "https:"].includes(parsed.protocol)) {
          return { name: call.name, content: "Seuls http/https sont autorisés." };
        }

        console.log(chalk.bold(`\n⬇  Momory propose de télécharger : `) + chalk.cyan(url));
        console.log(chalk.dim(`   vers : ${relPath}`));
        const ok = await askConfirm("Lancer ce téléchargement ?");
        if (!ok) {
          return { name: call.name, content: "Refusé par l'utilisateur — rien téléchargé." };
        }

        const MAX_BYTES = 50 * 1024 * 1024; // 50 Mo — raisonnable pour un usage projet
        const controller = new AbortController();
        const timeout = setTimeout(() => controller.abort(), 30000);
        try {
          const res = await fetch(url, { signal: controller.signal });
          if (!res.ok || !res.body) {
            return { name: call.name, content: `Échec du téléchargement : HTTP ${res.status}` };
          }
          const len = Number(res.headers.get("content-length") ?? 0);
          if (len > MAX_BYTES) {
            return {
              name: call.name,
              content: `Fichier trop volumineux (${(len / 1024 / 1024).toFixed(1)} Mo, limite 50 Mo).`,
            };
          }
          const buf = Buffer.from(await res.arrayBuffer());
          if (buf.length > MAX_BYTES) {
            return { name: call.name, content: "Fichier trop volumineux (limite 50 Mo)." };
          }
          mkdirSync(dirname(file), { recursive: true });
          writeFileSync(file, buf);
          console.log(chalk.green(`  ✓ ${relPath} téléchargé (${(buf.length / 1024).toFixed(1)} Ko).`));
          return { name: call.name, content: `Téléchargé avec succès : ${relPath} (${buf.length} octets)` };
        } catch (err) {
          return { name: call.name, content: `Erreur de téléchargement : ${(err as Error).message}` };
        } finally {
          clearTimeout(timeout);
        }
      }

      case "delete_file": {
        const relPath = String(call.arguments.path);
        const file = safeResolve(relPath);
        if (!existsSync(file)) {
          return { name: call.name, content: "Fichier déjà inexistant." };
        }
        console.log(chalk.bold(`\n🗑  Momory propose de supprimer : `) + chalk.red(relPath));
        const ok = await askConfirm("Confirmer la suppression ?");
        if (!ok) {
          return { name: call.name, content: "Refusé par l'utilisateur — fichier conservé." };
        }
        rmSync(file);
        console.log(chalk.green(`  ✓ ${relPath} supprimé.`));
        return { name: call.name, content: `Supprimé : ${relPath}` };
      }

      default:
        return { name: call.name, content: `Outil inconnu : ${call.name}` };
    }
  } catch (err) {
    return { name: call.name, content: `Erreur : ${(err as Error).message}` };
  }
}
