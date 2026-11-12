# 03 — Radar (Kubernetes UI) in the cluster

[Radar by Skyhook](https://github.com/skyhook-io/radar) is a web UI for Kubernetes:
topology, workloads, logs, events, Helm releases. It talks to the Kubernetes API
directly, no agents or CRDs.

## Local vs in-cluster

| | Local (on your PC) | In-cluster (Helm) |
|---|---|---|
| Install | one command | Helm + values + RBAC + access path |
| Cluster resources | none | 256 Mi request, 1 Gi limit |
| Permissions | yours (admin) | Radar's ServiceAccount only |
| Works when PC is off | no | yes, keeps a timeline 24/7 |
| Team access | no | yes (with proxy/OIDC auth) |

This lab installs it **in-cluster** to practice Helm, values, affinity and RBAC.

## Install (master-1)

```bash
kubectl describe node worker-1 | grep -A 8 "Allocated resources"   # check headroom first

helm repo add skyhook https://skyhook-io.github.io/helm-charts
helm repo update skyhook
helm upgrade --install radar skyhook/radar \
  -n radar --create-namespace \
  -f platform/radar/values.yaml
kubectl -n radar get pods -o wide        # Running on worker-1 (never on the Spot node)
```

`platform/radar/values.yaml`:
- **required node affinity** `lifecycle NotIn [spot]` — hard guarantee (the taint is only soft);
- **read-only RBAC** — Radar's default auth mode is `none`, so its rights equal the rights
  of anyone who reaches it;
- **ClusterIP** only — never exposed publicly;
- CPU limit lowered from 2 to 1 (B-series VMs are burstable).

## Open (PC)

```powershell
kubectl port-forward svc/radar 9280:9280 -n radar
```

Browser: http://localhost:9280. The tunnel is: browser → kubectl (localhost) →
TLS (mutual, client certificate from kubeconfig) → API server → kubelet → pod.
The "lock" on Radar is the kubeconfig: port-forward requires `pods/portforward` rights.

## Requests vs limits

- **requests** — guaranteed reservation; the scheduler places pods by the sum of requests.
- **limits** — ceiling: CPU is throttled, memory over the limit → `OOMKilled`.
- Limits may exceed node capacity in total ("overcommitted") — that's normal.
