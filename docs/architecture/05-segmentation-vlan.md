# Segmentation réseau par VLAN

Découpage du LAN en zones étanches au standard 802.1Q, avec OPNsense en routeur
inter-VLAN et un firewall stateful directionnel entre les segments.

> La couche réseau brute (deux bridges, NAT, DNAT) reste celle décrite dans
> [`02-reseau.md`](02-reseau.md). Ce document explique la **segmentation par
> VLAN** ajoutée par-dessus, pour les besoins de défense en profondeur et de
> moindre privilège réseau.

---

## Objectif et principe

La segmentation par VLAN cloisonne le réseau en zones logiques étanches. Sans
elle, tout le monde voit tout le monde — un compromis dans une zone donne accès
à toutes les autres. Avec elle :

- Chaque zone (VLAN) ne reçoit que le trafic qui lui est explicitement destiné.
- Les communications entre zones passent par OPNsense, qui applique des règles
  de firewall.
- La direction du trafic est contrôlée : on autorise A → B sans pour autant
  autoriser B → A (segmentation directionnelle).

C'est l'application du principe de **moindre privilège réseau** : aucune zone
n'a plus de visibilité que ce dont elle a besoin pour fonctionner.

---

## Architecture VLAN

Deux VLANs initiaux, suffisants pour pratiquer la segmentation et préparer
l'extension à d'autres rôles (DMZ, IoT, management, etc.).

```
                  ┌─────────────────────────┐
                  │   OPNsense (routeur +   │
                  │   firewall stateful)    │
                  └────────┬────────────────┘
                           │ trunk 802.1Q
                           ▼
                  ┌─────────────────────────┐
                  │   Bridge VLAN-aware     │
                  └──┬──────────────────┬───┘
                     │ tag 10           │ tag 20
                     ▼                  ▼
              ┌───────────────┐  ┌───────────────┐
              │   VLAN 10     │  │   VLAN 20     │
              │   SERVEURS    │  │   CLIENTS     │
              │  10.20.10/24  │  │  10.20.20/24  │
              └───────────────┘  └───────────────┘
```

| VLAN | Rôle    | Réseau | Passerelle |
|------|---------|--------|------------|
| 10   | SERVEURS | `10.20.10.0/24` | `10.20.10.1` (OPNsense) |
| 20   | CLIENTS  | `10.20.20.0/24` | `10.20.20.1` (OPNsense) |

Les IDs 10 et 20 sont volontairement espacés pour laisser de la place à des
zones intermédiaires (DMZ, MGMT) sans renumérotation ultérieure.

### Politique inter-VLAN (directionnelle)

| Source → Destination | Action |
|----------------------|--------|
| CLIENTS → SERVEURS   | **Autorisé** (un utilisateur consulte un service) |
| SERVEURS → CLIENTS   | **Bloqué** (un serveur n'initie pas vers un poste) |
| Les deux → Internet  | **Autorisé** (sortie via NAT) |
| Retours stateful     | **Autorisés** (conntrack RELATED,ESTABLISHED) |

Le sens « serveur → client bloqué » limite la propagation latérale en cas de
compromission d'un serveur : un service compromis ne peut pas, de sa propre
initiative, scanner les postes du segment client.

---

## Bridge VLAN-aware côté Proxmox

Par défaut, un bridge Linux ignore les tags 802.1Q : les frames taggées
traversent sans être filtrées, voire sont jetées. Pour activer le filtrage par
VLAN, on rend le bridge LAN VLAN-aware via les directives ifupdown2 :

```
bridge-vlan-aware yes
bridge-vids 2-4094
```

Vérification après `ifreload -a` :

```bash
cat /sys/class/net/<bridge>/bridge/vlan_filtering   # → 1
```

`vlan_filtering = 1` confirme que le moteur VLAN du kernel est actif. Sans
cette ligne, OPNsense crée bien ses sous-interfaces VLAN, mais aucun paquet
taggé ne traverse réellement — les VLANs restent lettre morte.

---

## Trunk vers OPNsense — persistance via `trunks=`

OPNsense doit recevoir **tous les VLANs en trunk**, pas un seul tag : c'est lui
qui crée ses sous-interfaces et qui tagge / détagge. Côté Proxmox, on ne met
donc **pas** de `tag=` sur l'interface réseau d'OPNsense — elle reste en mode
trunk.

Le point critique : par défaut, le port d'OPNsense n'est associé qu'au VLAN 1
(PVID). Il faut autoriser explicitement les VIDs 10 et 20 sur ce port. La
commande manuelle existe (`bridge vlan add dev <port> vid 10`) mais **n'est pas
persistante au reboot**.

**Solution retenue : l'option native Proxmox `trunks=`** sur l'interface réseau
de la VM. Elle déclare la liste des VLANs autorisés sur ce port, et Proxmox la
réapplique automatiquement à chaque démarrage de la VM. Plus de hook
post-up à maintenir, plus de risque d'oubli après reboot :

```
trunks=10;20
```

(syntaxe Proxmox : VIDs séparés par `;`)

C'est la méthode officielle pour exposer un trunk VLAN à une VM. Configuration
versionnée dans le fichier de définition de la VM, équivalente à
`bridge vlan add` mais persistante.

---

## DHCP par VLAN (Kea DHCPv4)

OPNsense propose Kea (ISC) pour le DHCP multi-subnet. Configuration retenue :

- **Interfaces** : les deux interfaces VLAN (SERVEURS, CLIENTS)
- **Socket Type** : `raw` (point d'attention décrit en pièges)
- **Subnets** : un par VLAN, chacun avec son pool, son routeur et son DNS

Kea ne pousse pas automatiquement le DNS aux clients — c'est une option DHCP à
renseigner par subnet (option 6). On y met l'IP OPNsense du VLAN, qui relaie
ensuite vers Unbound.

---

## Règles firewall par VLAN

Approche par alias : on définit `RFC1918` (l'union des trois plages privées
RFC1918) comme alias réutilisable. Cet alias sert ensuite de cible « tous les
réseaux privés » dans une règle de Block.

L'ordre des règles compte (first-match). Sur l'interface CLIENTS, la séquence
retenue est :

1. **Pass** vers l'adresse de l'interface OPNsense du VLAN (gateway + DNS)
2. **Pass** vers le réseau SERVEURS (autorisation directionnelle)
3. **Block** vers l'alias RFC1918 (cloisonnement des autres réseaux privés)
4. **Pass** vers `any` (sortie Internet)

Sur l'interface SERVEURS, la séquence est plus courte :

1. **Pass** vers l'adresse de l'interface OPNsense du VLAN
2. **Block** vers l'alias RFC1918
3. **Pass** vers `any`

L'absence d'un « Pass vers CLIENTS net » sur l'interface SERVEURS est ce qui
crée l'asymétrie : un paquet SERVEURS → CLIENTS tombe sur la règle Block
RFC1918 et est jeté. Les retours stateful d'une connexion initiée par CLIENTS
arrivent en revanche, via la table de conntrack.

> **Détail important** : la règle « Pass vers `<interface> address` » en
> position 1 est obligatoire. Sans elle, le Block RFC1918 qui suit attrape
> aussi la gateway/DNS du VLAN (qui est une IP privée), et casse la résolution
> DNS pour les clients du VLAN. Voir piège correspondant.

---

## Conventions de tagging côté clients

Sur Proxmox, l'option `tag=` sur l'interface d'un conteneur ou d'une VM le pose
en mode access : toutes ses trames sortent taggées par ce VLAN, et inversement
pour les trames entrantes. Le système invité est inconscient du VLAN — il
croit être dans un réseau plat.

- Client SERVEURS : `tag=10`
- Client CLIENTS : `tag=20`
- OPNsense : **pas de tag** (mode trunk, reçoit les deux VIDs via `trunks=`)

---

## Pièges marquants

Détails complets au format Contexte / Symptôme / Cause / Fix / Leçon dans
[`../pieges-resolus.md`](../pieges-resolus.md) :

- **Trunk VLAN absent sur le port tap de la VM** — VLAN crée côté OPNsense
  mais aucun paquet taggé ne traverse, car le port n'autorise que le PVID 1.
- **Conflit DHCP dnsmasq vs Kea sur le port 67** — Kea bind silencieusement en
  échec, aucun OFFER, parce qu'un autre service occupait déjà la wildcard.
- **Socket Type Kea en `udp` au lieu de `raw`** — pas d'OFFER sur VLAN, le
  binding unicast manque les broadcasts DHCP.
- **DNS LXC cassé par Tailscale MagicDNS héritée de l'hôte** — la résolution
  des conteneurs partait vers `100.100.100.100` et timeout.

---

## État

- Bridge LAN VLAN-aware (`vlan_filtering = 1`)
- Trunk vers OPNsense persistant via `trunks=10;20`
- Deux VLANs actifs (SERVEURS et CLIENTS), Kea DHCP en mode `raw`
- Règles firewall directionnelles posées et validées :
  - CLIENTS → SERVEURS : pass (validé par ping et nmap depuis un client)
  - SERVEURS → CLIENTS : block (validé par tentative inverse → timeout)
- Sortie Internet OK sur les deux VLANs
- DNS résolu via Unbound OPNsense

---

## Pour aller plus loin

- Ajouter une zone DMZ (VLAN 30) pour les services exposés via reverse-proxy
- Ajouter une zone MGMT (VLAN 99) pour le management out-of-band
- Resserrer les Pass `any` en règles plus fines (services explicitement
  ouverts plutôt que tout-port)
- Activer le logging sur les règles Block pour observer les tentatives de
  latérales bloquées et alimenter la supervision
