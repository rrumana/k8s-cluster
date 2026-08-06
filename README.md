# k8s-cluster

A live, six-node bare-metal Kubernetes homelab run with GitOps and real workloads for family and friends.


> This is a production-adjacent cluster. Kubernetes changes belong in Git and are reconciled by Argo CD; direct `kubectl apply`, `edit`, `patch`, `delete`, `scale`, and `rollout` operations are not part of the normal operating model.

## Cluster At A Glance

- Kubernetes `v1.36.2`, bootstrapped with kubeadm and running on containerd
- Three control/compute nodes and three tainted storage/IO nodes
- Kube-proxy-free Cilium datapath with native routing and Hubble
- HA API endpoint provided by kube-vip at `192.168.1.11`
- Argo CD root application with automated pruning and self-healing
- Rook/Ceph with 12 NVMe OSDs and approximately `36 TB` raw capacity
- HAProxy Ingress behind MetalLB, with explicit public/private exposure policy
- Authentik-backed identity, Vault-backed runtime secrets, and Harbor-backed
  runtime artifacts
- Five three-instance CloudNativePG clusters plus shared Valkey cache and queue
- Prometheus/Grafana metrics and Fluent Bit/Data Prepper/OpenSearch logs

### Nodes

| Node | Plane | Internal IP | OS |
|---|---|---:|---|
| `melchior-1` | control/compute | `192.168.1.13` | Arch Linux |
| `balthasar-2` | control/compute | `192.168.1.14` | Arch Linux |
| `casper-3` | control/compute | `192.168.1.15` | Arch Linux |
| `eva-1` | storage/IO | `192.168.1.16` | NixOS |
| `eva-2` | storage/IO | `192.168.1.17` | NixOS |
| `eva-3` | storage/IO | `192.168.1.18` | NixOS |


### Hardware And Placement Model

| Plane | Hardware per node | Primary responsibility |
|---|---|---|
| control/compute | Ryzen 9 AI HX 370, Radeon 890M, 96 GiB physical RAM with an intended 48 GiB system / 48 GiB GPU split, 2.5 Gb LAN | Kubernetes control plane, ordinary application compute, AI inference, and low-IO services |
| storage/IO | Ryzen 7 7745HX, Radeon 610-class iGPU, 64 GiB RAM, four dedicated NVMe OSDs, 10 Gb LAN | Ceph, storage gateways, PostgreSQL, and selected high-throughput storage-adjacent workloads |

The `eva-*` nodes carry
`homelab.rcrumana.xyz/storage=true:NoSchedule`. Workloads default to the
control/compute plane and need an explicit storage affinity and toleration to land on the storage plane.

## Architecture

```text
Git push
   |
   v
Argo CD root app (prune + self-heal)
   |----------------------|----------------------|
   v                      v                      v
Platform foundation    Shared data services    Workload apps
CNI, ingress, TLS,     CNPG, Valkey, Ceph      identity, AI, media,
mesh, secrets,         and snapshots           productivity, web
observability, Harbor

API clients -> k8s-api.lab.home -> kube-vip 192.168.1.11 -> API servers

Internet -> OPNsense 80/443 ----\
LAN / Headscale -----------------+-> MetalLB 192.168.1.230 -> HAProxy Ingress
                                     -> public direct / Cloudflare edge
                                     -> private LAN / Headscale edge
                                     -> Authentik or application auth
                                     -> Services -> CNPG / Valkey / Ceph
```

The API VIP and service VIPs are deliberately separate: kube-vip handles only
the control-plane endpoint, while MetalLB handles Kubernetes
`LoadBalancer` services.

## Operating Posture

### GitOps And Bootstrap Boundary

Argo CD manages the platform and workloads through the root application in
`cluster/bootstrap/root-application`. The root fans out into the
`Application` definitions under `cluster/platform/gitops/argocd`.

The following remain deliberate bootstrap or external responsibilities:

- node operating systems, firmware, disks, networking, and kubeadm lifecycle
- kube-vip static pod installation on each control-plane node
- initial Cilium and Argo CD installation
- Vault initialization, unseal material, and recovery
- OPNsense WAN policy, split DNS, and Cloudflare DNS
- physical storage/network work and emergency recovery procedures

Routine cluster changes should be committed to this repository and allowed to
flow through Argo CD. Bootstrap exceptions should still be represented here
where practical, then applied deliberately using the relevant runbook.

### Exposure And Identity

HAProxy has two ingress classes:

- `haproxy` is the public class. Every public Ingress declares whether its edge
  is `direct` or `cloudflare` and carries an explicit public-approval label.
- `haproxy-restricted` is the private class. Private Ingresses use the
  canonical RFC1918 plus Headscale `100.64.0.0/10` source allowlist.

Cloudflare-proxied origins accept only Cloudflare and private-network sources.
Direct public services retain client source addresses for native clients,
large uploads, and access policy. The documented perimeter exposes only TCP
80/443 to the HAProxy VIP; it does not expose the Kubernetes API, nodes,
storage services, Harbor, or the other MetalLB VIPs to WAN.

A Kubernetes `ValidatingAdmissionPolicy` checks the ingress contract, explicit
TLS secrets, approved namespaces, and non-wildcard `rcrumana.xyz` hosts.

Authentik is the invitation-only identity plane. Its declarative flows are
passkey-first, with progressively weaker enrolled recovery methods and an
offline break-glass administrator. OIDC integrations is an ongoing development as is forward-auth for certain legacy/unauthenticated apps. Protocol-specific backends
such as Collabora and Whiteboard trust Nextcloud-issued sessions instead of
adding a second login proxy.

Identity is intentionally not a single point of recovery. Local administrative
routes are retained where an application supports them, and Vaultwarden's
desired posture keeps its native invitation, master-password, and MFA flow
independent of Authentik.

### Secrets And Artifact Supply Chain

- Vault runs as a three-member integrated-Raft cluster on Ceph-backed storage.
- External Secrets Operator reads Vault through
  `ClusterSecretStore/vault` and materializes namespace-local Kubernetes
  Secrets. Secret values, OIDC client secrets, passkeys, recovery codes, and
  SMTP credentials do not belong in Git.
- Harbor provides private images, pull-through caches, and the OCI chart
  mirror used by GitOps-managed workloads.
- Renovate discovers updates from their true upstream sources while manifests
  continue to reference Harbor.
- The Renovate promoter copies changed images by digest, validates immutable
  content, renders mirrored charts to discover transitive images, and publishes
  the `renovate/artifacts-promoted` commit status. That status is intended to
  gate Renovate merges.
- The promoter does not execute pull-request code, has no Kubernetes service
  account token, and refuses to overwrite an existing Harbor tag with different
  content.

## Platform Foundation

| Area | Implementation | Current posture |
|---|---|---|
| API availability | kube-vip | ARP leader election on `192.168.1.11` / `k8s-api.lab.home` |
| Pod networking | Cilium + Hubble | Native routing, eBPF masquerading, kube-proxy replacement, flow visibility |
| Service VIPs | MetalLB | L2 pool `192.168.1.230-192.168.1.250` |
| HTTP ingress | HAProxy Ingress | Separate public and restricted classes with explicit exposure metadata |
| TLS | cert-manager | Let's Encrypt DNS-01 through Cloudflare; wildcard and host-specific certificates |
| Identity | Authentik | HA application tier, invitation enrollment, passkey-first login, OIDC and forward-auth |
| Service mesh | Linkerd CRDs + CNI + control plane + Viz | CNI mode, workload mTLS/policy, shared Prometheus |
| Secrets | Vault + External Secrets | Vault is secret authority; Kubernetes Secrets are runtime projections |
| Storage | Rook/Ceph | Three durability profiles across RBD and CephFS; storage plane owns all OSDs |
| Snapshots | CSI Snapshot Controller | Default `ceph-block-snap` plus CephFS snapshots |
| SQL | CloudNativePG | Five three-instance clusters on storage nodes |
| Cache / queue | Valkey | Replicated ephemeral cache and replicated AOF-backed queue |
| Metrics | kube-prometheus-stack | Persistent Prometheus, Alertmanager, Grafana, and node monitoring |
| Logs | Fluent Bit + Data Prepper + OpenSearch | Node collection into normalized daily OpenSearch indices |
| Registry / charts | Harbor | Private registry, proxy cache, and OCI mirror |
| Updates | Renovate + artifact promoter | Upstream discovery with pre-merge Harbor promotion |
| Scheduling | metrics-server + VPA + descheduler | Metrics, recommendation-mode right-sizing, and rebalancing |
| Bulk egress | `egress-qos` DaemonSet | Shapes pods labeled `traffic-tier=bulk-seed` |
| Backups | VolSync + CNPG definitions | Retained but fail-closed pending a replacement object store |

## Storage And Data Durability

The three `eva-*` nodes host four explicitly enumerated NVMe OSDs each:
approximately `12 TB` raw per node and `36 TB` raw cluster-wide. Usable
capacity depends on the selected durability profile; there is no single
"effective capacity" figure.

| StorageClass | Layout | Intended use |
|---|---|---|
| `ceph-block-critical` (default) | RBD, 3x host replication | Critical data without application-level replication |
| `ceph-block-app-replicated` | RBD, 2x host replication | CNPG, Valkey, OpenSearch, and other application-replicated data |
| `cephfs-replicated` | CephFS, 3x host replication | Critical RWX data |
| `cephfs-bulk` | CephFS, EC 2+1 | Reconstructible media, model caches, and other capacity-heavy RWX data |
| `cephfs-bulk-retain` | CephFS, EC 2+1, `Retain` reclaim policy | Bulk data whose PV lifecycle must survive claim deletion |

The CephFS metadata and replicated data pools remain 3x replicated. A
CephNFS gateway exposes a LAN endpoint for the bulk filesystem at
`192.168.1.236:2049`.

## Workloads By Domain

| Namespace/domain | Workloads |
|---|---|
| `identity` | Authentik identity provider, invitation enrollment, OIDC providers, and embedded forward-auth outpost |
| `ai` | LibreChat, MongoDB, Meilisearch, RAG API, LiteLLM gateway, and `llama.cpp` workers sharing CephFS model cache |
| `media` | qBittorrent/Servarr stack, Jellyseerr, Jellyfin, Plex, and Immich |
| `productivity` | Nextcloud, Collabora, admin and client Homepage dashboards, UniFi OS Server, Uptime Kuma, Vaultwarden, Whiteboard, and Elasticsearch |
| `other` | Headscale and UI, Hypermind, and the OPNsense service bridge |
| `web` | Production and staging portfolio deployments |

The shared data plane lives in `databases`: `pg-ai`, `pg-media`,
`pg-platform`, `pg-productivity`, `pg-other`, `valkey-cache`, and
`valkey-queue`. More detailed catalog and ingress notes are in
[docs/apps.md](docs/apps.md).

## Service Addresses

### Control And Service VIPs

| Purpose | Address |
|---|---:|
| Kubernetes API via kube-vip | `192.168.1.11:6443` |
| MetalLB allocation pool | `192.168.1.230-192.168.1.250` |

### Assigned MetalLB Services

| Service | External IP |
|---|---:|
| `ingress-haproxy/haproxy-ingress` | `192.168.1.230` |
| `media/plex` | `192.168.1.232` |
| `media/jellyfin` | `192.168.1.233` |
| `media/immich-server` | `192.168.1.234` |
| `productivity/unifi-os-server-tcp` and `unifi-os-server-udp` | `192.168.1.235` |
| `rook-ceph/ceph-nfs-bulk` | `192.168.1.236` |

These LAN addresses are not a statement of WAN exposure. Public HTTP(S)
traffic terminates through HAProxy at `192.168.1.230`.

## Repository Layout

```text
cluster/
  bootstrap/                  kubeadm, kube-vip, Cilium, Argo CD, root app
  platform/
    gitops/argocd/            Argo CD projects and child Applications
    base/                     namespaces, data, networking, security, storage
    ingress/                  HAProxy configuration and exposure policy
    observability/            monitoring and centralized logs
    registry/                 Harbor
    automation/               Renovate and artifact promotion
    scheduling/               metrics-server, VPA, descheduler
    service-mesh/             Linkerd
  apps/                       user-facing workloads grouped by domain
dependencies/                 manually tracked compatibility/version lines
docs/                         architecture, access, recovery, and audit notes
scripts/                      validation, seeding, and emergency operations
```

## Contributing

This cluster is personal and tailored to its hardware, network, users, and
failure model. Issues and discussions about idiomatic Kubernetes or safer
operations are welcome. Pull requests should avoid assuming that a generic
homelab layout can be applied safely to this live environment.
