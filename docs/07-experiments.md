# 07 — Experiments: networking, Spot eviction, failover

## 1. Pod network across nodes

```bash
kubectl run test-w1 --image=nginx:1.30 --overrides='{"spec":{"nodeName":"worker-1"}}'
kubectl run test-w2 --image=nginx:1.30 --overrides='{"spec":{"nodeName":"worker-2"}}'
kubectl get pods -o wide                         # note test-w2's IP (10.233.x.x)
kubectl expose pod test-w2 --port=80 --name=test-svc

kubectl run tmp --rm -it --restart=Never --image=busybox:1.36 \
  --overrides='{"spec":{"nodeName":"worker-1"}}' -- sh
/ # wget -qO- http://<test-w2-ip> | head -4     # pod -> pod over Calico VXLAN
/ # nslookup test-svc                           # DNS via nodelocaldns 169.254.25.10
/ # wget -qO- http://test-svc | head -4          # Service via kube-proxy
/ # wget -qO- http://example.com | head -4       # internet via NAT Gateway
/ # exit

kubectl delete svc test-svc; kubectl delete pod test-w1 test-w2
```

`nodeName` bypasses the scheduler (and therefore soft taints). The many `NXDOMAIN`
lines from busybox `nslookup` are just the search-domain list being tried.

## 2. Spot eviction (`labs/spot-eviction/`)

```bash
kubectl apply -f labs/spot-eviction/spot-demo.yaml
kubectl get pods -l app=spot-demo -o wide        # mostly on worker-2
kubectl get nodes -w                              # second terminal
# Cloud Shell:
az vm deallocate -g k8s-lab-rg -n worker-2
```

Observed timeline:
1. ~40–60 s: node `NotReady` (no kubelet heartbeats), taint
   `node.kubernetes.io/unreachable:NoExecute` added.
2. Pods tolerate it for **300 s** (default `tolerationSeconds`) — the network may just blink.
3. Then pods are evicted and the Deployment recreates them on worker-1.
4. `az vm start` → event `Rebooted` (new boot ID); DaemonSet pods are the same objects,
   their containers show `Restarted (1)`. The static pod `nginx-proxy` starts first.
5. **Pods do not move back automatically** — the scheduler decides only at creation time.
   `kubectl rollout restart deployment spot-demo` rebalances (rolling update: new
   ReplicaSet 0→3 while the old one goes 3→0). The *descheduler* project automates this.

Events are kept ~1 h: `kubectl get events -A --sort-by=.lastTimestamp`.

## 3. podinfo HA lab (`labs/podinfo-ha/`)

```bash
kubectl apply -f labs/podinfo-ha/podinfo.yaml
kubectl apply -f labs/podinfo-ha/loadgen.yaml
kubectl logs -f loadgen                           # which pod answered, or FAIL
kubectl logs loadgen --tail=100 | grep OK | awk '{print $3}' | sort | uniq -c
```

| Failure | Command | Expected |
|---|---|---|
| Delete a pod | `kubectl delete pod <name>` | 0 FAIL (graceful termination) |
| Crash | `kubectl exec loadgen -- wget -qO- http://<pod-ip>:9898/panic` | container restart, ~0–2 FAIL |
| Not ready | `kubectl exec loadgen -- wget -qO- --post-data='' http://<pod-ip>:9898/readyz/disable` | removed from Service, not restarted |
| Drain node | `kubectl drain worker-2 --ignore-daemonsets --delete-emptydir-data` | 0 FAIL, PDB evicts one at a time |
| Lose node | `az vm deallocate … worker-2` | FAILs for ~40–60 s until NotReady |

Planned operations are invisible to users; sudden failures are visible until detected.

## 4. Odoo: delete 3 of 4 replicas

```bash
sed -i 's/replicas: 2/replicas: 4/' apps/odoo/40-odoo.yaml && kubectl apply -f apps/odoo/40-odoo.yaml
# second terminal — a "user":
while true; do echo "$(date +%T) $(curl -s -o /dev/null -m 2 -w '%{http_code}' http://10.10.1.10:30069/web/health)"; sleep 0.5; done

kubectl -n odoo delete $(kubectl -n odoo get pods -l app=odoo -o name | head -3) --wait=false
kubectl -n odoo get pods -l app=odoo -o wide -w
```

Result: Odoo kept serving from the single surviving replica (sessions on NFS — no logout);
the Deployment recreated the 3 pods. Side effect: **13 pods `OutOfcpu`** on worker-1 —
see [lessons learned](lessons-learned.md).

Scale changes go into the YAML file (declarative), not `kubectl scale` — otherwise the
next `kubectl apply` silently reverts them.
