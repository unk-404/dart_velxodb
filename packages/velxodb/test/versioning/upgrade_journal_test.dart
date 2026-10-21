@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:velxodb/storage.dart';
import 'package:velxodb/velxodb.dart';

Uint8List bytes(String value) => Uint8List.fromList(value.codeUnits);

void writeFile(MemoryStorageDirectory directory, String name, Uint8List data) {
  final file = directory.openSync(name);
  try {
    file.writeAllSync(data);
  } finally {
    file.closeSync();
  }
}

Uint8List readFile(MemoryStorageDirectory directory, String name) {
  final file = directory.openSync(name, create: false);
  try {
    return Uint8List.fromList(file.readAllSync());
  } finally {
    file.closeSync();
  }
}

void main() {
  test('rollback restores writes, creations and deletions exactly', () {
    final directory = MemoryStorageDirectory();
    writeFile(directory, 'data.bin', bytes('abcdef'));
    writeFile(directory, 'gone.bin', bytes('ghost'));

    final journal = UpgradeJournal(directory)..begin();
    journal.recordWrite('data.bin', 2, bytes('cd'));
    writeFile(directory, 'data.bin', bytes('abXYef'));

    journal.recordCreate('new.bin');
    writeFile(directory, 'new.bin', bytes('new'));

    journal.recordDelete('gone.bin', readFile(directory, 'gone.bin'));
    directory.deleteSync('gone.bin');

    journal.rollback();

    expect(readFile(directory, 'data.bin'), bytes('abcdef'));
    expect(readFile(directory, 'gone.bin'), bytes('ghost'));
    expect(directory.existsSync('new.bin'), isFalse);
    expect(directory.existsSync(upgradeJournalFileName), isFalse);
  });

  test('discard drops the journal without touching data', () {
    final directory = MemoryStorageDirectory();
    writeFile(directory, 'data.bin', bytes('abc'));
    final journal = UpgradeJournal(directory)..begin();
    journal.recordWrite('data.bin', 0, bytes('abc'));
    writeFile(directory, 'data.bin', bytes('xyz'));

    journal.discard();

    expect(readFile(directory, 'data.bin'), bytes('xyz'));
    expect(directory.existsSync(upgradeJournalFileName), isFalse);
  });

  test('a torn tail is ignored and the valid prefix still rolls back', () {
    final directory = MemoryStorageDirectory();
    writeFile(directory, 'data.bin', bytes('abcdef'));

    final journal = UpgradeJournal(directory)..begin();
    journal.recordWrite('data.bin', 0, bytes('abc'));
    writeFile(directory, 'data.bin', bytes('XYZdef'));

    final torn = directory.openSync(upgradeJournalFileName);
    try {
      torn.appendSync(bytes('garbage'));
    } finally {
      torn.closeSync();
    }

    journal.rollback();

    expect(readFile(directory, 'data.bin'), bytes('abcdef'));
  });

  test('a bad header is typed corruption', () {
    final directory = MemoryStorageDirectory();
    writeFile(directory, upgradeJournalFileName, bytes('nope'));
    expect(
      () => UpgradeJournal(directory).rollback(),
      throwsA(isA<VelxoCorruptException>()),
    );
  });
}
