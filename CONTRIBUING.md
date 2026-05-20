# Conventions

## Commits

Format des messages : `type(scope): description`

Types : `feat`, `fix`, `docs`, `refactor`, `chore`

Exemples :
- `feat(proxmox): ajoute la configuration réseau anonymisée`
- `docs(articles): publie l'article sur le piège NAT fwbr+`
- `refactor(diagrams): met à jour le diagramme d'architecture globale`

## Anonymisation

Toute configuration publiée doit être anonymisée :
- IP publiques → `<HOST_PUB_IP>` ou `<IPV6_PUB>`
- IP Tailscale → `<TAILSCALE_IP>`
- Fingerprints SSH → retirés
- Mots de passe et tokens → jamais, même dans les exemples

## Style

Documentation en français principal. Termes techniques anglais
conservés quand c'est l'usage natif (DROP, ACCEPT, snapshot, etc.).