# Cilium Bootstrap Runbook (k8s-homelab-2)

This cluster treats Cilium as **day-0 infrastructure** (installed manually), not managed by ArgoCD.

Why:
- If Cilium (CNI) is broken, ArgoCD cannot reliably self-heal it because Argo itself depends on cluster networking.
- This runbook provides a reproducible “break-glass” path that can bring the cluster back without GitOps.

The file `cluster/platform/base/networking/cilium/values.yaml` is kept as **in-repo documentation** for the intended end state.

## Prereqs

- You are on a control-plane node with admin access and `kubectl` works (usually via `/etc/kubernetes/admin.conf`).
- `helm` has the Cilium repo available:
  - `helm repo add cilium https://helm.cilium.io/`
  - `helm repo update`

## 1) Install a *minimal* Cilium (safe baseline)

Install Cilium without kube-proxy replacement first (keep kube-proxy working during the initial bring-up).

```bash
helm upgrade --install cilium cilium/cilium \
  --namespace kube-system \
  --version 1.18.4 \
  --set cluster.name=k8s-homelab \
  --set cluster.id=1 \
  --set k8sServiceHost=k8s-api.lab.home \
  --set k8sServicePort=6443
```

Wait for readiness:

```bash
kubectl -n kube-system rollout status ds/cilium --timeout=10m
kubectl -n kube-system get pods -l k8s-app=cilium -o wide
```

## 2) Apply the “known-good” `cilium-config` patch (enables kube-proxy replacement)

This is the critical step that flips the runtime configuration in the source-of-truth that the agent consumes:
`ConfigMap/kube-system/cilium-config`.

```bash
kubectl -n kube-system patch configmap cilium-config --type merge -p '{
  "data": {
    "cluster-id": "1",
    "cluster-name": "k8s-homelab",
    "routing-mode": "native",
    "auto-direct-node-routes": "true",
    "ipv4-native-routing-cidr": "10.44.0.0/16",
    "ipam": "kubernetes",

    "kube-proxy-replacement": "true",
    "enable-node-port": "true",

    "enable-bpf-masquerade": "true",
    "enable-ipv4-masquerade": "true",
    "enable-ipv6-masquerade": "false"
  }
}'
```

## 2.1) Linkerd CNI: stop Cilium from overwriting `05-cilium.conflist`

If you use the Linkerd CNI plugin (`linkerd2-cni`), you must prevent Cilium
from rewriting `/etc/cni/net.d/05-cilium.conflist` after Linkerd patches it.

First, set:

```bash
kubectl -n kube-system patch configmap cilium-config --type json -p '[
  {"op":"add","path":"/data/custom-cni-conf","value":"true"}
]'
```

Then remove the write-on-ready key (this is what rewrites the file):

```bash
kubectl -n kube-system patch configmap cilium-config --type json -p '[
  {"op":"remove","path":"/data/write-cni-conf-when-ready"}
]'
```

If present, also remove `cni-exclusive` (or set it to `"false"`), since Cilium
is no longer responsible for owning the directory:

```bash
kubectl -n kube-system patch configmap cilium-config --type json -p '[
  {"op":"remove","path":"/data/cni-exclusive"}
]'
```

Restart Cilium components to pick up the updated config:

```bash
kubectl -n kube-system rollout restart ds/cilium
kubectl -n kube-system rollout restart deploy/cilium-operator
kubectl -n kube-system rollout status ds/cilium --timeout=10m
kubectl -n kube-system rollout status deploy/cilium-operator --timeout=10m
```

Verify:

```bash
kubectl -n kube-system exec ds/cilium -- cilium-dbg status --verbose
```

You should see:
- `KubeProxyReplacement: True`
- `KubeProxyReplacement Details -> NodePort: Enabled`
- `Masquerading: BPF ... [IPv4: Enabled]`

## 3) (Optional) Remove kube-proxy after confirming replacement is active

Only remove kube-proxy *after* `cilium-dbg status --verbose` confirms kube-proxy replacement is `True`.

If kube-proxy was installed by kubeadm (typical), you can remove it by deleting the DaemonSet:

```bash
kubectl -n kube-system delete ds kube-proxy
```

## Recovery notes

- If you ever lose Service routing (webhooks time out, `.svc` resolution works but connections hang), reinstalling kube-proxy is the fastest stabilizer:

```bash
sudo kubeadm config view --kubeconfig /etc/kubernetes/admin.conf > /tmp/kubeadm-config.yaml
sudo kubeadm init phase addon kube-proxy --config /tmp/kubeadm-config.yaml
```
