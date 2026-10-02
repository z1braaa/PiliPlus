import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Pure native equivalent of the current official spyder WASM signature.
/// Offline vectors and source hashes are in live-watch-signing-2026-10-02.json.
/// This establishes signature parity, not authenticated server acceptance.
abstract final class LiveWatchSigner {
  static const _hashes = [md5, sha1, sha256, sha224, sha512, sha384];
  static const _mixinOrder = [
    46,
    47,
    18,
    2,
    53,
    8,
    23,
    32,
    15,
    50,
    10,
    31,
    58,
    3,
    45,
    35,
    27,
    43,
    5,
    49,
    33,
    9,
    42,
    19,
    29,
    28,
    14,
    39,
    12,
    38,
    41,
    13,
  ];
  static final _filtered = RegExp(r"[!'()*]");

  static bool supportsRules(List<int> rules) =>
      rules.isNotEmpty &&
      rules.length <= 32 &&
      rules.every((rule) => rule >= 0 && rule < _hashes.length);

  static String canonical(Map<String, Object> body) {
    final rawId = body['id'];
    final rawDevice = body['device'];
    if (rawId is! String || rawDevice is! String) {
      throw const FormatException('Invalid live watch signature identity');
    }
    final id = jsonDecode(rawId);
    final device = jsonDecode(rawDevice);
    if (id is! List ||
        id.length != 4 ||
        id.any(
          (value) => value is! int || value < 0 || value > 9007199254740991,
        ) ||
        device is! List ||
        device.length != 2 ||
        device.any((value) => value is! String || value.isEmpty)) {
      throw const FormatException('Invalid live watch signature identity');
    }
    for (final field in ['ets', 'time', 'ts']) {
      final value = body[field];
      if (value is! int || value <= 0 || value > 9007199254740991) {
        throw const FormatException('Invalid live watch signature time');
      }
    }
    // Rust serializes its Body struct in this declaration order. ruid, ua,
    // trackid and benchmark are deliberately not serialized into this value.
    return jsonEncode({
      'platform': 'web',
      'parent_id': id[0],
      'area_id': id[1],
      'seq_id': id[2],
      'room_id': id[3],
      'buvid': device[0],
      'uuid': device[1],
      'ets': body['ets'],
      'time': body['time'],
      'ts': body['ts'],
    });
  }

  static String sign(Map<String, Object> body, List<int> rules) {
    if (!supportsRules(rules)) {
      throw const FormatException('Unsupported live watch signature rule');
    }
    final key = body['benchmark'];
    if (key is! String || key.isEmpty || key.length > 4096) {
      throw const FormatException('Invalid live watch signature key');
    }
    var value = canonical(body);
    final keyBytes = utf8.encode(key);
    for (final rule in rules) {
      value = Hmac(
        _hashes[rule],
        keyBytes,
      ).convert(utf8.encode(value)).toString();
    }
    return value;
  }

  static String mixinKey(String imgKey, String subKey) {
    final combined = imgKey + subKey;
    if (combined.length != 64 ||
        !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(combined)) {
      throw const FormatException('Official WBI keys are unavailable');
    }
    return String.fromCharCodes(_mixinOrder.map(combined.codeUnitAt));
  }

  /// Current official middleware signs query parameters, including CSRF.
  /// It rounds wall time to seconds; it does not use watching elapsed time.
  static Map<String, Object> signQuery(
    Map<String, Object> params,
    String mixinKey,
    DateTime now,
  ) {
    if (mixinKey.length != 32) {
      throw const FormatException('Official WBI keys are unavailable');
    }
    final result = <String, Object>{
      ...params,
      'wts': (now.millisecondsSinceEpoch / 1000).round().toString(),
    };
    final keys = result.keys.toList()..sort();
    final encoded = keys
        .map((key) {
          final value = result[key].toString().replaceAll(_filtered, '');
          return '${Uri.encodeComponent(key)}=${Uri.encodeComponent(value)}';
        })
        .join('&');
    result['w_rid'] = md5.convert(utf8.encode(encoded + mixinKey)).toString();
    return result;
  }
}
