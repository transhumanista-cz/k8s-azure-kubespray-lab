# 04 — Storage: local-path (block) + NFS (shared)

Business apps need two kinds of storage:

| Need | Access mode | Here | Cloud equivalent |
|---|---|---|---|
| Database: own fast disk, one pod | ReadWriteOnce (RWO) | `local-path` provisioner | Azure Disk, EBS |
| Shared files for many replicas on different nodes | ReadWriteMany (RWX) | NFS server on master-1 | Azure Files, EFS |

## 1. local-path StorageClass

Enabled by `local_path_provisioner_enabled: true` in `zz-lab.yml` (re-run `cluster.yml`
if you add it later — Kubespray is idempotent).

```bash
kubectl get storageclass
# local-path (default)  rancher.io/local-path  Delete  WaitForFirstConsumer
```

- `(default)` — used when a PVC doesn't name a class.
- `WaitForFirstConsumer` — the disk is created on the node where the pod lands.
- `Delete` — **deleting the PVC deletes the data**. Production DBs usually use `Retain`.
- Limitation: the data lives on one node (`/opt/local-path-provisioner/`). If that node
  dies, the pod can't move. Pin such workloads to a reliable node.

## 2. NFS server (master-1)

```bash
sudo apt update && sudo apt install -y nfs-kernel-server
sudo mkdir -p /srv/nfs/odoo
sudo chown nobody:nogroup /srv/nfs/odoo
sudo mkdir -p /etc/exports.d            # not created by default on Ubuntu
echo "/srv/nfs/odoo 10.10.1.0/24(rw,sync,no_subtree_check,all_squash)" | sudo tee /etc/exports.d/odoo.exports
sudo exportfs -ra
sudo exportfs -v
```

- `10.10.1.0/24` — only cluster nodes (mounts are done by the kubelet with the node IP).
- `sync` — acknowledge writes only after they hit the disk.
- `all_squash` — every client user becomes `nobody` on the server, so container UIDs don't matter.
- The file name must end in `.exports`.

## 3. NFS client on workers (Ansible ad-hoc)

```bash
cd ~/kubespray && source ~/kubespray-venv/bin/activate
ansible -i inventory/mycluster/inventory.ini kube_node -b -m apt \
  -a "name=nfs-common state=present update_cache=true"

# test: each worker mounts the share and writes a file (single quotes: $(hostname) runs remotely)
ansible -i inventory/mycluster/inventory.ini kube_node -b -m shell \
  -a 'mount -t nfs 10.10.1.10:/srv/nfs/odoo /mnt && touch /mnt/test-$(hostname) && umount /mnt'
ls -l /srv/nfs/odoo        # test-worker-1, test-worker-2 owned by nobody:nogroup
sudo rm /srv/nfs/odoo/test-*
```

## PV vs PVC

- **PersistentVolume** — the actual storage ("it's here"), cluster-scoped.
- **PersistentVolumeClaim** — an app's request ("I need 10 Gi RWX"), namespaced.
- **Dynamic** provisioning: a StorageClass creates PVs on demand (local-path).
- **Static** provisioning: you create the PV yourself (the NFS PV in `apps/odoo/20-filestore-nfs.yaml`,
  with `storageClassName: ""` so the default class is not used).
