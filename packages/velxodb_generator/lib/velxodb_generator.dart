/// Dev-time code generation for velxodb typed models.
///
/// This package is intentionally separate from `velxodb` so an application can
/// never pull the generator (or a `ModelSpec`) into its dependency graph. Run
/// it from a tool script; it emits plain Dart source.
library;

export 'src/generator.dart';
