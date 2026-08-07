import { createInterface, Interface } from "node:readline/promises";

/**
 * Une seule interface readline pour tout le processus, créée seulement à la
 * première utilisation réelle (pas au chargement du module). Sinon, une
 * commande non-interactive comme `momory config --auto` ou `momory doctor`
 * resterait bloquée indéfiniment : readline garde le process Node ouvert
 * tant que personne n'appelle .close(), même sans jamais être utilisée.
 */
let _rl: Interface | null = null;

export function getRl(): Interface {
  if (!_rl) {
    _rl = createInterface({ input: process.stdin, output: process.stdout });
  }
  return _rl;
}

export function closeRl(): void {
  _rl?.close();
  _rl = null;
}
