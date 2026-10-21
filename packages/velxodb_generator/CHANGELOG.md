## 1.0.0

First public release, matching `velxodb` 1.0.0.

- `ModelSpec` / `FieldSpec` describe a typed model: class name, collection,
  string key field, stable field ids, optional defaults, secondary indexes and
  reference bindings.
- `generateModel` emits plain Dart: `const` field ids, static
  `encodeInto` / `decodeFrom` functions, a typed collection opener, generated
  index creation and reference bindings.
- Validation: non-string key fields, duplicate ids and non-increasing ids are
  rejected at generation time.
