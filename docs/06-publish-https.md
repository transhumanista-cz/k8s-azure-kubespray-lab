# 06 — Publishing Odoo with HTTPS (Traefik + cert-manager + Let's Encrypt)

```
 Browser ── https://odoo.example.com
    ▼
 DNS A record → master-1 public IP
    ▼
 NSG: 80/443 from Internet, only to 10.10.1.10
    ▼
 Traefik on master-1 (hostPort 80/443)  ← Ingress controller, terminates TLS
    │   certificate: Secret odoo-tls ← cert-manager ← Let's Encrypt (HTTP-01)
    ▼
 Service odoo → Odoo replicas on the workers
```

- **Ingress** — a rule "host/path → Service". It does nothing by itself.
- **Ingress controller** — the reverse proxy that executes those rules. ingress-nginx is
  retired (Kubespray v2.30 was the last release shipping it), so this lab uses **Traefik**.
- **cert-manager** — obtains and renews certificates automatically (an *operator* with CRDs:
  `Certificate`, `ClusterIssuer`, `Challenge`…).

No cloud load balancer here, and only master-1 has a public IP → Traefik runs on
master-1 and binds the node's ports 80/443 (**hostPort**, implemented by Calico's portmap plugin).

## 0. DNS and firewall

Point an A record to the master public IP (this lab used a free No-IP `*.ddns.net`
hostname — free No-IP names must be confirmed every 30 days).

```powershell
Resolve-DnsName odoo.example.com -Type A
```

Cloud Shell:

```bash
az network nsg rule create -g k8s-lab-rg --nsg-name k8s-nsg -n allow-http-https \
  --priority 110 --direction Inbound --access Allow --protocol Tcp \
  --source-address-prefixes Internet \
  --destination-address-prefixes 10.10.1.10 \
  --destination-port-ranges 80 443 -o none
```

Port 80 must be open to everyone: Let's Encrypt validates from unknown IPs.
SSH and the API (6443) stay restricted to your IPs.

## 1. Traefik

```bash
helm repo add traefik https://traefik.github.io/charts
helm repo update traefik
helm upgrade --install traefik traefik/traefik \
  -n traefik --create-namespace -f platform/traefik/values.yaml
kubectl -n traefik get pods -o wide     # on master-1
kubectl get ingressclass                # traefik (default)
```

From your PC `curl.exe -I http://odoo.example.com` → **404** = traffic reaches Traefik.

Values worth noting: control-plane `nodeSelector` + toleration; `service.spec.type: ClusterIP`
(LoadBalancer would stay pending); `maxSurge: 0` — a hostPort can't be bound twice on one node.

## 2. cert-manager and issuers

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update jetstack
helm upgrade --install cert-manager jetstack/cert-manager \
  -n cert-manager --create-namespace --version v1.21.3 --set crds.enabled=true
kubectl -n cert-manager rollout status deploy/cert-manager-webhook

kubectl apply -f platform/cert-manager/cluster-issuers.yaml
kubectl get clusterissuer                # both READY True
```

**HTTP-01 challenge:** Let's Encrypt asks for a token at
`http://<domain>/.well-known/acme-challenge/<token>`; cert-manager spins up a temporary
solver pod + Ingress, Let's Encrypt fetches the token from the internet, the certificate
is issued into a `kubernetes.io/tls` Secret, temporary objects are removed.

## 3. Ingress — staging first, then production

```bash
cd apps/odoo
sed -i 's/odoo.example.com/your.domain.tld/g' 50-ingress.yaml

# first run: staging issuer (untrusted cert, no rate-limit risk)
sed 's/letsencrypt-prod/letsencrypt-staging/' 50-ingress.yaml | kubectl apply -f -
kubectl -n odoo get certificate -w       # odoo-tls READY True
kubectl get challenges -A                # while validating

# production
kubectl apply -f 50-ingress.yaml
kubectl -n odoo delete secret odoo-tls   # force a fresh certificate
kubectl -n odoo get certificate -w
```

Inspect the certificate:

```bash
kubectl -n odoo get secret odoo-tls -o jsonpath='{.data.tls\.crt}' | base64 -d \
  | openssl x509 -noout -subject -issuer -dates
```

Result in this lab: issuer *Let's Encrypt* (intermediate `YR1`), valid 90 days,
renewed by cert-manager ~30 days before expiry.

`50-ingress.yaml` also contains a Traefik **Middleware** that redirects `http://` → `https://`
(301). Without it, the site is still served over plain HTTP — passwords in clear text.
Check: `curl.exe -I http://your.domain.tld` → `301`, `Location: https://…`.

## 4. Security checklist (the app is on the internet now)

- [ ] Odoo `admin` password is not `admin` — new certificates are published in
      Certificate Transparency logs and bots scan new hostnames within hours
- [ ] `--no-database-list` (DB manager hidden)
- [ ] `--proxy-mode` only behind the proxy
- [ ] HTTP → HTTPS redirect active
- [ ] Only 80/443 public, only on master-1; 22 and 6443 restricted

## Rollback

```bash
kubectl -n odoo delete ingress odoo
az network nsg rule delete -g k8s-lab-rg --nsg-name k8s-nsg -n allow-http-https
```
