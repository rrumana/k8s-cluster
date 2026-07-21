Harbor is deployed as a chart-backed Argo CD application in the `harbor` namespace.

Bootstrap prerequisites in Vault:
- `apps/harbor/core` with property `HARBOR_ADMIN_PASSWORD`
- `apps/harbor/core` with property `secretKey`
- `apps/harbor/database` with property `password`

Notes:
- `secretKey` must be a 16-character string.
- Harbor is exposed at `https://harbor.rcrumana.xyz`.
- Harbor uses shared platform PostgreSQL at `pg-platform-rw.databases.svc.cluster.local`.
- Harbor currently uses chart-managed internal Redis because the upstream Harbor Helm chart's external Redis secret handling is broken under Argo/Helm rendering.
- You must create a `harbor` database and `harbor` role in `pg-platform` using the same password stored at `apps/harbor/database`.
- Persistence uses the critical Ceph RBD pool (`ceph-block-critical`) with `Recreate` update strategy because Harbor's persistent components use RWO volumes.
- ChartMuseum is disabled; OCI artifacts are the intended path for charts and images.
