#!/usr/bin/env bash
# Indicateurs de type DORA calculés par l'API en GitLab CE (les tableaux DORA et l'API /dora/metrics
# sont Ultimate : 404 en CE). Approximation à adapter à votre définition :
#   - fréquence de déploiement : déploiements "success" sur l'environnement production / période
#   - délai de livraison des changements : merged_at - created_at des MR fusionnées (médiane)
#   - taux d'échec : pipelines failed / (success + failed)  (inclut les pipelines externes Jenkins)
# Usage : ./indicateurs-ce.sh <groupe/projet> [jours=30] [environnement=production]
source "$(dirname "$0")/lib.sh"
PROJ=$1; DAYS=${2:-30}; ENV=${3:-production}
SINCE=$(date -u -d "-$DAYS days" +%FT%TZ)
pid=$(api GET "/projects/$(urlenc "$PROJ")" | jq -r .id)
pages() { local p=1 out; while out=$(api GET "$1&per_page=100&page=$p") && [[ $(jq length <<<"$out") -gt 0 ]]; do echo "$out"; p=$((p+1)); done | jq -s 'add // []'; }

dep=$(pages "/projects/$pid/deployments?environment=$ENV&updated_after=$SINCE&order_by=updated_at")
mrs=$(pages "/projects/$pid/merge_requests?state=merged&target_branch=main&updated_after=$SINCE")
pip=$(pages "/projects/$pid/pipelines?updated_after=$SINCE")

echo "Projet $PROJ - $DAYS derniers jours (depuis $SINCE)"
jq -r --argjson d "$DAYS" '"  déploiements $ENV réussis : \([.[] | select(.status=="success")] | length) (\(([.[] | select(.status=="success")] | length) * 7 / $d * 100 | floor / 100) / semaine)"' <<<"$dep" | sed "s/\$ENV/$ENV/"
jq -r '[.[] | select(.merged_at) | ((.merged_at|sub("\\.[0-9]+";"")|sub("\\+.*";"Z")|fromdate) - (.created_at|sub("\\.[0-9]+";"")|sub("\\+.*";"Z")|fromdate))/3600] | sort
       | "  MR fusionnées : \(length)  délai médian création -> fusion : \(if length>0 then (.[length/2|floor]*10|floor/10|tostring)+" h" else "n/a" end)"' <<<"$mrs"
jq -r '(map(select(.status=="success"))|length) as $s | (map(select(.status=="failed"))|length) as $f
       | "  pipelines : \(length) (dont externes : \(map(select(.source=="external"))|length))  success=\($s) failed=\($f)  taux d\u0027échec : \(if $s+$f>0 then ($f*1000/($s+$f)|floor/10|tostring)+" %" else "n/a" end)"' <<<"$pip"
