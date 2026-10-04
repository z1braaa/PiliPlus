// Manual read-only diagnosis, skipped without both explicit runtime and
// compile-time opt-in. Original accounts/settings remain unopened and unchanged.
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/services/live_intimacy_discovery.dart';
import 'package:PiliPlus/services/live_interaction_service.dart';
import 'package:PiliPlus/models_new/live/interactions/live_interaction_parser.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/account_manager/account_mgr.dart';
import 'package:PiliPlus/utils/live_intimacy_preferences.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import 'live_room_profile_gate.dart';

class _QuietAccountManager extends AccountManager {
  @override
  void onError(DioException err, ErrorInterceptorHandler handler) =>
      handler.next(err);
}

Map<String, Object?> _task(LiveFanTask task) => {
  'title': task.name,
  'description': task.description,
  'jump_type': task.jumpType,
  'progress_text': task.progressText,
  'completed': task.completed,
  'current': task.currentCount,
  'target': task.targetCount,
  'actions_per_progress': task.actionsPerProgress,
  'remaining': task.remainingCount,
  'completion_only': task.completionOnly,
  'daily_reward_progress': task.dailyRewardProgress,
  'has_explicit_period': task.period.isNotEmpty,
};

void main() {
  test(
    'explicitly authorized read-only room qualification and task profile',
    () async {
      final result = <String, dynamic>{
        'schema_version': 1,
        'status': 'starting',
        'scope': 'read_only_no_media_no_writes',
      };
      LiveRoomProfileConfig? config;
      LiveRoomProfileRequestGate? gate;
      Directory? private;
      var stage = 'explicit_authorization';
      var clientStarted = false;
      final panelPages = <Map<String, Object?>>[];
      result['medal_panel_pages'] = panelPages;
      final panelScanIds = <String, Set<int>>{};
      final panelScanNumber = <String, int>{};
      final panelIdFirstPage = <String, Map<int, int>>{};
      try {
        config = LiveRoomProfileConfig.fromEnvironment(Platform.environment);
        gate = LiveRoomProfileRequestGate(config.rooms);
        stage = 'private_account_copy';
        private = await Directory.systemTemp.createTemp('pili-room-profile-');
        if ((await Process.run('/bin/chmod', ['700', private.path])).exitCode !=
            0) {
          throw StateError('private_permissions_failed');
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
            throw StateError('private_permissions_failed');
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
        if (account == null) throw StateError('selected_main_account_missing');
        Accounts.accountMode[AccountType.main.index] = account;
        // Pure profile reads do not start reports or require a recording
        // account. No privacy preference or heartbeat identity is changed.
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
              if (!gate!.allows(
                options.uri,
                options.method,
                options.queryParameters,
              )) {
                handler.reject(
                  DioException.requestCancelled(
                    requestOptions: options,
                    reason: 'read_only_profile_scope_rejected',
                  ),
                );
              } else {
                handler.next(options);
              }
            },
            onResponse: (response, handler) {
              final request = response.requestOptions;
              if (request.uri.path == LiveIntimacyDiscovery.medalsPath) {
                final envelope = liveMap(response.data);
                final data = liveMap(envelope['data']);
                final info = liveMap(data['page_info']);
                final room = liveInt(request.queryParameters['room_id']);
                final anchor = liveInt(request.queryParameters['target_id']);
                final page = liveInt(request.queryParameters['page']);
                final key = '$room:$anchor';
                if (page == 1 || !panelScanIds.containsKey(key)) {
                  panelScanIds[key] = <int>{};
                  panelScanNumber[key] = (panelScanNumber[key] ?? 0) + 1;
                  panelIdFirstPage[key] = <int, int>{};
                }
                final raw = [
                  ...liveMaps(data['list']),
                  ...liveMaps(data['special_list']),
                ];
                final ids = raw
                    .map((item) => liveInt(liveMap(item['medal'])['medal_id']))
                    .whereType<int>()
                    .where((id) => id > 0)
                    .toSet();
                final prior = panelScanIds[key]!;
                final overlap = ids.intersection(prior).length;
                final overlapIds = ids.intersection(prior);
                final firstPages = panelIdFirstPage[key]!;
                prior.addAll(ids);
                panelPages.add({
                  'observed_utc': DateTime.now().toUtc().toIso8601String(),
                  'stage': stage,
                  'room_id': room,
                  'scan': panelScanNumber[key],
                  'requested_page': page,
                  'server_code': liveInt(envelope['code']),
                  'list_count': data['list'] is List
                      ? (data['list'] as List).length
                      : null,
                  'special_list_count': data['special_list'] is List
                      ? (data['special_list'] as List).length
                      : null,
                  'declared_total_number': liveInt(data['total_number']),
                  'page_unique_medal_count': ids.length,
                  'page_duplicates_or_invalid_identity_count':
                      raw.length - ids.length,
                  'overlap_with_prior_pages': overlap,
                  'overlap_prior_page_numbers': overlapIds
                      .map((id) => firstPages[id])
                      .whereType<int>()
                      .toSet()
                      .toList(),
                  'overlap_recently_lighted_sample': raw.any(
                    (item) =>
                        liveInt(liveMap(item['medal'])['target_id']) ==
                            345564775 &&
                        overlapIds.contains(
                          liveInt(liveMap(item['medal'])['medal_id']),
                        ),
                  ),
                  'scan_unique_medal_count': prior.length,
                  'requested_anchor_medal_present': raw.any(
                    (item) =>
                        liveInt(liveMap(item['medal'])['target_id']) == anchor,
                  ),
                  'has_more': liveBool(info['has_more']),
                  'current_page': liveInt(info['current_page']),
                  'informational_total_page': liveInt(info['total_page']),
                  'next_page': liveInt(info['next_page']),
                  'next_light_status': liveInt(info['next_light_status']),
                });
                for (final id in ids) {
                  firstPages.putIfAbsent(id, () => page ?? 0);
                }
              }
              handler.next(response);
            },
          ),
        );
        final ownedAnchors = <int>{};
        Future<Map<String, dynamic>> read(
          String path,
          Map<String, dynamic> query,
        ) async {
          final origin = path.startsWith('/x/')
              ? 'https://api.bilibili.com'
              : 'https://api.live.bilibili.com';
          final response = await Request.dio.get<dynamic>(
            origin + path,
            queryParameters: query,
            options: Options(
              extra: {'account': account},
              headers: {'user-agent': BrowserUa.pc},
              followRedirects: false,
            ),
          );
          final data = liveMap(response.data);
          if (path == LiveIntimacyDiscovery.medalsPath && data['code'] == 0) {
            for (final medal in LiveInteractionParser.medals(
              liveMap(data['data']),
            )) {
              if (medal.targetUid > 0 && medal.level > 0) {
                ownedAnchors.add(medal.targetUid);
              }
            }
          }
          return data;
        }

        stage = 'login_confirmation';
        final nav = await read('/x/web-interface/nav', {});
        final user = liveMap(nav['data']);
        if (nav['code'] != 0 ||
            user['isLogin'] != true ||
            user['mid'] != account.mid) {
          throw StateError('selected_login_unconfirmed');
        }
        result['account_confirmed'] = true;
        result['account_safety'] = {
          'stored_non_anonymous_account_count': Accounts.account.values
              .where((value) => value.mid > 0)
              .length,
          'anonymous_selected': Accounts.main.mid == 0,
          'anonymous_task_operations_possible': false,
          'background_scheduler_started': false,
          'actual_anonymous_ui_switch': 'not_run',
        };
        final profiles = <Map<String, Object?>>[];
        result['rooms'] = profiles;
        LiveIntimacyRoomPreferences? reference;
        for (final requested in config.rooms) {
          final profile = <String, Object?>{'requested_room': requested};
          profiles.add(profile);
          LiveInteractionService? service;
          try {
            stage = 'room_identity';
            final initial = await read(LiveIntimacyDiscovery.roomPath, {
              'room_id': requested,
            });
            final info = liveMap(liveMap(initial['data'])['room_info']);
            final roomId = liveInt(info['room_id']);
            final anchor = liveInt(info['uid']);
            if (initial['code'] != 0 || roomId == null || anchor == null) {
              throw StateError('room_identity_unconfirmed');
            }
            gate.registerRoom(
              requested: requested,
              canonical: roomId,
              anchor: anchor,
            );
            profile['canonical_room'] = roomId;
            profile['public_anchor_uid'] = anchor;
            stage = 'qualified_medal_inventory';
            final discovery = LiveIntimacyDiscovery.testing(read: read);
            final candidate = await discovery.recheck(
              LiveIntimacyRoomPreferences(roomId: roomId, anchorUid: anchor),
            );
            reference ??= LiveIntimacyRoomPreferences(
              roomId: roomId,
              anchorUid: anchor,
              authorized: true,
            );
            profile['qualification'] = {
              'followed': candidate.followed,
              'medal_owned': candidate.medalOwned,
              'medal_level': candidate.medalLevel,
              'live': candidate.live,
            };
            service = LiveInteractionService(
              roomId: roomId,
              anchorUid: anchor,
            );
            stage = 'task_profile';
            final snapshot = await service.loadFanTasks();
            profile['tasks'] = {
              'joined': snapshot.joined,
              'medal_lighted': snapshot.medalLighted,
              'items': snapshot.tasks.map(_task).toList(),
            };
            stage = 'room_emoticon_profile';
            final options = await service.loadTaskEmoticons();
            final club = options.where((option) => option.isFanClub).toList();
            profile['emoticons'] = {
              'club_count': club.length,
              'club_available_count': club
                  .where((option) => option.available)
                  .length,
              'first_club': club.isEmpty
                  ? null
                  : {
                      'label': club.first.label,
                      'unique': club.first.unique,
                      'available': club.first.available,
                    },
              'first_five_club': club
                  .take(5)
                  .map(
                    (option) => {
                      'label': option.label,
                      'unique': option.unique,
                      'available': option.available,
                    },
                  )
                  .toList(),
            };
            profile['status'] = 'profiled';
          } catch (error) {
            profile['status'] = 'failed';
            profile['failure_stage'] = stage;
            profile['error_type'] = error.runtimeType.toString();
            if (error is LiveInteractionException) {
              profile['reason'] = error.message;
            }
          } finally {
            service?.dispose();
          }
        }
        if (reference != null) {
          stage = 'eligible_live_sample_inventory';
          try {
            final discovery = LiveIntimacyDiscovery.testing(read: read);
            // Target qualification may end on its first positive page. Warm
            // one terminal inventory before enumerating every observed anchor;
            // the following call reuses that same identity/TTL-bound snapshot.
            await discovery.discover([reference]);
            final candidates = await discovery.discover([
              reference,
              for (final anchor in ownedAnchors)
                if (anchor != reference.anchorUid)
                  LiveIntimacyRoomPreferences(
                    roomId: reference.roomId,
                    anchorUid: anchor,
                    authorized: true,
                  ),
            ]);
            final eligible = candidates
                .where((candidate) => candidate.eligible)
                .toList();
            result['sample_inventory'] = {
              'status': discovery.complete
                  ? 'complete'
                  : 'partial_positive_inventory_missing_anchors_unknown',
              'medal_inventory_complete': discovery.complete,
              'counts_are_known_positive_lower_bounds': !discovery.complete,
              'owned_medal_anchor_count': candidates
                  .where((candidate) => candidate.medalOwned)
                  .length,
              'followed_medal_anchor_count': candidates
                  .where(
                    (candidate) => candidate.medalOwned && candidate.followed,
                  )
                  .length,
              'eligible_live_medal_followed_count': eligible.length,
              'first_six_public_samples': eligible
                  .take(6)
                  .map(
                    (candidate) => {
                      'room_id': candidate.roomId,
                      'public_anchor_uid': candidate.anchorUid,
                      'medal_level': candidate.medalLevel,
                    },
                  )
                  .toList(),
              'sample_enumeration_did_not_authorize_or_run_tasks': true,
            };
          } catch (error) {
            result['sample_inventory'] = {
              'status': 'unconfirmed',
              'error_type': error.runtimeType.toString(),
            };
          }
        }
        result['status'] = 'profiled';
      } catch (error) {
        result['status'] = 'failed';
        result['failure_stage'] = stage;
        result['error_type'] = error.runtimeType.toString();
      } finally {
        if (clientStarted) Request.dio.close(force: true);
        if (private != null) {
          try {
            await Hive.close();
          } catch (_) {
            result['storage_close_failed'] = true;
          }
          try {
            await private.delete(recursive: true);
          } catch (_) {
            result['private_storage_cleanup_failed'] = true;
          }
        }
        result['private_storage_removed'] =
            private != null && !private.existsSync();
        result['allowed_read_count'] = gate?.acceptedReads ?? 0;
        result['blocked_request_count'] = gate?.blockedRequests ?? 0;
        if (result['private_storage_removed'] != true ||
            gate?.blockedRequests != 0) {
          result['status'] = 'failed';
        }
        if (config != null) {
          File(config.reportPath).writeAsStringSync(jsonEncode(result));
        }
        print(jsonEncode(result));
      }
      expect(
        result['status'],
        'profiled',
        reason: 'Inspect sanitized room profile.',
      );
    },
    skip: !const bool.fromEnvironment('LIVE_ROOM_PROFILE_ACCEPTANCE'),
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
