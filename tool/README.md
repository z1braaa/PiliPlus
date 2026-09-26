run `dart run tool/jnigen.dart`

## Python 点播测试

`python3 tool/vod_auto_test.py regress` 汇总已有 Dart/Flutter 回归，SDK 不在系统路径时使用 `--dart` 和 `--flutter` 指定。

`python3 tool/vod_auto_test.py playback --help` 显示固定素材、画质与起点的原生双轨对照参数。需提供兼容的 mpv 动态库；工具不读取账号。并发路径使用真实 Dart 代理。

完整流程、报告解释和 GUI/真实网络验收边界见[自动化指南](../docs/harness/automated-vod-testing.md)。
