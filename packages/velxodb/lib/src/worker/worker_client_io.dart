import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:blit/blit.dart';

import '../errors.dart';
import '../query/database.dart';
import '../storage/engine.dart';
import 'worker_protocol.dart';
import 'worker_types.dart';

/// A client for a database owned by a dedicated worker isolate.
///
/// The worker owns the only [VelxoDatabase]; every call is serialized through
/// one command port, so the single-writer contract holds while many client
/// isolates can issue requests concurrently.
final class VelxoWorker {
  VelxoWorker._(
    this._isolate,
    this._responses,
    this._errors,
    this._errorEvents,
    this._errorsForwarder,
    this._commands,
    this._ownerKey,
  ) {
    _errorSub = _errorEvents.stream.listen((event) {
      _failPending(VelxoWorkerException('worker isolate failed: $event'));
    });
  }

  /// Worker-owned paths in this isolate, so one isolate cannot spawn two
  /// writers for the same directory.
  static final Set<String> _owners = <String>{};

  static String _ownerKeyFor(String path) {
    var key = File(path).absolute.path;
    if (Platform.isWindows || Platform.isMacOS) key = key.toLowerCase();
    return key;
  }

  final Isolate _isolate;
  final ReceivePort _responses;
  final ReceivePort _errors;
  final StreamController<Object?> _errorEvents;
  final StreamSubscription<Object?> _errorsForwarder;
  late StreamSubscription<Object?> _errorSub;
  final SendPort _commands;
  final String _ownerKey;
  final Map<int, Completer<Object?>> _pending = <int, Completer<Object?>>{};
  int _nextId = 0;
  bool _closed = false;

  /// Opens [path] in a new worker isolate.
  static Future<VelxoWorker> open(
    String path, {
    Durability durability = Durability.batched,
    bool backgroundFlush = false,
  }) async {
    final ownerKey = _ownerKeyFor(path);
    if (!_owners.add(ownerKey)) {
      throw VelxoLockedException('database is already open: $path');
    }
    final responses = ReceivePort();
    final errors = ReceivePort();
    final errorEvents = StreamController<Object?>.broadcast();
    final errorSub = errors.listen(errorEvents.add);
    final ready = Completer<SendPort>();
    late VelxoWorker client;

    // One listener for the port's lifetime: handshake first, then responses.
    responses.listen((message) {
      if (!ready.isCompleted) {
        if (message is! List || message.isEmpty) return;
        if (message[0] == 'ready') {
          ready.complete(message[1] as SendPort);
        } else if (message[0] == 'fatal') {
          ready.completeError(
            errorFromCode(message[1] as String, message[2] as String),
          );
        }
        return;
      }
      client._onMessage(message);
    });
    final preReady = errorEvents.stream.listen((event) {
      if (!ready.isCompleted) {
        ready.completeError(
          VelxoWorkerException('worker failed to start: $event'),
        );
      }
    });

    Isolate? isolate;
    try {
      isolate = await Isolate.spawn(
        _workerMain,
        <Object?>[responses.sendPort, path, backgroundFlush, durability.name],
        onError: errors.sendPort,
        onExit: errors.sendPort,
        errorsAreFatal: true,
        debugName: 'velxodb-worker',
      );
      final commands = await ready.future.timeout(const Duration(seconds: 30));
      await preReady.cancel();
      client = VelxoWorker._(
        isolate,
        responses,
        errors,
        errorEvents,
        errorSub,
        commands,
        ownerKey,
      );
      return client;
    } on Object {
      _owners.remove(ownerKey);
      isolate?.kill(priority: Isolate.immediate);
      await preReady.cancel();
      await errorSub.cancel();
      errors.close();
      responses.close();
      await errorEvents.close();
      rethrow;
    }
  }

  void _onMessage(Object? message) {
    if (message is! List || message.length < 2) return;
    final id = message[0] as int;
    final completer = _pending.remove(id);
    if (completer == null) return;
    if (message[1] == true) {
      completer.complete(message.length > 2 ? message[2] : null);
    } else {
      final error = message[2] as List<Object?>;
      completer.completeError(
        errorFromCode(error[0] as String, error[1] as String),
      );
    }
  }

  void _failPending(VelxoException error) {
    final pending = _pending.values.toList();
    _pending.clear();
    for (final completer in pending) {
      completer.completeError(error);
    }
  }

  Future<Object?> _request(String op, List<Object?> args) {
    if (_closed) {
      return Future<Object?>.error(
        const VelxoClosedException('worker is closed'),
      );
    }
    final id = _nextId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _commands.send(<Object?>[id, op, ...args]);
    return completer.future;
  }

  /// Reads one document, returning its raw VXS bytes.
  Future<Uint8List?> get(String collection, Uint8List key) async =>
      await _request('get', <Object?>[collection, key]) as Uint8List?;

  /// Inserts or replaces one document.
  Future<void> put(String collection, Uint8List key, Uint8List value) async {
    await _request('put', <Object?>[
      collection,
      key,
      TransferableTypedData.fromList(<Uint8List>[value]),
    ]);
  }

  /// Deletes one document. Deleting a missing key is allowed.
  Future<void> delete(String collection, Uint8List key) async {
    await _request('delete', <Object?>[collection, key]);
  }

  /// Returns one page plus the key to resume after.
  Future<WorkerPage> page(
    String collection, {
    Uint8List? prefix,
    Uint8List? after,
    int limit = 100,
  }) async {
    final result = await _request('page', <Object?>[
      collection,
      prefix,
      after,
      limit,
    ]) as List<Object?>;
    final rawEntries = result[0] as List<Object?>;
    final entries = <WorkerEntry>[
      for (final raw in rawEntries)
        (
          key: (raw as List<Object?>)[0] as Uint8List,
          value: raw[1] as Uint8List,
        ),
    ];
    return (entries: entries, next: result[1] as Uint8List?);
  }

  /// Flushes the worker's memtable into a segment.
  Future<void> flush() async {
    await _request('flush', const <Object?>[]);
  }

  /// Waits for a background segment build inside the worker.
  Future<void> waitForMaintenance() async {
    await _request('wait', const <Object?>[]);
  }

  /// Runs the read-only integrity check inside the worker.
  Future<WorkerCheck> check() async {
    final result = await _request('check', const <Object?>[]) as List<Object?>;
    final stats = <String, int>{
      for (final entry in (result[2] as Map<Object?, Object?>).entries)
        entry.key as String: entry.value as int,
    };
    return WorkerCheck(
      ok: result[0] as bool,
      issues: (result[1] as List<Object?>).cast<String>(),
      stats: stats,
    );
  }

  /// Closes the worker's database and terminates the isolate.
  Future<void> close({bool flush = false}) async {
    if (_closed) return;
    try {
      await _request('close', <Object?>[flush]);
    } on Object {
      // The worker may already be gone; still release local resources.
    }
    _closed = true;
    _owners.remove(_ownerKey);
    _failPending(const VelxoClosedException('worker is closed'));
    await _errorSub.cancel();
    await _errorsForwarder.cancel();
    _errors.close();
    _responses.close();
    await _errorEvents.close();
    _isolate.kill(priority: Isolate.beforeNextEvent);
  }
}

void _workerMain(List<Object?> args) {
  final responses = args[0] as SendPort;
  final path = args[1] as String;
  final backgroundFlush = args[2] as bool;
  final durability = Durability.values.byName(args[3] as String);
  final commands = ReceivePort();

  VelxoDatabase? database;
  try {
    database = VelxoDatabase.openSync(
      path,
      backgroundFlush: backgroundFlush,
      durability: durability,
    );
  } on Object catch (error) {
    responses.send(<Object?>['fatal', errorCode(error), '$error']);
    commands.close();
    return;
  }
  responses.send(<Object?>['ready', commands.sendPort]);

  Future<void> chain = Future<void>.value();
  commands.listen((message) {
    chain = chain.then((_) async {
      if (message is! List || message.length < 2) return;
      final id = message[0] as int;
      final op = message[1] as String;
      try {
        final result = await _dispatch(database!, op, message.sublist(2));
        responses.send(<Object?>[id, true, result]);
        if (op == 'close') commands.close();
      } on Object catch (error) {
        responses.send(<Object?>[
          id,
          false,
          <Object?>[errorCode(error), '$error'],
        ]);
      }
    });
  });
}

Future<Object?> _dispatch(
  VelxoDatabase database,
  String op,
  List<Object?> args,
) async {
  switch (op) {
    case 'get':
      final bytes = database
          .collectionOrNull(args[0] as String)
          ?.get(args[1] as Uint8List);
      return bytes == null ? null : Uint8List.fromList(bytes.asUint8List());
    case 'put':
      final transfer = args[2] as TransferableTypedData;
      final bytes = transfer.materialize().asUint8List();
      database
          .collection(args[0] as String)
          .putSync(args[1] as Uint8List, Bytes.view(bytes, 0, bytes.length));
      return null;
    case 'delete':
      database
          .collectionOrNull(args[0] as String)
          ?.deleteSync(args[1] as Uint8List);
      return null;
    case 'page':
      final collection = database.collectionOrNull(args[0] as String);
      if (collection == null) {
        return <Object?>[<Object?>[], null];
      }
      final page = collection.pageSync(
        prefix: args[1] as Uint8List?,
        after: args[2] as Uint8List?,
        limit: args[3] as int,
      );
      return <Object?>[
        <Object?>[
          for (final entry in page.entries)
            <Object?>[
              Uint8List.fromList(entry.key),
              Uint8List.fromList(entry.value.asUint8List()),
            ],
        ],
        page.next == null ? null : Uint8List.fromList(page.next!),
      ];
    case 'flush':
      database.flushSync();
      return null;
    case 'wait':
      await database.waitForMaintenance();
      return null;
    case 'check':
      final report = database.checkSync();
      return <Object?>[
        report.ok,
        <String>[for (final issue in report.issues) issue.toString()],
        report.stats,
      ];
    case 'close':
      database.closeSync(flush: args[0] as bool);
      return null;
    default:
      throw VelxoWorkerException('unknown worker operation: $op');
  }
}
