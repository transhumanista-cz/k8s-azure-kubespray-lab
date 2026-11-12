#!/usr/bin/env bash
# =============================================================================
# 00-probe-capacity.sh — find regions + VM sizes you can ACTUALLY create right now
#
# Why: on Azure Free Trial subscriptions many regions/sizes are restricted.
# There are two different failure modes:
#   1. Subscription restriction  — "this size is not offered to you in this region"
#                                  -> visible in `az vm list-skus`
#   2. Capacity restriction      — "offered, but no free hardware right now"
#                                  -> visible ONLY when you try to deploy
#
# How it works (creates NOTHING, costs nothing):
#   1. `az vm list-skus`              — sizes allowed for your subscription
#   2. `az deployment group validate` — ARM "preflight" validation of a template
#      with a VM; it checks quotas, capacity and availability without deploying.
#
# Usage (Azure Cloud Shell, bash):
#   bash 00-probe-capacity.sh
#   REGIONS="austriaeast swedencentral" bash 00-probe-capacity.sh
#
# Note: preflight is not a 100% guarantee (rarely a VM can still fail later
# with AllocationFailed), but "OK" here almost always means the VM will deploy.
# =============================================================================
set -uo pipefail   # no -e: validation failures are an expected part of the probe

RG="${RG:-k8s-lab-rg}"   # resource group used only as a "scope" for validation

read -r -a REGIONS <<<"${REGIONS:-austriaeast swedencentral germanywestcentral polandcentral northeurope francecentral italynorth switzerlandnorth}"

# Candidates: 1 vCPU (workers) and 2 vCPU / >=4 GB (control plane)
SIZES=(
  Standard_B1ms
  Standard_B2s
  Standard_B2als_v2  Standard_B2ls_v2
  Standard_B2as_v2   Standard_B2s_v2
  Standard_D2als_v6  Standard_D2as_v6
  Standard_D2as_v5   Standard_D2s_v5
)

if [[ ! -f ~/.ssh/id_ed25519.pub ]]; then
  ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" -C "k8s-lab"
fi
KEY="$(cat ~/.ssh/id_ed25519.pub)"

if ! az group show -n "$RG" -o none 2>/dev/null; then
  az group create -n "$RG" -l "${REGIONS[0]}" -o none
fi

# Minimal ARM template: VNet + NIC + VM
TPL="$(mktemp --suffix=.json)"
trap 'rm -f "$TPL"' EXIT
cat >"$TPL" <<'EOF'
{
  "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "location": { "type": "string" },
    "vmSize":   { "type": "string" },
    "sshKey":   { "type": "string" }
  },
  "resources": [
    {
      "type": "Microsoft.Network/virtualNetworks", "apiVersion": "2023-09-01",
      "name": "probe-vnet", "location": "[parameters('location')]",
      "properties": {
        "addressSpace": { "addressPrefixes": ["10.99.0.0/16"] },
        "subnets": [ { "name": "s", "properties": { "addressPrefix": "10.99.0.0/24" } } ]
      }
    },
    {
      "type": "Microsoft.Network/networkInterfaces", "apiVersion": "2023-09-01",
      "name": "probe-nic", "location": "[parameters('location')]",
      "dependsOn": [ "[resourceId('Microsoft.Network/virtualNetworks', 'probe-vnet')]" ],
      "properties": {
        "ipConfigurations": [ {
          "name": "ip",
          "properties": {
            "privateIPAllocationMethod": "Dynamic",
            "subnet": { "id": "[resourceId('Microsoft.Network/virtualNetworks/subnets', 'probe-vnet', 's')]" }
          }
        } ]
      }
    },
    {
      "type": "Microsoft.Compute/virtualMachines", "apiVersion": "2024-07-01",
      "name": "probe-vm", "location": "[parameters('location')]",
      "dependsOn": [ "[resourceId('Microsoft.Network/networkInterfaces', 'probe-nic')]" ],
      "properties": {
        "hardwareProfile": { "vmSize": "[parameters('vmSize')]" },
        "storageProfile": {
          "imageReference": { "publisher": "Canonical", "offer": "ubuntu-24_04-lts", "sku": "server", "version": "latest" },
          "osDisk": { "createOption": "FromImage", "managedDisk": { "storageAccountType": "StandardSSD_LRS" } }
        },
        "osProfile": {
          "computerName": "probe", "adminUsername": "azureuser",
          "linuxConfiguration": {
            "disablePasswordAuthentication": true,
            "ssh": { "publicKeys": [ { "path": "/home/azureuser/.ssh/authorized_keys", "keyData": "[parameters('sshKey')]" } ] }
          }
        },
        "networkProfile": { "networkInterfaces": [ { "id": "[resourceId('Microsoft.Network/networkInterfaces', 'probe-nic')]" } ] }
      }
    }
  ]
}
EOF

OK_LIST=()

for r in "${REGIONS[@]}"; do
  echo "=== $r"
  ALLOWED="$(az vm list-skus -l "$r" --resource-type virtualMachines --query "[].name" -o tsv 2>/dev/null)"

  for s in "${SIZES[@]}"; do
    if ! grep -qx "$s" <<<"$ALLOWED"; then
      printf "   %-20s -  not offered to subscription\n" "$s"
      continue
    fi

    OUT="$(az deployment group validate -g "$RG" --template-file "$TPL" \
             --parameters location="$r" vmSize="$s" sshKey="$KEY" -o none 2>&1)"
    RC=$?

    if [[ $RC -eq 0 ]]; then
      printf "   %-20s OK\n" "$s"
      OK_LIST+=("$r $s")
    elif grep -q "Capacity" <<<"$OUT"; then
      printf "   %-20s -  no capacity right now\n" "$s"
    else
      CODE="$(grep -oE 'QuotaExceeded|OperationNotAllowed|SkuNotAvailable|RequestDisallowedByAzure|NotAvailableForSubscription' <<<"$OUT" | head -1)"
      printf "   %-20s -  error: %s\n" "$s" "${CODE:-other (inspect manually)}"
    fi
  done
done

echo
echo "================= SUMMARY: deployable now ================="
if [[ ${#OK_LIST[@]} -eq 0 ]]; then
  echo "Nothing found. Try again later — capacity changes over time."
  exit 0
fi
for r in "${REGIONS[@]}"; do
  LINE=""
  for e in "${OK_LIST[@]}"; do
    [[ "${e%% *}" == "$r" ]] && LINE+="${e#* } "
  done
  [[ -n "$LINE" ]] && printf "%-20s %s\n" "$r" "$LINE"
done
