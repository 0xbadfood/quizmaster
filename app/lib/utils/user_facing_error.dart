bool _looksLikeConnectivityError(Object error) {
  final text = error.toString().toLowerCase();
  return text.contains('socketexception') ||
      text.contains('failed host lookup') ||
      text.contains('no address associated') ||
      text.contains('network is unreachable') ||
      text.contains('connection refused') ||
      text.contains('connection reset') ||
      text.contains('connection timed out') ||
      text.contains('operation timed out') ||
      text.contains('timed out') ||
      text.contains('clientexception') ||
      text.contains('handshakeexception');
}

String friendlyConnectionMessage(Object error) {
  if (_looksLikeConnectivityError(error)) {
    return 'This device may not be connected to the internet. Please check the connection and try again.';
  }
  final message = _cleanHumanMessage(error);
  if (message.isNotEmpty && !_looksTechnical(message)) {
    return message;
  }
  return 'StoryVault could not connect right now. Please try again in a little while.';
}

String friendlyDownloadMessage(Object error) {
  if (_looksLikeConnectivityError(error)) {
    return 'This device may not be connected to the internet. Please check the connection and try again.';
  }
  return 'Could not download this item right now. Please try again in a little while.';
}

String friendlyContentLoadMessage(Object error, String contentName) {
  if (_looksLikeConnectivityError(error)) {
    return 'This device may not be connected to the internet. Please check the connection and try again.';
  }
  return 'Could not load $contentName right now. Please try again in a little while.';
}

String _cleanHumanMessage(Object error) {
  return error
      .toString()
      .trim()
      .replaceFirst(RegExp(r'^(Exception|HttpException|StateError):\s*'), '')
      .replaceFirst(RegExp(r'^Bad state:\s*'), '')
      .trim();
}

bool _looksTechnical(String message) {
  final text = message.toLowerCase();
  return text.contains('http://') ||
      text.contains('https://') ||
      text.contains('uri=') ||
      text.contains('errno') ||
      text.contains('socket') ||
      text.contains('clientexception') ||
      text.contains('traceback') ||
      text.contains('request failed:');
}
