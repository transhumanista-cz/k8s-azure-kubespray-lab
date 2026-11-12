# 01 — Azure infrastructure

## Design

```
                   Internet
                      │
        ┌─────────────┴──────────────┐
  inbound: 22/6443 from your IPs    outbound (apt, images)
  (later 80/443 for the website)         │
        │                                │
 [ master-1 public IP ]           [ NAT Gateway ]
        │                                │
┌───────┼──────── VNet 10.10.0.0/16 ─────┼────────────┐
│  Subnet 10.10.1.0/24  (NSG attached to the subnet)  │
│  master-1 10.10.1.10  B2als_v2  control plane+etcd  │
│  worker-1 10.10.1.11  B2as_v2   regular worker      │
│  worker-2 10.10.1.12  D2als_v6  SPOT worker         │
└─────────────────────────────────────────────────────┘
```

| Component | Why |
|---|---|
| One resource group | `az group delete` removes everything — nothing forgotten keeps billing |
| NSG on the subnet | Only 22 (SSH) and 6443 (K8s API) from your IPs; traffic inside the VNet is allowed by default rules |
| NAT Gateway | New VNets are private by default (since 31 Mar 2026): VMs without a public IP have no outbound internet. NAT gives the subnet one outbound IP; inbound through it is impossible |
| Public IP only on master-1 | Jump host + later the ingress entry point. Workers are not reachable from the internet |
| Static private IPs | The Kubespray inventory never changes |
| VNet 10.10.0.0/16 | Doesn't overlap Kubespray's pod (10.233.64.0/18) and service (10.233.0.0/18) networks |
| Standard SSD 30 GB | Cheaper than Premium, enough for a lab |

### Why restrict SSH by IP if keys are used?

Defense in depth. A key protects authentication, but not against vulnerabilities in
sshd that trigger *before* key verification (e.g. CVE-2024-6387 "regreSSHion"),
bot noise on small VMs, and — more importantly — the Kubernetes API on 6443, where one
RBAC mistake exposes the whole cluster.

## Create

Cloud Shell (Bash):

```bash
HOME_IP=<your public IP> bash infra/azure/01-create-infra.sh
```

Defaults: region `austriaeast`, sizes as above. Override with `LOC=`, `MASTER_SIZE=`,
`WORKER_SIZE=`, `SPOT_SIZE=`. The script is idempotent — re-run it after a failure.

The output prints the **master public IP** — you need it for
`kubespray/inventory/mycluster/group_vars/k8s_cluster/zz-lab.yml` and for DNS.

> Run it with `bash`, not `sh` — it uses bash arrays.

## Spot node

`worker-2` is a Spot VM (`--eviction-policy Deallocate --max-price -1`):
- Azure can evict it at any time (~30 s notice) when it needs capacity.
- On eviction the VM is **stopped, not deleted**; start it again with
  `az vm start -g k8s-lab-rg -n worker-2` (may fail until capacity returns).
- If the Spot VM can't be created, the script continues — the cluster works on 2 nodes.

## Useful commands

```bash
# your IP changed / Cloud Shell got a new IP
az network nsg rule update -g k8s-lab-rg --nsg-name k8s-nsg -n allow-ssh-api-from-me \
  --source-address-prefixes <home-ip> $(curl -s https://api.ipify.org)

# put a new SSH public key on a VM without SSH access (VMAccess extension)
az vm user update -g k8s-lab-rg -n <vm> -u azureuser --ssh-key-value "ssh-ed25519 AAAA..." -o none

# stop / start all VMs
az vm deallocate --ids $(az vm list -g k8s-lab-rg --query '[].id' -o tsv)
az vm start      --ids $(az vm list -g k8s-lab-rg --query '[].id' -o tsv)

# delete everything
bash infra/azure/99-destroy.sh
```

## Cloud Shell gotcha

If Cloud Shell runs in *ephemeral* mode (no storage account), the home directory —
including `~/.ssh/id_ed25519` — is wiped when the session ends. Download the key or
mount a storage account. A lost key can be replaced with `az vm user update` (above).
