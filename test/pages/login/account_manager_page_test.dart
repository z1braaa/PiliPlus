import 'package:PiliPlus/pages/login/account_manager_page.dart';
import 'package:PiliPlus/utils/accounts/saved_account_profile.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('saved account shows identity and explicit management actions', (
    tester,
  ) async {
    var selected = 0;
    var relogin = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SavedAccountCard(
            uid: 100,
            profile: const SavedAccountProfile(name: 'Fixture user'),
            current: false,
            onSelect: () => ++selected,
            onRelogin: () => ++relogin,
            onRemove: () {},
            onClearTaskData: () {},
          ),
        ),
      ),
    );
    expect(find.text('Fixture user'), findsOneWidget);
    expect(find.textContaining('UID 100'), findsOneWidget);
    expect(find.textContaining('登录状态待核对'), findsOneWidget);
    await tester.tap(find.text('切换'));
    await tester.tap(find.text('重新登录'));
    expect(selected, 1);
    expect(relogin, 1);
    await tester.tap(find.byTooltip('账号操作'));
    await tester.pumpAndSettle();
    expect(find.text('移除本机登录'), findsOneWidget);
    expect(find.text('清除该账号任务数据'), findsOneWidget);
  });

  testWidgets('expired credentials remain available for reauthentication', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SavedAccountCard(
            uid: 100,
            profile: SavedAccountProfile(
              loginState: SavedAccountLoginState.expired,
            ),
            current: false,
          ),
        ),
      ),
    );
    expect(find.textContaining('登录已失效'), findsOneWidget);
    final switchButton = tester.widget<TextButton>(
      find.widgetWithText(TextButton, '切换'),
    );
    expect(switchButton.onPressed, isNull);
    expect(find.text('重新登录'), findsOneWidget);
  });

  testWidgets('narrow card supports large text without overlapping actions', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(1.5)),
          child: Scaffold(
            body: SavedAccountCard(
              uid: 1234567890123,
              profile: SavedAccountProfile(name: '很长的账号名称测试文字'),
              current: true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('当前'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
