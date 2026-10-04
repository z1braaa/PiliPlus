// Manual account acceptance. Never discovered by the ordinary offline suite.
// Requires both a compile-time opt-in and separate explicit environment consent.
// This is a headless native harness; it never claims to have verified the GUI.
// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/http/live.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/models_new/live/interactions/live_interaction_parser.dart';
import 'package:PiliPlus/services/live_automation_coordinator.dart';
import 'package:PiliPlus/services/live_intimacy_discovery.dart';
import 'package:PiliPlus/services/live_intimacy_scheduler.dart';
import 'package:PiliPlus/services/live_interaction_service.dart';
import 'package:PiliPlus/services/live_viewing_session.dart';
import 'package:PiliPlus/services/live_watch_reporter.dart';
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
import 'package:media_kit/media_kit.dart';

import 'live_intimacy_scheduler_acceptance_gate.dart';

Map<String, dynamic> _map(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : {};
int? _integer(Object? value) => value is int
    ? value
    : value is String && RegExp(r'^\d+$').hasMatch(value)
    ? int.tryParse(value)
    : null;

class _Failure implements Exception {
  const _Failure(this.category);
  final String category; // Only locally authored fixed categories are used.
}

class _QuietAccountManager extends AccountManager {
  @override
  void onError(DioException err, ErrorInterceptorHandler handler) =>
      handler.next(err);
}

class _SelectedRoom {
  const _SelectedRoom(
    this.candidate,
    this.preferences,
    this.before,
    this.observedAt,
  );
  final LiveIntimacyCandidate candidate;
  final LiveIntimacyRoomPreferences preferences;
  final List<LiveFanTask> before;
  final DateTime observedAt;
}

Map<String, Object?> _safeTasks(List<LiveFanTask> tasks) => {
  for (final kind in const ['like', 'sendDanmu', 'watchLive'])
    kind: () {
      final matches = tasks.where((task) => task.jumpType == kind).toList();
      if (matches.length != 1) return <String, Object?>{'confirmed': false};
      final task = matches.single;
      return <String, Object?>{
        'confirmed': true,
        'completed': task.completed,
        'current': task.currentCount,
        'target': task.targetCount,
        'completion_only': task.completionOnly,
        'daily_reward_progress': task.dailyRewardProgress,
        'has_explicit_period': task.period.isNotEmpty,
        if (kind == 'watchLive')
          'threshold_seconds': LiveIntimacyWatchProgress.thresholdFor(task),
      };
    }(),
};

int _interactionBudget(List<LiveFanTask> tasks, String kind) {
  final task = tasks.where((task) => task.jumpType == kind).single;
  if (task.completed == true) return 0;
  final remaining = task.remainingCount;
  final multiplier = task.dailyRewardProgress || task.completionOnly
      ? task.actionsPerProgress
      : 1;
  if (remaining == null ||
      multiplier == null ||
      remaining < 0 ||
      multiplier <= 0 ||
      remaining * multiplier > 10000) {
    throw const _Failure('interaction_budget_unconfirmed');
  }
  return remaining * multiplier;
}

Map<String, Object?> _featureEvidence(
  List<LiveFanTask> before,
  List<LiveFanTask> after,
  Map<String, int> accepted,
) => {
  for (final kind in const ['like', 'sendDanmu'])
    kind: () {
      final old = before.where((task) => task.jumpType == kind).single;
      final current = after.where((task) => task.jumpType == kind).toList();
      final amount =
          accepted[kind == 'like'
              ? 'accepted_like_clicks'
              : 'accepted_emote_requests'] ??
          0;
      if (current.length != 1) {
        return <String, Object?>{
          'exercised': amount > 0,
          'accepted_amount': amount,
          'official_confirmed': false,
          'state': 'official_task_unconfirmed',
        };
      }
      final latest = current.single;
      final increased =
          old.currentCount != null &&
              latest.currentCount != null &&
              latest.currentCount! > old.currentCount! ||
          old.completed != true && latest.completed == true;
      final alreadyComplete =
          old.completed == true && latest.completed == true && amount == 0;
      return <String, Object?>{
        'exercised': amount > 0,
        'accepted_amount': amount,
        'official_progress_increased': increased,
        'already_complete_stayed_stopped': alreadyComplete,
        'official_confirmed': amount > 0 && increased || alreadyComplete,
        'state': alreadyComplete
            ? 'already_complete_no_send'
            : amount > 0 && increased
            ? 'exercised_official_progress_confirmed'
            : amount > 0
            ? 'accepted_write_official_progress_not_observed'
            : increased
            ? 'official_change_no_harness_write_observed'
            : 'not_exercised',
      };
    }(),
};

String? _pauseCategory(String? reason) =>
    liveSchedulerSafeStateReason(reason)['category'] as String?;

Map<String, Object?> _roomDiagnostics(LiveIntimacyRoomState? state) {
  final reasons = {
    'watch_pause': state?.watchPauseReason,
    'common_pause': state?.pauseReason,
    'interaction_pause': state?.interactionPauseReason,
    'record_restore_error': state?.recordRestoreError,
    'record_save_error': state?.recordSaveError,
  };
  return {
    for (final entry in reasons.entries) ...{
      '${entry.key}_present': entry.value != null,
      '${entry.key}_category': liveSchedulerSafeStateReason(
        entry.value,
      )['category'],
      '${entry.key}_reason': liveSchedulerSafeStateReason(
        entry.value,
      )['message'],
    },
    'watch_running': state?.watchRunning,
    'interaction_running': state?.interactionRunning,
    'official_fresh': state?.officialFresh,
    'official_cycle_uncertain': state?.officialCycle.uncertain,
    'candidate_live': state?.candidate?.live,
    'candidate_followed': state?.candidate?.followed,
    'candidate_medal_owned': state?.candidate?.medalOwned,
  };
}

void main() {
  test(
    'explicitly authorized native background scheduler acceptance',
    () async {
      final result = <String, dynamic>{
        'schema_version': 3,
        'status': 'starting',
        'started_utc': DateTime.now().toUtc().toIso8601String(),
        'started_client_calendar_utc_plus_8': DateTime.now()
            .toUtc()
            .add(const Duration(hours: 8))
            .toIso8601String()
            .substring(0, 10),
        'scope': 'two_selected_rooms_independent_interactions_single_watch_first_fan_emote',
        'gui_verified': false,
        'native_foreground_is_route_hint_simulation': true,
        'two_room_watch_settlement': 'not_observed',
        'automatic_completion_transfer': 'not_observed',
        'dual_queue_interactions_during_other_room_watch': 'not_observed',
        'bounded_lighting_phase_stop': false,
        'new_daily_phase_observed': false,
      };
      LiveSchedulerAcceptanceConfig? config;
      Directory? private;
      LiveIntimacyScheduler? scheduler;
      LiveIntimacyDiscovery? discovery;
      LiveViewingSession? foreground;
      Player? frontPlayer;
      Timer? frontSamples;
      final subscriptions = <StreamSubscription<dynamic>>[];
      final readers = <LiveInteractionService>[];
      var clientStarted = false;
      var stage = 'explicit_authorization';
      final requestClock = Stopwatch()..start();
      final aliases = <int, String>{};
      final medalLightingByAnchor = <int, bool?>{};
      LiveSchedulerAcceptanceWriteGuard? writeGuard;
      LoginAccount? authorizedAccount;
      int? authorizedGeneration;
      final explicitlyAuthorizedRooms = <int>{};
      void Function()? targetListener;
      void Function()? inspectBoundedLighting;
      Future<void>? boundedLightingStop;
      var boundedLightingStopFailed = false;
      final activatedInteractionRooms = <int>{};
      int? frontRoomId;
      final writeStatistics = <String, Map<String, int>>{};
      final acceptedEvents = <Map<String, Object?>>[];
      result['accepted_request_events_not_official_progress'] = acceptedEvents;
      final requestCounts = <String, int>{};
      result['allowed_request_method_counts'] = requestCounts;
      var writesEnabled = false;
      var rejectedRequests = 0;
      final nativeErrorMonitor = LiveSchedulerNativeErrorMonitor();
      final nativeErrorEvents = <Map<String, Object?>>[];
      result['native_error_events'] = nativeErrorEvents;
      var frontUserPaused = false;
      final roomReasonEvents = <Map<String, Object?>>[];
      final lastRoomDiagnostics = <int, String>{};
      result['room_reason_change_events'] = roomReasonEvents;

      void activateInteractions() {
        for (final state in scheduler?.rooms ?? <LiveIntimacyRoomState>[]) {
          if (state.interactionRunning &&
              explicitlyAuthorizedRooms.contains(state.roomId) &&
              activatedInteractionRooms.add(state.roomId)) {
            writeGuard?.activateRoom(
              state.roomId,
              requestClock.elapsedMilliseconds,
            );
          }
        }
      }

      void record() {
        final path = config?.reportPath;
        if (path == null) return;
        try {
          if (Link(path).existsSync()) {
            throw const FileSystemException('symlink_report_rejected');
          }
          File(path).writeAsStringSync(jsonEncode(result));
        } on FileSystemException {
          result['report_write_failed'] = true;
          result['status'] = 'failed';
          result['failure_stage'] = 'report_write';
        }
      }

      void observeRoomReasons() {
        final active = scheduler;
        if (active == null) return;
        for (final state in active.rooms) {
          final alias = aliases[state.roomId];
          if (alias == null) continue;
          final diagnostics = {
            ..._roomDiagnostics(state),
            'background_target': aliases[active.currentRoom?.roomId],
            'background_owns_watch': active.ownsWatchReporter,
          };
          final fingerprint = jsonEncode(diagnostics);
          if (lastRoomDiagnostics[state.roomId] == fingerprint) continue;
          lastRoomDiagnostics[state.roomId] = fingerprint;
          if (roomReasonEvents.length >= 1024) {
            result['room_reason_change_event_limit_reached'] = true;
            continue;
          }
          roomReasonEvents.add({
            'request_elapsed_milliseconds': requestClock.elapsedMilliseconds,
            'room_alias': alias,
            ...diagnostics,
          });
          record();
        }
      }

      Future<bool> requestedStop() async {
        final path = config!.stopMarkerPath;
        if (Link(path).existsSync()) {
          throw const _Failure('stop_marker_symlink_rejected');
        }
        if (!File(path).existsSync()) return false;
        result['observation_end'] = 'operator_requested_graceful_stop';
        result['operator_stop_marker_observed'] = true;
        frontSamples?.cancel();
        foreground?.updatePlayback(
          playing: false,
          buffering: true,
          live: true,
        );
        final active = scheduler;
        if (active != null) {
          await active.savePreferences(
            active.preferences.copyWith(enabled: false),
          );
        }
        writesEnabled = false;
        return true;
      }

      int? watchRoom(RequestOptions options) =>
          LiveSchedulerAcceptanceWriteGuard.watchRoom(options.queryParameters);

      bool allow(RequestOptions options) {
        final guard = writeGuard ?? LiveSchedulerAcceptanceWriteGuard({});
        final mainIdentityConfirmed =
            authorizedAccount != null &&
            identical(Accounts.main, authorizedAccount) &&
            identical(Accounts.heartbeat, authorizedAccount) &&
            !Accounts.mainIdentityChangeInProgress &&
            authorizedGeneration == Accounts.mainChangeGeneration &&
            !Pref.historyPause &&
            options.extra['account'] != null &&
            identical(options.extra['account'], authorizedAccount);
        return guard.allow(
          uri: options.uri,
          method: options.method,
          query: options.queryParameters,
          data: options.data,
          elapsedMilliseconds: requestClock.elapsedMilliseconds,
          writesEnabled: writesEnabled,
          readOnly: config?.readOnly ?? true,
          identityAndPrivacyConfirmed: mainIdentityConfirmed,
          roomAuthorized: (roomId, interactive) {
            if (!explicitlyAuthorizedRooms.contains(roomId) ||
                authorizedAccount == null) {
              return false;
            }
            final scope = guard.rooms[roomId];
            if (scope == null) return false;
            final saved = Pref.liveIntimacyPreferencesFor(
              authorizedAccount.mid,
            );
            final room = saved.roomFor(roomId, scope.anchorUid);
            final coordinator = LiveAutomationCoordinator.instance;
            final watchOwnerConfirmed = coordinator.backgroundWatchClaimed
                ? scheduler?.ownsWatchReporter == true &&
                      scheduler?.currentRoom?.roomId == roomId
                : roomId == frontRoomId;
            final state = scheduler?.stateFor(roomId, scope.anchorUid);
            final kind = options.uri.path == '/msg/send' ? 'sendDanmu' : 'like';
            final matchingTasks = state?.tasks
                .where((task) => task.jumpType == kind)
                .toList();
            final interactionConfirmed =
                saved.enabled &&
                state?.candidate?.eligible == true &&
                state?.officialFresh == true &&
                state?.officialCycle.uncertain == false &&
                state?.pauseReason == null &&
                matchingTasks?.length == 1 &&
                matchingTasks!.single.completed == false &&
                (matchingTasks.single.remainingCount ?? 0) > 0;
            return room != null &&
                room.authorized &&
                room.automation.autoLike &&
                room.automation.autoDanmaku &&
                room.automation.danmakuMode == LiveTaskDanmakuMode.emoticon &&
                room.emoticons.length == scope.permittedEmoticons.length &&
                room.emoticons.every(
                  (emoticon) =>
                      scope.permittedEmoticons.contains(emoticon.unique),
                ) &&
                (!interactive || interactionConfirmed) &&
                (interactive ||
                    watchOwnerConfirmed ||
                    config?.diagnosticRoomEntry == true &&
                        options.uri.path ==
                            '/xlive/web-room/v1/index/roomEntryAction' &&
                        options.queryParameters['csrf'] ==
                            authorizedAccount.csrf);
          },
        );
      }

      void observeResponse(Response<dynamic> response) {
        final options = response.requestOptions;
        if (options.method == 'GET' && _map(response.data)['code'] == 0) {
          if (options.uri.path == '/xlive/app-ucenter/v1/fansMedal/panel') {
            for (final medal in LiveInteractionParser.medals(
              _map(_map(response.data)['data']),
            )) {
              medalLightingByAnchor[medal.targetUid] = medal.isLighted;
            }
          }
          if (options.uri.path == '/room/v1/Room/room_init') {
            result['room_init_observed'] = true;
          }
          if (options.uri.path.endsWith('/GetActivatedMedalInfo')) {
            final alias = aliases[_integer(options.queryParameters['room_id'])];
            if (alias != null) {
              final data = _map(_map(response.data)['data']);
              final safe = <String, Object?>{};
              for (final field in const [
                'is_lighted',
                'free_intimacy',
                'reach_free_intimacy_limit',
              ]) {
                final value = data[field];
                if (value is bool ||
                    value is int ||
                    value is String && const ['0', '1'].contains(value)) {
                  safe[field] = value;
                }
              }
              (result.putIfAbsent(
                'official_medal_state',
                () => <String, Object?>{},
              ) as Map<String, Object?>)[alias] = safe;
            }
          }
        }
        if (options.method != 'POST') {
          return;
        }
        if (_map(response.data)['code'] != 0) {
          (result.putIfAbsent(
            'server_rejected_posts',
            () => <Map<String, Object?>>[],
          ) as List<Map<String, Object?>>).add({
            'elapsed_milliseconds': requestClock.elapsedMilliseconds,
            'host': options.uri.host,
            'path': options.uri.path,
            'http_status': response.statusCode,
            'server_code': _integer(_map(response.data)['code']),
          });
          return;
        }
        final body = _map(options.data);
        final room = options.uri.host == 'live-trace.bilibili.com'
            ? watchRoom(options)
            : _integer(body['room_id'] ?? body['roomid']);
        final alias = aliases[room];
        if (alias == null) return;
        final statistics = writeStatistics.putIfAbsent(alias, () => {});
        final key = options.uri.path.endsWith('/X')
            ? 'accepted_watch_seconds'
            : options.uri.path.endsWith('/E')
            ? 'accepted_watch_entries'
            : options.uri.path == '/msg/send'
            ? 'accepted_emote_requests'
            : options.uri.path.endsWith('/roomEntryAction')
            ? 'accepted_room_entries'
            : 'accepted_like_clicks';
        final amount = LiveSchedulerAcceptanceWriteGuard.acceptedAmount(
          options.uri,
          options.queryParameters,
          options.data,
        );
        statistics[key] = (statistics[key] ?? 0) + amount;
        acceptedEvents.add({
          'elapsed_milliseconds': requestClock.elapsedMilliseconds,
          'room': alias,
          'kind': key,
          'accepted_amount': amount,
          if (options.uri.path == '/msg/send') 'fan_emoticon': body['msg'],
          'watch_room': aliases[scheduler?.currentRoom?.roomId],
          'watch_owner': scheduler?.ownsWatchReporter == true,
          'interaction_room':
              aliases[scheduler?.currentInteractionRoom?.roomId],
        });
      }

      try {
        config = LiveSchedulerAcceptanceConfig.fromEnvironment(
          Platform.environment,
        );
        result['native_source'] = config.nativeSource;
        result['diagnostic_room_entry'] = config.diagnosticRoomEntry;
        result['requested_window_seconds'] = config.seconds;
        result['interaction_hard_limits'] = config.interactionLimits;
        result['requested_fan_emote_pool_size'] = config.fanEmotePoolSize;
        result['watch_only_no_interaction_writes'] = config.watchOnly;
        if (config.fanEmotePoolSize > 1) {
          result['emoticon_test_authorization'] =
              'one_to_five_available_anchor_fan_club_emoticons_no_text';
        }
        result['watch_priority_scenario'] = config.keepBWatchPriority
            ? 'A_first_180_seconds_then_B_until_observation_end'
            : 'A_then_B_preemption_then_A_restore';
        if (config.singleRoom) {
          result['scope'] = 'single_selected_room_background_audio_first_fan_emote_initial_budgets_only';
          result['native_foreground_is_route_hint_simulation'] = false;
          result['two_room_watch_settlement'] = 'not_exercised_single_room';
          result['automatic_completion_transfer'] = 'not_exercised_single_room';
        }
        stage = 'private_storage';
        private = await Directory.systemTemp.createTemp(
          'pili-scheduler-acceptance-',
        );
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
            !identical(account, recording) ||
            Pref.historyPause) {
          throw const _Failure('recording_identity_or_privacy_conflict');
        }
        Accounts.accountMode[AccountType.main.index] = account;
        Accounts.accountMode[AccountType.heartbeat.index] = account;
        authorizedAccount = account;
        authorizedGeneration = Accounts.mainChangeGeneration;
        await GStorage.setting.putAll({
          SettingBoxKey.enableHttp2: false,
          SettingBoxKey.enableSystemProxy: false,
          SettingBoxKey.retryCount: 0,
          SettingBoxKey.badCertificateCallback: false,
        });
        // Clear only the disposable authorization domain; no old room grants
        // from the original account are admitted into this two-room experiment.
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
              if (!allow(options)) {
                ++rejectedRequests;
                handler.reject(
                  DioException.requestCancelled(
                    requestOptions: options,
                    reason: 'scheduler_acceptance_scope_rejected',
                  ),
                );
              } else {
                requestCounts.update(
                  options.method,
                  (count) => count + 1,
                  ifAbsent: () => 1,
                );
                handler.next(options);
              }
            },
            onResponse: (response, handler) {
              observeResponse(response);
              inspectBoundedLighting?.call();
              handler.next(response);
            },
            onError: (error, handler) {
              inspectBoundedLighting?.call();
              (result.putIfAbsent(
                'network_failures',
                () => <Map<String, Object?>>[],
              ) as List<Map<String, Object?>>).add({
                'host': error.requestOptions.uri.host,
                'path': error.requestOptions.uri.path,
                'http_status': error.response?.statusCode,
                'error_type': error.type.name,
              });
              handler.next(error);
            },
          ),
        );
        final options = Options(
          extra: {'account': account},
          headers: {'user-agent': BrowserUa.pc},
          followRedirects: false,
        );
        Future<Map<String, dynamic>> get(
          String path,
          Map<String, dynamic> query, {
          bool general = false,
        }) async => _map(
          (await Request.dio.get<dynamic>(
            '${general ? "https://api.bilibili.com" : "https://api.live.bilibili.com"}$path',
            queryParameters: query.isEmpty ? null : query,
            options: options,
          )).data,
        );

        stage = 'login';
        final nav = await get('/x/web-interface/nav', {}, general: true);
        if (nav['code'] != 0 ||
            _map(nav['data'])['isLogin'] != true ||
            _integer(_map(nav['data'])['mid']) != account.mid) {
          throw const _Failure('main_login_unconfirmed');
        }
        result['account_confirmed'] = true;
        stage = 'read_only_selection';
        final seeds = <LiveIntimacyRoomPreferences>[];
        final seen = <int>{};
        int? totalPages;
        for (var page = 1; page <= 500; ++page) {
          final response = await get(LiveIntimacyDiscovery.followingPath, {
            'page': page,
            'page_size': 9,
            'ignoreRecord': 1,
            'hit_ab': true,
          });
          final data = _map(response['data']);
          final pages = _integer(data['totalPage']);
          if (response['code'] != 0 ||
              pages == null ||
              pages < 0 ||
              pages > 500 ||
              data['list'] is! List ||
              totalPages != null && totalPages != pages) {
            throw const _Failure('following_pagination_unconfirmed');
          }
          totalPages = pages;
          for (final entry in (data['list'] as List).whereType<Map>()) {
            final uid = _integer(entry['uid']);
            final room = _integer(entry['roomid']);
            if (uid == null || uid <= 0 || !seen.add(uid)) {
              throw const _Failure(
                'following_identity_or_duplicates_unconfirmed',
              );
            }
            if (room != null &&
                room > 0 &&
                _integer(entry['is_attention']) == 1 &&
                _integer(entry['live_status']) == 1) {
              // The transient flag only tells the production read API which
              // identities to inspect; these seeds are never saved as grants.
              seeds.add(
                LiveIntimacyRoomPreferences(
                  anchorUid: uid,
                  roomId: room,
                  authorized: true,
                ),
              );
            }
          }
          if (pages == 0 || page >= pages) break;
          if ((data['list'] as List).isEmpty) {
            throw const _Failure('following_pagination_unconfirmed');
          }
        }
        discovery = LiveIntimacyDiscovery.production();
        final found =
            (await discovery.discover(seeds))
                .where((item) => item.eligible)
                .toList()
              ..sort((left, right) {
                final levels = right.medalLevel.compareTo(left.medalLevel);
                return levels != 0
                    ? levels
                    : left.anchorUid.compareTo(right.anchorUid);
              });
        result['discovery_evidence'] = {
          'live_follow_seeds': seeds.length,
          'followed_medal_live_candidates': found.length,
          'preferred_a_eligible': config.preferredA == null
              ? null
              : found.any((room) => room.roomId == config!.preferredA),
        };
        result['eligible_medal_lighting_read_only'] = {
          'lighting_source': 'existing_complete_personal_medal_panel_reads',
          'unlit_public_samples': [
            for (final candidate in found)
              if (medalLightingByAnchor[candidate.anchorUid] == false)
                {
                  'room_id': candidate.roomId,
                  'anchor_uid': candidate.anchorUid,
                  'medal_level': candidate.medalLevel,
                },
          ],
          'lighted_count': found
              .where(
                (candidate) =>
                    medalLightingByAnchor[candidate.anchorUid] == true,
              )
              .length,
          'lighting_unconfirmed_count': found
              .where(
                (candidate) =>
                    medalLightingByAnchor[candidate.anchorUid] == null,
              )
              .length,
          'did_not_activate_wear_join_or_send_gifts': true,
        };
        final selectionChecks = <String, int>{};
        result['selection_checks'] = selectionChecks;
        void checked(String reason) => selectionChecks.update(
          reason,
          (value) => value + 1,
          ifAbsent: () => 1,
        );
        final selected = <_SelectedRoom>[];
        final requiredRooms = config.singleRoom ? 1 : 2;
        final preferred = [config.preferredA, config.preferredB];
        final ordered = [
          if (config.preferredA != null)
            ...found.where((item) => item.roomId == config!.preferredA),
          ...found.where((item) => !preferred.contains(item.roomId)),
          if (config.preferredB != null)
            ...found.where((item) => item.roomId == config!.preferredB),
        ];
        // Reserve the second explicit choice instead of allowing it to become A
        // when only a B preference is supplied.
        final reservedB = config.preferredB;
        // A needs a watch baseline. A higher-ranked lighting candidate skipped
        // before A is found must get another chance to be B afterwards.
        for (final item in [...ordered, ...ordered]) {
          if (selected.any(
            (room) => room.candidate.anchorUid == item.anchorUid,
          )) {
            continue;
          }
          final seed = LiveIntimacyRoomPreferences(
            anchorUid: item.anchorUid,
            roomId: item.roomId,
          );
          final verified = await discovery.recheck(seed);
          if (!verified.eligible) {
            checked('recheck_not_eligible');
            continue;
          }
          checked('recheck_eligible');
          final reader = LiveInteractionService(
            roomId: verified.roomId,
            anchorUid: verified.anchorUid,
          );
          readers.add(reader);
          final tasks = await reader.loadFanTasks();
          final taskObservedAt = DateTime.now().toUtc();
          final selectingA = selected.isEmpty;
          final watchCount = tasks.tasks
              .where((task) => task.jumpType == 'watchLive')
              .length;
          if (tasks.joined != true) checked('medal_not_confirmed');
          if (liveIntimacyTasksCompleted(tasks.tasks)) {
            checked('three_already_completed');
          }
          for (final type in const ['like', 'sendDanmu', 'watchLive']) {
            if (tasks.tasks.where((task) => task.jumpType == type).length !=
                1) {
              checked('missing_$type');
            }
          }
          if (tasks.joined != true ||
              liveIntimacyTasksCompleted(tasks.tasks) ||
              const ['like', 'sendDanmu'].any(
                (type) =>
                    tasks.tasks.where((task) => task.jumpType == type).length !=
                    1,
              ) ||
              (selectingA ? watchCount != 1 : watchCount > 1)) {
            continue;
          }
          if (!selectingA && watchCount == 0) {
            checked('b_missing_watch_allowed_known_interactions_only');
          }
          if (watchCount == 1 &&
              liveIntimacyTaskCompleted(tasks.tasks, 'watchLive')) {
            checked('watch_already_complete_not_watch_queue_sample');
            continue;
          }
          final interactionsComplete = const ['like', 'sendDanmu'].every(
            (kind) => liveIntimacyTaskCompleted(tasks.tasks, kind),
          );
          if (config.watchOnly && !interactionsComplete) {
            checked('watch_only_requires_both_interactions_complete');
            continue;
          }
          if (!config.watchOnly && interactionsComplete) {
            checked('interactions_already_complete_not_dual_queue_sample');
            continue;
          }
          final expressions = await get(
            '/xlive/web-ucenter/v2/emoticon/GetEmoticons',
            {
              'platform': 'pc',
              'room_id': verified.roomId,
            },
          );
          if (expressions['code'] != 0) {
            checked('emoticon_read_failed');
            continue;
          }
          final first = liveSchedulerFirstFanEmoticon(
            _map(expressions['data'])['data'],
          );
          if (first == null && config.fanEmotePoolSize == 1) {
            checked('first_emoticon_unavailable');
            continue;
          }
          final expectedPoolSize = config.fanEmotePoolSize;
          final pool = (await reader.loadTaskEmoticons())
              .where(
                (option) =>
                    option.available &&
                    option.isFanClub &&
                    (expectedPoolSize > 1 || option.unique == first),
              )
              .take(config.fanEmotePoolSize)
              .toList();
          if (pool.length != expectedPoolSize ||
              pool.map((option) => option.unique).toSet().length !=
                  expectedPoolSize) {
            checked('first_emoticon_recheck_unavailable');
            continue;
          }
          checked('first_emoticon_available');
          try {
            _interactionBudget(tasks.tasks, 'like');
            _interactionBudget(tasks.tasks, 'sendDanmu');
          } on _Failure {
            checked('interaction_budget_unconfirmed');
            continue;
          }
          final configuration = seed.copyWith(
            roomId: verified.roomId,
            automation: const LiveTaskAutomationPreferences(
              autoLike: true,
              autoDanmaku: true,
              danmakuMode: LiveTaskDanmakuMode.emoticon,
              minIntervalSeconds: 30,
              maxIntervalSeconds: 60,
            ),
            emoticons: [
              for (final expression in pool)
                LiveIntimacyEmoticonSelection(
                  unique: expression.unique,
                  label: expression.label,
                ),
            ],
          );
          if (reservedB != null &&
              selected.isNotEmpty &&
              verified.roomId != reservedB) {
            continue;
          }
          selected.add(
            _SelectedRoom(verified, configuration, tasks.tasks, taskObservedAt),
          );
          if (selected.length == requiredRooms) break;
        }
        if (selected.length != requiredRooms ||
            !config.singleRoom &&
                selected[0].candidate.anchorUid ==
                    selected[1].candidate.anchorUid) {
          throw _Failure(
            config.singleRoom
                ? 'one_qualified_unfinished_room_unavailable'
                : 'two_qualified_unfinished_rooms_unavailable',
          );
        }
        if (config.preferredA != null &&
                selected[0].candidate.roomId != config.preferredA ||
            config.preferredB != null &&
                selected[1].candidate.roomId != config.preferredB) {
          throw const _Failure('preferred_room_not_eligible');
        }
        result['selected_rooms_count'] = requiredRooms;
        result['selection_follow_medal_live_confirmed'] = true;
        result['selected_public_rooms'] = [
          for (var i = 0; i < selected.length; ++i)
            {
              'alias': i == 0 ? 'A' : 'B',
              'room_id': selected[i].candidate.roomId,
              'anchor_uid': selected[i].candidate.anchorUid,
              'medal_level': selected[i].candidate.medalLevel,
              (config.fanEmotePoolSize == 1
                      ? 'first_fan_emoticon'
                      : 'selected_first_fan_emoticon'):
                  selected[i].preferences.emoticons.first.unique,
              (config.fanEmotePoolSize == 1
                      ? 'first_fan_emoticon_label'
                      : 'selected_first_fan_emoticon_label'):
                  selected[i].preferences.emoticons.first.label,
              'selected_fan_emoticons': [
                for (final expression in selected[i].preferences.emoticons)
                  {'unique': expression.unique, 'label': expression.label},
              ],
              'initial_like_click_budget': _interactionBudget(
                selected[i].before,
                'like',
              ),
              'initial_emote_budget': _interactionBudget(
                selected[i].before,
                'sendDanmu',
              ),
              'admitted_like_click_budget': config.limitedInteractionBudget(
                i == 0 ? 'A' : 'B',
                'like',
                _interactionBudget(selected[i].before, 'like'),
              ),
              'admitted_emote_budget': config.limitedInteractionBudget(
                i == 0 ? 'A' : 'B',
                'sendDanmu',
                _interactionBudget(selected[i].before, 'sendDanmu'),
              ),
              'official_read_completed_utc': selected[i].observedAt
                  .toIso8601String(),
            },
        ];
        result['before'] = {
          for (var i = 0; i < selected.length; ++i)
            (i == 0 ? 'A' : 'B'): _safeTasks(selected[i].before),
        };
        result['missing_watch_task_before'] = {
          for (var i = 0; i < selected.length; ++i)
            (i == 0 ? 'A' : 'B'): !selected[i].before.any(
              (task) => task.jumpType == 'watchLive',
            ),
        };
        result['lighting_phase_before'] = {
          for (var i = 0; i < selected.length; ++i)
            (i == 0 ? 'A' : 'B'): selected[i].before.any(
              (task) => task.completionOnly,
            ),
        };
        if (config.readOnly) {
          result['status'] = 'read_only_selected';
          result['harness_completed'] = true;
        } else if (config.singleRoom) {
          if (config.watchOnly) {
            result['scope'] = 'single_selected_room_watch_only_background_audio_no_interactions';
          } else if (config.fanEmotePoolSize > 1) {
            result['scope'] = 'single_selected_room_background_audio_selected_fan_emoticon_pool_initial_budgets_only';
          }
          final a = selected.single;
          aliases[a.candidate.roomId] = 'A';
          writeGuard = LiveSchedulerAcceptanceWriteGuard({
            a.candidate.roomId: LiveSchedulerAcceptanceRoomScope(
              anchorUid: a.candidate.anchorUid,
              emoticon: a.preferences.emoticons.first.unique,
              additionalEmoticons: a.preferences.emoticons
                  .skip(1)
                  .map((expression) => expression.unique)
                  .toSet(),
              likeClicks: config.limitedInteractionBudget(
                'A',
                'like',
                _interactionBudget(a.before, 'like'),
              ),
              danmakuCount: config.limitedInteractionBudget(
                'A',
                'sendDanmu',
                _interactionBudget(a.before, 'sendDanmu'),
              ),
            ),
          }, diagnosticRoomEntry: config.diagnosticRoomEntry);
          stage = 'explicit_single_room_authorization';
          MediaKit.ensureInitialized(libmpv: config.libraryPath);
          final activeScheduler = scheduler = LiveIntimacyScheduler.instance
            ..start();
          targetListener = () {
            activateInteractions();
            observeRoomReasons();
          };
          activeScheduler
            ..addListener(targetListener)
            ..updateForeground(
              roomId: a.candidate.roomId,
              anchorUid: a.candidate.anchorUid,
            );
          await activeScheduler.saveRoomPreferences(a.preferences);
          final issue = await activeScheduler.authorizeRoom(
            a.preferences,
            true,
          );
          if (issue != null) {
            throw const _Failure('explicit_room_authorization_rejected');
          }
          explicitlyAuthorizedRooms.add(a.candidate.roomId);
          if (activeScheduler.preferences.enabled ||
              activeScheduler.preferences.rooms.length != 1 ||
              !activeScheduler.preferences.rooms.single.authorized) {
            throw const _Failure('master_off_authorization_unconfirmed');
          }
          activeScheduler.updateForeground(playing: false);
          result['master_off_explicit_grants_confirmed'] = true;
          result['foreground_hint_cleared_before_run'] = true;
          result['foreground_player_created'] = false;
          writesEnabled = true;
          if (config.diagnosticRoomEntry) {
            final entry = await Request.dio.post<dynamic>(
              'https://api.live.bilibili.com/xlive/web-room/v1/index/roomEntryAction',
              queryParameters: {'csrf': account.csrf},
              data: {'room_id': a.candidate.roomId, 'platform': 'pc'},
              options: Options(
                extra: {'account': account},
                followRedirects: false,
              ),
            );
            if (_map(entry.data)['code'] != 0) {
              throw const _Failure('diagnostic_room_entry_rejected');
            }
            result['diagnostic_room_entry_accepted'] = true;
          }
          await activeScheduler.savePreferences(
            activeScheduler.preferences.copyWith(enabled: true),
          );
          final run = Stopwatch()..start();
          result['run_started_utc'] = DateTime.now().toUtc().toIso8601String();
          final timeline = <Map<String, Object?>>[];
          result['timeline'] = timeline;
          stage = 'bounded_single_room_background_audio';
          var everEffectiveAudio = false;
          while (run.elapsed.inSeconds < config.seconds) {
            if (await requestedStop()) break;
            await Future<void>.delayed(const Duration(seconds: 1));
            final state = activeScheduler.stateFor(
              a.candidate.roomId,
              a.candidate.anchorUid,
            );
            if ((state?.watchProgress.effectiveDuration.inMilliseconds ?? 0) >
                0) {
              everEffectiveAudio = true;
            }
            final pauseCategory = _pauseCategory(
              state?.watchPauseReason ?? state?.pauseReason,
            );
            if (run.elapsed.inSeconds % 5 == 0) {
              timeline.add({
                'elapsed_seconds': run.elapsed.inSeconds,
                'background_target':
                    aliases[activeScheduler.currentRoom?.roomId],
                'background_owns_watch': activeScheduler.ownsWatchReporter,
                'effective_seconds':
                    state?.watchProgress.effectiveDuration.inSeconds,
                'reported_seconds': state?.watchProgress.reportedSeconds,
                'official_tasks': _safeTasks(state?.tasks ?? []),
                'official_three_completed': state?.completed,
                'pause_category': pauseCategory,
                ..._roomDiagnostics(state),
              });
              result['status'] = 'single_room_running';
              record();
            }
            if (rejectedRequests != 0 ||
                result['report_write_failed'] == true) {
              throw const _Failure('request_scope_or_report_failure');
            }
            if (run.elapsed.inSeconds >= 180 &&
                !everEffectiveAudio &&
                pauseCategory?.startsWith('audio_') == true) {
              result['observation_end'] =
                  'audio_unavailable_no_effective_playback';
              result['single_room_audio_pause_category'] = pauseCategory;
              break;
            }
            if (state?.completed == true) {
              result['observation_end'] =
                  'official_three_tasks_complete_single_room';
              break;
            }
          }
          result['elapsed_seconds'] = run.elapsed.inSeconds;
          final state = activeScheduler.stateFor(
            a.candidate.roomId,
            a.candidate.anchorUid,
          );
          result['single_room_audio_effective_seconds'] =
              state?.watchProgress.effectiveDuration.inSeconds;
          result['single_room_audio_reported_seconds'] =
              state?.watchProgress.reportedSeconds;
          await activeScheduler.savePreferences(
            activeScheduler.preferences.copyWith(enabled: false),
          );
          activeScheduler.removeListener(targetListener);
          targetListener = null;
          await activeScheduler.shutdown().timeout(const Duration(seconds: 30));
          scheduler = null;
          stage = 'single_room_final_server_read';
          final reader = LiveInteractionService(
            roomId: a.candidate.roomId,
            anchorUid: a.candidate.anchorUid,
          );
          readers.add(reader);
          final after = await reader.loadFanTasks();
          final beforeWatch = a.before
              .where((task) => task.jumpType == 'watchLive')
              .single
              .currentCount;
          final watches = after.tasks
              .where((task) => task.jumpType == 'watchLive')
              .toList();
          final afterWatch = watches.length == 1
              ? watches.single.currentCount
              : null;
          if (beforeWatch != null &&
              afterWatch != null &&
              afterWatch < beforeWatch) {
            throw const _Failure('task_cycle_changed');
          }
          final features = _featureEvidence(
            a.before,
            after.tasks,
            writeStatistics['A'] ?? {},
          );
          result['after'] = {'A': _safeTasks(after.tasks)};
          result['interactive_feature_evidence'] = {'A': features};
          result['watch_feature_evidence'] = {
            'A': {
              'baseline_available': beforeWatch != null,
              'watch_task_after_confirmed': watches.length == 1,
              'official_round_gain_confirmed':
                  beforeWatch != null &&
                  afterWatch != null &&
                  afterWatch > beforeWatch,
            },
          };
          result['single_room_feature_results'] = {
            for (final kind in const ['like', 'sendDanmu'])
              kind: _map(features[kind])['exercised'] == true
                  ? _map(features[kind])['official_progress_increased'] == true
                        ? 'verified_official_progress'
                        : 'accepted_unconfirmed'
                  : 'not_run',
            'watchLive':
                beforeWatch != null &&
                    afterWatch != null &&
                    afterWatch > beforeWatch
                ? 'verified_official_round_increase'
                : 'not_observed',
          };
          result['accepted_requests_not_task_completion'] = writeStatistics;
          result['status'] = 'single_room_partial';
          result['acceptance_scope_result'] =
              'single_room_only_no_two_room_transfer_or_gui_acceptance';
          result['harness_completed'] = true;
        } else {
          if (config.fanEmotePoolSize > 1) {
            result['scope'] = 'two_selected_rooms_independent_interactions_single_watch_selected_fan_emoticon_pools';
          }
          final a = selected[0];
          final b = selected[1];
          frontRoomId = a.candidate.roomId;
          for (var i = 0; i < selected.length; ++i) {
            final room = selected[i].candidate.roomId;
            aliases[room] = i == 0 ? 'A' : 'B';
          }
          writeGuard = LiveSchedulerAcceptanceWriteGuard({
            for (var i = 0; i < selected.length; ++i)
              selected[i].candidate.roomId: LiveSchedulerAcceptanceRoomScope(
                anchorUid: selected[i].candidate.anchorUid,
                emoticon: selected[i].preferences.emoticons.first.unique,
                additionalEmoticons: selected[i].preferences.emoticons
                    .skip(1)
                    .map((expression) => expression.unique)
                    .toSet(),
                likeClicks: config.limitedInteractionBudget(
                  i == 0 ? 'A' : 'B',
                  'like',
                  _interactionBudget(selected[i].before, 'like'),
                ),
                danmakuCount: config.limitedInteractionBudget(
                  i == 0 ? 'A' : 'B',
                  'sendDanmu',
                  _interactionBudget(selected[i].before, 'sendDanmu'),
                ),
              ),
          });
          stage = 'explicit_two_room_authorization';
          MediaKit.ensureInitialized(libmpv: config.libraryPath);
          final activeScheduler = scheduler = LiveIntimacyScheduler.instance
            ..start();
          final bInitiallyMissingWatch = !b.before.any(
            (task) => task.jumpType == 'watchLive',
          );
          void stopBoundedLighting(String reason, List<LiveFanTask> tasks) {
            if (boundedLightingStop != null ||
                !explicitlyAuthorizedRooms.contains(b.candidate.roomId)) {
              return;
            }
            // Remove harness permission before the awaited private save. The
            // production revocation synchronously invalidates and stops the
            // session, so subsequent stages cannot spend a new daily budget.
            explicitlyAuthorizedRooms.remove(b.candidate.roomId);
            result['bounded_lighting_phase_stop'] = true;
            result['bounded_lighting_phase_stop_reason'] = reason;
            result['bounded_lighting_phase_official_tasks'] = _safeTasks(tasks);
            result['acceptance_scope_result'] =
                'partial_lighting_phase_initial_budget_only';
            boundedLightingStop = () async {
              try {
                final issue = await activeScheduler
                    .authorizeRoom(b.preferences, false)
                    .timeout(const Duration(seconds: 30));
                if (issue != null ||
                    activeScheduler.preferences
                            .roomFor(b.candidate.roomId, b.candidate.anchorUid)
                            ?.authorized ==
                        true ||
                    Pref.liveIntimacyPreferencesFor(authorizedAccount!.mid)
                            .roomFor(b.candidate.roomId, b.candidate.anchorUid)
                            ?.authorized ==
                        true) {
                  boundedLightingStopFailed = true;
                }
              } on Object {
                boundedLightingStopFailed = true;
              }
              result['bounded_lighting_phase_authorization_revoked'] =
                  !boundedLightingStopFailed;
            }();
          }

          inspectBoundedLighting = () {
            if (!bInitiallyMissingWatch ||
                boundedLightingStop != null ||
                !explicitlyAuthorizedRooms.contains(b.candidate.roomId)) {
              return;
            }
            final tasks =
                activeScheduler
                    .stateFor(b.candidate.roomId, b.candidate.anchorUid)
                    ?.tasks ??
                const <LiveFanTask>[];
            for (final old in b.before.where((task) => task.completionOnly)) {
              final current = tasks
                  .where((task) => task.jumpType == old.jumpType)
                  .toList();
              if (current.length == 1 && !current.single.completionOnly) {
                result['new_daily_phase_observed'] =
                    current.single.dailyRewardProgress;
                stopBoundedLighting(
                  current.single.dailyRewardProgress
                      ? 'new_daily_phase_observed'
                      : 'new_nonlighting_phase_observed',
                  tasks,
                );
                return;
              }
            }
            final guard = writeGuard!;
            final bothInitialBudgetsSpent =
                guard.remainingLikes(b.candidate.roomId) == 0 &&
                guard.remainingDanmaku(b.candidate.roomId) == 0;
            if (bothInitialBudgetsSpent) {
              for (final type in const ['like', 'sendDanmu']) {
                final current = tasks
                    .where((task) => task.jumpType == type)
                    .toList();
                if (current.length == 1 && current.single.completed != true) {
                  stopBoundedLighting(
                    'both_initial_lighting_budgets_exhausted_official_sync_pending',
                    tasks,
                  );
                  return;
                }
              }
            }
          };
          targetListener = () {
            activateInteractions();
            inspectBoundedLighting?.call();
            observeRoomReasons();
          };
          activeScheduler.addListener(targetListener);
          for (final room in selected) {
            activeScheduler.updateForeground(
              roomId: room.candidate.roomId,
              anchorUid: room.candidate.anchorUid,
            );
            await activeScheduler.saveRoomPreferences(room.preferences);
            final issue = await activeScheduler.authorizeRoom(
              room.preferences,
              true,
            );
            if (issue != null) {
              throw const _Failure('explicit_room_authorization_rejected');
            }
            explicitlyAuthorizedRooms.add(room.candidate.roomId);
          }
          if (activeScheduler.preferences.enabled ||
              activeScheduler.preferences.rooms.length != 2 ||
              activeScheduler.preferences.rooms.any(
                (room) => !room.authorized,
              )) {
            throw const _Failure('master_off_authorization_unconfirmed');
          }
          result['master_off_explicit_grants_confirmed'] = true;
          stage = 'native_foreground_a';
          final play = await LiveHttp.liveRoomInfo(
            roomId: a.candidate.roomId,
            qn: 80,
            onlyAudio: false,
          );
          if (play is! Success ||
              play.dataOrNull == null ||
              play.dataOrNull!.roomId != a.candidate.roomId ||
              play.dataOrNull!.uid != a.candidate.anchorUid ||
              play.dataOrNull!.liveStatus != 1) {
            throw const _Failure('foreground_play_info_unconfirmed');
          }
          String? media;
          for (final stream
              in play.dataOrNull!.playurlInfo?.playurl?.stream ?? []) {
            for (final format in stream.format) {
              for (final codec in format.codec) {
                if (codec.urlInfo.isNotEmpty) {
                  final location = codec.urlInfo.first;
                  media = '${location.host}${codec.baseUrl}${location.extra}';
                  break;
                }
              }
              if (media != null) break;
            }
            if (media != null) break;
          }
          if (media == null) {
            throw const _Failure('foreground_media_unavailable');
          }
          final uri = Uri.tryParse(media);
          if (uri == null ||
              !const ['https', 'http'].contains(uri.scheme) ||
              uri.userInfo.isNotEmpty) {
            throw const _Failure('foreground_media_unavailable');
          }
          frontPlayer = await Player.create(
            configuration: const PlayerConfiguration(
              options: {
                'vid': 'auto',
                'volume': '0',
                'mute': 'yes',
                'ao': 'null',
                'vo': 'null',
                'msg-level': 'all=no',
                'terminal': 'no',
              },
            ),
          );
          final native = frontPlayer
            ..setMediaHeader(
              userAgent: BrowserUa.pc,
              referer: 'https://live.bilibili.com/${a.candidate.roomId}',
            );
          await native.setVolume(0);
          subscriptions.add(
            native.stream.error.listen((error) {
              final elapsed = requestClock.elapsedMilliseconds;
              nativeErrorMonitor.error(elapsed);
              // Bound report size even if a damaged stream repeats one error.
              if (nativeErrorEvents.length < 32) {
                nativeErrorEvents.add({
                  ...liveSchedulerNativeErrorCategory(error),
                  'elapsed_milliseconds': elapsed,
                  'native_playing': native.state.playing,
                  'native_buffering': native.state.buffering,
                  'native_completed': native.state.completed,
                  'position_milliseconds': native.state.position.inMilliseconds,
                });
              }
            }),
          );
          await native.open(Media(media), play: false);
          if (double.tryParse(native.getProperty('volume')) != 0 ||
              native.getProperty('mute') != 'yes') {
            throw const _Failure('foreground_silent_output_unconfirmed');
          }
          result['foreground_silent_output_confirmed'] = true;
          final foregroundSession = foreground = LiveViewingSession(
            roomId: a.candidate.roomId,
            anchorUid: a.candidate.anchorUid,
            areaId: a.candidate.areaId,
            parentAreaId: a.candidate.parentAreaId,
          );
          final playbackClock = Stopwatch()..start();
          Duration? lastPosition;
          Duration? lastClock;
          bool frontValid = false;
          frontSamples = Timer.periodic(const Duration(seconds: 1), (_) {
            final position = native.state.position;
            final now = playbackClock.elapsed;
            final advance =
                lastPosition != null &&
                position > lastPosition! &&
                lastClock != null &&
                now - lastClock! <= const Duration(seconds: 3);
            lastPosition = position;
            lastClock = now;
            frontValid =
                native.state.playing &&
                !native.state.buffering &&
                !native.state.completed &&
                advance &&
                (native.state.audioParams.sampleRate ?? 0) > 0 &&
                (native.state.videoParams.w ?? 0) > 0;
            nativeErrorMonitor.sample(
              elapsedMilliseconds: requestClock.elapsedMilliseconds,
              effectivePlayback: frontValid,
              userPaused: frontUserPaused,
            );
            foregroundSession.updatePlayback(
              playing: frontValid,
              buffering: native.state.buffering || !frontValid,
              live: true,
              position: native.state.position,
            );
          });
          writesEnabled = true;
          await native.play();
          final run = Stopwatch()..start();
          result['run_started_utc'] = DateTime.now().toUtc().toIso8601String();
          activeScheduler.updateForeground(
            roomId: a.candidate.roomId,
            anchorUid: a.candidate.anchorUid,
          );
          await activeScheduler.savePreferences(
            activeScheduler.preferences.copyWith(enabled: true),
          );
          final timeline = <Map<String, Object?>>[];
          result['timeline'] = timeline;
          var paused = false;
          var resumed = false;
          var preempted = false;
          int? preemptedAt;
          var restoredPriority = false;
          var aPriorityObserved = false;
          var bPreemptionObserved = false;
          var pauseContinuedObserved = false;
          var nativeIsolationObserved = false;
          var foregroundDisabledObserved = false;
          var automaticTransferObserved = false;
          var unfinishedARunObserved = false;
          var unfinishedAAfterRestoreObserved = false;
          var completedATransferPending = false;
          var bAtACompletion = 0;
          final independentBInteractionKinds = <String>{};
          var aAtPause = 0;
          var foregroundCounterAtClaim =
              foregroundSession.watch.status.value.reportedSeconds;
          stage = 'bounded_production_scheduler_run';
          while (run.elapsed.inSeconds < config.seconds) {
            if (await requestedStop()) break;
            await Future<void>.delayed(const Duration(seconds: 1));
            final elapsed = run.elapsed.inSeconds;
            final stateA = activeScheduler.stateFor(
              a.candidate.roomId,
              a.candidate.anchorUid,
            );
            final stateB = activeScheduler.stateFor(
              b.candidate.roomId,
              b.candidate.anchorUid,
            );
            final target = aliases[activeScheduler.currentRoom?.roomId];
            final interactionTarget =
                aliases[activeScheduler.currentInteractionRoom?.roomId];
            final owner = activeScheduler.ownsWatchReporter;
            final aWatchComplete =
                stateA?.officialFresh == true &&
                stateA?.watchProgress.periodConfirmed == true &&
                stateA?.officialCycle.confirmedFor(const ['watchLive']) ==
                    true &&
                liveIntimacyTaskCompleted(stateA?.tasks ?? [], 'watchLive');
            if (target == 'A' && owner && !aWatchComplete) {
              unfinishedARunObserved = true;
              if (restoredPriority) unfinishedAAfterRestoreObserved = true;
            }
            if (target == 'A' && owner && !preempted) {
              for (final kind in const ['like', 'sendDanmu']) {
                final evidence = _map(
                  _featureEvidence(
                    b.before,
                    stateB?.tasks ?? [],
                    writeStatistics['B'] ?? {},
                  )[kind],
                );
                final acceptedKind = kind == 'like'
                    ? 'accepted_like_clicks'
                    : 'accepted_emote_requests';
                if (evidence['official_progress_increased'] == true &&
                    acceptedEvents.any(
                      (event) =>
                          event['room'] == 'B' &&
                          event['kind'] == acceptedKind &&
                          event['watch_room'] == 'A' &&
                          event['watch_owner'] == true,
                    )) {
                  independentBInteractionKinds.add(kind);
                }
              }
            }
            if (target == 'A' &&
                owner &&
                (stateA?.watchProgress.effectiveDuration.inSeconds ?? 0) >= 3) {
              aPriorityObserved = true;
            }
            if (!paused && elapsed >= 20 && aPriorityObserved) {
              frontUserPaused = true;
              await native.pause();
              aAtPause = stateA!.watchProgress.effectiveDuration.inSeconds;
              paused = true;
            }
            if (paused && !resumed && elapsed >= 45) {
              pauseContinuedObserved =
                  target == 'A' &&
                  (stateA?.watchProgress.effectiveDuration.inSeconds ?? 0) >=
                      aAtPause + 10 &&
                  !native.state.playing;
              frontUserPaused = false;
              await native.play();
              resumed = true;
            }
            // Leave enough time for the global account cooldown to serve both
            // rooms before exercising the separate watch preemption scenario.
            if (!preempted &&
                (resumed || config.keepBWatchPriority) &&
                elapsed >= (config.keepBWatchPriority ? 180 : 65) &&
                (config.keepBWatchPriority ||
                    independentBInteractionKinds.length == 2 ||
                    elapsed >= 180)) {
              foregroundCounterAtClaim =
                  foregroundSession.watch.status.value.reportedSeconds;
              activeScheduler.updateForeground(
                roomId: b.candidate.roomId,
                anchorUid: b.candidate.anchorUid,
              );
              preempted = true;
              preemptedAt = elapsed;
            }
            if (preempted &&
                target == 'B' &&
                owner &&
                (stateB?.watchProgress.effectiveDuration.inSeconds ?? 0) >= 3) {
              bPreemptionObserved = true;
              nativeIsolationObserved =
                  native.state.playlist.medias.any(
                    (item) => item.uri == media,
                  ) &&
                  frontValid &&
                  native.state.playing;
              foregroundDisabledObserved =
                  !const [
                    LiveWatchState.connecting,
                    LiveWatchState.reporting,
                  ].contains(foregroundSession.watch.status.value.state) &&
                  foregroundSession.watch.status.value.reportedSeconds ==
                      foregroundCounterAtClaim;
            }
            if (!restoredPriority &&
                !config.keepBWatchPriority &&
                preemptedAt != null &&
                elapsed >= preemptedAt + 60 &&
                bPreemptionObserved) {
              activeScheduler.updateForeground(
                roomId: a.candidate.roomId,
                anchorUid: a.candidate.anchorUid,
              );
              restoredPriority = true;
            }
            final automaticStage =
                !preempted && unfinishedARunObserved ||
                restoredPriority && unfinishedAAfterRestoreObserved;
            if (automaticStage &&
                aWatchComplete &&
                !completedATransferPending) {
              completedATransferPending = true;
              bAtACompletion =
                  stateB?.watchProgress.effectiveDuration.inSeconds ?? 0;
            }
            // A cleared target during closing is not a successful transfer.
            // Require new effective B playback after official A watch completion,
            // without a B route hint causing that transfer.
            if (automaticStage &&
                completedATransferPending &&
                target == 'B' &&
                owner &&
                (stateB?.watchProgress.effectiveDuration.inSeconds ?? 0) >=
                    bAtACompletion + 3) {
              automaticTransferObserved = true;
              result['automatic_completion_transfer'] =
                  'official_watch_complete_then_effective_b';
            }
            if (elapsed % 5 == 0) {
              timeline.add({
                'elapsed_seconds': elapsed,
                'background_target': target,
                'interaction_target': interactionTarget,
                'background_owns_watch': owner,
                'foreground_native_playing': native.state.playing,
                'foreground_native_valid_av': frontValid,
                'foreground_native_error_state': nativeErrorMonitor.state,
                'foreground_native_error_count':
                    nativeErrorMonitor.observedErrors,
                'foreground_native_effective_av_loss_observed':
                    nativeErrorMonitor.effectiveAvLossObserved,
                'foreground_watch_state':
                    foregroundSession.watch.status.value.state.name,
                'foreground_reported_seconds':
                    foregroundSession.watch.status.value.reportedSeconds,
                'A': {
                  'effective_seconds':
                      stateA?.watchProgress.effectiveDuration.inSeconds,
                  'reported_seconds': stateA?.watchProgress.reportedSeconds,
                  'official_tasks': _safeTasks(stateA?.tasks ?? []),
                  'official_three_completed': stateA?.completed,
                  'paused_reason_present': stateA?.pauseReason != null,
                  'interaction_advancing': stateA?.canAdvanceInteraction,
                  'interaction_paused': stateA?.interactionPauseReason != null,
                  'watch_paused': stateA?.watchPauseReason != null,
                  ..._roomDiagnostics(stateA),
                  'accepted_requests': Map<String, int>.from(
                    writeStatistics['A'] ?? {},
                  ),
                },
                'B': {
                  'effective_seconds':
                      stateB?.watchProgress.effectiveDuration.inSeconds,
                  'reported_seconds': stateB?.watchProgress.reportedSeconds,
                  'official_tasks': _safeTasks(stateB?.tasks ?? []),
                  'official_three_completed': stateB?.completed,
                  'paused_reason_present': stateB?.pauseReason != null,
                  'interaction_advancing': stateB?.canAdvanceInteraction,
                  'interaction_paused': stateB?.interactionPauseReason != null,
                  'watch_paused': stateB?.watchPauseReason != null,
                  ..._roomDiagnostics(stateB),
                  'accepted_requests': Map<String, int>.from(
                    writeStatistics['B'] ?? {},
                  ),
                },
              });
              result['status'] = 'running';
              record();
            }
            if (rejectedRequests != 0) {
              throw const _Failure('request_scope_failure');
            }
            if (result['report_write_failed'] == true) {
              throw const _Failure('sanitized_report_write_failed');
            }
            final originalAWatch = a.before
                .where((task) => task.jumpType == 'watchLive')
                .single
                .currentCount;
            final currentAWatch =
                stateA?.tasks
                    .where((task) => task.jumpType == 'watchLive')
                    .toList() ??
                const <LiveFanTask>[];
            final currentAWatchCount = currentAWatch.length == 1
                ? currentAWatch.single.currentCount
                : null;
            if (restoredPriority &&
                resumed &&
                native.state.playing &&
                frontValid &&
                result['bounded_lighting_phase_authorization_revoked'] ==
                    true &&
                stateA?.completed == true &&
                originalAWatch != null &&
                currentAWatchCount != null &&
                currentAWatchCount > originalAWatch) {
              result['observation_end'] =
                  'early_bounded_partial_evidence_collected';
              result['early_stop_evidence'] = 'A_official_watch_gain_three_complete_B_initial_phase_stopped_front_resumed';
              break;
            }
          }
          result['elapsed_seconds'] = run.elapsed.inSeconds;
          result['foreground_native_error_state'] = nativeErrorMonitor.state;
          result['foreground_native_error_count'] =
              nativeErrorMonitor.observedErrors;
          result['priority_a_observed'] = aPriorityObserved;
          result['frontend_pause_background_continued'] =
              pauseContinuedObserved;
          result['priority_b_preemption_observed'] = bPreemptionObserved;
          result['native_front_a_media_unchanged_and_playing_while_b'] =
              nativeIsolationObserved;
          result['foreground_watch_disabled_while_b'] =
              foregroundDisabledObserved;
          result['automatic_completion_transfer_observed'] =
              automaticTransferObserved;
          result['dual_queue_interactions_during_other_room_watch'] =
              independentBInteractionKinds.length == 2
              ? 'both_b_interactions_officially_increased_before_any_b_watch_hint'
              : independentBInteractionKinds.isNotEmpty
              ? 'one_b_interaction_officially_increased_before_any_b_watch_hint'
              : 'not_observed';
          result['independent_b_interaction_kinds'] =
              independentBInteractionKinds.toList()..sort();
          await boundedLightingStop;
          stage = 'final_server_read';
          final after = <String, Map<String, Object?>>{};
          final featureEvidence = <String, Map<String, Object?>>{};
          final watchEvidence = <String, Map<String, Object?>>{};
          var watchIncremented = 0;
          for (var i = 0; i < selected.length; ++i) {
            final room = selected[i];
            final reader = LiveInteractionService(
              roomId: room.candidate.roomId,
              anchorUid: room.candidate.anchorUid,
            );
            readers.add(reader);
            final tasks = await reader.loadFanTasks();
            final alias = i == 0 ? 'A' : 'B';
            if (alias == 'B' &&
                bInitiallyMissingWatch &&
                room.before.any(
                  (old) =>
                      old.completionOnly &&
                      tasks.tasks.any(
                        (current) =>
                            current.jumpType == old.jumpType &&
                            current.dailyRewardProgress &&
                            !current.completionOnly,
                      ),
                )) {
              // This observation establishes a phase transition only. It does
              // not establish completion or any earned rounds in the new phase.
              result['new_daily_phase_observed'] = true;
            }
            after[alias] = _safeTasks(tasks.tasks);
            featureEvidence[alias] = _featureEvidence(
              room.before,
              tasks.tasks,
              writeStatistics[alias] ?? {},
            );
            final beforeWatches = room.before
                .where((task) => task.jumpType == 'watchLive')
                .toList();
            final afterWatches = tasks.tasks
                .where((task) => task.jumpType == 'watchLive')
                .toList();
            final beforeCount = beforeWatches.length == 1
                ? beforeWatches.single.currentCount
                : null;
            final afterCount = afterWatches.length == 1
                ? afterWatches.single.currentCount
                : null;
            final roundGain =
                beforeCount != null &&
                afterCount != null &&
                afterCount > beforeCount;
            watchEvidence[alias] = {
              'missing_watch_task_before': beforeWatches.isEmpty,
              'baseline_available': beforeCount != null,
              'watch_task_after_confirmed': afterWatches.length == 1,
              'watch_task_appeared_after':
                  beforeWatches.isEmpty && afterWatches.length == 1,
              'official_round_gain_confirmed': roundGain,
            };
            if (roundGain) {
              ++watchIncremented;
            }
            if (beforeCount != null &&
                afterCount != null &&
                afterCount < beforeCount) {
              throw const _Failure('task_cycle_changed');
            }
          }
          result['after'] = after;
          result['interactive_feature_evidence'] = featureEvidence;
          result['watch_feature_evidence'] = watchEvidence;
          const featureKinds = ['like', 'sendDanmu'];
          final everyInteractiveConfirmed = featureEvidence.values.every(
            (evidence) => featureKinds.every(
              (kind) => _map(evidence[kind])['official_confirmed'] == true,
            ),
          );
          final eachInteractiveExercised = featureKinds.every(
            (kind) => featureEvidence.values.any(
              (evidence) =>
                  _map(evidence[kind])['exercised'] == true &&
                  _map(evidence[kind])['official_progress_increased'] == true,
            ),
          );
          result['each_interactive_feature_exercised_and_officially_increased'] =
              eachInteractiveExercised;
          result['two_room_watch_settlement'] = watchIncremented == 2
              ? 'both_official_rounds_increased'
              : watchIncremented == 1
              ? 'one_official_round_increased_other_not_observed'
              : 'not_observed';
          result['accepted_requests_not_task_completion'] = writeStatistics;
          await activeScheduler.savePreferences(
            activeScheduler.preferences.copyWith(enabled: false),
          );
          activeScheduler.removeListener(targetListener);
          targetListener = null;
          await activeScheduler.shutdown().timeout(const Duration(seconds: 30));
          scheduler = null;
          // The foreground decoder keeps running. With no background owner it
          // must be permitted to return to normal actual-playback watch reporting.
          final restoreDeadline = DateTime.now().add(
            const Duration(seconds: 20),
          );
          while (result['operator_stop_marker_observed'] != true &&
              DateTime.now().isBefore(restoreDeadline) &&
              foregroundSession.watch.status.value.state !=
                  LiveWatchState.reporting) {
            await Future<void>.delayed(const Duration(seconds: 1));
          }
          result['foreground_watch_restored_after_stop'] =
              foregroundSession.watch.status.value.state ==
                  LiveWatchState.reporting &&
              !LiveAutomationCoordinator.instance.backgroundWatchClaimed &&
              frontValid;
          result['status'] =
              aPriorityObserved &&
                  pauseContinuedObserved &&
                  bPreemptionObserved &&
                  nativeIsolationObserved &&
                  foregroundDisabledObserved &&
                  automaticTransferObserved &&
                  watchIncremented == 2 &&
                  everyInteractiveConfirmed &&
                  eachInteractiveExercised &&
                  independentBInteractionKinds.length == 2 &&
                  !nativeErrorMonitor.effectiveAvLossObserved &&
                  result['bounded_lighting_phase_stop'] != true &&
                  result['foreground_watch_restored_after_stop'] == true
              ? 'pass'
              : 'inconclusive';
          result['harness_completed'] = true;
        }
      } catch (error) {
        result['status'] = 'failed';
        result['failure_stage'] = stage;
        result['error_type'] = error.runtimeType.toString();
        if (error is _Failure) result['failure_category'] = error.category;
        if (error is DioException) {
          result['http_status'] = error.response?.statusCode;
          result['response_kind'] = error.response?.data is Map
              ? 'map'
              : 'other';
          final code = _integer(_map(error.response?.data)['code']);
          if (code != null) result['api_code'] = code;
        }
      } finally {
        frontSamples?.cancel();
        inspectBoundedLighting = null;
        if (targetListener != null) scheduler?.removeListener(targetListener);
        try {
          await scheduler?.shutdown().timeout(const Duration(seconds: 30));
        } on Object {
          result['scheduler_cleanup_failed'] = true;
        }
        try {
          await boundedLightingStop;
        } on Object {
          boundedLightingStopFailed = true;
        }
        if (boundedLightingStopFailed) {
          result['bounded_lighting_stop_failed'] = true;
        }
        writesEnabled = false;
        try {
          foreground?.dispose();
        } on Object {
          result['foreground_dispose_failed'] = true;
        }
        try {
          await foreground?.watch.settled.timeout(const Duration(seconds: 20));
        } on Object {
          result['foreground_cleanup_failed'] = true;
        }
        for (final subscription in subscriptions) {
          try {
            await subscription.cancel();
          } on Object {
            result['subscription_cleanup_failed'] = true;
          }
        }
        try {
          await frontPlayer?.dispose().timeout(const Duration(seconds: 20));
        } on Object {
          result['native_cleanup_failed'] = true;
        }
        try {
          discovery?.cancel();
        } on Object {
          result['discovery_cleanup_failed'] = true;
        }
        for (final reader in readers) {
          try {
            reader.dispose();
          } on Object {
            result['reader_cleanup_failed'] = true;
          }
        }
        try {
          if (clientStarted) Request.dio.close(force: true);
        } on Object {
          result['client_cleanup_failed'] = true;
        }
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
        result['scope_rejected_requests'] = rejectedRequests;
        result['foreground_native_error_state'] = nativeErrorMonitor.state;
        result['foreground_native_error_count'] =
            nativeErrorMonitor.observedErrors;
        result['foreground_native_effective_av_loss_observed'] =
            nativeErrorMonitor.effectiveAvLossObserved;
        result['ended_utc'] = DateTime.now().toUtc().toIso8601String();
        result['ended_client_calendar_utc_plus_8'] = DateTime.now()
            .toUtc()
            .add(const Duration(hours: 8))
            .toIso8601String()
            .substring(0, 10);
        result['accepted_requests_not_task_completion'] = writeStatistics;
        if (result['private_storage_removed'] != true ||
            result['report_write_failed'] == true ||
            const [
              'scheduler_cleanup_failed',
              'bounded_lighting_stop_failed',
              'foreground_cleanup_failed',
              'native_cleanup_failed',
              'foreground_dispose_failed',
              'subscription_cleanup_failed',
              'discovery_cleanup_failed',
              'reader_cleanup_failed',
              'client_cleanup_failed',
              'storage_close_failed',
              'private_storage_cleanup_failed',
            ].any((key) => result[key] == true)) {
          result['status'] = 'failed';
          result['failure_stage'] = 'cleanup';
        }
        record();
        print(jsonEncode(result));
      }
      expect(
        result['harness_completed'],
        true,
        reason: 'Manual scheduler harness did not complete; inspect the sanitized report.',
      );
      expect(
        result['status'],
        isNot('failed'),
        reason: 'Bounded execution is separate from official two-room settlement or GUI acceptance.',
      );
    },
    skip: !const bool.fromEnvironment('LIVE_SCHEDULER_ACCOUNT_ACCEPTANCE'),
    timeout: const Timeout(Duration(minutes: 25)),
  );
}
