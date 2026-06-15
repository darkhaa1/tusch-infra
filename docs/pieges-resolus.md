# Pièges résolus

Recueil des problèmes rencontrés pendant la mise en place de l'infrastructure,
et de leur résolution. Documenté au fil de l'eau, pour mémoire et pour partage.

> Principe que j'applique : **toujours consulter la doc officielle avant de
> plonger dans le diagnostic.** La plupart de ces pièges se règlent vite quand
> on lit la bonne page de doc plutôt qu'en tâtonnant.

## Légende des emplacements

- **Hôte PVE** : le serveur Proxmox lui-même (Debian 12 + Proxmox VE 8)
- **CT 101** : conteneur LXC Caddy (reverse proxy, `10.10.0.20`)
- **CT 200** : conteneur LXC applicatif tusch-app (`10.10.0.30`)
- **CT monitoring** : conteneur LXC de supervision (Prometheus/Grafana/Alertmanager)
- **CT auth** : conteneur LXC d'identité (Authentik IdP)
- **Poste client** : mon PC Windows (poste d'administration)
- **Cloudflare** : configuration edge (dashboard, pas une machine)

---

## 1. IPv6 mal routé chez Hetzner

**Contexte** : juste après l'installation de Debian 12 sur le serveur Hetzner,
je faisais les premières mises à jour système (`apt update && apt upgrade`) et
j'installais mes outils de base. Certaines commandes réseau traînaient ou
tombaient en timeout, alors que la connexion semblait fonctionner.

**Où** : Hôte PVE (Proxmox / Debian 12).

**Symptôme** : connexions sortantes qui partent en IPv6 et échouent ou traînent
(apt, curl, git lents ou en timeout) depuis l'hôte.

**Cause** : la glibc privilégie l'IPv6 par défaut dans l'ordre de résolution.
Le routage IPv6 n'était pas encore fiable dans ce contexte — les connexions
partaient en v6 et tombaient.

**Fix** — fichier `/etc/gai.conf` sur l'hôte PVE (ordre de sélection des
adresses par `getaddrinfo`).
```bash
echo 'precedence ::ffff:0:0/96 100' >> /etc/gai.conf
```
La règle `precedence ::ffff:0:0/96 100` donne priorité (100) aux adresses
IPv4. La résolution choisit l'IPv4 en premier tant que l'IPv6 n'est pas fiable.
Effet immédiat, pas de reboot.

**Leçon** : `/etc/gai.conf` arbitre v4/v6 au niveau résolution, sans toucher
au routage. À connaître dès qu'on monte un serveur dual-stack.

---

## 2. Conflit iptables-legacy vs iptables-nft

**Contexte** : j'étais en train de configurer le réseau de Proxmox — la mise
en place du NAT MASQUERADE pour que mes conteneurs sur le LAN privé `vmbr1`
puissent sortir sur Internet via l'IP publique. J'avais écrit la règle, mais
le trafic des conteneurs ne sortait pas.

**Où** : Hôte PVE.

**Symptôme** : la règle MASQUERADE est bien présente (`iptables -t nat -L`),
mais son compteur de paquets reste à 0. Le NAT ne s'applique pas.

**Cause** : Debian 12 fournit deux backends iptables qui coexistent
(`iptables-legacy` et `iptables-nft`). Les règles étaient écrites dans un
backend, le trafic traité par l'autre.

**Fix** — bascule du système sur le backend `nft` via `update-alternatives`
(gère les liens symboliques dans `/etc/alternatives/`).
```bash
update-alternatives --set iptables  /usr/sbin/iptables-nft
update-alternatives --set ip6tables /usr/sbin/ip6tables-nft
update-alternatives --display iptables   # vérifier le lien
reboot                                    # purge les règles résiduelles legacy
```
Repointe `/usr/sbin/iptables` → backend nft. Le reboot garantit qu'aucune
règle de l'ancien backend ne traîne en mémoire.

**Leçon** : sur Debian 12, vérifier **quel backend est actif**
(`update-alternatives --display iptables`) avant de débugger des règles qui
"ne s'appliquent pas".

---

## 3. NAT non appliqué avec le firewall Proxmox actif

**Contexte** : dans la continuité de la config réseau (piège #2), une fois le
backend iptables corrigé, le NAT ne fonctionnait toujours pas correctement.
J'avais activé le firewall Proxmox sur mon conteneur de test, et c'est là que
le trafic a recommencé à mal sortir. Le débogage au `tcpdump` a révélé que les
paquets sortaient avec la mauvaise IP source.

**Où** : Hôte PVE (config réseau) — symptôme observé depuis le conteneur
(le CT n'atteignait pas Internet correctement).

**Symptôme** : le NAT est configuré, mais les conteneurs sortent avec leur IP
privée (`10.10.0.x`) au lieu de l'IP publique. Compteur MASQUERADE à 0.
Visible au `tcpdump` sur l'interface physique de l'hôte.

**Cause** : quand le firewall PVE est activé sur un conteneur, Proxmox insère
automatiquement un mini-bridge `fwbrXXX` entre le conteneur et le bridge
principal (`vmbr1`). Le suivi de connexion (conntrack) mélange alors les flux
entre les zones, et la règle de NAT ne matche plus.

**Fix** — fichier `/etc/network/interfaces` sur l'hôte PVE, dans le bloc du
bridge LAN privé `vmbr1`. On ajoute deux directives qui assignent une zone
conntrack dédiée aux interfaces `fwbr+`.
```bash
# Dans /etc/network/interfaces, sous "iface vmbr1 inet static"
post-up   iptables -t raw -I PREROUTING -i fwbr+ -j CT --zone 1
post-down iptables -t raw -D PREROUTING -i fwbr+ -j CT --zone 1
```
- `-t raw -I PREROUTING` : agit très tôt dans le pipeline netfilter, avant le
  suivi de connexion.
- `-i fwbr+` : cible toutes les interfaces commençant par `fwbr` (les
  mini-bridges firewall générés par PVE).
- `-j CT --zone 1` : place ces flux dans une **zone conntrack séparée**, ce
  qui évite le mélange des connexions et restaure le NAT.

Application sans reboot :
```bash
ifreload -a   # recharge /etc/network/interfaces à chaud
```
Source : wiki officiel Proxmox (Network Configuration).

**Leçon** : sur Proxmox, le NAT entre bridges n'est pas du Linux pur — les
mini-bridges firewall (`fwbr+`) imposent cette règle de zone conntrack.
Lire la doc Proxmox **avant** de creuser au tcpdump.

---

## 4. Cache DNS de la box qui pointe sur l'ancien serveur

**Contexte** : je venais de migrer le DNS de tusch.mn vers Cloudflare et de
faire pointer le domaine vers la nouvelle IP du serveur Hetzner. Je voulais
vérifier que le site répondait — depuis mon PC, timeout systématique, alors
que tout était censé être en place côté serveur.

**Où** : Poste client (PC Windows) — l'infra distante était saine.

**Symptôme** : après migration DNS, le site est inaccessible depuis le PC
(timeout), alors qu'il fonctionne depuis le smartphone en 4G.

**Cause** : la box Internet (résolveur DNS local du réseau) garde en cache
l'ancienne résolution. `ipconfig /flushdns` ne suffit pas : le PC vide son
cache local mais re-interroge la box, qui répond toujours avec sa valeur
périmée.

**Fix** — sur le poste client, configurer un résolveur DNS public
**directement sur la carte réseau**, pour court-circuiter la box.
```powershell
# PowerShell en administrateur, interface "Wi-Fi"
Set-DnsClientServerAddress -InterfaceAlias "Wi-Fi" -ServerAddresses ("1.1.1.1","1.0.0.1")
Get-DnsClientServerAddress -InterfaceAlias "Wi-Fi"   # vérifier
ipconfig /flushdns
```
`-InterfaceAlias "Wi-Fi"` cible la bonne interface (à adapter si Ethernet).
`1.1.1.1` / `1.0.0.1` = résolveurs publics Cloudflare. Le PC interroge
désormais Cloudflare directement, sans passer par le cache de la box.

**Leçon** : quand "ça marche depuis mon téléphone mais pas mon PC", suspecter
le cache DNS du réseau local (box) avant l'infrastructure distante. Le problème
n'était pas sur le serveur du tout.

---

## 5. Caddy — permission denied sur /var/log/caddy/

**Contexte** : je mettais en place Caddy comme reverse proxy dans son conteneur
dédié, et je configurais la journalisation (logs JSON dans un fichier dédié).
Au moment de recharger la config pour activer les logs, le service refusait de
redémarrer.

**Où** : CT 101 (conteneur LXC Caddy).

**Symptôme** : `systemctl reload caddy` échoue avec "permission denied" sur le
fichier de log déclaré dans le Caddyfile.

**Cause** : le dossier `/var/log/caddy` existait, mais appartenait à `root`.
Le service Caddy tourne sous l'utilisateur système `caddy`, qui n'avait pas
les droits d'écriture.

**Fix** — dans le CT 101, rétablir la propriété et les permissions du dossier
de logs.
```bash
chown -R caddy:caddy /var/log/caddy   # propriété à l'utilisateur du service
chmod 755 /var/log/caddy              # rwx propriétaire, r-x groupe/autres
```
`chown -R caddy:caddy` : l'utilisateur/groupe du service (vérifiables dans
`/lib/systemd/system/caddy.service`, directives `User=` / `Group=`). `755`
permet à Caddy d'écrire ses logs tout en laissant le dossier lisible.

**Leçon** : un service qui ne tourne pas en root a besoin que les dossiers
qu'il écrit lui appartiennent. Vérifier `User=` dans l'unit systemd.

---

> **Complément (récidive observée lors de l'ajout de vhosts Authentik/Grafana)**
> Le même `permission denied` sur `/var/log/caddy/` s'est reproduit en ajoutant
> de nouveaux fichiers de log par vhost. Détail important : `systemctl reload
> caddy` qui **échoue laisse l'ancienne config en service** — le site public
> n'est jamais coupé. C'est la différence fondamentale avec `restart`, qui
> aurait arrêté le service puis échoué à le relancer (coupure réelle). En
> production, privilégier `reload` pour les changements de config.

---

## 6. Page HTML affichée en texte brut

**Contexte** : toujours sur la config Caddy, j'avais mis en place une page
"coming soon" en HTML inline via la directive `respond`. En ouvrant le site
dans le navigateur, au lieu de voir la page, je voyais le code HTML affiché
tel quel.

**Où** : CT 101 (Caddy).

**Symptôme** : le navigateur affiche le code HTML source au lieu de la page
rendue.

**Cause** : la directive `respond` de Caddy renvoie par défaut un en-tête
`Content-Type: text/plain`. Le navigateur, ne voyant pas `text/html`,
n'interprète pas le contenu comme du HTML.

**Fix** — fichier `/etc/caddy/Caddyfile` dans le CT 101, dans le bloc `header`
du site.
```caddyfile
header {
    Content-Type "text/html; charset=utf-8"
}
```
Le `charset=utf-8` garantit aussi le bon rendu des caractères (utile vu que
le projet contient du cyrillique mongol).

Validation + rechargement dans le CT 101 :
```bash
caddy validate --config /etc/caddy/Caddyfile   # vérifie la syntaxe
systemctl reload caddy                          # recharge sans coupure
```

---

## 7. SSL Labs : de B à A+

**Contexte** : une fois le site en ligne en HTTPS, j'ai voulu valider le
niveau de sécurité TLS avec le test SSL Labs. Premier résultat : B. Pas
suffisant pour une infra que je veux présenter comme production-grade, donc
j'ai cherché à monter à A+.

**Où** : Cloudflare (config edge) + CT 101 (en-têtes Caddy).

**Symptôme** : score SSL Labs en B.

**Outil de test** : [SSL Labs](https://www.ssllabs.com/ssltest/)
(scan public, mise en cache des résultats — décocher l'affichage public si besoin de discrétion).

**Cause** : la configuration TLS edge (Cloudflare) n'était pas durcie — mode
de chiffrement permissif, pas de HSTS, versions TLS anciennes autorisées.

**Fix** — côté **dashboard Cloudflare**, section **SSL/TLS** :
- **Overview → Encryption mode** : `Full (strict)` — Cloudflare valide le
  certificat de l'origine, pas seulement le chiffrement.
- **Edge Certificates → Always Use HTTPS** : ON
- **Edge Certificates → Minimum TLS Version** : `TLS 1.2`
- **Edge Certificates → TLS 1.3** : ON
- **Edge Certificates → HSTS** : activé (max-age 6 mois, includeSubDomains)

Complété côté origine par les en-têtes de sécurité dans le `Caddyfile` du
CT 101 (`Strict-Transport-Security`, `X-Content-Type-Options`,
`X-Frame-Options`, `Referrer-Policy`).

**Résultat** : score **A+**.

**Leçon** : le durcissement TLS se joue à deux endroits — l'edge (Cloudflare)
et l'origine (en-têtes Caddy). Les deux doivent être cohérents.

---

## 8. Le stockage "local" ne supporte pas les snapshots LXC

**Contexte** : avant de commencer à déployer des choses dans mes conteneurs,
je voulais pouvoir figer leur état (snapshot) pour rollback en cas de problème.
En tentant mon premier snapshot sur un conteneur, Proxmox a refusé.

**Où** : Hôte PVE (gestion du stockage Proxmox).

**Symptôme** : `pct snapshot <CTID> <nom>` échoue avec "feature not available".

**Cause** : le conteneur était sur le storage Proxmox `local`, de type `dir`
(répertoire sur ext4). Le type `dir` ne supporte pas les snapshots LXC —
seuls certains backends (LVM-thin, ZFS, etc.) le permettent.

**Fix** — sur l'hôte PVE, mise en place d'un pool **LVM-thin sur fichier
loopback** déclaré comme storage Proxmox.
```bash
# 1. Fichier image sparse de 200 Go dans le storage local
cd /var/lib/vz
truncate -s 200G lvm-pool.img

# 2. Attache le fichier à un périphérique loopback
losetup /dev/loop3 /var/lib/vz/lvm-pool.img

# 3. Empile les couches LVM : PV → VG → thin pool
pvcreate /dev/loop3
vgcreate vg_tusch /dev/loop3
lvcreate -L 195G -T vg_tusch/data     # -T = thin pool ; 5 Go pour les métadonnées

# 4. Déclare le storage côté Proxmox
pvesm add lvmthin local-lvm --vgname vg_tusch --thinpool data --content rootdir,images
```
La persistance au reboot est assurée par une unit systemd dédiée :
`/etc/systemd/system/lvm-pool-loopback.service` (recrée le loopback et active
le VG avant le démarrage des conteneurs). Détails dans
[`docs/architecture/04-stockage.md`](architecture/04-stockage.md).

**Leçon** : le choix du stockage se pense **avant** l'installation de
l'hyperviseur. L'installimage Hetzner part en ext4 (`dir`) par défaut, ce qui
ferme la porte aux snapshots sans réaménagement.

---

## 9. Migration d'un conteneur vers un storage compatible snapshots

**Contexte** : après avoir créé le storage `local-lvm` (piège #8), il fallait
y déplacer les conteneurs déjà créés sur l'ancien storage `dir` pour qu'ils
bénéficient des snapshots. Je voulais le faire sans casser les conteneurs
existants.

**Où** : Hôte PVE (les commandes `pct` s'exécutent sur l'hôte, pas dans le
conteneur).

**Symptôme** : besoin de déplacer un conteneur de `local` (`dir`) vers
`local-lvm` (LVM-thin) sans le corrompre.

**Cause** : déplacer le volume d'un conteneur **en cours d'exécution** expose
à un risque de corruption (le système de fichiers bouge pendant la copie).

**Fix** — depuis l'hôte PVE, arrêter proprement le conteneur avant de migrer.
```bash
pct stop <CTID>                              # arrêt propre du conteneur
pct move-volume <CTID> rootfs local-lvm      # déplace le rootfs vers local-lvm
pct start <CTID>                             # redémarrage une fois fini
```
Conteneur arrêté = système de fichiers figé = pas de corruption. Le downtime
est identique à une migration à chaud, mais sans le risque.

**Leçon** : `pct stop` **avant** `pct move-volume`. Toujours. Et ces commandes
`pct` se lancent depuis l'hôte PVE, jamais depuis l'intérieur du conteneur.

---

## 10. Trunk VLAN absent sur le port tap de la VM OPNsense

**Contexte** : mise en place de la segmentation par VLAN derrière OPNsense
(voir [`architecture/05-segmentation-vlan.md`](architecture/05-segmentation-vlan.md)).
Le bridge LAN avait bien été passé en `bridge-vlan-aware yes`, OPNsense avait
créé ses interfaces VLAN, mais les clients tagués ne recevaient pas d'IP DHCP.

**Où** : Hôte PVE — port tap de la VM OPNsense sur le bridge LAN.

**Symptôme** : conteneur de test sur le bridge LAN avec `tag=20` reste sans
IP DHCP. `tcpdump` côté OPNsense ne voit aucun `DHCPDISCOVER` tagué 20.

**Cause** : par défaut, un port de bridge n'est associé qu'au PVID 1 — même
quand le bridge global est VLAN-aware. La directive `bridge-vids` au niveau
du bridge autorise une plage globale, mais les **ports individuels** doivent
quand même être déclarés sur chaque VID qu'on veut laisser passer. Sans ça,
les frames .1Q tagués sont jetés à la sortie du port avant même d'atteindre
OPNsense.

**Fix** — déclarer les VIDs autorisés directement dans la définition réseau
de la VM, via l'option native Proxmox `trunks=`. Persistant au reboot, pas
besoin de hook post-up :

```
trunks=10;20
```

(syntaxe Proxmox : VIDs séparés par `;`, posés sur l'interface réseau de la
VM correspondant au port LAN). Après ré-application : `bridge vlan show`
liste bien les VIDs 10 et 20 sur le port tap. Les clients reçoivent leur IP.

**Leçon** : un bridge VLAN-aware filtre TOUS les VLANs sauf ceux explicitement
autorisés sur chaque port. Côté Proxmox, `trunks=` est la méthode officielle
et persistante — équivalente à `bridge vlan add`, mais réappliquée
automatiquement à chaque démarrage de la VM.

---

## 11. Conflit DHCP dnsmasq vs Kea sur le port 67

**Contexte** : configuration de Kea DHCP dans OPNsense pour servir les deux
subnets VLAN. Settings posés, subnets déclarés, mais aucun OFFER côté clients.

**Où** : VM OPNsense.

**Symptôme** : Kea démarré, aucune erreur visible dans l'UI, mais aucun client
ne reçoit d'IP. `sockstat -4 -l | grep 67` montre :

```
dnsmasq    *:67    *:*
```

Pas de `kea-dhcp4` sur les IPs des interfaces VLAN.

**Cause** : dnsmasq était resté activé par défaut. Il occupait le port 67 sur
wildcard (`*:67`) **avant** que Kea ne tente de se binder. Kea échouait
silencieusement à prendre le port et restait en idle. Décocher les
sous-options DHCP de dnsmasq ne suffit pas : c'est le service entier qui
occupe le port.

**Fix** — couper dnsmasq à la racine, pas juste ses sous-options.

```
Services → Dnsmasq DNS & DHCP → décocher l'Enable principal (section Default)
→ Save → Apply
```

Puis vérifier que Kea a bien pris la main :

```bash
sockstat -4 -l | grep 67
# → kea-dhcp4   <IP_VLAN_SERVEURS>:67
# → kea-dhcp4   <IP_VLAN_CLIENTS>:67
```

Conserver Unbound activé pour le DNS — sinon en désactivant dnsmasq on perd
aussi sa résolution intégrée.

**Leçon** : « le service ne marche pas » → toujours vérifier qui occupe
vraiment le port avec `sockstat`. Et désactiver un service signifie le couper
en racine, pas juste décocher une sous-option dans l'UI.

> **Sous-piège lié — Socket Type Kea en `udp`** : après avoir libéré le port,
> Kea bind bien ses ports mais aucun OFFER n'apparaît sur les VLANs.
> Cause : en `udp`, Kea bind un socket unicast sur l'IP de l'interface — qui
> ne reçoit pas les broadcasts DHCP (`255.255.255.255`).
> Fix : `Socket Type = raw` (capture L2 via `PF_PACKET`).
> Sur des sous-interfaces virtuelles (VLAN, alias), `raw` est presque toujours
> obligatoire.

---

## 12. Suricata — "no rules were loaded" après bascules successives

**Contexte** : mise en place de Suricata sur OPNsense. Plusieurs allers-retours
entre les modes PCAP (IDS) et Netmap (IPS), bascules de policy entre Alert et
Drop. Au moment de tester la détection, `eve.json` ne montrait aucune alerte
malgré du trafic de scan.

**Où** : VM OPNsense, plugin `os-intrusion-detection`.

**Symptôme** : `eve.json` ne contient que des events `event_type: flow` ou
`event_type: ssh` (identification de protocole), aucun `event_type: alert`.
Le log Suricata du jour révèle :

```
<Error> -- 1 rule files specified, but no rules were loaded!
<Error> -- threshold.config: No such file or directory
```

**Cause** : la config IDS s'est corrompue au fil des bascules. Le fichier
`threshold.config` (attendu par le moteur) a disparu, et le chargement des
règles échoue dès l'initialisation. Le service démarre quand même, mais sans
règle armée — d'où l'absence totale d'alertes.

**Fix** — réinstaller proprement le plugin plutôt que d'essayer de réparer
des fichiers manquants ou désynchronisés :

```bash
configctl ids stop
pkg remove -y os-intrusion-detection
rm -rf /usr/local/etc/suricata
pkg install -y os-intrusion-detection
```

Puis reconfigurer depuis l'UI (Settings, Download des rulesets, Policy).
Après réinstall, le log montre `N rules loaded successfully` et les alertes
apparaissent en quelques minutes de trafic. Le blocage IPS est validé par un
scan SSH sortant qui produit un événement `"action": "blocked"` (SID 2003068).

**Leçon** : avant de tester du trafic, **toujours** vérifier `N rules loaded
successfully` dans le log Suricata. C'est le premier maillon de la chaîne ;
inutile de générer des scans pendant des heures si aucune règle n'est armée.
Et quand la config IDS est manifestement corrompue, la réinstallation propre
du plugin est souvent plus rapide que la réparation à la pince.

---


## 13. Alertmanager refuse de démarrer — permissions du fichier de config

**Contexte** : ajout d'Alertmanager dans le conteneur de supervision, avec
configuration du routeur Telegram. Le fichier YAML était en place, validé
syntaxiquement par `amtool check-config`, mais le service ne démarrait pas.

**Où** : CT monitoring.

**Symptôme** : `systemctl status alertmanager` indique
`active (failed)`. `journalctl -u alertmanager -n 50` ne donne presque rien,
juste `Failed to start Alertmanager service`. Pas de stack trace, pas de
mention de la cause exacte.

**Cause** : le fichier `/etc/alertmanager/alertmanager.yml` avait été créé en
`root:root 600`. Le service tourne sous l'utilisateur `prometheus` (créé par
le paquet, comme c'est l'usage). `prometheus` n'avait donc pas la permission
de **lire** le fichier de config, et le service échouait à l'open() sans
verbosité utile dans les logs.

**Fix** — donner la lecture à l'utilisateur du service, sans relâcher les
droits d'écriture :

```bash
chown root:prometheus /etc/alertmanager/alertmanager.yml
chmod 640 /etc/alertmanager/alertmanager.yml
systemctl restart alertmanager
```

(Groupe `prometheus` en lecture, `root` propriétaire pour l'écriture.
Permissions resserrées à `640` plutôt que `644` puisque le fichier contient
des secrets — token Telegram, notamment.)

**Leçon** : quand un service systemd échoue à démarrer sans message clair,
vérifier en priorité (1) l'utilisateur sous lequel il tourne (`User=` dans
l'unit, ou directive par défaut du paquet) et (2) les permissions des
fichiers qu'il doit lire. Les logs sont souvent muets sur les erreurs
d'open() avant fork.

---

## 14. DNS des LXC cassé par Tailscale MagicDNS héritée de l'hôte

**Contexte** : après installation de Tailscale sur l'hôte Proxmox, plusieurs
conteneurs ont vu leur résolution DNS publique tomber d'un coup. Symptôme
visible aussi côté monitoring : `node_exporter` arrivait à scrape les cibles
référencées par IP mais pas celles référencées par nom DNS.

**Où** : Tous les LXC qui héritent du resolver de l'hôte (la majorité — les
CTs n'ont pas de resolver propre par défaut).

**Symptôme** : depuis un CT, `ping 8.8.8.8` répond ; `ping google.com`
retourne `unknown host`. `cat /etc/resolv.conf` montre :

```
nameserver 100.100.100.100
```

C'est l'IP du resolver MagicDNS de Tailscale.

**Cause** : Tailscale, à son démarrage, réécrit `/etc/resolv.conf` de l'hôte
pour pointer sur `100.100.100.100` (MagicDNS, qui résout les noms internes
au tailnet en `.ts.net`). Sans config explicite de forwarding pour les zones
publiques, les requêtes pour des noms publics ne sont pas relayées et
timeout. Les LXC héritent du resolver de l'hôte → ils sont impactés en
cascade.

**Fix** — désactiver MagicDNS comme resolver par défaut côté Tailscale (sans
casser le reste : Tailscale continue à fonctionner pour le réseau privé,
l'accès SSH par IP Tailscale, les ACL) :

```bash
tailscale set --accept-dns=false
```

L'hôte récupère son resolver public d'origine, et les LXC qui en héritent
résolvent à nouveau les noms publics. La résolution des noms internes au
tailnet est perdue côté hôte (acceptable, on n'en a pas besoin pour ce rôle).

**Leçon** : quand DNS échoue mais ping par IP marche, vérifier en priorité
`/etc/resolv.conf`. Et toujours considérer que Tailscale (ou n'importe quel
agent qui touche au DNS) peut réécrire la config sans préavis. Pour les LXC,
le simple fait qu'ils héritent du resolver de l'hôte sans le savoir suffit à
créer une cascade silencieuse.

**Complément ajouté pendant la mise en place de la supervision** : pour
découpler totalement chaque LXC de l'état DNS de l'hôte, on fixe un resolver
explicite par conteneur via `pct set <CTID> --nameserver <DNS_PROVIDER>`. Le
LXC garde un resolver fonctionnel même si l'hôte casse le sien plus tard
(MAJ Tailscale, autre agent, modification accidentelle). Principe :
**découpler le DNS des CTs de l'état de l'hôte**.

---

## 16. pve-exporter renvoie 500 — API Proxmox bloquée par son propre DROP

**Contexte** : mise en place de `pve-exporter` dans le CT de supervision
(voir [`architecture/07-supervision.md`](architecture/07-supervision.md)).
Token Proxmox généré, `pve.yml` configuré, service systemd démarré et `active`.
Au premier scrape, Prometheus rapporte un 500 sur le job `pve`.

**Où** : Hôte PVE (configuration du firewall Proxmox) — symptôme observé
depuis le CT supervision qui n'arrive pas à parler à l'API.

**Symptôme** : `curl -k https://<IP_HOST_LAN>:8006/api2/json/version` depuis
le CT supervision → timeout. Depuis l'hôte lui-même → 200 OK. L'API est
joignable de la machine qui l'héberge, mais pas du LAN.

**Cause** : le firewall Proxmox est en politique INPUT DROP par défaut sur
le node (cf. couche 4 de la défense en profondeur). Aucune security group
ne couvrait le LAN privé du CT supervision vers le port 8006 — le paquet
était jeté avant d'atteindre `pveproxy`. L'erreur 500 côté exporter masquait
en réalité un timeout réseau.

**Fix** — création d'un Security Group dédié dans Datacenter → Firewall →
Security Groups :

```
monitoring-access :
  ACCEPT  source = <IP_CT_MONITORING>  dest = -  proto = tcp  dport = 8006
  ACCEPT  source = <IP_CT_MONITORING>  dest = -  proto = tcp  dport = 9100
```

Puis application du groupe sur le node tusch-pve-01. Une fois ces deux
règles posées :

```bash
curl -k https://<IP_HOST_LAN>:8006/api2/json/version
# → 200 OK
systemctl restart pve-exporter   # côté CT supervision
```

Le job `pve` repasse `up == 1` côté Prometheus.

**Leçon** : quand un service de l'hôte est joignable **de l'hôte** mais pas
**du LAN**, suspecter le firewall de l'hôte avant le service lui-même. Les
500 applicatifs masquent souvent des `connect: timeout` ou `connection
refused` en dessous. `curl -v` depuis la source du scrape pour isoler la
couche fautive.

**Note sécurité** : on ouvre uniquement vers le **CT de supervision**, pas
vers tout le LAN. Le CT applicatif exposé indirectement à Internet (via le
reverse proxy) n'a aucun chemin vers l'API de l'hyperviseur — moindre
privilège réseau.

---

## 17. node_exporter du CT en crash-loop — ARGS hérités de l'hôte

**Contexte** : `prometheus-node-exporter` installé sur le CT supervision en
même temps que sur les autres nœuds. Sur l'hôte Proxmox, j'avais restreint
l'IP de bind au LAN via `/etc/default/prometheus-node-exporter`
(défense en profondeur, cf. doc supervision). J'ai copié-collé la même config
dans le CT pour aller vite.

**Où** : CT supervision (`prometheus-node-exporter`).

**Symptôme** : service en crash-loop. `systemctl status` affiche
`status=1/FAILURE` répétés, le service tente de redémarrer à chaque échec.
Dans les logs :

```
err="listen tcp <IP_HOST_LAN>:9100: bind: cannot assign requested address"
```

**Cause** : `ARGS="--web.listen-address=<IP_HOST_LAN>:9100"` avait été copié
de la config de l'hôte. Cette IP est celle de l'hôte sur le bridge LAN. À
l'intérieur du CT supervision, cette IP **n'existe pas** comme adresse
locale — le CT a la sienne propre, différente. `bind()` échoue
immédiatement (`EADDRNOTAVAIL`).

**Fix** — restaurer la valeur par défaut du paquet (bind sur
`0.0.0.0:9100`, ce qui dans le CT correspond à toutes ses interfaces
réelles) :

```bash
# /etc/default/prometheus-node-exporter
ARGS=""
```

Puis :

```bash
systemctl restart prometheus-node-exporter
ss -tlnp | grep 9100   # vérifier qu'il écoute bien
```

**Leçon** : une config copiée d'une machine à l'autre doit être **relue
ligne par ligne**, surtout les directives qui référencent des IPs ou des
chemins. Ce qui a du sens sur l'hôte (bind LAN restreint comme défense en
profondeur) n'a pas le même sens dans le CT (l'IP n'existe pas localement).

---

## 18. Alertmanager après 5 crashs rapides — `systemctl reset-failed` requis

**Contexte** : configuration d'Alertmanager (voir piège #14 pour les
permissions). Après plusieurs corrections successives du fichier de config
(permissions, syntaxe, secret Telegram), j'ai voulu relancer le service.

**Où** : CT supervision (`prometheus-alertmanager`).

**Symptôme** : `systemctl start prometheus-alertmanager` ne fait rien
visible. Le service ne démarre pas, aucun message dans `journalctl`. Statut :

```
prometheus-alertmanager.service - Alertmanager for Prometheus
  Active: failed (Result: exit-code) since ...
   start request repeated too quickly
```

**Cause** : avec `Restart=on-failure` (par défaut pour ce paquet), systemd
empile les redémarrages rapides. Au-delà d'un seuil
(`StartLimitBurst=5` / `StartLimitIntervalSec=10s` par défaut), systemd
**refuse de redémarrer le service** et exige une remise à zéro explicite
pour repartir, comme garde-fou contre les boucles infinies.

**Fix** :

```bash
systemctl reset-failed prometheus-alertmanager
systemctl start prometheus-alertmanager
```

`reset-failed` efface le compteur de crashs et débloque la machine d'état
systemd.

**Leçon** : quand un service refuse de démarrer alors qu'on a corrigé la
config, vérifier `systemctl status` complet — la mention `start request
repeated too quickly` est un cas spécifique de blocage par garde-fou
systemd. La résolution est un `reset-failed`, pas une nouvelle modification
de config.

---

## 19. Target `localhost:9100` en `connection refused` — paquet pas démarré

**Contexte** : déclaration du job `node` dans `prometheus.yml`. Targets :
les IPs des nœuds (hôte + 3 CTs). Au premier rechargement, presque tous les
targets remontent `up = 1`. Un seul reste à `up = 0` : `localhost:9100`
(c'est-à-dire le `node_exporter` censé tourner dans le CT supervision
lui-même).

**Où** : CT supervision.

**Symptôme** : dans l'UI Prometheus → Status → Targets, le target
`localhost:9100` est `DOWN` avec :

```
Get "http://localhost:9100/metrics": dial tcp [::1]:9100: connect: connection refused
```

Mention spécifique de `[::1]` : Prometheus tente IPv6 d'abord. L'erreur est
explicite, mais facile à mésinterpréter comme un problème de config (binding
IPv4 vs IPv6, etc.).

**Cause** : j'avais cru que `prometheus-node-exporter` était installé et
démarré dans le CT — en fait, après plusieurs purges/réinstallations
pendant la mise au point, le paquet n'était plus présent, ou son service
n'était pas démarré. Le port `9100` n'était pas en écoute, d'où le
`connection refused` (refus immédiat — distinct d'un timeout réseau qui
indiquerait un firewall).

**Fix** — vérifier d'abord l'état réel avant d'accuser la config :

```bash
ss -tlnp | grep 9100              # rien -> rien n'écoute
apt list --installed | grep node-exporter
systemctl status prometheus-node-exporter
# → réinstaller / réactiver / démarrer selon le cas
apt install -y prometheus-node-exporter
systemctl enable --now prometheus-node-exporter
ss -tlnp | grep 9100              # *:9100 LISTEN ...
```

Après quoi le target remonte `up = 1` au scrape suivant.

**Leçon** : **`connection refused` ≠ `connection timeout`**. Le refus est
immédiat et signifie qu'**il n'y a personne qui écoute** sur ce port côté
cible. Le timeout signifie qu'un paquet est jeté en route (firewall) ou que
la cible est injoignable. La première chose à faire face à un `connection
refused` est `ss -tlnp` côté cible — pas tripatouiller la config Prometheus.

---

## 20. Service injoignable — doublon d'IP (ping OK, refus TCP en 0 ms)

**Où** : CT auth (`<IP_CT_AUTH>`), depuis le poste d'admin.

**Symptôme** : tout est sain dans le CT (service démarré, port en écoute), le
`ping` répond, mais **toute connexion TCP est refusée instantanément** (0 ms).

**Cause** : doublon d'IP. Un autre CT portait déjà la même adresse ; c'est *lui*
qui répondait aux pings et renvoyait des `RST` sur ses ports fermés. Le service
visé ne voyait jamais le trafic.

**Fix** — identifier par la table de voisinage ARP et comparer la MAC :

```bash
ip neigh show <IP_CT_AUTH>
# comparer la MAC affichée avec celle du CT attendu
```

**Leçon** : **ping OK + refus TCP instantané = suspecter un doublon d'IP.** Un
refus en 0 ms est une réponse *active* d'une machine vivante, pas un timeout.
Vérifier la MAC avant de déboguer le service.

---

## 21. Firewall PVE réactivé « sans règles » mais le service reste joignable

**Où** : CT monitoring.

**Symptôme** : on réactive le firewall du CT avec une policy `DROP` et **sans**
règle d'autorisation, mais l'UI reste accessible — le filtrage semble inopérant.

**Cause** : le firewall est **stateful**. Les connexions *déjà établies* sont
suivies et survivent à l'activation de la policy `DROP` ; seuls les **nouveaux**
flux sont bloqués. La session navigateur ouverte continuait de fonctionner.

**Fix** : tester en fenêtre privée ou après fermeture complète du navigateur,
pour forcer une connexion neuve.

**Leçon** : **toujours valider un changement de firewall avec une connexion
NEUVE.** Une session vivante ne prouve rien sur la policy en vigueur.

---

## 22. Règle `.fw` sans effet — hors section `[RULES]` + écrasement UI/manuel

**Où** : fichier firewall d'un CT (`/etc/pve/firewall/<CTID>.fw`).

**Symptôme** : une règle ajoutée au fichier n'a aucun effet, et des règles
précédentes ont disparu.

**Cause double** : la règle avait été placée sous la section `[OPTIONS]` sans
header `[RULES]` (donc ignorée), et une modification via l'UI entre-temps avait
réécrit le fichier en perdant les règles éditées à la main.

**Fix** : réécriture complète du fichier avec les deux sections correctement
séparées, puis validation :

```bash
pve-firewall compile
```

**Leçon** : `cat` du fichier `.fw` **avant et après** toute modification.
L'édition par l'UI et l'édition manuelle ne se mélangent pas impunément — l'une
peut écraser l'autre. Choisir un canal et s'y tenir.

---

## 23. `502 Bad Gateway` avec `"duration":3.000` — drop silencieux du firewall

**Où** : reverse proxy → CT monitoring (UI sur port applicatif).

**Symptôme** : l'UI exposée renvoie `502`. Le log JSON du proxy montre une
`duration` de très exactement **3.000 s** sur la tentative d'upstream.

**Cause** : timeout de connexion vers l'upstream = **drop silencieux**. Le
firewall du CT n'autorisait pas le reverse proxy à joindre le port ; le paquet
était droppé sans réponse, d'où l'attente jusqu'au timeout.

**Fix** : règle dédiée autorisant le reverse proxy → port applicatif sur le CT.

**Leçon** — méthode de debug d'un `502` et **signature temporelle** :

- se placer **sur le proxy** et `curl` directement l'upstream ;
- un **timeout rond** (3.000 s, 5.000 s…) = **drop silencieux** d'un firewall
  (le paquet part dans le vide) ;
- un **refus en 0 ms** = **rejet actif** (`RST` renvoyé, rien n'écoute).

Le chrono distingue les deux pannes.

---

## 24. `Redirect URI Error` au login OIDC après passage au domaine public

**Où** : Authentik (provider OIDC) ↔ Grafana.

**Symptôme** : le login OIDC, qui marchait en interne, échoue avec `Redirect URI
Error` une fois le service passé sur son domaine public.

**Cause** : le provider Authentik ne connaissait que l'ancienne *redirect URI*
interne. En mode strict, l'URI publique non déclarée est refusée.

**Fix** : ajouter l'URI publique aux *redirect URIs* du provider (le mode strict
accepte plusieurs URIs déclarées — interne et publique coexistent).

**Leçon** : URL d'un service OIDC modifiée = provider à mettre à jour. Ce n'est
pas un bug, c'est le **contrôle de sécurité anti-détournement** du code
d'autorisation qui fait son travail.

---

## 25. Rôle Grafana non éditable — `skip_org_role_sync` dans le mauvais bloc

**Où** : `grafana.ini`.

**Symptôme** : impossible d'éditer le rôle d'un utilisateur, message
« synchronized from your auth provider ».

**Cause** : la synchronisation OAuth écrase le rôle à chaque login. Le paramètre
`skip_org_role_sync` avait bien été « activé » — mais en décommentant la ligne
d'exemple (préfixée `;`) dans la **section de référence** du fichier, et non en
l'ajoutant au bloc `[auth.generic_oauth]` **actif**. La ligne de référence
n'est jamais lue.

**Fix** : ajouter le paramètre dans le bloc actif, puis `restart`. Confirmer :

```bash
grep -n "skip_org_role_sync" /etc/grafana/grafana.ini
# doit apparaître sous le bon [auth.generic_oauth], non commenté
```

**Leçon** : dans les fichiers `ini` à sections dupliquées (référence commentée +
section active), toujours vérifier dans **quel** bloc on écrit. Un `grep` avec
numéro de ligne lève le doute en deux secondes.

---

*Document mis à jour au fil de la mise en place de l'infrastructure.*