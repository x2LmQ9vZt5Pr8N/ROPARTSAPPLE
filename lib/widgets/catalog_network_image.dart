import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import '../services/catalog_media_cache.dart';

/// Unified image renderer for DropAqua / ROParts catalog items.
/// Serves versioned local disk-cached S3 images (`Image.file`) in 0ms without
/// spinners once synced, refreshing automatically when `catalog_ref` updates
/// or an emergency FCM push arrives.
class CatalogNetworkImage extends StatefulWidget {
  final String? imageUrl;
  final String? fallbackAsset;
  final double? width;
  final double? height;
  final BoxFit fit;
  final int? cacheWidth;
  final int? cacheHeight;
  final IconData fallbackIcon;
  final double fallbackIconSize;
  final Color fallbackIconColor;

  const CatalogNetworkImage({
    super.key,
    required this.imageUrl,
    this.fallbackAsset,
    this.width,
    this.height,
    this.fit = BoxFit.contain,
    this.cacheWidth,
    this.cacheHeight,
    this.fallbackIcon = Icons.inventory_2_outlined,
    this.fallbackIconSize = 38,
    this.fallbackIconColor = const Color(0xFF94A3B8),
  });

  @override
  State<CatalogNetworkImage> createState() => _CatalogNetworkImageState();
}

class _CatalogNetworkImageState extends State<CatalogNetworkImage> {
  StreamSubscription<String>? _mediaSub;
  File? _cachedFile;
  bool _isFetching = false;
  bool _fetchFailed = false;

  bool _isRemoteUrl(String val) {
    final lower = val.toLowerCase();
    return lower.startsWith('https://') || lower.startsWith('http://');
  }

  String get _cleanUrl => (widget.imageUrl ?? '').trim();

  @override
  void initState() {
    super.initState();
    _syncFromCacheOrFetch();
    _mediaSub = CatalogMediaCache().updatedUrlsStream.listen((updatedKey) {
      if (!mounted || kIsWeb) return;
      final clean = _cleanUrl;
      if (clean.isEmpty || !_isRemoteUrl(clean)) return;
      if (updatedKey == '*' || updatedKey == clean) {
        final latest = CatalogMediaCache().getCachedFileSync(clean);
        if (latest != null && latest.path != _cachedFile?.path) {
          setState(() {
            _cachedFile = latest;
            _isFetching = false;
            _fetchFailed = false;
          });
        }
      }
    });
  }

  @override
  void didUpdateWidget(covariant CatalogNetworkImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((oldWidget.imageUrl ?? '').trim() != _cleanUrl) {
      _syncFromCacheOrFetch();
    }
  }

  @override
  void dispose() {
    _mediaSub?.cancel();
    super.dispose();
  }

  void _syncFromCacheOrFetch() {
    final clean = _cleanUrl;
    if (clean.isEmpty || !_isRemoteUrl(clean) || kIsWeb) {
      _cachedFile = null;
      _isFetching = false;
      _fetchFailed = false;
      return;
    }

    final existing = CatalogMediaCache().getCachedFileSync(clean);
    if (existing != null) {
      _cachedFile = existing;
      _isFetching = false;
      _fetchFailed = false;
      return;
    }

    _cachedFile = null;
    _isFetching = true;
    _fetchFailed = false;
    final requestedUrl = clean;

    unawaited(
      CatalogMediaCache().ensureImageCached(requestedUrl).then((file) {
        if (!mounted || _cleanUrl != requestedUrl) return;
        setState(() {
          _cachedFile = file;
          _isFetching = false;
          _fetchFailed = file == null;
        });
      }),
    );
  }

  Widget _buildFallback() {
    final fallbackAsset = widget.fallbackAsset;
    if (fallbackAsset != null &&
        fallbackAsset.trim().isNotEmpty &&
        !_isRemoteUrl(fallbackAsset.trim())) {
      return Image.asset(
        fallbackAsset.trim(),
        width: widget.width,
        height: widget.height,
        fit: widget.fit,
        cacheWidth: widget.cacheWidth,
        cacheHeight: widget.cacheHeight,
        errorBuilder: (_, __, ___) => Icon(
          widget.fallbackIcon,
          size: widget.fallbackIconSize,
          color: widget.fallbackIconColor,
        ),
      );
    }
    return Icon(
      widget.fallbackIcon,
      size: widget.fallbackIconSize,
      color: widget.fallbackIconColor,
    );
  }

  @override
  Widget build(BuildContext context) {
    final clean = _cleanUrl;
    if (clean.isEmpty) {
      return _buildFallback();
    }

    if (_isRemoteUrl(clean)) {
      if (kIsWeb) {
        return Image.network(
          clean,
          width: widget.width,
          height: widget.height,
          fit: widget.fit,
          cacheWidth: widget.cacheWidth,
          cacheHeight: widget.cacheHeight,
          gaplessPlayback: true,
          loadingBuilder: (context, child, progress) {
            if (progress == null) return child;
            return Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: const Color(0xFF0284C7).withValues(alpha: 0.45),
                ),
              ),
            );
          },
          errorBuilder: (_, __, ___) => _buildFallback(),
        );
      }

      final file = CatalogMediaCache().getCachedFileSync(clean) ?? _cachedFile;
      if (file != null) {
        return Image.file(
          file,
          width: widget.width,
          height: widget.height,
          fit: widget.fit,
          cacheWidth: widget.cacheWidth,
          cacheHeight: widget.cacheHeight,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => _buildFallback(),
        );
      }

      if (_fetchFailed || !_isFetching) {
        return _buildFallback();
      }

      return Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: const Color(0xFF0284C7).withValues(alpha: 0.45),
          ),
        ),
      );
    }

    return Image.asset(
      clean,
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      cacheWidth: widget.cacheWidth,
      cacheHeight: widget.cacheHeight,
      errorBuilder: (_, __, ___) => _buildFallback(),
    );
  }
}
