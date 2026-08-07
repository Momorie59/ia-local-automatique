#!/usr/bin/env node
import chalk from "chalk";
import { Command } from "commander";
import { configExists, loadConfig, MomoryConfig } from "./config.js";
import { runAssistant } from "./commands/assistant.js";
import { runConfig } from "./commands/configCmd.js";
import { runDoctor } from "./commands/doctor.js";
import { runModels } from "./commands/models.js";
import { runSetupWizard, runAutoConfig } from "./commands/setup.js";

const program = new Command();

program
  .name("momory")
  .description("Assistant IA personnel local — équivalent local de Gemini CLI / Claude Code.")
  .version("0.1.0");

/** Charge la config, ou lance l'assistant de première configuration si absente. */
async function ensureConfig(): Promise<MomoryConfig> {
  if (!configExists()) {
    return runSetupWizard();
  }
  const cfg = loadConfig();
  if (!cfg) {
    // configExists() était vrai mais loadConfig a échoué à parser -> loadConfig lève déjà une erreur explicite
    throw new Error("Configuration invalide.");
  }
  return cfg;
}

program
  .command("chat", { isDefault: true, hidden: false })
  .alias("code")
  .description("Discussion avec Momory — accède aux fichiers du dossier si besoin, sans que tu aies à le préciser")
  .action(async () => {
    const cfg = await ensureConfig();
    await runAssistant(cfg);
  });

program
  .command("doctor")
  .description("Diagnostic de l'installation (serveur, modèles)")
  .action(async () => {
    const cfg = await ensureConfig();
    await runDoctor(cfg);
  });

program
  .command("config")
  .description("Afficher la configuration, ou --setup / --auto pour la (re)configurer")
  .option("--setup", "Relancer l'assistant de configuration (manuel)")
  .option("--auto [host]", "Récupérer la config automatiquement depuis le dashboard du serveur")
  .action(async (opts) => {
    if (opts.auto !== undefined) {
      // opts.auto vaut soit une adresse (string), soit true si passé sans valeur
      const host = typeof opts.auto === "string" ? opts.auto : undefined;
      await runAutoConfig(host);
      return;
    }
    if (opts.setup) {
      // Toujours forcer l'assistant, même si une config existe déjà —
      // c'est tout l'intérêt du flag (ex: changer le port Ollama).
      await runSetupWizard();
      return;
    }
    const cfg = configExists() ? loadConfig()! : await runSetupWizard();
    await runConfig(cfg, opts);
  });

program
  .command("models")
  .description("Lister les modèles disponibles sur le serveur")
  .action(async () => {
    const cfg = await ensureConfig();
    await runModels(cfg);
  });

// ── Commandes prévues par la feuille de route, pas encore implémentées ──
for (const [name, desc] of [
  ["analyse", "Analyser un projet (momory analyse <chemin>)"],
  ["remember", "Ajouter un document à la mémoire longue durée"],
] as const) {
  program
    .command(name)
    .description(desc + "  (à venir)")
    .allowUnknownOption()
    .action(() => {
      console.log(
        chalk.yellow(`\n"momory ${name}" n'est pas encore implémenté — bientôt.\n`)
      );
    });
}

program.parseAsync(process.argv).catch((err: Error) => {
  console.error(chalk.red(`\n✗ ${err.message}\n`));
  process.exit(1);
});
