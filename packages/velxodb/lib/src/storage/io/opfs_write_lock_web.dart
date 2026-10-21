import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import '../../errors.dart';

@JS('navigator.locks.request')
external JSPromise<JSAny?> _requestLock(
  JSString name,
  JSObject options,
  JSFunction callback,
);

@JS('Promise.withResolvers')
external JSObject? _promiseWithResolvers();

/// Origin-wide exclusive lock over one OPFS database.
///
/// OPFS has no cross-tab mutual exclusion of its own: two tabs opening the same
/// root would interleave writes into one WAL and manifest. The Web Locks API is
/// exactly the primitive for this — the lock lives as long as this object, and
/// the browser releases it automatically when the tab closes or crashes.
///
/// Browsers without the API fall back to no lock; the limitation is documented
/// in the README.
final class OpfsWriteLock {
  OpfsWriteLock._(this._release, this._name);

  final void Function() _release;
  final String _name;
  bool _released = false;

  /// Databases open in this page. Web Locks exclude other tabs; this set
  /// excludes a second handle in the same page (Web Locks are reentrant for one
  /// client, so they cannot do that).
  static final Set<String> _openInPage = <String>{};

  /// Takes the lock called [name], or throws [VelxoLockedException] when another
  /// tab (Web Lock) or another handle in this page already holds it.
  static Future<OpfsWriteLock> acquire(String name) async {
    if (!_openInPage.add(name)) {
      throw VelxoLockedException(
        'the Web database "$name" is already open in this page',
      );
    }
    try {
      return await _acquireCrossTab(name);
    } on Object {
      _openInPage.remove(name);
      rethrow;
    }
  }

  static Future<OpfsWriteLock> _acquireCrossTab(String name) async {
    final deferred = _promiseWithResolvers();
    if (deferred == null) {
      // No Web Locks / Promise.withResolvers in this browser.
      return OpfsWriteLock._(() {}, name);
    }
    final promise = deferred.getProperty<JSAny>('promise'.toJS);
    final resolve = deferred.getProperty<JSFunction>('resolve'.toJS);

    final options = JSObject();
    options.setProperty('mode'.toJS, 'exclusive'.toJS);
    options.setProperty('ifAvailable'.toJS, true.toJS);

    final granted = Completer<bool>();
    final callback = ((JSAny? lock) {
      granted.complete(true);
      // Return a promise that stays pending until release(); resolving it is
      // what releases the Web Lock.
      return promise;
    }).toJS;

    final JSPromise<JSAny?> request;
    try {
      request = _requestLock(name.toJS, options, callback);
    } on Object {
      return OpfsWriteLock._(() {}, name);
    }
    unawaited(
      request.toDart.then(
        (_) {
          if (!granted.isCompleted) granted.complete(false);
        },
        onError: (Object _) {
          if (!granted.isCompleted) granted.complete(false);
        },
      ),
    );
    if (!await granted.future) {
      throw VelxoLockedException(
        'another tab already has the Web database "$name" open',
      );
    }
    return OpfsWriteLock._(() {
      resolve.callAsFunction(null);
    }, name);
  }

  /// Releases the lock, if it is still held.
  Future<void> release() async {
    if (_released) return;
    _released = true;
    _openInPage.remove(_name);
    _release();
  }
}
