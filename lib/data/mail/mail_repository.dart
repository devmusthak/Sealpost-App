import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:get/get.dart';

import '../../core/network/api_endpoints.dart';
import '../auth/auth_repository.dart';
import 'mail_detail.dart';
import 'mail_list_item.dart';

class MailRepository {
  MailRepository(this._dio);

  final Dio _dio;

  /// [folder] matches server IMAP folder names (e.g. `INBOX`, `Sent`, `Spam`, `Trash`).
  Future<MailListResult> fetchMails({
    String folder = 'INBOX',
    int skip = 0,
    int limit = 50,
    String? search,
  }) async {
    final token = Get.find<AuthRepository>().accessToken;
    if (token == null || token.isEmpty) {
      throw StateError('Not signed in');
    }

    final queryParameters = <String, dynamic>{
      'folder': folder,
      'skip': skip,
      'limit': limit,
    };
    final q = search?.trim();
    if (q != null && q.isNotEmpty) {
      queryParameters['q'] = q;
    }

    final res = await _dio.get(
      ApiEndpoints.mails,
      queryParameters: queryParameters,
    );

    final status = res.statusCode ?? 0;
    final raw = res.data;
    if (status == 200 && raw != null) {
      final data = _mapFromDynamic(raw);
      if (data == null) {
        throw DioException(
          requestOptions: res.requestOptions,
          response: res,
          type: DioExceptionType.badResponse,
          message: 'Invalid mail response',
        );
      }
      final list = data['items'];
      final items = <MailListItem>[];
      if (list is List) {
        for (final e in list) {
          final row = _mapFromDynamic(e);
          if (row == null) continue;
          try {
            items.add(MailListItem.fromJson(row));
          } catch (_) {
            /* skip malformed row; keeps rest of inbox visible */
          }
        }
      }
      final total = data['total'];
      return MailListResult(
        items: items,
        total: total is int ? total : int.tryParse('$total') ?? items.length,
      );
    }

    final errMap = _mapFromDynamic(raw);
    final msg = errMap != null && errMap['message'] != null
        ? '${errMap['message']}'
        : 'Failed to load mail';
    throw DioException(
      requestOptions: res.requestOptions,
      response: res,
      type: DioExceptionType.badResponse,
      message: msg,
    );
  }

  Future<MailDetail> fetchMailById(String id) async {
    final token = Get.find<AuthRepository>().accessToken;
    if (token == null || token.isEmpty) {
      throw StateError('Not signed in');
    }
    final trimmed = id.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('Mail id required');
    }

    final res = await _dio.get('${ApiEndpoints.mails}/$trimmed');

    final status = res.statusCode ?? 0;
    final raw = res.data;
    if (status == 200 && raw != null) {
      final data = _mapFromDynamic(raw);
      if (data == null) {
        throw DioException(
          requestOptions: res.requestOptions,
          response: res,
          type: DioExceptionType.badResponse,
          message: 'Invalid mail response',
        );
      }
      return MailDetail.fromJson(data);
    }

    final errMap = _mapFromDynamic(raw);
    final msg = errMap != null && errMap['message'] != null
        ? '${errMap['message']}'
        : 'Failed to load message';
    throw DioException(
      requestOptions: res.requestOptions,
      response: res,
      type: DioExceptionType.badResponse,
      message: msg,
    );
  }

  /// Sends a message via server SMTP (Nodemailer), using the signed-in account password.
  Future<void> sendComposeMail({
    required List<String> to,
    required List<String> cc,
    required String subject,
    required String text,
    List<MailOutgoingAttachment> attachments = const [],
  }) async {
    final token = Get.find<AuthRepository>().accessToken;
    if (token == null || token.isEmpty) {
      throw StateError('Not signed in');
    }
    if (to.isEmpty) {
      throw ArgumentError('At least one To address required');
    }

    final res = await _dio.post<dynamic>(
      ApiEndpoints.mailsSend,
      data: <String, dynamic>{
        'to': to,
        'cc': cc,
        'subject': subject,
        'text': text,
        'attachments': attachments
            .map(
              (a) => <String, dynamic>{
                'filename': a.filename,
                'contentType': a.contentType,
                'dataBase64': base64Encode(a.bytes),
              },
            )
            .toList(),
      },
    );

    final status = res.statusCode ?? 0;
    if (status == 200) return;

    final raw = res.data;
    final errMap = _mapFromDynamic(raw);
    final msg = errMap != null && errMap['message'] != null
        ? '${errMap['message']}'
        : 'Could not send message';
    throw DioException(
      requestOptions: res.requestOptions,
      response: res,
      type: DioExceptionType.badResponse,
      message: msg,
    );
  }

  Future<void> deleteMail(String id) async {
    final token = Get.find<AuthRepository>().accessToken;
    if (token == null || token.isEmpty) {
      throw StateError('Not signed in');
    }
    final trimmed = id.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('Mail id required');
    }

    final res = await _dio.delete<dynamic>('${ApiEndpoints.mails}/$trimmed');
    final status = res.statusCode ?? 0;
    if (status == 200) return;

    final raw = res.data;
    final errMap = _mapFromDynamic(raw);
    final msg = errMap != null && errMap['message'] != null
        ? '${errMap['message']}'
        : 'Could not delete message';
    throw DioException(
      requestOptions: res.requestOptions,
      response: res,
      type: DioExceptionType.badResponse,
      message: msg,
    );
  }

  /// Dio/json_decode often yields [Map<dynamic, dynamic>] for nested objects.
  Map<String, dynamic>? _mapFromDynamic(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    return null;
  }
}

class MailOutgoingAttachment {
  const MailOutgoingAttachment({
    required this.filename,
    required this.contentType,
    required this.bytes,
  });

  final String filename;
  final String contentType;
  final Uint8List bytes;
}

class MailListResult {
  const MailListResult({
    required this.items,
    required this.total,
  });

  final List<MailListItem> items;
  final int total;
}
