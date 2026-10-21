# Versioning policy

VelxoDB uses `A.B.C` (semantic versioning). The same numbers govern both the
package API and the on-disk format. This document is normative: a release that
does not satisfy its section must not be published.

## Terms

- **Direct read**: interpreting on-disk bytes without VelxoDB's compatibility
  layer, for example an external tool or a VelxoDB build from another major.
- **Format version**: the `(major, minor)` pair in the `FORMAT` stamp at the
  database root. It is independent from a document's schema version.
- **Interop**: opening a database with VelxoDB itself and getting the same
  logical data, with no user action.

## Rules by position

### C — patch (e.g. 1.4.2 → 1.4.3)

- On-disk format is **byte-identical**. No new fields, files, encodings or
  default changes.
- API is **unchanged**: no additions, removals, deprecations or behavior
  changes. Documentation and bug fixes only.
- No migration code, explicit or implicit, may be added for a C release.
- A database written by any `A.B.C` opens in any other `A.B.C` with no action.

### B — minor (e.g. 1.4.3 → 1.5.0)

- The on-disk format may change. A **direct read** by a previous B is not
  guaranteed: new bytes may need a new reader.
- Interop is still absolute **inside the same A**: every `A.x.y` opens every
  `A.*` database with no user action.
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
- **Direct read by the previous A is not guaranteed.** Opening an old database
  with the new A requires an explicit upgrade command/API. Opening a new
  database with an old A is not supported.
- Upgrade requirements:
  - `VelxoDatabase.upgradeSync(path)` (or CLI) is the only path. It must write
    a full backup before touching data, validate the result, and switch
    atomically.
  - A downgrade path is mandatory: the pre-upgrade backup restored with the
    previous A, or an explicit downgrade tool if one is provided.
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

## Release procedure

1. Classify the change as A, B or C against this policy.
2. Update `formatMajor` / `formatMinor` in `lib/src/version.dart` when the
   on-disk contract changes; update the package version accordingly.
3. Add fixtures: for B, old and new bytes plus the bidirectional matrix; for A,
   an upgrade fixture and a restored-backup fixture.
4. Run the full CI matrix (Linux, macOS, Windows, Chrome, wasm, crash matrix).
5. Update `CHANGELOG.md` and, for A, the upgrade/downgrade guide.
