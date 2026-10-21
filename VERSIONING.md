# Versioning policy

VelxoDB uses `A.B.C` (semantic versioning). The same numbers govern both the
package API and the on-disk format. This document is normative: a release that
does not satisfy its section must not be published.

## Terms

- **Direct read**: interpreting on-disk bytes with a reader built for one exact
  `A.B.C` release, without VelxoDB's compatibility layer or any implicit
  conversion. A direct reader is not promised to work on another `A.B.*` or
  another A at all.
- **API interop**: opening a database through VelxoDB's own API, where the
  release's compatibility layer may translate or ignore on-disk differences and
  the logical data is identical.

## Rules by position

### C — patch (e.g. 1.4.2 → 1.4.3)

- On-disk format is **byte-identical**. No new fields, files, encodings or
  default changes.
- The export API is **unchanged**: no additions, removals or deprecations. The
  documented behavior of every exported symbol is unchanged.
- Internal logic changes, bug fixes and performance optimizations are allowed,
  as long as no exported API behavior changes.
- No migration code, explicit or implicit, may be added for a C release.
- A database written by any `A.B.C` opens in any other `A.B.C` with no action.

### B — minor (e.g. 1.4.3 → 1.5.0)

- The on-disk format may change. A **direct reader for one exact `A.B.C`** is
  not guaranteed to work on a different `A.B.*` version; new bytes may need the
  matching reader.
- API interop is still absolute **inside the same A**: every `A.x.y` opens every
  `A.*` database through VelxoDB with no user action.
  - Newer VelxoDB implicitly upgrades old data when it opens it (in memory, and
    on the next write for the durable form).
  - Older VelxoDB in the same A must ignore unknown fields/sections. A B
    change that cannot be ignored by older releases is an A change.
- API changes are additive only: new APIs, or an explicit `@Deprecated`
  annotation that keeps the old behavior. No removals, no silent behavior
  changes within the same A.
- Tests must include the compatibility matrix: the newest release opens every
  older minor fixture, and the oldest supported minor opens the newest fixture.

### A — major (e.g. 1.9.0 → 2.0.0)

- The on-disk format and/or the API may be incompatible in any way.
- **Direct read by a previous A is not guaranteed.** Opening an old database
  with the new A requires an explicit upgrade command/API. Opening a new
  database with an old A is not supported.
- Upgrade requirements:
  - `VelxoDatabase.upgradeSync(path)` (or CLI) is the only path. It must create
    an **in-place undo journal** before touching data, validate the result, and
    switch atomically.
  - The undo journal is not a copy of the database. Each mutation records the
    original byte range it replaces, plus the full content of files it deletes
    and the names of files it creates. Entries are flushed before the mutation.
    `VelxoDatabase.rollbackUpgradeSync(path)` applies them in reverse and
    restores the exact pre-upgrade bytes.
  - A downgrade path is therefore built in: roll back with the journal, then
    open with the previous A. The journal may be discarded once the upgrade is
    accepted.
  - An interrupted upgrade leaves the journal in place; opening fails with
    `VelxoUpgradeRequiredException` until it is rolled back or retried.
  - Opening without upgrading fails with `VelxoUpgradeRequiredException`;
    opening a database from a newer A fails with `VelxoIncompatibleException`.
- API may change freely. Every breaking change must be documented in the
  changelog and the upgrade guide.

## Interoperability matrix

| Writer | Reader | Result |
| --- | --- | --- |
| same A, any B/C | same A, any B/C | opens directly, no action |
| older A | newer A | `VelxoUpgradeRequiredException` until explicit upgrade |
| newer A | older A | `VelxoIncompatibleException`; restore the backup instead |
| any | external direct reader | only guaranteed within the documented format version |

## Format stamp

The database root contains `FORMAT`:

```
offset 0..3   magic  "VXFM"
offset 4..5   format major, little endian u16
offset 6..7   format minor, little endian u16
offset 8..11  CRC-32C of bytes 0..7, little endian u32
```

- Missing stamp: treat as `1.0` (databases created before stamping). A writable
  open writes the current stamp; a read-only open does not modify the directory.
- `major` newer than the library: `VelxoIncompatibleException`.
- `major` older than the library: `VelxoUpgradeRequiredException` unless an
  explicit migration for that major is registered and `upgradeSync` runs.
- Same `major`, any `minor`: open normally. A writable open upgrades an older
  minor stamp to the current minor; a newer minor stamp is left untouched.
- An `UPGRADE-JOURNAL` in the root means a major upgrade did not finish. Opening
  raises `VelxoUpgradeRequiredException` until
  `VelxoDatabase.rollbackUpgradeSync(path)` restores the original bytes.

## Release procedure

1. Classify the change as A, B or C against this policy.
2. Update `formatMajor` / `formatMinor` in `lib/src/version.dart` when the
   on-disk contract changes; update the package version accordingly.
3. Add fixtures: for B, old and new bytes plus the bidirectional matrix; for A,
   an upgrade fixture and a restored-backup fixture.
4. Run the full CI matrix (Linux, macOS, Windows, Chrome, wasm, crash matrix).
5. Update `CHANGELOG.md` and, for A, the upgrade/downgrade guide.
