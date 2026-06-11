# Supervision — fichiers de configuration

Notes et configurations anonymisées de la stack de supervision
(Prometheus + Grafana + Alertmanager) hébergée dans un conteneur LXC dédié.

> Architecture, choix techniques et pièges : voir
> [`../docs/architecture/07-supervision.md`](../docs/architecture/07-supervision.md).

---

## Contenu

*(À enrichir au fil de la mise en place.)*

| Fichier | Contenu |
|---------|---------|
| (à venir) `prometheus.example.yml` | Scrape configs anonymisés (job_name, target labels, intervals) |
| (à venir) `alertmanager.example.yml` | Routing, receivers, templates Telegram (sans secrets) |
| (à venir) `rules/instance-down.example.yml` | Règle `up == 0` pendant N minutes |
| (à venir) `rules/disk-saturation.example.yml` | Règle `disk_avail < 15%` |
| (à venir) `rules/memory-pressure.example.yml` | Règle `mem_used > 90%` |
| (à venir) `node_exporter.service.example` | Unit systemd pour LXC (sans les binds spécifiques à l'hôte) |
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
