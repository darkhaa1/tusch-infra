# Supervision — fichiers de configuration

Configurations anonymisées de la stack de supervision et de logs
(Prometheus, Alertmanager, Grafana, Loki, Alloy), hébergée dans un conteneur
LXC dédié (`tusch-monitor-01`, `10.10.0.40`).

> Architecture, choix techniques et pièges : voir
> [`../docs/architecture/07-supervision.md`](../docs/architecture/07-supervision.md).

---

## Contenu

| Fichier | Contenu |
|---------|---------|
| `prometheus.example.yml` | Scrape configs : Prometheus, `node_exporter` sur 7 nœuds, `pve-exporter` (pattern relabel) |
| `rules.example.yml` | Règles d'alerte `InstanceDown`, `DiskAlmostFull`, `HighMemory` |
| `loki-config.example.yml` | Loki mono-instance, schéma v13 TSDB, rétention 31 jours |
| `alloy-caddy.example.alloy` | Agent Grafana Alloy du reverse proxy : logs Caddy → Loki |
| (à venir) `alertmanager.example.yml` | Routing, receivers, templates Telegram (sans secrets) |
| (à venir) `pve-exporter.example.yml` | Config exporter avec token Proxmox `<API_TOKEN>` |

## Conventions

- Tous les fichiers se terminent en `.example` quand ils contiennent des
  placeholders à la place de secrets, hostnames, IPs réelles, tokens.
- Les secrets sont **toujours** remplacés par un placeholder explicite :
  `<TELEGRAM_BOT_TOKEN>`, `<TELEGRAM_CHAT_ID>`, `<PROXMOX_API_TOKEN>`,
  `<HOSTNAME>`, etc.
- Les exemples sont fonctionnels une fois les placeholders substitués —
  ce ne sont pas des squelettes vides, mais des configurations validées
  en production avec les seules valeurs sensibles ôtées.
