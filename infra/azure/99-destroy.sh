#!/usr/bin/env bash
# Delete the whole lab: every resource lives in one resource group.
# NAT Gateway and public IPs are billed even when VMs are stopped —
# delete the group when you take a longer break; the scripts recreate it in minutes.
set -euo pipefail
RG="${RG:-k8s-lab-rg}"
read -r -p "Delete resource group '$RG' and EVERYTHING in it? Type the name to confirm: " ANSWER
[[ "$ANSWER" == "$RG" ]] || { echo "Aborted."; exit 1; }
az group delete -n "$RG" --yes
