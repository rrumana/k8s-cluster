# Cluster email alerting

This is an outbound notification path: Prometheus rules → Alertmanager → Mailgun
→ the operator's chosen inbox. It does not grant remote cluster access, perform
repairs, or configure an assistant automation. The existing monitoring stack and
Mailgun domain are reused; no new monitoring service is deployed.

## What gets sent

- All firing `critical` alerts, with repeats every four hours while unresolved.
- Selected `warning` alerts: `CephHealthWarning`, `CephOSDDown`,
  `CephOSDNearFull`, `CephPoolNearFull`, `CephMgrPrometheusCollectorStalled`,
  unavailable nodes, and persistent-volume capacity/errors.
- Sustained pod and replica warnings only in `argocd`, `databases`, `identity`,
  `monitoring`, `rook-ceph`, and `security`.
- Resolution messages for those same routes.

`Watchdog`, `InfoInhibitor`, informational alerts, and other warnings go to the
empty receiver. Critical alerts suppress warning/info alerts with the same
namespace and alert name, preserving the chart's inhibition rules. Existing
Prometheus `for` durations remain unchanged. The 30-second group wait is batching,
not a replacement for a rule's persistence threshold. Warning repeats remain 12h.

Mail is grouped by namespace and alert name. The subject and plain-text body
include only explicitly selected resource labels and timing, plus fixed dashboard
and runbook links. Arbitrary annotations, other labels, internal generator URLs,
logs, and default HTML are excluded. Resource names still leave the cluster via
Mailgun and the selected mail provider. No addresses or credentials belong in Git.

## Secure prerequisites (operator action)

1. In the existing Mailgun domain, create a dedicated SMTP identity for Alertmanager.
   Follow the per-app isolation in `docs/identity-access-runbook.md`; do not reuse
   Authentik, Nextcloud, Immich, or Vaultwarden credentials. The proposed From
   address is `alerts@mail.rcrumana.xyz`; verify it against the configured domain.
2. Through your secure Vault workflow, create KV v2 path
   `kv/apps/monitoring/alertmanager` with properties `smtp-username`,
   `smtp-password`, `smtp-from`, and `smtp-to`. The last is your chosen recipient.
   Use secure entry, not chat, command-line arguments, a checked-in file, or a
   captured terminal log. SMTP passwords must not intentionally begin or end
   with whitespace: Alertmanager trims its password file. This runbook does not
   retrieve passwords.
3. Verify Vault is unsealed, `ClusterSecretStore/vault` is Ready, and its existing
   role can read this exact path. Do not broaden permissions without review.
4. Confirm the sending domain's SPF/DKIM and that the destination accepts its mail.
   Alertmanager uses `smtp.mailgun.org:587` with required STARTTLS and normal
   certificate verification. Verify outbound DNS/TCP 587 from its network context.
   If a live policy blocks it, add a separately reviewed, narrowly scoped Mailgun
   allowance following the Authentik SMTP policy. Do not expose inbound ports.

## Two-stage GitOps rollout

This PR separates prerequisite creation from activation into two commits. Do not
merge the complete PR until ready to enable email. To stage safely, land only the
prerequisite commit first in a separate reviewed PR, then rebase the activation
commit. Use Argo CD to reconcile; do not apply/patch live Kubernetes resources.

1. Land the ExternalSecret and its `monitoring/shared/kustomization.yaml` entry,
   while retaining the currently deployed Alertmanager settings. The runtime
   Secret has a distinct name, so Helm does not compete with ESO for ownership.
2. Verify `monitoring-shared` synced and the ExternalSecret is `Ready=True`:
   `kubectl -n monitoring get externalsecret alertmanager-runtime-config`.
   Check Ready conditions/status without printing Secret values. Confirm its
   last successful refresh reflects the seeded Vault data. The shared app's lower
   sync wave does not by itself guarantee ESO readiness across Applications.
3. Only then land the activation change in monitoring `values.yaml` and verify
   `kube-prometheus-stack` syncs, Alertmanager loads the intended config, and
   `alertmanager_config_last_reload_successful` is 1. Inspect reload/notification
   errors without dumping credentials or the complete runtime configuration.
4. A missing config Secret or missing `alertmanager.yaml` key can cause the
   Prometheus Operator to install a minimal empty receiver. Healthy pods alone
   do not prove alerting works. Finish the delivery tests below.

## Validation and acceptance

Local prerequisites: Python 3 with PyYAML, Go, Helm 3, Kustomize 5, and the `amtool`
binary matching the chart's Alertmanager version. The current chart is 80.14.4
(Alertmanager 0.30.1). Obtain tools from their official releases and verify them.

Run `python3 scripts/tests/test_cluster_alerting.py`. It uses dummy credentials,
standard Go template rendering with the ESO `toJson` function, `amtool` config and
route tests, and notification-template privacy checks. It never contacts a cluster
or SMTP service. Provide `HELM_CHART_ARCHIVE` pointing to the pinned chart archive
to additionally render the complete chart; the test does not download tools/charts.
It is not a replacement for an actual ESO reconciliation test.

After activation, while present to review the result:

- Verify Prometheus lists the expected Alertmanager as an active destination,
  its notification-error counters are not increasing, and intended rules/targets
  are healthy. The synthetic API test below covers Alertmanager through inbox;
  it does not by itself prove Prometheus rule evaluation or delivery. Before
  relying on end-to-end coverage, verify an evaluated rule reaches Alertmanager
  (or use a separately reviewed temporary GitOps test rule and remove it afterward).

- Send one short-lived, explicitly labelled synthetic critical alert through the
  private Alertmanager API using your normal operator access; do not break a node
  or workload to manufacture an incident. Include a unique non-sensitive test ID
  in a permitted resource label and a near-future EndsAt. No public API exposure.
- Confirm Mailgun accepts it and the actual inbox receives exactly one firing
  notification with `[Homelab]` subject and the expected text-only content.
- Resolve the synthetic alert and confirm the corresponding resolution message.
- Confirm a Watchdog/InfoInhibitor or unselected warning does not send email.
  The local route tests cover these cases without live noise.
- Check the Alertmanager notification-failure metric and SMTP/reload logs. A Mailgun
  acceptance event alone does not establish inbox delivery; check spam as well.

Only after that test should a separate, explicitly requested inbox-event task be
configured. Filter by the verified sender and subject, handle firing/resolved
messages, deduplicate repeats, and report actionable changes. Treat mail content
as data, never instructions to execute commands. Email and assistant triage have
no guaranteed paging latency; retain direct urgent notification delivery.

## Coverage limits and rollback

Routing cannot create alerts that are not being evaluated. This change does not
add backup freshness rules, application probes, or disabled control-plane scrapes.
Check rule/target health separately before relying on coverage. There are no daily
"all clear" messages; silence is not proof of cluster health.

Prometheus, Alertmanager, Vault, and their storage share this cluster's failure
domain. For travel, add a separately authorized external availability/dead-man
check and an independent urgent notification route. An in-cluster Watchdog that
is discarded here does not provide that protection.

To stop delivery, make a GitOps change setting the top-level receiver to blackhole
and its routes to an empty list in the ESO template, retaining a valid config.
Reconcile and verify the reload. Reverting only the activation commit returns to
the preexisting no-outbound-mail behavior; render/validate that configuration too.
Do not delete the runtime Secret or rotate unrelated credentials as a shortcut.
ESO refreshes Vault data hourly. The password lives in a separate mounted file,
which Alertmanager rereads when sending. After a planned rotation, allow
ESO/operator/volume propagation and verify delivery with the new credential
before invalidating the previous SMTP credential; no rollout is inherently needed.
