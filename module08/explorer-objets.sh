#!/usr/bin/env bash
# Module 8 — Démo « Git de l'intérieur » sur un clone de plateforme/backend/api-commandes :
# objets (commit, tree, blob), refs, HEAD, packfiles, index de pack, commit-graph.
# Usage : ./explorer-objets.sh   (travaille dans ~/m08-demo, relançable)
set -euo pipefail
TOKEN=${GITLAB_TOKEN:-$(cat ~/.gitlab-token)}
D=~/m08-demo/api-commandes
t() { printf '\n### %s\n' "$*"; }
rm -rf "$D"; mkdir -p ~/m08-demo
git clone -q "http://oauth2:$TOKEN@gitlab.formation.lan/plateforme/backend/api-commandes.git" "$D"
cd "$D"; git remote set-url origin http://gitlab.formation.lan/plateforme/backend/api-commandes.git

t "HEAD et références"
cat .git/HEAD; git for-each-ref --format='%(objectname:short) %(refname)'
t "Le commit pointé par main"
git cat-file -t main; git cat-file -p main
t "Son arbre (tree)"
git cat-file -p 'main^{tree}'
t "Un blob (contenu de README.md)"
git cat-file -p main:README.md
t "Objets du clone : tous dans un pack"
git count-objects -vH
ls -la .git/objects/pack/
t "Contenu de l'index de pack (type, taille, taille compressée, offset)"
git verify-pack -v .git/objects/pack/*.idx > /tmp/verify-pack.txt; head -12 /tmp/verify-pack.txt   # (évite SIGPIPE avec pipefail)
tail -3 /tmp/verify-pack.txt
t "Écriture d'un nouvel objet : stockage « loose » (zlib) puis repack"
echo "note de démo" > note.txt; git add note.txt
oid=$(git rev-parse :note.txt); echo "blob $oid -> .git/objects/${oid:0:2}/${oid:2}"
ls -la ".git/objects/${oid:0:2}/"
python3 -c "import zlib,sys; print(zlib.decompress(open(sys.argv[1],'rb').read()))" ".git/objects/${oid:0:2}/${oid:2}"
git -c user.name=Demo -c user.email=demo@formation.lan commit -qm "Note de démo (local, non poussé)"; git gc -q
git count-objects -v | grep -E '^(count|in-pack|packs)'
t "commit-graph (accélère log, merge-base, calcul des ancêtres)"
git commit-graph write --reachable 2>/dev/null; ls .git/objects/info/
git commit-graph verify && echo "commit-graph valide"
