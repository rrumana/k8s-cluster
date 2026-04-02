# Cluster Application and Platform Guide

This document describes the declared shape of the live `k8s-cluster` repo.
It follows the manifests in this repository rather than a one-off runtime
snapshot.

## Scope and assumptions

- 3-node control-plane cluster: `melchior-1`, `balthasar-2`, `casper-3`
- GitOps model: Argo CD root app syncs `cluster/platform/gitops/argocd`, which fans out into platform and workload `Application` objects
- This guide focuses on active or intended state and ignores removed migration artifacts

## Quick app catalog

### Platform and operations apps

| App | One-sentence description |
|---|---|
| Argo CD | Continuously syncs Kubernetes resources from this Git repo so declared and live state stay aligned. |
| Cilium | Provides pod networking, service routing, and network policy with an eBPF datapath. |
| Hubble | Provides flow visibility for Cilium traffic. |
| MetalLB | Assigns and advertises bare-metal `LoadBalancer` IPs on the LAN. |
| HAProxy Ingress | Terminates HTTP(S) traffic and routes hostnames and paths to cluster services. |
| cert-manager | Requests, renews, and manages TLS certificates with Let's Encrypt DNS-01. |
| Linkerd | Adds mTLS, service-to-service telemetry, and policy controls. |
| Vault | Central secret store for cluster credentials, tokens, and keys. |
| External Secrets | Syncs selected Vault values into native Kubernetes `Secret` objects. |
| Harbor | Internal registry, proxy cache, and OCI chart mirror used for runtime images and chart sources. |
| Renovate | Twice-monthly dependency update scanner against GitHub and Harbor. |
| Rook/Ceph | Distributed block and filesystem storage for most persistent workloads. |
| Snapshot Controller | Enables CSI snapshots for Ceph-backed volumes. |
| VolSync | Runs scheduled PVC backups to MinIO through snapshot + restic flows. |
| metrics-server | Publishes pod and node metrics consumed by autoscaling and ops tooling. |
| VPA | Produces right-sizing recommendations across the workload set. |
| descheduler | Periodically evicts pods under policy to improve placement and balance. |
| egress-qos | Shapes outbound bandwidth for pods labeled `traffic-tier=bulk-seed`. |

### Data platform apps

| App | One-sentence description |
|---|---|
| CloudNativePG operator | Manages lifecycle, failover, and backups for PostgreSQL clusters. |
| `pg-ai` | Shared PostgreSQL cluster for AI workloads. |
| `pg-media` | Shared PostgreSQL cluster for media workloads. |
| `pg-platform` | Shared PostgreSQL cluster for platform and infrastructure services. |
| `pg-productivity` | Shared PostgreSQL cluster for productivity apps. |
| `pg-other` | Shared PostgreSQL cluster for miscellaneous workloads. |
| `valkey-cache` | Shared replicated cache tier with LRU eviction and no persistence. |
| `valkey-queue` | Shared replicated queue/state tier with AOF-backed persistence and no-eviction behavior. |
| MinIO service bridge | In-cluster services that front the external MinIO instance used for backups and object APIs. |

### User-facing and domain apps

| App | One-sentence description |
|---|---|
| LibreChat | Browser-based AI chat UI with local-model and RAG support. |
| llama-backend | Internal AMD GPU-backed `llama.cpp` workers plus a LiteLLM OpenAI-compatible gateway. |
| arr-stack | Main media automation pod bundling qBittorrent, Servarr apps, Jellyseerr, FlareSolverr, and Gluetun. |
| arr-lts | Secondary qBittorrent + Gluetun stack for isolated long-term workflows. |
| arr-lts2 | Third qBittorrent + Gluetun stack for additional isolated torrent throughput. |
| Jellyfin | Self-hosted media streaming server. |
| Plex | Self-hosted media streaming server with native-client LAN exposure. |
| Immich | Self-hosted photo and video backup platform with ROCm-backed ML workers. |
| Nextcloud | Private cloud suite for files, collaboration, and extensions. |
| Collabora | Web office editor integrated with Nextcloud. |
| Homarr | Dashboard and service launcher with widgets backed by Postgres and Valkey. |
| UniFi OS Server | Self-hosted UniFi appliance stack exposed through ingress and MetalLB. |
| Uptime Kuma | Uptime dashboard and endpoint monitor. |
| Vaultwarden | Bitwarden-compatible password manager server. |
| Whiteboard | Lightweight collaborative whiteboard currently used mainly with Nextcloud. |
| Elasticsearch | Search backend currently used by Nextcloud. |
| Headscale | Self-hosted Tailscale-compatible coordination server. |
| Headscale UI | Restricted browser UI for Headscale. |
| Host dashboards | Restricted ingress bridges to the desktop and each cluster node on port `7681`. |
| Folding@Home | Three-replica donation workload with one stateful pod per node. |
| Hypermind | Experimental host-networked shared map/chat service. |
| OPNsense service bridge | In-cluster proxy path to the external router UI/API endpoint. |
| TrueNAS service bridge | In-cluster proxy path to the external NAS UI endpoint. |
| Portfolio (prod) | Production personal site deployment. |
| Portfolio (staging) | Staging deployment for the same site. |

## 1) Core platform foundation

### GitOps and namespace layout

- Argo CD manages nearly everything in this repo.
- The root app fans out into platform apps, shared app scaffolding, and per-workload applications.
- Shared ingress definitions live under `cluster/apps/shared/ingress`.
- Harbor keeps its own chart-managed ingress instead of using the shared ingress bundle.
- Active workload namespaces are `ai`, `media`, `productivity`, `other`, and `web`.
- Active platform namespaces include `argocd`, `cert-manager`, `cnpg-system`, `metallb-system`, `ingress-haproxy`, `service-mesh`, `rook-ceph`, `security`, `backup`, `databases`, `harbor`, `automation`, and `scheduling`.

### Cluster networking: Cilium + Hubble

- Cilium is the cluster CNI and datapath, including kube-proxy replacement behavior.
- Hubble is enabled for flow visibility.
- Cilium is bootstrap-managed from `cluster/bootstrap/cilium` rather than through Argo CD.

### North-south networking: MetalLB + HAProxy Ingress

- MetalLB advertises bare-metal `LoadBalancer` addresses on the LAN with L2 mode.
- The default IP pool is `192.168.1.230-192.168.1.250` on interface `enp196s0`.
- HAProxy Ingress is the main HTTP(S) entrypoint and is exposed at `192.168.1.230`.
- Two ingress classes are defined:
- `haproxy`: default or broader-exposure traffic profile
- `haproxy-restricted`: restricted profile, usually combined with source allowlists

### TLS automation: cert-manager

- cert-manager runs in HA form with 2 controller replicas and 2 replicas each for webhook and cainjector.
- Let's Encrypt production and staging `ClusterIssuer` objects are declared.
- DNS-01 challenges use Cloudflare API credentials.
- A wildcard certificate for `k8s.rcrumana.xyz` and `*.k8s.rcrumana.xyz` is maintained for default ingress use.

### Service mesh: Linkerd

- Linkerd is installed as coordinated CRD, CNI, control-plane, identity, and viz applications.
- CNI mode avoids init-container privilege requirements in meshed workloads.
- Many user-facing apps have Linkerd injection enabled, with opt-out or opaque-port exceptions where needed.

### Registry and operational helpers

- Harbor is exposed at `https://harbor.rcrumana.xyz`.
- Harbor uses shared PostgreSQL from `pg-platform-rw.databases.svc.cluster.local` and chart-managed internal Redis.
- Harbor is used for private images, proxy-cache projects, and mirrored OCI charts.
- Harbor pull credentials are distributed by `ExternalSecret` on a per-namespace basis.
- Renovate runs as a CronJob in `automation` at `09:15` America/Los_Angeles on the 1st and 15th of each month.
- `metrics-server` runs in `kube-system`.
- VPA components run in `scheduling`, with workload VPA objects generally set to recommendation-only mode.
- Descheduler runs in `scheduling`.
- `egress-qos` runs host-networked on every node and shapes pods labeled `traffic-tier=bulk-seed`.

## 2) Storage, snapshots, backups, and recovery

### Primary storage: Rook/Ceph

- Rook deploys a 3-node Ceph cluster with OSDs on two dedicated NVMe devices per node.
- Ceph public and replication traffic are both pinned to the dedicated storage network `172.16.100.0/24`.
- The main storage interfaces exposed to Kubernetes are:
- `ceph-block`: default RBD `StorageClass` for `ReadWriteOnce` PVCs
- `ceph-filesystem`: CephFS `StorageClass` for RWX PVCs
- The Ceph dashboard is exposed through ingress at `ceph.rcrumana.xyz`.

### Volume snapshots

- CSI snapshot support is installed in `kube-system`.
- `ceph-block-snap` is the default `VolumeSnapshotClass`.
- `ceph-filesystem-snap` is also defined for CephFS-backed volumes.

### Backup engines

- VolSync runs in `backup`.
- Replication sources are declared across `ai`, `media`, `productivity`, `other`, and selected `databases` PVCs.
- The common pattern is `copyMethod: Snapshot` with `ceph-block-snap` plus restic push to MinIO.
- Most replication sources retain `daily 7 / weekly 4 / monthly 3` and prune restic data every 14 days.
- CloudNativePG clusters also run scheduled backups to `s3://cluster-backups/cnpg/*` via `minio-api.other.svc.cluster.local:9000`.
- CNPG retention is 30 days.

### Emergency dump operation

- `scripts/emergency-cluster-dump.sh` and `docs/emergency-dump-runbook.md` create a human-readable emergency bundle under `/NAS/dump`.
- The dump is intended as an operational recovery aid, not a replacement for VolSync or CNPG backups.
- It includes selected app data copies, exported secrets, and cluster configuration snapshots for the workloads it covers.

### External service bridges

- The repo defines service bridges to systems outside Kubernetes:
- MinIO at `192.168.1.10:9000/9002`
- OPNsense at `192.168.1.1:4443`
- TrueNAS at `192.168.1.10:443`
- Desktop and host dashboards at `192.168.1.11:7681`, `192.168.1.13:7681`, `192.168.1.14:7681`, and `192.168.1.15:7681`

## 3) Shared data platforms

### PostgreSQL platform (CloudNativePG)

- The CloudNativePG operator runs in `cnpg-system`.
- Five shared PostgreSQL clusters run in `databases`, all with 3-instance HA layouts:
- `pg-platform`
- `pg-media`
- `pg-ai`
- `pg-productivity`
- `pg-other`
- Each cluster exposes the usual CNPG service set such as `*-rw`, `*-ro`, and `*-r`.
- Persistent storage for all CNPG clusters uses Ceph block volumes.

### Valkey platform

- Redis Enterprise has been removed from GitOps and replaced by two Helm-managed Valkey releases in `databases`.
- `valkey-cache` runs 1 primary plus 2 replicas, no Sentinel, no persistence, `allkeys-lru`, and a 1 GiB maxmemory cap.
- `valkey-queue` runs 1 primary plus 2 replicas, no Sentinel, AOF persistence on Ceph block PVCs, and `noeviction`.
- Current client targets are:
- `valkey-cache-primary.databases.svc.cluster.local:6379`
- `valkey-queue-primary.databases.svc.cluster.local:6379`
- VolSync replication sources back up `valkey-queue` replica PVCs.

## 4) Workloads by namespace

## `ai` namespace

### LibreChat stack

- `librechat` is the main user-facing deployment and is exposed at `chat.rcrumana.xyz`.
- The namespace also contains:
- `librechat-mongodb` statefulset
- `librechat-meilisearch` statefulset
- `librechat-rag-api` deployment with 2 replicas
- LibreChat and the RAG API use shared `pg-ai` and `valkey-cache` rather than in-namespace relational or cache services.
- Persistent data is stored on Ceph-backed PVCs for uploads, MongoDB, and Meilisearch.

### Llama backend + gateway

- `llm-gateway` is a 2-replica LiteLLM deployment that exposes an OpenAI-compatible internal API.
- Three GPU-backed workers sit behind it:
- `llama-static-a`
- `llama-static-b`
- `llama-swap`
- Each worker requests one `amd.com/gpu` device.
- All model workers share a `500Gi` RWX CephFS PVC named `llama-models-cache`.
- Current fixed models are `Qwen3.5-35B-A3B` and `Qwen3-Next-80B-A3B-Instruct`.
- The swap pool currently seeds `Qwen3-Next-80B-A3B-Thinking`, `GLM-4.7-Flash`, `gpt-oss-20b`, `gemma-3-12b-it`, and `Qwen3-Coder-Next`.

## `media` namespace

### ARR ecosystem

- There are three qBittorrent-based stacks:
- `arr-stack`
- `arr-lts`
- `arr-lts2`
- All qBittorrent traffic is routed through a colocated Gluetun VPN container.
- The main `arr-stack` pod also includes `sonarr`, `radarr`, `lidarr`, `prowlarr`, `jellyseerr`, `flaresolverr`, and the `pf-sync` helper.
- `arr-stack` is labeled `traffic-tier=bulk-seed`, which makes it subject to `egress-qos`.
- The Servarr and Jellyseerr databases live on shared `pg-media`.
- Media files are mounted from host path `/NAS`.
- qBittorrent temp data also uses host path `/var/lib/qbit-temp`.

### Jellyfin

- Runs as a dedicated deployment with a Ceph-backed config PVC.
- Uses host media paths and `/dev/dri` for hardware acceleration.
- Exposed by both ingress (`jellyfin.rcrumana.xyz`) and direct MetalLB IP `192.168.1.233`.

### Plex

- Runs as a dedicated deployment with a Ceph-backed config PVC.
- Uses host media paths and `/dev/dri` for hardware acceleration.
- Exposed by both ingress (`plex.rcrumana.xyz`) and direct MetalLB IP `192.168.1.232`.

### Immich

- Split into `immich-server` and `immich-machine-learning` deployments.
- `immich-server` uses shared `pg-media` and `valkey-queue`.
- `immich-machine-learning` uses the ROCm image, mounts `/dev/dri` and `/dev/kfd`, and runs privileged without requesting `amd.com/gpu`.
- Persistent storage is:
- `immich-photos` at `1Ti`
- `immich-ml-cache` at `4Gi`
- Immich is exposed by both ingress (`immich.rcrumana.xyz`) and direct MetalLB IP `192.168.1.234`.

## `productivity` namespace

### Nextcloud

- Deployed through the community Helm chart with custom values.
- Uses shared `pg-productivity` and shared `valkey-cache`.
- Main app data lives on the `nextcloud-appdata` Ceph block PVC.
- External access is through `nextcloud.rcrumana.xyz`.
- Collabora is deployed separately and integrated with it.

### Collabora

- Runs as a standalone deployment exposed at `collabora.rcrumana.xyz`.
- Configured for TLS termination at ingress and trusted integration with Nextcloud.

### Homarr

- Deployed from the OCI Helm chart.
- Uses shared PostgreSQL plus shared `valkey-cache`.
- Exposed through restricted ingress at `homarr.rcrumana.xyz`.

### UniFi OS Server

- Replaced the older UniFi controller layout with the `lemker/unifi-os-server` image.
- Runs as a privileged `Recreate` deployment with several Ceph-backed PVCs for persistent data, logs, MongoDB data, UniFi data, and RabbitMQ SSL material.
- The web UI is exposed through restricted ingress at `unifi.rcrumana.xyz`.
- Native LAN ports are exposed through MetalLB at `192.168.1.235`.

### Uptime Kuma

- Single deployment with a Ceph-backed data PVC.
- Exposed through restricted ingress at `uptime.rcrumana.xyz`.

### Vaultwarden

- Single deployment with a small Ceph-backed `/data` PVC.
- Uses shared PostgreSQL rather than SQLite.
- Exposed through restricted ingress at `vault.rcrumana.xyz`.

### Whiteboard

- Stateless single deployment of `lovasoa/wbo`.
- Currently intended primarily for Nextcloud integration.
- Exposed through restricted ingress at `whiteboard.rcrumana.xyz`.

### Elasticsearch

- Single-node Elasticsearch deployment with a Ceph-backed data PVC.
- Currently used as the Nextcloud search backend.
- ClusterIP only, no direct ingress.

## `other` namespace

### Headscale

- Headscale API and UI are separate deployments.
- The API uses shared `pg-other` for PostgreSQL.
- A Ceph-backed PVC stores local Headscale state such as keys and policy files.
- The API is published at `headscale.rcrumana.xyz`.
- The UI is published on the same host under `/web` with a restricted ingress policy.
- The Tailnet base domain is `tail.rcrumana.xyz`.

### Host dashboards

- The repo defines ClusterIP services plus `EndpointSlice` objects for:
- `desktop-http`
- `melchior-http`
- `balthasar-http`
- `casper-http`
- Restricted ingresses publish those bridges at `desktop.rcrumana.xyz`, `melchior.rcrumana.xyz`, `balthasar.rcrumana.xyz`, and `casper.rcrumana.xyz`.

### Folding@Home

- Runs as a 3-replica StatefulSet with `podManagementPolicy: Parallel`.
- Each replica gets its own `5Gi` Ceph-backed config PVC.
- The workload is internal only and exposed through a headless service.

### Hypermind

- Single deployment published at `hypermind.rcrumana.xyz`.
- Uses `hostNetwork: true` because the upstream service expects direct host networking for its P2P behavior.

### MinIO, OPNsense, and TrueNAS bridges

- `minio` and `minio-api` front the external MinIO instance on `192.168.1.10`.
- `opnsense-https` fronts the router UI/API at `192.168.1.1:4443`.
- `truenas-https` fronts the NAS UI at `192.168.1.10:443`.
- All three are exposed through restricted ingress.

## `web` namespace

### Portfolio sites

- `portfolio` and `portfolio-staging` are separate 3-replica deployments.
- Both pull first-party images from Harbor's `apps-private` project.
- Ingress hostnames are:
- Production: `rcrumana.xyz`
- Staging: `staging.rcrumana.xyz`
- HAProxy rewrite annotations handle `.html` path normalization for the static site layout.

## 5) How the major pieces connect

- Argo CD continuously syncs platform and application definitions from this repo.
- Vault stores secret authority and External Secrets materializes runtime `Secret` objects where apps need them.
- Harbor sits in front of more and more runtime image pulls and OCI chart sources.
- cert-manager issues the TLS material used by HAProxy ingresses and Harbor.
- MetalLB provides LAN IPs for HAProxy plus the directly exposed media and UniFi services.
- Rook/Ceph provides almost all persistent storage through `ceph-block` and `ceph-filesystem`.
- Snapshot Controller and VolSync protect many PVCs on a schedule, while CNPG handles PostgreSQL backups natively.
- The emergency dump workflow gives a second operational recovery path for selected workloads.
- CNPG provides shared relational storage and Valkey provides shared cache or queue storage.
- The AI path is: LibreChat -> RAG API / PG / Valkey -> LiteLLM gateway -> `llama.cpp` workers.
- The main media path is: Servarr / Jellyseerr / Prowlarr -> qBittorrent through Gluetun -> `/NAS` libraries -> Jellyfin or Plex playback.

## 6) Quick namespace index

- `argocd`: Argo CD controllers and `Application` objects.
- `cert-manager`: cert-manager controller, webhook, and cainjector.
- `cnpg-system`: CloudNativePG operator.
- `kube-system`: core Kubernetes components, AMD GPU device plugin, metrics-server, and snapshot controller.
- `metallb-system`: MetalLB controllers, speakers, and shared pull-secret plumbing.
- `ingress-haproxy`: HAProxy ingress controller and default wildcard certificate.
- `service-mesh`: Linkerd control plane, CNI, and viz.
- `rook-ceph`: Ceph cluster, CSI drivers, toolbox, and dashboard.
- `security`: Vault and External Secrets.
- `backup`: VolSync controller and replication-source app.
- `databases`: shared PostgreSQL clusters and Valkey releases.
- `harbor`: Harbor registry components.
- `automation`: Renovate CronJob and related secrets.
- `scheduling`: VPA components and descheduler.
- `ai`: LibreChat and local LLM services.
- `media`: ARR stacks, Jellyfin, Plex, and Immich.
- `productivity`: Nextcloud, Collabora, Homarr, UniFi OS Server, Uptime Kuma, Vaultwarden, Whiteboard, and Elasticsearch.
- `other`: Headscale, host dashboards, Folding@Home, Hypermind, and external service bridges.
- `web`: portfolio production and staging.
- Reserved placeholders declared in repo: `ingress`, `networking`, and `monitoring`.

## Appendix A: Ingress routing map

| Hostname | Path | Namespace | Ingress | Class | Backend service:port |
|---|---|---|---|---|---|
| `argocd.rcrumana.xyz` | `/` | `argocd` | `argocd` | `haproxy-restricted` | `argocd-server:80` |
| `balthasar.rcrumana.xyz` | `/` | `other` | `balthasar-proxy` | `haproxy-restricted` | `balthasar-http:7681` |
| `casper.rcrumana.xyz` | `/` | `other` | `casper-proxy` | `haproxy-restricted` | `casper-http:7681` |
| `ceph.rcrumana.xyz` | `/` | `rook-ceph` | `ceph-dashboard` | `haproxy-restricted` | `rook-ceph-mgr-dashboard:8443` |
| `chat.rcrumana.xyz` | `/` | `ai` | `librechat` | `haproxy-restricted` | `librechat:80` |
| `collabora.rcrumana.xyz` | `/` | `productivity` | `collabora` | `haproxy-restricted` | `collabora:9980` |
| `desktop.rcrumana.xyz` | `/` | `other` | `desktop-proxy` | `haproxy-restricted` | `desktop-http:7681` |
| `harbor.rcrumana.xyz` | `/` | `harbor` | `harbor` | `haproxy` | `harbor-portal:80`, plus `harbor-core:80` for API and registry paths |
| `headscale.rcrumana.xyz` | `/` | `other` | `headscale-api` | `haproxy` | `headscale:80` |
| `headscale.rcrumana.xyz` | `/web` | `other` | `headscale-ui` | `haproxy-restricted` | `headscale-ui:80` |
| `homarr.rcrumana.xyz` | `/` | `productivity` | `homarr` | `haproxy-restricted` | `homarr-helm:7575` |
| `hypermind.rcrumana.xyz` | `/` | `other` | `hypermind` | `haproxy-restricted` | `hypermind:80` |
| `immich.rcrumana.xyz` | `/` | `media` | `immich` | `haproxy-restricted` | `immich-server:2283` |
| `jellyfin.rcrumana.xyz` | `/` | `media` | `jellyfin` | `haproxy-restricted` | `jellyfin:8096` |
| `jellyseerr.rcrumana.xyz` | `/` | `media` | `jellyseerr` | `haproxy-restricted` | `jellyseerr:80` |
| `lidarr.rcrumana.xyz` | `/` | `media` | `lidarr` | `haproxy-restricted` | `lidarr:80` |
| `melchior.rcrumana.xyz` | `/` | `other` | `melchior-proxy` | `haproxy-restricted` | `melchior-http:7681` |
| `minio-api.rcrumana.xyz` | `/` | `other` | `minio-api-proxy` | `haproxy-restricted` | `minio-api:9000` |
| `minio.rcrumana.xyz` | `/` | `other` | `minio-proxy` | `haproxy-restricted` | `minio:9002` |
| `nas.rcrumana.xyz` | `/` | `other` | `truenas-proxy` | `haproxy-restricted` | `truenas-https:443` |
| `nextcloud.rcrumana.xyz` | `/` | `productivity` | `nextcloud` | `haproxy-restricted` | `nextcloud:8080` |
| `plex.rcrumana.xyz` | `/` | `media` | `plex` | `haproxy-restricted` | `plex:32400` |
| `prowlarr.rcrumana.xyz` | `/` | `media` | `prowlarr` | `haproxy-restricted` | `prowlarr:80` |
| `qbit-lts.rcrumana.xyz` | `/` | `media` | `qbit-lts` | `haproxy-restricted` | `qbit-lts:80` |
| `qbit-lts2.rcrumana.xyz` | `/` | `media` | `qbit-lts2` | `haproxy-restricted` | `qbit-lts2:80` |
| `qbit.rcrumana.xyz` | `/` | `media` | `qbit` | `haproxy-restricted` | `qbit:80` |
| `radarr.rcrumana.xyz` | `/` | `media` | `radarr` | `haproxy-restricted` | `radarr:80` |
| `rcrumana.xyz` | `/` | `web` | `portfolio` | `haproxy` | `portfolio:80` |
| `router.rcrumana.xyz` | `/` | `other` | `opnsense-proxy` | `haproxy-restricted` | `opnsense-https:4443` |
| `sonarr.rcrumana.xyz` | `/` | `media` | `sonarr` | `haproxy-restricted` | `sonarr:80` |
| `staging.rcrumana.xyz` | `/` | `web` | `portfolio-staging` | `haproxy` | `portfolio-staging:80` |
| `unifi.rcrumana.xyz` | `/` | `productivity` | `unifi` | `haproxy-restricted` | `unifi-os-server-ui:11443` |
| `uptime.rcrumana.xyz` | `/` | `productivity` | `uptime-kuma` | `haproxy-restricted` | `uptime-kuma:80` |
| `vault.rcrumana.xyz` | `/` | `productivity` | `vaultwarden` | `haproxy-restricted` | `vaultwarden:80` |
| `whiteboard.rcrumana.xyz` | `/` | `productivity` | `whiteboard` | `haproxy-restricted` | `whiteboard:80` |

## Appendix B: Direct `LoadBalancer` services (LAN IP map)

| Namespace | Service | External IP | Ports |
|---|---|---|---|
| `ingress-haproxy` | `haproxy-ingress` | `192.168.1.230` | `80/TCP`, `443/TCP` |
| `media` | `plex` | `192.168.1.232` | `32400/TCP` |
| `media` | `jellyfin` | `192.168.1.233` | `8096/TCP`, `8920/TCP`, `7359/UDP` |
| `media` | `immich-server` | `192.168.1.234` | `2283/TCP` |
| `productivity` | `unifi-os-server-tcp` | `192.168.1.235` | `11443/TCP`, `5005/TCP`, `5671/TCP`, `6789/TCP`, `8080/TCP`, `8443/TCP`, `8843/TCP`, `8444/TCP`, `8880/TCP`, `8881/TCP`, `8882/TCP`, `9543/TCP`, `11084/TCP` |
| `productivity` | `unifi-os-server-udp` | `192.168.1.235` | `3478/UDP`, `5514/UDP`, `10001/UDP`, `10003/UDP` |

## Appendix C: External service bridges

| Namespace | Service | External target | Purpose |
|---|---|---|---|
| `other` | `minio` | `192.168.1.10:9002` | MinIO console and admin endpoint for backup workflows. |
| `other` | `minio-api` | `192.168.1.10:9000` | MinIO S3 API endpoint for VolSync and CNPG backups. |
| `other` | `opnsense-https` | `192.168.1.1:4443` | Reverse-proxied access path to OPNsense. |
| `other` | `truenas-https` | `192.168.1.10:443` | Reverse-proxied access path to TrueNAS. |
| `other` | `desktop-http` | `192.168.1.11:7681` | Desktop dashboard bridge. |
| `other` | `melchior-http` | `192.168.1.13:7681` | `melchior-1` dashboard bridge. |
| `other` | `balthasar-http` | `192.168.1.14:7681` | `balthasar-2` dashboard bridge. |
| `other` | `casper-http` | `192.168.1.15:7681` | `casper-3` dashboard bridge. |
