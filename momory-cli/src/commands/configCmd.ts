import chalk from "chalk";
import yaml from "js-yaml";
import { CONFIG_PATH, MomoryConfig } from "../config.js";
import { runSetupWizard } from "./setup.js";

export async function runConfig(
  cfg: MomoryConfig,
  opts: { setup?: boolean }
): Promise<void> {
  if (opts.setup) {
    await runSetupWizard();
    return;
  }
  console.log(chalk.bold(`\nConfiguration Momory`) + chalk.dim(`  (${CONFIG_PATH})\n`));
  console.log(yaml.dump(cfg, { indent: 2 }));
  console.log(chalk.dim("Pour modifier : momory config --setup\n"));
}
