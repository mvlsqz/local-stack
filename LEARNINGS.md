# LEARNINGS

## br_netfilter / bridge-nf-call-iptables Required for CNI on Arch-Based Hosts

**Date:** 2026-07-30
**Context:** Provisioning a vCluster with Docker driver on `hub01` (Arch-based laptop). Argo CD installation was blocked because the CNI (Flannel) pods were not starting.

### Symptom

- `kube-flannel` pods were crash-looping or stuck in `ContainerCreating`.
- `kubectl get nodes` showed `hub01` as `NotReady`.
- Argo CD could not be installed because the cluster network was not functional.

### Root Cause

The Linux kernel module `br_netfilter` was not loaded on the host. This module enables `bridge-nf-call-iptables`, which is required for Kubernetes CNI plugins such as Flannel to apply iptables rules to traffic flowing between pods.

On most distributions, this module is loaded automatically or by the kubelet / CNI installer. On Arch Linux, it is often not loaded by default.

### Why It Breaks the Cluster

Kubernetes pod-to-pod traffic on a single node traverses Linux bridges (e.g., `cni0`, `flannel.1`). The CNI needs iptables rules to:

1. Apply Kubernetes `NetworkPolicy` semantics.
2. Perform source/destination NAT for traffic between pods and external networks.
3. Route overlay traffic (in Flannel's VXLAN backend) correctly.

Without `br_netfilter`, iptables rules are not evaluated on bridge traffic, so Flannel cannot set up pod networking. The result is:

- Flannel pods fail health checks.
- CoreDNS pods cannot reach the API server.
- The node is marked `NotReady`.
- Any workload that depends on networking (e.g., Argo CD) fails to deploy.

### Fix on hub01

Load the module immediately:

```bash
sudo modprobe br_netfilter
sudo sysctl -w net.bridge.bridge-nf-call-iptables=1
sudo sysctl -w net.bridge.bridge-nf-call-ip6tables=1
```

Persist it across reboots:

```bash
cat <<EOF | sudo tee /etc/modules-load.d/br_netfilter.conf
br_netfilter
EOF

cat <<EOF | sudo tee /etc/sysctl.d/99-k8s-cni.conf
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

sudo sysctl --system
```

### Verification

```bash
lsmod | grep br_netfilter
sysctl net.bridge.bridge-nf-call-iptables
sysctl net.bridge.bridge-nf-call-ip6tables
kubectl get nodes
kubectl get pods -n kube-flannel
```

After applying the fix, the node should become `Ready` and Flannel pods should start successfully.

### Takeaway

On Arch-based hosts, always load `br_netfilter` and enable `bridge-nf-call-iptables` before running a Kubernetes cluster or vCluster with a CNI that relies on iptables.

## StorageClass `reclaimPolicy` Is Immutable

**Date:** 2026-07-31
**Context:** After fixing the local-path-provisioner ConfigMap, Argo CD stayed `OutOfSync` on the platform app because it could not reconcile the `local-path` StorageClass.

### Symptom

- `local-path-provisioner` application in Argo CD showed `OutOfSync` but `Healthy`.
- Argo CD events reported:
  ```
  StorageClass.storage.k8s.io "local-path" is invalid: reclaimPolicy: Forbidden: updates to reclaimPolicy are forbidden.
  ```
- After deleting the StorageClass, Argo CD recreated it with `reclaimPolicy: Delete` even though the Git manifest specified `Retain`.

### Root Cause

1. `reclaimPolicy` is an immutable field on `StorageClass` objects. Once a StorageClass is created, Kubernetes rejects any patch that tries to change it.
2. The live StorageClass had `reclaimPolicy: Delete`, likely created by the local-path-provisioner defaults or an earlier sync.
3. Argo CD's repo-server cached a stale generated manifest. After deleting the StorageClass, Argo CD recreated it from the cache instead of the latest Git commit, so it came back as `Delete`.

### Fix

Delete the StorageClass and force Argo CD to do a hard refresh before it recreates the resource:

```bash
vcluster connect hub01

# Delete the stale StorageClass
kubectl delete storageclass local-path

# Force a hard refresh of the Argo CD app
kubectl annotate application -n argocd local-path-provisioner argocd.argoproj.io/refresh=hard

# Clear Argo CD's manifest cache
kubectl delete pod -n argocd -l app.kubernetes.io/name=argocd-repo-server
kubectl delete pod -n argocd -l app.kubernetes.io/name=argocd-application-controller
```

Then verify:

```bash
kubectl get storageclass local-path -o yaml | grep reclaimPolicy
kubectl get applications -n argocd
```

### If It Still Recreates with the Wrong Policy

Apply the manifest manually after deleting the bad StorageClass:

```bash
kubectl delete storageclass local-path
kubectl apply -f ~/local-stack/platform/local-path-provisioner/storage-class.yaml
```

### Takeaway

- `StorageClass.reclaimPolicy` is immutable. To change it, you must delete and recreate the StorageClass.
- When a GitOps tool recreates a resource with the wrong state, clear the repo-server cache and force a hard refresh rather than repeatedly deleting the live object.
- Deleting a StorageClass does **not** delete existing PVs or PVCs — it only removes the provisioning template.

### References

- [Kubernetes StorageClasses](https://kubernetes.io/docs/concepts/storage/storage-classes/)
- [Argo CD Hard Refresh](https://argo-cd.readthedocs.io/en/stable/user-guide/commands/argocd_app/#hard-refresh)

---

### References

- [Kubernetes Network Plugin Requirements](https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/network-plugins/#network-plugin-requirements)
- [Flannel Troubleshooting](https://github.com/flannel-io/flannel/blob/master/Documentation/troubleshooting.md)
