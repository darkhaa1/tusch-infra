# Sécurité — Défense en profondeur

L'infrastructure applique le principe de **défense en profondeur** : empiler
plusieurs couches de sécurité indépendantes, pour que la défaillance d'une
seule ne compromette pas l'ensemble.

> Principe directeur : **si une couche tombe, les autres protègent.** Aucune
> couche n'est supposée parfaite ; c'est leur empilement qui assure la
> robustesse.

---

## Vue d'ensemble des couches

```
                    ATTAQUANT / INTERNET
                            │
   ┌────────────────────────▼────────────────────────┐
   │  1. Cloudflare          WAF · CDN · DDoS · TLS    │  edge
   ├────────────────────────▼────────────────────────┤
   │  2. Firewall hébergeur  filtrage réseau amont     │  réseau
   ├────────────────────────▼────────────────────────┤
   │  3. Firewall Proxmox    DROP par défaut           │  hyperviseur
   ├────────────────────────▼────────────────────────┤
   │  4. SSH hardening       clés uniquement           │  accès
   ├────────────────────────▼────────────────────────┤
   │  5. fail2ban            ban dynamique des IP      │  applicatif
   ├────────────────────────▼────────────────────────┤
   │  6. Tailscale           canal admin privé chiffré │  hors-bande
   └───────────────────────────────────────────────────┘
                            │
                     SERVICES PROTÉGÉS
```

Les couches sont décrites de l'extérieur (Internet) vers l'intérieur
(les services).

---

## Couche 1 — Cloudflare (edge)

Première ligne de défense, avant même que le trafic atteigne le réseau de
l'hébergeur.

- **WAF** : filtrage applicatif des requêtes malveillantes
- **CDN** : cache et accélération (utile vu la distance vers la Mongolie)
- **DDoS** : protection volumétrique incluse
- **TLS edge** : mode `Full (strict)`, TLS 1.3, HSTS, Always HTTPS
- **Mode Proxied** : l'IP réelle du serveur est masquée — un attaquant ne voit
  qu'une IP Cloudflare, jamais l'origine

Résultat TLS : **score A+ SSL Labs**.

---

## Couche 2 — Firewall de l'hébergeur (réseau amont)

Pare-feu géré côté hébergeur, **avant** que les paquets n'atteignent le serveur.

- SSH (22) ouvert **uniquement** depuis l'IP du poste d'administration
  (`<ADMIN_HOME_IP>`)
- HTTP (80), HTTPS (443), ICMP ouverts
- Règle TCP-established placée en dernier (selon recommandation de l'hébergeur)

**Avantage clé** : le filtrage en amont signifie que les paquets indésirables
sont rejetés au niveau réseau de l'hébergeur, **sans consommer le CPU ni
polluer les logs** du serveur.

---

## Couche 3 — Firewall Proxmox (hyperviseur)

Pare-feu intégré à l'hyperviseur, politique **DROP par défaut**.

- Tout flux non explicitement autorisé est rejeté
- Accès segmentés en *security groups* réutilisables : administration, accès
  Tailscale, web public

Configuration complète et procédure d'activation sécurisée :
[`../../proxmox/firewall/`](../../proxmox/firewall/).

---

## Couche 4 — SSH hardening (accès)

L'accès SSH est durci pour rendre le brute-force inopérant.

Fichier dédié : `/etc/ssh/sshd_config.d/99-hardening.conf` (drop-in, qui survit
aux mises à jour du paquet openssh et garde le fichier principal intact).

```ini
PasswordAuthentication no          # plus de mot de passe, clés uniquement
PermitRootLogin prohibit-password  # root seulement par clé
PubkeyAuthentication yes
KbdInteractiveAuthentication no
PermitEmptyPasswords no
MaxAuthTries 3                     # 3 essais puis déconnexion
LoginGraceTime 30                  # 30 s pour s'authentifier
```

- Clés **ed25519** uniquement (algorithme moderne, robuste)
- Authentification par mot de passe **désactivée**

> **Règle d'or appliquée** : ne jamais désactiver l'authentification par mot de
> passe avant d'avoir validé la connexion par clé. Procédure suivie :
> 1. déployer la clé publique → 2. tester la connexion par clé (succès) →
> 3. *alors seulement* désactiver le mot de passe → 4. tester (refus = preuve
> du durcissement).

**Effet** : les attaquants reçoivent immédiatement `Permission denied
(publickey)`, sans pouvoir tenter le moindre mot de passe.

---

## Couche 5 — fail2ban (applicatif)

Surveille les logs SSH et bannit dynamiquement les IP malveillantes.

- Au-delà de 3 tentatives échouées, l'IP est bannie au niveau pare-feu
- Jail `sshd`, backend `systemd`

> Piège rencontré : sans le paquet `python3-systemd`, fail2ban ne peut pas lire
> le journal systemd et ne démarre pas. Installation de ce paquet = résolution.

**Pourquoi en complément du hardening SSH** : même si les clés rendent le
brute-force inutile, les bots continuent d'essayer en boucle, ce qui consomme
un peu de CPU et pollue les logs. fail2ban coupe le flux dès la 3ᵉ tentative,
au niveau réseau — plus aucun paquet de l'attaquant n'atteint SSH.

---

## Couche 6 — Tailscale (accès admin hors-bande)

VPN mesh chiffré réservé à l'administration.

- L'interface Proxmox (`:8006`) **n'est pas exposée sur Internet** : elle n'est
  accessible que via Tailscale (`<TAILSCALE_IP>`)
- Compte protégé par OAuth + MFA TOTP
- Permet d'administrer sans IP publique ouverte sur les ports sensibles

**Bénéfice** : la surface d'attaque administrative est quasi nulle côté
Internet. L'interface d'hypervision, cible de choix, est invisible depuis
l'extérieur.

---

## Anecdote : l'épreuve du feu

Quelques heures seulement après la première mise en route, les logs montraient
déjà des tentatives de brute-force SSH automatisées (depuis des IP de scan
opportuniste — clouds publics, etc.) essayant des comptes classiques
(`root`, `mailadmin`, `azureuser`...).

C'est la démonstration concrète qu'**un serveur exposé est scanné en
permanence, dès la première heure.** Le durcissement n'est pas optionnel : il
doit être en place avant même que le serveur ne soit "utile".

---

## Synthèse

| # | Couche | Niveau | Mécanisme principal |
|---|--------|--------|---------------------|
| 1 | Cloudflare | Edge | WAF, DDoS, TLS, IP masquée |
| 2 | Firewall hébergeur | Réseau | Filtrage amont, économie CPU |
| 3 | Firewall Proxmox | Hyperviseur | DROP par défaut, segmentation |
| 4 | SSH hardening | Accès | Clés ed25519, pas de mot de passe |
| 5 | fail2ban | Applicatif | Ban dynamique des IP |
| 6 | Tailscale | Hors-bande | Admin privé, UI non exposée |

Chaque couche est indépendante. Le compromis d'une seule ne donne pas accès
aux services : c'est tout l'intérêt de la défense en profondeur.