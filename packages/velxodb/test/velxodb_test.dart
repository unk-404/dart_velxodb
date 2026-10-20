import 'package:test/test.dart';
import 'package:velxodb/velxodb.dart';

void main() {
  test('exposes a semantic version', () {
    expect(velxodbVersion, matches(RegExp(r'^\d+\.\d+\.\d+')));
  });
}
