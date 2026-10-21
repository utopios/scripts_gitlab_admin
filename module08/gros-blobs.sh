#!/usr/bin/env bash
# Module 8 — Les N plus gros blobs de TOUT l'historique d'un dépôt (y compris les fichiers
# supprimés depuis), avec leur chemin. Équivalent « pauvre » de git-sizer.
# Usage : ./gros-blobs.sh [chemin_du_depot=.] [N=10] [seuil_octets=0]
#   colonnes : oid, taille brute, taille compressée sur disque, chemin
set -euo pipefail
DEPOT=${1:-.}; N=${2:-10}; SEUIL=${3:-0}
git -C "$DEPOT" rev-list --objects --all \
  | git -C "$DEPOT" cat-file --batch-check='%(objecttype) %(objectname) %(objectsize) %(objectsize:disk) %(rest)' \
  | awk -v s="$SEUIL" '$1 == "blob" && $3 >= s {print $2, $3, $4, $5}' \
  | sort -k2,2 -n -r | head -n "$N" \
  | awk '{printf "%s %10.1f Mio %10.1f Mio  %s\n", $1, $2/1048576, $3/1048576, $4}'
