# Lessons learned

Real problems hit while building this lab — symptom, cause, fix.

## Azure

**Region "not accepting new customers"** — `RequestDisallowedByAzure` on the first real
resource (the resource group itself succeeded: it's only metadata). Popular regions
reserve capacity for paying customers. → Probe regions.

**`SkuNotAvailable … Capacity Restrictions`** although `az vm list-skus` listed the size.
Two different restrictions: *offered to the subscription* vs *hardware available now*.
→ `infra/azure/00-probe-capacity.sh` uses ARM preflight validation, which catches both,
for free. Old generations (B1ms, B2s) were the first to disappear.

**`az vm list-usage` returned nothing** — `Microsoft.Compute` was not registered on the
new subscription.

**VMs without a public IP had no internet** — new VNets are private by default
(since 31 Mar 2026). → NAT Gateway. Bonus: one stable egress IP for allow-lists; NAT
takes precedence over the master's own public IP for outbound traffic.

**Resource group location is immutable** — `InvalidResourceGroupLocation` when re-creating
in another region. Delete and recreate (resources inside may live in other regions,
but keep them together).

**Ephemeral Cloud Shell lost the SSH key** — restore access without SSH via
`az vm user update` (VMAccess extension).

**Spot VMs**: separate quota (extra node on Free Trial), B-series not supported,
`--validate` checks availability without creating anything.

## Ansible / Kubespray

**`>>` into a misspelled file** (`inventory.in`) silently created a new file. Always
verify with `tail`/`cat` after writing.

**Agent forwarding is fragile for long runs** — a dedicated key on the control node + `tmux`.

**Interpreter discovery warnings** → `ansible_python_interpreter=/usr/bin/python3`.

**`shell` module always reports `CHANGED`** — prefer specific modules (`apt`, `file`, `copy`).

**Single vs double quotes** in `ansible -a`: double quotes let your local shell expand
`$(hostname)` before Ansible runs it remotely.

## Kubernetes

**`kubectl` → `localhost:8080`** — empty or missing kubeconfig (here: `mkdir` created a
*folder* named `config`, then an empty file was downloaded).

**`get pods,pvc -w` fails** — watch supports one resource type.

**Taint vs affinity** — a taint is a node's "keep away" (soft `PreferNoSchedule` is not a
guarantee); node affinity is a pod's "I want / don't want". Use both.

**Pods don't rebalance** after a node returns — scheduling happens once per pod.

**PDB doesn't stop `kubectl delete`** — it only governs evictions (drain).

**`OutOfcpu` storm** — with 4 Odoo replicas worker-1 was near its CPU allocatable
(~1.4 of 2 cores — the rest is reserved for the OS and kubelet). After deleting 3 pods
with `--wait=false`, replacements were scheduled to worker-1 while the old pods were
still terminating; the kubelet's admission check rejected them (`OutOfcpu`), the
ReplicaSet created new ones, 13 failed pods piled up. **HA needs headroom** (N+1 capacity),
requests sized from real usage (`kubectl top`), and ideally node autoscaling.
Cleanup: `kubectl delete pods --field-selector=status.phase=Failed`.

**hostPort + default rolling update = deadlock** — the new Traefik pod can't bind port 80
while the old one holds it → `maxSurge: 0`.

**Secrets are base64, not encryption** — `kubectl get secret … | base64 -d` reveals them.

**Image tag `latest` (or none)** → `imagePullPolicy: Always`, re-checks the registry on
every pod start. Pin versions.

## Odoo

**Module install from the UI failed with 2 replicas** (`cursor already closed`), worked
on retry. Schema changes are migrations: do them with one process (Job or 1 replica).
HA protects against failures, not against schema changes.

**Behind a proxy** Odoo needs `--proxy-mode`; never enable it without a proxy
(clients could spoof `X-Forwarded-*`).

## Security

- Never commit kubeconfigs, SSH keys, `inventory/*/artifacts/`, passwords (see `.gitignore`).
- Publish only what must be public (80/443 on one node); keep 22/6443 IP-restricted.
- Radar/dashboards without auth stay internal (ClusterIP + port-forward).
- HTTP→HTTPS redirect; strong admin password before the certificate appears in CT logs.
