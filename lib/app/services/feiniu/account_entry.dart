import 'package:flutter/foundation.dart';

/// 已保存的账号条目
///
/// 每个账号对应一台飞牛服务器的登录身份（token + 服务器地址 + 可选中继/安全码）。
/// 用户可自定义 [name] 作为备注显示名；为空时展示自动生成的名称
/// （`username@host`）。
class AccountEntry {
  /// 稳定唯一 id，首次保存时生成
  final String id;

  /// 备注/显示名（用户可改；'' 时显示时自动生成）
  final String name;

  /// 规范化 base URL（无 /music/api/v1 后缀，无末尾斜杠）
  final String serverUrl;

  final String username;

  /// 明文密码，用于登录页自动填充（沿用 feiniu_password 约定）
  final String? password;

  /// 登录状态 token；'' 表示已退出/需重新登录
  final String token;

  /// 是否通过中继链接连接
  final bool relayMode;

  /// 该账号的安全码（可选）
  final String? accessCode;

  /// 若经 FNID 登录，记录用于探测的 FNID
  final String? fnId;

  /// 用户角色（admin 管理员 / member 普通用户）
  final String? role;

  final DateTime createdAt;

  const AccountEntry({
    required this.id,
    this.name = '',
    required this.serverUrl,
    required this.username,
    this.password,
    this.token = '',
    this.relayMode = false,
    this.accessCode,
    this.fnId,
    this.role,
    required this.createdAt,
  });

  /// 是否为管理员用户（敏感操作门禁）
  bool get isAdmin =>
      (role?.toLowerCase() == 'admin') ||
      (role?.toLowerCase() == 'administrator') ||
      (username.toLowerCase() == 'protokc');

  /// 去重键：同一 FNID + 同一用户名视为同一账号；无 FNID 时回退
  /// 「同一服务器 + 同一用户名」。
  ///
  /// FNID 账号的 serverUrl 是探测出来的最优地址（内网 IP / 公网 IP / 中继），
  /// 会随网络环境与重连而改变；若按 serverUrl 去重，重连探测到新地址就会
  /// 把同一账号拆成多个条目（「很多个服务器」）。FNID 是设备的稳定标识，
  /// 用它做去重键可让账号跨地址切换保持唯一。
  String get identityKey {
    final id = fnId;
    if (id != null && id.isNotEmpty) {
      return 'fnid:${id.trim()}::$username';
    }
    return '${serverUrl.trim()}::$username';
  }

  /// 服务器主机名（用于展示）
  String get host {
    final uri = Uri.tryParse(serverUrl);
    if (uri != null && uri.host.isNotEmpty) return uri.host;
    return serverUrl;
  }

  /// 服务器地址展示标签：
  /// - FNID 连接的账号只显示 FNID，不显示完整链接/域名；
  /// - 否则显示完整 origin（scheme://host:port），区分 HTTP/HTTPS 与端口
  ///   （同一台服务器可分别保存 HTTP 与 HTTPS 两个账号）。
  String get serverLabel {
    final id = fnId;
    if (id != null && id.isNotEmpty) {
      // 防御：fnId 可能带有 .5ddd.com 后缀，仅保留 id 部分
      if (id.endsWith('.5ddd.com')) {
        return id.substring(0, id.length - '.5ddd.com'.length);
      }
      return id;
    }
    final uri = Uri.tryParse(serverUrl);
    if (uri != null && uri.host.isNotEmpty) {
      final host = uri.host.contains(':') ? '[${uri.host}]' : uri.host;
      final port = uri.hasPort ? ':${uri.port}' : '';
      return '${uri.scheme}://$host$port';
    }
    return serverUrl;
  }

  /// 展示名称：优先备注，否则默认「飞牛音乐」
  String get displayName {
    if (name.isNotEmpty) return name;
    return '飞牛音乐';
  }

  bool get isLoggedIn => token.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'serverUrl': serverUrl,
        'username': username,
        if (password != null) 'password': password,
        'token': token,
        'relayMode': relayMode,
        if (accessCode != null) 'accessCode': accessCode,
        if (fnId != null) 'fnId': fnId,
        if (role != null) 'role': role,
        'createdAtMs': createdAt.millisecondsSinceEpoch,
      };

  factory AccountEntry.fromJson(Map<String, dynamic> json) {
    final rawCreatedAt = json['createdAtMs'];
    return AccountEntry(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      serverUrl: json['serverUrl'] as String? ?? '',
      username: json['username'] as String? ?? '',
      password: json['password'] as String?,
      token: json['token'] as String? ?? '',
      relayMode: json['relayMode'] as bool? ?? false,
      accessCode: json['accessCode'] as String?,
      fnId: json['fnId'] as String?,
      role: json['role'] as String?,
      createdAt: rawCreatedAt is int
          ? DateTime.fromMillisecondsSinceEpoch(rawCreatedAt)
          : DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  AccountEntry copyWith({
    String? id,
    String? name,
    String? serverUrl,
    String? username,
    String? Function()? password,
    String? token,
    bool? relayMode,
    String? Function()? accessCode,
    String? Function()? fnId,
    String? role,
    DateTime? createdAt,
  }) {
    return AccountEntry(
      id: id ?? this.id,
      name: name ?? this.name,
      serverUrl: serverUrl ?? this.serverUrl,
      username: username ?? this.username,
      password: password != null ? password() : this.password,
      token: token ?? this.token,
      relayMode: relayMode ?? this.relayMode,
      accessCode: accessCode != null ? accessCode() : this.accessCode,
      fnId: fnId != null ? fnId() : this.fnId,
      role: role ?? this.role,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  @override
  String toString() =>
      'AccountEntry(id: $id, name: $name, serverUrl: $serverUrl, '
      'username: $username, isLoggedIn: $isLoggedIn)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AccountEntry &&
          other.id == id &&
          other.name == name &&
          other.serverUrl == serverUrl &&
          other.username == username &&
          other.password == password &&
          other.token == token &&
          other.relayMode == relayMode &&
          other.accessCode == accessCode &&
          other.fnId == fnId &&
          other.createdAt == createdAt;

  @override
  int get hashCode => Object.hash(
    id,
    name,
    serverUrl,
    username,
    password,
    token,
    relayMode,
    accessCode,
    fnId,
    createdAt,
  );

  /// 测试用：便于在断言的 `==` 与常量构造中省略 id/createdAt。
  @visibleForTesting
  static AccountEntry build({
    String id = '',
    String name = '',
    required String serverUrl,
    required String username,
    String? password,
    String token = '',
    bool relayMode = false,
    String? accessCode,
    String? fnId,
    DateTime? createdAt,
  }) {
    return AccountEntry(
      id: id,
      name: name,
      serverUrl: serverUrl,
      username: username,
      password: password,
      token: token,
      relayMode: relayMode,
      accessCode: accessCode,
      fnId: fnId,
      createdAt: createdAt ?? DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}
