/// Display-only data. Credentials remain in the existing account store.
enum SavedAccountLoginState { unchecked, verified, expired }

class SavedAccountProfile {
  const SavedAccountProfile({
    this.name = '',
    this.avatar = '',
    this.loginState = SavedAccountLoginState.unchecked,
    this.checkedAt,
    this.checkFailed = false,
  });

  final String name;
  final String avatar;
  final SavedAccountLoginState loginState;
  final DateTime? checkedAt;
  final bool checkFailed;

  String get statusLabel => checkFailed
      ? '登录状态待核对'
      : switch (loginState) {
          SavedAccountLoginState.unchecked => '登录状态待核对',
          SavedAccountLoginState.verified => '登录有效',
          SavedAccountLoginState.expired => '登录已失效',
        };

  SavedAccountProfile copyWith({
    String? name,
    String? avatar,
    SavedAccountLoginState? loginState,
    DateTime? checkedAt,
    bool? checkFailed,
  }) => SavedAccountProfile(
    name: name ?? this.name,
    avatar: avatar ?? this.avatar,
    loginState: loginState ?? this.loginState,
    checkedAt: checkedAt ?? this.checkedAt,
    checkFailed: checkFailed ?? this.checkFailed,
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    'avatar': avatar,
    'state': loginState.name,
    if (checkedAt != null) 'checkedAt': checkedAt!.millisecondsSinceEpoch,
    'checkFailed': checkFailed,
  };

  factory SavedAccountProfile.fromJson(Map? json) {
    if (json == null) return const SavedAccountProfile();
    final state = SavedAccountLoginState.values.where(
      (value) => value.name == json['state'],
    );
    final timestamp = json['checkedAt'];
    return SavedAccountProfile(
      name: json['name'] is String ? json['name'] as String : '',
      avatar: json['avatar'] is String ? json['avatar'] as String : '',
      loginState: state.isEmpty
          ? SavedAccountLoginState.unchecked
          : state.first,
      checkedAt: timestamp is int
          ? DateTime.fromMillisecondsSinceEpoch(timestamp)
          : null,
      checkFailed: json['checkFailed'] == true,
    );
  }
}
