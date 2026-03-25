Harbor is deployed as a chart-backed Argo CD application in the `harbor` namespace.

Bootstrap prerequisites in Vault:
- `apps/harbor/core` with property `HARBOR_ADMIN_PASSWORD`
- `apps/harbor/core` with property `secretKey`

Notes:
- `secretKey` must be a 16-character string.
- Harbor is exposed at `https://harbor.rcrumana.xyz`.
- Persistence uses Ceph RBD (`ceph-block`) with `Recreate` update strategy because Harbor's persistent components use RWO volumes.
- ChartMuseum is disabled; OCI artifacts are the intended path for charts and images.
