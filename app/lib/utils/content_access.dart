import '../models/content_item.dart';
import '../providers/app_state.dart';

bool isContentLockedForCurrentUser(AppState appState, ContentItem item) {
  if (appState.sandboxMode || item.isHeroFree) {
    return false;
  }
  return item.locked && !appState.customerEntitled;
}
