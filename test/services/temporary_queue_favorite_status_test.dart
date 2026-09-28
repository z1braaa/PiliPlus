import 'package:PiliPlus/models_new/fav/fav_folder/list.dart';
import 'package:PiliPlus/services/temporary_queue_favorite_status.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('folder presence without fav_state=1 is not a confirmed favorite', () {
    final folders = [
      FavFolderInfo(id: 10, favState: 0),
      FavFolderInfo(id: 11, favState: 1),
      FavFolderInfo(id: 12),
    ];
    expect(isConfirmedFavoriteInFolder(folders, 10), isFalse);
    expect(isConfirmedFavoriteInFolder(folders, 11), isTrue);
    expect(isConfirmedFavoriteInFolder(folders, 12), isFalse);
    expect(isConfirmedFavoriteInFolder(folders, 13), isFalse);
    expect(isConfirmedFavoriteInFolder(null, 11), isFalse);
  });
}
