# Security and trust boundaries

This document describes how VelxoDB handles untrusted data, untrusted clients and
untrusted object stores. It is a design document for the trust-boundary work
planned for **1.4**; the current 1.0.x release has the decoder and corruption
guarantees below, but not yet the capability model, signed commit chain or trust
modes.

## Reporting a vulnerability

Open a private security advisory on GitHub rather than a public issue. Include a
reproduction, the version, and whether the issue requires write/delete access to
the backing store.

## What 1.0.x guarantees

- Every decoder validates lengths, offsets and checksums before use. A failed
  decode raises `VelxoCorruptException` or `VxsFormatException`; it does not read
  out of bounds.
- Segment metadata carries a CRC; document blocks are CRC-checked lazily; deep
  `check` verifies every block, orphan segment, catalog entry and posting.
- A lock is held on the database directory; read-only opens reject writes.
- Encryption at rest is not part of 1.0.0.

These are integrity guarantees for bytes that reach the database. They are not a
statement about who may write or delete objects in the backing store.

## The hard boundary

If a principal can execute `DeleteObject` (or overwrite) on every committed
object, no database code can preserve availability. VelxoDB can make tampering
**evident**, reject **forged** history and **repair** from another copy; it
cannot recreate deleted bytes. Preventing destructive access is an
authorization problem; the deployment must scope credentials.

## Trust modes (planned for 1.4)

| Mode | Control plane | Data plane | Position |
| --- | --- | --- | --- |
| **T1 mediated** | a coordinator role (time-bounded; may be a peer) holds the commit capability | clients write/read immutable data directly through scoped capabilities | default; the user-facing guarantee |
| **T2 unmediated** | no coordinator; the deployment issues scoped credentials | clients may hold broader write capability by policy | supported, explicit, deployment-owned |

Both modes are supported. They are not equally safe. T2 is never a silent
fallback: opening a database in T2 warns, and diagnostics report the mode.

### Capability matrix

| Prefix | Content | Client | Coordinator | GC |
| --- | --- | --- | --- | --- |
| `data/<hash>` | immutable segments/chunks | create-if-absent + read; no delete/overwrite | read | read |
| `ingest/<node>/<uuid>` | uncommitted staging | write/read/delete own | read + validate | read + clean |
| `commits/<gen>-<hash>` | signed commit records | read | append | read |
| `head` | latest commit pointer | read | CAS | read |
| `locks/` | leases and queue | read | CAS | read |
| `gc/tombstones/` | deletion markers | none | write | execute |

A capability should be a single key, a single method and a short TTL where the
provider supports it (presigned write, scoped bucket policy, access point). The
core ships no provider SDK; the host configures IAM and the capability issuer.

### Signed commit chain

The authoritative history is an append-only chain:

```
commit(n) = { generation, parentHash, manifestRoot, writerId, fenceToken, signature }
head      = { commitHash, generation, leaseProof, signature }
```

Readers verify the head, walk parent links to a trusted checkpoint, and reject a
forged, broken or rolled-back chain. Generations are monotonic and remembered;
peers gossip heads to detect forks. The legacy two-slot manifest remains a
derived compatibility view for 1.0 readers and is not authoritative.

### Validation before commit

Staging is untrusted. The commit path parses segment headers, validates lengths/
offsets/CRC/index ranges, checks hashes against the Merkle root, and rejects
oversized, decompression-bomb, duplicate-key and out-of-range inputs. Invalid
objects are quarantined and never become visible. In T2 the writer performs the
same validation and readers still verify structure and hashes; a key holder can
commit structurally valid but semantically bad data — that is authorization, not
corruption.

### Deletion and recovery

Clients never delete committed objects. GC is a privileged mark-sweep from signed
commits with tombstones and a grace period. Metadata is replicated across at
least two members/regions; chunks/segments use a replication factor or erasure
coding. Anti-entropy repairs a missing or corrupt copy. Backups are independent
of provider versioning.

## Guarantees by mode

| Property | T1 | T2 |
| --- | --- | --- |
| forged commit rejected | yes | only if the commit key is not shared; otherwise detected, not prevented |
| invalid staged data never committed | yes | writer validates; a key holder can commit bad data |
| client cannot delete committed objects | yes | depends on credentials |
| rollback/fork detected | yes | yes when readers/peers verify; a shared key removes the distinction |
| missing/corrupt object repaired | replicas/peers/backup | same, if a replica exists |
| availability under full delete rights | Object Lock/replicas | deployment responsibility |

## Deployment checklist

1. Do not grant clients `DeleteObject` on `data/`, `commits/`, `head` or
   `locks/`. Grant create-only writes to `data/` and their own `ingest/` prefix.
2. Prefer short-lived, single-key capabilities for direct data writes; commit
   and lock operations go through the coordinator role.
3. Enable provider versioning and, where available, Object Lock on committed
   metadata; use MFA delete for buckets that support it.
4. Replicate metadata across regions; set a replication factor for chunks; keep
   independent backups and test restores.
5. Protect the commit key: rotate it, audit its use, and consider threshold
   signatures if one coordinator is not an acceptable trust root.
6. In T2, document which principal holds which destructive capability and accept
   that the database cannot prevent its use.
7. Monitor hash mismatches, chain forks, rollbacks and unexpected deletes.

## Non-goals

- Preventing deletion by a principal with unrestricted credentials.
- Linearizable multi-region reads without a round trip.
- Distributed POSIX locks or automatic byte-level conflict merge.
- A cache that exposes collections or queries.
- Provider-specific adapters, transport bindings, discovery or a server tier.
