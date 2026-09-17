import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../state/settings_fn_state.dart';
import '../../utils/cache_version_store.dart';
import '../../utils/page_cache_store.dart';
import '../db/dao/song_dao.dart';
import '../player_service.dart';
import 'account_entry.dart';
import 'api_client.dart';
import 'auth_service.dart';
import 'fn_connection_probe_service.dart';

/// 已保存账号列表管理（单例）
///
/// 现有 SharedPreferences key（feiniu_music_token / feiniu_server_url /
/// feiniu_relay_mode / fn_access_code / feiniu_username / feiniu_password /
/// fn_last_fnid）继续作为「当前激活账号槽位」——描述内存中已加载的账号。
/// 本类是已保存账号列表的唯一数据源，每次激活/切换都把所选账号的字段写入
/// 该槽位，让现有加载逻辑（tryLoadAuth、登录页自动填充、启动预热探测）无需改动。
class AccountStore {
  AccountStore._();

  static final AccountStore instance = AccountStore._();

  /// 已保存账号列表（有序，最近登录/创建的靠前）
  final ValueNotifier<List<AccountEntry>> accounts = ValueNotifier([]);

  /// 当前激活账号 id（与「激活槽位」保持一致）
  final ValueNotifier<String?> currentAccountId = ValueNotifier(null);

  static const String _prefsAccounts = 'feiniu_accounts_v1';
  static const String _prefsCurrentAccountId = 'feiniu_current_account_id';

  bool _initialized = false;

  /// 账号切换进行中：期间抑制 onSessionExpired(401) 触发的会话失效处理，
  /// 避免切换窗口内闪现登录页。
  bool _switching = false;

  bool get isInitialized => _initialized;

  AccountEntry? get currentAccount {
    final id = currentAccountId.value;
    if (id == null) return null;
    return byId(id);
  }

  AccountEntry? byId(String id) {
    for (final e in accounts.value) {
      if (e.id == id) return e;
    }
    return null;
  }

  /// 初始化：加载列表 + 首启迁移 + 校正当前账号。
  ///
  /// 需在 [AuthService.init]（已恢复激活槽位）之后调用；会自行确保
  /// [AppFnConnectionSettings] 已加载（读取安全码 / FNID）。
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    FeiNiuApiClient.instance.onSessionExpired = handleTokenExpired;
    await AppFnConnectionSettings.ensureLoaded();

    final prefs = await SharedPreferences.getInstance();
    await _loadAccounts(prefs);

    // 首启迁移：列表为空但激活槽位有有效会话 → 导入为第一个账号
    if (accounts.value.isEmpty) {
      final api = FeiNiuApiClient.instance;
      if (api.token.isNotEmpty && api.baseUrl.isNotEmpty) {
        final entry = AccountEntry(
          id: _generateId(),
          serverUrl: api.baseUrl,
          username: prefs.getString('feiniu_username') ?? '',
          password: prefs.getString('feiniu_password'),
          token: api.token,
          relayMode: api.relayMode,
          accessCode: AppFnConnectionSettings.accessCode,
          fnId: AppFnConnectionSettings.lastFnId,
          createdAt: DateTime.now(),
        );
        accounts.value = [entry];
        currentAccountId.value = entry.id;
      }
    }

    _reconcileCurrent();
    await _persist();
    // 合并历史重复账号：1.3.5 之前按 serverUrl::username 去重，FNID 账号
    // 每次重连换地址就新增一条，导致列表积累多个「同一 FNID」的条目。
    // 按 FNID 维度合并（保留 token 最新的），只影响已登录的 FNID 账号。
    await _mergeDuplicateFnidAccounts();
    if (kDebugMode) {
      debugPrint(
        '[AccountStore] init: ${accounts.value.length} account(s), '
        'current=${currentAccount?.displayName}',
      );
    }
  }

  @visibleForTesting
  Future<void> resetForTest() async {
    _initialized = false;
    accounts.value = [];
    currentAccountId.value = null;
    FeiNiuApiClient.instance.onSessionExpired = null;
  }

  Future<void> _loadAccounts(SharedPreferences prefs) async {
    final raw = prefs.getString(_prefsAccounts);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          accounts.value = decoded
              .whereType<Map<String, dynamic>>()
              .map(AccountEntry.fromJson)
              .toList();
        }
      } catch (_) {
        // 数据损坏则丢弃，视为无账号
      }
    }
    final cid = prefs.getString(_prefsCurrentAccountId);
    if (cid != null && cid.isNotEmpty) {
      currentAccountId.value = cid;
    }
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsAccounts,
      jsonEncode(accounts.value.map((e) => e.toJson()).toList()),
    );
    final cid = currentAccountId.value;
    if (cid == null) {
      await prefs.remove(_prefsCurrentAccountId);
    } else {
      await prefs.setString(_prefsCurrentAccountId, cid);
    }
  }

  /// 按 id 替换列表中的条目（无则追加），并通知。
  void _replaceInList(AccountEntry entry) {
    final list = List<AccountEntry>.from(accounts.value);
    final index = list.indexWhere((e) => e.id == entry.id);
    if (index >= 0) {
      list[index] = entry;
    } else {
      list.add(entry);
    }
    accounts.value = list;
  }

  /// 校正当前账号：id 无效时按「激活槽位匹配 → 列表第一个」回退。
  void _reconcileCurrent() {
    final list = accounts.value;
    if (list.isEmpty) {
      currentAccountId.value = null;
      return;
    }
    if (currentAccountId.value != null &&
        byId(currentAccountId.value!) != null) {
      return;
    }
    final api = FeiNiuApiClient.instance;
    if (api.baseUrl.isNotEmpty) {
      final activeIdentity =
          '${api.baseUrl.trim()}::${AuthService.instance.username.value ?? ''}';
      // 优先按 FNID 匹配（当前激活槽位带 FNID 时）：FNID 是稳定标识，
      // 探测地址会变，地址匹配可能落空。
      final activeFnId = AppFnConnectionSettings.lastFnId;
      if (activeFnId != null && activeFnId.isNotEmpty) {
        for (final e in list) {
          final eFnId = e.fnId;
          if (eFnId != null &&
              eFnId.isNotEmpty &&
              eFnId == activeFnId &&
              e.username == (AuthService.instance.username.value ?? '')) {
            currentAccountId.value = e.id;
            return;
          }
        }
      }
      for (final e in list) {
        if (e.identityKey == activeIdentity) {
          currentAccountId.value = e.id;
          return;
        }
      }
    }
    currentAccountId.value = list.first.id;
  }

  /// 合并历史重复的 FNID 账号条目（一次性的数据修复，非每次启动必做）。
  ///
  /// 1.3.5 之前 [identityKey] 按 `serverUrl::username` 去重，FNID 账号每次
  /// 重连探测到新地址（内网 IP / 公网 IP / 中继）就新增一条，列表会积累
  /// 多个同一 FNID 的条目。本方法把这些条目合并为一个：
  /// - 保留 [AccountEntry.token] 非空、否则 createdAt 最新的条目（最可能是
  ///   当前有效会话）；
  /// - 被删重复条目的自定义备注合并进保留条目；
  /// - 更新 `currentAccountId` 指向保留条目，避免悬空。
  ///
  /// 幂等：仅在检测到同一 `fnId + username` 有多条时才改动并持久化。
  Future<void> _mergeDuplicateFnidAccounts() async {
    final list = List<AccountEntry>.from(accounts.value);
    // 分组：fnId::username → 条目
    final byKey = <String, List<AccountEntry>>{};
    for (final e in list) {
      final fnId = e.fnId;
      if (fnId == null || fnId.isEmpty) continue;
      byKey.putIfAbsent('${fnId.trim()}::${e.username}', () => []).add(e);
    }
    final groups = byKey.values.where((g) => g.length > 1).toList();
    if (groups.isEmpty) return;

    // 每组的保留条目 + 被删重复条目集合 + 备注补丁（按保留条目 id）
    final removeIds = <String>{};
    final namePatch = <String, String>{};
    for (final group in groups) {
      final sorted = List<AccountEntry>.from(group)
        ..sort((a, b) {
          final aToken = a.token.isNotEmpty ? 1 : 0;
          final bToken = b.token.isNotEmpty ? 1 : 0;
          if (aToken != bToken) return bToken.compareTo(aToken);
          return b.createdAt.compareTo(a.createdAt);
        });
      final winner = sorted.first;
      // 保留条目无备注时，取被删条目中的第一个非空备注
      if (winner.name.isEmpty) {
        for (final dup in sorted.skip(1)) {
          if (dup.name.isNotEmpty) {
            namePatch[winner.id] = dup.name;
            break;
          }
        }
      }
      for (final dup in sorted.skip(1)) {
        removeIds.add(dup.id);
      }
    }

    final cid = currentAccountId.value;
    final nextList = <AccountEntry>[];
    for (final e in list) {
      if (removeIds.contains(e.id)) {
        // 被删条目是当前账号 → currentAccountId 指向保留条目
        if (e.id == cid) {
          final winner = groups
              .expand((g) => g)
              .firstWhere(
                (g) => !removeIds.contains(g.id) &&
                    g.fnId == e.fnId &&
                    g.username == e.username,
              );
          currentAccountId.value = winner.id;
        }
        continue;
      }
      final patchedName = namePatch[e.id];
      nextList.add(patchedName != null ? e.copyWith(name: patchedName) : e);
    }
    accounts.value = nextList;
    await _persist();
    if (kDebugMode) {
      debugPrint('[AccountStore] merged ${removeIds.length} duplicate FNID account(s)');
    }
  }

  // ── CRUD ────────────────────────────────────────────────────────────

  /// 新增或更新账号（按 [AccountEntry.identityKey] 去重）。
  ///
  /// 命中已有账号时：保留用户自定义备注 [AccountEntry.name]，但若本次传入的
  /// [AccountEntry.name] 非空则以本次为准（用户明确输入了新备注）；覆盖其余字段。
  /// 返回规范化后的条目。
  Future<AccountEntry> addOrUpdate(AccountEntry entry) async {
    final list = List<AccountEntry>.from(accounts.value);
    final index = list.indexWhere(
      (e) => e.identityKey == entry.identityKey,
    );
    AccountEntry canonical;
    if (index >= 0) {
      final existing = list[index];
      canonical = existing.copyWith(
        serverUrl: entry.serverUrl,
        username: entry.username,
        password: () => entry.password,
        token: entry.token,
        relayMode: entry.relayMode,
        accessCode: () => entry.accessCode,
        fnId: () => entry.fnId,
        // 本次明确输入了备注则以本次为准，否则保留已有自定义备注
        name: entry.name.isNotEmpty ? entry.name : null,
      );
      list[index] = canonical;
    } else {
      canonical = AccountEntry(
        id: entry.id.isNotEmpty ? entry.id : _generateId(),
        name: _uniqueAutoName(list, entry),
        serverUrl: entry.serverUrl,
        username: entry.username,
        password: entry.password,
        token: entry.token,
        relayMode: entry.relayMode,
        accessCode: entry.accessCode,
        fnId: entry.fnId,
        createdAt: DateTime.now(),
      );
      list.add(canonical);
    }
    accounts.value = list;
    await _persist();
    return canonical;
  }

  /// 重命名账号备注。
  Future<void> rename(String id, String name) async {
    final list = List<AccountEntry>.from(accounts.value);
    final index = list.indexWhere((e) => e.id == id);
    if (index < 0) return;
    list[index] = list[index].copyWith(name: name.trim());
    accounts.value = list;
    await _persist();
  }

  /// 编辑账号服务器标识。
  ///
  /// 自动识别输入内容：
  /// - 以 http/https 开头 → 视为服务器地址，更新 [AccountEntry.serverUrl] 并清除 FNID；
  /// - 否则 → 视为 FNID，更新 [AccountEntry.fnId]（去掉可能的 .5ddd.com 后缀）。
  ///
  /// token 绑定服务器/FNID，修改后清空该账号 token（需重新登录）。
  Future<void> updateServerUrl(String id, String input) async {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return;
    final list = List<AccountEntry>.from(accounts.value);
    final index = list.indexWhere((e) => e.id == id);
    if (index < 0) return;
    final current = list[index];

    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      final normalized = _normalizeUrl(trimmed);
      if (normalized.isEmpty || current.serverUrl == normalized) return;
      list[index] = current.copyWith(
        serverUrl: normalized,
        fnId: () => null,
        token: '',
      );
    } else {
      // 视为 FNID，去掉可能带的后缀
      var fnId = trimmed;
      if (fnId.endsWith('.5ddd.com')) {
        fnId = fnId.substring(0, fnId.length - '.5ddd.com'.length);
      }
      if (current.fnId == fnId) return;
      list[index] = current.copyWith(fnId: () => fnId, token: '');
    }
    accounts.value = list;
    await _persist();
  }

  /// 删除账号。删除的是当前账号时，currentAccountId 回退到剩余第一个或 null。
  Future<void> remove(String id) async {
    final list = List<AccountEntry>.from(accounts.value);
    final index = list.indexWhere((e) => e.id == id);
    if (index < 0) return;
    final isCurrent = currentAccountId.value == id;
    list.removeAt(index);
    accounts.value = list;
    if (isCurrent) {
      if (list.isEmpty) {
        currentAccountId.value = null;
      } else {
        // 删除的是当前账号 → 激活账号将切到剩余第一个。先清空旧账号数据缓存
        // （顺序：清缓存 → 再设 currentAccountId，避免新外壳读到旧缓存），
        // 重建后的界面直接渲染新账号数据。
        await _clearDataCaches();
        currentAccountId.value = list.first.id;
      }
    }
    await _persist();
  }

  /// 登录成功后捕获账号并入列表（供登录页调用）。
  ///
  /// 登录成功意味着激活账号变更（可能换了服务器/账号），先清空上一账号的
  /// 数据缓存（内存 + SQLite api_cache）并停止播放，避免新账号首页/列表
  /// 先渲染旧账号缓存、点歌因服务器不匹配而无法播放。
  Future<AccountEntry> persistLogin({
    required String serverUrl,
    required String username,
    required String password,
    required bool relayMode,
    String? fnId,
    String name = '',
    String? role,
  }) async {
    final api = FeiNiuApiClient.instance;
    final entry = await addOrUpdate(
      AccountEntry(
        id: _generateId(),
        name: name,
        serverUrl: serverUrl.isNotEmpty ? serverUrl : api.baseUrl,
        username: username,
        password: password.isNotEmpty ? password : null,
        token: api.token,
        relayMode: relayMode,
        accessCode: AppFnConnectionSettings.accessCode,
        fnId: fnId,
        role: role ?? AuthService.instance.role.value,
        createdAt: DateTime.now(),
      ),
    );
    // 登录成功意味着激活账号变更（可能换了服务器/账号），先清空上一账号的
    // 数据缓存（内存 + SQLite api_cache）并停止播放，避免新账号首页/列表
    // 先渲染旧账号缓存、点歌因服务器不匹配而无法播放。
    // 注意顺序：必须在本方法里先清缓存再设 currentAccountId——设 currentAccountId
    // 会触发门控重建外壳、新首页立即读 SQLite 缓存，若缓存未清会先渲染旧数据。
    await _clearDataCaches();
    currentAccountId.value = entry.id;
    // 地址账号登录（无 fnId）时清掉残留的 fn_last_fnid，避免启动预热用
    // 上一个 FNID 账号的标识去探测/回写，把地址账号误改成 FNID 身份。
    await _syncLastFnIdFor(entry.fnId);
    await _persist();
    return entry;
  }

  /// 登录成功后将结果写回指定账号（编辑账号场景，保留原 id 与自定义备注）。
  ///
  /// 用户改完服务器地址/用户名/备注后重新登录，用新身份更新该账号：
  /// - 覆盖 serverUrl / username / token / relayMode / accessCode / fnId / password；
  /// - 若 [name] 非空则以新备注为准，否则保留原有自定义备注。
  /// 若指定 id 不存在则退化为 [persistLogin] 的新增逻辑。
  Future<AccountEntry> persistLoginForEdit({
    required String id,
    required String serverUrl,
    required String username,
    required String password,
    required bool relayMode,
    String? fnId,
    String name = '',
    String? role,
  }) async {
    final api = FeiNiuApiClient.instance;
    final list = List<AccountEntry>.from(accounts.value);
    final index = list.indexWhere((e) => e.id == id);
    if (index < 0) {
      return persistLogin(
        serverUrl: serverUrl,
        username: username,
        password: password,
        relayMode: relayMode,
        fnId: fnId,
        name: name,
        role: role,
      );
    }
    final existing = list[index];
    final updated = existing.copyWith(
      serverUrl: serverUrl.isNotEmpty ? serverUrl : api.baseUrl,
      username: username,
      password: () => password.isNotEmpty ? password : null,
      token: api.token,
      relayMode: relayMode,
      accessCode: () => AppFnConnectionSettings.accessCode,
      fnId: () => fnId,
      role: role ?? AuthService.instance.role.value ?? existing.role,
      // 本次输入了备注则以本次为准，否则保留原有自定义备注
      name: name.isNotEmpty ? name : null,
    );
    list[index] = updated;
    accounts.value = list;
    // 编辑账号重新登录后服务器地址/身份可能已变，先清空旧数据缓存
    // （顺序同上：须在设 currentAccountId 触发外壳重建前清完），
    // 避免新账号首页/列表渲染旧服务器数据。
    await _clearDataCaches();
    currentAccountId.value = id;
    // 地址账号（无 fnId）时清残留 fn_last_fnid，避免身份被改写。
    await _syncLastFnIdFor(updated.fnId);
    await _persist();
    return updated;
  }

  // ── 激活 / 切换 ─────────────────────────────────────────────────────

  /// 账号变更前清空数据缓存：停止播放、清空内存与 SQLite 层 API 缓存。
  ///
  /// 切换账号 / 登录新账号 / 编辑账号后，旧账号的缓存数据（首页 dashboard、
  /// 列表页等）与新账号服务器不匹配：先渲染旧数据、点歌因服务器上没有对应
  /// 歌曲而无法播放。此方法统一清理，让重建后的页面重拉新账号数据。
  Future<void> _clearDataCaches() async {
    // 停止播放（含清队列/持久化播放状态）
    try {
      await PlayerService.instance.stopAndClear();
    } catch (_) {}
    // 清空内存 API 缓存层
    PageCacheStore.instance.clearAll();
    // 清空 SQLite api_cache 表（不同服务器内容不串）
    try {
      await SongDao.instance.clearApiCache();
    } catch (_) {}
    // 触发缓存版本变更，令依赖缓存版本的页面重新拉取
    CacheVersionStore.instance.bump('song_library');
  }

  /// 把 [entry] 写入「当前激活账号槽位」。
  ///
  /// 同步 API 客户端（token/serverUrl/relay）、安全码、连接信息与 AuthService
  /// 各 notifier，使现有加载逻辑与请求头立即生效。
  Future<void> activate(AccountEntry entry) async {
    final api = FeiNiuApiClient.instance;
    if (entry.token.isNotEmpty) {
      await api.setAuth(entry.serverUrl, entry.token, relayMode: entry.relayMode);
    } else {
      await api.clearAuth();
      await api.setBaseUrl(entry.serverUrl);
      api.setRelayMode(entry.relayMode);
    }
    final prefs = await SharedPreferences.getInstance();
    // 无 token 时也写服务器地址/中继标记，保证登录页自动填充与预热探测一致
    await prefs.setString('feiniu_server_url', entry.serverUrl);
    await prefs.setBool('feiniu_relay_mode', entry.relayMode);
    if (entry.username.isNotEmpty) {
      await prefs.setString('feiniu_username', entry.username);
    }
    if (entry.password != null && entry.password!.isNotEmpty) {
      await prefs.setString('feiniu_password', entry.password!);
    } else {
      await prefs.remove('feiniu_password');
    }

    await AppFnConnectionSettings.setAccessCode(entry.accessCode);
    await AppFnConnectionSettings.restoreConnection(
      url: entry.serverUrl,
      isRelay: entry.relayMode,
      fnId: entry.fnId,
      method: (entry.fnId != null && entry.fnId!.isNotEmpty)
          ? 'FNID 连接'
          : '手动连接',
    );

    AuthService.instance.serverUrl.value = entry.serverUrl;
    AuthService.instance.username.value = entry.username;
    AuthService.instance.isLoggedIn.value = entry.token.isNotEmpty;

    // 地址账号（无 FNID）保存的是用户填写的地址；若为 HTTP 且服务器「HTTP
    // 强制跳转 HTTPS」，把内存中的活动连接升级为 HTTPS（不持久化，账号仍存
    // 填写值，HTTP/HTTPS 各自独立），避免切换后封面/音频因重定向丢 Cookie
    // 失败。FNID 账号由完整探测处理，此处不干预。
    if ((entry.fnId == null || entry.fnId!.isEmpty) &&
        entry.token.isNotEmpty &&
        entry.serverUrl.startsWith('http://')) {
      unawaited(
        FnConnectionProbeService.instance
            .upgradeLiveConnectionToHttpsIfRedirects(),
      );
    }
  }

  /// 还原备份后设为当前账号：激活会话槽位（token/服务器/中继/安全码/FNID）
  /// 并标记为当前，使备份里的登录态在还原后保持，无需手动重新点选。
  ///
  /// 与 [switchTo] 的区别：不做数据缓存清理、不自动重登；仅回填会话槽位。
  Future<void> activateForRestore(AccountEntry entry) async {
    await activate(entry);
    currentAccountId.value = entry.id;
    await _persist();
  }

  /// 切换到另一已保存账号：停止播放 → 清空缓存 → 激活 → 设当前。
  ///
  /// 目标账号 token 有效时直接切换；token 失效/为空但保存了密码时，
  /// 自动用密码重新登录验证后再切换（不跳登录页）。无法自动登录的失败
  /// 场景返回 false 且**不置空当前会话**（`isLoggedIn` 保持 true），由调用方
  /// 提示「需登录」，避免门控闪现登录页。
  ///
  /// 返回切换是否成功（失败返回 false，不抛出）。
  Future<bool> switchTo(String id) async {
    final entry = byId(id);
    if (entry == null || id == currentAccountId.value) return false;
    if (_switching) return false;
    _switching = true;
    try {
      // 账号切换前先清空上一账号的数据缓存并停止播放
      await _clearDataCaches();

      // token 失效/为空但有密码 → 自动重新登录验证
      if (entry.token.isEmpty) {
        final password = entry.password;
        if (password == null || password.isEmpty) {
          // 无密码可用，无法自动登录：不切换、不置空当前会话（避免门控闪现
          // 登录页），返回 false 由页面提示「需登录」，停留在当前账号。
          return false;
        }
        try {
          final deviceId = AuthService.instance.getOrCreateDeviceId();
          await FeiNiuApiClient.instance.setBaseUrl(entry.serverUrl);
          if (entry.relayMode) {
            FeiNiuApiClient.instance.setRelayMode(true);
          }
          final response = await FeiNiuApiClient.instance.login(
            entry.username,
            password,
            deviceId,
            relayMode: entry.relayMode,
          );
          // 用新 token 更新账号并激活
          final refreshed = entry.copyWith(
            token: response.userToken,
            username: response.username ?? entry.username,
          );
          _replaceInList(refreshed);
          await activate(refreshed);
          currentAccountId.value = refreshed.id;
          await _persist();
          return true;
        } catch (_) {
          // 自动登录失败：恢复当前账号连接，不置空会话（避免闪现登录页）。
          final currentId = currentAccountId.value;
          final current = currentId == null ? null : byId(currentId);
          if (current != null) {
            await activate(current);
          }
          return false;
        }
      }

      await activate(entry);
      currentAccountId.value = entry.id;
      await _persist();
      if (kDebugMode) {
        debugPrint('[AccountStore] Switched to ${entry.displayName}');
      }
      return true;
    } finally {
      _switching = false;
    }
  }

  /// 把激活槽位中的连接信息（探测得到的 URL/中继/安全码）回写当前账号。
  ///
  /// 仅更新连接字段，绝不动 token。供启动预热与自动重连成功后调用，
  /// 使账号列表与「当前实际使用的连接」保持一致。
  ///
  /// 注意：**绝不改变账号的 FNID 身份**。当前账号是地址账号（无 FNID）时，
  /// 即使 `fn_last_fnid` 有残留值，也不给它注入 FNID——否则地址账号的
  /// [AccountEntry.identityKey] 会从 `serverUrl::username` 变成
  /// `fnid:xxx::username`，与同用户的 FNID 账号冲突并被合并（账号丢失）。
  Future<void> syncActiveAccountConnection() async {
    final current = currentAccount;
    if (current == null) return;
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString('feiniu_server_url');
    final relay = prefs.getBool('feiniu_relay_mode') ?? false;
    final code = prefs.getString('fn_access_code');
    // 仅当当前账号原本就是 FNID 账号时才更新其 FNID（探测可能换新地址但
    // FNID 稳定）；地址账号保持无 FNID，避免身份被改写导致误合并。
    final hasFnId = current.fnId != null && current.fnId!.isNotEmpty;
    final fnId = hasFnId ? prefs.getString('fn_last_fnid') : null;
    final next = current.copyWith(
      serverUrl: (url != null && url.isNotEmpty) ? url : current.serverUrl,
      relayMode: relay,
      accessCode: () => code,
      fnId: () => (fnId == null || fnId.isEmpty) ? null : fnId,
    );
    if (next == current) return;
    final list = List<AccountEntry>.from(accounts.value);
    final index = list.indexWhere((e) => e.id == current.id);
    if (index < 0) return;
    list[index] = next;
    accounts.value = list;
    await _persist();
  }

  /// 处理 token 失效（401 / INVALID TOKEN）。
  ///
  /// 优先尝试用当前账号保存的密码静默重新登录换取新 token，保持会话不中断；
  /// 无密码或重登失败时强制登出——清空激活槽位 token、翻转 [AuthService.isLoggedIn]
  /// 为 false，让 `_AppStartupGate` 自动回到登录页。登出会保留
  /// `feiniu_server_url` / `feiniu_username`（沿用 [clearAuth] 约定），登录页
  /// 仍能预填，用户只需重新输入密码。
  ///
  /// 返回是否已恢复登录（true = 静默重登成功；false = 已登出，需用户重新登录）。
  ///
  /// 调用方应在识别到 401/INVALID TOKEN 时调用（如 [FeiNiuApiClient] 拦截器）。
  Future<bool> handleTokenExpired() async {
    final current = currentAccount;
    final api = FeiNiuApiClient.instance;
    if (current == null) return false;

    // 账号切换进行中：401 可能来自切换前的遗留请求，不处理会话失效，避免闪现登录页。
    if (_switching) return false;

    // 1) 尝试用保存的密码静默重登（与 switchTo 的自动登录一致）
    if (current.token.isNotEmpty && current.password != null && current.password!.isNotEmpty) {
      try {
        final deviceId = AuthService.instance.getOrCreateDeviceId();
        await api.setBaseUrl(current.serverUrl);
        if (current.relayMode) api.setRelayMode(true);
        final response = await api.login(
          current.username,
          current.password!,
          deviceId,
          relayMode: current.relayMode,
        );
        final refreshed = current.copyWith(token: response.userToken);
        _replaceInList(refreshed);
        await activate(refreshed);
        await _persist();
        return true;
      } catch (_) {
        // 重登失败 → 落到登出分支
      }
    }

    // 2) 无密码或重登失败 → 强制登出（门控自动回登录页，凭据保留供预填）
    if (current.token.isNotEmpty) {
      final list = List<AccountEntry>.from(accounts.value);
      final index = list.indexWhere((e) => e.id == current.id);
      if (index >= 0) {
        list[index] = current.copyWith(token: '');
        accounts.value = list;
      }
    }
    await api.clearAuth();
    await api.setBaseUrl(current.serverUrl);
    api.setRelayMode(current.relayMode);
    // 保留用户名/密码供登录页自动填充（clearAuth 已保留 server_url）
    if (current.username.isNotEmpty) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('feiniu_username', current.username);
      if (current.password != null && current.password!.isNotEmpty) {
        await prefs.setString('feiniu_password', current.password!);
      }
    }
    AuthService.instance.isLoggedIn.value = false;
    await _persist();
    return false;
  }

  // ── 工具 ────────────────────────────────────────────────────────────

  /// 让 `fn_last_fnid` 与账号的 FNID 身份保持一致。
  ///
  /// [fnId] 为空（地址账号）时移除残留的 `fn_last_fnid`，避免启动预热
  /// 用上一个 FNID 账号的标识去探测/回写，把地址账号误改成 FNID 身份
  /// 导致与同用户的 FNID 账号合并；非空（FNID 账号）时写入，供预热复用。
  static Future<void> _syncLastFnIdFor(String? fnId) async {
    await AppFnConnectionSettings.restoreConnection(
      url: FeiNiuApiClient.instance.baseUrl,
      isRelay: FeiNiuApiClient.instance.relayMode,
      fnId: (fnId == null || fnId.isEmpty) ? null : fnId,
      method: (fnId == null || fnId.isEmpty) ? '手动连接' : 'FNID 连接',
    );
  }

  static String _generateId() {
    final random = Random();
    return List.generate(
      16,
      (_) => random.nextInt(256),
    ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// 规范化服务器地址：去掉 /music/api/v1 后缀与末尾斜杠。
  static String _normalizeUrl(String url) {
    var u = url.replaceAll(RegExp(r'/music/api/v1/*$'), '');
    u = u.trim();
    while (u.endsWith('/')) {
      u = u.substring(0, u.length - 1);
    }
    return u;
  }

  /// 为新增账号生成唯一自动名（默认「飞牛音乐」，重名追加 " (2)"）。
  static String _uniqueAutoName(List<AccountEntry> list, AccountEntry entry) {
    final base = entry.displayName;
    final used = list
        .map((e) => e.name)
        .where((n) => n.isNotEmpty)
        .toSet();
    if (!used.contains(base)) return base;
    var i = 2;
    while (used.contains('$base ($i)')) {
      i++;
    }
    return '$base ($i)';
  }
}
