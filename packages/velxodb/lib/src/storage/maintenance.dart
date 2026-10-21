import 'dart:async';

/// Runs maintenance work (flush, compaction) outside the write that triggered
/// it.
///
/// This is the seam for the concurrency model: today the engine is single
/// isolate, so the default implementation only defers work to a microtask. A
/// future worker isolate implements the same interface with a real background
/// isolate; the engine does not change.
abstract interface class MaintenanceScheduler {
  /// Schedules [task] to run later on the engine's isolate.
  void schedule(void Function() task);
}

/// Defers maintenance to a microtask after the current write returns.
///
/// The task still runs on the same isolate, so it is cooperative: the event
/// loop is blocked while the segment is built, but the write that crossed the
/// memtable threshold no longer pays for it.
final class MicrotaskMaintenanceScheduler implements MaintenanceScheduler {
  /// Creates a scheduler.
  const MicrotaskMaintenanceScheduler();

  @override
  void schedule(void Function() task) => scheduleMicrotask(task);
}
