// Manual LIVE-ROOM-01 acceptance. Both opt-ins are required before storage.
// Uses a disposable copy, preserves the original stale budget, and sends only
// bounded free interactions through the production automation policy.
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/services/live_intimacy_discovery.dart';
import 'package:PiliPlus/services/live_interaction_service.dart';
import 'package:PiliPlus/services/live_task_automation.dart';
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

import 'live_room_recovery_gate.dart';

class _Failure implements Exception {
  const _Failure(this.category);
  final String category;
}

class _QuietAccountManager extends AccountManager {
  @override
  void onError(DioException err, ErrorInterceptorHandler handler) =>
      handler.next(err);
}

Map<String, Object?> _safeTask(LiveFanTask task) => {
  'type': task.jumpType,
  'completed': task.completed,
  'current': task.currentCount,
  'target': task.targetCount,
  'remaining': task.remainingCount,
  'actions_per_progress': task.actionsPerProgress,
  'daily_reward_progress': task.dailyRewardProgress,
  'completion_only': task.completionOnly,
  'has_explicit_period': task.period.isNotEmpty,
};

List<Map<String, Object?>> _safeBudgets(Box<dynamic> box, String scope) {
  final index = liveMap(box.get('${scope}index'))['keys'];
  return [
    if (index is List)
      for (final key in index.whereType<String>())
        if (key.startsWith(scope))
          {
            for (final field in [
              'schema',
              'type',
              'initial_remaining',
              'target',
              'sent',
              'pending_count',
              'before_write_count',
              'highest_observed',
              'actions_per_progress',
              'verification_checks',
              'unknown',
              'server_completed',
              'retired',
              'count_mapping_confirmed',
              'daily_reward_progress',
              'completion_only',
              'consecutive_no_progress',
              'unconfirmed_count',
            ])
              if (liveMap(box.get(key)).containsKey(field))
                field: liveMap(box.get(key))[field] as Object?,
            'halted': liveMap(box.get(key))['halted'] != null,
            'pending_since_persisted':
                liveMap(box.get(key))['pending_since_millis'] is int,
          },
  ];
}

void main() {
  test(
    'explicitly authorized single-room production recovery acceptance',
    () async {
      final result = <String, Object?>{
        'schema_version': 1,
        'requirement': 'LIVE-ROOM-01',
        'status': 'starting',
        'scope': 'saved_authorization_single_room_free_interactions_no_media',
        'started_utc': DateTime.now().toUtc().toIso8601String(),
        'maximum_like_click_attempts': 30,
        'maximum_danmaku_attempts': 2,
        'other_client_activity': 'unobserved',
        'gui_verified': false,
      };
      final clock = Stopwatch()..start();
      final random = math.Random();
      final samples = <Map<String, Object?>>[];
      final states = <Map<String, Object?>>[];
      final requests = <Map<String, Object?>>[];
      result['official_task_samples'] = samples;
      result['automation_states'] = states;
      result['network_events'] = requests;
      LiveRoomRecoveryConfig? config;
      LiveRoomRecoveryRequestGate? gate;
      Directory? private;
      Box<dynamic>? journal;
      LiveInteractionService? reader;
      LiveIntimacyDiscovery? discovery;
      LiveTaskAutomationService? automation;
      LoginAccount? owner;
      int? generation;
      LiveIntimacyRoomPreferences? savedRoom;
      LiveFanTaskSnapshot? latest;
      DateTime? qualifiedAt;
      DateTime? taskObservedAt;
      var stage = 'explicit_authorization';
      var reportValidated = false;
      var clientStarted = false;
      var writesEnabled = false;
      var stopped = false;
      var qualificationConfirmed = false;
      var loginConfirmed = false;
      var safetyViolation = false;
      String? lastState;
      String? journalScope;
      var lastPulseMilliseconds = -30000;

      bool stoppedByMarker() {
        final settings = config;
        if (settings == null) return false;
        if (Link(settings.stopMarkerPath).existsSync()) {
          safetyViolation = true;
          stopped = true;
          return true;
        }
        if (File(settings.stopMarkerPath).existsSync()) {
          stopped = true;
          result['operator_stop_marker_observed'] = true;
        }
        return stopped;
      }

      bool identityConfirmed([RequestOptions? options]) =>
          owner != null &&
          identical(Accounts.main, owner) &&
          identical(Accounts.heartbeat, owner) &&
          !Accounts.mainIdentityChangeInProgress &&
          generation == Accounts.mainChangeGeneration &&
          !Pref.historyPause &&
          (options == null || identical(options.extra['account'], owner));

      bool savedAuthorizationConfirmed() {
        if (owner == null || config == null || savedRoom == null) return false;
        final saved = Pref.liveIntimacyPreferencesFor(owner.mid);
        final room = saved.roomFor(config.roomId, config.anchorUid);
        return saved.enabled &&
            room == savedRoom &&
            room!.authorized &&
            room.mode == LiveIntimacyRoomMode.full &&
            room.automation.danmakuMode == LiveTaskDanmakuMode.emoticon &&
            room.configurationIssue() == null;
      }

      bool mayRun() =>
          writesEnabled &&
          !stoppedByMarker() &&
          identityConfirmed() &&
          savedAuthorizationConfirmed();

      bool taskConfirmedFor(String path) {
        final snapshot = latest;
        if (!loginConfirmed ||
            !qualificationConfirmed ||
            snapshot == null ||
            qualifiedAt == null ||
            taskObservedAt == null ||
            DateTime.now().difference(qualifiedAt!) >
                const Duration(seconds: 75) ||
            DateTime.now().difference(taskObservedAt!) >
                const Duration(seconds: 45) ||
            !savedAuthorizationConfirmed() ||
            snapshot.roomId != config?.roomId ||
            snapshot.anchorUid != config?.anchorUid ||
            snapshot.accountUid != owner?.mid ||
            !identical(snapshot.accountIdentity, owner) ||
            snapshot.joined != true) {
          return false;
        }
        final type = path == LiveRoomRecoveryRequestGate.likePath
            ? 'like'
            : 'sendDanmu';
        final matches = snapshot.tasks
            .where((task) => task.jumpType == type)
            .toList();
        return matches.length == 1 &&
            matches.single.completed == false &&
            (matches.single.remainingCount ?? 0) > 0 &&
            (matches.single.targetCount ?? 10001) <= 10000 &&
            matches.single.actionsPerProgress != null &&
            matches.single.actionsPerProgress! > 0 &&
            matches.single.actionsPerProgress! <= 1000;
      }

      void recordState() {
        final active = automation;
        if (active == null) return;
        final signature =
            '${active.state.name}:${active.statusText}:${active.issuedLikes}:${active.issuedDanmaku}';
        if (signature == lastState) return;
        lastState = signature;
        final budgets = journal != null && journalScope != null
            ? _safeBudgets(journal, journalScope)
            : const <Map<String, Object?>>[];
        if (budgets.any(
          (budget) =>
              budget['type'] == 'sendDanmu' &&
              budget['pending_since_persisted'] == true,
        )) {
          result['first_pending_timer_persisted_elapsed_ms'] ??=
              clock.elapsedMilliseconds;
        }
        if (budgets.any(
          (budget) =>
              budget['type'] == 'sendDanmu' &&
              budget['pending_count'] == 0 &&
              (budget['consecutive_no_progress'] as int? ?? 0) > 0 &&
              (budget['unconfirmed_count'] as int? ?? 0) > 0,
        )) {
          result['first_bounded_recovery_elapsed_ms'] ??=
              clock.elapsedMilliseconds;
        }
        states.add({
          'elapsed_ms': clock.elapsedMilliseconds,
          'state': active.state.name,
          'status_text': active.statusText,
          'issued_likes': active.issuedLikes,
          'issued_danmaku': active.issuedDanmaku,
          'budgets': budgets,
        });
      }

      Future<LiveFanTaskSnapshot> readTasks() async {
        final snapshot = await reader!.loadFanTasks();
        if (!identityConfirmed() ||
            snapshot.roomId != config!.roomId ||
            snapshot.anchorUid != config.anchorUid ||
            snapshot.accountUid != owner!.mid ||
            !identical(snapshot.accountIdentity, owner) ||
            snapshot.joined != true) {
          throw const _Failure('official_task_identity_unconfirmed');
        }
        latest = snapshot;
        taskObservedAt = DateTime.now();
        samples.add({
          'elapsed_ms': clock.elapsedMilliseconds,
          'independent_read': true,
          'items': snapshot.tasks.map(_safeTask).toList(),
        });
        if (clock.elapsedMilliseconds - lastPulseMilliseconds >= 30000) {
          lastPulseMilliseconds = clock.elapsedMilliseconds;
          print(
            jsonEncode({
              'event': 'official_progress_sample',
              'elapsed_ms': clock.elapsedMilliseconds,
              'tasks': [
                for (final task in snapshot.tasks)
                  if (task.jumpType == 'like' || task.jumpType == 'sendDanmu')
                    _safeTask(task),
              ],
            }),
          );
        }
        return snapshot;
      }

      Future<void> qualify() async {
        qualificationConfirmed = false;
        final candidate = await discovery!.recheck(savedRoom!);
        if (!identityConfirmed() ||
            candidate.roomId != config!.roomId ||
            candidate.anchorUid != config.anchorUid ||
            !candidate.eligible) {
          throw const _Failure('current_followed_owned_live_room_unconfirmed');
        }
        qualifiedAt = DateTime.now();
        qualificationConfirmed = true;
        requests.add({
          'kind': 'qualification',
          'elapsed_ms': clock.elapsedMilliseconds,
          'followed': candidate.followed,
          'medal_owned': candidate.medalOwned,
          'live': candidate.live,
        });
      }

      try {
        config = LiveRoomRecoveryConfig.fromEnvironment(Platform.environment);
        result['public_room_id'] = config.roomId;
        result['requested_window_seconds'] = config.seconds;
        stage = 'external_report_path';
        if (Link(config.reportPath).existsSync() ||
            File(config.reportPath).existsSync() ||
            !File(config.reportPath).parent.existsSync() ||
            File(config.stopMarkerPath).existsSync() ||
            Link(config.stopMarkerPath).existsSync()) {
          throw const _Failure(
            'fresh_external_report_and_stop_marker_required',
          );
        }
        final sourceReal = await Directory(config.hivePath)
            .resolveSymbolicLinks();
        final reportReal = await File(config.reportPath).parent
            .resolveSymbolicLinks();
        if (reportReal == sourceReal || reportReal.startsWith('$sourceReal/')) {
          throw const _Failure('report_must_be_outside_source_storage');
        }
        reportValidated = true;
        stage = 'private_account_and_original_journal_copy';
        private = await Directory.systemTemp.createTemp('pili-room-recovery-');
        if ((await Process.run('/bin/chmod', ['700', private.path])).exitCode !=
            0) {
          throw const _Failure('private_permissions_failed');
        }
        for (final name in [
          'account.hive',
          'setting.hive',
          'localcache.hive',
          'livetaskautomationjournal.hive',
        ]) {
          final copy = await File('${config.hivePath}/$name')
              .copy('${private.path}/$name');
          if ((await Process.run('/bin/chmod', ['600', copy.path])).exitCode !=
              0) {
            throw const _Failure('private_permissions_failed');
          }
        }
        result['original_journal_copied_without_reset'] = true;
        Hive.init(private.path);
        GStorage.regAdapter();
        GStorage.setting = await Hive.openBox('setting');
        GStorage.video = await Hive.openBox('video');
        GStorage.localCache = await Hive.openBox('localCache');
        Accounts.account = await Hive.openBox<LoginAccount>('account');
        final account = Accounts.account.values
            .where((entry) => entry.type.contains(AccountType.main))
            .firstOrNull;
        final heartbeat = Accounts.account.values
            .where((entry) => entry.type.contains(AccountType.heartbeat))
            .firstOrNull;
        if (account == null ||
            !account.isLogin ||
            account.mid <= 0 ||
            !identical(account, heartbeat) ||
            Pref.historyPause) {
          throw const _Failure(
            'stored_main_recording_identity_or_privacy_conflict',
          );
        }
        owner = account;
        Accounts.accountMode[AccountType.main.index] = account;
        Accounts.accountMode[AccountType.heartbeat.index] = account;
        generation = Accounts.mainChangeGeneration;
        final preferences = Pref.liveIntimacyPreferencesFor(account.mid);
        savedRoom = preferences.roomFor(config.roomId, config.anchorUid);
        if (!savedAuthorizationConfirmed()) {
          throw const _Failure(
            'original_saved_full_emoticon_authorization_required',
          );
        }
        journal = await Hive.openBox<dynamic>('liveTaskAutomationJournal');
        journalScope = '${account.mid}:${config.roomId}:${config.anchorUid}:';
        final beforeBudgets = _safeBudgets(journal, journalScope);
        result['initial_budgets'] = beforeBudgets;
        if (!beforeBudgets.any(
          (budget) =>
              budget['type'] == 'sendDanmu' &&
              (budget['pending_count'] is int &&
                  (budget['pending_count'] as int) > 0),
        )) {
          throw const _Failure('original_pending_danmaku_budget_required');
        }
        gate = LiveRoomRecoveryRequestGate(
          roomId: config.roomId,
          anchorUid: config.anchorUid,
          accountUid: account.mid,
          savedEmoticons: savedRoom!.emoticons.map((entry) => entry.unique),
          windowSeconds: config.seconds,
        );
        await GStorage.setting.putAll({
          SettingBoxKey.enableHttp2: false,
          SettingBoxKey.enableSystemProxy: false,
          SettingBoxKey.retryCount: 0,
          SettingBoxKey.badCertificateCallback: false,
        });
        Request();
        clientStarted = true;
        Request.dio.options.followRedirects = false;
        Request.dio.options.receiveTimeout = const Duration(seconds: 15);
        Request.dio.interceptors.clear();
        Request.dio.interceptors.add(_QuietAccountManager());
        Request.dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (options, handler) {
              final allowed =
                  !stoppedByMarker() &&
                  gate!.allows(
                    uri: options.uri,
                    method: options.method,
                    query: options.queryParameters,
                    data: options.data,
                    elapsedMilliseconds: clock.elapsedMilliseconds,
                    writesEnabled: writesEnabled,
                    identityAndPrivacyConfirmed: identityConfirmed(options),
                    roomAndTaskConfirmed: taskConfirmedFor(options.uri.path),
                  );
              if (!allowed) {
                safetyViolation = safetyViolation || !stopped;
                requests.add({
                  'kind': 'scope_rejected',
                  'method': options.method,
                  'elapsed_ms': clock.elapsedMilliseconds,
                });
                handler.reject(
                  DioException.requestCancelled(
                    requestOptions: options,
                    reason: 'single_room_recovery_scope_rejected',
                  ),
                );
              } else {
                if (options.method == 'POST') {
                  requests.add({
                    'kind':
                        options.uri.path == LiveRoomRecoveryRequestGate.likePath
                        ? 'like_attempt'
                        : 'danmaku_attempt',
                    'elapsed_ms': clock.elapsedMilliseconds,
                    'clicks':
                        options.uri.path ==
                                LiveRoomRecoveryRequestGate.likePath &&
                            options.data is Map
                        ? LiveRoomRecoveryRequestGate.integer(
                            (options.data as Map)['click_time'],
                          )
                        : null,
                    'attempted_like_clicks': gate.attemptedLikeClicks,
                    'attempted_danmaku': gate.attemptedDanmaku,
                    if (options.uri.path == '/msg/send' && options.data is Map)
                      'saved_pool_index': savedRoom!.emoticons.indexWhere(
                        (entry) => entry.unique == (options.data as Map)['msg'],
                      ),
                  });
                }
                handler.next(options);
              }
            },
            onResponse: (response, handler) {
              final options = response.requestOptions;
              if (options.method == 'POST') {
                requests.add({
                  'kind':
                      options.uri.path == LiveRoomRecoveryRequestGate.likePath
                      ? 'like_response'
                      : 'danmaku_response',
                  'elapsed_ms': clock.elapsedMilliseconds,
                  'server_code': liveInt(liveMap(response.data)['code']),
                });
              }
              handler.next(response);
            },
            onError: (error, handler) {
              requests.add({
                'kind': 'network_error',
                'elapsed_ms': clock.elapsedMilliseconds,
                'method': error.requestOptions.method,
                'error_type': error.type.name,
              });
              handler.next(error);
            },
          ),
        );
        stage = 'login_confirmation';
        final nav = await Request.dio.get<dynamic>(
          'https://api.bilibili.com/x/web-interface/nav',
          options: Options(
            extra: {'account': account},
            headers: {'user-agent': BrowserUa.pc},
          ),
        );
        final envelope = liveMap(nav.data);
        final user = liveMap(envelope['data']);
        if (liveInt(envelope['code']) != 0 ||
            user['isLogin'] != true ||
            liveInt(user['mid']) != account.mid) {
          throw const _Failure('current_login_unconfirmed');
        }
        loginConfirmed = true;
        result['current_account_and_recording_confirmed'] = true;
        discovery = LiveIntimacyDiscovery.production();
        reader = LiveInteractionService(
          roomId: config.roomId,
          anchorUid: config.anchorUid,
        );
        stage = 'official_qualification';
        await qualify();
        final before = await readTasks();
        result['before_tasks'] = before.tasks.map(_safeTask).toList();
        final options = await reader.loadTaskEmoticons();
        final available = options
            .where(
              (entry) =>
                  entry.available &&
                  entry.isFanClub &&
                  savedRoom!.emoticons.any(
                    (saved) => saved.unique == entry.unique,
                  ),
            )
            .toList();
        if (available.isEmpty) {
          throw const _Failure('saved_fanclub_emoticons_unavailable');
        }
        result['available_saved_fanclub_emoticon_count'] = available.length;
        gate.confirmEmoticons(
          available.map((entry) => entry.unique),
          clock.elapsedMilliseconds,
        );
        automation = LiveTaskAutomationService.production(
          roomId: config.roomId,
          anchorUid: config.anchorUid,
          taskService: reader,
          externalScheduling: true,
          loadTasks: readTasks,
          mayRun: mayRun,
          chooseDanmaku: (identity, allowed) async {
            if (!mayRun() || !allowed() || !identical(identity, owner)) {
              return null;
            }
            final current = await reader!.loadTaskEmoticons();
            final selected = current
                .where(
                  (entry) =>
                      entry.available &&
                      entry.isFanClub &&
                      savedRoom!.emoticons.any(
                        (saved) => saved.unique == entry.unique,
                      ),
                )
                .toList();
            if (!mayRun() || !allowed() || selected.isEmpty) return null;
            gate!.confirmEmoticons(
              selected.map((entry) => entry.unique),
              clock.elapsedMilliseconds,
            );
            return LiveTaskDanmakuMessage.emoticon(
              emoticonUnique: selected[random.nextInt(selected.length)].unique,
              roomId: config!.roomId,
              anchorUid: config.anchorUid,
            );
          },
        );
        final active = automation..addListener(recordState);
        writesEnabled = true;
        gate.activateInteractions(clock.elapsedMilliseconds);
        active.update(
          playing: true,
          enhancementEnabled: true,
          autoLike: savedRoom.automation.autoLike,
          autoDanmaku: savedRoom.automation.autoDanmaku,
          defaultMessage: '',
          danmakuMessage: LiveTaskDanmakuMessage.emoticon(
            emoticonUnique: available.first.unique,
            roomId: config.roomId,
            anchorUid: config.anchorUid,
          ),
        );
        stage = 'bounded_production_recovery';
        final window = Stopwatch()..start();
        var nextRead = 0;
        var nextQualification = 60000;
        var nextLike = 1000 + random.nextInt(2001);
        var nextDanmaku = 30000 + random.nextInt(30001);
        while (window.elapsedMilliseconds < config.seconds * 1000) {
          if (stoppedByMarker()) break;
          if (!identityConfirmed() ||
              !savedAuthorizationConfirmed() ||
              safetyViolation) {
            throw const _Failure(
              'identity_privacy_authorization_or_scope_changed',
            );
          }
          final now = window.elapsedMilliseconds;
          if (now >= nextQualification) {
            await qualify();
            nextQualification = window.elapsedMilliseconds + 60000;
          }
          if (now >= nextRead) {
            await active.refreshTasks();
            nextRead = window.elapsedMilliseconds + 30000;
          }
          if (now >= nextLike) {
            nextLike = window.elapsedMilliseconds + 1000 + random.nextInt(2001);
            if (gate.remainingLikeClicks > 0) {
              await active.tickFromQueue(like: true);
            }
          }
          if (now >= nextDanmaku) {
            nextDanmaku =
                window.elapsedMilliseconds + 30000 + random.nextInt(30001);
            if (gate.remainingDanmaku > 0) {
              await active.tickFromQueue(danmaku: true);
            }
          }
          recordState();
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
        result['observation_end'] = stopped
            ? 'operator_graceful_stop'
            : 'bounded_window_elapsed';
        writesEnabled = false;
        active.stop();
        await active.settled.timeout(const Duration(seconds: 20));
        stage = 'final_official_read_only_confirmation';
        if (!stopped) {
          final after = await readTasks();
          result['after_tasks'] = after.tasks.map(_safeTask).toList();
          for (final type in ['like', 'sendDanmu']) {
            final first = before.tasks
                .where((task) => task.jumpType == type)
                .toList();
            final last = after.tasks
                .where((task) => task.jumpType == type)
                .toList();
            result['${type}_official_progress_increased'] =
                first.length == 1 &&
                last.length == 1 &&
                ((last.single.currentCount != null &&
                        first.single.currentCount != null &&
                        last.single.currentCount! >
                            first.single.currentCount!) ||
                    first.single.completed == false &&
                        last.single.completed == true);
          }
        }
        result['final_budgets'] = _safeBudgets(journal, journalScope);
        result['attempted_like_clicks'] = gate.attemptedLikeClicks;
        result['attempted_danmaku'] = gate.attemptedDanmaku;
        result['accepted_reads'] = gate.acceptedReads;
        result['blocked_requests'] = gate.blockedRequests;
        if (safetyViolation) throw const _Failure('request_scope_violation');
        result['harness_completed'] = true;
        result['status'] = 'completed';
      } catch (error) {
        result['status'] = 'failed';
        result['failure_stage'] = stage;
        result['error_type'] = error.runtimeType.toString();
        if (error is _Failure) result['failure_category'] = error.category;
      } finally {
        writesEnabled = false;
        if (automation != null) {
          try {
            automation.stop();
            await automation.settled.timeout(const Duration(seconds: 20));
            automation
              ..removeListener(recordState)
              ..dispose();
            result['automation_closed'] = true;
          } catch (_) {
            result['automation_close_failed'] = true;
            result['status'] = 'failed';
          }
        }
        discovery?.cancel();
        reader?.dispose();
        if (clientStarted) Request.dio.close(force: true);
        if (private != null) {
          try {
            await Hive.close().timeout(const Duration(seconds: 20));
          } catch (_) {
            result['storage_close_failed'] = true;
            result['status'] = 'failed';
          }
          try {
            await private.delete(recursive: true);
            result['private_copy_removed'] = !private.existsSync();
          } catch (_) {
            result['private_copy_remove_failed'] = true;
            result['status'] = 'failed';
          }
        }
        result['original_storage_opened_for_writing'] = false;
        result['ended_utc'] = DateTime.now().toUtc().toIso8601String();
        if (reportValidated && config != null) {
          try {
            if (Link(config.reportPath).existsSync()) {
              throw const _Failure('report_symlink_rejected');
            }
            await File(config.reportPath).writeAsString(
              const JsonEncoder.withIndent('  ').convert(result),
              flush: true,
            );
          } catch (_) {
            result['report_write_failed'] = true;
            result['status'] = 'failed';
          }
        }
        print(jsonEncode(result));
      }
      expect(
        result['harness_completed'],
        true,
        reason: 'Inspect the sanitized recovery evidence.',
      );
      expect(
        result['status'],
        'completed',
        reason: 'Harness completion is separate from official task progress.',
      );
    },
    skip: !const bool.fromEnvironment('LIVE_ROOM_RECOVERY_ACCOUNT_ACCEPTANCE'),
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
