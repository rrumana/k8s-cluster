# kube-vip API VIP

This cluster uses kube-vip static pods to advertise the Kubernetes API VIP.

- VIP: `192.168.1.11`
- DNS: `k8s-api.lab.home`
- Interface: `enp196s0`
- Mode: ARP with leader election
- Scope: control-plane VIP only; MetalLB still handles `LoadBalancer` services

The manifest in this directory is intentionally not applied by Argo CD. It uses
a dedicated local kubeconfig on each control-plane node:

```bash
sudo cp -a /etc/kubernetes/admin.conf /etc/kubernetes/kube-vip.conf
sudo sed -i 's#server: https://.*:6443#server: https://kubernetes:6443#' \
  /etc/kubernetes/kube-vip.conf
```

The pod maps `kubernetes` to `127.0.0.1`, which avoids a dependency loop where
kube-vip must use the VIP in order to elect the next VIP holder.

The static pod manifest must exist on each control-plane node at:

```text
/etc/kubernetes/manifests/kube-vip.yaml
```

Install or repair it on each control-plane node with:

```bash
sudo install -m 0644 -o root -g root \
  cluster/bootstrap/kube-vip/kube-vip.yaml \
  /etc/kubernetes/manifests/kube-vip.yaml
```

Verify:

```bash
kubectl -n kube-system get pods -o wide | grep kube-vip
kubectl -n kube-system get lease plndr-cp-lock -o wide
curl -k https://192.168.1.11:6443/readyz
```

`k8s-api.lab.home` must resolve to `192.168.1.11`. Do not use
`https://192.168.1.11:6443` in kubeconfigs unless the apiserver certificate is
regenerated with `IP:192.168.1.11` in its SAN list.
