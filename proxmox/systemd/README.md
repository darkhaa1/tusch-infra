# Services systemd

Units systemd personnalisées de l'hôte Proxmox.

## `lvm-pool-loopback.service`

Remonte automatiquement le pool LVM-thin au démarrage du serveur.

### Pourquoi ce service existe

Le storage `local-lvm` de cette infrastructure est un **thin pool LVM construit
sur un fichier image loopback** (solution retenue pour avoir des snapshots LXC
sans réinstaller l'hyperviseur — voir
[`../../docs/pieges-resolus.md`](../../docs/pieges-resolus.md) #8).

Problème : au reboot, le périphérique loopback (`/dev/loop3`) et le Volume
Group ne sont **pas remontés automatiquement**. Sans intervention, Proxmox
tente de démarrer les conteneurs alors que leur storage n'existe pas encore →
échec au boot.

Ce service résout ça en recréant le loopback et en activant le VG **avant** que
Proxmox ne touche au stockage et aux invités.

### Le point clé : l'ordre de démarrage

Tout est dans la section `[Unit]` :

```ini
Before=lvm2-monitor.service pve-storage.target pve-guests.service
RequiresMountsFor=/var/lib/vz
```

- `Before=...pve-storage.target pve-guests.service` garantit que le pool est
  prêt **avant** que Proxmox monte ses storages et démarre les conteneurs.
- `RequiresMountsFor=/var/lib/vz` garantit que le système de fichiers
  contenant le fichier image est monté avant qu'on tente de l'attacher.

`Type=oneshot` + `RemainAfterExit=yes` : le service exécute ses commandes une
fois et reste considéré comme « actif » ensuite (il n'y a pas de processus à
maintenir en vie, juste un état à établir).

### Installation

```bash
# Copier l'unit dans /etc/systemd/system/, puis :
systemctl daemon-reload
systemctl enable lvm-pool-loopback.service
systemctl start  lvm-pool-loopback.service

# Vérifier
systemctl status lvm-pool-loopback.service
lvs                                          # le thin pool doit apparaître actif
pvesm status                                 # local-lvm doit être actif
```

### Test de résilience

Le vrai test : **rebooter** et vérifier que tout remonte seul.

```bash
reboot
# après reconnexion :
systemctl status lvm-pool-loopback.service   # active (exited)
pct list                                     # les conteneurs ont démarré
```

### Leçon

Quand un storage dépend d'un montage manuel (loopback, point réseau, etc.),
il faut une unit systemd avec les bonnes directives d'ordre (`Before=`,
`RequiresMountsFor=`) pour que tout remonte dans le bon ordre au boot.
Sinon, le serveur démarre mais les services qui dépendent du storage échouent.