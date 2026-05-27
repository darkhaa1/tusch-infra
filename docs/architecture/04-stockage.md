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

## Leçons

1. **Le stockage se pense avant l'installation de l'hyperviseur.** L'ext4 par
   défaut de l'installimage ferme la porte aux snapshots sans réaménagement.
2. **PV / VG / LV sont des couches logiques** dans le même module noyau — elles
   ne coûtent pas de performance. Ce qui coûte, c'est l'empilement de couches
   noyau différentes (loopback, fichiers, RAID).
3. **Toujours lire la doc officielle Proxmox Storage avant de diagnostiquer** :
   c'est là qu'on trouve la liste des backends qui supportent les snapshots LXC
   et la procédure LVM-thin. ([pve.proxmox.com/wiki/Storage](https://pve.proxmox.com/wiki/Storage))