# Firewall Proxmox

Configuration du pare-feu intégré de Proxmox VE, à deux niveaux :
**Datacenter** (règles globales + security groups) et **Node** (activation +
application des groupes).

> ⚠️ Fichiers `.example` anonymisés. Remplacer `<ADMIN_HOME_IP>` (IP du poste
> d'admin) et `<NODE_NAME>` (nom du node) par les valeurs réelles.

## Place dans la défense en profondeur

Ce pare-feu est l'une des couches de sécurité de l'infrastructure :

| # | Couche | Rôle |
|---|--------|------|
| 1 | Cloudflare | WAF, CDN, DDoS, TLS edge |
| 2 | Firewall hébergeur (amont) | Filtrage réseau avant le serveur |
| 3 | **Firewall Proxmox** | **DROP par défaut, accès segmenté (cette section)** |
| 4 | SSH hardening + fail2ban | Clés uniquement, ban dynamique |
| 5 | Tailscale | Canal d'administration privé chiffré |

## Hiérarchie du firewall Proxmox

Trois niveaux empilés, chacun avec son propre interrupteur d'activation :

```
Datacenter (cluster.fw)   ← règles globales + security groups
     │
     ▼
Node (host.fw)            ← active le firewall sur le serveur + applique les groupes
     │
     ▼
VM / CT (<vmid>.fw)       ← règles spécifiques par machine (optionnel)
```

Les interrupteurs `enable: 1` doivent être actifs en cascade pour que les
règles s'appliquent.

## Security Groups

Trois groupes réutilisables, définis une fois et appliqués au node :

- **admin-access** — SSH (22) + interface Proxmox (8006) depuis l'IP du poste
  d'administration uniquement.
- **tailscale-access** — accès complet depuis le réseau Tailscale
  (`100.64.0.0/10`, la plage CGNAT utilisée par Tailscale).
- **web-public** — HTTP (80) + HTTPS (443) depuis Internet, pour le reverse
  proxy.

## Politique par défaut

`policy_in: DROP` — tout ce qui n'est pas explicitement autorisé est rejeté.
Plus sûr qu'une politique `ACCEPT` par défaut : on ouvre uniquement ce dont on
a besoin.

## Procédure d'activation sécurisée

L'activation d'un firewall à distance est risquée : une mauvaise règle peut
couper l'accès SSH. Procédure pour éviter de se verrouiller dehors :

```bash
# 1. Garder DEUX sessions SSH ouvertes en parallèle (filet de sécurité)

# 2. Activer le firewall Datacenter (Datacenter > Firewall > Options)
#    → aucun effet sur le trafic à ce stade

# 3. Activer le firewall Node (Node > Firewall > Options)
#    → les règles entrent en vigueur immédiatement

# 4. Tester DEPUIS UNE NOUVELLE SESSION, sans fermer les anciennes :
ssh <admin>@<TAILSCALE_IP>      # accès via Tailscale
ssh <admin>@<HOST_PUB_IP>       # accès depuis l'IP d'admin
# + interface Proxmox sur :8006

# 5. Si tout répond, fermer la session de secours
```

## Plan de secours (si verrouillage)

Désactivation d'urgence via une session SSH encore ouverte :

```bash
sed -i 's/^enable: 1/enable: 0/' /etc/pve/nodes/<NODE_NAME>/host.fw
pve-firewall restart
```

Dernier recours si totalement bloqué : mode rescue de l'hébergeur, monter le
disque système, restaurer `cluster.fw` depuis une sauvegarde.

## Vérifications

```bash
systemctl status pve-firewall      # service actif
pve-firewall status                # état du firewall
iptables -L -n -v                  # règles effectivement chargées
```

## Validation finale (tests post-activation)

| Test | Attendu |
|------|---------|
| SSH via Tailscale | ✅ OK |
| SSH depuis l'IP d'admin | ✅ OK |
| Interface Proxmox `:8006` via Tailscale | ✅ OK |
| Interface Proxmox `:8006` depuis Internet | ⛔ DROP (sécurité OK) |
| Ping conteneur → Internet (NAT) | ✅ OK |
| `apt update` depuis un conteneur | ✅ OK |