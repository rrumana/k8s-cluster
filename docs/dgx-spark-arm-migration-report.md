# Feasibility report: migrating this cluster to NVIDIA DGX Spark ARM nodes

Date: 2026-06-04

## Executive verdict

This cluster is feasible on a 100% ARM64 DGX Spark Kubernetes cluster, but not as a direct GitOps replay of the current repository. The base platform is viable: DGX Spark is an ARM64 Ubuntu 24.04-based DGX OS system, Kubernetes publishes multi-architecture control-plane images, Cilium supports AArch64, and NVIDIA's container/GPU stack supports ARM64 on Ubuntu 24.04. The risky part is the workload and supply-chain layer, not Kubernetes itself.

Current state: a straight migration would fail on several known items:

- Harbor is a hard blocker if kept in-cluster using upstream `goharbor/*` images. `docker manifest inspect --verbose goharbor/harbor-core:v2.15.1` reports `linux/amd64` only. Your live cluster depends heavily on `harbor.rcrumana.xyz/mirror/*` and proxy-cache paths.
- The AMD GPU stack must be replaced. The cluster has `rocm/k8s-device-plugin` pinned to `kubernetes.io/arch=amd64`, and AI workers request `amd.com/gpu`.
- `egress-qos` downloads `kubectl` from `bin/linux/amd64/kubectl` at runtime.
- The in-cluster Rook/Ceph cluster is tied to current x86 node names and local NVMe device IDs. You already called out external Ceph; that is not optional for this migration unless the storage design is rewritten.
- Host media paths and hardware acceleration assumptions are x86/current-host specific: `/NAS`, `/dev/dri`, `LIBVA_DRIVER_NAME=radeonsi`, privileged media containers, and AMD/VAAPI assumptions.
- Private/custom images are unknown until rebuilt or inspected: `apps-private/portfolio:*`, `mostlygeek/llama-swap:v174-vulkan`, `lemker/unifi-os-server:*`, and possibly `lklynet/hypermind:*`.

My recommendation is not a one-shot all-ARM cutover. Build a parallel ARM64 cluster, move infrastructure first, keep registry/storage off the new cluster until proven, then migrate apps by risk tier. A temporary mixed-architecture cluster is the lowest-risk migration pattern even if the desired end state is 100% ARM.

## Evidence gathered

Live cluster inventory, read-only:

- Nodes: three `amd64` Arch Linux control-plane nodes, Kubernetes v1.35.4, containerd 2.3.0, about 24 allocatable CPUs and 48 GiB RAM per node.
- Storage: default `ceph-block` plus `ceph-filesystem`, both served by in-cluster Rook/Ceph.
- Workloads: GitOps-managed apps across AI, media, productivity, observability, registry, security, service mesh, and storage namespaces.
- Unique image list includes Kubernetes core images, Cilium, Linkerd, Rook/Ceph, Harbor, CloudNativePG, OpenSearch, Elasticsearch, Immich, LinuxServer.io media stack, Collabora, UniFi OS Server, LibreChat, LiteLLM, and private portfolio images.

Target platform facts from NVIDIA:

- DGX Spark has a 20-core Arm processor, 128 GB unified system memory, 10 GbE, ConnectX-7, and Blackwell GPU with NVENC/NVDEC.
- NVIDIA's DGX Spark porting guide describes DGX OS as Ubuntu 24.04 LTS plus NVIDIA drivers, libraries, frameworks, and tools.
- NVIDIA documents Spark as ARM64 with unified CPU/GPU memory. That is good for AI, but it changes assumptions for workloads that expect x86 plus a discrete GPU and conventional PCIe GPU memory behavior.

Sources:

- NVIDIA DGX Spark hardware guide: https://docs.nvidia.com/dgx/dgx-spark/hardware.html
- NVIDIA DGX Spark porting guide: https://docs.nvidia.com/dgx/dgx-spark-porting-guide/overview.html
- NVIDIA Container Toolkit platform support: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/supported-platforms.html
- NVIDIA GPU Operator platform support: https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/platform-support.html
- Kubernetes image architecture docs: https://kubernetes.io/releases/download/
- Kubernetes node architecture labels: https://v1-35.docs.kubernetes.io/docs/reference/node/node-labels/
- Cilium system requirements: https://docs.cilium.io/en/stable/operations/system_requirements/
- Docker multi-platform image behavior: https://www.docker.com/blog/docker-official-images-now-multi-platform/
- NVIDIA Spark dependency support matrix: https://docs.nvidia.com/dgx/dgx-spark-porting-guide/porting/dependencies.html
- NVIDIA Spark CUDA/GPUDirect RDMA note: https://docs.nvidia.com/dgx/dgx-spark-porting-guide/porting/cuda.html
- Harbor ARM issue: https://github.com/goharbor/harbor/issues/21125
- Harbor proxy-cache multi-arch issue: https://github.com/goharbor/harbor/issues/20920

## Platform layer assessment

### Kubernetes

Kubernetes itself is not the blocker. Kubernetes publishes container images for multiple architectures and the container runtime chooses the matching platform. Kubernetes also labels nodes with `kubernetes.io/arch`, which is how workloads and DaemonSets should constrain architecture-specific pieces.

The current Cilium pins are safe from the most obvious digest issue. I checked the exact digest-pinned Cilium, Cilium operator, Cilium Envoy, and Hubble Relay references used live; each returned both `linux/amd64` and `linux/arm64` in the manifest list.

### CNI and service mesh

Cilium is viable. Cilium documents support for AMD64 and AArch64 hosts with Linux kernel >= 5.10. DGX OS' Ubuntu 24.04/NVIDIA kernel should clear that bar, but Cilium must still be tested against the DGX Spark kernel and NIC layout.

Linkerd is likely viable. The live Linkerd proxy image `cr.l5d.io/linkerd/proxy:edge-26.3.3` returned `linux/amd64` and `linux/arm64` in manifest inspection. The rest of the Linkerd images should still be checked at the exact tags before cutover.

### NVIDIA GPU enablement

This is a rewrite from AMD to NVIDIA, not a minor patch:

- Remove `rocm/k8s-device-plugin`.
- Add NVIDIA GPU Operator or NVIDIA device plugin plus container toolkit integration.
- Replace `amd.com/gpu` resource requests with `nvidia.com/gpu`.
- Replace ROCm/Vulkan llama images with CUDA-capable ARM64 images.
- Revalidate model serving frameworks on DGX Spark's Blackwell/ARM64 stack.

NVIDIA's Spark dependency matrix says many core AI packages are supported, but not all. CUDA Toolkit support starts at 13.0 for Spark in the matrix, cuDNN at 9.11, TensorRT at 10.14.1, TensorRT-LLM at 1.2, RAPIDS at 25.10, and Deep Learning Frameworks at 25.09. Some packages are explicitly not supported on Spark, including cuCIM, CV-CUDA, HPC SDK, DOCA, Nsight Graphics, and TensorRT for RTX.

Also note the DGX Spark CUDA caveat: NVIDIA says GPUDirect RDMA is not supported on Spark. That probably does not affect this current homelab app set directly, but it matters if you plan high-performance distributed GPU workloads across the three nodes.

## Known blockers and required GitOps changes

### 1. Harbor registry and proxy cache

Severity: hard blocker for all-ARM if Harbor remains in-cluster unchanged.

Evidence:

- Live workloads use many `harbor.rcrumana.xyz/mirror/*`, `proxy-dockerhub/*`, `proxy-ghcr/*`, and private app image references.
- Upstream `goharbor/harbor-core:v2.15.1` inspected as `linux/amd64` only.
- Harbor upstream has a closed "Harbor on arm64" issue marked not planned.
- Harbor proxy cache also has open concerns around multi-architecture image indexes.

Options:

- Keep Harbor on x86 outside the new ARM cluster.
- Replace Harbor with an ARM-friendly registry path for the migration, such as plain `distribution/distribution`, zot, or another registry that publishes ARM64 images.
- Build and own a custom ARM64 Harbor fork/images, accepting the maintenance burden.
- Avoid in-cluster registry dependency during bootstrap and point workloads directly at upstream registries until the registry layer is solved.

### 2. AMD GPU assumptions

Severity: hard blocker for AI workload scheduling.

Evidence:

- `cluster/apps/ai/llama-backend/llama-static-a-deployment.yaml` requests and limits `amd.com/gpu: "1"`.
- The same pattern exists in the other llama backend deployments.
- `cluster/platform` has an AMD GPU device plugin DaemonSet pinned to `kubernetes.io/arch=amd64`.
- The llama image is `mostlygeek/llama-swap:v174-vulkan`, with `HSA_OVERRIDE_GFX_VERSION`, which is AMD/ROCm-specific.

Required change:

- Replace this with NVIDIA GPU Operator/device-plugin resources and CUDA/ARM64 model serving images. For llama.cpp-style serving, prefer a DGX Spark-tested CUDA image, or build a multi-arch CUDA ARM64 image yourself.

### 3. `egress-qos` hard-coded amd64 kubectl

Severity: definite ARM failure, easy fix.

Evidence:

- `cluster/platform/base/networking/egress-qos/configmap.yaml` downloads `https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl`.

Required change:

- Select `arm64` when `uname -m` is `aarch64` or `arm64`.
- Better: bake tools into a small multi-arch image instead of installing packages and downloading kubectl at pod start.

### 4. Storage topology

Severity: hard blocker for direct replay; separate migration project.

Evidence:

- `cluster/platform/base/storage/rook-ceph/cluster/ceph-cluster.yaml` lists current node names and `/dev/disk/by-id/*` device IDs.
- Live PVs are bound to `ceph-block` and `ceph-filesystem`.

Required change:

- Build external Ceph first.
- Convert the target cluster to external Ceph CSI/storageclasses.
- Migrate application data with backups/restores, VolSync/restic, or application-native dump/restore. Do not assume RBD image portability solves application-level consistency.

### 5. Host media and hardware paths

Severity: likely blocker for media workloads until redesigned.

Evidence:

- Plex/Jellyfin/Immich mount `/dev/dri`.
- Plex/Jellyfin mount `/NAS/Torrent/...` host paths.
- Jellyfin sets `LIBVA_DRIVER_NAME=radeonsi`.
- Arr stacks use `/dev/net/tun`, `/NAS`, privileged containers, and local temp host paths.

Required change:

- Replace AMD/VAAPI settings with NVIDIA-capable transcoding configuration, or explicitly run media workloads CPU-only.
- Replace hostPath `/NAS` with network storage, CephFS, NFS, SMB CSI, or another portable storage abstraction.
- Revalidate `/dev/net/tun` and VPN behavior on DGX OS.

## Container image assessment

Manifest inspection can identify images that cannot even be pulled on ARM64. It cannot prove the application works. An image can publish `linux/arm64` and still fail because of native plugins, JIT behavior, kernel expectations, GPU library paths, missing ARM dependencies, or data compatibility.

Local manifest checks on 2026-06-04:

| Component | Evidence | Assessment |
| --- | --- | --- |
| Kubernetes core images | `registry.k8s.io/kube-apiserver:v1.34.3` returned `linux/amd64`, `linux/arm64`, `ppc64le`, `s390x` | OK |
| Cilium exact pinned digests | Cilium, operator, Envoy, Hubble Relay exact live refs returned `linux/amd64` and `linux/arm64` | OK |
| Linkerd proxy | `cr.l5d.io/linkerd/proxy:edge-26.3.3` returned `linux/amd64` and `linux/arm64` | Likely OK, check all Linkerd images |
| Immich server | `ghcr.io/immich-app/immich-server:v2.7.5` returned `linux/amd64` and `linux/arm64` | Pull-compatible, app test needed |
| LinuxServer Plex | upstream `lscr.io/linuxserver/plex:1.42.2.10156-f737b826c-ls287` returned `linux/amd64` and `linux/arm64` | Pull-compatible, NVIDIA transcoding test needed |
| Collabora | `collabora/code:25.04.10.3.1` returned `linux/amd64`, `linux/arm64`, `ppc64le` | Pull-compatible |
| Elasticsearch | `docker.elastic.co/elasticsearch/elasticsearch:9.3.2` returned `linux/amd64`, `linux/arm64` | Pull-compatible, data/plugin test needed |
| OpenSearch | `opensearchproject/opensearch:3.4.0` returned `linux/amd64`, `linux/arm64` | Pull-compatible, data/plugin test needed |
| VectorChord CNPG image | `tensorchord/cloudnative-vectorchord:18.2` returned `linux/amd64`, `linux/arm64` | Pull-compatible, extension test required |
| Harbor core | `goharbor/harbor-core:v2.15.1` returned `linux/amd64` only | Not viable unchanged |
| `mostlygeek/llama-swap:v174-vulkan` | upstream Docker Hub denied/unauthorized; Harbor mirror returned no manifest through `docker manifest inspect` | Unknown, likely needs replacement anyway due AMD/Vulkan |
| `lemker/unifi-os-server:2026-03-31` | Docker Hub denied/unauthorized | Unknown |
| private portfolio images | private `harbor.rcrumana.xyz/apps-private/*` | Unknown, must be rebuilt/pushed as multi-arch |

High-confidence likely OK categories:

- Most Kubernetes ecosystem controllers written in Go: cert-manager, external-secrets, Argo CD, metrics-server, kube-state-metrics, descheduler, Prometheus operator, snapshot-controller, CSI sidecars. Still inspect exact tags before migration.
- Official language/base images such as Python, BusyBox, Alpine, Redis, Mongo, PostgreSQL often publish ARM64. Still inspect exact references because tags and mirrors can differ.
- Java services like OpenSearch/Elasticsearch generally publish ARM64, but plugins/native libraries and heap sizing need testing.

High-risk categories:

- Harbor and anything built from Photon-only upstream images.
- Custom/private images.
- GPU and media workloads.
- Anything using native browser automation, anti-bot bypass, or Chromium bundles, such as FlareSolverr-style containers.
- Anything with native database extensions, including vector search extensions, even if the image is multi-arch.

## Security and vulnerability implications

I did not find an inherent "ARM is less secure" problem. The security risks come from operational and supply-chain changes:

- Smaller test surface: some ARM64 images receive less real-world testing than amd64 images.
- Architecture-specific tags can lag behind amd64 tags, leading to older packages and CVEs if maintainers do not publish ARM64 promptly.
- Rebuilding custom ARM64 images shifts trust to your build pipeline. You need SBOMs, provenance, and vulnerability scanning for both amd64 and arm64 outputs.
- Harbor being unavailable on ARM removes your current registry, proxy-cache, and Trivy scanning path unless replaced or kept off-cluster.
- GPU Operator and NVIDIA runtime components run with elevated host privileges. This is normal for GPU Kubernetes, but it expands the node attack surface and must be kept current.
- Privileged workloads already exist (`egress-qos`, Arr VPN containers, Jellyfin, UniFi OS server, Linkerd CNI, storage components). Moving to ARM does not create those risks, but retesting them on a new kernel and driver stack is mandatory.
- QEMU/binfmt emulation for amd64 workloads on ARM should not be treated as a production solution. It is slower, more fragile, hard to support in Kubernetes, and especially poor for GPU/media workloads.

## Short-term downsides

- Migration time will be dominated by image validation, not Kubernetes installation.
- The registry layer must be solved before GitOps can converge cleanly.
- The AI stack must be rebuilt around NVIDIA CUDA/ARM64 and `nvidia.com/gpu`.
- Some apps will require restore rehearsals because architecture changes can expose native extension or binary cache assumptions.
- You lose current AMD media acceleration assumptions and must rework Plex/Jellyfin/Immich hardware acceleration.
- Debugging will be harder at first because failures will look like normal Kubernetes failures until you inspect image architecture, native dependencies, and device plugin resources.
- A full all-at-once cutover has a high chance of partial outage.

## Long-term downsides

- ARM64 self-hosting is much healthier than it used to be, but amd64 remains the default test path for many self-hosted projects.
- Niche containers may stop publishing ARM64 without warning.
- Private image builds must permanently become multi-arch or ARM-native.
- Some vendor docs and community answers will assume x86 paths, x86 package names, and x86 GPU driver layouts.
- DGX Spark is excellent for compact AI development, but it is not a conventional server platform. Watch thermals, power behavior, boot automation, firmware updates, remote management, and long-running cluster duty-cycle behavior.
- The 20 ARM cores per node are not equivalent to the current 24 x86 cores per node for all workloads. You gain memory capacity and NVIDIA acceleration, but CPU-bound apps may shift performance either direction.
- Unified memory is useful for AI, but it means CPU and GPU share the same 128 GB memory pool. Large model workloads can starve conventional services if not constrained.

## Practical migration plan

1. Build a parallel ARM64 Kubernetes cluster on one DGX Spark first.
2. Install only the base layer: kubeadm/kubelet/container runtime, Cilium, cert-manager, external-secrets, Argo CD, metrics-server, observability.
3. Solve registry before apps:
   - Preferred: keep current Harbor on x86 during migration.
   - Alternative: replace Harbor with an ARM64-compatible registry and update image references.
4. Connect external Ceph and verify RBD/CephFS provisioning, snapshots, restores, and VolSync behavior.
5. Add NVIDIA GPU Operator/device plugin and run CUDA validation workloads.
6. Port AI workloads from AMD/Vulkan/ROCm to NVIDIA CUDA/ARM64.
7. Rebuild private images as multi-arch and push manifest lists.
8. Migrate low-risk stateless apps first.
9. Migrate stateful apps with restore rehearsals: databases, Nextcloud, Vault, OpenSearch, Elasticsearch, Immich.
10. Migrate media stack last because it combines host paths, hardware devices, privileged networking, and large data paths.

## Recommended validation commands

Read-only image checks from a workstation:

```sh
docker manifest inspect IMAGE:TAG | jq -r '.manifests[]?.platform | [.os, .architecture, (.variant // "")] | @tsv'
docker manifest inspect --verbose IMAGE:TAG | jq '.Descriptor.platform'
```

Cluster inventory checks:

```sh
kubectl get nodes -o wide
kubectl get nodes -o json | jq -r '.items[] | [.metadata.name, .status.nodeInfo.architecture, .status.nodeInfo.osImage, .status.nodeInfo.kernelVersion] | @tsv'
kubectl get pods -A -o json | jq -r '[.items[] | (.spec.containers[]?.image, .spec.initContainers[]?.image)] | unique[]'
kubectl get deploy,statefulset,daemonset,cronjob -A -o json | jq -r '.items[] | [.metadata.namespace, .kind, .metadata.name, ((.spec.template.spec.nodeSelector // {}) | tostring), (([.spec.template.spec.containers[]?.image, .spec.template.spec.initContainers[]?.image] | unique | join(",")))] | @tsv'
```

ARM canary tests to run before cutover:

- Pull every exact image reference on an ARM64 node.
- Run every init container once.
- Restore each database/application backup into a disposable namespace.
- Run media transcoding tests for Plex, Jellyfin, and Immich.
- Run model-serving smoke tests on the NVIDIA GPU with the intended CUDA images.
- Verify Linkerd injection on ARM pods.
- Verify Cilium/Hubble datapath and service routing under load.
- Verify external Ceph failover, snapshot, restore, and RWX behavior.

## Direct answers

Would this cluster run on ARM?

Yes, after changes. Kubernetes, Cilium, Linkerd, most controllers, and many mainstream app images are ARM64-capable. The current repository will not converge unchanged on 100% ARM.

Can we tell which containers will and will not work?

We can tell three different levels:

- Pull impossible: no `linux/arm64` manifest or a digest pinned to amd64. Harbor core is confirmed here.
- Pull possible but unproven: manifest includes ARM64. This is most of the mainstream stack, but it still needs application tests.
- Unknown: private images, authenticated images, Harbor mirror/proxy quirks, custom images, GPU-specific images.

Every stateful app and every GPU/media app should still be independently verified. Manifest support is necessary, not sufficient.

What is the state of self-hosting/Kubernetes/containers on ARM?

ARM64 is now a first-class platform for Kubernetes and much of the container ecosystem. Docker official images and Kubernetes images are multi-platform, and many major self-hosted apps publish ARM64 images. The weak spots are still niche images, vendor appliances, browser-bundled apps, media/GPU workloads, registry/proxy tooling, and custom/private builds. A general-purpose ARM Kubernetes cluster is reasonable in 2026, but a 100% ARM homelab with AI, media, registry, Ceph, and many stateful apps still requires disciplined image auditing and canary testing.

