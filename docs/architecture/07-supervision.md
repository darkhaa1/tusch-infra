# Supervision — Prometheus, Grafana, Alertmanager

Stack de supervision et d'alerting, hébergée dans un conteneur LXC dédié et
isolée du chemin de production : un crash du monitoring ne touche pas l'app,
et inversement.

---

## Architecture

```
                ┌──────────────────────────────────┐
                │   CT monitoring  (LXC dédié)     │
                │                                  │
                │  ┌────────────┐   ┌────────────┐ │
                │  │ Prometheus │──►│  Grafana   │ │
                │  │  (scrape)  │   │  (UI)      │ │
                │  └─────┬──────┘   └────────────┘ │
                │        │                         │
                │        ▼                         │
                │  ┌──────────────┐                │
                │  │ Alertmanager │──►  Telegram   │
                │  └──────────────┘                │
                └────────┬─────────────────────────┘
                         │
                ┌────────┴────────────────────────┐
                │  scrape /metrics                │
                ▼                                 ▼
        ┌──────────────────┐         ┌──────────────────┐
        │ node_exporter    │         │ pve-exporter     │
        │ sur N nœuds      │         │ (API Proxmox     │
        │ (CTs + hôte)     │         │  read-only)      │
        └──────────────────┘         └──────────────────┘
```

| Composant | Source | Rôle |
|-----------|--------|------|
| **Prometheus 2.42** | paquet Debian `prometheus` | Collecte des métriques (scrape pull), stockage série temporelle. UI principale sur `/`, UI historique sur `/classic/`. |
| **Grafana** | repo apt officiel Grafana (clé GPG dans `/etc/apt/keyrings/`) | Visualisation, dashboards. La version Debian est absente du dépôt — passage par le repo officiel. |
| **Alertmanager** | paquet Debian `prometheus-alertmanager` | Routage, regroupement et envoi des alertes (port 9093) |
| **node_exporter** | paquet Debian `prometheus-node-exporter` | Métriques OS (CPU, RAM, disque, réseau) sur chaque nœud |
| **pve-exporter** | `pip install prometheus-pve-exporter` dans un venv | Métriques spécifiques Proxmox (VMs, CTs, storages, cluster) |

---

## Choix d'architecture

### LXC dédié plutôt que sur l'hôte

Trois raisons :

- **Isolation** : un bug ou une explosion de cardinalité dans Prometheus ne
  doit pas faire tomber Proxmox lui-même.
- **Reproductibilité** : tout le stack est cloisonné dans un seul conteneur,
  facile à snapshot, restaurer, migrer.
- **Permissions** : éviter d'ajouter des services réseau directement sur le
  Dom0 Proxmox (principe de moindre privilège côté hôte).

### Pull plutôt que push

Prometheus va chercher les métriques (scrape) plutôt qu'attendre qu'on les
pousse. Avantages :

- Les exporters n'ont pas besoin de connaître Prometheus (pas de config dans
  chaque source).
- Une cible qui tombe est immédiatement visible (`up == 0`), c'est le mécanisme
  natif de détection d'instance down.
- Cohérent avec le principe : centraliser la complexité, garder les agents
  minimaux.

---

## node_exporter — métriques OS

Déployé sur 4 nœuds : l'hôte Proxmox, le conteneur reverse-proxy (Caddy), le
conteneur applicatif (`tusch-app`), et le conteneur de supervision lui-même.
Paquet Debian `prometheus-node-exporter`, port `9100`.

### Particularité de l'hôte — bind restreint au LAN privé

Sur l'hôte Proxmox, l'exporter ne doit **pas** écouter sur l'IP publique. La
politique du firewall Proxmox en INPUT droppe déjà tout par défaut, mais on
applique en plus le principe de défense en profondeur côté service : on
restreint explicitement le bind à l'IP du LAN privé.

Fichier `/etc/default/prometheus-node-exporter` sur l'hôte :

```
ARGS="--web.listen-address=<IP_HOST_LAN>:9100"
```

Conséquence : même si une règle firewall était mal posée, l'exporter ne
servirait pas sur l'IP publique — la socket d'écoute n'y est tout simplement
pas. Deux couches indépendantes (firewall + bind) qui protègent la même
chose : c'est l'intention de la défense en profondeur.

### Particularité du conteneur

Dans un LXC, le bind doit rester à la valeur par défaut (`ARGS=""`) — l'IP du
LAN du LXC n'est pas la même que celle de l'hôte, et un `--web.listen-address`
copié de la config de l'hôte cause un crash au démarrage (l'IP référencée
n'existe pas dans le conteneur). Voir piège correspondant.

---

## pve-exporter — métriques Proxmox

L'exporter interroge l'API Proxmox pour exposer des métriques spécifiques
(état des VMs/CTs, utilisation des storages, statut du cluster, etc.).
Installé dans un virtualenv Python dédié plutôt qu'avec les paquets système,
pour ne pas polluer Python global et faciliter les mises à jour de
l'exporter sans toucher au système.

```bash
python3 -m venv /opt/pve-exporter
/opt/pve-exporter/bin/pip install prometheus-pve-exporter
```

L'exporter écoute en local sur le port `9221`. Prometheus le scrape via un
relabel pattern (voir plus bas).

### Authentification — principe de moindre privilège

L'exporter doit accéder à l'API Proxmox **en lecture seule**. Configuration
côté Proxmox :

- **Utilisateur Proxmox dédié** : `monitoring@pve`, sans accès shell, juste
  pour l'API.
- **Rôle** : `PVEAuditor` (rôle natif Proxmox qui donne lecture sur tout
  l'inventaire et les métriques, aucun droit d'écriture). Appliqué sur `/`
  (racine de la hiérarchie de permissions).
- **API token** : créé sur cet utilisateur avec le flag **`--privsep 0`**
  (« privilege separation off »). Concrètement, le token hérite alors
  pleinement des droits du user — `PVEAuditor`, donc lecture seule. Sans
  `--privsep 0`, le token a un jeu de droits indépendant qu'il faut explicitement
  attribuer ; avec `--privsep 0`, il hérite, ce qui est plus simple pour un
  exporter dédié et plus lisible à auditer (le contrôle d'accès se lit en un
  seul endroit, sur l'utilisateur).

L'exporter ne peut donc rien modifier sur Proxmox : il peut lire la liste des
VMs, leur état, leurs ressources, mais pas en créer, démarrer, supprimer.

### Stockage du token et service systemd

Le token est référencé dans `/etc/prometheus/pve.yml` côté CT supervision :

- Propriétaire `prometheus`, permissions `600` — lisible uniquement par le
  service.
- Jamais versionné dans Git ; le fichier réel reste hors du dépôt, seul un
  équivalent `.example` avec placeholders peut y figurer.

Service systemd dédié `pve-exporter.service` :

- `User=prometheus`
- `ExecStart=/opt/pve-exporter/bin/pve_exporter ...`
- `Restart=on-failure`
- `enabled` (démarre au boot du conteneur)

---

## Firewall Proxmox — Security Group dédié

Sur le datacenter Proxmox, un Security Group `monitoring-access` est créé puis
appliqué au node. Il autorise **uniquement le CT de supervision** à atteindre
deux ports de l'hôte :

- **tcp/8006** — API Proxmox, nécessaire à `pve-exporter` pour lire les
  métriques de l'hyperviseur.
- **tcp/9100** — `node_exporter` de l'hôte, scrapé par Prometheus du CT.

Aucun autre conteneur n'est autorisé à parler à ces ports — en particulier
pas le conteneur applicatif exposé indirectement à Internet via le reverse
proxy. Justification : si l'app est compromise, l'attaquant ne doit pas avoir
de route préapprouvée vers l'API de l'hyperviseur. Le seul CT qui a une raison
légitime de causer avec l'hôte sur ces deux ports est celui de la supervision,
qui n'a aucune entrée publique.

C'est l'application directe du moindre privilège **réseau** : un service ne
parle qu'aux endpoints dont il a besoin pour faire son travail, rien d'autre.

---

## Prometheus — jobs de scrape et relabel

Deux jobs dans `prometheus.yml` :

### Job `node` — node_exporter sur les 4 nœuds

Liste statique de targets sur le port `9100`. Un job, quatre IPs cibles, tout
en clair. Rien d'exotique.

### Job `pve` — relabel pattern des exporters proxy

`pve-exporter` est un *exporter proxy* : il expose lui-même un endpoint
unique (`localhost:9221/pve`), et c'est le **paramètre `?target=`** qui
indique quelle instance Proxmox interroger.

Le pattern de scrape côté Prometheus s'écrit comme suit (déclaration
sémantique, simplifiée) :

- `metrics_path: /pve`
- `static_configs.targets:` la liste des **noms** des hyperviseurs Proxmox à
  scraper (ici un seul : le nom de l'hôte courant)
- `relabel_configs:` trois étapes (pattern standard de tous les exporters
  proxy) :
  1. Recopier le label `__address__` (le nom du hyperviseur) dans le
     paramètre URL `__param_target`.
  2. Recopier ce même `__address__` dans le label `instance` (pour que les
     dashboards montrent bien le nom de l'hôte, pas `localhost:9221`).
  3. Réécrire l'`__address__` vers `localhost:9221` (l'adresse réelle de
     l'exporter).

Résultat : un seul exporter scrape N hyperviseurs en parallèle, sans
duplication de config — le pattern est extensible à un cluster Proxmox plus
tard sans changer de structure.

### Validation avant reload

Toujours valider le YAML avant de demander à Prometheus de recharger :

```bash
promtool check config /etc/prometheus/prometheus.yml
systemctl reload prometheus
```

Un YAML invalide laisse Prometheus tomber au reload, et le SIGHUP suivant
n'est pas mieux. Mieux vaut détecter l'erreur avant.

---

## Dashboards Grafana

Datasource Prometheus configurée sur `http://localhost:9090` (Prometheus
local au CT). Deux dashboards officiels importés depuis grafana.com :

- **Node Exporter Full** (ID `1860`) — vue complète OS par nœud (CPU, RAM,
  disque, IO, réseau, contextes, descripteurs de fichiers). Dashboard de
  référence de la communauté Prometheus, point de départ pour le tuning.
- **Proxmox via pve-exporter** (ID `10347`) — vue agrégée à partir de
  `pve-exporter` (nombre de VMs/CTs par état, utilisation des storages,
  métriques cluster).

### Aucune exposition publique de l'UI Grafana

L'accès passe **uniquement** par tunnel SSH (`ssh -L 3000:localhost:3000 ...`)
depuis le poste d'admin via le canal hors-bande (cf.
[`03-securite.md`](03-securite.md) couche 7). Les ports `9090` (Prometheus),
`9100` (node_exporter), `3000` (Grafana) **ne sont pas exposés sur Internet** —
vérifié depuis l'extérieur, ils ne répondent pas. Le seul chemin d'admin
passe par SSH/Tailscale, pas par une UI web publiée.

---

## Alertmanager — règles et notifications

Trois règles initiales déclarées dans `/etc/prometheus/rules.yml`, attachées
à Prometheus via les directives `alerting:` et `rule_files:` dans
`prometheus.yml`.

| Règle | Condition | `for` | Sévérité |
|-------|-----------|-------|----------|
| **InstanceDown** | `up == 0` | 5 min | critical |
| **DiskAlmostFull** | espace libre < 15 % sur une partition (hors `tmpfs` / `overlay`) | 10 min | warning |
| **HighMemory** | mémoire utilisée > 90 % | 10 min | warning |

Les `for` (durée de persistance avant déclenchement) évitent les alertes
flash sur un blip momentané. Cinq minutes pour InstanceDown, dix pour les
saturations qui peuvent osciller.

Les filesystems `tmpfs` et `overlay` sont **exclus** de DiskAlmostFull : ils
ne sont pas du stockage persistant, leur saturation a une autre sémantique
(et leur passage à 100 % est parfois normal).

### Notifications Telegram

Routage des alertes vers un canal Telegram dédié via `telegram_configs`. Bot
dédié à la supervision (créé via BotFather), `bot_token` et `chat_id`
référencés dans la config Alertmanager. Notifications push immédiates,
indépendantes du mail.

### Test de bout en bout — déclenchement contrôlé

Méthode utilisée pour valider la chaîne complète Prometheus → règle → AM →
Telegram :

1. Arrêt volontaire d'un `node_exporter` sur un CT applicatif : `systemctl
   stop prometheus-node-exporter`.
2. Côté Prometheus, la cible passe en `up == 0`. L'alerte InstanceDown passe
   en `pending` (mécanisme de déduplication pendant la fenêtre `for`).
3. À T+5 min, `pending` → `firing`. Alertmanager reçoit le signal.
4. Une notification Telegram arrive immédiatement, avec le label `instance`
   identifiant le CT en cause.
5. Redémarrage de l'exporter : la cible revient `up == 1`, Prometheus passe
   l'alerte en `resolved`, et Alertmanager pousse une notification
   « RESOLVED » sur Telegram.

Sans ce test, on ne sait pas si la chaîne marche — chaque maillon (règle,
templating, secret bot, ACL chat) peut casser silencieusement.

### Hygiène secrets — leçon de terrain

Pendant le setup, **le token du bot Telegram a été visible sur une capture
d'écran** partagée pendant une session de débogage. Action prise :

- Le token est considéré comme **compromis** dès lors qu'il a transité en
  clair, même brièvement.
- Régénération immédiate via BotFather → `/revoke` (l'ancien token devient
  invalide instantanément).
- Mise à jour de la config Alertmanager avec le nouveau token, restart du
  service.

Principe à retenir : **un secret exposé est un secret rotaté**, même si
« personne n'a sans doute vu », « c'était juste 30 secondes », « le canal
était privé ». La rotation est gratuite (quelques minutes), un secret
compromis qui reste actif ne l'est pas.

---

## Robustesse — test de reboot

Reboot complet du CT supervision réalisé après mise en place. Les **cinq
services systemd** remontent seuls au boot, sans intervention :

- `prometheus`
- `grafana-server`
- `pve-exporter`
- `prometheus-node-exporter`
- `prometheus-alertmanager`

Vérification : `systemctl is-active prometheus grafana-server pve-exporter
prometheus-node-exporter prometheus-alertmanager` après reboot → tout est
`active`. Aucun `enabled` oublié, aucune dépendance manquante.

Sans ce test, on ne sait pas si la stack survit à une panne d'hôte ou à un
reboot pour mise à jour kernel — c'est exactement le moment où on a le plus
besoin de la supervision, donc le moment où il ne faut pas qu'elle soit
manuelle à redémarrer.

---

## Pièges marquants

Détails complets dans [`../pieges-resolus.md`](../pieges-resolus.md) :

- **pve-exporter renvoie 500** — l'API Proxmox `:8006` était bloquée par
  l'INPUT DROP du firewall Proxmox depuis le LAN. Solution : Security Group
  `monitoring-access` autorisant la source = CT monitoring vers `:8006` et
  `:9100`.
- **node_exporter du CT en crash-loop** — `ARGS="--web.listen-address=..."`
  copié de la config de l'hôte, IP référencée inexistante dans le CT.
  Solution : `ARGS=""`.
- **Alertmanager refuse de démarrer** — fichier de config en `root:root 600`,
  illisible par l'utilisateur `prometheus`. Solution : `chown
  prometheus:prometheus`. Complément : après 5 crashs rapides, systemd exige
  un `reset-failed` avant de re-tenter.
- **Target `localhost:9100` en `connection refused`** — paquet installé mais
  service jamais démarré. Solution : `ss -tlnp | grep 9100` avant d'incriminer
  la config.
- **DNS LXC cassé par Tailscale MagicDNS héritée de l'hôte** — solution
  globale `tailscale set --accept-dns=false` sur l'hôte, plus découplage de
  chaque CT via `pct set --nameserver` (cf. piège dédié).

---

## État

- LXC supervision dédié, isolé du LAN applicatif (pas joignable depuis
  Internet, pas exposé publiquement sur aucun port)
- `node_exporter` sur **4 nœuds** (hôte Proxmox avec bind LAN restreint,
  CT reverse-proxy, CT applicatif, CT supervision lui-même) — scrape OK sur
  tous
- `pve-exporter` dans un venv, configuré avec un utilisateur Proxmox
  `PVEAuditor` + API token `--privsep 0` (lecture seule, audit lisible
  d'un coup d'œil sur l'utilisateur)
- Firewall Proxmox : Security Group `monitoring-access` ouvre uniquement le
  CT supervision vers `:8006` et `:9100` de l'hôte ; tous les autres CTs
  restent isolés
- Dashboards officiels Grafana `1860` (Node Exporter Full) et `10347`
  (Proxmox) en service
- 3 règles Alertmanager actives, testées de bout en bout (arrêt volontaire
  d'un exporter → `firing` à T+5 min → notification Telegram → `resolved`
  au redémarrage)
- Bot Telegram dédié, token rotaté après une exposition en capture d'écran
  pendant le setup
- Reboot complet du CT supervision validé : tous les services remontent
  seuls

---

## Pour aller plus loin

- **Loki** pour la centralisation des logs (cf. perspective du README)
- **Blackbox exporter** pour la supervision des endpoints HTTPS publics
  (latence, expiration certificats, codes 200)
- Export des alertes Suricata (`eve.json` cf.
  [`06-ids-ips-suricata.md`](06-ids-ips-suricata.md)) vers Loki + dashboard
  dédié dans Grafana
- Resserrer les seuils d'alerte après quelques semaines de baseline
- Documentation runbook par règle d'alerte (que faire quand celle-ci se
  déclenche)
