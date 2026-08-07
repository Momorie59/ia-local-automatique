import chalk from "chalk";
import { CONFIG_PATH, MomoryConfig } from "../config.js";
import { listModels, pingServer } from "../ollama.js";

function line(ok: boolean, label: string, detail = ""): void {
  const icon = ok ? chalk.green("✓") : chalk.red("✗");
  console.log(`  ${icon} ${label}${detail ? chalk.dim("  " + detail) : ""}`);
}

export async function runDoctor(cfg: MomoryConfig): Promise<void> {
  console.log(chalk.bold("\nDiagnostic Momory\n"));

  line(true, `Configuration trouvée`, CONFIG_PATH);

  const ping = await pingServer(cfg);
  line(
    ping.ok,
    `Serveur Ollama (${cfg.server.host}:${cfg.server.port})`,
    ping.ok ? "" : ping.error
  );

  if (!ping.ok) {
    console.log(
      chalk.yellow(
        "\n  → Le serveur ne répond pas. Vérifie qu'Ollama tourne sur cette machine,"
      )
    );
    console.log(
      chalk.yellow("    et que l'adresse/port dans la config sont corrects.")
    );
    console.log(chalk.dim("    (momory config --setup pour reconfigurer)\n"));
    return;
  }

  let models: string[] = [];
  try {
    models = (await listModels(cfg)).map((m) => m.name);
  } catch (err) {
    line(false, "Liste des modèles", (err as Error).message);
  }

  for (const [role, wanted] of [
    ["Modèle conversation", cfg.models.chat],
    ["Modèle développement", cfg.models.coder],
    ["Modèle embedding", cfg.models.embed],
  ] as const) {
    const present = models.some(
      (m) => m === wanted || m.startsWith(wanted.split(":")[0] + ":")
    );
    line(
      present,
      `${role} — ${wanted}`,
      present ? "" : `absent — lance: ollama pull ${wanted}`
    );
  }

  console.log(
    cfg.memory.enabled
      ? chalk.dim(
          `\n  Mémoire (Qdrant) : ${cfg.memory.qdrant.host}:${cfg.memory.qdrant.port} — vérification à venir (pas encore implémentée)`
        )
      : chalk.dim("\n  Mémoire (Qdrant) : désactivée")
  );
  console.log("");
}
