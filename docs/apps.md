# Cluster Application and Platform Guide

This document explains what the live `k8s-homelab-2` cluster is doing, based on the GitOps repo and the live pod/service/PVC snapshot you provided.

It is organized from platform foundations to user-facing apps so a reader can understand dependencies as they go.

## Scope and assumptions

- Cluster shape: 3-node highly available control plane (`balthasar-2`, `casper-3`, `melchior-1`), all currently `Ready` on Kubernetes `v1.35.1`.
- GitOps model: Argo CD `root` app syncs `cluster/platform/gitops/argocd`, which then syncs platform and app `Application` objects.
- This guide focuses on active/intended functionality and ignores leftover migration/iteration artifacts as requested.

## Quick app catalog (one sentence each)

These are short descriptions for readers who are new to the platform.

### Platform and operations apps

| App | One-sentence description |
|---|---|
| Argo CD | Continuously syncs Kubernetes resources from this Git repo so cluster state matches declared state. |
| Cilium | Provides pod networking, service routing, and network policy using an eBPF-based CNI datapath. |
| Hubble | Gives UI/API visibility into live network flows and drops inside the cluster. |
| MetalLB | Assigns and advertises LAN IPs for Kubernetes `LoadBalancer` services on bare metal. |
| HAProxy Ingress | Terminates HTTP(S) traffic and routes hostnames/paths to internal Kubernetes services. |
| cert-manager | Automatically requests, renews, and manages TLS certificates for ingresses and internal components. |
| Linkerd | Adds service-to-service mTLS, traffic observability, and policy controls through a service mesh. |
| Vault | Central secret store for credentials, tokens, and keys used by cluster workloads. |
| External Secrets | Pulls secrets from Vault and creates native Kubernetes Secrets for consuming apps. |
| Rook/Ceph | Runs distributed block/filesystem storage used by most persistent volumes in the cluster. |
| Snapshot Controller | Enables CSI volume snapshots used directly and by backup tooling. |
| VolSync | Performs scheduled PVC backups (via snapshots/restic) to object storage. |
| egress-qos | Applies outbound bandwidth shaping for selected high-throughput pods (for example torrent traffic). |
| descheduler | Periodically evicts pods under policy rules to improve placement and rebalance nodes. |

### Data platform apps

| App | One-sentence description |
|---|---|
| CloudNativePG operator | Manages lifecycle, failover, and backups of PostgreSQL clusters. |
| `pg-ai` | Shared PostgreSQL cluster for AI workloads and related app databases. |
| `pg-media` | Shared PostgreSQL cluster for media automation and media-adjacent apps. |
| `pg-platform` | Shared PostgreSQL cluster for infrastructure/platform-oriented services. |
| `pg-productivity` | Shared PostgreSQL cluster for productivity applications. |
| `pg-other` | Shared PostgreSQL cluster for miscellaneous/non-media/non-productivity services. |
| Redis Enterprise operator | Installs and manages Redis Enterprise control-plane resources. |
| `rec-platform` | Three-node Redis Enterprise cluster hosting managed Redis databases. |
| `redis-cache` | Managed Redis database optimized for cache-style workloads (evictable data). |
| `redis-queue` | Managed Redis database configured for queue/state workloads with persistence. |
| MinIO service bridge | Provides in-cluster service endpoints that proxy to an external MinIO instance for backup/object APIs. |

### User-facing and domain apps

| App | One-sentence description |
|---|---|
| LibreChat | Browser-based multi-model AI chat interface with RAG/search and local model gateway integration. |
| llama-backend | Hosts local GPU-backed `llama.cpp` model workers plus a LiteLLM OpenAI-compatible gateway. |
| arr-stack | Full media automation bundle (qBittorrent, Servarr apps, Jellyseerr, FlareSolverr) behind a VPN sidecar. |
| arr-lts | Secondary qBittorrent+Gluetun VPN stack for isolated long-term seeding/downloading. |
| arr-lts2 | Third qBittorrent+Gluetun VPN stack for additional isolated torrent throughput. |
| Jellyfin | Self-hosted media streaming server for TV/movie/music playback. |
| Plex | Self-hosted media streaming server with broad client ecosystem support. |
| Immich | Self-hosted photo/video backup and management platform with machine-learning services. |
| Nextcloud | Private cloud suite for files, collaboration, and app extensions. |
| Collabora | Online document editor service integrated with Nextcloud for office files. |
| Homarr | Self-hosted dashboard that aggregates links and service widgets. |
| UniFi Controller | Network controller managing UniFi devices, telemetry, and configuration workflows. |
| Uptime Kuma | Status page and endpoint monitoring service for uptime checks and alerts. |
| Vaultwarden | Lightweight Bitwarden-compatible password manager server. |
| Whiteboard | Collaborative whiteboard service primarily used by Nextcloud, which is currently its only client. |
| Elasticsearch | Search/index backend deployed primarily for Nextcloud, which is currently its only client. |
| Headscale | Self-hosted Tailscale-compatible coordination server for mesh VPN control. |
| Hypermind | Experimental peer-to-peer shared room/map/chat service exposed through the cluster ingress. |
| OPNsense service bridge | In-cluster service/ingress path to the external OPNsense router web UI/API endpoint. |
| TrueNAS service bridge | In-cluster service/ingress path to the external TrueNAS web UI endpoint. |
| Portfolio (prod) | Production personal website/application deployment. |
| Portfolio (staging) | Staging version of the portfolio for preview and validation before production rollout. |

## 1) Core platform foundation

### Kubernetes and GitOps

- Kubernetes control plane components (API server, scheduler, controller-manager, etcd) run on all 3 nodes.
- Argo CD is the deployment orchestrator for almost everything in this repo.
- Argo app-of-apps pattern is used: one root app fans out into many platform and workload apps.
- Namespaces are pre-created for logical separation: `ai`, `media`, `productivity`, `other`, `web`, plus platform namespaces like `security`, `service-mesh`, `rook-ceph`, `databases`, `backup`, and others.

### Cluster networking: Cilium + Hubble

- Cilium is the CNI and datapath (including kube-proxy replacement) for pod/service networking.
- Hubble Relay/UI are enabled for network flow visibility.
- Cilium is treated as day-0/bootstrap infrastructure (manual runbook-driven) rather than Argo-managed.

### North-south networking: MetalLB + HAProxy Ingress

- MetalLB advertises service IPs on LAN via L2.
- IP pool: `192.168.1.230-192.168.1.250` on interface `enp196s0`.
- HAProxy Ingress is the HTTP/HTTPS entrypoint, exposed via MetalLB at `192.168.1.230`.
- Two ingress classes are defined:
- `haproxy` (default/public-facing style)
- `haproxy-restricted` (used for internal/restricted apps, often with source allowlists)
- Shared ingress manifests route many hostnames to internal services (for example `chat.rcrumana.xyz`, `nextcloud.rcrumana.xyz`, `qbit.rcrumana.xyz`, `ceph.rcrumana.xyz`, `argocd.rcrumana.xyz`, etc.).

### TLS automation: cert-manager

- cert-manager is installed with HA replicas.
- Let’s Encrypt ClusterIssuers exist for staging and production, using Cloudflare DNS-01.
- A wildcard certificate for `*.k8s.rcrumana.xyz` is issued for ingress default TLS usage.

### Service mesh: Linkerd

- Linkerd is installed as multiple coordinated apps:
- CRDs, CNI plugin, control plane, identity/cert resources, and viz components.
- Linkerd CNI is used to avoid privileged init containers in meshed workloads.
- Linkerd identity and webhook certs are managed with cert-manager, with trust anchor material sourced via External Secrets.

### Traffic control and scheduling helpers

- `egress-qos` daemonset runs on each node and uses `tc`/iptables/ipset to shape egress for pods labeled `traffic-tier=bulk-seed`.
- This is specifically relevant to high-bandwidth torrent workloads in media stacks.
- Descheduler is installed as a periodic CronJob to rebalance/evict under policy constraints.

## 2) Security and secrets foundation

### Vault

- HashiCorp Vault runs as a 3-node HA Raft cluster in `security`.
- Vault storage is on Ceph (`ceph-block`, 10Gi per Vault pod).
- Vault UI is enabled (cluster-internal service; external access is typically through ingress or internal networking controls).

### External Secrets

- External Secrets Operator is installed in HA mode.
- `ClusterSecretStore` named `vault` points ESO to Vault (`http://vault.security.svc:8200`, KV v2).
- Most app credentials are not in Git; they are pulled from Vault and materialized as Kubernetes Secrets.

## 3) Storage, snapshots, and backups

### Primary storage: Rook/Ceph

- Rook operator is installed via Helm, then a Ceph cluster is defined via manifests.
- Ceph cluster is 3-mon / 2-mgr with OSDs spread across all 3 nodes (two NVMe devices per node are configured).
- Ceph networking is host-network based with:
- Public network: `192.168.1.0/24`
- Cluster/replication network: `172.16.100.0/24`
- Core storage interfaces exposed to Kubernetes:
- `ceph-block` (default StorageClass, RBD, RWO volumes)
- `ceph-filesystem` (CephFS, RWX volumes)
- Ceph dashboard is enabled and exposed via ingress (`ceph.rcrumana.xyz`).

### Volume snapshots

- CSI snapshot controller is installed.
- Default `VolumeSnapshotClass` is `ceph-block-snap` (RBD snapshots).

### Object storage endpoint for backups

- `other/minio` in this repo is a Kubernetes Service/Endpoints bridge to an external MinIO instance at `192.168.1.10`.
- Two internal services are provided:
- `minio` (console-style endpoint on 9002)
- `minio-api` (S3 API endpoint on 9000)
- Both are also published through restricted ingresses.

### Backup engines

- VolSync is installed in `backup`.
- VolSync replication sources are declared for `media`, `productivity`, and `other` namespaces.
- Pattern used:
- Snapshot-based copy from Ceph PVCs (`copyMethod: Snapshot`, `ceph-block-snap`)
- Restic repository stored in MinIO (credentials pulled from Vault)
- Retention profile is typically daily/weekly/monthly.
- CloudNativePG clusters also run scheduled backups to MinIO (`s3://cluster-backups/cnpg/...`) with 30-day retention.

## 4) Shared data platforms

### PostgreSQL platform (CloudNativePG)

- CNPG operator runs in `cnpg-system`.
- Five shared PostgreSQL clusters run in `databases` (all 3-instance HA):
- `pg-platform` (platform services)
- `pg-media` (media services)
- `pg-ai` (AI services)
- `pg-productivity` (productivity services)
- `pg-other` (other services)
- Each cluster provides read-write and read-only services (`*-rw`, `*-ro`, `*-r`).
- Persistent storage for all CNPG clusters uses Ceph block volumes.

### Redis platform (Redis Enterprise)

- Redis Enterprise operator is installed in `databases`.
- `RedisEnterpriseCluster` named `rec-platform` runs 3 nodes with Ceph-backed persistence.
- Two managed Redis databases are defined:
- `redis-cache` (cache semantics, LRU eviction)
- `redis-queue` (queue semantics, persistence enabled)

## 5) Workloads by namespace

## `ai` namespace

### LibreChat stack

- Main web app: `librechat` deployment and service.
- Embedded support services inside same namespace:
- MongoDB (`librechat-mongodb` statefulset)
- Meilisearch (`librechat-meilisearch` statefulset)
- RAG API (`librechat-rag-api` deployment, 2 replicas)
- Core behavior:
- User chat UI/API is served by LibreChat.
- RAG API uses `pg-ai-rw` (pgvector-style backend) and Redis.
- LLM calls are routed to local `llm-gateway` (in-cluster OpenAI-compatible endpoint).
- External access is via ingress at `chat.rcrumana.xyz`.
- Persistent data uses Ceph PVCs (`librechat-data`, Mongo data, Meilisearch data).

### Llama backend + gateway

- Three model-serving workers:
- `llama-static-a`
- `llama-static-b`
- `llama-swap` (dynamic model swap service)
- Front door for AI clients is `llm-gateway` (LiteLLM), exposed as cluster service `llm-gateway:4000`.
- Workers use AMD GPU resources (`amd.com/gpu`) and shared RWX model cache PVC (`llama-models-cache`, `ceph-filesystem`, 500Gi).
- Model artifacts are fetched/seeded from Hugging Face in init containers, using Vault-sourced tokens.
- This backend is consumed by LibreChat and can be consumed by other internal clients through OpenAI-compatible APIs.

## `media` namespace

### ARR ecosystem (arr, arr-lts, arr-lts2)

- There are three qBittorrent stacks in media:
- `arr-stack` (full media automation suite)
- `arr-lts` (qBittorrent + Gluetun)
- `arr-lts2` (qBittorrent + Gluetun)
- All three route qBittorrent traffic through a colocated Gluetun VPN container.
- Each stack also includes a `pf-sync` sidecar that continuously applies VPN-forwarded port changes into qBittorrent WebUI settings.
- `arr-stack` includes these additional services in one pod:
- `sonarr`, `radarr`, `lidarr`, `prowlarr`, `jellyseerr`, `flaresolverr`
- `arr-stack` also includes bootstrap logic to write Servarr PostgreSQL settings into config files.
- PostgreSQL dependency for media automation is `pg-media-rw` (for Servarr/Jellyseerr DBs).
- Media files are mounted from node host path `/NAS`; app configs are on Ceph PVCs.
- Ingresses expose major UIs: `qbit`, `qbit-lts`, `qbit-lts2`, `sonarr`, `radarr`, `lidarr`, `prowlarr`, `jellyseerr`.

### Jellyfin

- Runs as a dedicated deployment with Ceph-backed config PVC.
- Uses host media libraries (`/NAS/Torrent/...`) and `/dev/dri` for hardware acceleration.
- Exposed two ways:
- MetalLB LoadBalancer (`192.168.1.233`) for native client protocols
- HAProxy ingress (`jellyfin.rcrumana.xyz`) for browser/reverse-proxy access

### Plex

- Dedicated deployment similar to Jellyfin.
- Uses `/dev/dri` and host media paths.
- Ceph-backed config PVC.
- Exposed via MetalLB LoadBalancer (`192.168.1.232`) and ingress (`plex.rcrumana.xyz`).

### Immich

- Two deployments:
- `immich-server`
- `immich-machine-learning`
- `immich-machine-learning` runs the Immich ROCm image with direct host GPU device access (`/dev/kfd`, `/dev/dri`) and does not reserve `amd.com/gpu`
- Data dependencies:
- PostgreSQL on shared cluster `pg-media-rw`
- Redis on shared Redis Enterprise DB `redis-queue`
- Persistent volumes:
- `immich-photos` (1Ti, Ceph block)
- `immich-ml-cache` (4Gi, Ceph block)
- Exposed via MetalLB LoadBalancer (`192.168.1.234`) and ingress (`immich.rcrumana.xyz`).

## `productivity` namespace

### Nextcloud

- Deployed via Helm with custom values.
- Runs with integrated in-namespace PostgreSQL and Redis components (chart-managed), both backed by Ceph PVCs.
- Main app data PVC: `nextcloud-appdata` (Ceph block).
- External access via ingress `nextcloud.rcrumana.xyz`.
- Collabora is deployed separately and configured to integrate with Nextcloud for document editing.
- Includes seed/restore jobs for migration workflows (appdata, redis dump, postgres restore).

### Collabora

- `collabora/code` deployment for web-based office editing.
- Configured to trust/integrate with Nextcloud domain.
- Exposed via ingress `collabora.rcrumana.xyz`.

### Homarr

- Homarr app deployed from OCI Helm chart.
- Repo also defines supporting MySQL and Redis stateful workloads and related secrets.
- Homarr UI service is exposed via ingress `homarr.rcrumana.xyz`.
- Storage for MySQL/Redis is Ceph-backed.

### Homepage

- Homepage is deployed from plain Kubernetes manifests for fully declarative dashboard configuration.
- Runs as a 3-replica stateless deployment with a `minAvailable: 1` PodDisruptionBudget.
- Uses in-cluster RBAC to surface Kubernetes widgets and resource views.
- Restricted ingress exposes the proof-of-concept dashboard at `dash.rcrumana.xyz`.

### UniFi Controller

- `unifi-network-application` plus in-namespace MongoDB (`unifi-db`).
- Ceph-backed PVCs for controller config and DB.
- Exposed via MetalLB at `192.168.1.235` with split TCP and UDP LoadBalancer services.
- Restricted ingress (`unifi.rcrumana.xyz`) fronts the web UI path to TCP/8443.

### Uptime Kuma

- Status/monitoring dashboard service with Ceph-backed data PVC.
- Exposed via ingress `uptime.rcrumana.xyz`.

### Vaultwarden

- Self-hosted Bitwarden-compatible password vault.
- Ceph-backed data PVC.
- Exposed via ingress `vault.rcrumana.xyz`.

### Whiteboard

- `lovasoa/wbo` collaborative whiteboard service.
- In this cluster it is primarily for Nextcloud integration, and Nextcloud is currently the only intended client.
- Stateless deployment (no dedicated PVC in this repo).
- Exposed via ingress `whiteboard.rcrumana.xyz`.

### Elasticsearch

- Single-node Elasticsearch deployment for search/index workloads.
- In this cluster it is primarily for Nextcloud integration, and Nextcloud is currently the only intended client.
- Ceph-backed data PVC.
- ClusterIP service (no direct ingress in this repo).

## `other` namespace

### Headscale

- Self-hosted Tailscale control plane (`headscale`) with separate web UI (`headscale-ui`).
- Own PostgreSQL statefulset (`headscale-postgres`) with Ceph-backed storage.
- API and UI are published with different access profiles:
- API ingress on `headscale.rcrumana.xyz` via `haproxy` class
- UI under `/web` on same host via restricted ingress class
- Includes restore job for postgres migration workflows.

### Hypermind

- Small single-pod `hypermind` deployment for experimental shared chat/map rooms.
- Published on `hypermind.rcrumana.xyz` through restricted HAProxy ingress.
- Runs with host networking because upstream expects direct DHT/Hyperswarm socket access.

### MinIO service bridge

- Cluster-internal service wrappers around external MinIO (`192.168.1.10`).
- Used heavily as backup target for VolSync and CNPG.

### OPNsense and TrueNAS reverse-proxy bridges

- `opnsense-https` service points to external router (`192.168.1.1:4443`).
- `truenas-https` service points to external NAS (`192.168.1.10:443`).
- Both are surfaced through restricted HAProxy ingresses:
- `router.rcrumana.xyz`
- `nas.rcrumana.xyz`

## `web` namespace

### Portfolio sites

- `portfolio` (production) and `portfolio-staging` run as separate 3-replica deployments.
- Images are pulled from GHCR with Vault-sourced image pull secret.
- Exposed via ingresses:
- Production: `rcrumana.xyz`
- Staging: `staging.rcrumana.xyz`
- HAProxy annotations provide HTML path rewrite behavior for static site routing.

## 6) How the major pieces connect

- Argo CD continuously syncs all platform and application definitions from this repo.
- Vault stores secrets; External Secrets copies them into Kubernetes Secrets for apps.
- cert-manager issues TLS certs used by HAProxy ingresses.
- MetalLB provides LAN IPs for HAProxy and selected direct-exposure services (Plex/Jellyfin/Immich/UniFi).
- Rook/Ceph provides nearly all persistent storage (`ceph-block` and `ceph-filesystem`).
- Snapshot controller + VolSync protect many app PVCs to MinIO on a schedule.
- CNPG provides shared PostgreSQL clusters for platform/media/AI/productivity/other domains.
- Redis Enterprise provides shared cache/queue services used by some apps.
- AI path is: LibreChat -> RAG API/DB + LiteLLM gateway -> llama.cpp workers.
- Media automation path is: Servarr/Jellyseerr/Prowlarr -> qBittorrent (through Gluetun VPN) -> NAS media libraries -> Jellyfin/Plex playback.

## 7) Quick namespace index

- `argocd`: GitOps controllers.
- `kube-system`: Cilium/Hubble, DNS, control-plane static pods, AMD GPU device plugin, snapshot controller.
- `ingress-haproxy`: HAProxy ingress controller.
- `metallb-system`: MetalLB controller/speakers.
- `service-mesh`: Linkerd control plane and viz.
- `rook-ceph`: Ceph storage stack and CSI.
- `security`: Vault + External Secrets.
- `backup`: VolSync controller.
- `databases`: CNPG clusters + Redis Enterprise platform.
- `ai`: LibreChat and local LLM backend services.
- `media`: ARR stacks, Immich, Jellyfin, Plex.
- `productivity`: Nextcloud, Collabora, Homarr, Homepage, UniFi, Uptime Kuma, Vaultwarden, Whiteboard, Elasticsearch.
- `other`: Headscale, Hypermind, MinIO bridge, OPNsense/TrueNAS bridges.
- `web`: Portfolio prod/staging.

## Appendix A: Public ingress routing map

This table maps internet/LAN hostnames to the in-cluster service backends.

| Hostname | Path | Namespace | Ingress | Class | Backend service:port |
|---|---|---|---|---|---|
| `argocd.rcrumana.xyz` | `/` | `argocd` | `argocd` | `haproxy-restricted` | `argocd-server:80` |
| `ceph.rcrumana.xyz` | `/` | `rook-ceph` | `ceph-dashboard` | `haproxy-restricted` | `rook-ceph-mgr-dashboard:8443` |
| `collabora.rcrumana.xyz` | `/` | `productivity` | `collabora` | `haproxy-restricted` | `collabora:9980` |
| `headscale.rcrumana.xyz` | `/` | `other` | `headscale-api` | `haproxy` | `headscale:80` |
| `headscale.rcrumana.xyz` | `/web` | `other` | `headscale-ui` | `haproxy-restricted` | `headscale-ui:80` |
| `homarr.rcrumana.xyz` | `/` | `productivity` | `homarr` | `haproxy-restricted` | `homarr-helm:7575` |
| `hypermind.rcrumana.xyz` | `/` | `other` | `hypermind` | `haproxy-restricted` | `hypermind:80` |
| `immich.rcrumana.xyz` | `/` | `media` | `immich` | `haproxy-restricted` | `immich-server:2283` |
| `jellyfin.rcrumana.xyz` | `/` | `media` | `jellyfin` | `haproxy-restricted` | `jellyfin:8096` |
| `jellyseerr.rcrumana.xyz` | `/` | `media` | `jellyseerr` | `haproxy-restricted` | `jellyseerr:80` |
| `chat.rcrumana.xyz` | `/` | `ai` | `librechat` | `haproxy-restricted` | `librechat:80` |
| `lidarr.rcrumana.xyz` | `/` | `media` | `lidarr` | `haproxy-restricted` | `lidarr:80` |
| `minio.rcrumana.xyz` | `/` | `other` | `minio-proxy` | `haproxy-restricted` | `minio:9002` |
| `minio-api.rcrumana.xyz` | `/` | `other` | `minio-api-proxy` | `haproxy-restricted` | `minio-api:9000` |
| `nextcloud.rcrumana.xyz` | `/` | `productivity` | `nextcloud` | `haproxy-restricted` | `nextcloud:8080` |
| `router.rcrumana.xyz` | `/` | `other` | `opnsense-proxy` | `haproxy-restricted` | `opnsense-https:4443` |
| `plex.rcrumana.xyz` | `/` | `media` | `plex` | `haproxy-restricted` | `plex:32400` |
| `staging.rcrumana.xyz` | `/` | `web` | `portfolio-staging` | `haproxy` | `portfolio-staging:80` |
| `rcrumana.xyz` | `/` | `web` | `portfolio` | `haproxy` | `portfolio:80` |
| `prowlarr.rcrumana.xyz` | `/` | `media` | `prowlarr` | `haproxy-restricted` | `prowlarr:80` |
| `qbit-lts.rcrumana.xyz` | `/` | `media` | `qbit-lts` | `haproxy-restricted` | `qbit-lts:80` |
| `qbit-lts2.rcrumana.xyz` | `/` | `media` | `qbit-lts2` | `haproxy-restricted` | `qbit-lts2:80` |
| `qbit.rcrumana.xyz` | `/` | `media` | `qbit` | `haproxy-restricted` | `qbit:80` |
| `radarr.rcrumana.xyz` | `/` | `media` | `radarr` | `haproxy-restricted` | `radarr:80` |
| `sonarr.rcrumana.xyz` | `/` | `media` | `sonarr` | `haproxy-restricted` | `sonarr:80` |
| `nas.rcrumana.xyz` | `/` | `other` | `truenas-proxy` | `haproxy-restricted` | `truenas-https:443` |
| `unifi.rcrumana.xyz` | `/` | `productivity` | `unifi` | `haproxy-restricted` | `unifi-tcp:8443` |
| `uptime.rcrumana.xyz` | `/` | `productivity` | `uptime-kuma` | `haproxy-restricted` | `uptime-kuma:80` |
| `vault.rcrumana.xyz` | `/` | `productivity` | `vaultwarden` | `haproxy-restricted` | `vaultwarden:80` |
| `whiteboard.rcrumana.xyz` | `/` | `productivity` | `whiteboard` | `haproxy-restricted` | `whiteboard:80` |

## Appendix B: Direct `LoadBalancer` services (LAN IP map)

These services receive direct MetalLB-assigned LAN IPs (not only ingress host routing).

| Namespace | Service | External IP | Ports |
|---|---|---|---|
| `ingress-haproxy` | `haproxy-ingress` | `192.168.1.230` | `80/TCP`, `443/TCP` |
| `media` | `plex` | `192.168.1.232` | `32400/TCP` |
| `media` | `jellyfin` | `192.168.1.233` | `8096/TCP`, `8920/TCP`, `7359/UDP` |
| `media` | `immich-server` | `192.168.1.234` | `2283/TCP` |
| `productivity` | `unifi-tcp` | `192.168.1.235` | `8443/TCP`, `8080/TCP`, `8843/TCP`, `8880/TCP`, `6789/TCP` |
| `productivity` | `unifi-udp` | `192.168.1.235` | `3478/UDP`, `10001/UDP`, `1900/UDP`, `5514/UDP` |

## Appendix C: External service bridges (in-cluster service to external endpoint)

These are Kubernetes Services/Endpoints that front systems running outside Kubernetes.

| Namespace | Service | External target | Purpose |
|---|---|---|---|
| `other` | `minio` | `192.168.1.10:9002` | MinIO console/service endpoint for backup workflows and admin access. |
| `other` | `minio-api` | `192.168.1.10:9000` | MinIO S3 API endpoint used by CNPG backups and VolSync restic repositories. |
| `other` | `opnsense-https` | `192.168.1.1:4443` | Reverse-proxied access path to OPNsense. |
| `other` | `truenas-https` | `192.168.1.10:443` | Reverse-proxied access path to TrueNAS. |
