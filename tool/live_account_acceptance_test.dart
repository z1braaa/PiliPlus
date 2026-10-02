// Manual acceptance only. Never discovered by the ordinary offline test suite.
// Explicitly authorized local account copy; original Hive files stay unopened.
// ignore_for_file: avoid_print, cascade_invocations, curly_braces_in_flow_control_structures
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/services/live_interaction_service.dart';
import 'package:PiliPlus/services/live_viewing_session.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/account_manager/account_mgr.dart';
import 'package:PiliPlus/utils/live_viewer_preferences.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

Map<String, dynamic> _map(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : {};

Map<String, Object?> _safeTask(Map<String, dynamic> task) => {
  for (final key in ['title', 'sub_title', 'add_text', 'jump_type', 'is_done'])
    if (task[key] is String || task[key] is num || task[key] is bool)
      key: task[key],
};

void main() {
  test(
    'authorized live account acceptance',
    () async {
      final env = Platform.environment;
      final result = <String, dynamic>{'status': 'starting'};
      final output = env['LIVE_ACCEPTANCE_REPORT'];
      void record() {
        if (output != null) File(output).writeAsStringSync(jsonEncode(result));
      }

      Directory? private;
      Process? player;
      LiveViewingSession? session;
      LiveInteractionService? reader;
      String stage = 'private_storage';
      try {
        private = await Directory.systemTemp.createTemp(
          'pili-live-acceptance-',
        );
        await Process.run('/bin/chmod', ['700', private.path]);
        final source =
            env['LIVE_ACCEPTANCE_HIVE'] ??
            '${env['HOME']}/Library/Containers/com.example.piliplus/Data/Library/Application Support/com.example.piliplus/hive';
        for (final name in ['account.hive', 'setting.hive']) {
          final copy = await File('$source/$name')
              .copy('${private.path}/$name');
          await Process.run('/bin/chmod', ['600', copy.path]);
        }
        Hive.init(private.path);
        GStorage.regAdapter();
        GStorage.setting = await Hive.openBox('setting');
        GStorage.video = await Hive.openBox('video');
        GStorage.localCache = await Hive.openBox('localCache');
        Accounts.account = await Hive.openBox<LoginAccount>('account');
        final account = Accounts.account.values
            .where(
              (a) => a.type.contains(AccountType.main),
            )
            .firstOrNull;
        if (account == null) throw StateError('no_selected_main');
        Accounts.accountMode[AccountType.main.index] = account;
        Accounts.accountMode[AccountType.heartbeat.index] = account;
        await GStorage.setting.putAll({
          SettingBoxKey.enableHttp2: false,
          SettingBoxKey.enableSystemProxy: false,
          SettingBoxKey.retryCount: 0,
          SettingBoxKey.liveRoomEnhancement: true,
        });
        // No debug request logger, retry, webview sync or original storage writes.
        Request();
        Request.dio.interceptors.clear();
        Request.dio.interceptors.add(AccountManager());
        final options = Options(
          extra: {'account': account},
          headers: {'user-agent': BrowserUa.pc},
          followRedirects: false,
        );
        Future<Map<String, dynamic>> get(
          String url, [
          Map<String, dynamic>? query,
        ]) async => _map(
          (await Request.dio.get<dynamic>(
            url,
            queryParameters: query,
            options: options,
          )).data,
        );
        stage = 'login';
        final nav = await get('https://api.bilibili.com/x/web-interface/nav');
        final navData = _map(nav['data']);
        if (nav['code'] != 0 ||
            navData['isLogin'] != true ||
            navData['mid'] != account.mid) {
          throw StateError('main_login_unconfirmed');
        }
        result['account_confirmed'] = true;
        stage = 'medal_rooms';
        final wall = await get(
          'https://api.live.bilibili.com/xlive/web-ucenter/user/MedalWall',
          {'target_id': account.mid},
        );
        if (wall['code'] != 0) throw StateError('medal_wall_rejected');
        final candidates = (_map(wall['data'])['list'] as List? ?? [])
            .map(_map)
            .where((m) => m['live_status'] == 1)
            .toList();
        result['active_medal_rooms'] = candidates.length;
        result['candidate_shapes'] = candidates
            .take(3)
            .map(
              (m) => {
                for (final key in ['target_name', 'live_status']) key: m[key],
                'room_path': Uri.tryParse(m['link']?.toString() ?? '')?.path,
                'medal_info_keys': _map(m['medal_info']).keys.toList(),
              },
            )
            .toList();
        final preferred = int.tryParse(env['LIVE_ACCEPTANCE_ROOM'] ?? '');
        if (preferred != null) {
          candidates.sort(
            (a, b) =>
                (b['link'].toString().contains('/$preferred') ? 1 : 0) -
                (a['link'].toString().contains('/$preferred') ? 1 : 0),
          );
        }
        Map<String, dynamic>? roomInfo;
        Map<String, dynamic>? taskData;
        LiveTaskEmoticonOption? firstEmote;
        int room = 0;
        int anchor = 0;
        for (final medal in candidates) {
          final uri = Uri.tryParse(medal['link']?.toString() ?? '');
          final id = int.tryParse(uri?.pathSegments.lastOrNull ?? '');
          if (id == null) continue;
          final info = await get(
            'https://api.live.bilibili.com/xlive/web-room/v1/index/getInfoByRoom',
            {'room_id': id},
          );
          final detail = _map(_map(info['data'])['room_info']);
          if (info['code'] != 0 || detail['live_status'] != 1) continue;
          room = detail['room_id'] as int;
          anchor = detail['uid'] as int;
          reader?.dispose();
          reader = LiveInteractionService(roomId: room, anchorUid: anchor);
          final fan = await get(
            'https://api.live.bilibili.com/xlive/app-ucenter/v1/fansMedal/GetActivatedMedalInfo',
            {
              'target_id': anchor,
              'room_id': room,
              'platform': 'pc',
              'scene': 'club',
            },
          );
          final data = _map(fan['data']);
          final emoteResponse = await get(
            'https://api.live.bilibili.com/xlive/web-ucenter/v2/emoticon/GetEmoticons',
            {'platform': 'pc', 'room_id': room},
          );
          final packages = _map(emoteResponse['data'])['data'] as List? ?? [];
          result['emote_fields'] = packages
              .map(_map)
              .map(
                (p) => {
                  for (final key in ['pkg_name', 'pkg_type', 'perm'])
                    key: p[key],
                  'first': (p['emoticons'] as List? ?? [])
                      .take(1)
                      .map(_map)
                      .map(
                        (e) => {
                          for (final key in [
                            'emoji',
                            'perm',
                            'unlock_need_gift',
                            'unlock_need_guard_level',
                            'unlock_need_level',
                          ])
                            if (e.containsKey(key)) key: e[key],
                          'keys': e.keys.toList(),
                        },
                      )
                      .toList(),
                },
              )
              .toList();
          result['last_candidate_room'] = room;
          result['last_candidate_tasks'] = (data['task_info'] as List? ?? [])
              .map(_map)
              .map(_safeTask)
              .toList();
          final emotes = await reader.loadTaskEmoticons();
          // Preserve package and item order; never substitute a generic emoticon.
          final fanPackage = packages
              .map(_map)
              .where((p) => p['pkg_type'] == 2)
              .firstOrNull;
          final rawFirst = (_map(fanPackage)['emoticons'] as List? ?? [])
              .map(_map)
              .firstOrNull;
          final first = emotes
              .where((e) => e.unique == rawFirst?['emoticon_unique'])
              .firstOrNull;
          if (fan['code'] != 0 ||
              (data['level'] as num? ?? 0) <= 0 ||
              first?.available != true)
            continue;
          firstEmote = first;
          roomInfo = detail;
          taskData = data;
          result['room'] = room;
          result['anchor'] = anchor;
          result['streamer'] = medal['target_name'];
          break;
        }
        if (roomInfo == null || taskData == null || firstEmote == null)
          throw StateError('no_live_medal_room_with_first_fan_emote');
        List<Map<String, Object?>> taskFields(Map<String, dynamic> data) =>
            (data['task_info'] as List? ?? [])
                .map(_map)
                .map(_safeTask)
                .toList();
        result['before'] = taskFields(taskData);
        result['fan_state_before'] = {
          for (final key in taskData.keys)
            if (taskData[key] is num || taskData[key] is bool)
              key: taskData[key],
        };
        result['emote'] = {
          'label': firstEmote.label,
          'package': firstEmote.packageName,
          'first_in_fan_package': true,
          'available': true,
        };
        result['task_data_keys'] = taskData.keys.toList();
        result['status'] = 'read_complete';
        record();
        if (env['LIVE_ACCEPTANCE_READ_ONLY'] == 'true') return;
        stage = 'native_playback';
        final play = await get(
          'https://api.live.bilibili.com/xlive/web-room/v2/index/getRoomPlayInfo',
          {
            'room_id': room,
            'protocol': '0,1',
            'format': '0,1,2',
            'codec': '0',
            'qn': 10000,
            'platform': 'web',
            'ptype': 8,
          },
        );
        final playInfo = _map(_map(play['data'])['playurl_info']);
        final streams = _map(playInfo['playurl'])['stream'] as List? ?? [];
        String? media;
        for (final stream in streams.map(_map)) {
          for (final format in (stream['format'] as List? ?? []).map(_map)) {
            for (final codec in (format['codec'] as List? ?? []).map(_map)) {
              final urls = codec['url_info'] as List? ?? [];
              if (urls.isNotEmpty) {
                final url = _map(urls.first);
                media = '${url['host']}${codec['base_url']}${url['extra']}';
                break;
              }
            }
            if (media != null) break;
          }
          if (media != null) break;
        }
        if (play['code'] != 0 || media == null)
          throw StateError('no_native_media');
        player = await Process.start('python3', [
          'tool/live_native_playback_probe.py',
          '--library',
          env['LIVE_ACCEPTANCE_MPV']!,
        ]);
        player.stdin.writeln(jsonEncode({'live_url': media}));
        final started = Completer<void>();
        var decoded = false;
        var buffering = false;
        var playing = false;
        double? position;
        player.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen((line) {
              final state = _map(jsonDecode(line));
              decoded = state['tracks_decoded'] == true;
              buffering = state['buffering'] == true;
              playing = state['playing'] == true;
              position = (state['position'] as num?)?.toDouble();
              session?.updatePlayback(
                playing: playing,
                buffering: buffering,
                live: true,
              );
              if (playing && !started.isCompleted) started.complete();
            });
        // Helper diagnostics are fixed categories; consume without logging.
        player.stderr.drain<void>();
        await started.future.timeout(const Duration(seconds: 45));
        result['native_tracks_decoded'] = decoded;
        result['playback_started'] = true;
        stage = 'automatic_tasks';
        final preferences = LiveTaskAutomationPreferences(
          autoLike: true,
          autoDanmaku: true,
          danmakuMode: LiveTaskDanmakuMode.emoticon,
          defaultEmoticonUnique: firstEmote.unique,
          defaultEmoticonName: firstEmote.label,
          defaultEmoticonRoomId: room,
          defaultEmoticonAnchorUid: anchor,
        );
        await Pref.saveLiveTaskAutomationFor(account.mid, preferences);
        session = LiveViewingSession(
          roomId: room,
          anchorUid: anchor,
          areaId: roomInfo['area_id'] as int,
          parentAreaId: roomInfo['parent_area_id'] as int,
        );
        session.updatePlayback(
          playing: playing,
          buffering: buffering,
          live: true,
        );
        final timeline = <Map<String, dynamic>>[];
        result['timeline'] = timeline;
        final clock = Stopwatch()..start();
        final duration =
            int.tryParse(env['LIVE_ACCEPTANCE_SECONDS'] ?? '') ?? 720;
        while (clock.elapsed.inSeconds < duration) {
          await Future<void>.delayed(const Duration(seconds: 10));
          final fan = await get(
            'https://api.live.bilibili.com/xlive/app-ucenter/v1/fansMedal/GetActivatedMedalInfo',
            {
              'target_id': anchor,
              'room_id': room,
              'platform': 'pc',
              'scene': 'club',
            },
          );
          final data = _map(fan['data']);
          final item = <String, dynamic>{
            'seconds': clock.elapsed.inSeconds,
            'native_position': position,
            'playing': playing,
            'buffering': buffering,
            'watch_state': session.watch.status.value.state.name,
            'watch_message': session.watch.status.value.message,
            'reported_seconds': session.watch.status.value.reportedSeconds,
            'automation_state': session.tasks.state.name,
            'automation_message': session.tasks.statusText,
            'server_code': fan['code'],
            'tasks': taskFields(data),
            'fan_state': {
              for (final key in data.keys)
                if (data[key] is num || data[key] is bool) key: data[key],
            },
          };
          timeline.add(item);
          result['status'] = 'running';
          record();
          if (session.watch.status.value.state.name == 'unsupported' ||
              session.watch.status.value.state.name == 'error')
            break;
        }
        result['status'] = 'complete';
      } catch (error) {
        // Error bodies, headers, signed queries and credentials are never logged.
        result['status'] = 'failed';
        result['failure_stage'] = stage;
        result['error_type'] = error.runtimeType.toString();
        if (error is DioException)
          result['http_status'] = error.response?.statusCode;
      } finally {
        session?.dispose();
        reader?.dispose();
        player?.kill();
        if (private != null) {
          await Hive.close();
          await private.delete(recursive: true);
        }
        record();
      // Output only the public sanitized report.
      print(jsonEncode(result));
      if (result['status'] == 'failed') {
        fail('Live acceptance failed at $stage; see the sanitized report.');
      }
      }
    },
    skip: !const bool.fromEnvironment('LIVE_ACCOUNT_ACCEPTANCE'),
    timeout: const Timeout(Duration(minutes: 35)),
  );
}
