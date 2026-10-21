#!/usr/bin/env bash
# Module 8 — Diagnostic d'un dépôt hébergé, côté GitLab ET côté disque Gitaly.
# Usage : sudo ./diagnostic-depot.sh <groupe/projet>
#  - statistiques API (taille dépôt / LFS / artefacts, nombre de commits) ;
#  - chemin hashed storage (@hashed/ab/cd/sha256(id).git) ;
#  - objets : loose, packs, cruft packs (.mtimes), garbage ;
#  - structures d'accélération : commit-graph, multi-pack-index, bitmaps ;
#  - références par espace (heads, tags, keep-around, merge-requests, pipelines…) ;
#  - git fsck (connectivité et intégrité).
set -uo pipefail
[[ $EUID -eq 0 ]] || exec sudo -E bash "$0" "$@"
P=${1:?usage: $0 groupe/projet}
TOKEN=${GITLAB_TOKEN:-$(cat /home/formateur/.gitlab-token)}
API=http://gitlab.formation.lan/api/v4
t() { printf '\n=== %s ===\n' "$*"; }

info=$(curl -sf -H "PRIVATE-TOKEN: $TOKEN" "$API/projects/$(jq -rn --arg v "$P" '$v|@uri')?statistics=true") \
  || { echo "projet introuvable : $P"; exit 1; }
id=$(jq -r .id <<<"$info")
t "Statistiques GitLab (API)"
jq -r '.statistics | "dépôt \(.repository_size/1048576*100|round/100) Mio | LFS \(.lfs_objects_size/1048576*100|round/100) Mio | artefacts \(.job_artifacts_size/1048576*100|round/100) Mio | commits \(.commit_count)"' <<<"$info"

h=$(printf '%s' "$id" | sha256sum | cut -c1-64)
D=/var/opt/gitlab/git-data/repositories/@hashed/${h:0:2}/${h:2:2}/$h.git
t "Emplacement (hashed storage, projet $id)"
echo "$D  ($(du -sh "$D" | cut -f1) sur disque)"
G() { sudo -u git git -C "$D" "$@"; }

t "Objets (git count-objects -vH)"
G count-objects -vH
t "Packs"
for f in "$D"/objects/pack/*.pack; do
  [[ -e $f ]] || continue
  type=normal; [[ -e ${f%.pack}.mtimes ]] && type="CRUFT (objets inaccessibles en attente de purge)"
  printf '%8s  %s  %s\n' "$(du -h "$f" | cut -f1)" "$(basename "$f")" "$type"
done
t "Structures d'accélération"
[[ -e $D/objects/info/commit-graphs/commit-graph-chain || -e $D/objects/info/commit-graph ]] && echo "commit-graph : présent" || echo "commit-graph : ABSENT"
[[ -e $D/objects/pack/multi-pack-index ]] && echo "multi-pack-index : présent" || echo "multi-pack-index : absent"
ls "$D"/objects/pack/*.bitmap >/dev/null 2>&1 && echo "bitmap : présent" || echo "bitmap : ABSENT"
[[ -f $D/objects/info/alternates ]] && echo "alternates (pool d'objets / fork) : $(cat "$D/objects/info/alternates")"
[[ -f $D/packed-refs ]] && echo "packed-refs : $(grep -vc '^#' "$D/packed-refs") référence(s)"
t "Références par espace de noms"
G for-each-ref --format='%(refname)' | awk -F/ '{print $1"/"$2}' | sort | uniq -c
t "Intégrité (git fsck)"
sortie=$(G fsck --no-progress 2>&1); rc=$?
[[ -n $sortie ]] && head -8 <<<"$sortie"
if (( rc == 0 )); then echo "fsck : OK (les « dangling » sont des objets inaccessibles, pas des erreurs)"
else echo "fsck : ERREURS (code $rc)"; fi
