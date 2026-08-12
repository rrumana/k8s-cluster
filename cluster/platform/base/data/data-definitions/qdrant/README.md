# Qdrant cluster

This directory supplements the official Qdrant Helm chart with the resources
needed to integrate a three-peer test cluster into this repository. Qdrant is
deployed as an internal-only service in `databases`; it has no Ingress or
`LoadBalancer` endpoint.

## Posture

- Qdrant chart and runtime images are pinned and served by Harbor.
- Three peers are placed one per `eva-*` storage node.
- Each peer has a 50 GiB Ceph RBD data PVC and a separate 50 GiB snapshot PVC.
- New collections default to two replicas, one acknowledged write, and two
  shards per node. A client can deliberately override those values per
  collection.
- The admin and read-only API keys come from Vault through External Secrets.
- REST, external gRPC, and peer traffic use a private cert-manager CA. CORS,
  telemetry, and recovery from arbitrary URLs are disabled.
- NetworkPolicy permits peer traffic, Prometheus scraping, and clients that
  opt in with `qdrant.rcrumana.xyz/client: "true"` on their pod template.
- Prometheus scrapes each peer over HTTPS and alerts on lost targets,
  consensus degradation, inactive replicas, and stalled consensus work. The
  `Qdrant Cluster` Grafana dashboard covers peer, request, collection, memory,
  and PVC health.
- The VPA is recommendation-only and the PDB permits at most one voluntarily
  unavailable peer.
- VolSync definitions mirror the other persistent database resources. They
  inherit the repository-wide safety pause until backup targets are replaced.

This is the upstream community chart, not the commercial Qdrant Enterprise
Operator. The operator is the natural future step if its license, private
artifacts, and support model are adopted. The chart is suitable for validating
Qdrant clustering and client behavior, but upgrades, certificate rollouts, and
collection lifecycle remain GitOps/operator-run operations.

## Prerequisites

Before the first Argo sync, run `scripts/seed-qdrant-prereqs.sh` from a trusted
administrator workstation. It creates `kv/apps/databases/qdrant-api-keys` only
when absent, pushes chart `qdrant:1.18.2` to `thirdparty-charts`, and mirrors the
pinned Qdrant and Helm-test images. It refuses to replace existing API keys.

The script requires `kubectl`, `helm`, `crane`, `jq`, and `openssl`, plus:

```bash
export HARBOR_PASSWORD='<Harbor push credential>'
scripts/seed-qdrant-prereqs.sh
```

The default Vault token file is `vault-init.json` at the repository root; use
`VAULT_INIT_FILE` to select another file. The file and generated key values are
never printed.

## Client contract

REST and gRPC clients use these internal endpoints:

- `https://qdrant.databases.svc.cluster.local:6333`
- `qdrant.databases.svc.cluster.local:6334` with TLS

A client needs all of the following:

1. Its pod template carries `qdrant.rcrumana.xyz/client: "true"`.
2. Its namespace receives an ExternalSecret for a purpose-specific credential.
   Do not share the cluster admin key with an ordinary application.
3. It trusts `ca.crt` from `Secret/qdrant-tls`, distributed into the client
   namespace through the secret authority rather than copied into Git.
4. It creates collections with an explicit replication and write-consistency
   policy when the defaults in `values.yaml` are not appropriate.

## Read-only verification

After Argo reports the application healthy:

```bash
kubectl -n databases get statefulset,pod,service,pvc -l app.kubernetes.io/instance=qdrant
kubectl -n databases get certificate qdrant-internal-ca qdrant-tls
kubectl -n databases get externalsecret qdrant-api-keys
kubectl -n databases get servicemonitor,prometheusrule qdrant
kubectl -n databases logs statefulset/qdrant --tail=100
```

Expected state is three ready peers on three different storage nodes, six bound
PVCs, ready certificates and ExternalSecret, and three healthy Prometheus
targets. Inspect the Qdrant dashboard/API only through an authenticated,
temporary local port-forward; no external route is declared.

cert-manager rotates the leaf certificate. Qdrant reloads the REST certificate
from disk, but its gRPC and peer transports require a controlled rolling restart
after renewal. Plan that restart through GitOps before the old certificate
expires, and confirm all three peers and collection replicas recover between
pods. Vault API-key changes also enter the pods through environment variables
and require a restart. Increment
`podAnnotations.qdrant.rcrumana.xyz/rollout-revision` in `values.yaml` to request
either rollout declaratively.
