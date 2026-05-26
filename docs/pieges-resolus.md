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

*Document mis à jour au fil de la mise en place de l'infrastructure.*