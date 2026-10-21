#!/bin/sh
# "Construction" factice : produit un artefact
set -e
mkdir -p dist
echo "app version $(git rev-parse --short HEAD 2>/dev/null || echo dev)" > dist/version.txt
cat dist/version.txt
