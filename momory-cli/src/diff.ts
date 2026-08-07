import chalk from "chalk";

/**
 * Diff ligne à ligne minimaliste (LCS) — suffisant pour afficher clairement
 * ce qui va changer avant une confirmation, sans dépendance externe.
 */
export function lineDiff(before: string, after: string): string {
  const a = before.split("\n");
  const b = after.split("\n");
  const n = a.length;
  const m = b.length;

  // Table LCS
  const dp: number[][] = Array.from({ length: n + 1 }, () => new Array(m + 1).fill(0));
  for (let i = n - 1; i >= 0; i--) {
    for (let j = m - 1; j >= 0; j--) {
      dp[i][j] =
        a[i] === b[j] ? dp[i + 1][j + 1] + 1 : Math.max(dp[i + 1][j], dp[i][j + 1]);
    }
  }

  const lines: string[] = [];
  let i = 0,
    j = 0;
  while (i < n && j < m) {
    if (a[i] === b[j]) {
      lines.push(chalk.dim(`  ${a[i]}`));
      i++;
      j++;
    } else if (dp[i + 1][j] >= dp[i][j + 1]) {
      lines.push(chalk.red(`- ${a[i]}`));
      i++;
    } else {
      lines.push(chalk.green(`+ ${b[j]}`));
      j++;
    }
  }
  while (i < n) lines.push(chalk.red(`- ${a[i++]}`));
  while (j < m) lines.push(chalk.green(`+ ${b[j++]}`));

  return lines.join("\n");
}
