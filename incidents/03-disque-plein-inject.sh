#!/usr/bin/env bash
# Incident 03 — Partition / pleine
# Un « export » oublié remplit tout l'espace disponible pour les utilisateurs non-root.
# fallocate réserve les blocs instantanément sans écrire de données (pas d'usure du disque,
# pas de croissance d'un disque virtuel dynamique au-delà des métadonnées).
# Les 5 % réservés à root par ext4 restent libres : la VM reste administrable.
# Symptômes : push refusés (« unpacker error »), erreurs 500 en écriture (PostgreSQL
# « could not extend file … No space left on device »), journaux tronqués.
source "$(dirname "$(readlink -f "$0")")/_commun.sh"
besoin_root "$@"

N=03
FICHIER=/var/tmp/export-gitlab/export-complet-20261014.tar
est_injecte $N && die "incident $N déjà injecté"

dispo=$(df --output=avail -B1 / | tail -1)
(( dispo > 1024*1024*1024 )) || die "moins de 1 Go libre : injection annulée"
mkdir -p "$(dirname "$FICHIER")"
fallocate -l "$dispo" "$FICHIER" || die "fallocate impossible sur ce système de fichiers"
echo "$FICHIER" > "$ETAT/$N-fichier"
marquer $N
log "Incident $N injecté : $(df -h / | tail -1)"
