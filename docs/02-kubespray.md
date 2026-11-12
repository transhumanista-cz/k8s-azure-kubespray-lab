# 02 — Kubernetes with Kubespray

Kubespray is a set of Ansible playbooks that turns plain Linux VMs into a Kubernetes
cluster (kubeadm under the hood). Ansible is **agentless**: it connects over SSH,
copies small Python modules, runs them and removes them.

| Role | Host |
|---|---|
| Ansible **control node** (runs the playbooks) | master-1 |
| **Managed nodes** | master-1, worker-1, worker-2 |

In production the control node is usually a separate bastion VM; in a 4-vCPU lab
the master is the pragmatic choice — it's inside the private network and doesn't
depend on your laptop's connection.

## 1. Two SSH keys

1. **Your key** (PC → master-1). With MobaXterm: *Tools → MobaKeyGen*, type EdDSA/Ed25519,
   save the `.ppk`, add it in *Settings → SSH → SSH agents (MobAgent)* and in the session.
2. **Ansible key** (master-1 → all nodes) — lives on the master, so a 20–40 min
   playbook run doesn't die if your laptop disconnects (agent forwarding would).

On master-1:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" -C "ansible@master-1"
cat ~/.ssh/id_ed25519.pub
```

In Cloud Shell — distribute it to **all three** VMs (Ansible also SSHes into master-1 itself):

```bash
ANSIBLE_KEY="ssh-ed25519 AAAA... ansible@master-1"
for vm in master-1 worker-1 worker-2; do
  az vm user update -g k8s-lab-rg -n "$vm" -u azureuser --ssh-key-value "$ANSIBLE_KEY" -o none
done
```

Check from master-1:

```bash
for ip in 10.10.1.10 10.10.1.11 10.10.1.12; do
  ssh -o StrictHostKeyChecking=accept-new $ip hostname
done
curl -s https://api.ipify.org; echo     # shows the NAT Gateway IP, not the master's public IP
```

## 2. Install Kubespray (pinned release) in a venv

```bash
sudo apt update && sudo apt install -y git python3-venv python3-pip
git clone https://github.com/kubernetes-sigs/kubespray.git ~/kubespray
cd ~/kubespray
git checkout v2.32.0                 # this lab was built with v2.32.0 (Kubernetes 1.36)

python3 -m venv ~/kubespray-venv
source ~/kubespray-venv/bin/activate
pip install -U pip
pip install -r requirements.txt
ansible --version                    # ansible-core 2.19.x from the venv
```

Why a venv: Kubespray pins exact Ansible versions, and Ubuntu 24.04 forbids `pip install`
into the system Python (`externally-managed-environment`).

## 3. Inventory

Start from Kubespray's sample and overlay this repository's files:

```bash
cd ~/kubespray
cp -rfp inventory/sample inventory/mycluster
# copy from this repo: kubespray/inventory/mycluster/* -> ~/kubespray/inventory/mycluster/
#   inventory.ini
#   host_vars/worker-2.yml
#   group_vars/k8s_cluster/zz-lab.yml   <- set the master PUBLIC IP here first!
```

| Group | Members |
|---|---|
| `kube_control_plane` | master-1 |
| `etcd` | master-1 (stacked etcd) |
| `kube_node` | worker-1, worker-2 |

`zz-lab.yml` switches Calico to **VXLAN** (Azure drops IP-in-IP), adds the master's
public IP to the API certificate, saves an admin kubeconfig, enables Helm,
metrics-server and the local-path provisioner.

Test connectivity (the `ping` module is SSH + Python, not ICMP):

```bash
ansible -i inventory/mycluster/inventory.ini all -m ping
```

## 4. Deploy (inside tmux)

```bash
tmux new -s kubespray        # Ctrl+b d = detach, tmux attach -t kubespray = return
cd ~/kubespray && source ~/kubespray-venv/bin/activate
ansible-playbook -i inventory/mycluster/inventory.ini -b cluster.yml 2>&1 | tee ~/kubespray-install.log
```

First run took **~8 minutes**. Success = `failed=0` and `unreachable=0` for every host
in PLAY RECAP. `ignored=N` is fine (expected checks). Re-running is idempotent —
change variables and run again to reconfigure the cluster.

## 5. kubectl

On master-1 (Kubespray ran as root, so copy the artifact kubeconfig for your user):

```bash
mkdir -p ~/.kube
cp ~/kubespray/inventory/mycluster/artifacts/admin.conf ~/.kube/config
chmod 600 ~/.kube/config
kubectl get nodes -o wide
kubectl get pods -A
kubectl top nodes
```

On your PC (Windows):

```powershell
winget install -e --id Kubernetes.kubectl
```

On master-1 create a copy that points to the public IP, download it via MobaXterm's
SFTP panel and save it as `%USERPROFILE%\.kube\config` (a file, **not** a folder):

```bash
sed 's#https://10.10.1.10:6443#https://<MASTER_PUBLIC_IP>:6443#' ~/.kube/config > ~/admin-external.conf
```

Then delete `~/admin-external.conf` on the master. It's a full cluster-admin credential —
never commit, upload or share it.

> Symptom to remember: `kubectl` trying `localhost:8080` = the kubeconfig is empty or missing.

## What you get

- Kubernetes v1.36, containerd, Calico (VXLAN), CoreDNS + nodelocaldns, metrics-server, Helm
- Taints: control plane `NoSchedule`; worker-2 `lifecycle=spot:PreferNoSchedule`
- On workers, a static pod `nginx-proxy` — a local load balancer to the API server
