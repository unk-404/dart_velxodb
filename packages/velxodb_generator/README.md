# velxodb_generator

Development-time model and codec generator for
[velxodb](https://pub.dev/packages/velxodb).

It turns a `ModelSpec` into plain Dart source: `const` field ids, static
`encodeInto` / `decodeFrom` functions, index declarations and reference
bindings. There is no reflection and no runtime code generation; the generated
file is committed and compiled like hand-written code.

## Install

```yaml
dev_dependencies:
  velxodb_generator: ^1.0.0
```

Requires Dart `^3.13.0`. The generator has no runtime dependency; it is meant to
run from a `tool/` script, never from application startup.

```dart
import 'package:velxodb_generator/velxodb_generator.dart';

const spec = ModelSpec(
  className: 'Product',
  collectionName: 'products',
  keyField: 'id',
  fields: <FieldSpec>[
    FieldSpec('id', 1, FieldKind.string),
    FieldSpec('name', 2, FieldKind.string, indexed: true),
    FieldSpec('category', 3, FieldKind.string, indexed: true),
    FieldSpec('updatedAt', 4, FieldKind.int64, indexed: true),
    FieldSpec('description', 5, FieldKind.string),
  ],
);

final source = generateModel(spec); // write it to a .g.dart file
```

Field ids are part of the on-disk contract: never reuse or reorder them. The
generator rejects non-string key fields and duplicate or non-positive ids.

## License

MIT.
