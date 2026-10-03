// Manual, explicitly authorized, read-only shape sampling. Default suites skip.
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/http/browser_ua.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/http/live.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/account_manager/account_mgr.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

import 'live_discovery_schema_gate.dart';

Map<String, dynamic> _map(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : {};

class _QuietAccountManager extends AccountManager {
  @override
  void onError(DioException err, ErrorInterceptorHandler handler) =>
      handler.next(err);
}

void main() {
  test(
    'explicitly authorized read-only discovery schema sampling',
    () async {
      final result = <String, dynamic>{
        'schema_version': 1,
        'status': 'starting',
        'scope': 'read_only_no_playback_no_interactive_writes',
        'pagination_scope':
            'first_two_pages_schema_sample_not_complete_discovery',
      };
      LiveDiscoverySchemaConfig? config;
      Directory? private;
      var stage = 'explicit_authorization';
      var clientStarted = false;
      try {
        config = LiveDiscoverySchemaConfig.fromEnvironment(
          Platform.environment,
        );
        stage = 'private_storage';
        private = await Directory.systemTemp.createTemp(
          'pili-live-schema-gate-',
        );
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
        final recording = Accounts.account.values
            .where((value) => value.type.contains(AccountType.heartbeat))
            .firstOrNull;
        if (account == null ||
            !identical(account, recording) ||
            Pref.historyPause) {
          throw StateError('recording_identity_or_privacy_conflict');
        }
        Accounts.accountMode[AccountType.main.index] = account;
        Accounts.accountMode[AccountType.heartbeat.index] = account;
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
              if (!liveDiscoverySchemaRequestAllowed(
                options.uri,
                options.method,
                options.queryParameters,
              )) {
                handler.reject(
                  DioException.requestCancelled(
                    requestOptions: options,
                    reason: 'manual_read_only_scope_rejected',
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
        stage = 'room_normalization';
        // Reuse the existing only-audio metadata API without opening any media.
        final play = await LiveHttp.liveRoomInfo(
          roomId: config.roomId,
          qn: 80,
          onlyAudio: true,
        );
        final room = play.dataOrNull?.roomId;
        final anchor = play.dataOrNull?.uid;
        if (play is! Success ||
            room == null ||
            room <= 0 ||
            anchor == null ||
            anchor <= 0) {
          throw StateError('room_identity_unconfirmed');
        }
        result['normalized_room_matches_requested'] = room == config.roomId;
        result['anchor_identity_available'] = true;
        Future<void> sample(
          String name,
          String path,
          int pageSize,
          Map<String, dynamic> extra,
        ) async {
          stage = '${name}_sampling';
          final rawPages = <Map<String, dynamic>>[];
          final safePages = <Map<String, Object?>>[];
          for (final page in [1, 2]) {
            final response = await get('https://api.live.bilibili.com$path', {
              ...extra,
              'page': page,
              'page_size': pageSize,
            });
            safePages.add({
              'requested_page': page,
              'requested_page_size': pageSize,
              ...liveDiscoveryPageSummary(response),
            });
            rawPages.add(_map(response['data']));
          }
          result[name] = {
            'pages': safePages,
            'duplicates': liveDiscoveryDuplicateSummary(
              rawPages[0],
              rawPages[1],
            ),
            'both_pages_success': safePages.every(
              (value) => value['code'] == 0,
            ),
          };
        }

        await sample('following', '/xlive/web-ucenter/user/following', 9, {
          'ignoreRecord': 1,
          'hit_ab': true,
        });
        await sample(
          'medal_panel',
          '/xlive/app-ucenter/v1/fansMedal/panel',
          10,
          {'target_id': anchor, 'room_id': room},
        );
        result['status'] =
            _map(result['following'])['both_pages_success'] == true &&
                _map(result['medal_panel'])['both_pages_success'] == true
            ? 'pass'
            : 'schema_rejected';
      } catch (error) {
        result['status'] = 'failed';
        result['failure_stage'] = stage;
        result['error_type'] = error.runtimeType.toString();
        if (error is DioException) {
          result['http_status'] = error.response?.statusCode;
        }
      } finally {
        if (clientStarted) Request.dio.close(force: true);
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
            result['private_storage_removed'] != true) {
          result['status'] = 'failed';
          result['failure_stage'] = 'cleanup';
        }
        try {
          if (config != null) {
            File(config.reportPath).writeAsStringSync(jsonEncode(result));
          }
        } on FileSystemException {
          result['status'] = 'failed';
          result['failure_stage'] = 'report_write';
        }
        print(jsonEncode(result));
      }
      expect(
        result['status'],
        'pass',
        reason: 'Inspect sanitized discovery schema report.',
      );
    },
    skip: !const bool.fromEnvironment('LIVE_DISCOVERY_SCHEMA_ACCEPTANCE'),
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
