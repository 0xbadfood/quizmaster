import 'dart:io';

import 'package:flutter/material.dart';

bool isNetworkContentPath(String path) {
  final normalized = path.trim().toLowerCase();
  return normalized.startsWith('http://') || normalized.startsWith('https://');
}

bool isLocalFileContentPath(String path) {
  final normalized = path.trim().toLowerCase();
  return normalized.startsWith('/') || normalized.startsWith('file://');
}

Widget buildContentImage(
  String path, {
  Key? key,
  double? width,
  double? height,
  BoxFit fit = BoxFit.cover,
  FilterQuality filterQuality = FilterQuality.medium,
  Widget Function(BuildContext, Object, StackTrace?)? errorBuilder,
}) {
  final normalized = path.trim();
  if (isNetworkContentPath(normalized)) {
    return Image.network(
      normalized,
      key: key,
      width: width,
      height: height,
      fit: fit,
      filterQuality: filterQuality,
      errorBuilder: errorBuilder,
    );
  }
  if (isLocalFileContentPath(normalized)) {
    final file = normalized.startsWith('file://') ? File.fromUri(Uri.parse(normalized)) : File(normalized);
    return Image.file(
      file,
      key: key,
      width: width,
      height: height,
      fit: fit,
      filterQuality: filterQuality,
      errorBuilder: errorBuilder,
    );
  }
  return Image.asset(
    normalized,
    key: key,
    width: width,
    height: height,
    fit: fit,
    filterQuality: filterQuality,
    errorBuilder: errorBuilder,
  );
}
