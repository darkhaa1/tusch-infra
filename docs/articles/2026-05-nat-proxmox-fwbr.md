# Pourquoi mon NAT Proxmox ne marchait pas avec le firewall activé

*Mai 2026 — retour d'expérience sur un piège réseau spécifique à Proxmox.*

---

## Le contexte

Je montais le réseau de mon hôte Proxmox : deux bridges, un WAN public
(`vmbr0`) qui porte l'IP publique, et un LAN privé (`vmbr1`, `10.10.0.0/24`)
pour mes conteneurs. Objectif classique : que les conteneurs du LAN privé
puissent sortir sur Internet via NAT, comme des machines derrière une box.

La règle de NAT, je la connaissais :

```bash
iptables -t nat -A POSTROUTING -s 10.10.0.0/24 -o vmbr0 -j MASQUERADE
```

Le forwarding IP activé, la règle en place. Sur le papier, tout était bon.

Sauf que mes conteneurs ne sortaient pas. `apt update` qui timeout, `ping
8.8.8.8` sans réponse.

---

## Premier réflexe (et première erreur)

Mon premier réflexe a été de plonger directement dans le diagnostic. J'ai
vérifié la règle : présente. J'ai vérifié le forwarding :

```bash
cat /proc/sys/net/ipv4/ip_forward   # → 1, OK
```

J'ai regardé le compteur de la règle MASQUERADE :

```bash
iptables -t nat -L POSTROUTING -n -v
```

Et là, premier indice : le **compteur de paquets était à 0**. La règle ne
matchait jamais. Pourtant elle était syntaxiquement correcte et bien placée.

> Note : j'avais aussi un faux départ avec le conflit `iptables-legacy` vs
> `iptables-nft` de Debian 12, réglé en basculant sur le backend nft. Mais même
> après ça, le compteur restait à 0.

---

## La traque au tcpdump

Pour comprendre où passaient vraiment les paquets, j'ai sorti `tcpdump` sur
l'interface physique de sortie. Et c'est là que le problème est devenu clair :

Les paquets d'un conteneur sortaient bien sur l'interface physique... mais
**avec leur IP source privée** (`10.10.0.x`), pas avec l'IP publique. Autrement
dit, le NAT ne s'appliquait pas du tout : les paquets partaient en clair avec
une adresse privée, que l'hébergeur jette immédiatement.

La question devenait : *pourquoi une règle MASQUERADE correcte ne s'applique
pas à des paquets qui passent pourtant par la bonne interface ?*

---

## L'illumination : les mini-bridges firewall de Proxmox

C'est en lisant la documentation officielle Proxmox sur la configuration réseau
que j'ai compris. Le coupable : **le firewall Proxmox**, que j'avais activé sur
le conteneur.

Quand le firewall PVE est actif sur un conteneur, Proxmox n'attache pas
directement le conteneur à `vmbr1`. Il insère un **mini-bridge intermédiaire**
nommé `fwbrXXX` entre les deux, pour pouvoir y appliquer ses propres règles de
filtrage :

```
Conteneur  ──►  fwbrXXX  ──►  vmbr1  ──►  vmbr0  ──►  Internet
                  ▲
            inséré par PVE quand le firewall du conteneur est actif
```

Le problème : ce mini-bridge perturbe le suivi de connexion (conntrack). Les
flux se mélangent entre les zones, et le NAT ne reconnaît plus les connexions
qu'il devrait traiter. D'où le compteur à 0.

Ce n'est **pas** du Linux standard. C'est une spécificité de l'implémentation
réseau de Proxmox, qu'aucune connaissance générale d'iptables ne permet de
deviner.

---

## La solution

La doc Proxmox donne la règle qui résout exactement ça : assigner les
interfaces `fwbr+` à une **zone conntrack dédiée**, très tôt dans le pipeline
netfilter (table `raw`, chaîne `PREROUTING`).

Dans `/etc/network/interfaces`, sous la définition de `vmbr1` :

```bash
post-up   iptables -t raw -I PREROUTING -i fwbr+ -j CT --zone 1
post-down iptables -t raw -D PREROUTING -i fwbr+ -j CT --zone 1
```

- `-i fwbr+` cible toutes les interfaces commençant par `fwbr` (les
  mini-bridges générés par PVE).
- `-j CT --zone 1` les place dans une zone de suivi de connexion séparée, ce
  qui évite le mélange des flux et restaure le bon fonctionnement du NAT.

Application à chaud :

```bash
ifreload -a
```

Compteur MASQUERADE vérifié juste après : il grimpait enfin. `apt update`
depuis le conteneur : fonctionnel.

---

## Ce que j'en retiens

**1. Sur Proxmox, le NAT entre bridges n'est pas du Linux pur.**
Les mini-bridges firewall introduisent un comportement qui sort du cadre
iptables classique. Une bonne maîtrise générale de Linux ne suffit pas ici.

**2. Lire la doc officielle AVANT de creuser.**
J'ai perdu du temps à diagnostiquer un comportement qui était documenté noir
sur blanc dans le wiki Proxmox. Le réflexe « doc d'abord, tcpdump ensuite »
m'aurait fait gagner une heure.

**3. Le compteur d'une règle iptables est un signal précieux.**
Un compteur à 0 sur une règle censée matcher = la règle n'est jamais
atteinte. C'est souvent plus parlant qu'un message d'erreur (qui ici
n'existait pas).

---

*Cet article fait partie de la documentation de mon infrastructure
auto-hébergée. La configuration réseau complète et anonymisée est
[ici](../../proxmox/network/), et le récapitulatif des pièges rencontrés
[là](../pieges-resolus.md).*