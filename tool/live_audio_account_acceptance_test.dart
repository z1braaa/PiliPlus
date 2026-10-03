// Manual acceptance only. Ordinary offline suites never discover this entry.
// Both a compile-time switch and explicit environment authorization are needed.
// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/http/live.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/services/live_watch_reporter.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/account_manager/account_mgr.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import 'live_audio_acceptance_gate.dart';

Map<String, dynamic> _map(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : {};

// AccountManager's normal error path logs a complete request URL in debug mode.
// Manual acceptance retains cookie handling, but never invokes that logger.
class _QuietAccountManager extends AccountManager {
  @override
  void onError(DioException err, ErrorInterceptorHandler handler) =>
      handler.next(err);
}

void main() {
  test(
    'explicitly authorized silent audio intimacy settlement',
    () async {
      final result = <String, dynamic>{
        'schema_version': 1,
        'status': 'starting',
        'scope': 'watch_only_no_interactive_writes',
        'playback_evidence': 'headless_native_audio_decode_null_output',
      };
      LiveAudioAcceptanceConfig? config;
      Directory? private;
      Process? player;
      LiveWatchReporter? watch;
      Timer? staleSamples;
      StreamSubscription<String>? samples;
      var stage = 'explicit_authorization';
      void record() {
        final path = config?.reportPath;
        if (path != null) {
          try {
            File(path).writeAsStringSync(jsonEncode(result));
          } on FileSystemException {
            result['report_write_failed'] = true;
          }
        }
      }

      try {
        config = LiveAudioAcceptanceConfig.fromEnvironment(
          Platform.environment,
        );
        result['native_source'] = config.nativeSource;
        stage = 'private_storage';
        private = await Directory.systemTemp.createTemp(
          'pili-live-audio-gate-',
        );
        if ((await Process.run('/bin/chmod', ['700', private.path])).exitCode !=
            0) {
          throw StateError('private_directory_permissions_failed');
        }
        // Include recording privacy state; opening a fresh empty local cache
        // would silently bypass the original pause-recording preference.
        for (final name in [
          'account.hive',
          'setting.hive',
          'localcache.hive',
        ]) {
          final copy = await File('${config.hivePath}/$name').copy(
            '${private.path}/$name',
          );
          if ((await Process.run('/bin/chmod', ['600', copy.path])).exitCode !=
              0) {
            throw StateError('private_file_permissions_failed');
          }
        }
        Hive.init(private.path);
        GStorage.regAdapter();
        GStorage.setting = await Hive.openBox('setting');
        GStorage.video = await Hive.openBox('video');
        GStorage.localCache = await Hive.openBox('localCache');
        Accounts.account = await Hive.openBox<LoginAccount>('account');
        final account = Accounts.account.values
            .where((value) => value.type.contains(AccountType.main))
            .firstOrNull;
        if (account == null) throw StateError('no_selected_main');
        final recordingAccount = Accounts.account.values
            .where((value) => value.type.contains(AccountType.heartbeat))
            .firstOrNull;
        if (!identical(account, recordingAccount)) {
          throw StateError('recording_identity_conflict');
        }
        Accounts.accountMode[AccountType.main.index] = account;
        Accounts.accountMode[AccountType.heartbeat.index] = account;
        // All of these writes target the disposable setting copy.
        await GStorage.setting.putAll({
          SettingBoxKey.enableHttp2: false,
          SettingBoxKey.enableSystemProxy: false,
          SettingBoxKey.retryCount: 0,
          SettingBoxKey.badCertificateCallback: false,
        });
        if (Pref.historyPause) throw StateError('recording_privacy_conflict');
        Request();
        Request.dio.options.followRedirects = false;
        Request.dio.options.receiveTimeout = const Duration(seconds: 15);
        Request.dio.interceptors.clear();
        Request.dio.interceptors.add(_QuietAccountManager());
        Request.dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              if (!liveAudioAcceptanceRequestAllowed(
                options.uri,
                options.method,
                options.queryParameters,
              )) {
                handler.reject(
                  DioException.requestCancelled(
                    requestOptions: options,
                    reason: 'manual_audio_scope_rejected',
                  ),
                );
              } else {
                handler.next(options);
              }
            },
          ),
        );
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
        stage = 'room_qualification';
        final info = await get(
          'https://api.live.bilibili.com/xlive/web-room/v1/index/getInfoByRoom',
          {'room_id': config.roomId},
        );
        final roomInfo = _map(_map(info['data'])['room_info']);
        final room = roomInfo['room_id'];
        final anchor = roomInfo['uid'];
        final area = roomInfo['area_id'];
        final parentArea = roomInfo['parent_area_id'];
        if (info['code'] != 0 ||
            roomInfo['live_status'] != 1 ||
            room is! int ||
            anchor is! int ||
            area is! int ||
            parentArea is! int ||
            room <= 0 ||
            anchor <= 0 ||
            area <= 0 ||
            parentArea <= 0) {
          throw StateError('room_not_eligible');
        }
        final relation = await get(
          'https://api.bilibili.com/x/relation',
          {'fid': anchor},
        );
        if (relation['code'] != 0 ||
            !const [2, 6].contains(_map(relation['data'])['attribute'])) {
          throw StateError('follow_not_confirmed');
        }
        Future<Map<String, dynamic>> readTaskData() async {
          final response = await get(
            'https://api.live.bilibili.com/xlive/app-ucenter/v1/fansMedal/GetActivatedMedalInfo',
            {
              'target_id': anchor,
              'room_id': room,
              'platform': 'pc',
              'scene': 'club',
            },
          );
          final data = _map(response['data']);
          if (response['code'] != 0 || (data['level'] as num? ?? 0) <= 0) {
            throw StateError('medal_task_not_confirmed');
          }
          return data;
        }

        final before = LiveAudioWatchProgress.fromTaskData(
          await readTaskData(),
        );
        if (before == null ||
            before.done ||
            before.completedRounds >= before.dailyRounds) {
          throw StateError('unfinished_watch_task_not_confirmed');
        }
        // The probe is bounded to 1,200 seconds. Never shorten a larger task
        // threshold and pretend the settlement gate was covered.
        if (before.thresholdSeconds + 150 > 1200) {
          throw StateError('task_threshold_exceeds_bounded_probe');
        }
        result['qualification'] = {
          'follow_confirmed': true,
          'medal_confirmed': true,
        };
        result['before'] = before.toSafeJson();
        result['settlement_wait_seconds'] = 90;
        result['only_audio_requested'] = true;
        result['status'] = 'qualified';
        record();
        stage = 'only_audio_request';
        final play = await LiveHttp.liveRoomInfo(
          roomId: room,
          qn: 80,
          onlyAudio: true,
        );
        if (play is! Success || play.dataOrNull?.liveStatus != 1) {
          throw StateError('audio_play_info_rejected');
        }
        final playInfo = play.dataOrNull!;
        if (playInfo.roomId != room || playInfo.uid != anchor) {
          throw StateError('audio_room_identity_mismatch');
        }
        String? media;
        for (final stream in playInfo.playurlInfo?.playurl?.stream ?? []) {
          for (final format in stream.format) {
            for (final codec in format.codec) {
              if (codec.urlInfo.isNotEmpty) {
                final url = codec.urlInfo.first;
                media = '${url.host}${codec.baseUrl}${url.extra}';
                break;
              }
            }
            if (media != null) break;
          }
          if (media != null) break;
        }
        if (media == null) throw StateError('audio_media_unavailable');
        stage = 'native_audio_playback';
        final runSeconds = before.thresholdSeconds + 90;
        player = await Process.start('python3', [
          'tool/live_native_playback_probe.py',
          '--library',
          config.mpvPath,
          '--audio-only',
          '--duration-seconds',
          '${runSeconds + 60}',
        ]);
        player.stdin.writeln(jsonEncode({'live_url': media}));
        // The signed media address is transported only over the private pipe.
        final started = Completer<void>();
        final playbackClock = Stopwatch()..start();
        double effectiveSeconds = 0;
        double? lastSampleAt;
        Map<String, dynamic> latestNative = {};
        bool wasValid = false;
        void pauseWatch() => watch?.updatePlayback(
          enabled: true,
          playing: false,
          buffering: true,
          live: true,
        );
        samples = player.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen(
              (line) {
                LiveAudioNativeSample parsed;
                try {
                  parsed = LiveAudioNativeSample.fromJson(jsonDecode(line));
                } on FormatException {
                  wasValid = false;
                  pauseWatch();
                  return;
                }
                final sample = parsed.safe;
                final now = playbackClock.elapsedMicroseconds / 1000000;
                final valid = parsed.valid;
                final previous = lastSampleAt;
                if (valid &&
                    wasValid &&
                    previous != null &&
                    now - previous <= 2.5) {
                  effectiveSeconds += now - previous;
                }
                lastSampleAt = now;
                wasValid = valid;
                latestNative = Map<String, dynamic>.from(sample);
                watch?.updatePlayback(
                  enabled: true,
                  playing: valid,
                  buffering: sample['buffering'] != false,
                  live: true,
                );
                if (valid && !started.isCompleted) started.complete();
              },
              onError: (Object _) {
                wasValid = false;
                pauseWatch();
              },
              onDone: () {
                wasValid = false;
                pauseWatch();
              },
            );
        unawaited(player.stderr.drain<void>().catchError((Object _) {}));
        staleSamples = Timer.periodic(const Duration(seconds: 1), (_) {
          final last = lastSampleAt;
          if (last == null ||
              playbackClock.elapsedMicroseconds / 1000000 - last > 2.5) {
            wasValid = false;
            pauseWatch();
          }
        });
        await started.future.timeout(const Duration(seconds: 45));
        result['native_audio_started'] = true;
        watch =
            LiveWatchReporter(
              roomId: room,
              anchorUid: anchor,
              areaId: area,
              parentAreaId: parentArea,
            )..updatePlayback(
              enabled: true,
              playing: true,
              buffering: false,
              live: true,
            );
        final timeline = <Map<String, dynamic>>[];
        result['timeline'] = timeline;
        stage = 'audio_watch_settlement';
        final elapsed = Stopwatch()..start();
        LiveAudioWatchProgress? after;
        while (elapsed.elapsed.inSeconds < runSeconds) {
          await Future<void>.delayed(const Duration(seconds: 10));
          after = LiveAudioWatchProgress.fromTaskData(await readTaskData());
          if (after == null ||
              after.thresholdSeconds != before.thresholdSeconds ||
              after.dailyRounds != before.dailyRounds ||
              after.completedRounds < before.completedRounds) {
            throw StateError('watch_task_cycle_unconfirmed');
          }
          timeline.add({
            'elapsed_seconds': elapsed.elapsed.inSeconds,
            'effective_audio_seconds': effectiveSeconds.round(),
            'native': latestNative,
            'watch_state': watch.status.value.state.name,
            'reported_seconds': watch.status.value.reportedSeconds,
            'official_watch': after.toSafeJson(),
          });
          result['status'] = 'running';
          record();
          if (watch.status.value.state == LiveWatchState.error ||
              watch.status.value.state == LiveWatchState.unsupported) {
            break;
          }
        }
        result['after'] = after?.toSafeJson();
        result['elapsed_seconds'] = elapsed.elapsed.inSeconds;
        result['effective_audio_seconds'] = effectiveSeconds.round();
        result['reported_seconds'] = watch.status.value.reportedSeconds;
        result['official_round_increased'] =
            after != null && after.completedRounds > before.completedRounds;
        final covered =
            effectiveSeconds >= before.thresholdSeconds &&
            elapsed.elapsed.inSeconds >= runSeconds;
        result['threshold_and_wait_covered'] = covered;
        result['status'] = !covered
            ? 'inconclusive'
            : result['official_round_increased'] == true
            ? 'pass'
            : 'not_credited';
      } catch (error) {
        // Never emit response bodies, paths, exception text or account identifiers.
        result['status'] = 'failed';
        result['failure_stage'] = stage;
        result['error_type'] = error.runtimeType.toString();
        // Only harness-authored fixed categories can be included. Native/Dio
        // exception messages remain excluded, even when their type is known.
        if (error is StateError &&
            const {
              'private_directory_permissions_failed',
              'private_file_permissions_failed',
              'no_selected_main',
              'recording_identity_conflict',
              'recording_privacy_conflict',
              'main_login_unconfirmed',
              'room_not_eligible',
              'follow_not_confirmed',
              'medal_task_not_confirmed',
              'unfinished_watch_task_not_confirmed',
              'task_threshold_exceeds_bounded_probe',
              'audio_play_info_rejected',
              'audio_room_identity_mismatch',
              'audio_media_unavailable',
              'watch_task_cycle_unconfirmed',
            }.contains(error.message)) {
          result['failure_reason'] = error.message;
        }
        if (error is DioException) {
          result['http_status'] = error.response?.statusCode;
        }
      } finally {
        staleSamples?.cancel();
        watch?.dispose();
        try {
          await watch?.settled.timeout(const Duration(seconds: 5));
        } on Object {
          result['watch_shutdown_failed'] = true;
        }
        if (player != null) {
          try {
            player.stdin.writeln('stop');
            await player.stdin.close();
          } on IOException {
            // A failed native child may already have closed its input pipe.
          }
          try {
            await player.exitCode.timeout(const Duration(seconds: 5));
          } on TimeoutException {
            player.kill(ProcessSignal.sigkill);
            try {
              await player.exitCode.timeout(const Duration(seconds: 5));
            } on TimeoutException {
              result['native_shutdown_failed'] = true;
            }
          }
        }
        await samples?.cancel();
        if (private != null) {
          try {
            await Hive.close();
          } on Object {
            result['storage_close_failed'] = true;
          } finally {
            try {
              await private.delete(recursive: true);
            } on FileSystemException {
              result['private_storage_cleanup_failed'] = true;
            }
          }
        }
        result['private_storage_removed'] =
            private != null && !private.existsSync();
        if (result['status'] == 'pass' &&
            (result['private_storage_removed'] != true ||
                result['native_shutdown_failed'] == true ||
                result['watch_shutdown_failed'] == true ||
                result['report_write_failed'] == true)) {
          result['status'] = 'failed';
          result['failure_stage'] = 'cleanup';
        }
        record();
        print(jsonEncode(result));
      }
      expect(
        result['status'],
        'pass',
        reason: 'Silent audio gate not passed; inspect the sanitized report.',
      );
    },
    skip: !const bool.fromEnvironment('LIVE_AUDIO_ACCOUNT_ACCEPTANCE'),
    timeout: const Timeout(Duration(minutes: 25)),
  );
}
