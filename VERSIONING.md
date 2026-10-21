# Versioning policy

VelxoDB versions are `A.B.C`. The same three numbers govern the package API, the
on-disk format and the documented behavior. This document is normative: a
release that cannot satisfy its section must not be published.

The policy exists because an embedded database has two independent consumers:
the application that links the package, and any tool that reads the files
directly. `A.B.C` answers both questions at once.

## Terms

- **Direct read** — interpreting on-disk bytes with a reader built for one exact
  `A.B.C` release, without VelxoDB's compatibility layer. Only the format
  version documented for those bytes is promised to work.
- **API interop** — opening a database through VelxoDB's own API, where the
  release's compatibility layer may translate or ignore on-disk differences. The
  logical data is identical; the bytes may not be.
- **Format stamp** — the `FORMAT` file at the database root (an object named
  `<prefix>FORMAT` on the object-store backend), described below.

## Rules by position

| Change | `C` patch | `B` minor | `A` major |
| --- | --- | --- | --- |
| On-disk bytes | byte-identical | may change | may change |
| Direct read by another release | guaranteed | not guaranteed | not guaranteed |
| VelxoDB API interop within the same `A` | guaranteed | guaranteed, automatic | requires explicit upgrade |
| Package API | unchanged | additions / deprecations only | may break |
| Migration logic | none | implicit, transparent | explicit, journaled |
| User action to open | none | none | `upgradeSync` |

### `C` — patch (for example 1.4.2 → 1.4.3)

- The on-disk format is **byte-identical**. No new fields, files, encodings,
  default values or changed interpretation.
- The exported API is **unchanged**: no additions, removals, deprecations or
  behavior changes. Bug fixes may change behavior only where the previous
  behavior was undocumented or clearly a defect.
- Internal logic and performance work are allowed.
- No migration code, explicit or implicit, may be added.
- Any `1.x.y` database opens in any other `1.x.y` release with no action.

### `B` — minor (for example 1.4.3 → 1.5.0)

- The on-disk format may change. A **direct reader built for one exact `A.B.C`**
  is not promised to read a different `A.B.*`.
- **API interop inside the same `A` is absolute in both directions.**
  - A newer release implicitly upgrades older data when it opens it: in memory,
    and in its durable form on the next write.
  - An older release in the same `A` must still open data written by a newer
    release. It ignores unknown fields and sections and preserves them verbatim
    when it rewrites a document. A `B` change that an older release cannot
    ignore is an `A` change, not a `B` change.
- API changes are additive: new APIs, or `@Deprecated` annotations that keep the
  old behavior. No removals and no silent behavior changes inside one `A`.
- Tests must cover the compatibility matrix: the newest release opens every
  older minor fixture, and the oldest supported minor opens the newest fixture.

### `A` — major (for example 1.9.0 → 2.0.0)

- The format and/or the API may change in any way. Direct read by a previous `A`
  is not guaranteed.
- Opening an older database with a newer `A` requires an **explicit upgrade**;
  opening a newer database with an older `A` is refused.
- `VelxoDatabase.upgradeSync(path)` is the only upgrade entry point:
  1. it refuses when an `UPGRADE-JOURNAL` is already present;
  2. it writes an **in-place undo journal** before touching data — original byte
     ranges plus the original length of every file it changes, and the full
     content of files it deletes;
  3. it switches atomically (manifest generation or stamp rename);
  4. it validates the result before reporting success.
- `VelxoDatabase.rollbackUpgradeSync(path)` applies the journal in reverse and
  restores the exact pre-upgrade bytes. The journal is a reverse diff, not a
  copy of the database.
- An interrupted upgrade leaves the journal behind; opening fails with
  `VelxoUpgradeRequiredException` until it is rolled back (or the upgrade is
  retried). A torn journal header that recorded no entries is safe to discard.
- Opening without upgrading raises `VelxoUpgradeRequiredException`; opening a
  database from a newer `A` raises `VelxoIncompatibleException`.
- Every breaking API change must be documented in the changelog and an upgrade
  guide.

## Interoperability matrix

| Writer | Reader | Result |
| --- | --- | --- |
| same `A`, any `B.C` | same `A`, any `B.C` | opens directly, no action |
| older `A` | newer `A` | `VelxoUpgradeRequiredException` until `upgradeSync` |
| newer `A` | older `A` | `VelxoIncompatibleException`; restore a backup instead |
| any release | external direct reader | only the documented format version |

## Format stamp

The database root contains `FORMAT`:

```
offset 0..3   magic  "VXFM"
offset 4..5   format major, little-endian u16
offset 6..7   format minor, little-endian u16
offset 8..11  CRC-32C of bytes 0..7, little-endian u32
```

- The stamp is written atomically: a temporary file is renamed over the previous
  stamp, so a crash leaves either the old stamp or the new one, never a torn
  one. (An earlier build wrote it in place; a torn stamp made a healthy database
  unreadable. That is the reason for the rule.)
- A missing stamp means a database created before stamping: it is treated as
  `1.0` and stamped on the next writable open. A read-only open never writes.
- `major` newer than the library: `VelxoIncompatibleException`.
- `major` older than the library: `VelxoUpgradeRequiredException` unless the
  release that supports that major is used.
- Same `major`, any `minor`: opens normally. A writable open upgrades an older
  minor stamp to the current minor; a newer minor stamp is left untouched (the
  older release must be able to read it, per the `B` rules).
- An `UPGRADE-JOURNAL` at the root means a major upgrade did not finish: opening
  raises `VelxoUpgradeRequiredException` until
  `VelxoDatabase.rollbackUpgradeSync(path)` restores the original bytes.

## State of this release

`1.0.0` writes format `1.0`. It is the first public release, so there is no
older major to upgrade from and no migration is registered. The journal, the
`upgradeSync` entry point and the rollback path are implemented and tested; the
first `2.0.0` migration must use them rather than inventing another mechanism.
`upgradeSync` on an older major currently raises
`VelxoUpgradeRequiredException` with the message that no migration is registered.

## Catalog versions

The catalog carries its own `catalogVersion`. It is part of the on-disk
contract, not a free counter: a decoder rejects a version it does not know.
Consequently, a `B` release may only change the catalog in a way an older
release in the same `A` can still parse — today the decoder requires exact
consumption of the file, so appending a new section is **not** a `B` change
unless a decoder that ignores trailing data is introduced first. Treat a
catalog layout change as an `A` change until that compatibility layer exists,
and keep `catalogVersion` and `formatMinor` in step when it does.

## Release procedure

1. Classify the change against the table above before writing code.
2. Update `formatMajor` / `formatMinor` in `lib/src/version.dart` when the
   on-disk contract changes, and the package version accordingly.
3. Add fixtures: for `B`, old and new bytes plus the bidirectional matrix; for
   `A`, an upgrade fixture and a restored-backup fixture.
4. Run the full CI matrix: Linux, macOS, Windows, Chrome, wasm, crash matrix,
   benchmarks.
5. Update `CHANGELOG.md` and, for `A`, the upgrade/downgrade guide.
