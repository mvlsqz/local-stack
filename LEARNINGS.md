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

## Tailscale MagicDNS Does Not Resolve Service Subdomains Automatically

**Date:** 2026-07-31
**Context:** All Kubernetes services are running, but `curl -I http://git.hub01.quetzal-quillback.ts.net` fails with `Could not resolve host`.

### Symptom

- All pods are Running, all Ingresses exist, and all Argo CD / Flux resources are synced.
- `curl` against `http://git.hub01.quetzal-quillback.ts.net`, `http://draw.hub01.quetzal-quillback.ts.net`, and `http://photos.hub01.quetzal-quillback.ts.net` returns `Could not resolve host`.

### Root Cause

Tailscale MagicDNS creates a DNS record for the machine itself (e.g., `hub01.quetzal-quillback.ts.net`), but it does not automatically create subdomains for individual services running inside the vCluster. The Kubernetes Ingresses use host-based routing, but those hostnames are not known to Tailscale DNS.

### Workaround: Test from the Cluster Without Tailscale DNS

From `hub01`, test the services using the Traefik service IP and the correct `Host` header:

```bash
vcluster connect hub01
TRAEFIK_IP=$(kubectl get svc -n traefik -o jsonpath='{.items[0].spec.clusterIP}')

curl -I -H "Host: git.hub01.quetzal-quillback.ts.net" http://$TRAEFIK_IP
curl -I -H "Host: draw.hub01.quetzal-quillback.ts.net" http://$TRAEFIK_IP
curl -I -H "Host: photos.hub01.quetzal-quillback.ts.net" http://$TRAEFIK_IP
```

### Options for Remote Access

#### Option 1: Tailscale Kubernetes Operator (recommended)

Install the operator inside the vCluster and expose each service with a Kubernetes `Ingress` that uses `ingressClassName: tailscale`. The operator automatically creates a Tailscale device and MagicDNS name for each Ingress, and provisions a TLS certificate.

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: forgejo
  namespace: forgejo
spec:
  ingressClassName: tailscale
  tls:
    - hosts:
        - git.hub01
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: forgejo
                port:
                  number: 3000
```

The operator exposes the service at `https://git.hub01.quetzal-quillback.ts.net`.

Install the operator:

```bash
# 1. Create tags and OAuth client in the Tailscale admin console
# 2. Download the manifest
curl -L -o operator.yaml https://raw.githubusercontent.com/tailscale/tailscale/main/cmd/k8s-operator/deploy/manifests/operator.yaml

# 3. Edit the manifest with OAuth client_id and client_secret
# 4. Apply
kubectl apply -f operator.yaml
```

#### Option 2: Tailscale Serve (simple, private to tailnet)

Expose the Traefik port on `hub01` under the machine's Tailscale name:

```bash
sudo tailscale serve --bg --set-path=/ http://localhost:80
```

Then access services by passing the Ingress `Host` header:

```bash
curl -I -H "Host: git.hub01.quetzal-quillback.ts.net" https://hub01.quetzal-quillback.ts.net
```

#### Option 3: Tailscale Funnel (public internet, Tailscale-authenticated)

```bash
sudo tailscale funnel --bg --set-path=/ http://localhost:80
```

#### Option 4: Custom DNS with Subdomains

If you want the exact `git.hub01...` subdomains without the operator, you need to manage DNS records yourself (e.g., via a public DNS provider or a custom DNS server). This is more complex and usually not needed for a homelab.

### Takeaway

- Tailscale MagicDNS only resolves the machine name, not arbitrary subdomains for services inside the cluster.
- The Tailscale Kubernetes Operator is the cleanest way to expose services with per-service MagicDNS names and TLS certificates.
- For testing, use the Traefik cluster IP with the correct `Host` header.

### References

- [Tailscale Kubernetes Operator](https://tailscale.com/docs/kubernetes-operator)
- [Tailscale Serve](https://tailscale.com/kb/1242/tailscale-serve)
- [Tailscale Funnel](https://tailscale.com/kb/1223/tailscale-funnel)
- [Tailscale MagicDNS](https://tailscale.com/kb/1081/magicdns)

---

## Immich Requires `pgvector` Extension

**Date:** 2026-07-31
**Context:** Immich pod was in `CrashLoopBackOff` and the Tailscale proxy for `photos` returned HTTP 502.

### Symptom

- `kubectl get pods -n immich` showed `immich-server` in `CrashLoopBackOff` with `2/3` ready.
- Immich server logs showed:
  ```
  Error: No vector extension found. Available extensions: vchord, vector
  microservices worker error: Error: No vector extension found. Available extensions: vchord, vector
  ```
- `curl -I https://photos.quetzal-quillback.ts.net` returned `502 Bad Gateway`.

### Root Cause

Immich uses a PostgreSQL vector extension for face and object recognition. The deployment was using `tensorchord/pgvecto-rs:pg14-v0.2.0`, which provides the `vchord`/`pgvecto-rs` extension. Immich v3.1.0 could not detect a compatible vector extension in this image and failed to start the microservices worker.

### Fix

Switch the Postgres container to the official `pgvector` image, which provides the `vector` extension that Immich expects.

```yaml
- name: immich-postgres
  image: docker.io/pgvector/pgvector:pg14
  env:
    - name: POSTGRES_USER
      value: immich
    - name: POSTGRES_PASSWORD
      value: immich
    - name: POSTGRES_DB
      value: immich
  volumeMounts:
    - name: postgres
      mountPath: /var/lib/postgresql/data
```

Because the existing Postgres data directory was initialized by the old `pgvecto-rs` image, it is not compatible with the new `pgvector` image. Delete the `immich-postgres` PVC so it is recreated and reinitialized:

```bash
kubectl scale deployment immich-server --replicas=0 -n immich
kubectl delete pvc immich-postgres -n immich
flux reconcile kustomization apps --with-source
kubectl scale deployment immich-server --replicas=1 -n immich
```

### Verification

```bash
kubectl get pods -n immich
kubectl logs -n immich deployment/immich-server -c immich-server
kubectl logs -n immich deployment/immich-server -c immich-postgres
```

The Immich server should start without the `No vector extension found` error, and the `curl` to `https://photos.quetzal-quillback.ts.net` should return HTTP 200.

### Follow-up: Reverse Geocoding Causes Microservices Worker Crash

After fixing the Postgres extension, the Immich UI came up but the microservices worker crashed during admin account creation with:

```
[Nest] 7  - 08/01/2026, 1:25:16 AM   ERROR [Microservices:MetadataService] Unable to initialize reverse geocoding: AggregateError
AggregateError [ECONNREFUSED]:
    at internalConnectMultiple (node:net:1142:49)
    at afterConnectMultiple (node:net:1723:7)
Error: Metadata service init failed
```

Immich's microservices worker initializes the reverse geocoding service at startup. In this single-container deployment, the worker tries to connect to the API server before it is fully ready, or the service needs network access that is not available in this environment. The result is a `ECONNREFUSED` error and the microservices worker exits, which kills the whole container.

### Fix

Disable reverse geocoding by adding an environment variable to the `immich-server` container:

```yaml
- name: immich-server
  image: ghcr.io/immich-app/immich-server:release
  env:
    - name: IMMICH_MACHINE_LEARNING_ENABLED
      value: "false"
    - name: IMMICH_TELEMETRY_INCLUDE_SENSITIVE
      value: "false"
    - name: REVERSE_GEOCODING_ENABLED
      value: "false"
    # ... remaining env vars
```

Then restart the deployment:

```bash
kubectl rollout restart deployment/immich-server -n immich
kubectl rollout status deployment/immich-server -n immich
```

### Verification

```bash
kubectl logs -n immich deployment/immich-server -c immich-server
```

The microservices worker should start without the `Metadata service init failed` error, and the Immich web UI should allow creating the admin account.

### Takeaway

- Immich requires a PostgreSQL vector extension. The `pgvector/pgvector` image is the most compatible choice.
- When switching Postgres images, the data directory must be reinitialized. In a fresh setup, deleting the PVC is the simplest fix.
- Disabling reverse geocoding (`REVERSE_GEOCODING_ENABLED=false`) avoids a microservices worker startup race/network issue in single-container deployments.
- For a production setup, run the API server and microservices worker as separate containers with proper resource allocation and network access.
- Pin the Immich image tag to a specific version (e.g., `v1.131.3`) instead of `release` to avoid unexpected version changes.

### References

- [Immich PostgreSQL Requirements](https://immich.app/docs/install/requirements#postgresql)
- [pgvector Docker Image](https://github.com/pgvector/pgvector#docker)
- [Immich Environment Variables](https://immich.app/docs/install/environment-variables)

---

### References

- [Kubernetes StorageClasses](https://kubernetes.io/docs/concepts/storage/storage-classes/)
- [Argo CD Hard Refresh](https://argo-cd.readthedocs.io/en/stable/user-guide/commands/argocd_app/#hard-refresh)
- [Kubernetes Network Plugin Requirements](https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/network-plugins/#network-plugin-requirements)
- [Flannel Troubleshooting](https://github.com/flannel-io/flannel/blob/master/Documentation/troubleshooting.md)
