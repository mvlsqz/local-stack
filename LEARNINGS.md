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

## Local-Path-Provisioner Requires `DEFAULT_PATH_FOR_NON_LISTED_NODES`

**Date:** 2026-07-31
**Context:** Apps (Forgejo, Immich) and vCluster Platform pods were stuck in `Pending` because their PVCs could not be provisioned.

### Symptom

- Pods showed `FailedScheduling` with:
  ```
  running PreBind plugin "VolumeBinding": binding volumes: context deadline exceeded
  ```
- `local-path-provisioner` logs showed:
  ```
  failed to provision volume with StorageClass "local-path": config doesn't contain node hub01,
  and no DEFAULT_PATH_FOR_NON_LISTED_NODES available
  ```
- `kubectl get pvc -A` showed all PVCs in `Pending` state.

### Root Cause

The `local-path-provisioner` ConfigMap used `DEFAULT_PATH_FOR_ALL_LISTED_NODES` as the node key. This key only applies to nodes that are explicitly listed in the `nodePathMap`. Since no nodes were explicitly listed, the provisioner could not find a path for any node, including `hub01` and `home-lab01`.

The correct key for a catch-all path is `DEFAULT_PATH_FOR_NON_LISTED_NODES`.

### Fix

Change the `nodePathMap` entry in the ConfigMap:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-path-config
  namespace: local-path-storage
data:
  config.json: |
    {
      "nodePathMap": [
        {
          "node": "DEFAULT_PATH_FOR_NON_LISTED_NODES",
          "paths": ["/data/k8s-volumes"]
        }
      ]
    }
```

The path must also be on a directory that is mounted from the host into the vCluster. The vCluster Docker driver only mounts `/data/vcluster` by default, so the local-path-provisioner should use `/data/vcluster/k8s-volumes` instead of `/data/k8s-volumes`. Otherwise, the helper pods write to the vCluster container's overlay filesystem, which is not persistent and can cause timeouts.

Also, the provisioner needs `pods/log` permission to read helper pod logs.

### Fix

Change the `nodePathMap` entry in the ConfigMap, and add the required `setup` and `teardown` scripts and a proper `helperPod.yaml` template:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-path-config
  namespace: local-path-storage
data:
  config.json: |
    {
      "nodePathMap": [
        {
          "node": "DEFAULT_PATH_FOR_NON_LISTED_NODES",
          "paths": ["/data/vcluster/k8s-volumes"]
        }
      ]
    }
  setup: |
    #!/bin/sh
    set -eu
    mkdir -m 0777 -p "$VOL_DIR"
  teardown: |
    #!/bin/sh
    set -eu
    rm -rf "$VOL_DIR"
  helperPod.yaml: |
    apiVersion: v1
    kind: Pod
    metadata:
      name: helper-pod
    spec:
      priorityClassName: system-node-critical
      tolerations:
        - key: node.kubernetes.io/disk-pressure
          operator: Exists
          effect: NoSchedule
      containers:
        - name: helper-pod
          image: busybox
          imagePullPolicy: IfNotPresent
```

The `setup` and `teardown` scripts are mounted into the helper pod at `/script/setup` and `/script/teardown`. Without them, the helper pod fails with:
```
MountVolume.SetUp failed for volume "script": configmap references non-existent config key: setup
```

The local-path-provisioner Deployment only needs to mount the ConfigMap, not the host directory. The host directory is mounted by the helper pods that the provisioner creates.

Update the RBAC to allow reading helper pod logs:

```yaml
rules:
  - apiGroups: [""]
    resources: ["endpoints", "persistentvolumes", "pods", "pods/log"]
    verbs: ["*"]
```

After updating the manifests, restart the provisioner and delete the old PVCs so they are re-provisioned:

```bash
kubectl rollout restart deployment/local-path-provisioner -n local-path-storage
kubectl delete pvc --all -n forgejo
kubectl delete pvc --all -n immich
kubectl delete pvc --all -n vcluster-platform
```

### Verification

```bash
kubectl get pvc -A
kubectl get pv
kubectl logs -n local-path-storage deployment/local-path-provisioner
ls -la /data/vcluster/k8s-volumes
```

PVCs should move from `Pending` to `Bound`, and PVs should be created under `/data/vcluster/k8s-volumes` on the host.

### Takeaway

- Use `DEFAULT_PATH_FOR_NON_LISTED_NODES` when you want a single path for all nodes that are not explicitly named in the `nodePathMap`.
- Use `DEFAULT_PATH_FOR_ALL_LISTED_NODES` only when you have explicit node entries and want them to share the same path.
- The local-path-provisioner error message is explicit: read the key it asks for and update the ConfigMap accordingly.
- In a vCluster Docker setup, ensure the local-path base directory is mounted from the host. Otherwise, data is not persistent and helper pods may time out.
- The local-path-provisioner ConfigMap must include `setup` and `teardown` scripts. The helper pod mounts them as a `script` volume.
- The local-path-provisioner service account needs `pods/log` access to read helper pod logs.

### References

- [local-path-provisioner Configuration](https://github.com/rancher/local-path-provisioner#configuration)
- [vCluster Docker Driver Volumes](https://www.vcluster.com/docs/vcluster/deploy/topology/single-node-hybrid/docker)

---

### References

- [Kubernetes StorageClasses](https://kubernetes.io/docs/concepts/storage/storage-classes/)
- [Argo CD Hard Refresh](https://argo-cd.readthedocs.io/en/stable/user-guide/commands/argocd_app/#hard-refresh)
- [Kubernetes Network Plugin Requirements](https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/network-plugins/#network-plugin-requirements)
- [Flannel Troubleshooting](https://github.com/flannel-io/flannel/blob/master/Documentation/troubleshooting.md)
