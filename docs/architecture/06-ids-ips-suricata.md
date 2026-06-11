# Détection et prévention d'intrusion — Suricata sur OPNsense

Suricata est le moteur d'inspection en profondeur de paquets activé sur le
routeur OPNsense. Il observe le trafic, applique des règles de signature, et —
en mode IPS — bloque les flux qui matchent une règle d'action `drop`.

> Architecture VLAN sous-jacente : [`05-segmentation-vlan.md`](05-segmentation-vlan.md).

---

## IDS vs IPS

Deux modes de fonctionnement à bien distinguer :

| Mode | Position dans le chemin du paquet | Effet | Capture |
|------|-----------------------------------|-------|---------|
| **IDS** | Hors-bande (copie via libpcap) | Alerte seulement | PCAP live mode |
| **IPS** | Inline dans le chemin de routage | Alerte + drop actif | Netmap |

L'IDS est non-intrusif : il observe et logue. L'IPS est intrusif : il peut
casser un trafic légitime si une règle est trop large. La stratégie retenue
est de **valider d'abord la chaîne en IDS** (capture → règles → alerte), puis
de basculer en IPS uniquement quand la détection est solide.

---

## Choix d'architecture

### Placement : interface LAN / parent, pas WAN

Suricata écoute sur le parent des VLANs (interface LAN brute), pas sur le WAN.
Deux raisons :

- Sur le WAN, OPNsense voit le trafic après NAT entrant et avant NAT sortant.
  Les IPs côté WAN sont les IPs du réseau de transit, pas les IPs réelles des
  postes du LAN — inutilisable pour comprendre qui fait quoi.
- Les rulesets ET (Emerging Threats) raisonnent en termes de `$HOME_NET` versus
  `$EXTERNAL_NET`. En écoutant sur le LAN, Suricata voit les vraies IPs
  internes et applique correctement la sémantique des règles.

### Home networks : les deux VLANs internes

Configuration `Home networks = 10.20.10.0/24, 10.20.20.0/24`. Un scan venant
d'un client du LAN vers Internet est interprété « interne → externe » et
matche les règles `ET SCAN OUTBOUND`. Inversement pour le sens entrant.

### Lecture des VLANs taggés

Les frames des VLANs remontent au parent en restant taggées 802.1Q. Suricata
lit le tag et l'inclut dans les événements `eve.json` (`"vlan":[20]`). On n'a
donc pas besoin de dédoubler la configuration par VLAN — écouter le parent
suffit, le filtrage par VLAN se fait dans les queries `eve.json` ensuite.

---

## Contrainte virtualisation — Netmap + VirtIO

Suricata en mode IPS utilise Netmap (capture rapide au niveau kernel,
nécessaire pour l'inline). Or les cartes virtuelles VirtIO ne sont pas
nativement supportées par Netmap, qui a été conçu pour des NIC physiques avec
drivers spécifiques.

Sans contournement, le passage en mode Netmap fait crasher le moteur ou refuse
de démarrer.

**Solution officielle (doc OPNsense)** : passer Netmap en mode émulé via un
tunable kernel.

```
dev.netmap.admode = 2
```

À ajouter dans `System → Settings → Tunables`, puis **reboot obligatoire** (le
tunable se charge au boot). Vérification après reboot :

```bash
sysctl dev.netmap.admode    # → 2
```

Mode 2 = émulation logicielle de Netmap au-dessus du driver natif (VirtIO ici).
Performance moindre qu'un Netmap natif sur NIC physique, mais largement
suffisante pour le contexte.

---

## Rulesets — Emerging Threats Open

Quatre jeux activés (gratuits, mis à jour quotidiennement) :

- `emerging-exploit` — exploits applicatifs
- `emerging-malware` — signatures de familles malware
- `emerging-scan` — scans réseau (type nmap)
- `emerging-sql` — injections SQL

Les fichiers sont téléchargés dans `/usr/local/etc/suricata/rules/`. **Ne
jamais les éditer à la main** : ils sont écrasés au prochain `Download &
Update`. Les modifications passent par l'UI (User-defined rules ou onglet
Rules) ou par une Policy.

---

## Mécanisme Policy — alert vs drop

Les rulesets ET Open sont livrés en action `alert` (toutes les règles sont en
détection seulement). Pour bloquer activement, on **ne touche pas aux fichiers
`.rules`** : on définit une *Policy*.

Configuration de la Policy retenue :

- **Rulesets** : les 4 jeux ET cochés
- **Action (filtre)** : Alert → sélectionne les règles qui sont actuellement
  en action `alert` (donc toutes)
- **New action items** : `Drop` → force les règles sélectionnées en action
  `drop` au moment du chargement par Suricata

C'est le champ `New action items` qui détermine si l'on est en IDS (`Alert`)
ou en IPS (`Drop`) — c'est le seul levier à manipuler pour basculer entre les
deux modes. Aucune édition de fichier nécessaire.

### Piège d'affichage à connaître

Quand la policy est en `Drop`, **les fichiers `.rules` ne sont pas réécrits**.
Un `grep '^drop'` sur les fichiers retourne 0 occurrence, même quand le drop
est bien appliqué en mémoire. C'est normal. La source de vérité est :

- l'onglet Rules de l'UI (action effective affichée par règle)
- la commande `configctl ids list installedrules` (action effective en
  mémoire après application de la policy)

Se fier au fichier source pour vérifier l'IPS conduit à une fausse alerte.

---

## Validation — méthode « un maillon à la fois »

Le pipeline IDS a plusieurs maillons : réseau → driver → libpcap → moteur →
règles → logging. Valider chaque maillon individuellement, du bas vers le
haut, évite de tourner en rond entre les couches.

### Maillon 1 — la capture fonctionne

```bash
tcpdump -i <interface_LAN> -n
```

Pendant ce temps, générer du trafic depuis un client. Les paquets doivent
défiler. Confirmation indirecte côté Suricata : `eve.json` contient
`"pkt_src":"wire/pcap"` ou `"pkt_src":"netmap"` selon le mode.

### Maillon 2 — le moteur charge les règles

Inspecter `/var/log/suricata/suricata_AAAAMMJJ.log` :

```
<Info> (rule-loader) -- N rules loaded successfully
```

Si à la place on voit `1 rule files specified, but no rules were loaded!`,
inutile de tester du trafic — aucune règle n'est armée. Voir piège ci-dessous.

### Maillon 3 — la détection produit des alertes

Watcher `eve.json` en filtrant sur les vraies alertes :

```bash
tail -f /var/log/suricata/eve.json | grep '"event_type":"alert"'
```

Distinction importante :

- `event_type: flow / ssh / http / dns / tls` → **identification** de protocole
- `event_type: alert` → **détection** par une règle de signature

L'`event_type: ssh` apparaît dès qu'un handshake SSH est observé : ce n'est
pas une alerte, juste l'identification d'un protocole.

### Validation IPS — `action: blocked`

En mode IPS, une règle drop qui matche produit un événement avec
`"action":"blocked"` dans `eve.json`. C'est le signal qu'un paquet a
effectivement été jeté, pas juste signalé.

**Test concluant** : depuis un client interne, lancer un scan SSH sortant. La
signature ET Open `SID 2003068` (Potential SSH Scan OUTBOUND) matche, et
l'événement `eve.json` montre `"action": "blocked"` — confirmation que le
blocage est effectif, pas juste la détection.

---

## Mise à jour des règles

- **Manuelle** : `Download → Download & Update Rules → Apply` → `configctl
  ids reload`.
- **Automatique** : onglet Schedule → planification quotidienne (signatures
  ET mises à jour chaque jour côté upstream). Heure choisie en dehors de la
  fenêtre de reboot post-MAJ kernel.

---

## Pièges marquants

Détails complets dans [`../pieges-resolus.md`](../pieges-resolus.md) :

- **Suricata « no rules were loaded » après bascules successives** — la config
  IDS s'est corrompue ; réinstallation propre du plugin
  (`os-intrusion-detection`) après stop, suppression de
  `/usr/local/etc/suricata`, et reconfig depuis l'UI.
- **Fausse piste Netmap / VirtIO au début** — on a suspecté la capture alors
  que la capture marchait. Le vrai problème était le chargement des règles.
  Leçon : prouver chaque maillon du bas vers le haut.

---

## État

- Plugin `os-intrusion-detection` installé et stable
- Tunable `dev.netmap.admode = 2` actif (vérifié au boot)
- 4 rulesets ET Open chargés, policy en `Drop` appliquée
- Capture confirmée (`tcpdump` + champ `pkt_src` dans `eve.json`)
- Détection confirmée (alertes `ET SCAN OUTBOUND` observées)
- **Blocage IPS confirmé** par événement `"action": "blocked"` sur le scan
  SSH (SID 2003068) depuis un client interne

---

## Pour aller plus loin

- Tuner les faux positifs récurrents (Cloudflare, etc.) via Rules → Disable
- Activer le schedule de mise à jour automatique des règles
- Exporter `eve.json` vers la stack de supervision (cf.
  [`07-supervision.md`](07-supervision.md)) pour visualiser les alertes dans
  le temps
- Pratiquer l'écriture de signatures custom dans User-defined rules
