#!/bin/bash
# /usr/local/sbin/backup-restic.sh — sauvegarde chiffrée de tous les CT/VM
#
# 1. vzdump de tous les invités, NON compressé, dans un répertoire local
#    temporaire (restic déduplique et compresse mieux un flux brut)
# 2. restic backup vers le dépôt chiffré (AES-256) sur la Storage Box
# 3. purge du temporaire, rétention 7 j / 4 sem. / 3 mois
# 4. le dimanche : vérification d'intégrité sur 5 % des données
# 5. métriques pour Prometheus (textfile collector de node_exporter)
set -uo pipefail

export RESTIC_REPOSITORY=/mnt/pve/storagebox-backup/restic
export RESTIC_PASSWORD_FILE=/root/.restic-pass
STAGING=/var/lib/vz/restic-staging
METRICS=/var/lib/prometheus/node-exporter/backup_restic.prom
START=$(date +%s)

log() { echo "[$(date '+%F %T')] $*"; }

write_metrics() {
    local status=$1 tmp="${METRICS}.$$"
    {
        echo "# HELP backup_restic_last_status 1 si la derniere sauvegarde a reussi, 0 sinon"
        echo "# TYPE backup_restic_last_status gauge"
        echo "backup_restic_last_status $status"
        echo "# HELP backup_restic_last_run_timestamp_seconds Fin de la derniere execution"
        echo "# TYPE backup_restic_last_run_timestamp_seconds gauge"
        echo "backup_restic_last_run_timestamp_seconds $(date +%s)"
        echo "# HELP backup_restic_duration_seconds Duree de la derniere execution"
        echo "# TYPE backup_restic_duration_seconds gauge"
        echo "backup_restic_duration_seconds $(( $(date +%s) - START ))"
        if [ "$status" = 1 ]; then
            echo "# HELP backup_restic_last_success_timestamp_seconds Fin de la derniere sauvegarde reussie"
            echo "# TYPE backup_restic_last_success_timestamp_seconds gauge"
            echo "backup_restic_last_success_timestamp_seconds $(date +%s)"
        elif [ -f "$METRICS" ]; then
            grep '^backup_restic_last_success_timestamp_seconds' "$METRICS" || true
        fi
    } > "$tmp" && mv "$tmp" "$METRICS"
}

fail() { log "ECHEC : $*"; rm -f "$STAGING"/vzdump-*; write_metrics 0; exit 1; }

mountpoint -q /mnt/pve/storagebox-backup || fail "Storage Box non montee"
mkdir -p "$STAGING"
# 755 obligatoire : pour un CT non privilégié, vzdump lance tar sous l'UID
# remappé (100000), qui doit pouvoir écrire son .tmp dans ce répertoire
chmod 755 "$STAGING"
rm -f "$STAGING"/vzdump-*

log "vzdump de tous les invites vers $STAGING"
vzdump --all 1 --mode snapshot --compress 0 --dumpdir "$STAGING" || fail "vzdump"

log "restic backup"
restic backup --host tusch-pve-01 --tag vzdump "$STAGING" || fail "restic backup"
rm -f "$STAGING"/vzdump-*

log "restic forget/prune"
restic forget --host tusch-pve-01 --tag vzdump \
       --keep-daily 7 --keep-weekly 4 --keep-monthly 3 --prune || fail "restic forget"

if [ "$(date +%u)" = 7 ]; then
    log "restic check (5 % des donnees)"
    restic check --read-data-subset=5% || fail "restic check"
fi

write_metrics 1
log "OK en $(( $(date +%s) - START )) s"
