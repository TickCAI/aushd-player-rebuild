# OpenList 连接失败修复：鉴权与播放地址改动记录

## 问题现象
用户在存储源里添加 OpenList/AList（`http://10.0.0.1:5244/dav`），点「测试连接」报错：
`连接失败：Bad state: HTTP 401`。此前统一配置表单本身能保存、能显示，但连不上服务器。

## 根因（对照朋友在真实服务器上验证过的 addon.js）
原实现有三处与 OpenList/AList 真实协议不一致，任意一处都会导致 401：

1. **鉴权头格式错误**：原代码发 `Authorization: Bearer <token>`；OpenList/AList 要求**裸 token**：`Authorization: <token>`（addon.js 第 38 行 `/api/fs/list` 就是裸 token）。
2. **播放地址错误**：原代码用 `GET /d/<path>` 直接播放；`/d/` 需要 `sign`+`expire`，裸调返回 `401 expire missing`（addon.js 头部注释明确指出）。正确做法是 `POST /api/fs/get` 取 `data.raw_url`——这是带签名的直链，支持 HTTP Range，且不需要任何鉴权头。
3. **Base URL 带上了 WebDAV 端点**：用户填的 `/dav` 是 WebDAV 路径，不是 REST API 根；原代码在其后拼 `/api/fs/list` → 打到 `/dav/api/fs/list`，404/401。表单提示里还写着「例如 /dav」，误导用户。
4. **附带**：懒登录缺失——若从搜索页直接进入播放、没有先扫描目录，token 不会被获取。

## 改动（分支 feat/openlist-auth-fix，commit 23bb6b7）
### `lib/data/mount/openlist_vfs.dart`
- `_base()` 去掉结尾 `/dav`（以及尾斜杠），REST 路径始终基于服务器根。
- `_headers` 改为裸 token：`{'Authorization': _token}`（删除 `Bearer ` 前缀）。
- 构造保留 `username`，新增 `ensureToken()`：有账号密码但无 token 时懒登录（`POST /api/auth/login` → `data.token`），`list`/`check`/`getRaw` 前调用。
- 新增 `getRaw(path)`：`POST /api/fs/get` → `data.raw_url`，返回带签名直链。
- `resolvePlayableUrl(path)` 改为优先 `getRaw`，失败回退原 `/d/<path>`（公共实例仍可播）。

### `lib/data/mount/mount_service.dart`
- `toVfs()` 构造 OpenListVfs 时把 `username` 透传进去（支撑懒登录）。

### `lib/l10n/app_en.arb` / `app_zh.arb`
- `storagePathHint` 从「例如 /dav」改为「反代子路径，如 /openlist（服务器根路径请留空）」。
- `storageFormHint` 改为明确提示：OpenList/AList 填服务器**根地址（不要带 /dav）**和账号密码，token 自动获取。

### `test/mount_vfs_test.dart`
- 修正原断言：鉴权头为裸 token（`tk`）而非 `Bearer tk`。
- 新增 4 个用例：`/dav` 从 REST base 剥离、`/api/fs/get` 取签名 raw_url、无签名时回退 `/d/`、有账号密码时懒登录并带 token 请求。

## 验证
- CI run `46093570934` **全绿 6/6**：Validate / Test+compile / Build androidtv·windows·linux / Publish 全部 success。
- l10n 双文件 JSON 校验通过（en 57388B / zh 44060B）。

## 诚实边界
- CI 不连真实 OpenList 服务器；鉴权格式与播放地址按朋友在真实服务器验证过的 addon.js 对齐，需真机复测确认。
- 若用户的 OpenList 挂在反代子路径（如 `/openlist`），应把该子路径填进「路径」字段，而不是 `/dav`；根路径实例请留空路径。
- FTP/FTPS 仍是纯 Dart 实现，不支持 FTPS 隐式加密与主动模式；Android 端直播链路为 no-op。

## 版本链
…→ 五问题修复 855081c → 存储源统一表单 e3d0a3b → **OpenList 鉴权修复（本改动）**。
