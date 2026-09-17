import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../state/settings_fn_state.dart';
import 'api_client.dart';

/// 认证状态管理
class AuthService {
  AuthService._();

  static final AuthService instance = AuthService._();

  /// 登录状态
  final ValueNotifier<bool> isLoggedIn = ValueNotifier(false);

  /// 服务器 URL
  final ValueNotifier<String?> serverUrl = ValueNotifier(null);

  /// 用户名
  final ValueNotifier<String?> username = ValueNotifier(null);

  /// 当前用户角色（admin / member）
  final ValueNotifier<String?> role = ValueNotifier(null);

  /// 登录中
  final ValueNotifier<bool> isLoggingIn = ValueNotifier(false);

  String? _deviceId;

  // SharedPreferences 键名（仅用于 logout 清理）
  static const String _prefsUsername = 'feiniu_username';
  static const String _prefsPassword = 'feiniu_password';
  static const String _prefsRole = 'feiniu_user_role';
  static const String _prefsDeviceId = 'feiniu_device_id';

  /// 当前是否为管理员权限
  bool get isAdmin {
    final currentRole = role.value?.toLowerCase();
    if (currentRole == 'admin' || currentRole == 'administrator') return true;
    final currentName = username.value?.toLowerCase() ?? '';
    if (currentName == 'protokc' || currentName == 'admin') return true;
    return false;
  }

  /// 初始化：从 SharedPreferences 恢复认证状态
  Future<void> init() async {
    final hasAuth = await FeiNiuApiClient.instance.tryLoadAuth();
    if (hasAuth) {
      final prefs = await SharedPreferences.getInstance();
      final savedUsername = prefs.getString(_prefsUsername) ?? '';
      final savedRole = prefs.getString(_prefsRole);
      serverUrl.value = FeiNiuApiClient.instance.baseUrl;
      username.value = savedUsername;
      role.value = savedRole;
      isLoggedIn.value = true;
      if (kDebugMode) {
        debugPrint(
          '[AuthService] Restored session: $savedUsername ($savedRole) @ ${FeiNiuApiClient.instance.baseUrl}',
        );
      }
    }
  }

  /// 登录
  ///
  /// [relayMode] 设置为 true 时，后续所有 API 请求自动携带 Cookie: mode=relay。
  ///
  /// [persistServerUrl] 可选：**持久化到账号/feiniu_server_url 的服务器地址**
  /// （默认用 [serverUrl]）。登录页在「HTTP 强制跳转 HTTPS」时会把连接地址
  /// 自动升级为 HTTPS（[serverUrl] 传有效地址），但账号应保存用户填写的原始
  /// 地址（[persistServerUrl] 传填写值），使 HTTP/HTTPS 可各自存为独立账号、
  /// 互不覆盖。仅改持久化，不影响本次连接。
  Future<bool> login(
    String serverUrl,
    String username,
    String password, {
    bool relayMode = false,
    String? persistServerUrl,
  }) async {
    if (isLoggingIn.value) return false;
    isLoggingIn.value = true;
    try {
      final deviceId = getOrCreateDeviceId();
      // 先设置 baseUrl，login() 方法需要它来拼 URL
      await FeiNiuApiClient.instance.setBaseUrl(serverUrl);
      // 中继模式：在登录请求前就设置 relayMode，确保 login() 请求携带 Cookie: mode=relay
      if (relayMode) {
        FeiNiuApiClient.instance.setRelayMode(true);
      }
      final response = await FeiNiuApiClient.instance.login(
        username,
        password,
        deviceId,
        relayMode: relayMode,
      );

      // 持久化认证信息（含中继模式标记）。持久化地址用 persistServerUrl
      // （用户填写值），与账号条目保持一致，保证 HTTP/HTTPS 各自独立。
      await FeiNiuApiClient.instance.setAuth(
        persistServerUrl ?? serverUrl,
        response.userToken,
        relayMode: relayMode,
      );
      // setAuth 会把活动 _baseUrl 一并设为持久化地址（可能是用户填写的 HTTP）；
      // 本次会话的连接地址仍是 serverUrl（可能已被升级为 HTTPS），重新指回。
      await FeiNiuApiClient.instance.setBaseUrl(serverUrl);

      final prefs = await SharedPreferences.getInstance();
      if (response.username != null) {
        await prefs.setString(_prefsUsername, response.username!);
      }
      if (response.role != null) {
        await prefs.setString(_prefsRole, response.role!);
      }
      // 保存密码以便登录页自动填充
      if (password.isNotEmpty) {
        await prefs.setString(_prefsPassword, password);
      }

      this.serverUrl.value = serverUrl;
      this.username.value = response.username ?? username;
      this.role.value = response.role;
      isLoggedIn.value = true;

      if (kDebugMode) {
        debugPrint('[AuthService] Login successful: ${response.username}');
      }
      return true;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[AuthService] Login failed: $e');
      }
      rethrow; // 让调用方处理具体错误
    } finally {
      isLoggingIn.value = false;
    }
  }

  /// 退出登录
  Future<void> logout() async {
    await FeiNiuApiClient.instance.clearAuth();
    isLoggedIn.value = false;
    serverUrl.value = null;
    username.value = null;
    role.value = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsRole);
    // 清除连接信息（含安全码）
    await AppFnConnectionSettings.clearConnection();
    if (kDebugMode) {
      debugPrint('[AuthService] Logged out');
    }
  }

  /// 获取设备 ID（首次生成并持久化）
  String getOrCreateDeviceId() {
    if (_deviceId != null) return _deviceId!;
    _deviceId = _cachedDeviceId;
    if (_deviceId != null) return _deviceId!;
    // 异步生成
    _initDeviceId();
    return _deviceId ?? '00000000000000000000000000000000';
  }

  String? _cachedDeviceId;

  Future<void> _initDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    var deviceId = prefs.getString(_prefsDeviceId);
    if (deviceId == null || deviceId.isEmpty) {
      deviceId = FeiNiuApiClient.generateDeviceId();
      await prefs.setString(_prefsDeviceId, deviceId);
    }
    _cachedDeviceId = deviceId;
    _deviceId = deviceId;
  }

  /// 确保设备 ID 已加载
  Future<String> ensureDeviceId() async {
    if (_deviceId != null) return _deviceId!;
    final prefs = await SharedPreferences.getInstance();
    var deviceId = prefs.getString(_prefsDeviceId);
    if (deviceId == null || deviceId.isEmpty) {
      deviceId = FeiNiuApiClient.generateDeviceId();
      await prefs.setString(_prefsDeviceId, deviceId);
    }
    _cachedDeviceId = deviceId;
    _deviceId = deviceId;
    return deviceId;
  }
}
