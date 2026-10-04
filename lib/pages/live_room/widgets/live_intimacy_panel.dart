import 'package:PiliPlus/pages/live_room/widgets/live_intimacy_controls.dart';
import 'package:PiliPlus/pages/live_room/widgets/live_intimacy_progress_widgets.dart';
import 'package:PiliPlus/services/live_intimacy_scheduler.dart';
import 'package:PiliPlus/services/live_interaction_service.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/live_intimacy_preferences.dart';
import 'package:material_ui/material_ui.dart';

/// Separate from the gift panel, so its authorization entry survives hiding
/// the optional enhanced interface and does not alter a manual message draft.
class LiveIntimacyRoomPanel extends StatefulWidget {
  const LiveIntimacyRoomPanel({
    super.key,
    required this.roomId,
    required this.anchorUid,
    required this.anchorName,
  });
  final int roomId;
  final int anchorUid;
  final String anchorName;

  @override
  State<LiveIntimacyRoomPanel> createState() => _LiveIntimacyRoomPanelState();
}

class _LiveIntimacyRoomPanelState extends State<LiveIntimacyRoomPanel> {
  late LiveInteractionService _interaction = LiveInteractionService(
    roomId: widget.roomId,
    anchorUid: widget.anchorUid,
  );

  @override
  void didUpdateWidget(covariant LiveIntimacyRoomPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.roomId != widget.roomId ||
        oldWidget.anchorUid != widget.anchorUid) {
      _interaction.dispose();
      _interaction = LiveInteractionService(
        roomId: widget.roomId,
        anchorUid: widget.anchorUid,
      );
    }
  }

  @override
  void dispose() {
    _interaction.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheduler = LiveIntimacyScheduler.instance;
    return AnimatedBuilder(
      animation: scheduler,
      builder: (context, _) {
        final account = Accounts.main;
        final generation = Accounts.mainChangeGeneration;
        final roomId = widget.roomId;
        final anchorUid = widget.anchorUid;
        bool current() =>
            mounted &&
            !Accounts.mainIdentityChangeInProgress &&
            identical(account, Accounts.main) &&
            generation == Accounts.mainChangeGeneration &&
            roomId == widget.roomId &&
            anchorUid == widget.anchorUid;
        final state = scheduler.stateFor(roomId, anchorUid);
        final preferences =
            (state?.preferences ??
                    scheduler.preferences.roomFor(roomId, anchorUid) ??
                    LiveIntimacyRoomPreferences(
                      roomId: roomId,
                      anchorUid: anchorUid,
                    ))
                .copyWith(roomId: roomId, anchorName: widget.anchorName);
        return LiveIntimacyRoomControls(
          key: ValueKey('intimacy-controls:$anchorUid:$roomId'),
          preferences: preferences,
          loggedIn: scheduler.isLoggedIn && current(),
          accountIdentity: account,
          accountGeneration: generation,
          globalEnabled: scheduler.preferences.enabled,
          onChanged: (value) async {
            if (current()) await scheduler.saveRoomPreferences(value);
          },
          onAuthorize: (value, enabled) async {
            if (!current()) return '账号或房间已变化，请重新打开配置';
            return scheduler.authorizeRoom(value, enabled);
          },
          loadEmoticons: _interaction.loadTaskEmoticons,
          statusText: state == null
              ? preferences.configurationIssue() ?? '已保存此房间配置；总开关和房间授权均开启后才执行。'
              : liveIntimacyRoomStatusSummary(state),
          progress: state == null
              ? null
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Text(liveIntimacyTaskSummary(state.tasks)),
                    ),
                    liveIntimacyProgressView(state),
                  ],
                ),
        );
      },
    );
  }
}
