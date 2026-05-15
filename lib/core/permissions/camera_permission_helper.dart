import 'package:permission_handler/permission_handler.dart';

/// Requests iOS/Android camera permission for video calls and chat camera.
Future<bool> ensureCameraPermission() async {
  var status = await Permission.camera.status;
  if (status.isGranted) return true;
  status = await Permission.camera.request();
  return status.isGranted;
}
