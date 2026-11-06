# Scripts

Scripts d'exploitation déployés sur l'hôte Proxmox (`/usr/local/sbin/`).

| Script | Déclenché par | Rôle |
|--------|---------------|------|
| `backup-restic.sh` | `backup-restic.timer` (02:00) | Sauvegarde **chiffrée** de tous les CT/VM : vzdump → restic → Storage Box, rétention, vérification, métriques |
| `pct-fstrim-all.sh` | `pct-fstrim.timer` (dimanche 01:00) | Rend au pool LVM-thin les blocs libérés dans chaque CT |

Les units systemd sont dans [`../proxmox/systemd/`](../proxmox/systemd/), la
conception dans [`../docs/architecture/04-stockage.md`](../docs/architecture/04-stockage.md).

## Secrets

`backup-restic.sh` lit le mot de passe du dépôt restic dans
`/root/.restic-pass` (mode `600`). Ce fichier n'est **jamais** versionné.
Une copie doit exister **hors du serveur** (gestionnaire de mots de passe) :
sans elle, la perte de l'hôte rend les sauvegardes illisibles.
