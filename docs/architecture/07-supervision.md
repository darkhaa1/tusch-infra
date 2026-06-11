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

| Composant | Rôle |
|-----------|------|
| **Prometheus** | Collecte des métriques (scrape pull), stockage série temporelle |
| **Grafana** | Visualisation, dashboards |
| **Alertmanager** | Routage, regroupement et envoi des alertes |
| **node_exporter** | Métriques OS (CPU, RAM, disque, réseau) sur chaque nœud |
| **pve-exporter** | Métriques spécifiques Proxmox (VMs, CTs, storages) |

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

Déployé sur 5 nœuds : l'hôte Proxmox et un sous-ensemble de conteneurs
représentatifs (reverse proxy, application, supervision elle-même, etc.).

### Service systemd minimal

L'exporter tourne sous un utilisateur non-privilégié dédié, exposé en interne
sur le port `9100`. Le scrape passe par le LAN privé — aucune exposition
publique.

### Piège LXC

Sur l'hôte Proxmox, la config systemd de référence inclut souvent un
`ProtectHome=true` et plusieurs `BindReadOnlyPaths=`. **Ne pas copier-coller
cette config telle quelle dans un LXC** : le bind échoue (chemins inexistants
ou non remontables côté conteneur) et le service refuse de démarrer. Il faut
une version simplifiée pour LXC, sans les binds spécifiques à l'hôte. Voir
piège correspondant.

---

## pve-exporter — métriques Proxmox

L'exporter interroge l'API Proxmox pour exposer des métriques spécifiques
(état des VMs/CTs, utilisation des storages, statut du cluster, etc.).

### Authentification — principe de moindre privilège

L'exporter a besoin d'accéder à l'API Proxmox **en lecture seule**. Plutôt que
d'utiliser un compte admin, on crée :

- Un **utilisateur Proxmox dédié** (`monitoring@pve` par exemple), sans accès
  shell, juste pour l'API.
- Un **rôle** : `PVEAuditor` (rôle natif Proxmox qui donne lecture sur tout
  l'inventaire et les métriques, sans aucun droit d'écriture).
- Un **API token** scoped à cet utilisateur, configuré côté exporter.

L'exporter ne peut donc rien modifier sur Proxmox : il peut lire la liste des
VMs, leur état, leurs ressources, mais pas en créer, démarrer, supprimer.
Application directe du moindre privilège — si le secret de l'exporter fuite,
l'impact est limité à de la lecture.

> Le token est traité comme un secret : stocké dans un fichier dont les
> permissions limitent la lecture au seul utilisateur du service, jamais
> versionné dans Git.

---

## Dashboards Grafana

Deux dashboards en service :

- **Node Exporter Full** — vue complète OS par nœud (CPU, RAM, disque, IO,
  réseau, contextes, descripteurs de fichiers). Dashboard très utilisé de la
  communauté, point de départ pour le tuning.
- **Proxmox** — vue agrégée à partir de `pve-exporter` (nombre de VMs/CTs par
  état, utilisation des storages, métriques cluster).

Les dashboards sont importés depuis le hub Grafana ; les sources de données
sont configurées pour pointer vers Prometheus interne au CT supervision.

---

## Alertmanager — règles et notifications

Trois règles initiales, suffisamment génériques pour couvrir les pannes les
plus fréquentes sans déclencher pour rien :

| Règle | Condition (sémantique) | Pourquoi |
|-------|------------------------|----------|
| **Instance down** | `up == 0` pendant N minutes | Une cible ne répond plus → détection immédiate |
| **Disque > 85 %** | Espace libre < 15 % sur une partition | Anticiper la saturation, pas attendre l'urgence |
| **RAM > 90 %** | Mémoire utilisée > 90 % pendant N minutes | Pression mémoire soutenue, risque OOM |

Les seuils (85 % disque, 90 % RAM) sont volontairement larges au démarrage,
pour éviter le bruit. Ils seront resserrés une fois la baseline de l'infra
connue.

### Notifications Telegram

Routage des alertes vers un canal Telegram dédié : notifications push
immédiates, indépendantes du mail. Le bot Telegram et le chat ID sont
référencés dans la config Alertmanager via une variable d'environnement, le
secret n'apparaît pas dans le fichier YAML.

### Permissions de la config Alertmanager

Le service tourne sous l'utilisateur `prometheus` (créé par le paquet). Le
fichier de config doit donc être **lisible par cet utilisateur**, sinon
Alertmanager refuse de démarrer en silence (les logs systemd disent juste
« failed to start » sans grand détail). Voir piège correspondant.

---

## Pièges marquants

Détails complets dans [`../pieges-resolus.md`](../pieges-resolus.md) :

- **node_exporter en crash dans un LXC** — config systemd copiée depuis
  l'hôte avec des binds qui n'existent pas dans le CT ; service refuse de
  démarrer. Solution : config simplifiée pour LXC.
- **Alertmanager refuse de démarrer** — fichier de config en `root:root 600`,
  illisible par l'utilisateur `prometheus`. Solution : `chown` au bon
  utilisateur ou ajustement de l'umask.
- **DNS des LXC cassé par Tailscale MagicDNS héritée de l'hôte** — les CTs
  pointaient vers `100.100.100.100` (resolver Tailscale) qui ne pouvait pas
  résoudre les noms publics, scrape vers `*.example.com` impossible. Solution
  côté hôte : `tailscale set --accept-dns=false`, puis les CTs héritent d'un
  resolver fonctionnel.

---

## État

- LXC supervision dédié, isolé du LAN applicatif
- `node_exporter` sur 5 nœuds (scrape réussi sur tous)
- `pve-exporter` configuré avec un utilisateur Proxmox `PVEAuditor` + API
  token (lecture seule)
- Dashboards Node Exporter Full et Proxmox en service
- 3 règles d'alerte actives (instance down, disque > 85 %, RAM > 90 %)
- Notifications Telegram opérationnelles (testées par déclenchement contrôlé
  d'une règle)

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
