# Homelab

A small, recoverable Kubernetes homelab running a Docker-backed vCluster on a single host.

The project is designed around a disposable Kubernetes control plane:

- vCluster can be recreated.
- Workload data must survive cluster recreation.
- Flux is the intended source of truth for Kubernetes resources.
- The Tailscale Kubernetes Operator is the only workload exposure mechanism.

## Architecture

```text
Physical disk
    ↓
Host filesystem mounted at /srv/cluster-data
    ↓
Host NFS service
    ↓
NFS CSI driver inside vCluster
    ↓
PersistentVolumes and PersistentVolumeClaims
    ↓
Flux-managed workloads
    ↓
Tailscale-managed Kubernetes Ingress
```

The vCluster is named `hub` and runs a Docker worker named `hub1`.

## Why workload data is separate

The vCluster control plane is infrastructure. It should be possible to delete and recreate it without losing application data.

Workloads are recreated from Kubernetes manifests and GitOps configuration. Their persistent data is stored outside the vCluster runtime and exposed through Kubernetes storage.

Recovery therefore has two separate responsibilities:

1. Recreate the Kubernetes platform.
2. Reattach the existing workload data.

The application data is the important part to preserve—not the internal state of the disposable vCluster.

## Why NFS was chosen

The first storage design used a host iSCSI target and attempted to connect to it from the Docker-backed vCluster worker.

The host-side iSCSI target worked correctly: the physical disk was formatted with ext4, `tgtd` exported it as an iSCSI LUN, and the host initiator could discover, attach, mount, write, unmount, and remount the LUN.

However, the Docker-backed vCluster worker could not reliably run the iSCSI initiator. iSCSI depends on host kernel, netlink, daemon, and IPC integration that is difficult to reproduce inside a private Docker worker network.

NFS was chosen because:

- The NFS CSI driver is a mature Kubernetes integration.
- It works through normal network storage semantics.
- It does not require running `iscsid` inside the vCluster worker.
- It keeps the storage service outside the disposable cluster.
- It supports static recovery-oriented volumes.

The tradeoff is that NFS provides file storage rather than block storage. Forgejo's SQLite behavior must therefore be validated carefully.

## Workload storage

### Forgejo

Forgejo is the primary persistent workload. Its `/data` directory contains Forgejo repositories, configuration, and database data.

The intended storage path is:

```text
/srv/cluster-data/forgejo
```

That directory is exported by the host NFS service and consumed by the vCluster through the NFS CSI driver. A retained static volume is used so that deleting and recreating Kubernetes objects does not delete the data directory.

### Excalidraw

Excalidraw is treated as stateless at the Kubernetes layer. It does not define a PersistentVolumeClaim or persistent volume mount, so the deployment can be recreated from its manifests.

### Immich

Immich was removed because it was not being used. Its storage and application manifests are no longer part of the active application graph.

## GitOps direction

Flux is the intended GitOps controller for the cluster:

```text
Git repository
    ↓
Flux
    ↓
CSI, storage resources, workloads, and services
```

Argo CD is not part of the required architecture. Existing Argo configuration is historical and will be removed or replaced as the Flux migration progresses.

## Workload exposure

Workloads are exposed only through the Tailscale Kubernetes Operator.

The application manifests use Tailscale-managed Kubernetes `Ingress` resources, for example:

```yaml
ingressClassName: tailscale
```

The project does not require Gateway API, Traefik, public LoadBalancer services, or NodePort exposure. Application access remains private to the Tailscale network.

## Namespace policy

Application workloads use the `default` namespace unless there is a concrete reason to isolate them.

System components retain their own namespaces:

- `flux-system` for Flux.
- `kube-system` for Kubernetes system components and the NFS CSI driver.
- Other dedicated namespaces only when required by a component.

## Recovery story

The intended replacement-host recovery sequence is:

```text
Attach the physical disk
    ↓
Mount it at /srv/cluster-data
    ↓
Start the host NFS service
    ↓
Create a fresh vCluster named hub
    ↓
Install the NFS CSI driver
    ↓
Bootstrap Flux
    ↓
Recreate PV and PVC definitions
    ↓
Recreate workloads
    ↓
Reattach Forgejo data
    ↓
Expose healthy services through Tailscale
```

The vCluster may be recreated. The Forgejo data directory must remain intact throughout the process.

## Design principles

- Keep the Kubernetes control plane disposable.
- Preserve workload data independently.
- Prefer simple infrastructure over nested daemon integration.
- Make storage ownership explicit.
- Keep application manifests small and recoverable.
- Use Flux as the single GitOps authority.
- Expose workloads only through Tailscale.
- Avoid adding components without a concrete operational benefit.

## Current status

Validated manually:

- The physical disk can be formatted and mounted as ext4.
- The host can export storage through NFS.
- The Docker-backed vCluster worker can mount the NFS export.
- The NFS CSI driver can bind a static PersistentVolume and PersistentVolumeClaim.
- A workload running as UID 1000 can write to the Forgejo data directory.
- Immich has been removed from the active application graph.
- Forgejo and Excalidraw use the default namespace.

Remaining work includes making host NFS setup, CSI installation, network addressing, Flux bootstrap, and final Forgejo validation reproducible from the repository.
