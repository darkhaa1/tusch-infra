# Stockage — LVM-thin sur loopback

Comment et pourquoi le storage `local-lvm` de cette infrastructure est un
thin pool LVM construit sur un fichier image loopback, et ce que ça permet.

---

## Le problème de départ

Après l'installation de Proxmox, le seul storage disponible était `local`,
de type `dir` (un simple répertoire sur le système de fichiers ext4 de
l'hôte). Ce type de storage **ne supporte pas les snapshots LXC** : impossible
de figer l'état d'un conteneur avant une opération risquée (mise à jour, test,
migration).

Or les snapshots sont essentiels pour travailler sereinement : prendre un point
de retour propre, tester quelque chose, et revenir en arrière en une commande
si ça casse.

> Cause racine : l'installimage de l'hébergeur partitionne en **ext4 par
> défaut**. Le choix du stockage ne se pose donc qu'**après** l'installation,
> alors qu'idéalement il se pense avant (voir
> [`../pieges-resolus.md`](../pieges-resolus.md) #8).

---

## Alternatives évaluées

| Option | Verdict | Raison |
|--------|---------|--------|
| **ZFS** | écartée | Oblige à reformater les disques. Trop lourd pour un premier setup déjà en place. |
| **Réinstallation complète** | écartée | On perdrait toute l'infra déjà configurée. Radical. |
| **vzdump nightly** | insuffisant | Ce sont des sauvegardes complètes, pas de vrais snapshots instantanés. Utile, mais répond à un autre besoin. |
| **LVM-thin sur loopback** | ✅ retenue | Supporte nativement les snapshots, sans reformater ni réinstaller. |

---

## La solution : LVM-thin sur fichier loopback

L'idée : créer un fichier image, l'attacher à un périphérique loopback, et
construire dessus une pile LVM classique avec un thin pool. Proxmox sait gérer
ce storage en mode `lvmthin`, qui supporte les snapshots.

### Les couches empilées

```
/var/lib/vz/lvm-pool.img        Fichier image sparse de 200 Go
        │
        ▼
   /dev/loop3                   Périphérique loopback (le fichier vu comme un disque)
        │
        ▼
   PV  (Physical Volume)        LVM voit /dev/loop3 comme un volume physique
        │
        ▼
   VG  "vg_tusch"               Volume Group (réservoir d'espace)
        │
        ▼
   Thin pool "data" (195 Go)    Pool à allocation fine
        │
        ▼
   Storage Proxmox "local-lvm"  Utilisable pour conteneurs/VM AVEC snapshots ✅
```

### Pourquoi un fichier *sparse*

Le fichier est créé avec `truncate -s 200G` : il apparaît comme faisant 200 Go
mais n'occupe quasiment rien sur le disque tant qu'il est vide. L'espace réel
n'est consommé qu'au fur et à mesure de l'utilisation. C'est ce qui permet
d'avoir un « gros » pool sans réserver 200 Go en dur immédiatement.

---

## Mise en place

```bash
# 1. Fichier image sparse de 200 Go dans le storage local
cd /var/lib/vz
truncate -s 200G lvm-pool.img

# 2. Attache le fichier à un périphérique loopback
losetup /dev/loop3 /var/lib/vz/lvm-pool.img

# 3. Empile les couches LVM
pvcreate /dev/loop3                    # PV : LVM prend possession du loopback
vgcreate vg_tusch /dev/loop3           # VG : réservoir d'espace nommé vg_tusch
lvcreate -L 195G -T vg_tusch/data      # thin pool "data" (-T), 5 Go laissés pour les métadonnées

# 4. Déclare le storage côté Proxmox
pvesm add lvmthin local-lvm --vgname vg_tusch --thinpool data --content rootdir,images

# 5. Vérification
pvesm status                           # local-lvm doit apparaître en type lvmthin, actif
```

> On laisse ~5 Go de marge dans le VG (`-L 195G` sur un VG de 200 Go) pour les
> métadonnées du thin pool, qui ont besoin de leur propre espace.

---

## Persistance au reboot

C'est le point critique. Au redémarrage, le loopback et le VG **ne se
remontent pas automatiquement**. Sans intervention, Proxmox tente de lancer les
conteneurs alors que leur storage n'existe pas → échec au boot.

La solution est une unit systemd dédiée qui recrée le loopback et active le VG
**avant** que Proxmox ne touche au stockage :
[`../../proxmox/systemd/lvm-pool-loopback.service`](../../proxmox/systemd/lvm-pool-loopback.service).

L'ordre de démarrage (`Before=pve-storage.target pve-guests.service`) est ce
qui garantit que le pool est prêt à temps.

---

## Et la performance ?

Question légitime : empiler fichier → loopback → LVM, est-ce que ça coûte cher ?

Il faut distinguer deux types de couches :

- **Les couches LVM (PV / VG / LV)** sont des abstractions **logiques** gérées
  dans le même module noyau. Elles ne coûtent quasiment rien en performance —
  c'est de la cartographie de blocs.
- **Ce qui a un coût réel**, c'est l'empilement de couches noyau *différentes* :
  le loopback + le système de fichiers ext4 sous-jacent + le RAID logiciel.

Pour l'usage de cette infra (conteneurs de services web, bases de données de
taille modérée), le surcoût est négligeable et le bénéfice — snapshots
instantanés — largement gagnant. Pour une charge I/O intensive en production
sérieuse, on partirait plutôt sur du LVM-thin directement sur partition, ou du
ZFS, décidés **avant** l'installation.

---

## État final validé

- Storage `local-lvm` visible et actif dans l'interface Proxmox
  (Datacenter → Storage)
- Création d'un snapshot LXC fonctionnelle : `pct snapshot 200 test_snapshot`
- Reboot de l'hôte → loopback remonté automatiquement, VG actif, storage
  disponible, conteneurs démarrés

---

> Note : le numéro de périphérique loopback n'est pas fixe. La mise en place
> manuelle utilisait `/dev/loop3` ; après reboot, l'unit systemd prend le
> premier libre (`/dev/loop0` aujourd'hui). C'est sans importance : LVM
> retrouve le VG par sa signature, pas par le nom du périphérique.

### Occupation actuelle

Le pool `data` est rempli à environ 48 %. Le VG ne garde que ~5 Go libres (la
marge prévue pour les métadonnées), il faut donc surveiller le remplissage du
**pool**, pas celui du VG.

Un volume thin peut afficher un taux d'occupation bien plus haut que le `df`
vu de l'intérieur du conteneur : les blocs libérés par le système de fichiers
ne sont rendus au pool qu'après un `fstrim`. Commande de rattrapage pour tous
les CT : `pct fstrim <CTID>` — automatisé chaque dimanche par `pct-fstrim.timer`
(premier passage : volume du CT supervision ramené de 95 % à 38 %).

---

## Sauvegardes

Les snapshots protègent contre une erreur de manipulation, pas contre la perte
de l'hôte. Les sauvegardes complètes partent donc **hors du serveur**, et
**chiffrées** : l'hébergeur de la Storage Box ne peut pas les lire.

### Chaîne de sauvegarde

```
02:00  backup-restic.timer
  │
  ▼
vzdump --all --mode snapshot --compress 0      tous les CT et VM, à chaud
  │      → /var/lib/vz/restic-staging          (local, temporaire)
  ▼
restic backup                                  chiffrement AES-256 côté hôte
  │      → Storage Box (CIFS) /restic          déduplication + compression
  ▼
restic forget --prune                          7 quotidiennes, 4 hebdo, 3 mensuelles
  │
  ├─ dimanche : restic check --read-data-subset=5%   (intégrité)
  ▼
métriques → node_exporter (textfile) → Prometheus → alerte Telegram
```

| | |
|---|---|
| Script | [`scripts/backup-restic.sh`](../../scripts/backup-restic.sh) (timer systemd 02:00) |
| Périmètre | Tous les CT et toutes les VM |
| Mode | `snapshot` — pas d'arrêt des invités |
| Chiffrement | restic (AES-256-CTR + Poly1305), clé dérivée du mot de passe du dépôt |
| Cible | Hetzner Storage Box, montée en CIFS (`storagebox-backup`) |
| Rétention | 7 quotidiennes, 4 hebdomadaires, 3 mensuelles |
| Alertes | `BackupFailed`, `BackupTooOld` (> 26 h), `BackupMetricsMissing` |

### Pourquoi vzdump **non compressé**

restic découpe les données en blocs et ne stocke qu'une fois les blocs
identiques. Une archive `zstd` change entièrement dès qu'un octet change :
rien ne se déduplique d'un jour à l'autre. Une archive brute, elle, se
déduplique, et restic la compresse lui-même ensuite.

Première sauvegarde : **76 Go** d'archives brutes → **42 Go** stockés, en
14 minutes. Les suivantes n'envoient que les blocs modifiés.

### Le mot de passe du dépôt

`/root/.restic-pass` (mode `600`). **Sans lui, les sauvegardes sont
illisibles**, y compris pour l'administrateur. Une copie est conservée hors du
serveur, dans un gestionnaire de mots de passe : si l'hôte est perdu, c'est la
seule clé des sauvegardes.

### Restauration — testée

Une sauvegarde qui n'a jamais été restaurée n'est qu'une hypothèse. Test
réalisé sur le CT applicatif (application + PostgreSQL) :

```bash
export RESTIC_REPOSITORY=/mnt/pve/storagebox-backup/restic
export RESTIC_PASSWORD_FILE=/root/.restic-pass

# 1. Extraire l'archive du CT depuis le dernier snapshot (39 s, 6,6 Go)
restic restore latest --target /var/lib/vz/restore-test \
    --include "/var/lib/vz/restic-staging/vzdump-lxc-200-*"

# 2. Restaurer sous un ID libre, MAC régénérée (--unique) (34 s)
pct restore 9200 /var/lib/vz/restore-test/.../vzdump-lxc-200-*.tar \
    --storage local-lvm --unique 1

# 3. Isoler AVANT de démarrer : autre IP, carte réseau coupée
pct set 9200 -hostname restore-test-200 -onboot 0 \
    -net0 name=eth0,bridge=vmbr1,ip=10.10.0.230/24,gw=10.10.0.1,firewall=1,link_down=1
pct start 9200
```

> L'isolement réseau est indispensable : le CT restauré a la même IP que
> l'original (conflit, piège #20) et le même client Tailscale (doublon de
> nœud sur le tailnet).

Vérifications, original contre restauré :

| Contrôle | Original (CT 200) | Restauré (CT 9200) |
|----------|-------------------|--------------------|
| Services `postgresql`, `tusch-api`, `tusch-web` | actifs | actifs |
| Base `tusch_prod` : tables / lignes (comptage exact) | 13 / 53 | 13 / 53 |
| Empreinte des comptages par table | `039cb96a1a02` | `039cb96a1a02` |
| Empreinte du binaire de l'API | `072fc1d2ba62…` | `072fc1d2ba62…` |
| Front `:3000` / API `:3310` (localhost) | 200 / 302 | 200 / 302 |

> Piège de vérification : sur la copie, `pg_stat_user_tables.n_live_tup`
> affichait 0 ligne. Ce sont des **statistiques**, réinitialisées après la
> reprise d'une sauvegarde à chaud — pas les données. Seul un `count(*)` réel
> par table fait foi.

**RTO mesuré** pour ce CT : environ **2 minutes** de la commande `restic
restore` au CT démarré. Le CT de test a ensuite été détruit
(`pct destroy 9200 --purge`).

---

## Leçons

1. **Le stockage se pense avant l'installation de l'hyperviseur.** L'ext4 par
   défaut de l'installimage ferme la porte aux snapshots sans réaménagement.
2. **PV / VG / LV sont des couches logiques** dans le même module noyau — elles
   ne coûtent pas de performance. Ce qui coûte, c'est l'empilement de couches
   noyau différentes (loopback, fichiers, RAID).
3. **Toujours lire la doc officielle Proxmox Storage avant de diagnostiquer** :
   c'est là qu'on trouve la liste des backends qui supportent les snapshots LXC
   et la procédure LVM-thin. ([pve.proxmox.com/wiki/Storage](https://pve.proxmox.com/wiki/Storage))