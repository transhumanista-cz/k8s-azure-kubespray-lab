# 00 — Azure account, quotas and choosing a region

## Free account

The Azure free account gives a **USD 200 credit for 30 days** plus 12 months of
selected free services. The credit is applied automatically when you sign up through
the *free account* path — there is nothing to "activate".

Check that your subscription really is a Free Trial (Cloud Shell → Bash):

```bash
az rest --method get \
  --url "https://management.azure.com/subscriptions/$(az account show --query id -o tsv)?api-version=2020-01-01" \
  --query "subscriptionPolicies.quotaId" -o tsv
```

- `FreeTrial_2014-09-01` → credit available
- `PayAsYouGo_2014-09-01` → no credit

Credit balance: *Cost Management + Billing → Payment methods → Azure credits*.
Right after sign-up the portal may fail to load credit info for a while — that's normal.

> Set a **budget alert** (Cost Management → Budgets, e.g. $150) before creating anything.

## Register resource providers

A brand-new subscription may not have `Microsoft.Compute` registered — then
`az vm list-usage` silently returns nothing.

```bash
az provider show -n Microsoft.Compute --query registrationState -o tsv
az provider register -n Microsoft.Compute
az provider register -n Microsoft.Network
az provider register -n Microsoft.Storage
```

## Quotas

```bash
az vm list-usage -l <region> -o table | head -30
```

Typical Free Trial limits **per region**:

| Quota | Limit |
|---|---|
| Total Regional vCPUs | 4 |
| Per VM family (BS, Basv2, Dasv6, …) | 4 |
| Total Regional Low-priority (Spot) vCPUs | 3 |

Consequences for the cluster design:
- kubeadm requires **≥ 2 vCPU on the control plane** (preflight check), workers don't.
- With 2-vCPU sizes only two regular nodes fit (2 + 2 = 4).
- The **Spot quota is separate** — a third node fits as a Spot VM.
- Free Trial quotas generally cannot be raised without upgrading to Pay-As-You-Go.

## Choosing a region — what actually happened

| Region | Result |
|---|---|
| westeurope | `RequestDisallowedByAzure: region not accepting new customers` |
| switzerlandnorth | `SkuNotAvailable … Capacity Restrictions` for B2s, then for B2als_v2 |
| most others nearby | B1ms / B2s not offered to the subscription |
| **austriaeast**, swedencentral | B-v2 and D-series sizes deployable |

Two different restrictions exist:

1. **Subscription restriction** — the size is not offered to you → `az vm list-skus`.
2. **Capacity restriction** — offered, but no free hardware → only visible on deploy.

`infra/azure/00-probe-capacity.sh` checks both: it lists allowed sizes and runs an ARM
**preflight validation** (`az deployment group validate`) for each region × size.
It creates nothing and costs nothing.

```bash
bash infra/azure/00-probe-capacity.sh
```

Spot availability can be checked the same way:

```bash
az vm create -g k8s-lab-rg -n spot-test -l austriaeast \
  --image Canonical:ubuntu-24_04-lts:server:latest --size Standard_D2als_v6 \
  --priority Spot --eviction-policy Deallocate --max-price -1 \
  --ssh-key-values ~/.ssh/id_ed25519.pub --validate
```

## Cost

Roughly **$3–4/day** for 3 VMs + NAT Gateway + disks + public IPs (estimate).
NAT Gateway and public IPs are billed even when VMs are deallocated —
for longer breaks delete the resource group and recreate it with the scripts.
