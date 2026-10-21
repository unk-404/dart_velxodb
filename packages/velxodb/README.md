# velxodb

Embedded, pure-Dart document database. Local-first: memory-mapped immutable
segments, zero-copy documents, WAL-backed writes. The same segment format is
served unchanged by the object-store backend.

See the [workspace README](../../README.md) for the architecture, performance
numbers and roadmap.

## Getting started

```dart
import 'package:velxodb/velxodb.dart';

final db = VelxoDatabase.openSync('data/chat');
final messages = db.collection('messages');

messages.putSync(key, encodedDocument);
final document = messages.getSync(key);          // Bytes?
final recent = messages.scanSync(start: since, limit: 50);
```

## Generated models

Add `velxodb_generator` as a dev dependency, describe the model, and generate
plain Dart (const field ids, static codecs, index and reference setup):

```dart
const spec = ModelSpec(
  className: 'ChatMessage',
  collectionName: 'messages',
  keyField: 'id',
  fields: <FieldSpec>[
    FieldSpec('id', 1, FieldKind.string),
    FieldSpec('senderId', 3, FieldKind.string, indexed: true),
  ],
);
final source = generateModel(spec);
```

## Design notes

- Documents use a field-addressable binary layout (`VXS`); reading a value
  allocates nothing until it is materialized.
- Segments are immutable; the manifest is the only object replaced on commit.
  That single property is what makes both crash recovery and non-file backends
  simple.
- Secondary indexes, reference bindings and graph edges live in the same
  key/value engine under their own two-byte namespaces; a document and its
  derived entries commit in one WAL frame.
- I/O stays at the edge: the format and the engine are tested without a
  filesystem, and the local (mmap) and object-store backends share every codec.

## License

MIT.
