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

import 'live_medal_pagination_gate.dart';

Map<String, dynamic> _map(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : {};

class _QuietAccountManager extends AccountManager {
  @override
  void onError(DioException err, ErrorInterceptorHandler handler) =>
      handler.next(err);
}

void main() {
  test(
    'explicitly authorized bounded read-only medal pagination',
    () async {
      final result = <String, dynamic>{
        'schema_version': 1,
        'status': 'starting',
        'scope': 'read_only_no_playback_no_interactive_writes',
        'pagination_scope':
            'panel_only_max_30_pages_stop_before_unverified_light_cursor',
      };
      LiveMedalPaginationConfig? config;
      Directory? private;
      var stage = 'explicit_authorization';
      var clientStarted = false;
      try {
        config = LiveMedalPaginationConfig.fromEnvironment(
          Platform.environment,
        );
        stage = 'private_storage';
        private = await Directory.systemTemp.createTemp(
          'pili-live-medal-pages-gate-',
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
              if (!liveMedalPaginationRequestAllowed(
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
        stage = 'medal_panel_pagination';
        final cursor = LiveMedalPaginationCursor();
        while (cursor.nextPage != null) {
          final page = cursor.nextPage!;
          final response = await get(
            'https://api.live.bilibili.com/xlive/app-ucenter/v1/fansMedal/panel',
            {
              'target_id': anchor,
              'room_id': room,
              'page': page,
              'page_size': 10,
            },
          );
          cursor.accept(page, response);
        }
        result['medal_panel'] = cursor.summary;
        // A protocol boundary is a successful read-only sample, never a claim
        // that discovery was complete or that the next cursor is verified.
        result['status'] = cursor.stopReason == 'service_rejected'
            ? 'schema_rejected'
            : 'sampled';
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
        if (result['status'] == 'sampled' &&
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
        'sampled',
        reason: 'Inspect sanitized pagination boundary report.',
      );
    },
    skip: !const bool.fromEnvironment('LIVE_MEDAL_PAGINATION_ACCEPTANCE'),
    timeout: const Timeout(Duration(minutes: 9)),
  );
}
