// Manual LIVE-LIKE-01 account acceptance. The ordinary offline suite skips it.
// Requires compile-time opt-in AND separate runtime consent. Uses only a
// disposable private Hive copy; no player, media library or viewing session.
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/services/live_intimacy_discovery.dart';
import 'package:PiliPlus/services/live_intimacy_scheduler.dart';
import 'package:PiliPlus/services/live_interaction_service.dart';
import 'package:PiliPlus/services/live_medal_reader.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/account_manager/account_mgr.dart';
import 'package:PiliPlus/utils/live_intimacy_preferences.dart';
import 'package:PiliPlus/utils/live_viewer_preferences.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import 'live_intimacy_like_only_acceptance_gate.dart';

class _Failure implements Exception {
  const _Failure(this.category);
  final String category;
}

class _QuietAccountManager extends AccountManager {
  @override
  void onError(DioException err, ErrorInterceptorHandler handler) =>
      handler.next(err);
}

LiveFanTask _knownPendingLike(List<LiveFanTask> tasks) {
  final matches = tasks.where((task) => task.jumpType == 'like').toList();
  if (matches.length != 1) {
    throw const _Failure('like_task_not_uniquely_confirmed');
  }
  final task = matches.single;
  final remaining = task.remainingCount;
  final multiplier = task.dailyRewardProgress || task.completionOnly
      ? task.actionsPerProgress
      : 1;
  if (task.completed != false ||
      task.currentCount == null && !task.completionOnly ||
      task.targetCount == null ||
      task.targetCount! > 10000 ||
      remaining == null ||
      remaining <= 0 ||
      multiplier == null ||
      multiplier <= 0 ||
      multiplier > LiveLikeOnlyAcceptanceGate.maximumLikeClicks) {
    throw const _Failure('pending_free_like_budget_unconfirmed');
  }
  return task;
}

Map<String, Object?> _safeLikeTask(List<LiveFanTask> tasks) {
  final matches = tasks.where((task) => task.jumpType == 'like').toList();
  if (matches.length != 1) return {'confirmed': false};
  final task = matches.single;
  return {
    'confirmed': true,
    'completed': task.completed,
    'current': task.currentCount,
    'target': task.targetCount,
    'actions_per_progress': task.actionsPerProgress,
    'daily_reward_progress': task.dailyRewardProgress,
    'completion_only': task.completionOnly,
    'has_explicit_period': task.period.isNotEmpty,
  };
}

bool _sameLikePhase(LiveFanTask before, LiveFanTask after) =>
    before.id == after.id &&
    before.period == after.period &&
    before.targetCount == after.targetCount &&
    before.actionsPerProgress == after.actionsPerProgress &&
    before.dailyRewardProgress == after.dailyRewardProgress &&
    before.completionOnly == after.completionOnly;

void main() {
  test(
    'explicitly authorized unlit medal production like-only acceptance',
    () async {
      final result = <String, Object?>{
        'schema_version': 1,
        'requirement': 'LIVE-LIKE-01',
        'status': 'starting',
        'scope': 'single_explicit_unlit_room_free_likes_only',
        'maximum_like_click_attempts': 30,
        'gui_verified': false,
        'media_library_initialized': false,
        'foreground_player_created': false,
        'automatic_upgrade_to_full_allowed': false,
        'started_utc': DateTime.now().toUtc().toIso8601String(),
      };
      LiveLikeOnlyAcceptanceConfig? config;
      LiveLikeOnlyAcceptanceGate? gate;
      Directory? private;
      LiveIntimacyScheduler? scheduler;
      LiveIntimacyDiscovery? discovery;
      LiveInteractionService? reader;
      LoginAccount? authorizedAccount;
      int? authorizedGeneration;
      var stage = 'explicit_authorization';
      var reportValidated = false;
      var clientStarted = false;
      var writesEnabled = false;
      var writeSettled = false;
      var safetyViolation = false;
      var acceptedClicks = 0;
      var unknownLikeAttempts = 0;
      var mediaOrWatchRequestsRejected = 0;
      var danmakuOrPaidRequestsRejected = 0;
      final requestClock = Stopwatch()..start();
      final likeEvents = <Map<String, Object?>>[];
      final officialSamples = <Map<String, Object?>>[];
      final networkFailures = <Map<String, Object?>>[];
      void Function()? listener;

      bool identityConfirmed([RequestOptions? options]) =>
          authorizedAccount != null &&
          identical(Accounts.main, authorizedAccount) &&
          identical(Accounts.heartbeat, authorizedAccount) &&
          !Accounts.mainIdentityChangeInProgress &&
          authorizedGeneration == Accounts.mainChangeGeneration &&
          !Pref.historyPause &&
          (options == null ||
              identical(options.extra['account'], authorizedAccount));

      bool roomConfirmed() {
        final account = authorizedAccount;
        final settings = config;
        final active = scheduler;
        if (account == null || settings == null || active == null) return false;
        final saved = Pref.liveIntimacyPreferencesFor(account.mid);
        final room = saved.roomFor(settings.roomId, settings.anchorUid);
        final state = active.stateFor(settings.roomId, settings.anchorUid);
        final likes = state?.tasks
            .where((task) => task.jumpType == 'like')
            .toList();
        return saved.enabled &&
            saved.rooms.length == 1 &&
            room?.authorized == true &&
            room?.mode == LiveIntimacyRoomMode.likeOnly &&
            room?.automation.autoLike == true &&
            room?.automation.autoDanmaku == false &&
            room?.automation.defaultMessage.isEmpty == true &&
            room?.emoticons.isEmpty == true &&
            active.currentRoom == null &&
            !active.ownsWatchReporter &&
            state?.candidate?.eligible == true &&
            state?.officialFresh == true &&
            state?.periodConfirmed == true &&
            state?.pauseReason == null &&
            state?.interactionPauseReason == null &&
            likes?.length == 1 &&
            likes!.single.completed == false &&
            (likes.single.remainingCount ?? 0) > 0;
      }

      void inspectScheduler() {
        final active = scheduler;
        if (active == null || config == null) return;
        final state = active.stateFor(config.roomId, config.anchorUid);
        if (active.currentRoom != null ||
            active.ownsWatchReporter ||
            active.rooms.any((room) => room.watchRunning) ||
            active.preferences.rooms.any(
              (room) =>
                  room.mode != LiveIntimacyRoomMode.likeOnly ||
                  room.automation.autoDanmaku,
            )) {
          safetyViolation = true;
          writesEnabled = false;
        }
        if (state?.interactionRunning == true) {
          gate?.activateInteractions(requestClock.elapsedMilliseconds);
        }
      }

      Future<void> stopTasks() async {
        writesEnabled = false;
        final active = scheduler;
        if (active != null) {
          await active.savePreferences(
            active.preferences.copyWith(enabled: false),
          );
        }
      }

      try {
        config = LiveLikeOnlyAcceptanceConfig.fromEnvironment(
          Platform.environment,
        );
        result['public_room_id'] = config.roomId;
        result['public_anchor_uid'] = config.anchorUid;
        result['requested_window_seconds'] = config.seconds;
        stage = 'external_report_path';
        if (Link(config.reportPath).existsSync() ||
            File(config.reportPath).existsSync() ||
            !Directory(File(config.reportPath).parent.path).existsSync()) {
          throw const _Failure('fresh_external_report_path_required');
        }
        final sourceReal = await Directory(config.hivePath)
            .resolveSymbolicLinks();
        final reportParentReal = await File(config.reportPath).parent
            .resolveSymbolicLinks();
        if (reportParentReal == sourceReal ||
            reportParentReal.startsWith('$sourceReal/')) {
          throw const _Failure('report_must_be_outside_source_storage');
        }
        reportValidated = true;
        stage = 'private_account_copy';
        private = await Directory.systemTemp.createTemp('pili-like-only-');
        if ((await Process.run('/bin/chmod', ['700', private.path])).exitCode !=
            0) {
          throw const _Failure('private_permissions_failed');
        }
        for (final name in [
          'account.hive',
          'setting.hive',
          'localcache.hive',
        ]) {
          final copy = await File('${config.hivePath}/$name')
              .copy('${private.path}/$name');
          if ((await Process.run('/bin/chmod', ['600', copy.path])).exitCode !=
              0) {
            throw const _Failure('private_permissions_failed');
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
        final recording = Accounts.account.values
            .where((value) => value.type.contains(AccountType.heartbeat))
            .firstOrNull;
        if (account == null ||
            !account.isLogin ||
            account.mid <= 0 ||
            !identical(account, recording) ||
            Pref.historyPause) {
          throw const _Failure('recording_identity_or_privacy_conflict');
        }
        Accounts.accountMode[AccountType.main.index] = account;
        Accounts.accountMode[AccountType.heartbeat.index] = account;
        authorizedAccount = account;
        authorizedGeneration = Accounts.mainChangeGeneration;
        gate = LiveLikeOnlyAcceptanceGate(
          roomId: config.roomId,
          anchorUid: config.anchorUid,
          accountUid: account.mid,
        );
        await GStorage.setting.putAll({
          SettingBoxKey.enableHttp2: false,
          SettingBoxKey.enableSystemProxy: false,
          SettingBoxKey.retryCount: 0,
          SettingBoxKey.badCertificateCallback: false,
        });
        // Reset only the private test's authorization domain. Original account
        // preferences and room grants are never opened for writing.
        await Pref.saveLiveIntimacyPreferencesFor(
          account.mid,
          const LiveIntimacyPreferences(),
        );
        Request();
        clientStarted = true;
        Request.dio.options.followRedirects = false;
        Request.dio.options.receiveTimeout = const Duration(seconds: 15);
        Request.dio.interceptors.clear();
        Request.dio.interceptors.add(_QuietAccountManager());
        Request.dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              inspectScheduler();
              final allowed = gate!.allow(
                uri: options.uri,
                method: options.method,
                query: options.queryParameters,
                data: options.data,
                elapsedMilliseconds: requestClock.elapsedMilliseconds,
                writesEnabled: writesEnabled,
                identityAndPrivacyConfirmed: identityConfirmed(options),
                roomAndTaskConfirmed: roomConfirmed(),
              );
              if (!allowed) {
                if (options.uri.host == 'live-trace.bilibili.com' ||
                    options.uri.path.contains('PlayInfo') ||
                    options.uri.path.contains('room_init')) {
                  ++mediaOrWatchRequestsRejected;
                  safetyViolation = true;
                } else if (options.method != 'GET' &&
                    options.uri.path != LiveLikeOnlyAcceptanceGate.likePath) {
                  ++danmakuOrPaidRequestsRejected;
                  safetyViolation = true;
                }
                handler.reject(
                  DioException.requestCancelled(
                    requestOptions: options,
                    reason: 'like_only_acceptance_scope_rejected',
                  ),
                );
              } else {
                if (options.method == 'POST') {
                  likeEvents.add({
                    'elapsed_ms': requestClock.elapsedMilliseconds,
                    'clicks': LiveLikeOnlyAcceptanceGate.integer(
                      (options.data as Map)['click_time'],
                    ),
                    'accepted': null,
                  });
                }
                handler.next(options);
              }
            },
            onResponse: (response, handler) {
              if (response.requestOptions.method == 'POST') {
                final accepted = liveInt(liveMap(response.data)['code']) == 0;
                final clicks =
                    LiveLikeOnlyAcceptanceGate.integer(
                      (response.requestOptions.data as Map)['click_time'],
                    ) ??
                    0;
                if (accepted) acceptedClicks += clicks;
                if (likeEvents.isNotEmpty) {
                  likeEvents.last['accepted'] = accepted;
                }
                writeSettled = true;
              }
              handler.next(response);
            },
            onError: (error, handler) {
              if (error.requestOptions.method == 'POST' &&
                  error.requestOptions.uri.path ==
                      LiveLikeOnlyAcceptanceGate.likePath &&
                  error.type != DioExceptionType.cancel) {
                ++unknownLikeAttempts;
                writeSettled = true;
              }
              // Do not retain server error text, URL, body, headers or query.
              networkFailures.add({'error_type': error.type.name});
              handler.next(error);
            },
          ),
        );
        Future<Map<String, dynamic>> read(
          String path,
          Map<String, dynamic> query,
        ) async {
          if (!identityConfirmed()) {
            throw const _Failure('account_identity_changed');
          }
          final origin = path.startsWith('/x/')
              ? 'https://api.bilibili.com'
              : 'https://api.live.bilibili.com';
          return liveMap(
            (await Request.dio.get<dynamic>(
              origin + path,
              queryParameters: query,
              options: Options(
                extra: {'account': account},
                headers: {'user-agent': BrowserUa.pc},
                followRedirects: false,
              ),
            )).data,
          );
        }

        stage = 'login_confirmation';
        final nav = await read('/x/web-interface/nav', {});
        final user = liveMap(nav['data']);
        if (liveInt(nav['code']) != 0 ||
            user['isLogin'] != true ||
            liveInt(user['mid']) != account.mid) {
          throw const _Failure('selected_login_unconfirmed');
        }
        result['account_confirmed'] = true;
        final room = LiveIntimacyRoomPreferences(
          roomId: config.roomId,
          anchorUid: config.anchorUid,
          mode: LiveIntimacyRoomMode.likeOnly,
          automation: const LiveTaskAutomationPreferences(autoLike: true),
        );
        stage = 'live_owned_followed_qualification';
        discovery = LiveIntimacyDiscovery.production();
        final candidate = await discovery.recheck(room);
        if (!candidate.eligible ||
            candidate.roomId != config.roomId ||
            candidate.anchorUid != config.anchorUid) {
          throw const _Failure('explicit_room_qualification_unconfirmed');
        }
        result['initial_qualification'] = {
          'followed': candidate.followed,
          'medal_owned': candidate.medalOwned,
          'live': candidate.live,
          'medal_level': candidate.medalLevel,
        };
        stage = 'complete_unlit_medal_inventory';
        final beforeMedals = await readLiveMedals(
          read: read,
          roomId: config.roomId,
          anchorUid: config.anchorUid,
        );
        final medal = beforeMedals
            .where((value) => value.targetUid == config!.anchorUid)
            .toList();
        if (medal.length != 1 || medal.single.isLighted != false) {
          throw const _Failure('owned_unlit_medal_not_confirmed');
        }
        result['initial_official_medal'] = {
          'lighted': medal.single.isLighted,
          'wearing': medal.single.wearing,
          'level': medal.single.level,
          'complete_inventory': true,
        };
        stage = 'fresh_like_task';
        reader = LiveInteractionService(
          roomId: config.roomId,
          anchorUid: config.anchorUid,
        );
        final before = await reader.loadFanTasks();
        if (before.joined != true ||
            before.accountUid != account.mid ||
            !identical(before.accountIdentity, account) ||
            before.roomId != config.roomId ||
            before.anchorUid != config.anchorUid) {
          throw const _Failure('task_account_or_room_unconfirmed');
        }
        final beforeLike = _knownPendingLike(before.tasks);
        result['before_like_task'] = _safeLikeTask(before.tasks);
        stage = 'explicit_private_like_only_authorization';
        final active = scheduler = LiveIntimacyScheduler.production()..start();
        listener = inspectScheduler;
        active
          ..addListener(listener)
          ..updateForeground(
            roomId: config.roomId,
            anchorUid: config.anchorUid,
          );
        await active.saveRoomPreferences(room);
        final issue = await active.authorizeRoom(room, true);
        if (issue != null ||
            active.preferences.enabled ||
            active.preferences.rooms.length != 1 ||
            !active.preferences.rooms.single.authorized) {
          throw const _Failure('private_like_only_authorization_rejected');
        }
        active.updateForeground(playing: false);
        result['no_frontend_live_room_required'] = true;
        result['no_danmaku_content_configured'] = true;
        writesEnabled = true;
        await active.savePreferences(
          active.preferences.copyWith(enabled: true),
        );
        stage = 'bounded_production_like_queue';
        final window = Stopwatch()..start();
        while (window.elapsed.inSeconds < config.seconds) {
          await Future<void>.delayed(const Duration(seconds: 1));
          inspectScheduler();
          if (safetyViolation || !identityConfirmed()) {
            throw const _Failure('scope_or_identity_changed');
          }
          if (Link(config.stopMarkerPath).existsSync()) {
            throw const _Failure('stop_marker_symlink_rejected');
          }
          if (File(config.stopMarkerPath).existsSync()) {
            result['observation_end'] = 'operator_graceful_stop';
            break;
          }
          if (writeSettled && gate.remainingLikeClicks == 0) {
            result['observation_end'] = 'thirty_click_attempt_cap_reached';
            break;
          }
          if (writeSettled && unknownLikeAttempts > 0) {
            result['observation_end'] = 'unknown_write_no_retry';
            break;
          }
        }
        result['observation_end'] ??= 'bounded_window_elapsed';
        stage = 'stop_before_official_confirmation';
        await stopTasks().timeout(const Duration(seconds: 25));
        result['task_mode_after_run'] =
            active.preferences.rooms.single.mode.name;
        if (active.preferences.rooms.single.mode !=
                LiveIntimacyRoomMode.likeOnly ||
            active.currentRoom != null ||
            active.ownsWatchReporter) {
          throw const _Failure('like_only_scope_not_preserved');
        }
        stage = 'complete_official_inventory_and_task_confirmation';
        var lighted = false;
        var progressIncreased = false;
        var phaseChanged = false;
        for (var sample = 0; sample < 3; ++sample) {
          if (sample > 0) {
            await Future<void>.delayed(const Duration(seconds: 10));
          }
          final medals = await readLiveMedals(
            read: read,
            roomId: config.roomId,
            anchorUid: config.anchorUid,
          );
          final currentMedal = medals
              .where((value) => value.targetUid == config!.anchorUid)
              .toList();
          final after = await reader.loadFanTasks();
          if (after.accountUid != account.mid ||
              !identical(after.accountIdentity, account) ||
              after.roomId != config.roomId ||
              after.anchorUid != config.anchorUid) {
            throw const _Failure('official_confirmation_identity_changed');
          }
          final afterLikes = after.tasks
              .where((task) => task.jumpType == 'like')
              .toList();
          final medalConfirmed = currentMedal.length == 1;
          final currentlyLit =
              medalConfirmed && currentMedal.single.isLighted == true;
          final likeConfirmed = afterLikes.length == 1;
          var increased = false;
          var changed = false;
          if (likeConfirmed) {
            final latest = afterLikes.single;
            changed = !_sameLikePhase(beforeLike, latest);
            increased =
                !changed &&
                (beforeLike.currentCount != null &&
                        latest.currentCount != null &&
                        latest.currentCount! > beforeLike.currentCount! ||
                    beforeLike.completed == false && latest.completed == true);
          }
          lighted |= currentlyLit;
          progressIncreased |= increased;
          phaseChanged |= changed;
          officialSamples.add({
            'elapsed_ms': requestClock.elapsedMilliseconds,
            'complete_medal_inventory': true,
            'same_anchor_medal_confirmed': medalConfirmed,
            'official_lighted': medalConfirmed
                ? currentMedal.single.isLighted
                : null,
            'official_like_task': _safeLikeTask(after.tasks),
            'same_phase_progress_increased': increased,
            'like_task_phase_changed': changed,
          });
          if (lighted && progressIncreased) break;
        }
        result['official_medal_lighting_confirmed'] = lighted;
        result['official_like_round_progress_increased'] = progressIncreased;
        result['official_like_task_phase_changed'] = phaseChanged;
        result['accepted_writes_are_not_official_confirmation'] = true;
        result['status'] = acceptedClicks > 0 && lighted && progressIncreased
            ? 'official_lighting_and_like_progress_confirmed'
            : acceptedClicks > 0 && lighted
            ? 'official_lighting_confirmed_like_round_increment_not_observed'
            : 'official_acceptance_not_confirmed';
        result['harness_completed'] = true;
      } catch (error) {
        result['status'] = 'failed';
        result['failure_stage'] = stage;
        result['failure_category'] = error is _Failure
            ? error.category
            : error is FormatException && stage == 'explicit_authorization'
            ? error.message
            : 'operation_failed';
      } finally {
        writesEnabled = false;
        if (listener != null) scheduler?.removeListener(listener);
        try {
          await scheduler?.shutdown().timeout(const Duration(seconds: 25));
        } on Object {
          result['scheduler_cleanup_failed'] = true;
        }
        reader?.dispose();
        discovery?.cancel();
        if (clientStarted) Request.dio.close(force: true);
        if (private != null) {
          try {
            await Hive.close().timeout(const Duration(seconds: 20));
          } on Object {
            result['storage_close_failed'] = true;
          }
          try {
            await private.delete(recursive: true);
          } on Object {
            result['private_storage_cleanup_failed'] = true;
          }
        }
        result['private_storage_removed'] =
            private != null && !private.existsSync();
        result['attempted_like_clicks'] = gate?.attemptedLikeClicks ?? 0;
        result['accepted_like_clicks_not_task_completion'] = acceptedClicks;
        result['unknown_like_attempts'] = unknownLikeAttempts;
        result['like_request_events'] = likeEvents;
        result['official_confirmation_samples'] = officialSamples;
        result['network_failure_categories'] = networkFailures;
        result['scope_rejected_requests'] = gate?.blockedRequests ?? 0;
        result['media_or_watch_requests_rejected'] =
            mediaOrWatchRequestsRejected;
        result['danmaku_or_paid_requests_rejected'] =
            danmakuOrPaidRequestsRejected;
        result['watch_report_requests_admitted'] = 0;
        result['danmaku_requests_admitted'] = 0;
        result['gift_or_wear_requests_admitted'] = 0;
        result['ended_utc'] = DateTime.now().toUtc().toIso8601String();
        if (safetyViolation ||
            (gate?.attemptedLikeClicks ?? 0) > 30 ||
            private != null && result['private_storage_removed'] != true ||
            const [
              'scheduler_cleanup_failed',
              'storage_close_failed',
              'private_storage_cleanup_failed',
            ].any((key) => result[key] == true)) {
          result['status'] = 'failed';
          result['failure_stage'] = 'scope_or_cleanup';
        }
        if (reportValidated && config != null) {
          try {
            if (Link(config.reportPath).existsSync()) {
              throw const _Failure('report_symlink_rejected');
            }
            await File(config.reportPath).writeAsString(
              const JsonEncoder.withIndent('  ').convert(result),
              flush: true,
            );
          } on Object {
            result['report_write_failed'] = true;
            result['status'] = 'failed';
          }
        }
        print(jsonEncode(result));
      }
      expect(
        result['harness_completed'],
        true,
        reason: 'Manual harness did not complete; inspect sanitized evidence.',
      );
      expect(
        result['status'],
        isNot('failed'),
        reason: 'A completed harness is separate from official acceptance.',
      );
    },
    skip: !const bool.fromEnvironment('LIVE_LIKE_ONLY_ACCOUNT_ACCEPTANCE'),
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
