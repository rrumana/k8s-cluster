# Vault add-before-remove migration runbook

This kustomization creates a second, permanent three-member Vault StatefulSet
whose PVCs use `ceph-block-app-replicated`. It is intentionally isolated from
the canonical Vault client services until the new Raft members have joined,
unsealed, caught up, and been promoted through Git.

Committing the Argo Application is an activation: Argo will create the
StatefulSet, three 10 GiB PVCs, its headless peer-discovery Service, ConfigMap,
and PodDisruptionBudget. The empty target pods are expected to be sealed,
uninitialized, NotReady, and leave the Application Progressing until an
operator joins and unseals them. **Never run `vault operator init` in a target
pod.** Doing so would create a separate Vault cluster on that PVC.

## Isolation and immutable identity

- Canonical Services created by the Vault chart select
  `app.kubernetes.io/instance=vault`, `app.kubernetes.io/name=vault`, and
  `component=server`.
- Target pods initially use the literal label `component=server-migration`, so neither the API,
  UI, active, nor standby Service can send client traffic to them.
- The StatefulSet, headless Service, PDB, and required pod anti-affinity select
  `vault.rcrumana.xyz/generation=app-replicated`. The mutable `component` label
  is deliberately absent from the StatefulSet selector, allowing a later Git
  change from `server-migration` to `server` without replacing the StatefulSet
  or its PVCs.
- The target members advertise cluster traffic through their own stable DNS
  names under
  `vault-app-replicated-internal.security.svc.cluster.local`. The headless
  Service publishes addresses before readiness so sealed members remain
  reachable for controlled joining and unsealing.
- The target reuses the chart-managed `vault` ServiceAccount and
  `harbor-pull-creds`. Do not delete the original Vault Application until
  ownership of those shared resources and the canonical Services has been
  moved to reviewed Git manifests.

The container image, command, probes, security contexts, lifecycle hook,
storage config, and `OnDelete` strategy mirror the live proven Vault
StatefulSet. Required target-to-target anti-affinity is scoped to the new
generation. It intentionally permits one old and one new member to share a
node during the transition; forbidding that would make all target pods
unschedulable on the current three-node Vault topology.

## Hard prerequisites

Do not activate this Application unless all of the following are true:

1. Ceph is healthy and all PGs are active and clean.
2. All three current Vault members are Ready, unsealed, and present as healthy
   voters in `vault operator raft list-peers` and
   `vault operator raft autopilot state`.
3. The operator has the current unseal threshold (currently two Shamir key
   shares) and an authorized Vault token. Keep secrets out of manifests,
   command arguments, shell history, terminal transcripts, and this runbook.
4. The three known-good replicated recovery copies remain available. The
   offsite backup pause and the decision to forgo a recovery drill are explicit
   operator-accepted risks, not evidence that recovery is unnecessary.
5. No node drain, reboot, Ceph maintenance, or other Vault rollout overlaps
   the membership change.

The uncommitted `storageClass` change in the original chart Application is not
a data migration: StatefulSet volume claim templates are immutable, and the
existing `data-vault-{0,1,2}` claims remain on `ceph-block`. Do not rely on that
edit to move any data.

## Phase 1: provision and prove target identity

After the Argo Application is committed and synced, require exactly three
Bound target claims and verify every PV before joining a member:

```sh
kubectl -n security get statefulset,pod,pvc,service,pdb \
  -l vault.rcrumana.xyz/generation=app-replicated -o wide
kubectl -n security get pvc \
  -l vault.rcrumana.xyz/generation=app-replicated \
  -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,SC:.spec.storageClassName,VOLUME:.spec.volumeName
```

Each claim must be Bound with `storageClassName:
ceph-block-app-replicated`; inspect each PV's CSI attributes as well. Require
all three target pods to be scheduled on different nodes. Sealed target pods
being `0/1 Running` is expected at this point. Confirm the canonical Services
still expose only old `vault-*` pod endpoints before continuing.

## Phase 2: join and unseal one target at a time

Use a local interactive shell that does not persist the token or key shares.
For each ordinal in order (`0`, `1`, `2`), join the existing cluster first and
then provide the unseal threshold interactively:

```sh
TARGET=vault-app-replicated-0
kubectl -n security exec "$TARGET" -- \
  vault operator raft join \
  http://vault-active.security.svc.cluster.local:8200
kubectl -n security exec -it "$TARGET" -- vault operator unseal
kubectl -n security exec -it "$TARGET" -- vault operator unseal
kubectl -n security wait --for=condition=Ready "pod/$TARGET" --timeout=5m
```

After every individual join, use an authenticated session on the current
leader to require all of these before starting the next ordinal:

- the new node ID is exactly `vault-app-replicated-N`;
- its advertised address uses
  `vault-app-replicated-N.vault-app-replicated-internal.security.svc.cluster.local:8201`;
- it is a healthy voter, not lagging, and Autopilot reports healthy;
- the original three voters remain healthy;
- Vault client requests and External Secrets remain healthy.

Stop on a failed join, unexpected node ID/address, leadership churn, lagging
peer, sealed old member, loss of quorum, Ceph degradation, or client errors.
Do not retry by initializing, wiping, or deleting a PVC. Diagnose the member
and Raft state first.

## Phase 3: promote target pods to canonical Services

After all three target members are healthy voters, change only the pod-template
literal `component` label from `server-migration` to `server` in Git. The
qualified `app.kubernetes.io/component` label may be changed at the same time
for descriptive consistency, but it is not part of canonical Service routing.
Do not add either component label to the StatefulSet selector, generation
selector, headless Service selector, anti-affinity, or PDB selector.

The StatefulSet uses `OnDelete`, so the Git change does not restart a Vault
member automatically. After the desired labels are committed and synced,
patch the same two labels on each already-running target pod one at a time.
This is a live convergence action to an already-committed desired state, and
avoids restarting healthy voters merely to change Service membership. Require
healthy Raft state and correct Service endpoints after every pod label patch.

After all three label patches, inspect canonical API, active, standby, and UI
Service endpoints. Require all target pods to be eligible, exactly one healthy
leader, successful authenticated reads through the stable `vault.security.svc`
address, and healthy External Secrets. Do not retire an old member until this
gate passes.

After the source voters are retired, replace the target pods one at a time so
they adopt the final `OnDelete` controller revision. Unseal and fully gate each
replacement before moving to the next ordinal.

## Phase 4: retire old members without dropping below quorum

Scale the original Helm StatefulSet down through Git by setting
`server.ha.replicas`; never delete an old pod while its ordinal remains desired.
StatefulSet scale-down removes the highest ordinal first, so the required order
is `vault-2`, `vault-1`, then `vault-0`:

1. Verify every current voter and application health. If the next ordinal is
   leader, step it down and prove that a target member became the healthy
   leader before scaling.
2. Change the source replica count by exactly one in Git and wait for that old
   pod to terminate. Do not change target replicas.
3. From the healthy leader, remove exactly that departed node ID with
   `vault operator raft remove-peer`.
4. Require the departed ID to be absent, all remaining members to be healthy
   voters, Autopilot healthy, a stable target leader, and canonical client
   requests successful before proceeding.

With all three target voters joined first, each old-member removal retains a
quorum. Do not batch source scale-downs or peer removals. Before the final
`1 -> 0` source scale, explicitly require leadership on a target member.

Preserve the three old PVCs for a rollback/recovery soak. Once an old peer has
been removed from the Raft configuration, its retained data directory is stale
and must not simply be started beside the live cluster. Reintroducing it
requires a separately reviewed reset/rejoin or recovery procedure.

## Cleanup gates

This kustomization contains no old-PVC or old-pool deletion mechanism. Cleanup
is a separate destructive GitOps phase and requires all of the following:

- the target has survived the agreed rollback soak, restart/unseal checks, and
  a controlled leader transition;
- all three target PVC/PV identities still resolve to
  `ceph-block-app-replicated`;
- the source StatefulSet is at zero and none of the old PVCs has an attachment
  or RBD watcher;
- no live PV, snapshot, clone, backup scratch volume, or workload references
  `ceph-block` unexpectedly;
- the shared ServiceAccount, canonical Services, and any remaining chart-owned
  resources have explicit durable ownership before the old Application is
  removed;
- Ceph reports that the legacy pool no longer supports live data.

Only then should a reviewed GitOps cleanup job remove retained source claims
and RBD images, followed by the separately gated legacy pool deletion.
