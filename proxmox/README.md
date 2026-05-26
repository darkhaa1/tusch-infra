# Configurations Proxmox

Configurations de l'hôte Proxmox VE 8, anonymisées.

> ⚠️ Tous les fichiers `.example` contiennent des placeholders `<...>` à la
> place des valeurs sensibles (IP publiques, passerelles, interface physique).
> Les IP privées `10.10.0.0/24` (RFC 1918) sont conservées telles quelles
> pour la lisibilité.

## Contenu

| Fichier | Rôle |
|---------|------|
| `network/interfaces.example` | Configuration réseau de l'hôte (bridges, NAT, DNAT) |
| `firewall/cluster.fw.example` | Firewall Proxmox niveau datacenter (security groups) |
| `firewall/host.fw.example` | Firewall Proxmox niveau node |
| `systemd/lvm-pool-loopback.service` | Persistance du pool LVM-thin au reboot |

## Architecture réseau

```
Internet
   │
   ▼
<PHYS_IFACE>  (interface physique, slave de vmbr0, sans IP)
   │
   ▼
vmbr0  (bridge WAN — IP publique)
   ├─→  Hôte Proxmox
   ├─→  DNAT 80/443  ────────────┐
   └─→  NAT MASQUERADE            │
            │                     │
            ▼                     ▼
        vmbr1  (LAN privé 10.10.0.0/24)
            ├─→  CT 101 · Caddy        10.10.0.20   ◄── reçoit le trafic web (DNAT)
            ├─→  CT 200 · tusch-app    10.10.0.30
            └─→  CT 900 · template     (read-only)
```

### Principe

- **vmbr0** porte l'IP publique. L'interface physique est en `manual` (pas
  d'IP propre) et sert uniquement de port au bridge.
- **vmbr1** est un réseau privé isolé. Les conteneurs n'ont pas d'IP publique ;
  ils sortent sur Internet via **NAT MASQUERADE** (comme des machines derrière
  une box).
- Le trafic web entrant (**80/443**) est redirigé par **DNAT** vers le
  conteneur Caddy (`10.10.0.20`), qui assure le reverse proxy et le TLS.
- L'**accès admin** (SSH, interface Proxmox `:8006`) ne passe pas par ce
  chemin : il se fait via Tailscale (VPN chiffré) ou depuis une IP d'admin
  autorisée dans le firewall.

### Point d'attention : règle `fwbr+`

Quand le firewall Proxmox est activé sur un conteneur, PVE insère un
mini-bridge `fwbrXXX` entre le conteneur et `vmbr1`. Sans une zone conntrack
dédiée, le NAT cesse de fonctionner. D'où la règle :

```bash
post-up   iptables -t raw -I PREROUTING -i fwbr+ -j CT --zone 1
post-down iptables -t raw -D PREROUTING -i fwbr+ -j CT --zone 1
```

Détail complet dans [`../docs/pieges-resolus.md`](../docs/pieges-resolus.md) (piège #3).

## Application des changements

```bash
# Recharge la config réseau à chaud (peut figer la session SSH 2-3 s)
ifreload -a

# Vérifications
ip -br a                                  # bridges UP avec les bonnes IP
ip route                                  # route par défaut via vmbr0
iptables -t nat -L POSTROUTING -n -v      # compteur MASQUERADE > 0 après trafic
cat /proc/sys/net/ipv4/ip_forward         # doit retourner 1
```