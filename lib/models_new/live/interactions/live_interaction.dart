// LIVE-FN-01/02, LIVE-TX-01..06. Missing server fields stay unknown.
int? liveInt(Object? value) => switch (value) {
  int v => v,
  num v when v.isFinite && v == v.roundToDouble() => v.toInt(),
  String v => int.tryParse(v),
  _ => null,
};

Map<String, dynamic> liveMap(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : const {};

List<Map<String, dynamic>> liveMaps(Object? value) => value is List
    ? value.whereType<Map>().map(liveMap).toList(growable: false)
    : const [];

bool? liveBool(Object? value) => switch (value) {
  bool v => v,
  1 || '1' => true,
  0 || '0' => false,
  _ => null,
};

enum LiveGiftPurpose { gift, joinFanClub, lightMedal }

enum LiveActionState { notSubmitted, submitting, succeeded, failed, unknown }

class LiveGift {
  final int id;
  final String name;

  /// Official integer gold/silver units. No assumed RMB conversion.
  final int price;
  final bool priceKnown;
  final String coinType;
  final String imageUrl;
  final String description;
  final int maxQuantity;
  final bool sendable;
  final String? unavailableReason;

  const LiveGift({
    required this.id,
    required this.name,
    required this.price,
    required this.coinType,
    this.priceKnown = true,
    this.imageUrl = '',
    this.description = '',
    this.maxQuantity = 1,
    this.sendable = false,
    this.unavailableReason,
  });

  String get coinLabel => switch (coinType) {
    'gold' => '金瓜子',
    'silver' => '银瓜子',
    _ => coinType,
  };
}

class LiveBagItem {
  final int bagId;
  final int giftId;
  final String name;
  final int quantity;
  final DateTime? expiresAt;
  final LiveGift gift;
  final bool available;
  const LiveBagItem({
    required this.bagId,
    required this.giftId,
    required this.name,
    required this.quantity,
    required this.gift,
    required this.available,
    this.expiresAt,
  });
}

class LiveMedal {
  final int medalId;
  final int targetUid;
  final String name;
  final int level;
  final bool wearing;
  final bool? isLighted;
  const LiveMedal({
    required this.medalId,
    required this.targetUid,
    required this.name,
    required this.level,
    required this.wearing,
    this.isLighted,
  });
}

class LiveFanTask {
  final String name;
  final String description;
  final String jumpType;
  final bool? completed;
  const LiveFanTask({
    required this.name,
    required this.description,
    required this.jumpType,
    this.completed,
  });
}

class LiveFanStatus {
  final bool? joined;
  final bool? isLighted;
  final String name;
  final int? level;
  final int? intimacy;
  final int? nextIntimacy;
  final List<LiveFanTask> tasks;
  final LiveGift? joinGift;
  final LiveGift? lightGift;
  const LiveFanStatus({
    this.joined,
    this.isLighted,
    this.name = '',
    this.level,
    this.intimacy,
    this.nextIntimacy,
    this.tasks = const [],
    this.joinGift,
    this.lightGift,
  });
}

class LiveWallet {
  final int? gold;
  final int? silver;
  const LiveWallet({this.gold, this.silver});
}

class LiveInteractionSnapshot {
  final int roomId;
  final int anchorUid;
  final int accountUid;
  final bool loggedIn;
  final List<LiveGift> gifts;
  final List<LiveBagItem> bag;
  final List<LiveMedal> medals;
  final LiveFanStatus? fanStatus;
  final LiveWallet? wallet;
  final Map<String, String> errors;
  const LiveInteractionSnapshot({
    required this.roomId,
    required this.anchorUid,
    required this.accountUid,
    required this.loggedIn,
    this.gifts = const [],
    this.bag = const [],
    this.medals = const [],
    this.fanStatus,
    this.wallet,
    this.errors = const {},
  });
}

class LiveGiftConfirmation {
  final LiveGift gift;
  final int quantity;
  final LiveBagItem? bagItem;
  final LiveGiftPurpose purpose;
  final int accountUid;
  final int roomId;
  final int anchorUid;
  final DateTime expiresAt;
  final String operationId;

  /// Opaque login instance; never serialized. Restored confirmations cannot send.
  final Object? accountIdentity;
  final int approvalEpoch;
  const LiveGiftConfirmation({
    required this.gift,
    required this.quantity,
    required this.purpose,
    required this.accountUid,
    required this.roomId,
    required this.anchorUid,
    required this.expiresAt,
    required this.operationId,
    this.accountIdentity,
    this.approvalEpoch = 0,
    this.bagItem,
  });
  int get totalPrice => bagItem == null ? gift.price * quantity : 0;
  String get coinLabel => bagItem == null ? gift.coinLabel : '背包库存';
}

class LiveActionResult {
  final LiveActionState state;
  final String message;
  final String operationId;
  final String? receiptId;
  final LiveGiftConfirmation? confirmation;
  final LiveFanStatus? fanStatus;
  final int? medalId;
  final bool? medalWearing;

  /// Session owner for visible state only; never written to the journal.
  final Object? accountIdentity;
  const LiveActionResult({
    required this.state,
    required this.message,
    required this.operationId,
    this.receiptId,
    this.confirmation,
    this.fanStatus,
    this.medalId,
    this.medalWearing,
    this.accountIdentity,
  });

  LiveActionResult copyWith({
    LiveActionState? state,
    String? message,
    LiveFanStatus? fanStatus,
  }) => LiveActionResult(
    state: state ?? this.state,
    message: message ?? this.message,
    operationId: operationId,
    receiptId: receiptId,
    confirmation: confirmation,
    fanStatus: fanStatus ?? this.fanStatus,
    medalId: medalId,
    medalWearing: medalWearing,
    accountIdentity: accountIdentity,
  );
}

class LiveInteractionException implements Exception {
  final String message;
  const LiveInteractionException(this.message);
  @override
  String toString() => message;
}
