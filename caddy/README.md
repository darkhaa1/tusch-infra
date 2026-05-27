# Reverse proxy — Caddy

Caddy tourne dans son propre conteneur LXC (CT 101, `10.10.0.20`) et sert de
point d'entrée web unique de l'infrastructure. Il termine le TLS et route le
trafic vers les applications du LAN privé.

## Rôle dans la chaîne

```
Internet
   │
   ▼
Cloudflare           (CDN, WAF, DDoS, TLS edge)
   │  (Proxied — IP réelle masquée)
   ▼
Firewall hébergeur   (80 / 443)
   │
   ▼
Hôte Proxmox         (DNAT 80/443 → 10.10.0.20)
   │
   ▼
CT 101 · Caddy       ◄── ce conteneur
   ├─→  tusch.mn / www   →  CT 200 · Next.js  (10.10.0.30:3000)
   └─→  api.tusch.mn     →  CT 200 · NestJS   (10.10.0.30:3310)
```

Caddy est le seul conteneur à recevoir du trafic Internet. Les applications
(CT 200) ne sont **jamais exposées directement** : elles n'écoutent que sur le
LAN privé, accessibles uniquement à travers le reverse proxy.

## Pourquoi Caddy

- **TLS automatique** : Caddy obtient et renouvelle seul les certificats
  Let's Encrypt, sans cron ni intervention.
- **Configuration minimale** : le Caddyfile est court et lisible comparé à
  un équivalent Nginx/Apache.
- **HTTPS par défaut** : redirection HTTP→HTTPS automatique.

## Sécurité

### En-têtes HTTP

Chaque site renvoie un jeu d'en-têtes de sécurité standard :

| En-tête | Rôle |
|---------|------|
| `Strict-Transport-Security` | Force HTTPS côté navigateur (HSTS) |
| `X-Content-Type-Options: nosniff` | Empêche le MIME-sniffing |
| `X-Frame-Options: SAMEORIGIN` | Anti-clickjacking (pas d'iframe externe) |
| `Referrer-Policy` | Limite la fuite d'URL vers les tiers |

Combinés au durcissement TLS côté Cloudflare, ces en-têtes contribuent au
score **A+ SSL Labs** (voir [`../docs/pieges-resolus.md`](../docs/pieges-resolus.md) #7).

### Isolation

Caddy est dans un conteneur **non privilégié** dédié, avec le firewall PVE
actif. Sa seule exposition est 80/443 ; tout le reste est filtré.

## Installation

Dépôt officiel Caddy (Cloudsmith) :

```bash
apt install -y debian-keyring debian-archive-keyring apt-transport-https curl
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
  | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
  | tee /etc/apt/sources.list.d/caddy-stable.list
apt update && apt install -y caddy
```

## Exploitation

```bash
# Valider la syntaxe avant tout rechargement
caddy validate --config /etc/caddy/Caddyfile

# Recharger sans coupure (conserve les connexions)
systemctl reload caddy

# Suivre les logs en temps réel
journalctl -u caddy -f
```

## Pièges rencontrés

Deux pièges classiques documentés dans
[`../docs/pieges-resolus.md`](../docs/pieges-resolus.md) :

- **#5** — permission denied sur `/var/log/caddy/` : le dossier de logs doit
  appartenir à l'utilisateur `caddy`.
- **#6** — page HTML affichée en texte brut : la directive `respond` renvoie
  du `text/plain` par défaut, il faut forcer le `Content-Type`.

## Préparation des logs

Caddy doit pouvoir écrire dans son dossier de logs :

```bash
mkdir -p /var/log/caddy
chown -R caddy:caddy /var/log/caddy
chmod 755 /var/log/caddy
```

## Évolution prévue

- **Cloudflare Origin Certificate** : remplacer Let's Encrypt par un certificat
  d'origine Cloudflare (validité longue) pour simplifier la chaîne en mode
  Proxied.
- **Authenticated Origin Pulls** : n'accepter que le trafic provenant de
  Cloudflare, pour fermer tout accès direct à l'origine.