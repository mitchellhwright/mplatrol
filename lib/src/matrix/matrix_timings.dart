import 'dart:convert';
import 'dart:io';

import 'package:mplatrol/src/matrix/matrix_leg.dart';
import 'package:path/path.dart' as p;

/// One leg's lane and times from `queue.log`.
typedef MatrixQueueLeg = ({String lane, DateTime? start, DateTime? released, DateTime? finish, int? exit});

final _queueLine = RegExp(r'^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) (\S+) (start|released|finish) '
    r'([a-z0-9]+:(?:lt-)?(?:ios|android))(?:@.*?)?(?: exit (\d+))?$');

/// The legs of a `queue.log` by leg spec (`<tenant>:<variant>`) from its [lines], and every timestamp
/// the lines start with, in order.
({Map<String, MatrixQueueLeg> legs, List<DateTime> stamps}) parseMatrixQueue(List<String> lines) {
  final legs = <String, MatrixQueueLeg>{};
  final stamps = <DateTime>[];
  for (final raw in lines) {
    final at = raw.length >= 19 ? DateTime.tryParse(raw.substring(0, 19)) : null;
    if (at != null) {
      stamps.add(at);
    }
    final match = _queueLine.firstMatch(raw.trim());
    if (match == null) {
      continue;
    }
    final time = DateTime.parse(match[1]!);
    final old = legs[match[4]!] ?? (lane: match[2]!, start: null, released: null, finish: null, exit: null);
    legs[match[4]!] = switch (match[3]) {
      'start' => (lane: old.lane, start: time, released: old.released, finish: old.finish, exit: old.exit),
      'released' => (lane: old.lane, start: old.start, released: time, finish: old.finish, exit: old.exit),
      _ => (lane: old.lane, start: old.start, released: old.released, finish: time, exit: int.tryParse(match[5] ?? '')),
    };
  }
  return (legs: legs, stamps: stamps..sort());
}

/// The wall clock of a matrix run, per leg and per phase, as Markdown.
///
/// Phases of a leg come from its timestamped console (`<key>.log.times`):
/// prepare (start to "Prepared for the login E2E"), build (to the first upload
/// or an artifact-cache hit), upload (to `[lane-release]`) and LambdaTest
/// (release to exit; none for a local leg, which holds its lane until it
/// exits). "Lane busy" is start to release. The peak concurrent
/// LambdaTest sessions come from [usageLog] (the session budget's log).
class MatrixTimings {
  /// Creates a report reader; [usageLog] is `~/.mplatrol/lt-slots/usage.log`.
  MatrixTimings({this.usageLog});

  /// The session budget's grant/release log, or null to leave peak sessions out.
  final String? usageLog;

  /// The report of the run in [run].
  String report(MatrixRunDir run) {
    final (legs, start, end) = _queue(run);
    final out = StringBuffer()
      ..writeln('## ${run.id}: ${_fmt(end.difference(start))} wall clock '
          '(${_hhmm(start)} to ${_hhmm(end)}), ${legs.length} legs');
    final peak = _peakSessions(start, end);
    if (peak != null) {
      out.writeln('peak concurrent LambdaTest sessions: $peak');
    }
    out
      ..writeln(
          '| leg | lane | exit | leg total | lane busy | prepare | build | upload | LT after release | LambdaTest |')
      ..writeln('|---|---|---|---|---|---|---|---|---|---|');
    for (final MapEntry(key: spec, value: leg) in legs.entries) {
      final phases = _phases(run, MatrixLeg.parse(spec)!, leg);
      out.writeln('| $spec | ${leg.lane} | ${leg.exit ?? '?'} | ${_span(leg.start, leg.finish)} | '
          '${_span(leg.start, leg.released ?? leg.finish)} | ${_fmt(phases['prepare'])} | ${_fmt(phases['build'])} | '
          '${_fmt(phases['upload'])} | ${_fmt(phases['lt'])} | ${_dashboardLinks(run, MatrixLeg.parse(spec)!)} |');
    }
    return out.toString();
  }

  /// Markdown links to the HyperExecute job and App Automation build pages the leg's `summary.json` records,
  /// or `-` when it recorded none.
  String _dashboardLinks(MatrixRunDir run, MatrixLeg leg) {
    final file = File(p.join(run.legDir(leg), 'reports', 'summary.json'));
    if (!file.existsSync()) {
      return '-';
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(file.readAsStringSync());
    } on FormatException {
      return '-';
    }
    final legs = decoded is Map ? decoded['Legs'] : null;
    final links = <String>[];
    for (final entry in legs is List ? legs.whereType<Map>() : const <Map>[]) {
      for (final (label, key) in [('job', 'hyperexecuteJobUrl'), ('build', 'ltBuildUrl')]) {
        final urls = entry[key];
        for (final url in urls is String ? urls.split(' ') : const <String>[]) {
          links.add('[$label]($url)');
        }
      }
    }
    return links.isEmpty ? '-' : links.join(' ');
  }

  (Map<String, MatrixQueueLeg>, DateTime, DateTime) _queue(MatrixRunDir run) {
    final (:legs, :stamps) = parseMatrixQueue(File(run.queueLog).readAsLinesSync());
    return (legs, stamps.first, stamps.last);
  }

  Map<String, Duration> _phases(MatrixRunDir run, MatrixLeg leg, MatrixQueueLeg times) {
    final file = File(run.times(leg));
    final start = times.start;
    if (start == null || !file.existsSync()) {
      return const {};
    }
    final marks = <String, DateTime>{};
    for (final raw in file.readAsLinesSync()) {
      final at = _clockTime(raw, start);
      if (at == null) {
        continue;
      }
      final body = raw.substring(9);
      for (final (name, seen) in [
        ('prepared', body.contains('Prepared for the login E2E')),
        ('upload', body.contains('Uploading ') || body.contains('[artifact-cache] hit')),
        ('released', body.contains('[lane-release]')),
      ]) {
        if (seen) {
          marks.putIfAbsent(name, () => at);
        }
      }
    }
    final released = marks['released'] ?? times.released;
    return {
      if (marks['prepared'] != null) 'prepare': marks['prepared']!.difference(start),
      if (marks['prepared'] != null && marks['upload'] != null)
        'build': marks['upload']!.difference(marks['prepared']!),
      if (marks['upload'] != null && released != null) 'upload': released.difference(marks['upload']!),
      if (released != null && times.finish != null) 'lt': times.finish!.difference(released),
    };
  }

  /// The `HH:MM:SS` at the start of [raw] on [start]'s day (or the next day
  /// for a time before the leg started), or null.
  DateTime? _clockTime(String raw, DateTime start) {
    final match = RegExp(r'^(\d\d):(\d\d):(\d\d) ').firstMatch(raw);
    if (match == null) {
      return null;
    }
    var at =
        DateTime(start.year, start.month, start.day, int.parse(match[1]!), int.parse(match[2]!), int.parse(match[3]!));
    if (at.isBefore(start.subtract(const Duration(minutes: 1)))) {
      at = at.add(const Duration(days: 1));
    }
    return at;
  }

  int? _peakSessions(DateTime start, DateTime end) {
    final path = usageLog;
    if (path == null || !File(path).existsSync()) {
      return null;
    }
    var peak = 0;
    for (final line in File(path).readAsLinesSync()) {
      final at = DateTime.tryParse(line.split(' ').first);
      final inUse = int.tryParse(RegExp(r'inUse=(\d+)/').firstMatch(line)?[1] ?? '');
      if (at != null && inUse != null && !at.isBefore(start) && !at.isAfter(end) && inUse > peak) {
        peak = inUse;
      }
    }
    return peak;
  }

  String _span(DateTime? from, DateTime? to) => from == null || to == null ? '—' : _fmt(to.difference(from));

  String _hhmm(DateTime at) => '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';

  String _fmt(Duration? duration) {
    if (duration == null) {
      return '—';
    }
    final minutes = duration.inMinutes;
    final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
    return minutes >= 60 ? '${minutes ~/ 60}h${(minutes % 60).toString().padLeft(2, '0')}m' : '${minutes}m${seconds}s';
  }
}

/// `~/.mplatrol/lt-slots/usage.log` for [home], or null without one.
String? matrixUsageLog(String? home) =>
    home == null || home.isEmpty ? null : p.join(home, '.mplatrol', 'lt-slots', 'usage.log');
