import 'package:PiliPlus/pages/live_room/live_startup_monitor.dart';
import 'package:material_ui/material_ui.dart';

/// Source acquisition can fail while a sheet or another page covers the room.
/// Keep a visible recovery action when the room is shown again.
class LiveStartupPlaceholder extends StatelessWidget {
  const LiveStartupPlaceholder({
    super.key,
    required this.phase,
    required this.onRetry,
  });
  final LiveStartupPhase phase;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final waiting = const {
      LiveStartupPhase.requestingSource,
      LiveStartupPhase.preparingPlayer,
      LiveStartupPhase.waitingMedia,
      LiveStartupPhase.retrying,
    }.contains(phase);
    final message = switch (phase) {
      LiveStartupPhase.failed => '直播加载未能恢复，请重试',
      LiveStartupPhase.cancelled => '直播尚未载入',
      LiveStartupPhase.progressing => '直播播放会话需要重新加载',
      _ => '正在加载直播',
    };
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (waiting) ...[
              const CircularProgressIndicator(),
              const SizedBox(height: 12),
            ],
            Text(message, textAlign: TextAlign.center),
            if (!waiting) ...[
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('重试直播'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
