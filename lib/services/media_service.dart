import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:open_file/open_file.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import '../core/constants.dart';

class AttachmentMeta {
  final String url;
  final String type;
  final String name;
  final int size;

  const AttachmentMeta({
    required this.url,
    required this.type,
    required this.name,
    required this.size,
  });
}

class MediaService {
  static final _picker = ImagePicker();

  static const int maxUploadBytes = 100 * 1024 * 1024; // 100 MB

  /// Called with the byte count whenever a file is freshly downloaded (not cache hit).
  /// Wire this up in app.dart to AutoDownloadProvider.recordBytesDownloaded().
  static void Function(int bytes)? onBytesDownloaded;

  // ── Picking ──────────────────────────────────────────────

  /// Pick an image or GIF from gallery.
  /// Uses FileType.custom to bypass Android system photo picker which rejects GIFs.
  static Future<File?> pickFromGallery() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic'],
      allowMultiple: false,
    );
    if (result == null || result.files.isEmpty) return null;
    final path = result.files.single.path;
    return path != null ? File(path) : null;
  }

  /// Capture a photo from the camera.
  static Future<File?> pickFromCamera() async {
    final xfile = await _picker.pickImage(
      source: ImageSource.camera,
      imageQuality: 85,
    );
    return xfile != null ? File(xfile.path) : null;
  }

  /// Record a video from the camera (max 3 minutes).
  static Future<File?> recordVideo() async {
    final xfile = await _picker.pickVideo(
      source: ImageSource.camera,
      maxDuration: const Duration(minutes: 3),
    );
    return xfile != null ? File(xfile.path) : null;
  }

  /// Pick a video from the gallery.
  static Future<File?> pickVideoFromGallery() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.video,
      allowMultiple: false,
    );
    if (result == null || result.files.isEmpty) return null;
    final path = result.files.single.path;
    return path != null ? File(path) : null;
  }

  /// Pick any file (documents, PDFs, etc.).
  static Future<File?> pickFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: false,
    );
    if (result == null || result.files.isEmpty) return null;
    final path = result.files.single.path;
    return path != null ? File(path) : null;
  }

  // ── Upload ───────────────────────────────────────────────

  /// Upload [file] to the server and return metadata.
  static Future<AttachmentMeta> upload(File file, String token) async {
    final fileSize = await file.length();
    if (fileSize > maxUploadBytes) {
      throw Exception(
          'File too large (${formatSize(fileSize)}). Max is ${formatSize(maxUploadBytes)}.');
    }

    final filename = p.basename(file.path);
    final mime = lookupMimeType(file.path) ?? 'application/octet-stream';
    final parts = mime.split('/');

    final request = http.MultipartRequest(
      'POST',
      Uri.parse('${AppConstants.serverBaseUrl}/media/upload'),
    )
      ..headers['Authorization'] = 'Bearer $token'
      ..files.add(await http.MultipartFile.fromPath(
        'file',
        file.path,
        filename: filename,
        contentType: MediaType(parts[0], parts[1]),
      ));

    final streamed = await request.send();
    final body = await http.Response.fromStream(streamed);

    if (body.statusCode != 200) {
      throw Exception('Upload failed: ${body.statusCode}');
    }

    final json = jsonDecode(body.body) as Map<String, dynamic>;
    final serverType = json['type'] as String;
    // Client-side fallback: if server couldn't detect the type (e.g. temp files
    // without extension), derive it from the MIME type we already have.
    final resolvedType = serverType != 'file' ? serverType : _typeFromMime(mime);
    return AttachmentMeta(
      url: json['url'] as String,
      type: resolvedType,
      name: json['name'] as String,
      size: (json['size'] as num).toInt(),
    );
  }

  static String _typeFromMime(String mime) {
    if (mime == 'image/gif') return 'gif';
    if (mime.startsWith('image/')) return 'image';
    if (mime.startsWith('video/')) return 'video';
    return 'file';
  }

  // ── Download ─────────────────────────────────────────────

  /// Download [url] to the device temp dir with optional progress callback.
  /// Returns immediately if the file is already cached.
  static Future<File> downloadFile(
    String url,
    String filename, {
    void Function(double progress)? onProgress,
  }) async {
    final fullUrl =
        url.startsWith('http') ? url : '${AppConstants.serverBaseUrl}$url';

    final dir = await getTemporaryDirectory();
    // Use a unique subdirectory to avoid name collisions across chats
    final cacheDir = Directory('${dir.path}/pager_media');
    if (!cacheDir.existsSync()) cacheDir.createSync();
    final dest = File('${cacheDir.path}/${_safeFilename(filename)}');

    if (dest.existsSync()) {
      onProgress?.call(1.0);
      return dest;
    }

    final client = http.Client();
    try {
      final request = http.Request('GET', Uri.parse(fullUrl));
      final response = await client.send(request);
      if (response.statusCode != 200) {
        throw Exception('Download failed: ${response.statusCode}');
      }

      final total = response.contentLength ?? 0;
      int received = 0;
      final sink = dest.openWrite();
      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) onProgress?.call(received / total);
      }
      await sink.flush();
      await sink.close();
      onProgress?.call(1.0);
      // Notify data-usage tracker with actual bytes written
      final fileSize = await dest.length();
      onBytesDownloaded?.call(fileSize);
      return dest;
    } catch (e) {
      if (dest.existsSync()) dest.deleteSync();
      rethrow;
    } finally {
      client.close();
    }
  }

  // ── Thumbnails ───────────────────────────────────────────

  /// Generate a JPEG thumbnail for a remote video URL.
  /// Returns null on failure (network error, unsupported codec, etc.).
  static Future<Uint8List?> videoThumbnailBytes(String url) async {
    try {
      final fullUrl =
          url.startsWith('http') ? url : '${AppConstants.serverBaseUrl}$url';
      return await VideoThumbnail.thumbnailData(
        video: fullUrl,
        imageFormat: ImageFormat.JPEG,
        maxWidth: 480,
        quality: 70,
      );
    } catch (_) {
      return null;
    }
  }

  /// Check if a file is already in the local cache.
  static Future<bool> isCached(String filename) async {
    final dir = await getTemporaryDirectory();
    return File('${dir.path}/pager_media/${_safeFilename(filename)}')
        .existsSync();
  }

  /// Download then open with system handler (for generic files).
  static Future<void> downloadAndOpen(
    String url,
    String filename, {
    void Function(double)? onProgress,
  }) async {
    final file = await downloadFile(url, filename, onProgress: onProgress);
    await OpenFile.open(file.path);
  }

  /// Returns the full URL for displaying an attachment.
  static String fullUrl(String relativeOrAbsolute) {
    if (relativeOrAbsolute.startsWith('http')) return relativeOrAbsolute;
    return '${AppConstants.serverBaseUrl}$relativeOrAbsolute';
  }

  static String formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  static String _safeFilename(String name) =>
      name.replaceAll(RegExp(r'[^\w.\-]'), '_');
}
