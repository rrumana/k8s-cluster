This directory defines a parallel Valkey replacement for the current Redis Enterprise footprint.

Architecture:
- `valkey-cache`: 1 primary + 2 replicas, no Sentinel, no persistence
- `valkey-queue`: 1 primary + 2 replicas, no Sentinel, AOF-backed persistence

Why this shape:
- It matches the current logical split between cache and queue workloads.
- It avoids Redis Enterprise's REC/REDB control-plane complexity.
- `valkey-cache` uses the chart's built-in primary service for non-Sentinel-aware apps.
- `valkey-queue` also uses the chart's built-in primary service because a single plain primary endpoint is the best fit for the current app set.

Vault prerequisites:
- `apps/databases/valkey-cache-auth` with property `password`
- `apps/databases/valkey-queue-auth` with property `password`

Client migration targets:
- `valkey-cache-primary.databases.svc.cluster.local:6379`
- `valkey-queue-primary.databases.svc.cluster.local:6379`
