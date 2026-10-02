/// One lease per media owner. Returning to an old route acquires a fresh lease,
/// so its earlier room requests cannot overwrite the current media context.
typedef LivePlaybackLease = ({Object owner, int generation});

/// The caller serializes native commands and captures the source, owner and
/// playing intent in [stillAllowed]. Re-check after each asynchronous command.
Future<void> recoverLivePlayback({
  required bool Function() stillAllowed,
  required Future<void> Function() openPaused,
  required Future<void> Function() play,
  required void Function() onRecovered,
}) async {
  if (!stillAllowed()) return;
  await openPaused();
  if (!stillAllowed()) return;
  await play();
  if (!stillAllowed()) return;
  onRecovered();
}

class LivePlaybackGate {
  Object? _owner;
  int _generation = 0;
  bool _roomLive = false;
  bool _healthy = false;

  LivePlaybackLease claim(Object owner, {bool preserveSource = false}) {
    if (!identical(_owner, owner)) {
      _owner = owner;
      ++_generation;
      if (!preserveSource) {
        _roomLive = false;
        _healthy = false;
      }
    }
    return (owner: owner, generation: _generation);
  }

  bool owns(Object owner) => identical(_owner, owner);
  LivePlaybackLease? get lease =>
      _owner == null ? null : (owner: _owner!, generation: _generation);
  bool accepts(LivePlaybackLease lease) =>
      owns(lease.owner) && lease.generation == _generation;
  bool get allowed => _roomLive && _healthy;
  bool get roomLive => _roomLive;

  void confirmRoom(LivePlaybackLease lease, {required bool live}) {
    if (!accepts(lease)) return;
    _roomLive = live;
    if (!live) _healthy = false;
  }

  void sourceChanging() => _healthy = false;
  void sourceOpened() => _healthy = true;
  void sourceFailed() => _healthy = false;
  void roomEnded() {
    _roomLive = false;
    _healthy = false;
  }

  void clear() {
    _owner = null;
    ++_generation;
    _roomLive = false;
    _healthy = false;
  }
}
