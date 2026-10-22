# Roadmap

Status: **1.0.0 is released** (`velxodb` and `velxodb_generator`, format `1.0`).
This document is the plan for what comes next. Every item is classified against
[VERSIONING.md](VERSIONING.md): `C` keeps bytes and API identical, `B` may change
bytes but stays transparent inside the same major, `A` needs an explicit
journaled upgrade.

The order is driven by design correctness, not release cadence. A capability
ships only when its semantics, failure model, conformance suite and benchmarks
are complete. Internal feature flags are allowed while developing; public APIs
are not published as "preview".

---

## Positioning and vocabulary

VelxoDB is a **general-purpose embedded document database**. Every public
artifact — README, docs, this roadmap, benchmarks, release notes — describes
capabilities and guarantees, not vertical scenarios. Scenario mappings belong in
internal design notes and are not part of this document.

Capability vocabulary used here:

- **storage**: WAL, immutable segments, manifests, compaction, integrity;
- **retrieval**: ordered scans, secondary indexes, range queries, full-text and
  n-gram matching, resumable cursors;
- **coordination**: ordered logs, multi-writer commits, leases, locks,
  fence tokens;
- **data**: documents, files, content-addressed chunks;
- **placement**: caches, object stores, pools, peer-to-peer exchange.

---

## 1. What 1.0.0 already provides

VXS zero-copy documents; local WAL + mmap segments + bloom + two-slot manifest;
secondary indexes; transactions; reference bindings with restrict/cascade; typed
graph with BFS; full-text search; schema versions and migrations; typed models
and a generator; an object-store engine over a five-method `ObjectStore`; the
OPFS/Web stack; a worker-isolate facade; read-only opens; backup; integrity
checks; `A.B.C` versioning with a journaled upgrade path; and a benchmark suite
with seven generated cards.

What is missing is coordination between nodes, lock semantics for critical
sections, a peer protocol for nodes sharing one logical database, files as
first-class data, and placement across several object stores.

---

## L — Ordered log and change feed

### Goal

An ordered, append-only stream with resumable cursors, idempotent appends and
subscriptions. This is a general storage primitive: event logs, audit trails,
activity feeds, outboxes, replication journals.

### Model

- A **stream** is an ordered sequence of opaque records.
- A record carries an idempotency key, producer id, sequence number, producer
  timestamp (metadata only) and an operation kind (`append`, `replace`,
  `tombstone`, `receipt` is not a storage concept; the kind is open).
- `append(stream, records, idempotencyKey)` returns the assigned sequence(s).
  Replaying the same key returns the same result and never duplicates.
- `readFeed(stream, afterSequence, limit)` returns the next records;
  `head(stream)` returns the latest sequence.
- Retention and snapshots bound growth; tombstones represent removal; edits are
  records that reference an earlier record.

### Concurrent producers

Per-stream coordination, not global locks:

- a small stream-head object; append = stage immutable record object(s) + CAS
  head from `n` to `n+k`;
- the CAS winner owns the sequence range; the loser re-reads and retries;
- every producer's records land, each exactly once; order is the assigned
  sequence; producer timestamps never decide order;
- duplicate idempotency keys are no-ops;
- a hot stream is bounded by the CAS round trip and amortised by batching;
  different streams proceed in parallel;
- a long-lived producer may take a per-stream lease with a fence token, which
  the lock track generalises.

This requires a conditional-write store (`putIfMatch`). Without that capability
the log is single-writer and read-only replicas stay read-only; the API returns a
typed error rather than silently degrading.

### Consumers and multi-node sync

- Each consumer keeps a cursor per stream and advances it as records are read.
- A producer may stage locally (the cache track C2) and upload with an
  idempotency key; reconnect uploads then pulls from the cursor.
- Read receipts and derived state are ordinary records; consumers can build
  their own projections.
- The database guarantees per-stream total order and exactly-once append; it
  does not promise exactly-once delivery to consumers. That is a cursor +
  dedupe contract.

### Subscriptions

The same stream can be watched: `subscribe(stream, after)` pushes records in
order over the peer protocol (V), with acknowledgements and flow control. A
consumer that falls too far behind resumes from a snapshot + cursor.

### Storage layout

Records and the idempotency index use reserved key namespaces and the existing
document format; segment/manifest bytes do not change. This is a **B** release.

### Definition of done

- Two concurrent producers on one stream: both committed, unique sequences, no
  duplicates under retry/replay.
- Feed resume after a crash at every step; a cursor never skips a committed
  record.
- Idempotency index survives restart; retention/tombstones never resurrect data.
- Throughput/latency benchmark, hot-stream contention, cold-stream fan-out.
- Cursor and subscription conformance tests, including reconnect and expiry.

---

## K — Distributed locks

### Why locks are first-class

Multi-writer makes contention explicit: some writers must hold a section alone
because a race is unacceptable, while other readers may proceed concurrently.
A lock service with leases, fence tokens, fair queueing and **predicted release**
belongs in the database, not in every application.

### Modes

| Mode | Concurrent holders | Blocks | Intended use |
| --- | --- | --- | --- |
| `sharedRead` | many readers | writers | consistent reads, exports |
| `exclusiveWrite` | one writer | readers and writers | a critical write section |
| `exclusiveRead` | one reader | writers and other readers | maintenance that must not race |

Multiple **writers** are handled by M2 optimistic commits, not by a lock;
`exclusiveWrite` is for the cases where optimistic retry is not acceptable.
Locks are advisory at the API level but **enforced at commit** through the fence
token: a writer whose lease expired cannot commit.

### Semantics

- Lease-based: every grant has a TTL, a monotonic **fence token**, holder id and
  mode. The holder renews; a crashed holder loses the lease at expiry.
- Waiting is a **queue**: FIFO within a priority class, fair between holders,
  writer-preference to avoid writer starvation, cancellable, with a deadline.
- Reentrancy is supported per holder; upgrade/downgrade is explicit and may be
  refused or queued (never a silent deadlock).
- Granularity is a caller-chosen key (database, collection, key range, stream,
  file, volume), with a documented lock-ordering rule for multi-key sections.
- `tryAcquire` fails immediately; `acquire` queues; `acquire(timeout)` cancels.
- Release is explicit and idempotent; lease expiry is the crash fallback.

### Prediction instead of polling

A waiter should not spin on the network. The lock service publishes:

- holder id and mode;
- `leaseExpiresAt` (heartbeat-extended);
- queue position and an `estimatedAvailableAt` derived from the holder's lease,
  observed hold-time history and the queue ahead;
- a change event when the holder releases, renews or dies.

The waiter sets a timer for `estimatedAvailableAt` (with jitter) and sends one
**probe** then; it does not poll on a fixed interval. If the holder releases
early, the release event wakes the next waiter immediately. If notifications are
unavailable, the waiter falls back to a conditional GET at the predicted time,
then exponential backoff with jitter. Heartbeats update the estimate; stale
estimates are never trusted as a grant.

### Peer-to-peer coordination

There is no lock server. The lock state is an object with CAS; a coordinator
peer (any node holding the coordination lease, see M) may order queue entries
and relay notifications. Peers exchange `LOCK_REQUEST`, `LOCK_GRANT`,
`LOCK_RENEW`, `LOCK_RELEASE`, `LOCK_NOTIFY`, `LOCK_PROBE` over the peer protocol
(V). If peers cannot reach each other, storage CAS + lease expiry still grant the
lock; notifications are an optimisation, not the safety mechanism.

### Storage

Lock state lives in a reserved `locks/` namespace with CAS and TTL metadata;
the database format is unchanged. This is a **B** feature. Old readers ignore
lock objects; they do not participate in locking and must not write while a
lock-using writer is active.

### Definition of done

- Mutual exclusion for all three modes under concurrent stress; readers
  concurrently admitted; writer exclusion; fairness and no starvation.
- Fence tokens reject a stale writer after lease expiry; no double grant.
- Crash/restart: lease expiry grants the next waiter; queue state recovers.
- Prediction accuracy and probe traffic measured; no fixed-interval polling.
- Multi-node tests with injected latency, partition, clock skew and peer loss.

---

## M — Multi-writer commits

### Goal

Writers on different nodes commit to one logical database with a documented
serialization model and a fair queue. This is the general form of the per-stream
mechanism in L.

### Tiers

| Tier | Coordination | Guarantee | Cost |
| --- | --- | --- | --- |
| M1 lease | coordination lease + TTL + fence | strict serial order; one writer at a time; others queue | lease renew + commit RTT |
| M2 optimistic | manifest CAS + read-set validation | serializable commits with abort/retry; disjoint writers concurrent | head GET + stage + CAS |
| M3 sequencer | durable queue + CAS sequencer | one total order with group commit and fair queueing | one wide-area RTT per group, amortised |

The K lock service is orthogonal: use M2 for throughput, K when a section must
be exclusive, and M1/M3 when the whole commit stream must be ordered.

### B-safe commit protocol

1.0 readers list `wal/` and apply everything they find, so staged batches never
appear there. Multi-writer commits materialise a **segment per commit/group**:

1. stage immutable segment object(s) under `mw/staged/`;
2. obtain the turn (coordination lease/fence, or read-set validation);
3. CAS the manifest from generation `G` to `G+1`; this is the linearization
   point;
4. delete stale staged objects and release the turn.

Older readers see manifest + segments and therefore a consistent committed
snapshot. The cost is a segment PUT plus a manifest CAS per commit/group; group
commit amortises it. A cheaper commit-log format is an **A** decision for 2.x.

### Queue

- `mw/queue/` holds intent objects; `mw/head` holds the ordered sequence.
- Intents carry producer id, idempotency key, base generation, priority and a
  staged-batch reference.
- A coordinator peer drains a group, commits it as one generation, acknowledges
  and removes intents.
- FIFO within priority, fair round-robin between producers, visibility timeout,
  retry with backoff, dead-letter objects, backpressure, metrics.
- Regional queues plus a global sequencer (or per-shard sequencer) keep the
  wide-area RTT off the per-write path.
- Coordination is a **role**, not a server: any peer may hold the coordination
  lease; there is no privileged process.

### Guarantees

- single commit order per shard (global with one sequencer);
- no lost updates; conflicts abort explicitly;
- fence tokens reject a stale writer;
- snapshot reads by generation; optional linearizable read by reading the head;
- offline writers join the queue later through the cache outbox.

### Definition of done

- 3 simulated regions, 8–32 writers, injected latency: one order, no lost
  updates, no duplicate applies, stale writers fenced.
- Queue fairness and progress under contention; bounded retries and dead letters.
- Chaos: CAS storm, lease expiry, partition, duplicate submit, orphan GC,
  coordinator restart, clock skew.
- Request/cost accounting: GET/PUT/CAS per commit; staged-object GC.

### Version

M1/M2 and K in 1.4; M3 in 1.6. Both are **B**: document/segment/manifest bytes
do not change, new object namespaces appear, older readers see committed state.
Old writers must not open a multi-writer database; a writer-mode marker makes
this explicit.

---

## V — Peer protocol (VPP)

### Positioning

VPP is a protocol between **VelxoDB nodes**, not a client-server protocol. Nodes
that share the same logical database use it to synchronise, to fetch content
from another node instead of the object store, to relay requests through
intermediate nodes, and to exchange lock and commit notifications. There is no
server tier and no central coordinator required; a coordinator is only a
time-bounded role held by one peer.

The protocol does not define how peers discover each other or which transport
they use. A `PeerChannel` contract supplies framed messages; discovery, NAT
traversal, WebSocket/QUIC/WebRTC/LAN wiring and authentication handshakes are
host-side concerns. No transport or discovery adapter is shipped.

### Session model

- Symmetric: either side can request, serve, forward or relay.
- `HELLO` negotiates protocol version, feature bits, node identity, database
  identity and capabilities.
- A session multiplexes logical streams (sync, relay, lock, RPC).
- Requests carry ids; responses and streams can be cancelled; flow control is
  per stream.
- Any node may be read-only, cache-only, relay-only or coordinator; roles are
  dynamic and advertised, never assumed.

### Message families

| Family | Messages | Purpose |
| --- | --- | --- |
| Session | `HELLO`, `CAPS`, `PING`, `GOAWAY`, `BYE`, `ERROR` | identity, negotiation, liveness |
| Inventory | `INVENTORY`, `HAVE`, `WANT`, `MISS` | compact summaries of manifests, Merkle roots, chunk hashes and cursors |
| Data | `MANIFEST`, `SEGMENT`, `CHUNK`, `RANGE`, `DATA` | immutable objects and byte ranges |
| Log | `LOG`, `CURSOR`, `SUBSCRIBE`, `ACK` | ordered records and resumable feeds |
| Relay | `FORWARD`, `ROUTE`, `RETURN` | store-and-forward through intermediate peers |
| Coordination | `LOCK_REQUEST`, `LOCK_GRANT`, `LOCK_RENEW`, `LOCK_RELEASE`, `LOCK_NOTIFY`, `LOCK_PROBE`, `COMMIT_HINT` | locks and commit notifications |

Payloads are opaque bytes (VXS documents, segments, chunks); the protocol does
not re-encode them. Integrity is content-hash based; a transport CRC is optional.

### Synchronisation

- `INVENTORY` carries compact summaries: manifest generation and digest, Merkle
  roots, a chunk-hash Bloom filter, log cursors.
- A peer compares inventories and sends `WANT` for missing hashes/ranges; the
  responder sends `DATA`; the receiver verifies hashes before use.
- A peer that lacks an object can `FORWARD` the want to another peer, with a
  hop limit and loop prevention; responses return along the route.
- If no peer can serve, the node falls back to the object store. Peer exchange
  is an optimisation, never a durability dependency.
- Snapshot + cursor fallback handles a peer that is too far behind.

### Relay (store-and-forward)

`FORWARD` carries origin, target, message id, hop limit and deadline. Every hop
deduplicates by message id, decrements the hop limit and records the return
route. Relays may cache immutable objects. A relay never acknowledges durability
it does not have; only the object store commit is durable.

### Writes

A node may commit directly to the object store with a coordination lease/fence,
or forward a proposal to a coordinator peer. Peers exchange `COMMIT_HINT` so
subscriptions and caches converge quickly; hints are advisory and never replace
reading the committed manifest/generation. Locks coordinate critical sections;
fence tokens protect the commit.

### Consistency

- Every response carries the generation/cursor it was computed from.
- Reads may be served from a stale peer; the caller sees the generation and can
  choose to require the latest head.
- Conflicts on metadata produce conflict versions (F) or aborts (M); no silent
  overwrite.
- A node that cannot reach any peer or the store reports a typed offline error,
  not a fabricated success.

### Security

- Peer sessions must run over an authenticated, encrypted channel supplied by
  the host (TLS/Noise or a trusted local channel). VPP does not invent crypto.
- Node identity and database membership are part of `HELLO`; capabilities are
  scoped (read, write, relay, lock).
- Content is verified by hash; a peer cannot inject bytes for a known hash.
- Frame sizes, decompression bounds, hop limits, deadlines and rate limits are
  enforced; relay loops are rejected.
- Untrusted peers can be read-only or relay-only; write capability requires an
  explicit grant.

### Versioning

Protocol major/minor is independent of the database format. Feature bits gate
additive messages; unknown critical frames are rejected with `UNSUPPORTED`,
unknown optional frames are ignored. A conformance suite, golden frames and a
parser fuzzer ship with the protocol.

### Definition of done

- Loopback `PeerChannel` conformance: framing, negotiation, multiplexing,
  cancellation, flow control, hash verification.
- Two-node sync from empty, incremental sync, resume after disconnect, stale
  peer fallback, snapshot fallback.
- Relay through three nodes with loops, deadline expiry and dedupe.
- Lock and commit hints under partition; hints never grant durability.
- Malformed frames, oversized payloads, hash mismatch, replay and hop-limit
  exhaustion produce typed errors.

### Version

**B** / 1.5. New message types and a host-supplied channel; the database format
is unchanged. No transport, discovery or server implementation ships with it.

---

## C — Cache and sync

### Goal

Make object-store deployments fast and usable offline without turning the cache
into a VelxoDB instance. The cache is a separate storage mechanism: bytes,
metadata and a pending journal. No catalog, no collections, no query layer, no
document encoding.

### Layers

| Layer | Contents | Durability | Purpose |
| --- | --- | --- | --- |
| C0 memory | segments, blocks, manifest | volatile | hot reads |
| C1 persistent objects | immutable objects by `key@etag` | crash-safe, evictable | avoid GETs across restarts |
| C2 write-behind journal | pending commits + idempotency keys | crash-safe | low-latency/offline writes |
| C3 sync engine | base generation, pending state, invalidation | metadata | reconcile local/remote |

### Cache format

An append-only record log plus an index: `[type][keyLen][key][etag][generation]
[flags][len][data][crc32c]`, compacted periodically. Records are either object
bytes or journal entries. The cache format is disposable (versioned, discarded
on mismatch) and independent of the database `A.B.C` format.

`CacheStore` is a contract with memory, file and OPFS implementations; external
implementations are private integrator choices. LRU with a byte budget;
manifest/head and pending entries are pinned; corruption drops and refetches.

### Read path

- `(key, etag/generation)` lookup; hits avoid the network.
- Manifest is revalidated with `If-None-Match`; a newer generation invalidates
  older entries lazily.
- Block-level caching for large segments; prefetch on scan; zero-copy views
  while pinned.

### Write path and acknowledgements

- `AckPolicy.remote`: acknowledge after the store/commit confirms.
- `AckPolicy.local`: acknowledge after the durable local journal; upload in the
  background, with a documented loss window.
- `AckPolicy.memory`: fastest, no durability.
- Pending entries carry an idempotency key and a base generation; retries are
  safe; group commit batches uploads.

### Reconciliation

1. conditional GET the head/manifest; compare with the local base generation;
2. unchanged: upload pending batches and CAS;
3. newer: validate each pending batch's read set; disjoint → rebase and upload;
   overlap → conflict policy (abort / commit-order last-writer-wins / custom);
4. invalidate older cache entries; refresh the manifest and hot segments;
5. emit sync metrics (pending, lag, conflicts, bytes).

Temporary mode (cleared on close) and persistent mode (survives restart) share
the algorithm; only journal durability differs.

### Definition of done

- Warm hit ratio and p50/p99 local vs remote reads.
- Offline writes + reconnect convergence; conflict abort and rebase.
- Crash injection at every journal step: no acknowledged write lost under
  `remote`/`local`; no partial commit visible.
- Generation correctness; bounded disk/OPFS; eviction does not break uploads.
- The cache exposes no catalog/collection/query API.

### Version

C0/C1 in 1.1, C2/C3 in 1.2; **B**. Cache compression is a **C** internal
improvement once the record format is stable.

---

## F — Embedded file system

### Goal

Store files inside a VelxoDB instance without a second file store: multiple
independent file-system volumes per database, content deduplication, links,
versions, diffs and copy-on-write, with fast total-size accounting.

### Two planes

```
Volume
 ├─ Namespace (directories, rename, delete; mutable, ordered)
 ├─ Inode / Version (metadata, version chain, quotas)
 └─ File version
      └─ Merkle root (content hash)
           ├─ tree nodes (chunk hashes + offsets)
           └─ chunks (content-defined, content-addressed, immutable)
                     └─ Chunk locator (hash → member)
```

Metadata is small, mutable and ordered; chunks are large, immutable and
content-addressed. The split is the reason distribution, caching and
deduplication do not rewrite file metadata.

### Data model

- Content-defined chunking (FastCDC/gear) with a per-volume policy; chunks are
  stored by hash.
- A file version is a Merkle root; tree nodes carry child hashes, offsets and
  lengths; large files are trees, not single documents.
- **File Link**: hard links share the inode/version; content links share the
  Merkle root; identical chunks are deduplicated globally.
- **Diff**: two version roots are compared as trees; only changed subtrees/
  leaves are stored or transferred.
- **Copy-on-Write**: a new version shares unchanged subtrees and writes new
  chunks for changed ranges.
- Write modes are explicit: `FileWriteMode.diff` (retain a base + changes,
  lower bandwidth) vs `FileWriteMode.copyOnWrite` (new tree sharing old
  subtrees, faster reads). Compaction merges long diff chains.

### Multi-writer file semantics

- The data plane needs no locks: chunks are immutable, uploads are idempotent,
  and abandoned chunks are garbage collected.
- Metadata uses a per-file **version CAS**. On conflict the default is to
  **preserve both versions** (a conflict version), never silently overwrite; the
  application chooses a merge policy.
- Namespace operations use a per-directory/shard ordered log or CAS head; rename
  is atomic within a shard. Cross-shard rename uses an intent record and is
  eventually completed, or a later two-phase protocol; it is not promised as
  distributed-POSIX-atomic in 1.x.
- K locks are available for sections that must not race, and fence tokens are
  checked at metadata commit. There is no distributed POSIX lock manager.
- Open handles pin a version; a write from an old version produces a conflict
  version rather than losing data.
- Quotas are reserved at commit; garbage collection uses pins for open handles
  and in-flight uploads.

### Total size and quotas

- Per-volume logical size is maintained transactionally and is O(1) to read.
- Per-directory subtree counters are maintained (with batched ancestor updates)
  or exposed as approximate with a documented reconciliation; no fake precision.
- Physical size is computed from the chunk index and reference counts, including
  deduplication benefits.
- Quotas reserve at commit to avoid oversubscription; logical and physical sizes
  are both reported.

### Distribution

- The chunk locator maps `hash → member(s)` independently of file metadata;
  migration updates locators, never inode records.
- Placement policy: hash, tenant, temperature, capacity quota. A full member
  receives no new chunks and its chunks migrate in the background.
- Metadata lives in a small consistent pool; chunks live in a large immutable
  pool (see P). They may use different pools.

### Local performance

The first implementation is pure Dart over the existing engine. A host-side
local block-device contract may be added later for native acceleration; it is
not promised here and no native filesystem adapter is shipped. The pure-Dart
path is the correctness baseline.

### Definition of done

- POSIX-like semantics for create/read/write/append/truncate/rename/link/
  unlink/readdir/stat; crash consistency at every metadata step.
- Dedupe ratio and diff/COW space measurements; total size matches logical/
  physical sums after random operations, restart and GC.
- Large-file random reads, 1M-file directory, concurrent writers on different
  files; conflict versions preserved.
- No database catalog or segment format change; older readers still open the
  database (B).

### Version

**B / 1.8**, conditional on the design gate: metadata must live in reserved
collections and chunks in reserved object namespaces, not in a new catalog
section. If a new catalog entity or block kind is unavoidable, it becomes an
**A** release.

---

## P — Storage pools

### Goal

One logical database does not have to live in one object store. A pool presents
several members as one logical store; when a member reaches its limit, new
objects go elsewhere and old objects migrate in the background.

### Two pools

- **Metadata pool**: small, consistent, conditional-write; holds manifest,
  coordination/head objects and lock state. It must support CAS.
- **Chunk pool**: large, immutable, content-addressed; holds chunks and segments
  that are referenced by hash or key. Migration is free to move them.

A volume may bind a metadata pool and a chunk pool independently.

### Design

- `PooledObjectStore` composes members and implements the same `ObjectStore`
  contract the engine uses; the database format does not change.
- A small placement index maps object keys to members; capacity policies choose
  placement (hash, range, free-space quota, tenant).
- Capacity is an explicit quota or a member callback; object stores do not
  reliably expose free space.
- Migration: copy → verify checksum → update placement atomically → delete old;
  the manifest commit is the safety point. Immutable chunks/segments move
  freely; staged multi-writer objects are pinned until their commit resolves.
- Reads route by placement; a missing member falls back to a replica or a typed
  error, never wrong bytes.

### Classification

**B / 1.7** while placement stays outside the database format: the pool is a
storage backend and the database bytes are ordinary object-store bytes. A reader
must be given the same pool configuration (as it must be given the same bucket
today). Storing placement inside the manifest would make it an **A** change and
is rejected for this track.

### Definition of done

- Simulated members with quotas: automatic placement, migration when a member
  fills, reads during migration, crash at every migration step.
- No lost/duplicated objects; checksum verification; GC of copied-but-not-
  deleted objects.
- Coordination interaction: manifest/head CAS never spans two members; staged
  objects are pinned; migration never invalidates a fence.
- Request/latency accounting: extra GET/PUT per migration, read fallback cost.

---

## Z — Compression

### Goal

Reduce disk, object-store and transfer bytes with mainstream codecs.

### Codecs

| Codec | Role | License (Dart port) |
| --- | --- | --- |
| zstd | default, dictionaries, levels | MIT |
| lz4 | fastest block codec | BSD-style (in-tree or vetted package) |
| brotli | text-heavy blocks | MIT |
| snappy | very fast, lower ratio | BSD |
| gzip/deflate | interop | zlib/BSD (VM path) |
| lzo | legacy, optional | MIT Dart port; upstream LZO is GPL, documented |

Stable codec ids: `1..127` core, `128..255` externally registered. A reader
without a codec raises a typed incompatibility, never returns wrong bytes.
Incompressible blocks fall back to raw. Decompression has a hard size bound.

### Format and version

Block v2 adds codec id, compressed/uncompressed lengths, dictionary id and a CRC
over stored bytes. A 1.0 reader cannot parse it, so this is **A / 2.0.0**:
`upgradeSync` rewrites segments with the chosen policy (or stamps compatible
databases), `rollbackUpgradeSync` restores exact bytes through the journal. The
cache may compress its own records earlier (C, 1.2), independent of the database
format.

### Definition of done

- Ratio/throughput per codec on documents, CJK text, index keys and
  incompressible blobs; read p50 overhead; wasm bundle/speed.
- Fuzz: truncated/oversized/bomb blocks raise typed corruption.
- Upgrade/rollback byte-exact; interrupted upgrade refused until rolled back.

---

## Version plan

| Version | Class | Theme | Headline items |
| --- | --- | --- | --- |
| 1.0.x | C | maintenance | fixes/docs; no format or API change |
| **1.1.0** | B | foundations | MVCC snapshots + reader/writer split; batched peer RPC + queries/transactions; long-lived segment builder; segment pin/deferred unmap; directory-fsync contract; process-wide writer guard; conditional object-store capability; C0/C1 read cache; covering index/range; incremental/live backup; graph-edge cleanup |
| **1.2.0** | B | cache & sync | C2 durable write-behind; ack policies; C3 sync/reconciliation; offline; cache compression; OPFS cache; OPFS key-index compaction; Web Locks fallback |
| **1.3.0** | B | ordered log | streams, idempotent append, per-stream sequence, change feed/cursors, subscriptions, retention; per-stream lease |
| **1.4.0** | B | multi-writer & locks | M1 coordination lease + fence; M2 optimistic commits; manifest CAS; commit-as-segment; queue v1; K shared/exclusive locks; lease prediction/notifications; conflict policies; writer-mode marker |
| **1.5.0** | B | peer protocol | VPP framing/session/inventory/have-want/data; relay/forward; peer fetch; lock/commit notifications; loopback conformance; no transport or discovery shipped |
| **1.6.0** | B | global serialization | M3 sequencer + durable queue; group commit; fairness/backpressure/dead-letter; linearizable read; sharding; WAN chaos |
| **1.7.0** | B | storage pools | metadata pool + chunk pool; capacity-aware placement; background migration; read routing; no DB format change |
| **1.8.0** | B | file system | volumes; content-defined chunks; Merkle versions; hard links; diff and copy-on-write; O(1) total size; file metadata index |
| **2.0.0** | A | format v2 | compression (zstd/lz4/brotli/snappy/gzip, optional lzo), block v2, codec registry, journaled recompression upgrade |
| 2.x | B/A | extensions | geo/vector (B if additive), encryption at rest (A), optional document-style client facade as a separate package (B) |

### Dependencies

```
1.1 foundations
  ├─► 1.2 cache/sync ──► 1.3 ordered log
  ├─► 1.4 multi-writer + locks ──► 1.5 peer protocol ──► 1.6 global order
  ├─► 1.7 storage pools
  └─► 1.8 file system (uses pools/chunks; can start on one store)
2.0 compression (independent, but must be an A release)
```

File-system chunks and pool placement are designed together but delivered
separately: the FS works on a single store first, then on a pool.

---

## Design gates and definition of done

Each track starts with a design RFC containing:

1. the semantics and exact guarantees (and non-guarantees);
2. invariants and a failure matrix (crash, partition, stale cache, duplicate,
   clock skew, capacity, GC races);
3. the version classification with a byte-format diff (or proof there is none);
4. conformance tests and chaos tests;
5. benchmarks with targets and request/cost accounting.

No public API ships before the track's definition of done is met. Internal
feature flags are fine; public "preview" semantics are not.

---

## No adapters, no server

Explicitly out of scope:

- S3/GCS/R2 SDKs, SigV4, multipart code, provider-specific error mapping.
- etcd/Redis/DynamoDB lock/sequencer adapters.
- WebSocket/QUIC/WebRTC discovery or transport bindings shipped by this
  project; the host supplies a `PeerChannel`.
- IndexedDB/RocksDB/SQLite cache backend adapters.
- NTFS/ext4/native filesystem instruction adapters.
- A central server tier, hub, proxy or API gateway.

The core ships capability contracts, a loopback `PeerChannel` for tests, a
simulated store with conditional writes/latency/faults/quotas, and conformance
kits. Integrators implement transports, stores and membership privately; no
adapter package is planned, published or supported.

---

## Benchmark and CI additions

- `ordered_log_bench`: concurrent appends, feed resume, dedupe, hot/cold streams.
- `lock_bench`: acquire/release, shared vs exclusive, fairness, predicted
  release accuracy, probe traffic, fencing.
- `peer_bench`: inventory exchange, have/want, relay hops, resume, throughput.
- `multi_writer_bench`: 3 simulated regions, 8–32 writers, invariants, p50/p99
  commit, abort rate, fairness, request counts.
- `cache_bench`: hit ratio, local vs remote p50/p99, offline convergence, crash
  recovery, bytes on disk/OPFS.
- `file_system_bench`: create/write/read/rename/link/diff/COW, dedupe ratio,
  total-size accounting, 1M-file directory, large-file random reads.
- `pool_bench`: placement, capacity migration, reads during migration, request
  overhead.
- `compression_bench`: per-codec ratio/throughput, CPU overhead, wasm numbers.
- CI adds nightly WAN/chaos, cache crash matrix, FS metadata crash matrix,
  lock fairness and compression fuzz; PR jobs keep the fast subset.

---

## Decisions taken

1. **General-purpose positioning.** Public artifacts describe capabilities;
   scenario mappings stay internal.
2. **Ordered log + change feed is a core primitive**, with per-stream CAS/lease,
   cursors, idempotency and subscriptions.
3. **Locks are first-class**: shared-read, exclusive-write, exclusive-read; TTL
   leases, fence tokens, fair queue, predicted release and event-driven probes.
4. **Multi-writer is B**, via segment-per-commit and manifest CAS; older readers
   still see committed state. A cheaper commit-log path is an A decision later.
5. **The protocol is peer-to-peer (VPP), not a server.** Any node can serve,
   relay or hold a time-bounded coordinator role; transport/discovery are
   host-side.
6. **The cache is a separate record-log mechanism**, not a VelxoDB instance.
7. **File system = metadata plane + content-addressed Merkle chunk plane**;
   distribution moves chunks/locators, never file metadata. Multi-writer is
   metadata version CAS + conflict versions, with explicit locks for critical
   sections.
8. **Storage pool = metadata pool + chunk pool**, transparent to the database
   format.
9. **Compression is A / 2.0.0**, because 1.0 readers cannot parse compressed
   blocks.
10. **No adapters, no server**, in this roadmap.

## Open questions

1. Lock defaults: writer-preference vs fair queue; whether upgrade is allowed or
   requires release + reacquire.
2. Lock granularity limits: should key-range locks be bounded to avoid a lock
   table that grows without bound?
3. Peer discovery: entirely host-side, or should the database expose a small
   presence namespace in the shared store?
4. File-system chunking: FastCDC parameters per volume; whether a fixed-chunk
   mode should exist for local-only volumes.
5. Total-size exactness: exact per volume, approximate per directory, or exact
   per directory with batched ancestor updates?
6. Whether 2.0 compression should also introduce the optional commit-log format
   for multi-writer, or keep that for 2.x.

## Non-goals

- Linearizable multi-region reads without a round trip.
- CRDT/eventual semantics as the default; conflicts are explicit.
- A cache that exposes collections/queries.
- Distributed POSIX locks or byte-level automatic merge.
- Cross-shard transactions in 1.x (future two-phase work only).
- Provider-specific adapters, transport bindings, discovery or a server tier.
- Promising native filesystem performance before a pure-Dart baseline exists.
