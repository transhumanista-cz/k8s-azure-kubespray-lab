# 05 — Odoo 19 (ERP) with application-level high availability

Odoo is an open-source ERP (sales, inventory, accounting, CRM) — the same class of
application as SAP, small enough for this cluster. Architecture of a typical business
app: **web tier → application server → database → file storage**.

```
 Service odoo (NodePort 30069 / Ingress)
      │                    │
 ┌────▼────────┐    ┌──────▼──────┐
 │ odoo replica│    │ odoo replica│   Deployment, spread across nodes
 │  worker-1   │    │  worker-2   │
 └──┬──────┬───┘    └───┬─────┬───┘
    │      └── NFS ─────┘     │       /var/lib/odoo: attachments + sessions (shared)
    │    master-1:/srv/nfs    │
    └──────────┬──────────────┘
         ┌─────▼──────┐
         │ PostgreSQL │                StatefulSet, 1 replica, local-path disk
         │  worker-1  │                ← single point of failure (by design)
         └────────────┘
```

Scope: **application-level HA** — the Odoo tier survives pod and node failures;
the database is a single instance. DB-level HA (replicated PostgreSQL with an
operator such as CloudNativePG) is the next step.

## Deploy (master-1, from the repo's `apps/odoo/`)

```bash
kubectl apply -f 00-namespace.yaml
kubectl -n odoo create secret generic odoo-db \
  --from-literal=password="$(openssl rand -base64 18)"

kubectl apply -f 10-postgres.yaml
kubectl -n odoo get pods -o wide -w          # postgres-0 Running on worker-1
kubectl -n odoo exec postgres-0 -- psql -U odoo -d postgres -c "select version();"

kubectl apply -f 20-filestore-nfs.yaml
kubectl -n odoo get pvc odoo-filestore        # Bound

kubectl apply -f 30-init-job.yaml             # creates DB "odoo", installs base (2–5 min)
kubectl -n odoo logs -f job/odoo-init
kubectl -n odoo wait --for=condition=complete job/odoo-init --timeout=900s

kubectl apply -f 40-odoo.yaml
kubectl -n odoo get pods -o wide -w           # replicas on different workers
curl -s http://10.10.1.10:30069/web/health; echo   # {"status": "pass"}
```

Default login of a database created this way: `admin` / `admin` — **change it immediately**.

> Note: `kubectl get -w` watches one resource type only (`get pods,pvc -w` fails).

## Key design points

| Setting | Why |
|---|---|
| `Secret` + `secretKeyRef` | No password in git. Secrets are only base64-encoded, not encrypted — restrict access with RBAC |
| StatefulSet for PostgreSQL | Stable name `postgres-0`, disk bound to it, ordered start/stop |
| `PGDATA` subdirectory | `initdb` refuses non-empty directories |
| `enableServiceLinks: false` | No legacy `POSTGRES_PORT=tcp://…` env vars clashing with image settings |
| Init **Job** | One-off task that must finish (vs Deployment that must keep running) |
| `topologySpreadConstraints` | Replicas on different nodes, otherwise one node failure kills all |
| startup / readiness / liveness on `/web/health` | Slow boot tolerated; unready pods leave the Service; hung pods restart |
| `maxUnavailable: 0` | Rolling updates never reduce serving replicas |
| PDB `minAvailable: 1` | `kubectl drain` keeps at least one replica (does not protect from `delete`) |
| `--no-database-list` | Hide the database manager (can drop/download whole DBs) |
| `--proxy-mode` | Trust `X-Forwarded-*` from Traefik — only enable behind a proxy |

## Access before publishing: SSH tunnel to the NodePort

MobaXterm → *Tunneling → New SSH tunnel → Local port forwarding*:
local `8069` → SSH server `<MASTER_PUBLIC_IP>` (azureuser) → remote `10.10.1.10:30069`.
Browser: http://localhost:8069. Unlike `kubectl port-forward` (pinned to ONE pod),
this goes through the Service and is load-balanced across replicas.

## Installing Odoo modules with several replicas

Installing *Sales* from the UI with 2 replicas failed once with
`psycopg2.InterfaceError: cursor already closed` and succeeded on the second click.
Module installation changes the DB schema and reloads Odoo's registry while other
replicas (and their cron threads) keep using the same database.

Reliable options:

```bash
# A) temporarily one replica, install from the UI, scale back
kubectl -n odoo scale deployment odoo --replicas=1

# B) "migration" Job with the app stopped (production pattern)
kubectl -n odoo scale deployment odoo --replicas=0
sed -e 's/name: odoo-init/name: odoo-install-sales/' \
    -e 's/"-i", "base"/"-i", "sale_management"/' 30-init-job.yaml | kubectl apply -f -
kubectl -n odoo wait --for=condition=complete job/odoo-install-sales --timeout=1200s
kubectl -n odoo scale deployment odoo --replicas=2
```

Production hardening: web replicas with `--max-cron-threads=0` plus a separate
single-replica cron Deployment; more tolerant liveness during heavy operations.

Stuck module operations can be reset in the DB (take a backup first):

```sql
update ir_module_module set state='uninstalled' where state='to install';
```

## Cleanup

```bash
kubectl delete namespace odoo
kubectl delete pv odoo-filestore
sudo rm -rf /srv/nfs/odoo/*     # on master-1
```
