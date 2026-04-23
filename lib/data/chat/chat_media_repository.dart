import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:get/get.dart' hide FormData, MultipartFile;
import 'package:image_picker/image_picker.dart';

import '../../core/network/api_endpoints.dart';
import '../auth/auth_repository.dart';

class ChatMediaRepository {
  ChatMediaRepository(this._dio);

  final Dio _dio;

  /// Upload one image; server returns ImageKit URL + SHA-256 + size.
  Future<({String url, String hash, int size})> uploadImage(
    XFile file, {
    ProgressCallback? onSendProgress,
  }) async {
    final token = Get.find<AuthRepository>().accessToken;
    if (token == null || token.isEmpty) {
      throw StateError('Not signed in');
    }
    final bytes = await file.readAsBytes();
    final name = file.name.trim().isEmpty ? 'image.jpg' : file.name.trim();
    final form = FormData.fromMap({
      'file': MultipartFile.fromBytes(bytes, filename: name),
    });
    final res = await _dio.post<dynamic>(
      ApiEndpoints.chatMediaUpload,
      data: form,
      options: Options(
        headers: {'Authorization': 'Bearer $token'},
        contentType: 'multipart/form-data',
      ),
      onSendProgress: onSendProgress,
    );
    final raw = res.data;
    if (raw is! Map) {
      throw StateError('Invalid upload response');
    }
    final url = '${raw['url'] ?? ''}'.trim();
    final hash = '${raw['hash'] ?? ''}'.trim().toLowerCase();
    final size = int.tryParse('${raw['size'] ?? bytes.length}') ?? bytes.length;
    if (url.isEmpty || hash.length != 64) {
      throw StateError('Invalid upload payload');
    }
    return (url: url, hash: hash, size: size);
  }

  /// Download remote image bytes (for cache / viewer).
  Future<Uint8List> downloadUrl(String url, {void Function(int received, int total)? onProgress}) async {
    final res = await _dio.get<List<int>>(
      url,
      options: Options(responseType: ResponseType.bytes),
      onReceiveProgress: onProgress,
    );
    final data = res.data;
    if (data == null) throw StateError('Empty download');
    return Uint8List.fromList(data);
  }
}
