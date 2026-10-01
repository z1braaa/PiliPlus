import 'package:PiliPlus/models_new/live/interactions/live_interaction.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('gold API values display exact batteries without changing transaction units', () {
    for (final (raw, label) in [
      (-1, '-0.01'),
      (0, '0'),
      (1, '0.01'),
      (10, '0.1'),
      (100, '1'),
      (150, '1.5'),
      (199, '1.99'),
      (3000000, '30000'),
    ]) {
      final gift = LiveGift(id: 1, name: '礼物', price: raw, coinType: 'gold');
      expect(gift.displayPrice, label);
      expect(gift.coinLabel, '电池');
      expect(gift.price, raw);
      expect(gift.formatPrice(raw * 3), liveBatteryAmount(raw * 3));
    }
    const silver = LiveGift(
      id: 2,
      name: '免费礼物',
      price: 100,
      coinType: 'silver',
    );
    expect(silver.displayPrice, '100');
    expect(silver.coinLabel, '银瓜子');
  });
}
