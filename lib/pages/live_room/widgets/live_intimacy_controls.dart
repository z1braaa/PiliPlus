import 'package:PiliPlus/common/widgets/image/network_img_layer.dart';
import 'package:PiliPlus/models/common/image_type.dart';
import 'package:PiliPlus/services/live_interaction_service.dart';
import 'package:PiliPlus/utils/live_intimacy_preferences.dart';
import 'package:PiliPlus/utils/live_viewer_preferences.dart';
import 'package:material_ui/material_ui.dart';

/// Room authorization is explicit; editing its content never grants permission.
class LiveIntimacyRoomControls extends StatefulWidget {
  const LiveIntimacyRoomControls({
    super.key,
    required this.preferences,
    required this.loggedIn,
    required this.accountIdentity,
    required this.accountGeneration,
    required this.onChanged,
    required this.onAuthorize,
    required this.loadEmoticons,
    this.statusText,
    this.progress,
    this.globalEnabled = false,
  });

  final LiveIntimacyRoomPreferences preferences;
  final bool loggedIn;
  final Object? accountIdentity;
  final int accountGeneration;
  final Future<void> Function(LiveIntimacyRoomPreferences)? onChanged;
  final Future<String?> Function(LiveIntimacyRoomPreferences, bool)?
  onAuthorize;
  final Future<List<LiveTaskEmoticonOption>> Function() loadEmoticons;
  final String? statusText;
  final Widget? progress;
  final bool globalEnabled;

  @override
  State<LiveIntimacyRoomControls> createState() =>
      _LiveIntimacyRoomControlsState();
}

class _LiveIntimacyRoomControlsState extends State<LiveIntimacyRoomControls> {
  bool _busy = false;
  String? _error;
  int _scope = 0;
  ModalRoute<dynamic>? _editor;
  bool get _editable => widget.loggedIn && widget.onChanged != null && !_busy;

  void _closeEditor() {
    final route = _editor;
    _editor = null;
    if (route != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (route.isActive) route.navigator?.removeRoute(route);
      });
    }
  }

  @override
  void didUpdateWidget(covariant LiveIntimacyRoomControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.accountIdentity, widget.accountIdentity) ||
        oldWidget.accountGeneration != widget.accountGeneration ||
        oldWidget.preferences.key != widget.preferences.key ||
        !widget.loggedIn) {
      ++_scope;
      _busy = false;
      _error = null;
      _closeEditor();
    }
  }

  @override
  void dispose() {
    ++_scope;
    _closeEditor();
    super.dispose();
  }

  Future<void> _save(LiveIntimacyRoomPreferences value) async {
    if (!_editable) return;
    final scope = _scope;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onChanged!(value);
    } catch (_) {
      if (mounted && scope == _scope) _error = '设置保存失败，请重试';
    } finally {
      if (mounted && scope == _scope) setState(() => _busy = false);
    }
  }

  Future<void> _authorize(bool enabled) async {
    if (!_editable || widget.onAuthorize == null) return;
    final scope = _scope;
    final preferences = widget.preferences;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      var issue = enabled ? preferences.configurationIssue() : null;
      if (enabled &&
          issue == null &&
          preferences.automation.danmakuMode == LiveTaskDanmakuMode.emoticon) {
        final options = await widget.loadEmoticons();
        if (!mounted || scope != _scope) return;
        issue = preferences.configurationIssue(
          availableEmoticons: options
              .where((e) => e.available)
              .map((e) => e.unique),
        );
      }
      if (!mounted || scope != _scope) return;
      final result = issue ?? await widget.onAuthorize!(preferences, enabled);
      if (mounted && scope == _scope) _error = result;
    } catch (_) {
      if (mounted && scope == _scope) _error = '无法确认房间资格或表情权限，请刷新后重试';
    } finally {
      if (mounted && scope == _scope) setState(() => _busy = false);
    }
  }

  Future<T?> _dialog<T>(WidgetBuilder builder) async {
    final route = DialogRoute<T>(context: context, builder: builder);
    try {
      _editor = route;
      final result = await Navigator.of(
        context,
        rootNavigator: true,
      ).push(route);
      await route.completed;
      return result;
    } finally {
      if (identical(_editor, route)) _editor = null;
    }
  }

  Future<void> _editText() async {
    if (!_editable) return;
    final scope = _scope;
    final controller = TextEditingController(
      text: widget.preferences.automation.defaultMessage,
    );
    String? value;
    try {
      value = await _dialog<String>(
        (context) => AlertDialog(
          title: const Text('自动发送文字'),
          scrollable: true,
          content: TextField(
            key: const ValueKey('live-intimacy-message-editor'),
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: '填写此直播间要自动发送的内容',
              helperText: '清空后暂停此房间，保留授权选择。',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('保存'),
            ),
          ],
        ),
      );
    } finally {
      controller.dispose();
    }
    if (mounted && scope == _scope && value != null && _editable) {
      await _save(
        widget.preferences.copyWith(
          automation: widget.preferences.automation.copyWith(
            defaultMessage: value,
          ),
        ),
      );
    }
  }

  Future<void> _editEmoticons() async {
    if (!_editable) return;
    final scope = _scope;
    final value = await _dialog<List<LiveIntimacyEmoticonSelection>>(
      (context) => LiveIntimacyEmoticonPicker(
        load: widget.loadEmoticons,
        selected: widget.preferences.emoticons,
      ),
    );
    if (mounted && scope == _scope && value != null && _editable) {
      await _save(widget.preferences.copyWith(emoticons: value));
    }
  }

  @override
  Widget build(BuildContext context) {
    final room = widget.preferences;
    final automation = room.automation;
    final emotes = automation.danmakuMode == LiveTaskDanmakuMode.emoticon;
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            key: const ValueKey('live-intimacy-room-authorized'),
            title: const Text('此房间自动亲密度'),
            subtitle: Text(
              !widget.loggedIn
                  ? '登录后配置和授权'
                  : !room.authorized
                  ? '仅对此账号和直播间授权，首次默认关闭'
                  : !widget.globalEnabled
                  ? '已授权；在其他设置开启总开关后运行'
                  : '已授权；开播且任务未完成时自动排队',
            ),
            value: room.authorized,
            onChanged: _editable && widget.onAuthorize != null
                ? _authorize
                : null,
          ),
          if (_busy) const LinearProgressIndicator(),
          if (_error case final error?)
            Padding(
              key: const ValueKey('live-intimacy-configuration-error'),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          SwitchListTile(
            key: const ValueKey('live-intimacy-auto-like'),
            title: const Text('自动点赞'),
            subtitle: const Text('每次间隔1～3秒，任务完成后停止'),
            value: automation.autoLike,
            onChanged: _editable
                ? (value) => _save(
                    room.copyWith(
                      automation: automation.copyWith(autoLike: value),
                    ),
                  )
                : null,
          ),
          SwitchListTile(
            key: const ValueKey('live-intimacy-auto-danmaku'),
            title: const Text('自动弹幕'),
            subtitle: const Text('每次随机间隔30～60秒，每次发送一条'),
            value: automation.autoDanmaku,
            onChanged: _editable
                ? (value) => _save(
                    room.copyWith(
                      automation: automation.copyWith(autoDanmaku: value),
                    ),
                  )
                : null,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: SegmentedButton<LiveTaskDanmakuMode>(
              segments: const [
                ButtonSegment(
                  value: LiveTaskDanmakuMode.text,
                  label: Text('文字'),
                  icon: Icon(Icons.text_fields),
                ),
                ButtonSegment(
                  value: LiveTaskDanmakuMode.emoticon,
                  label: Text('表情'),
                  icon: Icon(Icons.emoji_emotions_outlined),
                ),
              ],
              selected: {automation.danmakuMode},
              onSelectionChanged: _editable
                  ? (values) => _save(
                      room.copyWith(
                        automation: automation.copyWith(
                          danmakuMode: values.single,
                        ),
                      ),
                    )
                  : null,
            ),
          ),
          ListTile(
            key: const ValueKey('live-intimacy-content'),
            title: Text(emotes ? '随机发送表情（1～5个）' : '自动发送文字'),
            subtitle: Text(
              emotes
                  ? '${room.emoticons.length}/5 已选 · ${room.emoticons.isEmpty ? "尚未设置" : room.emoticons.map((e) => e.label.isEmpty ? "已选表情" : e.label).join("、")}'
                  : automation.defaultMessage.isEmpty
                  ? '尚未设置'
                  : automation.defaultMessage,
            ),
            trailing: const Icon(Icons.edit_outlined),
            onTap: _editable
                ? emotes
                      ? _editEmoticons
                      : _editText
                : null,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Text(widget.statusText ?? '只完成点赞、弹幕和观时。内容逐房间保存，手动弹幕草稿独立。'),
          ),
          ?widget.progress,
        ],
      ),
    );
  }
}

class LiveIntimacyEmoticonPicker extends StatefulWidget {
  const LiveIntimacyEmoticonPicker({
    super.key,
    required this.load,
    required this.selected,
  });
  final Future<List<LiveTaskEmoticonOption>> Function() load;
  final List<LiveIntimacyEmoticonSelection> selected;
  @override
  State<LiveIntimacyEmoticonPicker> createState() =>
      _LiveIntimacyEmoticonPickerState();
}

class _LiveIntimacyEmoticonPickerState
    extends State<LiveIntimacyEmoticonPicker> {
  late Future<List<LiveTaskEmoticonOption>> _options = widget.load();
  late final _selected = <String, LiveIntimacyEmoticonSelection>{
    for (final entry in widget.selected.take(5)) entry.unique: entry,
  };
  String? _error;

  void _select(LiveTaskEmoticonOption option, bool? checked) {
    setState(() {
      _error = null;
      if (checked != true) {
        _selected.remove(option.unique);
      } else if (_selected.length >= 5 &&
          !_selected.containsKey(option.unique)) {
        _error = '最多选择5个表情';
      } else if (option.available && option.unique.isNotEmpty) {
        _selected[option.unique] = LiveIntimacyEmoticonSelection(
          unique: option.unique,
          label: option.label,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      '随机发送表情 · ${_selected.length}/5',
      key: const ValueKey('live-intimacy-emoticon-count'),
    ),
    content: SizedBox(
      width: 380,
      height: MediaQuery.sizeOf(context).height * 0.45,
      child: FutureBuilder<List<LiveTaskEmoticonOption>>(
        future: _options,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: TextButton.icon(
                onPressed: () => setState(() => _options = widget.load()),
                icon: const Icon(Icons.refresh),
                label: const Text('表情加载失败，点击重试'),
              ),
            );
          }
          final loaded = <String, LiveTaskEmoticonOption>{
            for (final entry in snapshot.data ?? <LiveTaskEmoticonOption>[])
              if (entry.unique.isNotEmpty) entry.unique: entry,
          };
          final options = [
            ...loaded.values.where((e) => e.isFanClub),
            ...loaded.values.where((e) => !e.isFanClub),
            for (final entry in widget.selected)
              if (!loaded.containsKey(entry.unique))
                LiveTaskEmoticonOption(
                  unique: entry.unique,
                  label: entry.label,
                  available: false,
                ),
          ];
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('每次随机发送一个。不可用候选保留选择，可手动移除。'),
              if (_error case final error?)
                Text(
                  error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              if (options.isEmpty) const Text('当前没有可选表情'),
              Expanded(
                child: ListView(
                  children: [
                    for (final option in options)
                      CheckboxListTile(
                        key: ValueKey(
                          'live-intimacy-emoticon:${option.unique}',
                        ),
                        value: _selected.containsKey(option.unique),
                        onChanged:
                            option.available ||
                                _selected.containsKey(option.unique)
                            ? (value) => _select(option, value)
                            : null,
                        title: Text(option.label),
                        subtitle: Text(
                          option.available ? option.packageName : '当前不可发送',
                        ),
                        secondary: option.url.isEmpty
                            ? const Icon(Icons.emoji_emotions_outlined)
                            : NetworkImgLayer(
                                src: option.url,
                                width: 36,
                                height: 36,
                                fit: BoxFit.contain,
                                type: ImageType.emote,
                              ),
                      ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        key: const ValueKey('live-intimacy-emoticon-save'),
        onPressed: () =>
            Navigator.pop(context, _selected.values.toList(growable: false)),
        child: const Text('保存'),
      ),
    ],
  );
}

class LiveIntimacyWatchProgressView extends StatelessWidget {
  const LiveIntimacyWatchProgressView({
    super.key,
    required this.effectiveDuration,
    this.completedRounds,
    this.dailyRounds,
    this.thresholdSeconds,
    this.officialSeconds,
    this.currentRoundEstimateSeconds,
    this.waitingConfirmation = false,
    this.progressValue,
  });
  final Duration effectiveDuration;
  final int? completedRounds;
  final int? dailyRounds;
  final int? thresholdSeconds;
  final int? officialSeconds;
  final int? currentRoundEstimateSeconds;
  final bool waitingConfirmation;
  final double? progressValue;

  static String formatSeconds(int seconds) {
    final value = seconds < 0 ? 0 : seconds;
    final minutes = value ~/ 60;
    final remainder = (value % 60).toString().padLeft(2, '0');
    return '${minutes.toString().padLeft(2, "0")}:$remainder';
  }

  @override
  Widget build(BuildContext context) {
    final seconds = officialSeconds ?? currentRoundEstimateSeconds;
    final known =
        thresholdSeconds != null &&
        thresholdSeconds! > 0 &&
        seconds != null &&
        progressValue != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      child: Column(
        key: const ValueKey('live-intimacy-watch-progress'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            completedRounds == null
                ? '官方轮数待同步'
                : '官方已完成$completedRounds/${dailyRounds ?? "?"}轮',
          ),
          Text('本次有效观时 ${formatSeconds(effectiveDuration.inSeconds)}'),
          if (known) ...[
            Text(
              '${officialSeconds == null ? "本轮估算" : "官方当前轮"} ${formatSeconds(seconds)} / ${formatSeconds(thresholdSeconds!)}',
            ),
            const SizedBox(height: 6),
            LinearProgressIndicator(
              key: const ValueKey('live-intimacy-watch-bar'),
              value: progressValue!.clamp(0.0, 1.0),
            ),
          ] else
            Text(thresholdSeconds == null ? '当前轮进度待确认' : '当前轮起点待同步，不估算百分比'),
          if (waitingConfirmation) const Text('等待官方确认'),
        ],
      ),
    );
  }
}
