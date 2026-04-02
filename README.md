# k8s-cluster

A live, bare-metal Kubernetes homelab run with GitOps and real workloads for family and friends.

## Live Lab, Real Data, Learning First

This project is for fun and for learning.

It is live and stores data that matters to me and to people I care about. That said it is backed up often and most of this data lives elsewhere.


## Cluster Details

### Nodes

| Node | Role | Internal IP | OS |
|---|---|---|---|
| `melchior-1` | control-plane | `192.168.1.13` | Arch Linux |
| `balthasar-2` | control-plane | `192.168.1.14` | Arch Linux |
| `casper-3` | control-plane | `192.168.1.15` | Arch Linux |

### Hardware (identical per node)

- CPU: Ryzen 9 class APU (`12 cores / 24 threads`)
- GPU: Radeon 890M iGPU
- RAM: `96 GB` total (`48 GB` system + `48 GB` reserved for GPU memory)
- Boot disk: `1 x 1 TB` SSD
- Ceph disks: `2 x 2 TB` SSD per node

Cluster storage math:

- Raw Ceph device pool: `12 TB` (6 drives total)
- Effective usable (3x replication): about `4 TB`

## Architecture At A Glance

```text
                        Git push
                           |
                           v
                    Argo CD (root app)
                           |
        -----------------------------------------
        |                    |                  |
        v                    v                  v
   Platform apps         Data platform      Workload apps
 (networking, mesh,      (Postgres, Redis,  (AI, media,
  ingress, certs,        backups, Ceph)      productivity, web)
  security)

Ingress path:
Internet/LAN -> Cloudflare DNS -> MetalLB VIP (HAProxy) -> Ingress -> Services

Data path:
Apps -> Ceph PVCs / CNPG / Redis -> Snapshots + VolSync -> MinIO (external bridge)
```

## Platform Foundation

| Area | Implementation | Notes |
|---|---|---|
| Networking | Cilium + Hubble | eBPF datapath, kube-proxy replacement, flow visibility |
| North-south traffic | MetalLB + HAProxy Ingress | LB range `192.168.1.230-192.168.1.250`, HAProxy service pinned to `192.168.1.230` |
| TLS | cert-manager + Let's Encrypt DNS-01 | Cloudflare-backed issuers (`letsencrypt-prod`, `letsencrypt-staging`) |
| Service mesh | Linkerd (CRDs + CNI + control plane + viz) | CNI mode avoids init container `NET_ADMIN` needs in meshed workloads |
| Secrets | Vault (HA Raft) + External Secrets | Secrets stay in Vault, synced into K8s secrets at runtime |
| Storage | Rook/Ceph | `ceph-block` default StorageClass, `ceph-filesystem` for RWX workloads |
| Snapshots | CSI Snapshot Controller | Default snapshot class `ceph-block-snap` |
| Backups | VolSync + CNPG native backups | Snapshot + restic to MinIO for PVCs; CNPG to S3-compatible MinIO |
| Shared SQL | CloudNativePG | 5 x HA Postgres clusters (`pg-ai`, `pg-media`, `pg-platform`, `pg-productivity`, `pg-other`) |
| Shared Redis | Redis Enterprise | 3-node `rec-platform` with `redis-cache` and `redis-queue` databases |
| Egress shaping | `egress-qos` DaemonSet | Shapes pods labeled `traffic-tier=bulk-seed` (media torrent workloads) |

## Storage And Data Durability

### Ceph

- 3-node Rook/Ceph cluster
- OSDs on two dedicated SSDs per node
- Block pool replication: `size: 3`
- CephFS data pool replication: `size: 3`
- Designed for resilience first, capacity second

### Backups

- VolSync replication sources exist across `media`, `productivity`, and `other` namespaces
- Copy method: CSI snapshots (`ceph-block-snap`) plus restic push to MinIO
- Typical retention: `daily 7 / weekly 4 / monthly 3`
- CNPG clusters back up to `s3://cluster-backups/cnpg/*` via `minio-api.other.svc.cluster.local:9000`
- CNPG retention policy: `30d`

### External Service Bridges

The cluster also defines service bridges to systems outside Kubernetes:

- MinIO (`192.168.1.10:9000/9002`)
- OPNsense (`192.168.1.1:4443`)
- TrueNAS (`192.168.1.10:443`)

## Workloads By Domain

For the full app catalog and ingress maps, read `docs/apps.md`.

### `ai`

- LibreChat + MongoDB + Meilisearch + RAG API
- Local LLM backend (`llama-static-a`, `llama-static-b`, `llama-swap`) using AMD GPU resources
- LiteLLM gateway (`llm-gateway`) provides an OpenAI-compatible endpoint for internal clients
- Shared RWX model cache PVC (`500Gi`, CephFS)

### `media`

- `arr-stack` (qBittorrent + Servarr + Jellyseerr + FlareSolverr + Gluetun + pf-sync)
- `arr-lts` and `arr-lts2` for isolated long-term qBittorrent workflows
- Jellyfin, Plex, and Immich
- Media libraries mounted from host path `/NAS`

### `productivity`

- Nextcloud + Collabora
- Homarr
- UniFi Network Application
- Uptime Kuma
- Vaultwarden
- Whiteboard
- Elasticsearch (currently used by Nextcloud)

### `other`

- Headscale + Headscale UI
- MinIO, OPNsense, and TrueNAS ingress/service bridges

### `web`

- `portfolio` (production)
- `portfolio-staging` (preview environment)

## Exposure Model

### Ingress classes

- `haproxy`: default ingress class
- `haproxy-restricted`: restricted/internal exposure profile

Many restricted ingresses use source allowlisting, for example:

`192.168.0.0/16,172.16.0.0/12,10.0.0.0/8`

### Direct LoadBalancer services (MetalLB)

| Service | External IP |
|---|---|
| `ingress-haproxy/haproxy-ingress` | `192.168.1.230` |
| `media/plex` | `192.168.1.232` |
| `media/jellyfin` | `192.168.1.233` |
| `media/immich-server` | `192.168.1.234` |
| `productivity/unifi-tcp` + `productivity/unifi-udp` | `192.168.1.235` |

## Contributing

Feel free to make pull requests. I'll probably close them immediately, but feel free to do it!

On a more serious note this setup is very personal and unique to my circumstances. I welcome insight on idiomatic Kubernetes, but unless you have a similar platform to test changes against I'd prefer insights to be raised as discussions/issues, not PRs.

## Further Reading

- `docs/vault-operations.md`
- `docs/apps.md`
