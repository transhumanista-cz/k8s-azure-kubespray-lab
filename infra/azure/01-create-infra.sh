#!/usr/bin/env bash
# =============================================================================
# 01-create-infra.sh — Azure infrastructure for a 3-node Kubespray lab
#
# Creates:
#   - Resource Group  k8s-lab-rg          — one "folder" for everything (delete = one command)
#   - NSG             k8s-nsg             — firewall: SSH + K8s API only from your IPs
#   - NAT Gateway     k8s-natgw (+ IP)    — outbound internet for all VMs
#   - VNet / Subnet   10.10.0.0/16 / 10.10.1.0/24
#   - 3 Ubuntu 24.04 VMs:
#       master-1  Standard_B2als_v2  2 vCPU / 4 GB   10.10.1.10  + public IP (jump host)
#       worker-1  Standard_B2as_v2   2 vCPU / 8 GB   10.10.1.11  (private only)
#       worker-2  Standard_D2als_v6  2 vCPU / 4 GB   10.10.1.12  SPOT (private only)
#
# Why these sizes: Free Trial = 4 regular vCPUs per region (2 + 2) plus a separate
# 3 vCPU Spot ("low-priority") quota — the third node fits only as a Spot VM.
# The B-series does not support Spot, hence D-series for worker-2.
#
# Usage (Azure Cloud Shell, run with bash — the script uses bash arrays):
#   HOME_IP=<your public IP> bash 01-create-infra.sh
#   HOME_IP=... LOC=swedencentral bash 01-create-infra.sh
#
# Idempotent: safe to re-run after a failure — existing resources are reused.
#
# If your IP changes, update the firewall rule:
#   az network nsg rule update -g k8s-lab-rg --nsg-name k8s-nsg -n allow-ssh-api-from-me \
#     --source-address-prefixes <home-ip> $(curl -s https://api.ipify.org)
# =============================================================================
set -euo pipefail

# ---------- 0. Parameters ----------------------------------------------------
: "${HOME_IP:?Set HOME_IP to your public IP, e.g. HOME_IP=198.51.100.7 bash $0}"

RG="${RG:-k8s-lab-rg}"
LOC="${LOC:-austriaeast}"          # pick one that 00-probe-capacity.sh reports as OK
VNET="k8s-vnet"
SUBNET="k8s-subnet"
NSG="k8s-nsg"
NATGW="k8s-natgw"
ADMIN="azureuser"
IMAGE="Canonical:ubuntu-24_04-lts:server:latest"

# Allowed source IPs for SSH (22) and Kubernetes API (6443):
# your home IP + the current Cloud Shell egress IP (it may change between sessions)
CLOUDSHELL_IP="$(curl -s https://api.ipify.org)"
ALLOWED_IPS=("$HOME_IP" "$CLOUDSHELL_IP")

MASTER_SIZE="${MASTER_SIZE:-Standard_B2als_v2}"   # control plane needs >= 2 vCPU (kubeadm preflight)
WORKER_SIZE="${WORKER_SIZE:-Standard_B2as_v2}"    # more RAM for apps and monitoring
SPOT_SIZE="${SPOT_SIZE:-Standard_D2als_v6}"       # Spot: separate quota, B-series not supported

# "name  size  private_ip  kind"
NODES=(
  "master-1 $MASTER_SIZE 10.10.1.10 regular"
  "worker-1 $WORKER_SIZE 10.10.1.11 regular"
  "worker-2 $SPOT_SIZE   10.10.1.12 spot"
)

echo ">>> SSH/API will be allowed from: ${ALLOWED_IPS[*]}"

# ---------- 1. SSH key -------------------------------------------------------
if [[ ! -f ~/.ssh/id_ed25519 ]]; then
  echo ">>> Generating SSH key ~/.ssh/id_ed25519"
  ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" -C "k8s-lab"
fi

# ---------- 2. Resource group ------------------------------------------------
echo ">>> Resource group"
az group create -n "$RG" -l "$LOC" -o none

# ---------- 3. NSG (firewall) ------------------------------------------------
# Default NSG rules already allow traffic inside the VNet and deny inbound from
# the internet. We add a single exception: 22 + 6443 from your IPs only.
echo ">>> NSG"
az network nsg create -g "$RG" -n "$NSG" -o none
az network nsg rule create -g "$RG" --nsg-name "$NSG" -n allow-ssh-api-from-me \
  --priority 100 --direction Inbound --access Allow --protocol Tcp \
  --source-address-prefixes "${ALLOWED_IPS[@]}" --destination-port-ranges 22 6443 -o none

# ---------- 4. NAT Gateway (outbound internet) -------------------------------
# Since 31 Mar 2026 new VNets are "private by default": VMs without a public IP
# get no implicit outbound access. Nodes need internet (apt, binaries, images).
# NAT Gateway gives the whole subnet one outbound IP; it does not allow inbound.
echo ">>> NAT Gateway"
az network public-ip create -g "$RG" -n "${NATGW}-pip" --sku Standard -o none
az network nat gateway create -g "$RG" -n "$NATGW" \
  --public-ip-addresses "${NATGW}-pip" --idle-timeout 10 -o none

# ---------- 5. Network -------------------------------------------------------
# 10.10.0.0/16 does not overlap Kubespray defaults: pods 10.233.64.0/18, services 10.233.0.0/18
echo ">>> VNet + subnet"
if ! az network vnet show -g "$RG" -n "$VNET" -o none 2>/dev/null; then
  az network vnet create -g "$RG" -n "$VNET" --address-prefixes 10.10.0.0/16 -o none
fi
az network vnet subnet create -g "$RG" --vnet-name "$VNET" -n "$SUBNET" \
  --address-prefixes 10.10.1.0/24 \
  --network-security-group "$NSG" \
  --nat-gateway "$NATGW" -o none

# ---------- 6. Virtual machines ----------------------------------------------
for spec in "${NODES[@]}"; do
  read -r NAME SIZE IP KIND <<<"$spec"

  if az vm show -g "$RG" -n "$NAME" -o none 2>/dev/null; then
    echo ">>> VM $NAME already exists — skipping"
    continue
  fi

  # Only master-1 gets a public IP: it is the jump host and the ingress entry point
  if [[ "$NAME" == "master-1" ]]; then
    PIP_ARGS=(--public-ip-address "${NAME}-pip" --public-ip-sku Standard)
  else
    PIP_ARGS=(--public-ip-address "")
  fi

  # Spot VM: discounted spare capacity, can be evicted at any time (~30 s notice).
  #   Deallocate  — on eviction the VM is stopped (disk kept), not deleted
  #   max-price -1 — pay current spot price up to on-demand; evict only on capacity
  if [[ "$KIND" == "spot" ]]; then
    SPOT_ARGS=(--priority Spot --eviction-policy Deallocate --max-price -1)
  else
    SPOT_ARGS=()
  fi

  echo ">>> VM $NAME ($SIZE, $IP, $KIND)"
  if ! az vm create -g "$RG" -n "$NAME" \
      --image "$IMAGE" --size "$SIZE" \
      --admin-username "$ADMIN" --ssh-key-values ~/.ssh/id_ed25519.pub \
      --vnet-name "$VNET" --subnet "$SUBNET" --private-ip-address "$IP" \
      --nsg "" "${PIP_ARGS[@]}" "${SPOT_ARGS[@]}" \
      --storage-sku StandardSSD_LRS --os-disk-size-gb 30 \
      --os-disk-delete-option Delete --nic-delete-option Delete \
      -o none; then
    if [[ "$KIND" == "spot" ]]; then
      echo "!!! Spot VM $NAME was not created — continuing without it (re-run later)"
    else
      echo "!!! Failed to create $NAME — stopping"; exit 1
    fi
  fi
done

# ---------- 7. Summary -------------------------------------------------------
echo
echo "=============== Done ==============="
az vm list -g "$RG" -d \
  --query "[].{Name:name, Size:hardwareProfile.vmSize, Priority:priority, PrivateIP:privateIps, PublicIP:publicIps, State:powerState}" \
  -o table

MASTER_PIP=$(az vm show -g "$RG" -n master-1 -d --query publicIps -o tsv)
echo
echo "Master public IP: ${MASTER_PIP}"
echo "  -> put it into kubespray/inventory/mycluster/group_vars/k8s_cluster/zz-lab.yml"
echo "     (supplementary_addresses_in_ssl_keys) and into your DNS A record"
echo
echo "Connect:  ssh ${ADMIN}@${MASTER_PIP}"
echo "Spot node evicted?   az vm start -g $RG -n worker-2"
echo "Stop all VMs:        az vm deallocate --ids \$(az vm list -g $RG --query '[].id' -o tsv)"
echo "Delete everything:   az group delete -n $RG --yes"
