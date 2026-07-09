# Workload Placement Plan

Current as of 2026-07-08, after the Eva storage-node migration and the
NAS-to-CephFS media migration.

This document is the placement contract for steady-state scheduling. It is not a
record of where pods happen to be today. It states where workloads should land
once placement is implemented through GitOps.

## Hardware Model

### Control/compute plane

Nodes:

- `melchior-1`
- `balthasar-2`
- `casper-3`

Hardware posture:

- Ryzen 9 AI HX370.
- Radeon 890M iGPU.
- 96 GiB RAM, with the intended split of 48 GiB system RAM and 48 GiB GPU RAM.
- 2.5 Gb cluster/LAN networking.
- No final Ceph OSD role.

Primary job:

- Kubernetes control plane.
- General application compute.
- AI inference and GPU-oriented workloads.
- Stateless and low-IO stateful services.

### Storage plane

Nodes:

- `eva-1`
- `eva-2`
- `eva-3`

Hardware posture:

- Ryzen 7 7745HX.
- Radeon 610 iGPU.
- 64 GiB RAM.
- Final Ceph OSD hosts.
- 10 Gb storage backbone target.
- Currently tainted with `homelab.rcrumana.xyz/storage=true:NoSchedule`.

Primary job:

- Ceph data path.
- Ceph management daemons that need to follow the storage quorum.
- High-throughput storage-adjacent workloads where the control-node 2.5 Gb link
  or extra Ceph network hop is a material bottleneck.

## Placement Principles

### Default To Control

The default placement for every workload is the control/compute plane.

Reasons:

- The Eva nodes should remain storage-biased and protected by a taint.
- Non-PVC workloads do not get faster by running on the storage nodes.
- Most request/response apps benefit more from CPU/GPU/RAM headroom on the
  HX370 nodes than from storage locality.
- The control nodes are the cluster's normal compute pool and should absorb
  ordinary scheduling pressure.

### Storage Nodes Need A Specific Reason

A workload should be placed on the Eva nodes only if at least one of these is
true:

- It is a Ceph daemon or storage gateway.
- It is on the storage data path and can saturate, or materially suffer from,
  the control nodes' 2.5 Gb link.
- It performs high-volume RBD/CephFS reads or writes where moving the pod to the
  storage backbone removes a meaningful hop.
- It needs to be near the CephFS media namespace for sustained streaming,
  seeding, scanning, or hardlink-heavy media workflows.

### Data Spread Beats Manual Node Pinning

For most replicated workloads, prefer a required placement pool plus hostname
spread rules over hard pinning to individual nodes.

Use hard node placement only when the workload is tied to a specific local
device or when an operator requires it. For example, OSD pods and mon local data
are node-specific; general app pods should not be.

### Non-PVC Workloads Stay Control

Non-PVC workloads stay on the control plane unless they are cluster agents that
must run everywhere or they are direct storage control/data plane components.

Examples:

- Argo CD, cert-manager, External Secrets, Linkerd control plane, web apps, and
  most API services stay on control nodes.
- Cilium, Linkerd CNI, node-exporter, Fluent Bit, and CSI node plugins run on
  all eligible nodes because they are per-node agents.

### CephFS Is For Shared POSIX Data

Cluster workloads should consume CephFS directly through CSI. NFS is for
non-cluster clients or compatibility endpoints.

The media migration showed that qBittorrent seeding can trigger large CephFS
read amplification when kernel readahead is too aggressive. Torrent workloads
therefore use the dedicated `media-library-torrent` PVC with `rasize=0`.
Sequential media consumers use the normal `media-library` PVC.

### Local Scratch Is Not Ceph

High-churn temporary data should be local:

- qBittorrent incomplete/temp data.
- Plex transcode.
- Jellyfin transcode/cache.
- Image processing scratch where the output is persisted elsewhere.

This avoids turning temporary writes into replicated cluster writes.

## Label Contract

Current storage labels:

```text
node-role.kubernetes.io/storage=
homelab.rcrumana.xyz/node-plane=storage
homelab.rcrumana.xyz/storage-tier=nvme
homelab.rcrumana.xyz/media-accel=amd-vaapi
```

Recommended explicit control label:

```text
homelab.rcrumana.xyz/node-plane=control
```

The control label should be added to `melchior-1`, `balthasar-2`, and
`casper-3` before GitOps selectors are converted away from implicit scheduling.

Storage toleration:

```yaml
tolerations:
  - key: homelab.rcrumana.xyz/storage
    operator: Equal
    value: "true"
    effect: NoSchedule
```

Only workloads listed in this document as `storage` or `all nodes` should get
that toleration.

## Target Placement Summary

| Placement | Nodes | Workload shape |
| --- | --- | --- |
| `control` | `melchior-1`, `balthasar-2`, `casper-3` | Default for apps, controllers, AI, web, service mesh control plane, security, low-IO stateful services |
| `storage` | `eva-1`, `eva-2`, `eva-3` | Ceph daemons, Ceph gateways, high-throughput media, IO-heavy database/search/registry workloads |
| `all nodes` | all six nodes | Network, CNI, CSI node plugins, logging agents, node metrics, device plugins |
| `external` | not scheduled | Services backed by external endpoints |

## Exact Workload Decisions

### Kubernetes Control Plane

| Workload | Target | Spread | Justification |
| --- | --- | --- | --- |
| `kube-apiserver-*` | control | one per control node | Static control-plane component. No storage-locality benefit. |
| `kube-controller-manager-*` | control | one per control node | Static control-plane component. No storage-locality benefit. |
| `kube-scheduler-*` | control | one per control node | Static control-plane component. No storage-locality benefit. |
| `etcd-*` | control | one per control node | Etcd should stay with the Kubernetes control plane. Moving it to Eva would couple Kubernetes availability to the storage plane without a storage throughput benefit. |
| `kube-vip-*` | control | one per control node | API VIP follows the control plane. |

### Node Agents

| Workload | Target | Spread | Justification |
| --- | --- | --- | --- |
| `kube-system/cilium` | all nodes | one per node | Required for pod networking on every schedulable node. |
| `kube-system/cilium-envoy` | all nodes | one per node | Required by Cilium data path on every node. |
| `service-mesh/linkerd-cni` | all nodes | one per node | Required before meshed pods start on any node. |
| `metallb-system/metallb-speaker` | all nodes | one per node | L2/BGP speaker role is node-local. |
| `monitoring/kube-prometheus-stack-prometheus-node-exporter` | all nodes | one per node | Node metrics must cover both control and storage nodes. |
| `search/fluent-bit` | all nodes | one per node | Log collection must cover both control and storage nodes. |
| `rook-ceph/csi-rbdplugin` | all nodes | one per node | Any node that can run an RBD-backed pod needs the node plugin. |
| `rook-ceph/csi-cephfsplugin` | all nodes | one per node | Any node that can run a CephFS-backed pod needs the node plugin. |
| `kube-system/amdgpu-device-plugin-daemonset` | all GPU-capable nodes | one per GPU-capable node | Device discovery is node-local. Scheduling policy decides which GPUs are consumed. |
| `kube-system/egress-qos` | all nodes unless narrowed later | one per node | Egress policy is node-local. Keep broad unless it becomes control-only by design. |

### Core Cluster Controllers

| Workload | Target | Spread | Justification |
| --- | --- | --- | --- |
| `kube-system/cilium-operator` | control | two replicas across different control nodes | Non-PVC control-plane service. Keep off storage nodes. |
| `kube-system/coredns` | control | two replicas across different control nodes | Latency-sensitive cluster service, but not storage-local. Control nodes are the default compute pool. |
| `kube-system/hubble-relay` | control | single replica, control preferred | Non-PVC observability service. |
| `kube-system/hubble-ui` | control | single replica, control preferred | Non-PVC UI. |
| `kube-system/metrics-server` | control | single replica, control preferred | Non-PVC API helper. |
| `kube-system/snapshot-controller` | control | two replicas across different control nodes | Storage API controller, not storage data path. No Eva placement benefit. |
| `cert-manager/cert-manager` | control | two replicas across different control nodes | Non-PVC controller. |
| `cert-manager/cert-manager-cainjector` | control | two replicas across different control nodes | Non-PVC controller. |
| `cert-manager/cert-manager-webhook` | control | two replicas across different control nodes | Non-PVC webhook. |
| `scheduling/vpa-recommender` | control | single replica, control preferred | Non-PVC controller. |
| `scheduling/descheduler` | control | scheduled job on control | Scheduling maintenance job, no storage-locality benefit. |
| `automation/renovate` | control | scheduled job on control | Non-PVC automation job. |

### GitOps

| Workload | Target | Spread | Justification |
| --- | --- | --- | --- |
| `argocd/argocd-application-controller` | control | single replica, control preferred | GitOps brain should not depend on storage nodes unless needed. EmptyDir only. |
| `argocd/argocd-applicationset-controller` | control | single replica, control preferred | Non-PVC controller. |
| `argocd/argocd-dex-server` | control | single replica, control preferred | Non-PVC auth component. |
| `argocd/argocd-notifications-controller` | control | single replica, control preferred | Non-PVC controller. |
| `argocd/argocd-redis` | control | single replica, control preferred | Cache only, no storage-locality benefit. |
| `argocd/argocd-repo-server` | control | single replica, control preferred | EmptyDir/cache-heavy but not Ceph-bound. |
| `argocd/argocd-server` | control | single replica, control preferred | API/UI component. |

### Security

| Workload | Target | Spread | Justification |
| --- | --- | --- | --- |
| `security/vault` | control | three replicas, one per control node | Critical service, but not high-throughput storage-bound. Keep it with the control plane and avoid coupling Vault availability to storage-node maintenance. |
| `security/external-secrets` | control | two replicas across different control nodes | Non-PVC controller that depends on Vault/API reachability. |
| `security/external-secrets-cert-controller` | control | single replica, control preferred | Non-PVC controller. |
| `security/external-secrets-webhook` | control | single replica, control preferred | Non-PVC webhook. |

### Service Mesh

| Workload | Target | Spread | Justification |
| --- | --- | --- | --- |
| `service-mesh/linkerd-destination` | control | three replicas across control nodes | Non-PVC control-plane service. |
| `service-mesh/linkerd-identity` | control | three replicas across control nodes | Critical service-mesh control plane; no storage-locality benefit. |
| `service-mesh/linkerd-proxy-injector` | control | three replicas across control nodes | Admission/control-plane component. |
| `service-mesh/metrics-api` | control | single replica, control preferred | Non-PVC control-plane component. |
| `service-mesh/tap` | control | single replica, control preferred | Non-PVC control-plane component. |
| `service-mesh/tap-injector` | control | single replica, control preferred | Admission/control-plane component. |
| `service-mesh/web` | control | single replica, control preferred | UI. |
| `service-mesh/linkerd-heartbeat` | control | scheduled job on control | Non-PVC scheduled telemetry job. |

### Ingress And Load Balancing

| Workload | Target | Spread | Justification |
| --- | --- | --- | --- |
| `ingress-haproxy/haproxy-ingress` | control | three replicas, one per control node | Stateless external traffic entry point. Keep storage nodes reserved for storage. If media ingress becomes bandwidth-limited, add a separate media ingress class later rather than moving all ingress. |
| `metallb-system/metallb-controller` | control | single replica, control preferred | Non-PVC controller. |
| `metallb-system/metallb-speaker` | all nodes | one per node | Per-node speaker agent. |

### Rook And Ceph

| Workload | Target | Spread | Justification |
| --- | --- | --- | --- |
| `rook-ceph/rook-ceph-mon-*` | storage | one mon per Eva | Monitor quorum should live with the dedicated Ceph hosts. Three mons across three storage nodes gives host-failure tolerance without involving control nodes. |
| `rook-ceph/rook-ceph-mgr-*` | storage | active and standby on different Evas | Manager services, dashboard, and orchestration should remain with the Ceph control plane. |
| `rook-ceph/rook-ceph-osd-*` | storage | OSDs fixed to their owning Eva | OSDs are tied to local disks. |
| `rook-ceph/rook-ceph-mds-ceph-filesystem-*` | storage | active and standby on different Evas | CephFS metadata service is storage data path. Keeping it on Eva reduces storage fabric hops for CephFS-heavy media/model use. |
| `rook-ceph/rook-ceph-nfs-ceph-nfs-bulk-*` | storage | prefer at least two instances across Evas if configured | NFS is an external storage gateway. It should be near CephFS and not contend with control-node networking. |
| `rook-ceph/rook-ceph-crashcollector-*` | storage | one per Eva | Follows Ceph daemons and local crash/log paths. |
| `rook-ceph/rook-ceph-tools` | storage | single replica, any Eva | Operational toolbox should have direct storage-plane placement. |
| `rook-ceph/rook-ceph-operator` | control | single replica, control preferred | Operator is not on the IO path. Running it on control keeps Eva reserved for Ceph daemons. It may tolerate storage taints for emergency flexibility, but should prefer control. |
| `rook-ceph/csi-rbdplugin-provisioner` | control | two replicas across control nodes | Provisioner is a controller, not node-local IO. |
| `rook-ceph/csi-cephfsplugin-provisioner` | control | two replicas across control nodes | Provisioner is a controller, not node-local IO. |

### Databases

| Workload | Target | Spread | Justification |
| --- | --- | --- | --- |
| `databases/pg-ai` | storage | three instances, one per Eva | PostgreSQL is latency and write-path sensitive. On control nodes, every RBD write crosses the 2.5 Gb link to Ceph. On Eva, the database uses the storage backbone and removes a material bottleneck. Client query traffic is usually smaller than the storage write/read path. |
| `databases/pg-media` | storage | three instances, one per Eva | Media apps are now storage-backed and database IO can be write-heavy during scans/imports. Place near Ceph. |
| `databases/pg-other` | storage | three instances, one per Eva | Same CNPG/RBD reasoning. Keep the cluster spread by host. |
| `databases/pg-platform` | storage | three instances, one per Eva | Platform DB backs shared services such as Harbor. Storage locality matters more than keeping DB pods near stateless clients. |
| `databases/pg-productivity` | storage | three instances, one per Eva | Nextcloud/productivity DB writes should avoid the 2.5 Gb control-node storage path. |
| `databases/valkey-cache-primary` | control | one primary on a control node | Cache latency to apps matters more than disk locality. Persistence is low-volume. |
| `databases/valkey-cache-replicas` | control | two replicas on other control nodes | Keep cache service near general apps and spread across control nodes. |
| `databases/valkey-queue-primary` | control | one primary on a control node | Queue operations are network/memory oriented. No observed storage throughput reason to consume Eva. |
| `databases/valkey-queue-replicas` | control | two replicas on other control nodes | Spread with the queue primary for availability. |
| `cnpg-system/cnpg-controller-manager` | control | single replica, control preferred | Operator/controller, not database data path. |

PostgreSQL primary distribution should be monitored after moving CNPG clusters.
If all primaries settle on one Eva, use controlled CNPG switchovers to distribute
write leaders. A reasonable target is:

- `pg-platform` primary on `eva-1`
- `pg-media` primary on `eva-2`
- `pg-productivity` primary on `eva-3`
- `pg-ai` and `pg-other` primaries split across the least busy Evas

Do not hard-pin individual CNPG instance ordinals unless the operator placement
model requires it.

### Harbor

| Workload | Target | Spread | Justification |
| --- | --- | --- | --- |
| `harbor/harbor-registry` | storage | single RWO pod, any Eva | Registry blob storage is large and IO-heavy. Image push/pull, GC, and layer scans benefit from avoiding the control nodes' 2.5 Gb storage path. |
| `harbor/harbor-jobservice` | storage | single RWO pod, any Eva | Jobservice performs registry maintenance and can be IO-heavy during GC/replication tasks. Place with registry storage. |
| `harbor/harbor-trivy` | storage | single stateful pod, any Eva | Trivy keeps a vulnerability DB and scans image layers. It should be close to the registry storage path. |
| `harbor/harbor-core` | control | two replicas across control nodes | API/control service. It talks to registry and DB, but is not itself storage IO bound. |
| `harbor/harbor-portal` | control | two replicas across control nodes | Static UI. No storage-locality benefit. |
| `harbor/harbor-exporter` | control | single replica, control preferred | Metrics exporter. No storage-locality benefit. |
| `harbor/harbor-redis` | control | single stateful pod, control preferred | Small internal cache/coordination service. Keep near Harbor core. |

Long-term, Harbor registry blobs may be a better RGW/object-storage fit than a
large RBD volume. Until that migration is proven, registry and jobservice should
run on Eva.

### Media

| Workload | Target | Exact preferred node | Spread | Justification |
| --- | --- | --- | --- | --- |
| `media/arr-stack` | storage | `eva-1` | separate from other qBittorrent stacks when possible | Main qBittorrent/Servarr stack is sustained network and CephFS IO. It already demonstrated storage-path sensitivity. Use `media-library-torrent` with `rasize=0`, and keep `/temp` local. |
| `media/arr-lts` | storage | `eva-2` | separate from other qBittorrent stacks when possible | Torrent seeding is the clearest Eva candidate after Ceph itself. Spread to avoid one node owning all outbound traffic and all CephFS client reads. |
| `media/arr-lts2` | storage | `eva-3` | separate from other qBittorrent stacks when possible | Same torrent/CephFS reasoning. |
| `media/plex` | storage | `eva-2` preferred | anti-affined from Jellyfin | Plex reads large media files from CephFS. Direct-play workloads benefit from storage proximity. Keep transcode on local scratch. If transcoding load proves Radeon 610 is insufficient, move Plex to a control GPU node and accept the storage hop. |
| `media/jellyfin` | storage | `eva-3` preferred | anti-affined from Plex | Same media-read reasoning as Plex. Jellyfin should use local cache/transcode and normal `media-library`, not the torrent PVC. |
| `media/immich-server` | control | spread/any control node | control preferred | Immich is compute/GPU and app-latency oriented. Its photo PVC is important but not the same high-throughput immutable media path. The HX370/890M nodes are better suited for video/photo processing. |
| `media/immich-machine-learning` | control | spread/any control node | control preferred | ML inference/cache workload. Better CPU/GPU/memory posture on the control nodes. |
| `media/media-library` PVC consumers | depends on consumer | n/a | n/a | Sequential readers use normal `media-library`; torrent seeders use `media-library-torrent`. |

The recommended first hard media spread is:

- `arr-stack` on `eva-1`
- `arr-lts` on `eva-2`
- `arr-lts2` on `eva-3`
- `plex` preferred on `eva-2`
- `jellyfin` preferred on `eva-3`

This avoids stacking all qBittorrent clients on one node and gives the two media
servers separate nodes. It is acceptable for qBittorrent plus one media server
to share an Eva because the final 10 Gb storage backbone should carry this load.
If streaming suffers during high seeding, reduce qBittorrent IO priority or move
Plex/Jellyfin to the least busy Eva.

### AI

| Workload | Target | Spread | Justification |
| --- | --- | --- | --- |
| `ai/llama-static-a` | control | one control node, anti-affined from other llama backends where possible | AI belongs on the HX370/890M nodes. Offloading Ceph has freed system memory on those nodes, which directly helps inference. |
| `ai/llama-static-b` | control | different control node from `llama-static-a` when possible | Same GPU/memory reasoning. |
| `ai/llama-swap` | control | remaining control node when possible | Same GPU/memory reasoning; model cache can stay on CephFS. |
| `ai/llm-gateway` | control | two replicas across different control nodes | Stateless gateway. No storage-locality benefit. |
| `ai/librechat` | control | single replica, control preferred | User-facing app with small PVC; not storage-throughput bound. |
| `ai/librechat-rag-api` | control | two replicas across different control nodes | Compute/API workload. No Eva benefit. |
| `ai/librechat-mongodb` | control | single stateful pod, control preferred | Singleton app database. It has PVC storage, but no evidence that storage throughput dominates. Keep near LibreChat unless it becomes IO-bound. |
| `ai/librechat-meilisearch` | control | single stateful pod, control preferred | Search index service for LibreChat. Keep on control unless index IO becomes a proven bottleneck. |

Model cache storage should eventually live under the bulk CephFS model layout,
but the model-serving pods should stay on control nodes.

### Search And Logs

| Workload | Target | Spread | Justification |
| --- | --- | --- | --- |
| `search/opensearch-logs-logs` | storage | three data nodes, one per Eva | Log storage is RBD-backed, write-heavy, and search/index IO-bound. Place data nodes near Ceph and spread one per Eva. |
| `search/data-prepper` | control | two replicas across control nodes | Ingest pipeline has no PVC. Keep on control unless metrics show Data Prepper-to-OpenSearch traffic saturating the 2.5 Gb path. |
| `search/opensearch-operator-controller-manager` | control | single replica, control preferred | Operator/controller, not data path. |
| `search/fluent-bit` | all nodes | one per node | Node-local log collection. |

If log ingest grows enough that Data Prepper becomes the dominant writer to
OpenSearch, move `data-prepper` to storage. Until then, its non-PVC nature keeps
it on control.

### Monitoring

| Workload | Target | Spread | Justification |
| --- | --- | --- | --- |
| `monitoring/prometheus-kube-prometheus-stack-prometheus` | storage | single RWO pod, any Eva | Prometheus is an append-heavy TSDB on RBD. Scrape traffic is smaller than TSDB write IO. Storage placement reduces write-path pressure on 2.5 Gb control links. |
| `monitoring/kube-prometheus-stack-grafana` | control | single replica, control preferred | UI and dashboard state are small. No storage-throughput justification for Eva. |
| `monitoring/kube-prometheus-stack-operator` | control | single replica, control preferred | Non-PVC controller. |
| `monitoring/kube-prometheus-stack-kube-state-metrics` | control | single replica, control preferred | API metrics service. No storage-locality benefit. |
| `monitoring/kube-prometheus-stack-prometheus-node-exporter` | all nodes | one per node | Node-local metrics. |

### Backup

| Workload | Target | Spread | Justification |
| --- | --- | --- | --- |
| `backup/volsync` | control | single replica, control preferred | Controller only. Keep off Eva. |
| VolSync mover jobs for small RBD PVCs | control | schedule near default app pool | Backup IO exists but current protected PVCs are mostly small. No need to reserve storage nodes. |
| VolSync mover jobs for future large bulk datasets | storage | any Eva | Large backup/restore jobs should run near Ceph to avoid the 2.5 Gb control-node cap. |

### Productivity

| Workload | Target | Spread | Justification |
| --- | --- | --- | --- |
| `productivity/nextcloud` | control | single replica, control preferred | User-facing app with moderate RBD appdata. Compute/app latency and stronger control-node GPU/CPU matter more than storage locality. DB may move to Eva separately. |
| `productivity/elasticsearch` | control | single replica, control preferred | Small 8 GiB app-local search service. No current evidence of IO saturation. |
| `productivity/collabora` | control | single replica, control preferred | CPU/app workload, no PVC. |
| `productivity/homarr-helm` | control | single replica, control preferred | Dashboard app, not storage-bound. |
| `productivity/homepage` | control | three replicas, one per control node | Stateless dashboard. |
| `productivity/unifi-os-server` | control | single replica, control preferred | Stateful singleton with several small RBD PVCs. Keep near general network/control services. |
| `productivity/uptime-kuma` | control | single replica, control preferred | Small stateful monitor. No storage-throughput justification. |
| `productivity/vaultwarden` | control | single replica, control preferred | Tiny but important state. Keep on control. |
| `productivity/whiteboard` | control | single replica, control preferred | Stateless/lightweight app. |

### Other

| Workload | Target | Spread | Justification |
| --- | --- | --- | --- |
| `other/headscale` | control | single replica, control preferred | Network coordination service with small PVC. No storage-throughput justification. |
| `other/headscale-ui` | control | single replica, control preferred | UI, no PVC. |
| `other/hypermind` | control | single replica, control preferred | No PVC. Keep on default compute pool. |
| `other/foldingathome` | control | three replicas across control nodes | Compute workload. If it uses GPU, the control nodes have better GPUs. |
| `other/host-dashboards` | external/service-only | n/a | Kubernetes Services/Endpoints only. |
| `other/minio` | external/service-only | n/a | External endpoint. No pod placement. |
| `other/opnsense` | external/service-only | n/a | External endpoint. No pod placement. |
| `other/truenas` | external/service-only | n/a | External endpoint. No pod placement. |
| `other/truenas-2` | external/service-only | n/a | External endpoint. No pod placement. |

### Web

| Workload | Target | Spread | Justification |
| --- | --- | --- | --- |
| `web/portfolio` | control | three replicas, one per control node | Stateless web app. No Eva benefit. |
| `web/portfolio-staging` | control | three replicas, one per control node | Stateless web app. No Eva benefit. |

## Storage Surface Decisions

| Surface | Placement impact |
| --- | --- |
| `ceph-block` / `ceph-block-critical` | Consuming a PVC does not automatically justify Eva placement. Use Eva for IO-heavy RBD consumers, not for every RBD user. |
| `ceph-block-db` | Best fit for CNPG clusters after restore testing. CNPG pods should run on Eva when moved to this class. |
| `cephfs-bulk` | Storage-heavy consumers should run on Eva; compute-heavy consumers can run on control. |
| `media-library` | Normal media readers such as Plex/Jellyfin. Use normal readahead. |
| `media-library-torrent` | qBittorrent/Servarr stacks only. Uses `rasize=0` to avoid CephFS read amplification while seeding. |
| local scratch | Always local to the pod node. Required for qBittorrent temp and media transcode. |
| NFS export | External clients only. Cluster workloads should prefer CSI. |

## Implementation Order

1. Add the explicit control-plane label:

   ```bash
   kubectl label node melchior-1 homelab.rcrumana.xyz/node-plane=control
   kubectl label node balthasar-2 homelab.rcrumana.xyz/node-plane=control
   kubectl label node casper-3 homelab.rcrumana.xyz/node-plane=control
   ```

2. Add shared Kustomize patches or local workload snippets for:

   - control default selector:

     ```yaml
     nodeSelector:
       homelab.rcrumana.xyz/node-plane: control
     ```

   - storage selector and toleration:

     ```yaml
     nodeSelector:
       homelab.rcrumana.xyz/node-plane: storage
     tolerations:
       - key: homelab.rcrumana.xyz/storage
         operator: Equal
         value: "true"
         effect: NoSchedule
     ```

3. Move workload groups in this order:

   - Ceph/Rook controller cleanup: move non-data-path controllers back to
     control where possible, keep daemons on Eva.
   - Media: qBittorrent stacks, Plex, Jellyfin.
   - IO-heavy platform services: CNPG, OpenSearch data nodes, Harbor registry,
     Harbor jobservice, Harbor Trivy, Prometheus.
   - Remaining control defaults for stateless/non-PVC apps.

4. After each group:

   - Check pod spread by hostname.
   - Check Ceph client IO by node.
   - Check application latency and restart behavior.
   - Confirm no unexpected storage tolerations were added to generic apps.

## Open Validation Gates

These checks decide whether any target should be adjusted:

- Plex/Jellyfin transcoding: if Radeon 610 transcode quality or throughput is
  insufficient, move the affected media server to a control GPU node and keep
  the CephFS mount over the network.
- qBittorrent after final 10 Gb move: confirm RX/TX symmetry remains acceptable
  with `rasize=0`.
- PostgreSQL after Eva placement: confirm query latency does not regress for
  control-plane apps and that RBD write latency improves.
- Harbor after Eva placement: confirm image pulls to control nodes are not worse
  and that registry GC/scans improve.
- Prometheus after Eva placement: confirm scrape latency is acceptable and TSDB
  write latency improves.
- OpenSearch after Eva placement: confirm indexing/backpressure improves without
  starving Ceph.

## Policy Short Version

- Control nodes run the cluster and normal apps.
- Eva nodes run Ceph and the few workloads that can prove storage locality pays
  for itself.
- AI stays on control nodes.
- Torrenting, media serving, CNPG, OpenSearch data, Harbor registry/jobservice,
  Harbor Trivy, and Prometheus are the main Eva candidates.
- NFS is for non-cluster devices; cluster pods should use CephFS/RBD through
  CSI.
