// Durability tiers on the real filesystem.
//
//   dart run scenarios/durability_bench.dart
//
// The main suite runs the engine over a counting no-I/O directory, so it never
// pays for an fsync. This scenario is the other half: the same write path over
// `LocalStorageDirectory`, once per `Durability` tier and per API shape.
//
//   always   fsync after every WAL frame
//   batched  fsync on flush / close / sync()   (the default)
//   none     never fsync automatically
//
// It also reports the WAL bytes written per document, i.e. the write
// amplification of the current frame format.
import 'dart:io';
import 'dart:typed_data';

import 'package:blit/blit.dart';
import 'package:velxodb/storage.dart';
import 'package:velxodb_benchmarks/fixtures.dart';
import 'package:velxodb_benchmarks/report.dart';

/// Single-document puts per tier.
const int kSinglePuts = 2000;

/// Documents per batch write.
const int kBatchDocs = 500;

/// Batch writes per tier.
const int kBatches = 20;

/// Documents per transaction.
const int kTxnDocs = 100;

/// Transactions per tier.
const int kTxns = 20;

Future<void> main() async {
  final doc = chatDocument();
  final report = BenchReport(tool: 'velxo-durability');

  for (final tier in Durability.values) {
    final dir = createTempDir('durability_${tier.name}');
    final engine = StorageEngine(
      directory: LocalStorageDirectory(dir.path),
      durability: tier,
    )..openSync();

    try {
      // 1. One frame per put: the fsync cost is per document.
      final putWatch = Stopwatch()..start();
      for (var i = 0; i < kSinglePuts; i++) {
        engine.putSync(_keyOf(i), doc);
      }
      putWatch.stop();
      // WAL bytes for exactly the frames written above.
      final walBytes = _walBytes(dir);

      // 2. One frame per batch of 500.
      final batchWatch = Stopwatch()..start();
      for (var batch = 0; batch < kBatches; batch++) {
        engine.putManySync(<({Uint8List key, Bytes document})>[
          for (var i = 0; i < kBatchDocs; i++)
            (key: _keyOf(batch * kBatchDocs + i), document: doc),
        ]);
      }
      batchWatch.stop();

      // 3. One frame per transaction of 100.
      final txnWatch = Stopwatch()..start();
      for (var txn = 0; txn < kTxns; txn++) {
        engine.transactionSync(() {
          for (var i = 0; i < kTxnDocs; i++) {
            engine.putSync(_keyOf(txn * kTxnDocs + i), doc);
          }
        });
      }
      txnWatch.stop();

      final docsForWal = kSinglePuts;

      report.add(
        BenchmarkResult(
          id: 'durability.${tier.name}.put',
          group: 'Durability',
          label: 'Single put (${tier.name})',
          unit: 'Kdocs/s',
          value: _perSecond(kSinglePuts, putWatch.elapsedMicroseconds) / 1e3,
          note: '$kSinglePuts puts, one WAL frame each',
        ),
      );
      report.add(
        BenchmarkResult(
          id: 'durability.${tier.name}.batch',
          group: 'Durability',
          label: 'Batch put 500 (${tier.name})',
          unit: 'Kdocs/s',
          value:
              _perSecond(
                kBatches * kBatchDocs,
                batchWatch.elapsedMicroseconds,
              ) /
              1e3,
          note: '${kBatches * kBatchDocs} docs, $kBatches frames',
        ),
      );
      report.add(
        BenchmarkResult(
          id: 'durability.${tier.name}.txn',
          group: 'Durability',
          label: 'Transaction 100 (${tier.name})',
          unit: 'Kdocs/s',
          value:
              _perSecond(kTxns * kTxnDocs, txnWatch.elapsedMicroseconds) / 1e3,
          note: '${kTxns * kTxnDocs} docs, $kTxns frames',
        ),
      );
      if (tier == Durability.batched) {
        report.add(
          BenchmarkResult(
            id: 'durability.wal_bytes_per_doc',
            group: 'Durability',
            label: 'WAL bytes per document',
            unit: 'B',
            value: walBytes / docsForWal,
            direction: 'lower',
            note: 'frame overhead included',
          ),
        );
      }

      stdout.writeln(
        '${tier.name.padRight(8)} '
        'put ${(_perSecond(kSinglePuts, putWatch.elapsedMicroseconds) / 1e3).toStringAsFixed(1)} K/s  '
        'batch ${(_perSecond(kBatches * kBatchDocs, batchWatch.elapsedMicroseconds) / 1e3).toStringAsFixed(1)} K/s  '
        'txn ${(_perSecond(kTxns * kTxnDocs, txnWatch.elapsedMicroseconds) / 1e3).toStringAsFixed(1)} K/s  '
        'wal ${(walBytes / docsForWal).toStringAsFixed(1)} B/doc',
      );
    } finally {
      engine.closeSync();
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  }

  report.write('results/durability.json');
  stdout.writeln('wrote results/durability.json (${report.rows.length} rows)');
}

double _perSecond(int ops, int microseconds) {
  if (microseconds <= 0) return 0;
  return ops * 1000000 / microseconds;
}

int _walBytes(Directory dir) {
  final wal = File('${dir.path}/${StorageEngine.walFileName}');
  return wal.existsSync() ? wal.lengthSync() : 0;
}

Uint8List _keyOf(int index) =>
    Uint8List.fromList('key-${index.toString().padLeft(9, '0')}'.codeUnits);
