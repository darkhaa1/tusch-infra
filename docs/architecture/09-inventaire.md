# Inventaire — état réel de l'infrastructure

Photographie de ce qui tourne réellement sur l'hôte, relevée par reconnaissance
en lecture seule (`pct list`, `qm list`, `pct config`, `ss -tlnp`,
`systemctl`, `docker ps`). Les autres documents expliquent le **pourquoi** ;
celui-ci répond au **quoi et où**.

> Dernier relevé : **novembre 2026**. Les IP publiques, IP Tailscale,
> identifiants de compte et adresses MAC sont volontairement omis.

---

## Hôte

| | |
|---|---|
| Hyperviseur | Proxmox VE 8.4 — kernel 6.8 (PVE) |
| OS | Debian 12 Bookworm |
| CPU / RAM | 12 threads / 64 Go (≈ 17 Go utilisés en régime normal) |
| Disques | 2 × NVMe 512 Go, 3 grappes RAID 1 mdadm (`md0` swap, `md1` `/boot`, `md2` `/`) |
| Storage `local` | `dir` sur `/` (ISO, templates, image du pool loopback) |
| Storage `local-lvm` | LVM-thin `vg_tusch/data` 195 Go sur loopback — ≈ 48 % utilisé |
| Storage `storagebox-backup` | CIFS vers Hetzner Storage Box (1 To) — cible vzdump |
| Services hôte | `pve-firewall`, `fail2ban` (jail `sshd`), `tailscaled`, `prometheus-node-exporter`, `smartmontools`, `unattended-upgrades` |

---

## Conteneurs LXC

Tous sont des CT **non privilégiés** sous Debian 12, démarrés au boot
(`onboot: 1`) sauf le template.

| CTID | Hostname | IP | Bridge | vCPU / RAM | Rôle | Services / ports |
|------|----------|----|--------|-----------|------|------------------|
| 101 | `tusch-caddy-01` | `10.10.0.20` | vmbr1 | 1 / 512 Mo | Reverse proxy | Caddy `:80` `:443`, Grafana Alloy (logs → Loki) |
| 102 | `tusch-monitor-01` | `10.10.0.40` | vmbr1 | 1 / 2 Go | Supervision | Prometheus `:9090`, Alertmanager `:9093`, Grafana `:3000`, Loki `:3100`, pve-exporter `:9221` |
| 103 | `tusch-auth-01` | `10.10.0.50` | vmbr1 | 2 / 3 Go | Identités (IAM) | Authentik 2026.5 en Docker (server, worker, PostgreSQL 16) `:9000` `:9443`, Alloy |
| 104 | `tusch-ansible-01` | `10.10.0.60` | vmbr1 | 1 / 1 Go | Automatisation | Ansible core 2.14 (nœud de contrôle) |
| 200 | `tusch-app-01` | `10.10.0.30` | vmbr1 | 4 / 8 Go | Application tusch.mn | Next.js `:3000` (`tusch-web`), NestJS `:3310` (`tusch-api`), PostgreSQL 15 (local uniquement), Tailscale |
| 201 | `portfolio-01` | `10.10.0.31` | vmbr1 | 1 / 512 Mo | Portfolio + outils perso | Caddy statique `:80`, `health-service` `:3001`, `daybook` `:3002` |
| 900 | `template-debian-12` | `10.10.0.250` | vmbr1 | 1 / 512 Mo | Template read-only | — (arrêté) |
| 998 | `lab-serveur` | DHCP — VLAN 10 | vmbr2 | 1 / 512 Mo | Lab segmentation | client de test zone SERVEURS |
| 999 | `lab-client` | DHCP — VLAN 20 | vmbr2 | 1 / 512 Mo | Lab segmentation | client de test zone CLIENTS |

Tous les CT de `vmbr1` exposent `node_exporter` sur `:9100`, scrapé par le CT
supervision.

### Snapshots

Le CT applicatif garde deux points de retour, pris pendant son installation :

```
vide              Debian 12 fresh, avant install Node + PG
└─ stack-installed  Node 22 + pnpm + PostgreSQL 15 installés
   └─ current
```

---

## Machines virtuelles (KVM)

| VMID | Nom | vCPU / RAM | Réseau | Rôle | État |
|------|-----|-----------|--------|------|------|
| 300 | `opnsense-lab` | 2 / 4 Go | WAN `vmbr3`, LAN `vmbr2` (trunk VLAN 10 + 20) | Routeur/firewall du lab, Suricata | en marche |
| 301 | `tusch-dc-01` | 4 / 8 Go | `vmbr2` VLAN 10 (SERVEURS) | Windows Server (évaluation) — contrôleur de domaine du lab AD | en marche |
| 302 | `tusch-ws-01` | 4 / 8 Go | `vmbr2` VLAN 20 (CLIENTS) | Poste client Windows 11 (lab AD) | arrêtée |

Les VM Windows démarrent en UEFI (OVMF) ; le poste Windows 11 a un TPM 2.0
virtuel (exigence d'installation).

---

## Exposition publique (Caddy, CT 101)

Tout le trafic web entre par le DNAT 80/443 de l'hôte vers Caddy, qui gère le
TLS automatiquement et route par nom d'hôte :

| Domaine | Destination | Protection |
|---------|-------------|------------|
| `tusch.mn`, `www.tusch.mn` | CT 200 `:3000` (Next.js) | En-têtes de sécurité (HSTS, nosniff…) |
| `api.tusch.mn` | CT 200 `:3310` (NestJS) | En-têtes de sécurité |
| `auth.tusch.mn` | CT 103 `:9000` (Authentik) | Authentik lui-même |
| `grafana.tusch.mn` | CT 102 `:3000` (Grafana) | SSO OIDC Authentik |
| `darkhaa.dev`, `www.darkhaa.dev` | CT 201 `:80` (portfolio statique) | — |
| `health.darkhaa.dev` | CT 201 `:3001` (endpoint d'uptime) | — (lecture seule) |
| `daybook.darkhaa.dev` | CT 201 `:3002` | **Forward auth Authentik** |

Prometheus, Alertmanager et Loki ne sont **jamais** publiés.

### Endpoint d'uptime

Un cron minute de l'hôte (`write-uptime.sh`) écrit un petit JSON (uptime,
dernier boot, date de mise en service) dans `/srv/health`. Ce répertoire est
monté **en lecture seule** dans le CT portfolio (`mp0: ...,ro=1`), où
`health-service` le sert. Le CT n'a ainsi aucun accès à l'hôte : il lit un
fichier, c'est tout.

---

## Réseaux

| Bridge | Adresse hôte | Rôle |
|--------|--------------|------|
| `vmbr0` | IP publique | WAN — DNAT 80/443 vers Caddy |
| `vmbr1` | `10.10.0.1/24` | LAN de production (CT de service), NAT sortant |
| `vmbr2` | `10.20.0.254/24` | LAN du lab, **VLAN-aware** (VLAN 10 SERVEURS, VLAN 20 CLIENTS), derrière OPNsense |
| `vmbr3` | `10.30.0.254/30` | Lien de transit WAN d'OPNsense, NAT sortant |

Routes annoncées par le subnet router Tailscale : `10.10.0.0/24`,
`10.20.0.0/24`, `10.20.10.0/24`, `10.20.20.0/24`.

---

## Sauvegardes

| | |
|---|---|
| Outil | `vzdump` (job planifié Proxmox) |
| Fréquence | Tous les jours à 03:00, **tous** les CT et VM |
| Mode | `snapshot`, compression `zstd` |
| Cible | Hetzner Storage Box (CIFS) |
| Rétention | 7 quotidiennes, 4 hebdomadaires, 3 mensuelles |

Voir [`04-stockage.md`](04-stockage.md) § Sauvegardes.

---

## Supervision et logs

- **Métriques** : 7 cibles `node_exporter` (hôte + CT 101, 102, 103, 104, 200,
  201) et `pve-exporter` pour l'API Proxmox.
- **Logs** : Grafana Alloy sur le reverse proxy (logs d'accès Caddy) et sur le
  CT d'identité (logs des conteneurs Docker Authentik) pousse vers Loki
  (rétention 31 jours).
- **Alertes** : `InstanceDown`, `DiskAlmostFull`, `HighMemory` → Telegram.

Détail dans [`07-supervision.md`](07-supervision.md).

---

## Automatisation

Le CT `tusch-ansible-01` est le nœud de contrôle Ansible. Premier playbook en
service : déploiement de `node_exporter` sur le groupe `monitored`. Fichiers
anonymisés dans [`../../ansible/`](../../ansible/).

---

## Écarts avec la convention de numérotation

La convention de [`02-reseau.md`](02-reseau.md) réserve `100–199` aux tests.
En pratique les CT d'infrastructure (proxy, supervision, IAM, Ansible) y ont
été créés au fil de l'eau, et les VM du lab occupent `300–302`. La
renumérotation n'apporte rien tant que tout est documenté ici ; elle sera faite
si l'automatisation Ansible le justifie.
