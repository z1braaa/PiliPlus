import 'dart:math' show min;

import 'package:PiliPlus/common/widgets/button/icon_button.dart';
import 'package:PiliPlus/common/widgets/flutter/text_field/controller.dart';
import 'package:PiliPlus/common/widgets/flutter/text_field/text_field.dart';
import 'package:PiliPlus/common/widgets/view_safe_area.dart';
import 'package:PiliPlus/models/common/publish_panel_type.dart';
import 'package:PiliPlus/models_new/live/live_danmaku/danmaku_msg.dart';
import 'package:PiliPlus/pages/common/publish/common_rich_text_pub_page.dart';
import 'package:PiliPlus/pages/live_emote/controller.dart';
import 'package:PiliPlus/pages/live_emote/view.dart';
import 'package:PiliPlus/pages/live_room/controller.dart';
import 'package:PiliPlus/pages/live_room/live_danmaku_send_gate.dart';
import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart' hide TextField;

class LiveSendDmPanel extends CommonRichTextPubPage {
  final bool fromEmote;
  final bool inline;
  final ValueChanged<bool>? onInlineEmojiChanged;
  final LiveRoomController liveRoomController;

  const LiveSendDmPanel({
    super.key,
    super.items,
    super.onSave,
    super.autofocus = true,
    this.fromEmote = false,
    this.inline = false,
    this.onInlineEmojiChanged,
    required this.liveRoomController,
  });

  @override
  State<LiveSendDmPanel> createState() => LiveSendDmPanelState();
}

class LiveSendDmPanelState extends CommonRichTextPubPageState<LiveSendDmPanel> {
  LiveRoomController get liveRoomController => widget.liveRoomController;
  LiveDanmakuSendGate get _sendGate => liveRoomController.danmakuSendGate;
  bool _inlineEmoji = false;
  late int _lastEditRevision;
  late int _seenSuccessSerial;

  void _onSendGateChanged() {
    if (!mounted) return;
    final gate = _sendGate;
    if (_seenSuccessSerial != gate.successSerial) {
      _seenSuccessSerial = gate.successSerial;
      if (gate.successfulRevision == gate.draftRevision &&
          _lastEditRevision == gate.draftRevision) {
        editController.clear();
        enablePublish.value = false;
      }
    }
    setState(() {});
  }

  @override
  void onChanged(String value) {
    super.onChanged(value);
    _sendGate.markDraftChanged();
    _lastEditRevision = _sendGate.draftRevision;
  }

  @override
  void onChooseEmote(dynamic emote, double? width, double? height) {
    super.onChooseEmote(emote, width, height);
    _sendGate.markDraftChanged();
    _lastEditRevision = _sendGate.draftRevision;
  }

  @override
  void onSave() {
    // A composer disposed after a newer draft was edited must not overwrite it.
    if (_lastEditRevision == _sendGate.draftRevision) super.onSave();
  }

  void _setInlineEmoji(bool value) {
    if (_inlineEmoji == value) return;
    setState(() => _inlineEmoji = value);
    widget.onInlineEmojiChanged?.call(value);
  }

  void focusInput({bool showEmote = false}) {
    if (widget.inline && kReleaseMode && !liveRoomController.isLogin) {
      liveRoomController.toastNotLogin();
      return;
    }
    if (showEmote && widget.inline) {
      focusNode.unfocus();
      _setInlineEmoji(true);
    } else {
      _setInlineEmoji(false);
      focusNode.requestFocus();
    }
  }

  void mention(DanmakuMsg item) {
    onInsertText(
      '@${item.name} ',
      RichTextType.at,
      rawText: item.extra.mid.toString(),
      id: item.extra.id.toString(),
    );
    _sendGate.markDraftChanged();
    _lastEditRevision = _sendGate.draftRevision;
    focusInput();
  }

  void _closeInlineEmojiOnFocus() {
    if (widget.inline && focusNode.hasFocus && _inlineEmoji) {
      _setInlineEmoji(false);
    }
  }

  @override
  void initState() {
    super.initState();
    _lastEditRevision = _sendGate.draftRevision;
    _seenSuccessSerial = _sendGate.successSerial;
    _sendGate.addListener(_onSendGateChanged);
    focusNode.addListener(_closeInlineEmojiOnFocus);
    if (widget.fromEmote) {
      if (widget.inline) {
        _inlineEmoji = true;
      } else {
        updatePanelType(PanelType.emoji);
      }
    }
  }

  @override
  void dispose() {
    _sendGate.removeListener(_onSendGateChanged);
    focusNode.removeListener(_closeInlineEmojiOnFocus);
    if (widget.inline && _inlineEmoji) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.onInlineEmojiChanged?.call(false);
      });
    }
    Get.delete<LiveEmotePanelController>(
      tag: liveRoomController.roomId.toString(),
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.inline) {
      if (kReleaseMode && !liveRoomController.isLogin) {
        return Material(
          color: theme.colorScheme.surface,
          child: ListTile(
            dense: true,
            leading: const Icon(Icons.login),
            title: const Text('登录后发送弹幕'),
            onTap: liveRoomController.toastNotLogin,
          ),
        );
      }
      return Material(
        color: theme.colorScheme.surface,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            buildInputView(),
            if (_inlineEmoji)
              SizedBox(
                height: min(180, MediaQuery.sizeOf(context).height * 0.25),
                child: customPanel,
              ),
          ],
        ),
      );
    }
    return ViewSafeArea(
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Container(
          constraints: const BoxConstraints(maxWidth: 640),
          decoration: BoxDecoration(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
            color: theme.colorScheme.surface,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              buildInputView(),
              Flexible(child: buildPanelContainer(Colors.transparent)),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget? get customPanel => DecoratedBox(
    decoration: BoxDecoration(
      border: Border(
        top: BorderSide(
          color: theme.colorScheme.outline.withValues(alpha: 0.1),
        ),
      ),
    ),
    child: LiveEmotePanel(
      onChoose: onChooseEmote,
      roomId: liveRoomController.roomId,
      onSendEmoticonUnique: (emote) {
        onCustomPublish(
          message: emote.emoticonUnique!,
          dmType: 1,
          emoticonOptions: '[object Object]',
        );
      },
    ),
  );

  Widget buildInputView() {
    return Padding(
      padding: const .only(left: 8, top: 2, right: 8),
      child: Row(
        children: [
          if (widget.inline)
            _emojiButton(_inlineEmoji)
          else
            Obx(() => _emojiButton(panelType.value == .emoji)),
          const SizedBox(width: 12),
          Expanded(
            child: Obx(
              () => RichTextField(
                key: key,
                textInputAction: .send,
                controller: editController,
                autofocus: false,
                readOnly: readOnly.value,
                onChanged: onChanged,
                onSubmitted: onSubmitted,
                focusNode: focusNode,
                decoration: const InputDecoration(
                  hintText: "输入弹幕内容",
                  border: InputBorder.none,
                  hintStyle: TextStyle(fontSize: 14),
                ),
                style: theme.textTheme.bodyLarge,
                // inputFormatters: [LengthLimitingTextInputFormatter(20)],
              ),
            ),
          ),
          Obx(
            () => enablePublish.value
                ? iconButton(
                    iconSize: 22,
                    iconColor: theme.colorScheme.onSurfaceVariant,
                    onPressed: () {
                      editController.clear();
                      enablePublish.value = false;
                      _sendGate.markDraftChanged();
                      _lastEditRevision = _sendGate.draftRevision;
                    },
                    icon: const Icon(Icons.clear),
                  )
                : const SizedBox.shrink(),
          ),
          const SizedBox(width: 12),
          Obx(
            () => iconButton(
              tooltip: '发送',
              iconSize: 22,
              iconColor: enablePublish.value && !_sendGate.pending
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outline,
              onPressed: enablePublish.value && !_sendGate.pending
                  ? onPublishThrottle
                  : null,
              icon: const Icon(Icons.send),
            ),
          ),
        ],
      ),
    );
  }

  Widget _emojiButton(bool isEmoji) => iconButton(
    tooltip: '表情',
    onPressed: () {
      if (widget.inline) {
        if (isEmoji) {
          focusInput();
        } else {
          focusInput(showEmote: true);
        }
      } else {
        updatePanelType(isEmoji ? PanelType.keyboard : PanelType.emoji);
      }
    },
    iconSize: 22,
    icon: const Icon(Icons.emoji_emotions_outlined),
    iconColor: isEmoji
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurfaceVariant,
  );

  @override
  Future<void> onCustomPublish({
    String? message,
    List? pictures,
    int? dmType,
    emoticonOptions,
  }) async {
    if (widget.inline && kReleaseMode && !liveRoomController.isLogin) {
      liveRoomController.toastNotLogin();
      return;
    }
    final isDraftSend = message == null;
    int replyMid = 0;
    String replyDmid = '';
    if (message == null) {
      final buffer = StringBuffer();
      for (final e in editController.items) {
        if (e.type == .at) {
          replyMid = int.parse(e.rawText);
          replyDmid = e.id!;
        } else {
          buffer.write(e.rawText);
        }
      }
      message = buffer.toString();
    }
    final outgoingMessage = message;
    LiveDanmakuSendAttempt? attempt;
    try {
      attempt = await _sendGate.trySend(
        () => liveRoomController.sendLiveDanmaku(
          message: outgoingMessage,
          dmType: dmType,
          emoticonOptions: emoticonOptions,
          replyMid: replyMid,
          replayDmid: replyDmid,
        ),
        clearDraftOnSuccess: isDraftSend,
        onDraftSuccess: (revision) {
          if (_sendGate.draftRevision == revision) {
            liveRoomController.savedDanmaku = null;
          }
        },
      );
    } catch (_) {
      if (mounted) SmartDialog.showToast('弹幕发送未完成，请确认后再尝试。');
      return;
    }
    if (attempt == null) return;
    final response = attempt.response;
    if (!response.isSuccess) {
      if (mounted) response.toast();
      return;
    }
    if (!mounted) return;
    final shouldCloseRoute = isDraftSend
        ? _sendGate.draftRevision == attempt.draftRevision &&
              _lastEditRevision == attempt.draftRevision
        : editController.items.isEmpty;
    if (!widget.inline &&
        shouldCloseRoute &&
        ModalRoute.of(context)?.isCurrent == true) {
      hasPub = true;
      Navigator.of(context).pop();
    }
    SmartDialog.showToast('发送成功');
  }

  @override
  Future<void>? onMention([bool fromClick = false]) => null;
}
