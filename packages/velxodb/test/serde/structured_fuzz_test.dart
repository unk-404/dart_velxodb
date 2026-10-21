@TestOn('vm')
library;

import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:velxodb/serde.dart';

/// Structured fuzzing: start from a *valid* document, mutate framing bytes, and
/// require that the parser either succeeds or raises [VxsFormatException].
///
/// Random-byte fuzzing almost never produces a valid header, so it exercises
/// very little of the parser. Mutating real documents reaches length prefixes,
/// extended keys, list counts and the checksum trailer.
void main() {
  test('mutated documents only ever raise VxsFormatException', () {
    final random = Random(0x5158DA7A);
    var parsed = 0;
    var rejected = 0;

    for (var iteration = 0; iteration < 4000; iteration++) {
      final generated = _randomDocument(random);
      final mutated = _mutate(random, generated.bytes);
      try {
        final view = DocView.parse(mutated);
        parsed++;
        view.forEachField((cursor) {
          cursor.wireType;
          cursor.valueLength;
        });
        view.validate(generated.schema);
        if (view.hasChecksum) {
          try {
            view.verifyChecksum();
          } on VxsFormatException {
            // A corrupted body is allowed to fail verification.
          }
        }
      } on VxsFormatException {
        rejected++;
      }
    }

    // Both outcomes must occur, otherwise the test is not exercising anything.
    expect(parsed, greaterThan(100));
    expect(rejected, greaterThan(100));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('unmutated documents always validate', () {
    final random = Random(7);
    for (var i = 0; i < 200; i++) {
      final generated = _randomDocument(random, checksum: i.isEven);
      final bytes = Uint8List.fromList(generated.bytes);
      final view = DocView.parseVerified(bytes);
      expect(view.validate(generated.schema), isEmpty);
    }
  });
}

typedef _Generated = ({Uint8List bytes, VxsSchema schema});

_Generated _randomDocument(Random random, {bool checksum = false}) {
  final count = 1 + random.nextInt(6);
  final ids = <int>{};
  while (ids.length < count) {
    ids.add(1 + random.nextInt(12));
  }
  final sorted = ids.toList()..sort();

  final builder = DocBuilder(schemaId: 1, schemaVersion: 1);
  final fields = <VxsField>[];
  for (final id in sorted) {
    final kind = random.nextInt(6);
    switch (kind) {
      case 0:
        // Dart's Random.nextInt caps at 2^32, so build a wider value by hand.
        final magnitude = random.nextInt(1 << 31);
        builder.putInt(id, random.nextBool() ? magnitude : -magnitude);
        fields.add(VxsField(id, 'i$id', VxsType.int64));
      case 1:
        builder.putString(id, _randomText(random));
        fields.add(VxsField(id, 's$id', VxsType.string));
      case 2:
        builder.putBool(id, random.nextBool());
        fields.add(VxsField(id, 'b$id', VxsType.boolean));
      case 3:
        builder.putFloat64(id, random.nextDouble() * 1000 - 500);
        fields.add(VxsField(id, 'f$id', VxsType.float64));
      case 4:
        builder.putStringList(id, <String>[
          _randomText(random),
          _randomText(random),
        ]);
        fields.add(VxsField(id, 'sl$id', VxsType.stringList));
      default:
        builder.putBytes(
          id,
          List<int>.generate(random.nextInt(20), (_) => random.nextInt(256)),
        );
        fields.add(VxsField(id, 'b$id', VxsType.bytes));
    }
  }
  final bytes = builder.finish(checksum: checksum);
  return (
    bytes: Uint8List.fromList(bytes.asUint8List()),
    schema: VxsSchema(id: 1, version: 1, fields: fields),
  );
}

String _randomText(Random random) {
  final pieces = <String>[
    'a',
    'conv-42',
    '中文消息',
    '😀',
    'hello world',
    '',
    '0' * 200,
  ];
  return pieces[random.nextInt(pieces.length)];
}

Uint8List _mutate(Random random, Uint8List source) {
  final out = Uint8List.fromList(source);
  switch (random.nextInt(6)) {
    case 0:
      // Flip one byte.
      final at = random.nextInt(out.length);
      out[at] ^= 1 << random.nextInt(8);
    case 1:
      // Truncate.
      final length = random.nextInt(out.length);
      return Uint8List.sublistView(out, 0, length);
    case 2:
      // Append garbage.
      final extra = Uint8List(random.nextInt(8) + 1);
      for (var i = 0; i < extra.length; i++) {
        extra[i] = random.nextInt(256);
      }
      final grown = Uint8List(out.length + extra.length)
        ..setRange(0, out.length, out)
        ..setRange(out.length, out.length + extra.length, extra);
      return grown;
    case 3:
      // Set a byte to 0xFF (breaks varint continuation / length prefixes).
      out[random.nextInt(out.length)] = 0xFF;
    case 4:
      // Corrupt a length-prefix-looking byte somewhere in the body.
      final bodyStart = vxsHeaderSize;
      if (out.length > bodyStart) {
        final at = bodyStart + random.nextInt(out.length - bodyStart);
        out[at] = random.nextBool() ? 0xFF : 0x7F;
      }
    default:
      // Leave it valid.
      break;
  }
  return out;
}
