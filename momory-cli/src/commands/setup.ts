import chalk from "chalk";
import prompts from "prompts";
import {
  CONFIG_PATH,
  DEFAULT_CONFIG,
  MomoryConfig,
  loadConfig,
  saveConfig,
} from "../config.js";
import { pingServer } from "../ollama.js";
import { fetchServerMomoryInfo, serverInfoToConfig } from "../serverConfig.js";

/**
 * Assistant interactif de première configuration. Se lance automatiquement
 * si aucun ~/.momory/config.yaml n'existe (voir index.ts), ou explicitement
 * via `momory config --setup`.
 */
export async function runSetupWizard(): Promise<MomoryConfig> {
  console.log(chalk.bold("\nBienvenue dans Momory.\n"));

  const { mode } = await prompts(
    {
      type: "select",
      name: "mode",
      message: "Comment configurer Momory ?",
      choices: [
        { title: "Automatique — récupérer depuis le dashboard du serveur (recommandé)", value: "auto" },
        { title: "Manuelle — je saisis tout moi-même", value: "manual" },
      ],
      initial: 0,
    },
    { onCancel: () => process.exit(1) }
  );

  if (mode === "auto") {
    const { host } = await prompts(
      {
        type: "text",
        name: "host",
        message: "Adresse du serveur (ex: 192.168.1.16)",
        initial: loadConfig()?.server.host || DEFAULT_CONFIG.server.host,
      },
      { onCancel: () => process.exit(1) }
    );
    try {
      return await runAutoConfig(host);
    } catch {
      console.log(chalk.yellow("\nBasculement en configuration manuelle...\n"));
      // on continue plus bas avec le formulaire manuel
    }
  }

  console.log("Configuration du serveur IA :\n");

  const answers = await prompts(
    [
      {
        type: "text",
        name: "host",
        message: "Adresse du serveur (Ollama)",
        initial: DEFAULT_CONFIG.server.host,
      },
      {
        type: "number",
        name: "port",
        message: "Port",
        initial: DEFAULT_CONFIG.server.port,
      },
      {
        type: "text",
        name: "chatModel",
        message: "Modèle principal (conversation)",
        initial: DEFAULT_CONFIG.models.chat,
      },
      {
        type: "text",
        name: "coderModel",
        message: "Modèle développement (momory code)",
        initial: DEFAULT_CONFIG.models.coder,
      },
      {
        type: "confirm",
        name: "memoryEnabled",
        message: "Activer la mémoire longue durée (Qdrant) ?",
        initial: true,
      },
      {
        type: (prev) => (prev ? "text" : null),
        name: "qdrantHost",
        message: "Adresse Qdrant",
        initial: (_prev, values) => values.host,
      },
      {
        type: (_prev, values) => (values.memoryEnabled ? "number" : null),
        name: "qdrantPort",
        message: "Port Qdrant",
        initial: DEFAULT_CONFIG.memory.qdrant.port,
      },
    ],
    {
      onCancel: () => {
        console.log(chalk.yellow("\nConfiguration annulée."));
        process.exit(1);
      },
    }
  );

  const cfg: MomoryConfig = {
    server: { host: answers.host, port: answers.port },
    models: {
      chat: answers.chatModel,
      coder: answers.coderModel,
      embed: DEFAULT_CONFIG.models.embed,
    },
    memory: {
      enabled: answers.memoryEnabled,
      qdrant: {
        host: answers.qdrantHost ?? DEFAULT_CONFIG.memory.qdrant.host,
        port: answers.qdrantPort ?? DEFAULT_CONFIG.memory.qdrant.port,
      },
    },
  };

  console.log(chalk.dim("\nVérification du serveur…"));
  const ping = await pingServer(cfg);
  if (ping.ok) {
    console.log(chalk.green("✓ Serveur Ollama joignable."));
  } else {
    console.log(
      chalk.yellow(
        `⚠ Serveur injoignable pour l'instant (${ping.error}). ` +
          `La configuration sera quand même enregistrée — relance "momory doctor" une fois le serveur démarré.`
      )
    );
  }

  saveConfig(cfg);
  console.log(chalk.green(`\n✓ Configuration enregistrée : ${CONFIG_PATH}\n`));

  return cfg;
}

/**
 * Configuration automatique : récupère tout (adresse, modèles, Qdrant)
 * directement depuis le dashboard du serveur — aucune saisie manuelle.
 */
export async function runAutoConfig(host?: string): Promise<MomoryConfig> {
  const targetHost = host || loadConfig()?.server.host;
  if (!targetHost) {
    throw new Error("Aucune adresse de serveur connue. Précise-la : momory config --auto 192.168.1.16");
  }

  console.log(chalk.dim(`\nRécupération de la config depuis ${targetHost}:7842…`));
  const info = await fetchServerMomoryInfo(targetHost);

  const existing = loadConfig() ?? undefined;
  const cfg = serverInfoToConfig(info, existing);
  saveConfig(cfg);

  console.log(chalk.green(`✓ Configuration récupérée automatiquement depuis ${targetHost} :`));
  console.log(chalk.dim(`  Serveur : ${cfg.server.host}:${cfg.server.port}`));
  console.log(chalk.dim(`  Chat    : ${cfg.models.chat}`));
  console.log(chalk.dim(`  Coder   : ${cfg.models.coder}`));
  if (cfg.memory.enabled) {
    console.log(chalk.dim(`  Qdrant  : ${cfg.memory.qdrant.host}:${cfg.memory.qdrant.port}`));
  }
  console.log(chalk.green(`✓ Enregistré : ${CONFIG_PATH}\n`));

  return cfg;
}
