import 'package:dio/dio.dart';
import 'package:get/get.dart';

import '../../core/network/api_endpoints.dart';
import 'call_history_entry.dart';

class CallsRepository extends GetxService {
  CallsRepository(this._dio);

  final Dio _dio;

  Future<List<CallHistoryEntry>> fetchHistory({int limit = 50}) async {
    final res = await _dio.get<dynamic>(
      ApiEndpoints.chatCallHistory,
      queryParameters: {'limit': limit},
    );
    final data = res.data;
    if (data is! Map) return const [];
    final raw = data['items'];
    if (raw is! List) return const [];
    return raw
        .whereType<Map>()
        .map((e) => CallHistoryEntry.fromJson(Map<String, dynamic>.from(e)))
        .where((e) => e.callId.isNotEmpty && e.peerId.isNotEmpty)
        .toList();
  }
}
