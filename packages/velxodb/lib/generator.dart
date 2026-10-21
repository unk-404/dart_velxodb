/// Typed model code generation.
///
/// ```dart
/// import 'package:velxodb/generator.dart';
///
/// final source = generateModel(ModelSpec(...));
/// ```
library;

export 'src/generator/generator.dart';
export 'src/query/schema.dart' show DocumentSchema, Field, TypedCollection;
