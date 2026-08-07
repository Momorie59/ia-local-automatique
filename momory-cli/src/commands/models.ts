import chalk from "chalk";
import { MomoryConfig } from "../config.js";
import { listModels } from "../ollama.js";

function fmtSize(bytes: number): string {
  const gb = bytes / 1024 ** 3;
  return gb >= 1 ? `${gb.toFixed(1)} Go` : `${(bytes / 1024 ** 2).toFixed(0)} Mo`;
}

export async function runModels(cfg: MomoryConfig): Promise<void> {
  console.log(chalk.bold(`\nModèles disponibles sur ${cfg.server.host}:${cfg.server.port}\n`));

  let models;
  try {
    models = await listModels(cfg);
  } catch (err) {
    console.log(chalk.red(`✗ Impossible de contacter le serveur : ${(err as Error).message}`));
    console.log(chalk.dim("  (momory doctor pour un diagnostic complet)\n"));
    return;
  }

  if (models.length === 0) {
    console.log(chalk.yellow("  Aucun modèle installé sur ce serveur."));
    console.log(chalk.dim(`  Exemple : ollama pull ${cfg.models.chat}\n`));
    return;
  }

  for (const m of models) {
    const roles: string[] = [];
    if (m.name === cfg.models.chat) roles.push("conversation");
    if (m.name === cfg.models.coder) roles.push("code");
    if (m.name === cfg.models.embed) roles.push("embedding");
    const tag = roles.length ? chalk.cyan(`  [${roles.join(", ")}]`) : "";
    console.log(`  ${chalk.bold(m.name)}  ${chalk.dim(fmtSize(m.size))}${tag}`);
  }
  console.log("");
}
