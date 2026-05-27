# Réseau

Architecture réseau de l'hôte Proxmox : deux bridges, un WAN public et un LAN
privé, avec NAT pour la sortie et DNAT pour l'entrée web.

> La configuration concrète (fichier `/etc/network/interfaces` commenté) est
> dans [`../../proxmox/network/`](../../proxmox/network/). Ce document explique
> les **choix de conception** derrière.

---

## Principe : deux bridges, deux rôles

```
Internet
   │
   ▼
<PHYS_IFACE>            interface physique (slave, sans IP)
   │
   ▼
vmbr0  ── WAN ──        porte l'IP publique <HOST_PUB_IP>
   │
   ├──────────────────► Hôte Proxmox
   │
   ▼  (NAT / DNAT)
vmbr1  ── LAN privé ──  10.10.0.0/24 (réseau isolé)
   │
   ├─► CT 101 · Caddy        10.10.0.20
   ├─► CT 200 · tusch-app    10.10.0.30
   └─► CT 900 · template     (read-only)
```

- **vmbr0 (WAN)** porte l'unique IP publique. L'interface physique y est
  rattachée en mode `manual` (sans IP propre) : elle ne sert que de port au
  bridge.
- **vmbr1 (LAN privé)** est un réseau interne `10.10.0.0/24`, totalement isolé
  d'Internet. Les conteneurs y vivent sans IP publique.

### Pourquoi cette séparation

C'est le même principe qu'un réseau domestique derrière une box : les machines
internes ne sont pas joignables directement depuis l'extérieur. Réduire la
surface d'exposition est la première règle — **seul ce qui doit être public
l'est**, le reste reste privé.

---

## Sortie Internet : NAT MASQUERADE

Les conteneurs du LAN privé doivent pouvoir sortir (mises à jour, API
externes...) sans avoir d'IP publique. C'est le rôle du NAT MASQUERADE : le
trafic `10.10.0.0/24` sort en empruntant l'IP publique de l'hôte.

```bash
iptables -t nat -A POSTROUTING -s 10.10.0.0/24 -o vmbr0 -j MASQUERADE
```

Sans cette règle, les paquets sortiraient avec une IP source privée et seraient
rejetés en amont.

---

## Entrée web : DNAT

Le trafic web entrant (80/443) doit atteindre le reverse proxy, qui est dans un
conteneur privé. Le DNAT redirige ce trafic de l'hôte vers Caddy
(`10.10.0.20`) :

```bash
iptables -t nat -A PREROUTING -i vmbr0 -p tcp --dport 443 -j DNAT --to-destination 10.10.0.20:443
```

Seuls les ports web sont redirigés. Tout le reste du LAN privé reste
inaccessible depuis Internet.

---

## Plan d'adressage `vmbr1`

Adressage réservé et documenté, pour éviter les collisions et garder une infra
lisible :

| IP | Hôte | Rôle |
|----|------|------|
| `10.10.0.1` | Hôte Proxmox | Passerelle du LAN privé |
| `10.10.0.20` | CT 101 · Caddy | Reverse proxy (reçoit le DNAT) |
| `10.10.0.30` | CT 200 · tusch-app | Application (Next.js + NestJS + PostgreSQL) |
| `10.10.0.250` | CT 900 · template | Modèle de conteneur (arrêté) |

## Convention de numérotation des conteneurs (CTID)

Les identifiants de conteneurs suivent une convention par tranches, pour que
le numéro indique immédiatement le rôle :

| Tranche | Usage |
|---------|-------|
| `100–199` | Tests / temporaires |
| `200–299` | Services applicatifs |
| `300–399` | Bases de données dédiées *(futur)* |
| `400–499` | Caches / files d'attente *(futur)* |
| `500–599` | Outils internes *(futur)* |
| `700–799` | Monitoring *(futur)* |
| `900–999` | Templates read-only |

Cette convention rend l'infra prévisible : un CTID `7xx` est forcément du
monitoring, un `9xx` un template, etc. Utile dès qu'on dépasse quelques
conteneurs.

---

## Spécificité Proxmox : les mini-bridges firewall

Quand le firewall Proxmox est actif sur un conteneur, PVE insère
automatiquement un mini-bridge `fwbrXXX` entre le conteneur et `vmbr1`. Cela
casse le NAT si on n'assigne pas une zone conntrack dédiée :

```bash
iptables -t raw -I PREROUTING -i fwbr+ -j CT --zone 1
```

C'est une spécificité Proxmox, pas du Linux standard. Détail complet dans
[`../pieges-resolus.md`](../pieges-resolus.md) (piège #3).

---

## Accès administration

L'administration **ne passe pas** par le chemin web public :

- **SSH** : autorisé uniquement depuis l'IP du poste d'admin (filtré au
  pare-feu hébergeur) ou via Tailscale
- **Interface Proxmox (`:8006`)** : accessible uniquement via Tailscale, jamais
  exposée sur Internet

Voir [`03-securite.md`](03-securite.md) pour la défense en profondeur complète.