#!/bin/sh
# Tests factices : échouent si le fichier VERSION contient "casse" (pour montrer un statut failed)
set -e
if grep -qi casse VERSION 2>/dev/null; then echo "TEST KO"; exit 1; fi
echo "TESTS OK"
