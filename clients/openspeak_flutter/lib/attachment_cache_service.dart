import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'openspeak_api.dart';

class AttachmentCacheService {
  AttachmentCacheService();

  OpenSpeakApi? _api;

  void updateApi(OpenSpeakApi? api) {
    _api = api;
  }

  Future<File> ensureCached({
    required String token,
    required bool direct,
    required String fileId,
    required String originalName,
    int expectedSizeBytes = 0,
    TransferProgress? onProgress,
    TransferCancelToken? cancelToken,
  }) async {
    final api = _api;
    if (api == null) {
      throw OpenSpeakException('未连接服务器');
    }
    final cached = await cachedFile(fileId: fileId, originalName: originalName);
    if (await cached.exists() && await cached.length() > 0) {
      if (expectedSizeBytes <= 0 ||
          await cached.length() == expectedSizeBytes) {
        return cached;
      }
      await cached.delete();
    }
    final downloaded = direct
        ? await api.downloadDirectFile(
            token,
            fileId,
            originalName,
            onProgress: onProgress,
            cancelToken: cancelToken,
          )
        : await api.downloadStoredFile(
            token,
            fileId,
            originalName,
            onProgress: onProgress,
            cancelToken: cancelToken,
          );
    if (expectedSizeBytes > 0 &&
        await downloaded.length() != expectedSizeBytes) {
      throw OpenSpeakException('附件下载不完整，请重试');
    }
    await cached.parent.create(recursive: true);
    return downloaded.copy(cached.path);
  }

  Future<File> seedFromLocalFile({
    required String fileId,
    required String originalName,
    required File source,
    int expectedSizeBytes = 0,
  }) async {
    if (!await source.exists()) {
      throw OpenSpeakException('原文件不存在，无法写入本地缓存');
    }
    final cached = await cachedFile(fileId: fileId, originalName: originalName);
    final sourceLength = await source.length();
    final expectedLength = expectedSizeBytes > 0
        ? expectedSizeBytes
        : sourceLength;
    if (await cached.exists() && await cached.length() == expectedLength) {
      return cached;
    }
    await cached.parent.create(recursive: true);
    if (source.absolute.path == cached.absolute.path) {
      return cached;
    }
    return source.copy(cached.path);
  }

  Future<File?> existingCachedFile({
    required String fileId,
    required String originalName,
    int expectedSizeBytes = 0,
  }) async {
    final cached = await cachedFile(fileId: fileId, originalName: originalName);
    if (!await cached.exists() || await cached.length() <= 0) {
      return null;
    }
    if (expectedSizeBytes > 0 && await cached.length() != expectedSizeBytes) {
      return null;
    }
    return cached;
  }

  Future<File> cachedFile({
    required String fileId,
    required String originalName,
  }) async {
    final dir = await _cacheDir();
    final safeId = sanitizeDownloadName(fileId);
    final safeName = sanitizeDownloadName(originalName);
    final ext = _extensionOf(safeName);
    final baseName = ext.isEmpty ? '$safeId-$safeName' : '$safeId$ext';
    return File('${dir.path}${Platform.pathSeparator}$baseName');
  }

  Future<void> clearCache() async {
    final dir = await _cacheDir();
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }

  Future<Directory> _cacheDir() async {
    final base = await getApplicationSupportDirectory();
    return Directory(
      '${base.path}${Platform.pathSeparator}openspeak${Platform.pathSeparator}attachments_cache',
    );
  }

  String _extensionOf(String name) {
    final index = name.lastIndexOf('.');
    if (index <= 0 || index == name.length - 1) return '';
    final ext = name.substring(index).toLowerCase();
    return ext.length > 16 ? '' : ext;
  }
}
