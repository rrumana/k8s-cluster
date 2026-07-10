# qBittorrent CephFS canary report

Date: 2026-07-10

## Scope

`arr-lts2` on `eva-3` was used as the only canary. The test kept libtorrent
2.x and did not test a libtorrent 1.2 image. The goals were to reduce the
approximately 1 second qBittorrent disk queue, eliminate the observed 3:1
Ceph read-to-upload amplification, and retain 1 Gbps-class seeding.

The final canary runs:

- qBittorrent 5.2.0 with libtorrent 2.0.12
- LinuxServer image `harbor.rcrumana.xyz/mirror/linuxserver/qbittorrent:5.2.0_v2.0.12-ls454`
- Linux 7.1.2 on `eva-3`
- Ceph 20.2.2 with a size-2 replicated CephFS bulk data pool
- `Simple pread/pwrite`, two asynchronous I/O threads, and four hash threads
- A dedicated, `eva-3`-affine CephFS mount with `noatime`, 128 KiB readahead,
  and localized replica reads

## Selected configuration

### CephFS mount

The canary PV uses:

```yaml
mountOptions:
  - noatime
  - rasize=131072
  - read_from_replica=localize
  - crush_location=host:eva-3
```

The PV is node-affine to `eva-3`. `read_from_replica=localize` asks the Ceph
client to select the nearest replica. With two replicas spread across three
hosts, a local copy is expected for roughly two thirds of objects; other reads
remain remote. It does not bypass RADOS or guarantee that every read is local.

Ceph documents `rasize` as the kernel client's maximum readahead and documents
localized replica reads as choosing the closest replica according to the
client's CRUSH location:

- [CephFS kernel mount options](https://docs.ceph.com/en/reef/man/8/mount.ceph/)
- [Ceph replica-read behavior](https://docs.ceph.com/en/reef/man/8/rbd/)

### qBittorrent/libtorrent

The selected qBittorrent preferences are:

| Preference | Value |
| --- | ---: |
| Disk I/O type | Simple pread/pwrite (`disk_io_type=3`) |
| Asynchronous I/O threads | 2 |
| Hashing threads | 4 |
| Global upload slots | 128 |
| Upload slots per torrent | 8 |
| Send-buffer low watermark | 16 KiB |
| Send-buffer maximum | 128 KiB |
| Send-buffer factor | 250% |
| Container memory request/limit | 2 GiB / 6 GiB |
| Termination grace period | 180 seconds |

These application preferences are currently persisted in the qBittorrent
configuration PVC, not rendered by GitOps. The image, memory allocation,
termination grace period, PV, and mount options are declarative. VPN endpoint
values are owned by Vault and rendered into the pod by External Secrets.

### Memory right-sizing

At the 12 GiB test limit, the container cgroup reached 12.0 GiB even though
`kubectl top` reported a 2.2 GiB working set. Cgroup accounting showed about
1.0 GiB of anonymous memory and 10.9 GiB of file cache, of which 9.8 GiB was
inactive and reclaimable. The cgroup recorded memory-limit reclaim events but
no OOM or OOM-kill event. VPA's target working set was about 2.6 GiB.

The canary now requests 2 GiB and is limited to 6 GiB. This preserves roughly
5 GiB for useful media page cache while preventing an idle reclaimable cache
from occupying 12 GiB. The limit is a ceiling rather than a reservation; the
2 GiB request is the amount considered by the scheduler.

Post-change validation reached 103 MB/s of upload at about 224 ms queue
latency. At that load the cgroup held about 1.1 GiB of anonymous memory and
4.7 GiB of file cache. It recorded reclaim events and only 1,960 file refaults,
with zero OOM or OOM-kill events. Six GiB therefore retains useful cache while
four GiB would leave materially less headroom for the measured working set.

The qBittorrent 5.2.0 source maps value 3 to `SimplePreadPwrite`. It implements
that mode through libtorrent's mmap disk backend while forcing actual file I/O
to pread/pwrite. In contrast, libtorrent's POSIX backend performs reads inline
and does not use its configurable I/O thread pool. This explains why increasing
`aio_threads` had no effect under POSIX mode.

Relevant upstream references:

- [qBittorrent advanced option documentation](https://github.com/qbittorrent/qBittorrent/wiki/Explanation-of-Options-in-qBittorrent)
- [qBittorrent 5.2.0 storage selection](https://github.com/qbittorrent/qBittorrent/blob/release-5.2.0/src/base/bittorrent/sessionimpl.cpp)
- [libtorrent 2.0.12 POSIX disk backend](https://github.com/arvidn/libtorrent/blob/v2.0.12/src/posix_disk_io.cpp)
- [libtorrent settings reference](https://www.libtorrent.org/reference-Settings.html)

## Results

The live upload rate depends on peer demand, so short samples should be read as
comparative results rather than exact benchmarks. Queue values are
qBittorrent's `average_time_queue` metric.

| Test | Queue latency | Upload/read result | Outcome |
| --- | ---: | --- | --- |
| Original: qBit 5.1.4, POSIX, `rasize=0` | 1,313-1,314 ms | About 14.5 MB/s; Ceph issued 4 KiB reads | Baseline |
| qBit 5.2.0 upgrade only, POSIX | 1,351-1,357 ms | About 12.5 MB/s | No storage improvement |
| Simple pread/pwrite, 16 threads, `rasize=0` | 4,700-5,100 ms | About 100 MiB/s Ceph reads and 25k read ops/s | Severe overdrive |
| Simple pread/pwrite, 4 threads, `rasize=0` | 1,625-1,646 ms | About 38.2 MB/s average upload | Faster, still overloaded |
| Simple pread/pwrite, 2 threads, `rasize=0` | 1,252-1,275 ms | About 25.0 MB/s average upload | Best thread count before mount tuning |
| Two threads plus localized reads, `rasize=0` | 1,079-1,096 ms | 28-35 MB/s before VPN failure | Locality helped |
| 64 KiB readahead, 20.07 GiB recheck | 96-98 ms | About 35 seconds; 531 MiB/s and 9.31k read ops/s sample | About 58 KiB per Ceph read op |
| 128 KiB readahead, 20.20 GiB recheck | 88-90 ms | About 30 seconds; estimated 650-700 MiB/s | About 106 KiB per Ceph read op |
| 128 KiB readahead, 4 I/O threads | 90-92 ms | No material throughput gain | Extra threads not useful |
| Live seeding, all three qBits active | About 220 ms | 57 MB/s average, 89 MB/s peak | Ceph reads tracked upload near 1:1 |
| Isolated canary, 128/8 slots, small buffers | 167-188 ms | 93 MB/s average, 110 MB/s peak | Best measured latency/throughput balance |
| Isolated canary, 128/8 slots, large buffers | 216-236 ms | About 99 MB/s average | More queueing, no useful gain |
| Isolated canary, unlimited slots, small buffers | 241-266 ms | 108-111 MB/s | Higher latency at the same ceiling |
| Isolated canary, 64/4 slots, small buffers | 191-204 ms | Reached 110 MB/s | No latency improvement over 128/8 |

During the isolated 128/8 test, cluster Ceph telemetry showed about 65 MiB/s
of reads while qBittorrent uploaded about 105 MB/s. The difference was served
from the eva-3 page cache. Ceph averaged roughly 63 KiB per read operation in
that sample. The prior 3:1 amplification was no longer present.

Three representative 20 GiB-class torrents completed forced rechecks without
data errors. The Ceph cluster remained `HEALTH_OK`, with all 337 PGs
`active+clean`, throughout the performance matrix.

## What worked

1. `Simple pread/pwrite` made libtorrent's I/O concurrency effective without
   changing to libtorrent 1.2.
2. Two I/O workers were enough after request sizing was fixed. More workers
   only deepened queues when Ceph was receiving 4 KiB requests.
3. `read_from_replica=localize` with an explicit host CRUSH location reduced
   queue latency before readahead was introduced.
4. A 128 KiB `rasize` allowed sequential checking to approach the configured
   request size and gave a modest improvement over 64 KiB.
5. Keeping OS caching enabled produced useful local page-cache hits for
   immutable media.
6. A 128-global/8-per-torrent upload-slot bound reduced queue latency while
   still saturating the uplink in the isolated test.
7. The original 16/128 KiB send-buffer bounds were better for latency than the
   proposed 128 KiB/1 MiB values.

## What did not work

1. Upgrading qBittorrent alone did not change CephFS behavior.
2. Raising the memory limit alone did not fix queue latency. It only allowed
   the page cache to grow beyond the prior 4 GiB cgroup limit.
3. Sixteen I/O threads generated thousands of queued jobs and amplified tiny
   Ceph requests. Four threads also remained worse than two.
4. Large send buffers increased queue latency and queued-job spikes without a
   meaningful throughput benefit.
5. A 64/4 upload-slot limit did not beat 128/8 in the measured workload.
6. Updating PV `mountOptions` and replacing the pod did not remount the staged
   CSI volume. The deployment had to reach zero replicas and the CSI global
   mount had to disappear before the new option took effect.
7. An in-place mount remount was rejected because the CSI CephX secret is not
   available to a host `mount -o remount` invocation.

## Incidental repairs

### Ceph PG cleanup

PG `17.7b` was `active+clean+inconsistent` with one stale shallow-scrub error.
It had no missing, degraded, or unfound objects, and Ceph returned no
inconsistent object or snapset entries. `ceph pg repair 17.7b` triggered a
deep verification and cleared the inconsistency.

Final state:

- PG `17.7b`: `active+clean`
- Scrub errors: 0
- Objects repaired: 0
- Cluster: `HEALTH_OK`, 337/337 PGs `active+clean`

The zero repaired-object count indicates stale scrub metadata after the storage
migration rather than detected payload corruption.

### Retired Proton endpoint

The arr-lts2 WireGuard endpoint failed during the locality test. It received
zero tunnel bytes across in-place and full pod restarts. Both its endpoint IP
and server public key were absent from Gluetun's current Proton database, while
the old IP still answered ICMP. A current San Jose port-forwarding server's
public IP and public server key were written to the existing Vault fields. The
existing private client key was retained and connected immediately. External
Secrets synchronized the values and the temporary Deployment overrides were
removed.

### Restart behavior

After an early forced shutdown, qBittorrent repeatedly exited because its
runtime `lockfile` and `ipc-socket` were stale. Removing only those runtime
files after confirming no process was active recovered it. Subsequent tests
used clean s6 shutdowns and a 180-second Kubernetes termination grace period.

After most qBittorrent process restarts, peer traffic did not resume until the
network interface preference was toggled between `tun0` and `Any interface`.
That behavior remains and should be automated or investigated separately.

## Further tests

1. Run a 24-hour endurance sample with all three seeders active, collecting
   qBittorrent queue latency, Ceph client read bytes/ops, page-cache refaults,
   pod memory, and OSD commit/apply latency in Prometheus.
2. Repeat the final test after the eva nodes move to the 10 GbE backbone. This
   should separate client/storage tuning from the temporary 2.5 GbE path.
3. Apply the selected backend and mount strategy to one additional qBittorrent
   instance at a time. Each node needs its own host-affine PV and
   `crush_location` value for localized reads.
4. Automate the post-restart interface refresh, ideally only after Gluetun has
   published a forwarded port, instead of relying on a manual toggle.
5. Replace fixed custom-server configuration with a supported server-selection
   workflow that can rotate retired Proton endpoints.
6. Reassess the 6 GiB memory limit after the endurance run using cgroup
   `memory.stat`, refaults, and OOM events rather than working-set telemetry
   alone.
7. Test qBittorrent 5.2.1 as a separate image-only change after this storage
   configuration has a stable endurance baseline.

Testing a libtorrent 1.2 build remains a last resort and is not currently
justified by the canary results.
