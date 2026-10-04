import 'package:PiliPlus/services/live_interaction_service.dart';

/// Tracks the cycles of the tasks actually authorized in a room. Watch-only
/// fields cannot certify a like-only authorization, or vice versa.
class LiveIntimacyOfficialCycle {
  final Map<String, int> _counts = {};
  final Map<String, String> _periods = {};
  final Set<String> _uncertain = {};
  Set<String> _required = const {};
  final Set<String> _knownTypes = {};
  final Map<String, int> _generations = {};
  final Map<String, ({int count, String definition})> _resetCandidates = {};
  Object? _lastObservation;

  /// Local journal namespaces, never represented as official period IDs.
  Map<String, int> get confirmedLocalCycles => Map.unmodifiable(_generations);

  bool get uncertain => _required.any(_uncertain.contains);
  bool get confirmed => _required.isNotEmpty && confirmedFor(_required);
  bool confirmedFor(Iterable<String> types) => types.every(
    (type) => _knownTypes.contains(type) && !_uncertain.contains(type),
  );

  Set<String> synchronize(
    List<LiveFanTask> tasks,
    Iterable<String> requiredTypes, {
    Object? observation,
  }) {
    final independent =
        observation != null && !identical(observation, _lastObservation);
    if (observation != null) _lastObservation = observation;
    final resetTypes = <String>{};
    _required = requiredTypes.toSet();
    _knownTypes.clear();
    for (final type in const ['like', 'sendDanmu', 'watchLive']) {
      final matches = tasks.where((task) => task.jumpType == type).toList();
      if (matches.length == 1 && matches.single.completed != null) {
        _knownTypes.add(type);
      }
    }
    for (final type in const ['like', 'sendDanmu', 'watchLive']) {
      final matches = tasks.where((task) => task.jumpType == type).toList();
      if (matches.length != 1) {
        _resetCandidates.remove(type);
        continue;
      }
      final task = matches.single;
      final previous = _counts[type];
      if (task.period.isNotEmpty) {
        final samePeriod = _periods[type] == task.period;
        if (samePeriod &&
            previous != null &&
            task.currentCount != null &&
            task.currentCount! < previous) {
          _uncertain.add(type);
          _resetCandidates.remove(type);
          continue;
        }
        _periods[type] = task.period;
        _uncertain.remove(type);
        _resetCandidates.remove(type);
      } else if (previous != null &&
          task.currentCount != null &&
          task.currentCount! < previous) {
        _uncertain.add(type);
        // Two distinct successful reads must agree on a valid daily task.
        // A smaller quota, lighting transition or missing/contradictory flag
        // cannot provide a fresh write budget.
        final reliableReset =
            task.dailyRewardProgress &&
            !task.completionOnly &&
            task.completed == false &&
            task.currentCount! >= 0 &&
            (task.targetCount ?? 0) > 0 &&
            task.currentCount! < task.targetCount! &&
            !_periods.containsKey(type);
        if (!reliableReset) {
          _resetCandidates.remove(type);
          continue;
        }
        final definition =
            '${task.id}:${task.name}:${task.targetCount}:'
            '${task.actionsPerProgress}';
        final candidate = _resetCandidates[type];
        if (independent &&
            candidate != null &&
            candidate.definition == definition &&
            task.currentCount! >= candidate.count) {
          _generations[type] = (_generations[type] ?? 0) + 1;
          resetTypes.add(type);
          _uncertain.remove(type);
          _resetCandidates.remove(type);
        } else {
          if (independent) {
            _resetCandidates[type] = (
              count: task.currentCount!,
              definition: definition,
            );
          }
          continue;
        }
      } else if (task.currentCount != null) {
        _uncertain.remove(type);
        _resetCandidates.remove(type);
      } else {
        _resetCandidates.remove(type);
      }
      if (task.currentCount != null) _counts[type] = task.currentCount!;
    }
    return Set.unmodifiable(resetTypes);
  }

  /// Failure breaks consecutive confirmation. Restored candidates likewise
  /// require two new reads rather than treating a cached snapshot as proof.
  void interruptConfirmation() => _resetCandidates.clear();

  Map<String, Object> toJson() => {
    'schema': 1,
    'counts': Map.of(_counts),
    'periods': Map.of(_periods),
    'uncertain': _uncertain.toList(),
    'local_cycles': Map.of(_generations),
  };

  void restore(Object? value) {
    if (value is! Map || value['schema'] != 1) return;
    for (final entry in liveMap(value['counts']).entries) {
      final count = liveInt(entry.value);
      if (count != null && count >= 0) _counts[entry.key] = count;
    }
    for (final entry in liveMap(value['periods']).entries) {
      if (entry.value is String) _periods[entry.key] = entry.value as String;
    }
    if (value['uncertain'] is List) {
      _uncertain.addAll((value['uncertain'] as List).whereType<String>());
    }
    for (final entry in liveMap(value['local_cycles']).entries) {
      final generation = liveInt(entry.value);
      if (generation != null && generation > 0) {
        _generations[entry.key] = generation;
      }
    }
    _resetCandidates.clear();
    _lastObservation = null;
    _knownTypes.clear();
  }
}
