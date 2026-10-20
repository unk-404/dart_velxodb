# velxodb

Embedded, pure-Dart document database with zero-copy storage, pluggable object
stores and Mongo-style APIs.

See the [workspace README](../../README.md) for the project overview and roadmap.

## Getting started

```dart
import 'package:velxodb/velxodb.dart';

void main() {
  print(velxodbVersion);
}
```

## Design notes

- Documents are stored in a field-addressable binary layout (`VXS`); reading a
  document allocates nothing until a value is materialized.
- Storage is an immutable-segment log-structured engine; the manifest is the only
  object that needs compare-and-swap, which is what makes object stores viable.
- Extension points (`Analyzer`, `Scorer`, `FieldCodec`, `IndexProvider`,
  `ObjectStore`) are resolved once when a database is opened, never per record.

## License

MIT.
