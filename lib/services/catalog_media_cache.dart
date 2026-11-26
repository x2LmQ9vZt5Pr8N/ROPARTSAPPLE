import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/catalog_snapshot.dart';
import 'api_service.dart';

/// Persistent local disk image cache tied to `catalog_ref` (Redis + FCM).
///
/// Normal opens hydrate file paths from SharedPreferences in ~1ms and serve
/// images directly via `Image.file` with zero S3 downloads when `catalog_ref`
/// matches Redis. Only missing files, `catalog_ref` version bumps, or
/// emergency FCM pushes (`CATALOG_UPDATED`) trigger image downloads.
class CatalogMediaCache {
  static final CatalogMediaCache _instance = CatalogMediaCache._internal();
  factory CatalogMediaCache() => _instance;
  CatalogMediaCache._internal();

  static const String _prefMediaVersionKey = 'ro_media_cache_ref_v1';
  static const String _prefMediaIndexKey = 'ro_media_index_v1';
  static const String _prefMediaDirtyKey = 'ro_media_dirty_v1';

  Future<Directory> Function()? cacheDirectoryProviderForTesting;

  bool _isHydrated = false;
  bool _hasDirtyMarker = false;
  int _syncSeq = 0;
  String _cachedVersion = '';
  final Map<String, String> _urlToPath = {};
  final Map<String, Future<File?>> _inFlightDownloads = {};
  Future<bool>? _inFlightBatchSync;

  final StreamController<String> _updatedUrlsController =
      StreamController<String>.broadcast();
  Stream<String> get updatedUrlsStream => _updatedUrlsController.stream;

  String get cachedCatalogRef => _cachedVersion;

  /// Records pending media refresh from background/terminated FCM isolate.
  static Future<void> markMediaDirtyInPrefs(String? catalogRef) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cleanRef = (catalogRef ?? '').trim();
      await prefs.setString(
        _prefMediaDirtyKey,
        cleanRef.isNotEmpty ? cleanRef : '__DIRTY__',
      );
    } catch (e) {
      debugPrint('[CatalogMediaCache] markMediaDirtyInPrefs warning: $e');
    }
  }

  /// Resets in-memory cache state (and optionally deletes cached files) for tests.
  Future<void> resetForTesting({bool deleteFiles = false}) async {
    _isHydrated = false;
    _hasDirtyMarker = false;
    _cachedVersion = '';
    _urlToPath.clear();
    _inFlightDownloads.clear();
    _inFlightBatchSync = null;
    if (deleteFiles && !kIsWeb) {
      try {
        final dir = await _resolveMediaDir();
        if (await dir.exists()) {
          await dir.delete(recursive: true);
        }
      } catch (_) {}
    }
  }

  Future<Directory> _resolveMediaDir() async {
    if (cacheDirectoryProviderForTesting != null) {
      final dir = await cacheDirectoryProviderForTesting!();
      if (!await dir.exists()) await dir.create(recursive: true);
      return dir;
    }

    Directory base;
    try {
      base = await getApplicationSupportDirectory();
    } catch (_) {
      base = Directory.systemTemp;
    }
    final mediaDir = Directory('${base.path}${Platform.pathSeparator}catalog_media');
    if (!await mediaDir.exists()) {
      await mediaDir.create(recursive: true);
    }
    return mediaDir;
  }

  /// Hydrates URL -> local file mapping from disk once (0ms network cost).
  Future<void> hydrate({bool force = false}) async {
    if (kIsWeb) {
      _isHydrated = true;
      return;
    }
    if (_isHydrated && !force) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      if (force) {
        try {
          await prefs.reload();
        } catch (_) {}
      }
      _cachedVersion = (prefs.getString(_prefMediaVersionKey) ?? '').trim();
      final dirty = (prefs.getString(_prefMediaDirtyKey) ?? '').trim();
      _hasDirtyMarker = dirty.isNotEmpty &&
          (dirty == '__DIRTY__' || dirty != _cachedVersion);

      final rawIndex = prefs.getString(_prefMediaIndexKey);
      _urlToPath.clear();
      if (rawIndex != null && rawIndex.trim().isNotEmpty) {
        final decoded = json.decode(rawIndex);
        if (decoded is Map) {
          decoded.forEach((key, val) {
            final url = key.toString().trim();
            final path = val?.toString().trim() ?? '';
            if (url.isNotEmpty && path.isNotEmpty) {
              try {
                final file = File(path);
                if (file.existsSync() && file.lengthSync() > 0) {
                  _urlToPath[url] = path;
                }
              } catch (_) {}
            }
          });
        }
      }
      _isHydrated = true;
    } catch (e) {
      debugPrint('[CatalogMediaCache] hydrate warning: $e');
      _isHydrated = true;
    }
  }

  /// Synchronous check used inside widget build() for 0ms disk-cached images.
  File? getCachedFileSync(String url) {
    if (kIsWeb) return null;
    final clean = url.trim();
    if (clean.isEmpty) return null;
    final path = _urlToPath[clean];
    if (path == null || path.isEmpty) return null;
    try {
      final file = File(path);
      if (file.existsSync() && file.lengthSync() > 0) {
        return file;
      }
      _urlToPath.remove(clean);
    } catch (_) {}
    return null;
  }

  /// Returns true when local disk already holds every image for [targetRef].
  bool isVersionSynced(String? targetRef, {CatalogSnapshot? snapshot}) {
    if (kIsWeb) return true;
    final cleanRef = (targetRef ?? '').trim();
    if (cleanRef.isEmpty || _hasDirtyMarker || _cachedVersion != cleanRef) {
      return false;
    }
    if (snapshot != null) {
      final urls = extractCatalogImageUrls(snapshot);
      for (final url in urls) {
        if (getCachedFileSync(url) == null) return false;
      }
    }
    return true;
  }

  /// Extracts every unique remote HTTP/HTTPS image URL from a catalog snapshot.
  static List<String> extractCatalogImageUrls(CatalogSnapshot snap) {
    final seen = <String>{};
    void addUrl(String? raw) {
      final clean = (raw ?? '').trim();
      final lower = clean.toLowerCase();
      if (clean.isNotEmpty &&
          (lower.startsWith('https://') || lower.startsWith('http://'))) {
        seen.add(clean);
      }
    }

    for (final cat in snap.categories) {
      addUrl(cat.imageUrl);
    }
    for (final prod in snap.products) {
      addUrl(prod.image);
      for (final g in prod.galleryUrls) {
        addUrl(g);
      }
    }
    for (final kit in snap.kits) {
      addUrl(kit.image);
      for (final g in kit.galleryUrls) {
        addUrl(g);
      }
    }
    return seen.toList(growable: false);
  }

  /// Synchronizes cached images with [snap] only when the version changed,
  /// emergency FCM invalidated media, or individual files are missing on disk.
  Future<bool> syncSnapshotMedia(
    CatalogSnapshot snap, {
    bool forceRefreshAll = false,
  }) async {
    if (kIsWeb) return false;
    if (_inFlightBatchSync != null && !forceRefreshAll) {
      return _inFlightBatchSync!;
    }

    final future = _syncSnapshotMediaInternal(
      snap,
      forceRefreshAll: forceRefreshAll,
    );
    _inFlightBatchSync = future;
    try {
      return await future;
    } finally {
      if (identical(_inFlightBatchSync, future)) {
        _inFlightBatchSync = null;
      }
    }
  }

  Future<bool> _syncSnapshotMediaInternal(
    CatalogSnapshot snap, {
    required bool forceRefreshAll,
  }) async {
    await hydrate();
    final prefs = await SharedPreferences.getInstance();
    final targetRef = snap.catalogRef.trim();
    final dirty = (prefs.getString(_prefMediaDirtyKey) ?? '').trim();
    final hasDirty = dirty.isNotEmpty &&
        (dirty == '__DIRTY__' || dirty != _cachedVersion);

    final versionChanged = forceRefreshAll ||
        hasDirty ||
        (targetRef.isNotEmpty && targetRef != _cachedVersion);

    final urls = extractCatalogImageUrls(snap);
    final toDownload = versionChanged
        ? urls
        : urls.where((u) => getCachedFileSync(u) == null).toList();

    final Set<String> oldPathsToClean = {};
    if (versionChanged) {
      final activeSet = urls.toSet();
      for (final entry in _urlToPath.entries.toList()) {
        if (!activeSet.contains(entry.key)) {
          oldPathsToClean.add(entry.value);
          _urlToPath.remove(entry.key);
        }
      }
    }

    if (toDownload.isEmpty && !versionChanged) {
      await prefs.remove(_prefMediaDirtyKey);
      _hasDirtyMarker = false;
      return false;
    }

    final mediaDir = await _resolveMediaDir();
    final versionTag = _sanitizeTag(
      '${targetRef.isNotEmpty ? targetRef : "v"}_${DateTime.now().millisecondsSinceEpoch}_${++_syncSeq}',
    );
    bool updatedAny = false;

    const batchSize = 4;
    for (int i = 0; i < toDownload.length; i += batchSize) {
      final batch = toDownload.skip(i).take(batchSize);
      await Future.wait(
        batch.map((url) async {
          final prevPath = _urlToPath[url];
          final existingFuture = !versionChanged ? _inFlightDownloads[url] : null;
          final downloadFuture = existingFuture ??
              _downloadUrlToFile(
                url,
                mediaDir: mediaDir,
                versionTag: versionTag,
                forceRefresh: versionChanged,
              );
          if (existingFuture == null) {
            _inFlightDownloads[url] = downloadFuture;
          }
          try {
            final file = await downloadFuture;
            if (file != null) {
              _urlToPath[url] = file.path;
              updatedAny = true;
              if (prevPath != null && prevPath.isNotEmpty && prevPath != file.path) {
                oldPathsToClean.add(prevPath);
              }
            }
          } finally {
            if (identical(_inFlightDownloads[url], downloadFuture)) {
              _inFlightDownloads.remove(url);
            }
          }
        }),
      );
    }

    if (versionChanged) {
      for (final stalePath in oldPathsToClean) {
        try {
          final f = File(stalePath);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
      // Sweep any orphaned media files in directory that are not in _urlToPath
      final activePaths = _urlToPath.values.toSet();
      try {
        await for (final entity in mediaDir.list(followLinks: false)) {
          if (entity is File && !activePaths.contains(entity.path)) {
            await entity.delete().catchError((_) => entity);
          }
        }
      } catch (_) {}
    }

    if (targetRef.isNotEmpty) {
      _cachedVersion = targetRef;
      await prefs.setString(_prefMediaVersionKey, targetRef);
    }
    _hasDirtyMarker = false;
    await prefs.remove(_prefMediaDirtyKey);
    await _persistIndex(prefs);

    if (updatedAny && !_updatedUrlsController.isClosed) {
      _updatedUrlsController.add('*');
    }
    debugPrint(
      '[CatalogMediaCache] Synced ${toDownload.length} image(s) (${targetRef.isNotEmpty ? targetRef : "uncatalogged"}), total cached: ${_urlToPath.length}',
    );
    return updatedAny;
  }

  /// Ensures a single URL is cached locally on disk (deduplicated per URL).
  Future<File?> ensureImageCached(
    String url, {
    bool forceRefresh = false,
  }) async {
    if (kIsWeb) return null;
    final clean = url.trim();
    if (clean.isEmpty) return null;
    final lower = clean.toLowerCase();
    if (!lower.startsWith('https://') && !lower.startsWith('http://')) {
      return null;
    }

    await hydrate();
    if (!forceRefresh) {
      final existing = getCachedFileSync(clean);
      if (existing != null) return existing;
    }

    final existingInFlight = _inFlightDownloads[clean];
    if (existingInFlight != null) return existingInFlight;

    final future = () async {
      try {
        final mediaDir = await _resolveMediaDir();
        final prevPath = _urlToPath[clean];
        final tag = _sanitizeTag(
          '${_cachedVersion.isNotEmpty ? _cachedVersion : "ondemand"}_${DateTime.now().millisecondsSinceEpoch}_${++_syncSeq}',
        );
        final file = await _downloadUrlToFile(
          clean,
          mediaDir: mediaDir,
          versionTag: tag,
          forceRefresh: forceRefresh,
        );
        if (file != null) {
          _urlToPath[clean] = file.path;
          if (prevPath != null && prevPath.isNotEmpty && prevPath != file.path) {
            try {
              final old = File(prevPath);
              if (await old.exists()) await old.delete();
            } catch (_) {}
          }
          final prefs = await SharedPreferences.getInstance();
          await _persistIndex(prefs);
          if (!_updatedUrlsController.isClosed) {
            _updatedUrlsController.add(clean);
          }
        }
        return file;
      } finally {
        _inFlightDownloads.remove(clean);
      }
    }();

    _inFlightDownloads[clean] = future;
    return future;
  }

  Future<void> _persistIndex(SharedPreferences prefs) async {
    try {
      await prefs.setString(_prefMediaIndexKey, json.encode(_urlToPath));
    } catch (e) {
      debugPrint('[CatalogMediaCache] persist index warning: $e');
    }
  }

  Future<File?> _downloadUrlToFile(
    String url, {
    required Directory mediaDir,
    required String versionTag,
    required bool forceRefresh,
  }) async {
    try {
      final response = await ApiService.client
          .get(
            Uri.parse(url),
            headers: forceRefresh ? const {'Cache-Control': 'no-cache'} : null,
          )
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
        return null;
      }
      final filename = '${_hashUrl128(url)}_$versionTag.${_extractExtension(url)}';
      final target = File('${mediaDir.path}${Platform.pathSeparator}$filename');
      final tmp = File('${target.path}.tmp');
      await tmp.writeAsBytes(response.bodyBytes, flush: true);
      if (await target.exists()) {
        await target.delete();
      }
      return await tmp.rename(target.path);
    } catch (e) {
      debugPrint('[CatalogMediaCache] Image download notice ($url): $e');
      return null;
    }
  }

  static String _sanitizeTag(String raw) =>
      raw.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

  static String _extractExtension(String url) {
    final cleanPath = Uri.tryParse(url)?.path.toLowerCase() ?? url.toLowerCase();
    for (final ext in const ['png', 'webp', 'jpeg', 'jpg']) {
      if (cleanPath.endsWith('.$ext')) return ext;
    }
    return 'img';
  }

  static final BigInt _fnvMask64 = BigInt.parse('FFFFFFFFFFFFFFFF', radix: 16);
  static final BigInt _fnvPrime = BigInt.parse('100000001b3', radix: 16);
  static final BigInt _fnvOffset1 = BigInt.parse('cbf29ce484222325', radix: 16);
  static final BigInt _fnvOffset2 = BigInt.parse('84222325cbf29ce4', radix: 16);

  /// Dual 64-bit FNV-1a digest -> 32 hex chars with zero extra package imports.
  static String _hashUrl128(String input) {
    final bytes = utf8.encode(input);
    var h1 = _fnvOffset1;
    var h2 = _fnvOffset2;
    for (int i = 0; i < bytes.length; i++) {
      final b = BigInt.from(bytes[i]);
      h1 = ((h1 ^ b) * _fnvPrime) & _fnvMask64;
      h2 = ((h2 ^ BigInt.from(bytes[i] ^ (i & 0xff))) * _fnvPrime) & _fnvMask64;
    }
    return '${h1.toRadixString(16).padLeft(16, '0')}${h2.toRadixString(16).padLeft(16, '0')}';
  }
}
