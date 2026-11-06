# Ansible

Gestion de configuration de l'infrastructure, pilotée depuis un conteneur de
contrôle dédié : `tusch-ansible-01` (CT 104, `10.10.0.60`).

## Pourquoi un CT de contrôle dédié

- La clé SSH qui ouvre les autres CT vit **dans un seul endroit**, isolé, et
  pas sur le poste d'admin.
- Le firewall de chaque CT géré n'a qu'**une** source à autoriser pour le port
  22 (`10.10.0.60`).
- Le CT est supervisé comme les autres (`node_exporter`).

## Contenu

| Fichier | Rôle |
|---------|------|
| `ansible.cfg.example` | Configuration Ansible (inventaire par défaut) |
| `inventory.example.ini` | Groupe `monitored` : les CT sur lesquels déployer la supervision |
| `node_exporter.yml` | Premier playbook : installe et active `prometheus-node-exporter` |

## Utilisation

```bash
# Depuis le CT de contrôle
ansible monitored -m ping                 # vérifier la connectivité
ansible-playbook node_exporter.yml --check  # simulation (aucun changement)
ansible-playbook node_exporter.yml          # application
```

Le playbook est **idempotent** : le relancer sur un CT déjà configuré ne
change rien (`changed=0`).

## Prochaines étapes

- Rôle de durcissement de base (SSH, `unattended-upgrades`, fail2ban)
- Création des CT depuis le template via l'API Proxmox
- `host_key_checking` à réactiver une fois les empreintes collectées dans un
  `known_hosts` géré
