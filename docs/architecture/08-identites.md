# Gestion des identités — Authentik (IdP / SSO)

Fournisseur d'identité centralisé pour l'infrastructure. Authentik fédère
l'authentification des services internes derrière un Single Sign-On, hébergé
dans un conteneur LXC dédié.

> Configurations concrètes anonymisées dans [`../../`](../../). Ce document
> explique les **choix de conception**, pas une recette à copier.

---

## Pourquoi un fournisseur d'identité

À mesure que les services s'accumulent (Proxmox, Grafana, OPNsense…), deux
problèmes apparaissent :

- **Multiplication des comptes** : un identifiant et un mot de passe par
  service, chacun à créer, retenir et faire tourner — autant d'occasions de
  réutilisation ou de faiblesse.
- **Services sans authentification native** : Prometheus et Alertmanager
  exposent leur UI sans login digne de ce nom.

Un **fournisseur d'identité (IdP)** centralise l'authentification : les services
délèguent la vérification de l'identité à l'IdP au lieu de gérer leurs propres
comptes. Le **SSO** en est la conséquence visible : on s'authentifie une fois,
tous les services connectés font confiance à ce verdict. L'IdP devient aussi le
point unique où **couper un accès** — désactiver un compte à un seul endroit le
coupe partout.

### Place dans la défense en profondeur

Cette brique complète une trilogie :

| Étape | Couches |
|-------|---------|
| **Prévention** | Firewall, segmentation VLAN, IDS/IPS Suricata |
| **Détection** | Supervision Prometheus / Grafana / Alertmanager |
| **Contrôle d'accès** | IAM — Authentik (cette doc) |

Empêcher, voir, et maîtriser qui entre.

---

## Choix : Authentik

| Solution | Évaluation |
|----------|------------|
| **Keycloak** | Standard entreprise, très complet, mais lourd (stack Java) et surdimensionné pour un homelab. Courbe d'apprentissage raide pour un premier IdP. |
| **Authelia** | Léger, mais *forward-auth* pur : pas un IdP complet (pas de serveur OIDC/SAML mature). Protège des services derrière un proxy mais ne fédère pas les identités. |
| **Authentik** ✅ | IdP complet (OIDC, SAML, LDAP, forward auth), déploiement Docker simple. Meilleur ratio apprentissage / friction pour un homelab pré-professionnel. |

---

## Déploiement

### Conteneur dédié

Un LXC dédié (`tusch-auth-01`), Debian 12, cloné du template. La supervision
tourne déjà dans son propre CT ; l'IAM mérite le même isolement — c'est lui qui
détient les credentials d'accès aux services.

### Docker dans un LXC non privilégié — le prérequis critique

Docker ne démarre **pas** dans un conteneur LXC non privilégié sans deux
features Proxmox :

```bash
pct set <CTID> --features nesting=1,keyctl=1
```

- `nesting=1` autorise les cgroups imbriqués (le conteneur Docker dans le
  conteneur LXC) ;
- `keyctl=1` donne accès au *keyring* du kernel dont le démon Docker a besoin.

Sans ces features, `dockerd` échoue au démarrage avec des erreurs de montage
cgroup ou de keyring souvent illisibles. C'est **le** prérequis qui fait perdre
une heure quand on l'oublie.

### Docker CE + validation

Docker CE depuis le dépôt officiel (clé GPG dans `/etc/apt/keyrings/`), puis
validation de toute la chaîne avant d'y poser quoi que ce soit :

```bash
docker run --rm hello-world
```

Si `nesting`/`keyctl` manquaient, c'est ici que ça casse — autant le savoir sur
une image de 13 Ko que sur la stack complète.

### Authentik via docker-compose

Stack officielle (goauthentik.io) : `server` + `worker` + PostgreSQL 16 +
Redis. Les secrets (`PG_PASS`, `AUTHENTIK_SECRET_KEY`) sont **générés
aléatoirement** (jamais choisis à la main) et le fichier `.env` est en `600`.

> `AUTHENTIK_SECRET_KEY` signe les sessions et les tokens : le changer invalide
> toutes les sessions, le perdre casse l'instance.

Le compte administrateur se crée **obligatoirement** via une URL dédiée au
premier accès (`/if/flow/initial-setup/`). Tant que ce flow n'est pas complété,
l'interface principale n'est pas utilisable — ce n'est pas dans les menus, c'est
une URL à connaître.

---

## Premier branchement SSO — Grafana en OIDC

### Le couple application + provider

Brancher un service dans Authentik demande **deux objets liés** :

- le **provider** est le moteur : il parle le protocole (OAuth2/OIDC), détient
  le `client_id`/`client_secret` et les *redirect URIs* ;
- l'**application** est l'objet « métier » résolu quand un service se présente,
  et pointe vers son provider.

Un provider **sans** application produit l'erreur `Failed to resolve
application` : le moteur existe mais rien ne le réclame. Toujours créer les deux.

### Redirect URIs en mode strict = contrôle de sécurité

Le mode strict impose que l'URI de redirection après login corresponde
**exactement** à une URI déclarée. C'est la défense contre le détournement du
code d'autorisation : un attaquant ne peut pas se faire renvoyer le code vers un
domaine qu'il contrôle.

Corollaire opérationnel : toute modification de l'URL d'un service (interne →
public, changement de domaine) impose de mettre à jour les redirect URIs du
provider. *(Voir piège « Redirect URI Error » dans `../pieges-resolus.md`.)*

### Côté Grafana

Bloc `[auth.generic_oauth]` : `client_id`/`client_secret`, scopes minimaux
(`openid profile email`), URLs `auth`/`token`/`api`, et surtout :

```ini
skip_org_role_sync = true
```

`skip_org_role_sync = true` laisse le rôle Grafana géré **à la main** au lieu
d'être écrasé à chaque login. Indispensable tant qu'on est en mono-utilisateur.

> **Évolution multi-utilisateurs** *(à venir)* : remplacer la gestion manuelle
> par un mapping automatique via `role_attribute_path`, qui lira un groupe
> Authentik (ex. membres de `grafana-admins` → rôle Admin).

### Toujours garder une porte locale

L'admin local Grafana **reste actif**. On ne pose jamais `disable_login_form`
tant qu'un seul IdP est branché : si Authentik tombe, le formulaire local est
la seule porte qui reste. Couper la porte locale avant d'avoir un second facteur
de secours, c'est se préparer un *lockout*.

---

## Exposition publique

- **DNS** : enregistrements `auth` et `grafana` en mode *Proxied* (le trafic
  passe par l'edge — CDN, WAF, masquage de l'IP d'origine — avant le reverse
  proxy).
- **Reverse proxy** : deux vhosts en `reverse_proxy` avec logs JSON dédiés.

### Ne pas dupliquer les headers de sécurité

Règle de répartition des responsabilités :

- **contenu statique servi par le proxy** → c'est le proxy qui pose les headers
  (HSTS, CSP…) ;
- **application proxifiée** → l'application gère ses propres headers, on ne les
  rajoute pas par-dessus dans le proxy.

Ici HSTS est déjà injecté à l'edge. Le dupliquer dans le proxy puis
potentiellement dans l'application créerait des en-têtes contradictoires ou en
double. **Un header de sécurité, une seule source responsable.**

### URLs OIDC sur le domaine public (hairpin)

Les URLs `token`/`api` de Grafana pointent vers le domaine **public** plutôt que
vers l'IP interne. Le trafic Grafana → Authentik ressort donc vers l'edge puis
revient (*hairpin*), au lieu de rester sur le LAN. C'est volontaire : un seul
jeu d'URLs publiques est plus simple à maintenir qu'un *split* interne/externe
(source classique de bugs OIDC, où `token_url` serait interne mais `auth_url`
public). Le léger surcoût réseau est négligeable à cette échelle.

---

## Segmentation firewall par conteneur

Le firewall Proxmox au niveau de **chaque** CT est la seule couche qui limite
le **mouvement latéral** à l'intérieur du LAN. Une fois dans le LAN, aucune
autre couche ne filtre le trafic intra-LAN.

### Chaîne d'activation à 4 maillons

| Maillon | Où | Effet |
|---------|----|----|
| 1. Datacenter | Datacenter → Firewall → Options | Interrupteur global du cluster |
| 2. Node | Node → Firewall → Options | Active le firewall sur l'hôte |
| 3. Option du CT | CT → Firewall → Options (`enable: 1`) | Interrupteur **logique** du CT |
| 4. Case `firewall=1` sur la NIC | CT → Network → net0 | Insère **physiquement** le `fwbr` dans le chemin réseau |

Les maillons 1 à 3 sont logiques ; le **maillon 4 est physique**. Tant que
`firewall=1` n'est pas coché sur la carte réseau, le `fwbr` n'est pas inséré :
les règles existent mais aucun trafic ne les traverse.

> **Contre-exemple volontaire** : la VM OPNsense a `firewall=0` sur ses pattes
> réseau. C'est *elle* le pare-feu du lab — on ne veut surtout pas que le
> firewall Proxmox s'interpose sur son trafic.

### Pourquoi segmenter les CT sensibles

Le CT de supervision détient un **token API Proxmox** ; le CT d'identité détient
les **credentials d'accès aux services**. Ce sont les cibles prioritaires d'un
mouvement latéral : si le CT applicatif exposé à Internet est compromis,
l'attaquant cherchera à rebondir vers ces CT-là. Le firewall par-CT est ce qui
l'en empêche.

### Principe des règles

**Une règle = un flux légitime identifié.** Jamais de règle « au cas où » ou
« pour plus tard ». Chaque ouverture correspond à une origine et une raison
nommables :

- l'UI exposée publiquement est joignable par le reverse proxy (pour le public)
  et par l'admin ;
- les services sans authentification (Prometheus, Alertmanager) ne sont
  joignables **que** par l'admin — jamais exposés.

> La source « admin » est unique grâce au subnet router Tailscale (SNAT) : tout
> le trafic d'administration entre dans le LAN avec l'IP de l'hôte. Une seule
> source à autoriser au lieu d'une par appareil. *(Voir
> [`02-reseau.md`](02-reseau.md) § Subnet router.)*

> **À compléter** : durcissement firewall du CT d'identité (maillon 4 + option
> `enable`, puis règle d'accès depuis le reverse proxy et l'admin uniquement).

---

## Hygiène des secrets

Pendant la mise en place, des secrets ont transité en clair (captures, copies) :
token de bot de notification, puis `client_secret` OAuth. Réponse systématique,
**sans débat : rotation.** Un secret qui a transité en clair est considéré
compromis. La rotation est un réflexe de quelques minutes — le coût d'un doute
permanent sur un secret est toujours supérieur.

---

## État et perspectives

**En place** : IdP Authentik opérationnel, premier service (Grafana) en SSO
OIDC, exposition publique des UIs `auth` et `grafana`, segmentation firewall du
CT de supervision.

**À venir** :

- durcissement firewall du CT d'identité ;
- mapping automatique des rôles Grafana par groupes (multi-utilisateurs) ;
- branchements OIDC suivants : Proxmox, *forward auth* pour Prometheus /
  Alertmanager (les services sans auth native).

---

*Document mis à jour au fil de la mise en place de l'infrastructure.*
