# AusHD Player — 全屏崩溃问题交接文档

> 面向接手的 AI / 开发者。目标：在**全新仓库**里继续解决 Windows 播放时全屏切换崩溃的问题。
> 交接时间：2026-11-17 17:00。基线代码：回到 **v1.0.9 + UI 整改**（commit `4e27162`）。

---

## 0. 一句话现状

Windows 桌面播放器在**播放视频 + 切入/切出全屏**时进程崩溃（`0xC0000005`）。从 v1.0.8 到 v1.0.14 连续多版尝试均未根治，**用户已决定全部回退**，换一个 AI 从零重新分析。当前代码已回到崩溃问题出现前的 v1.0.9（保留 UI 整改），云端旧仓库 v1.0.10~v1.0.14 的 Release 和 tag 已删除。

**重要：不要假设之前的结论是对的。** 下面记录的"已尝试方案"多数被实测证伪，请把它们当作"排除项"，用新证据独立判断。

---

## 1. 项目概况

| 项 | 值 |
| --- | --- |
| 项目名称 | AusHD Player（内部包名仍为 `zerk_play`，未做完整重命名） |
| 技术栈 | Flutter 3.50 / Dart 3.14，Windows 桌面为主，兼顾 Linux / Android TV |
| 上游 | fork 自 `florinp93/Zerk-Play-2.0`（GPL v3.0，2026-11-12 基于 `a20b48f` / 2beta9） |
| 主程序 | `zerk_play.exe`（Windows），安装包名 `AusHD-Player-<ver>-setup.exe` |
| 播放器内核 | **同进程内嵌 libmpv**：Dart FFI `DynamicLibrary.open('libmpv-2.dll')`，mpv 视频窗口 attach 到 Flutter 窗口 |
| Windows 原生层 | C++ Runner：`windows/runner/`（`main.cpp` / `native_window.cpp` / `video_host.cpp` / `flutter_window.cpp`） |
| 渲染 | Flutter 用 ANGLE/D3D11；mpv 用 `vo=gpu gpu-api=opengl gpu-context=win`（默认）或 `d3d11` |
| 配置文件 | `lib/playback/mpv/mpv_options.dart`（mpv 启动参数）、`lib/app/app_settings.dart`（视图/GPU 设置） |
| 构建 | **全部走 GitHub Actions 云端**（本地 Windows 因 symlink 权限无法构建 Flutter）；`.github/workflows/build.yml` |

### 关键目录
- `lib/playback/mpv/` — mpv FFI 封装（`libmpv.dart` / `mpv_player.dart` / `mpv_backend.dart` / `mpv_options.dart` / `video_host.dart`）
- `windows/runner/` — 原生窗口/全屏/HDR/DPI 逻辑
- `assets/mpv/zerk_osd.lua` — OSD 控制栏脚本（同进程模式下由 mpv 加载）
- `lib/ui/player/` — Flutter 侧播放器 UI
- `test/` — Dart 单测（当前 8 个测试文件）
- `docs/` — `A路径-首次构建与部署.md`、`本地化术语表.md`

---

## 2. 核心问题：Windows 全屏播放崩溃

### 现象
- 播放视频（尤其 4K / HDR）时切入或切出全屏，进程直接崩溃退出。
- 并非只在全屏发生：日志显示崩溃前往往有播放/窗口尺寸变化；一度怀疑是"全屏 frame churn"。
- **用户的朋友在另一台机器用 v1.0.9 也复现**，说明不是单一机器个例。
- v1.0.10~v1.0.14 的多轮修复均未解决，用户最终放弃该路线。

### 崩溃签名（自抓 minidump，v1.0.11 引入的诊断）
| 时间 | 异常 | 地址 | 参数 | 解读 |
| --- | --- | --- | --- | --- |
| 11:19:42 | `0xC0000005` | `0x0` | `[0]=0x8, [1]=0x0` | **执行违例**：`param[0]=8` 表示 DEP/execute violation，试图在空地址 `0x0` 执行代码 → 典型**空函数指针 / 空 vtable 调用** |
| 13:00:37 | `0xC0000005` | `0x7FF863A4AA83` | `[0]=0x1, [1]=0x24` | **读取违例**：读 `0x24` 处内存失败，地址落在某模块内 |
| 14:26:36 | `0xC0000005` | 同上 | 同上 | 与 13:00 同类 |

> 结论倾向：不是单纯的 D3D11/AMD UMD 崩溃（那样地址应落在 `amdxx64.dll` 内）。地址 `0x0` 的执行违例更像是**某个回调/vtable 指针为 nullptr 被调用**，Flutter 与 mpv 两个渲染栈在同一进程内共存时的生命周期/初始化竞态是主要嫌疑。**但这只是假设，未证实**——请从 dump 栈回溯独立验证。

### 环境特征（来自 `aushd-env-*.txt`，重要）
- 系统 DPI：`192`（200% 缩放）；主显示器 `\\.\DISPLAY1` 2880×1800，`dpi=192,192`
- GPU：`AMD Radeon 780M`（`\\.\DISPLAY1` attached），另有 `\\.\DISPLAY2~5`
- **10 个 `GameViewer Virtual Display Adapter` 虚拟显示器**（`\\.\DISPLAY6~15`，均未 attached）
- Vulkan 隐式层注入：`D:\steam\SteamOverlayVulkanLayer64.json`、`SteamFossilizeVulkanLayer64.json`（Steam overlay）
- 诊断开关（均未设置）：`AUSHD_VIDEO_CHILD`、`AUSHD_ANGLE_PLATFORM`、`ANGLE_DEFAULT_PLATFORM`、`VK_LOADER_LAYERS_DISABLE`

> 环境非常特殊（200% DPI + 4K + 多虚拟显示器 + Steam Vulkan 注入）。**任何复现/修复都要考虑这些变量**，不要只在默认环境推理。

---

## 3. 已尝试方案与结论（按版本时间线，全部为"排除项"）

| 版本 | commit | 方案 | 结果 |
| --- | --- | --- | --- |
| v1.0.8 | `5461bb1` | 把 Windows 播放从崩溃的 AMD D3D11 路径切到 opengl/win | 仍崩 |
| v1.0.9 | `3203d5d` | 停止触发 AMD 驱动故障的 fullscreen frame churn（`WS_CHILD` + 尺寸同步） | **仍崩**（基线，朋友也复现） |
| v1.0.10 | `4e27162` | UI 整改（媒体库卡片缩小、控制栏压缩、合集中文过滤、TV 横屏收口） | 与崩溃无关，已保留 |
| v1.0.10 | `3110f58` | **Phase B**：视频窗口从 `WS_CHILD` 改为 owned `WS_POPUP`，全屏切换加 180ms 串行化 | 仍崩；只拆了窗口树，没拆进程 |
| v1.0.10/11 | `62c7bad`/`3e0de7e` | 新增 minidump + 环境快照自抓（`crash_dump.cpp` + `MiniDumpWriteDump`） | 诊断价值高，定位到 `0x0` 执行违例；**崩溃路径内严格禁止堆分配** |
| — | （未合并） | **换内核 mpv-Yaozhi**（`Yaozhil/mpv-Yaozhi`） | **不可行**：该仓库是完整播放器整合包，releases 只有 `Yaoplayer-*.7z/.exe`，**不含 `libmpv-2.dll`**。`Yaoplayer.exe` 虽导出 58 个 `mpv_*` 符号，但作为 DLL 加载后 `mpv_create()` 直接 access violation（EXE 被当 DLL 加载不会正常初始化 CRT）。已放弃 |
| v1.0.12 | `5374de5` | **进程隔离**：独立 `mpv.exe` + JSON IPC named pipe + 跨进程 `--wid` + 崩溃自动拉起（`MpvIpcPlayer` / `MpvPipeTransport` / `mpv_ipc_protocol.dart`） | 视频能播，但 OSD 控制栏全无；连修两版后用户仍放弃整条路线 |
| v1.0.13 | `d820b59` | 修 OSD：① pipe 写命令 `codeUnits & 0xFF` 把中文截坏（UTF-16→单字节），含 `0x0A` 的码元切断 JSON 帧 → 改 `utf8.encode`；② mpv 的 script-message 事件名是 `client-message` 而非 `message` → 两者都接受 | OSD 仍未出现（非主因） |
| v1.0.14 | `198195d` | 修 OSD：命令队列——`create()` 异步启动 mpv 未连上 pipe 时 `load-script` 被静默丢弃 → pipe 就绪后 flush；崩溃重启重放启动命令 | 用户最终决定回退，未再验证 |

### 从失败中提炼的教训
1. **不要再试"换 mpv 内核/换 DLL"** —— mpv-Yaozhi 路线已证伪，官方 `libmpv-2.dll` 是唯一现实的库来源。
2. **不要只看"CI 全绿"** —— v1.0.12 进程隔离版需要额外的 `mpv.exe`，CI 打包链路正确但运行时 OSD 全无。功能验证必须真机。
3. **同进程 FFI 的 OSD 依赖 `load-script` + `script-message` 双向通道**；一旦改进程模型，这条链路全部要重建，坑很多。
4. **本地无法构建**：Windows 未开开发者模式/未提权，Flutter 插件 symlink 创建失败（`Building with plugins requires symlink support`）。必须云端构建。
5. **dump 是最有价值的证据**：崩溃路径内只能用栈缓冲 + `WriteFile`，任何堆分配都可能在堆已损坏时二次崩溃。

---

## 4. 当前代码状态（交接基线）

- **分支**：`main`，指针 = `4e27162`（"UI 整改：媒体库卡片缩小、控制栏压缩、合集中文过滤、TV 横屏收口"）
- **版本**：三处均为 `1.0.9`（`lib/app/release.dart` / `pubspec.yaml` / `installer/zerk_play.iss`）
- **CI 已恢复原生**：`build.yml` 的 `Fetch libmpv (Windows)` 只下载 `mpv-dev-x86_64-*` 里的 `libmpv-2.dll` 到 `windows/libs/`；**没有**隔离播放器 `mpv.exe` 的 stage 步骤
- **播放模式**：同进程 FFI（`MpvPlayer`），无 IPC / 无 named pipe / 无 `crash_dump.cpp`
- **本地备份分支**：`backup/pre-rollback-1.0.14`（指向原 v1.0.14 commit `198195d`），**包含所有失败版本的代码**，需要研究进程隔离/诊断实现时可 `git checkout backup/pre-rollback-1.0.14`。该分支仅在本地，未推送。
- 另一本地分支 `ui-redesign`（历史遗留）。

**云端旧仓库**（`TickCAI/aushd-player`）现状：main 已强制回退到 `4e271624cfc2`，tag/Release 只剩 `v1.0.0`~`v1.0.9`，v1.0.10~v1.0.14 全部删除。

---

## 5. 证据文件清单（均在用户机器本机）

日志目录：`C:\Users\Administrator\AppData\Roaming\AusHD\AusHD Player\logs\`

**minidump + 摘要**（配合 `crash_dump.cpp` 自抓）：
- `aushd-crash-20261117-111942.dmp` / `.txt` — 地址 `0x0` 执行违例（最有价值）
- `aushd-crash-20261117-130037.dmp` / `.txt` — 读取违例
- `aushd-crash-20261117-142636.dmp` / `.txt` — 读取违例

**环境快照**：`aushd-env-20261117-*.txt`（记录了 DPI/显示器/Vulkan 层/诊断开关）

**应用日志**（UTF-16LE 编码，读时 `tr -d '\000'`）：
- `aushd-20261117-165547.log` — 最后一组 v1.0.13 实测，16:56 播放 4K HDR（`3840x1600 hevc 60fps HDR10`），`VO: [gpu]` 正常出帧，16:56:54 `exit requested`（用户正常退出，非崩溃）；但 OSD 报 `did not report ready within 3 s`
- `aushd-20261117-142420.log` — v1.0.13 实测，OSD 未 ready
- `aushd-20261117-125814.log` — v1.0.12 实测，中文 JSON 被截断（malformed JSON）

**mpv 详细日志**：`mpv-20261117-*.log`，尤其
- `mpv-20261117-142554.log` — 含 `Setting option 'load-scripts' = 'no'`、`Can't find script 'zerk_osd'`，是定位"启动竞态致 load-script 丢失"的关键
- `mpv-20261117-165622.log` — 最后一次实测的 mpv 侧日志

**朋友机器的 1.0.9 崩溃日志压缩包**：`C:\Users\Administrator\Downloads\logs.7z`

> 分析 dump 建议用 WinDbg `!analyze -v`，重点看 faulting thread 的调用栈，确认 `0x0` 执行违例发生在哪个组件的回调/vtable。

---

## 6. 构建与发布流程（新仓库照此配置）

### GitHub Actions（`.github/workflows/build.yml`）
- **触发方式**：推送 `v*` tag，或手动 `workflow_dispatch`（参数 `tag`、`skip_distribution`）
- **两种模式**：
  - tag push / 手动且 `skip_distribution=false` → 完整发布（需 `DIST_URL` 等 secret，创建 Release 并登记到分发服务）
  - 手动且 `skip_distribution=true`（默认）→ **build-only**，不需要任何 secret，产物仅作本地试用
- **当前环境 `DIST_URL` secret 缺失** → tag push 会 preflight 失败。**请用 build-only dispatch**。
- **Secrets**：`DIST_URL` / `HUB_URL` / `ADMIN_TOKEN`（新仓库如需完整发布需重新配置）
- 新仓库若需要 TPDB/TMDB key 探测，另有 `.github/workflows/tmdb-check.yml`

### 触发 build-only 构建的方式（本机已验证）
```bash
# 凭证来自 Windows Credential Manager（git credential.helper=manager，用户 TickCAI）
TOKEN=$(printf "protocol=https\nhost=github.com\n\n" | git credential fill 2>/dev/null | grep '^password=' | head -1 | cut -d= -f2-)
curl -X POST -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/<OWNER>/<REPO>/actions/workflows/build.yml/dispatches" \
  -d '{"ref":"main","inputs":{"tag":"v1.0.9","skip_distribution":true}}'
```

### 网络 / 推送注意事项（本机环境特有，很关键）
- **git 协议通道不稳定**：`github.com:443` 常 `Recv failure: Connection was reset` 或代理 CONNECT 502；但 `api.github.com` 直连通常 200。
- **git push 有时靠重试能通**：PowerShell 直连 + `-c http.version=HTTP/1.1 -c http.lowSpeedLimit=0 -c http.lowSpeedTime=180`，循环重试。
- **git 完全不通时的兜底**：GitHub REST API 的 Git Data API——GET ref → POST `/git/blobs`（base64）→ POST `/git/trees`（base_tree+tree）→ POST `/git/commits` → PATCH `/git/refs/heads/main`。注意 API 上传的是工作区 CRLF 字节，会导致 tree SHA 与本地 LF commit 不同，但内容一致、不影响 CI。
- **删除 Release / tag / 强推 main** 也走 REST API（本次回退就是这么做的）。
- 本机代理端口变来变去（曾见 `18990`/`56645`/`40100`），不要硬编码。
- Flutter 命令会改写 `pubspec.lock` → 每次跑完 `git checkout -- pubspec.lock`，并用 `--no-pub`。
- Flutter 测试需清代理：`NO_PROXY=localhost,127.0.0.1,::1` 且 unset `HTTP_PROXY/HTTPS_PROXY/http_proxy/https_proxy`（否则 WebSocket 连不上）。本地 Flutter 在 `D:/flutter/bin/flutter`。
- 本地校验命令：
  ```bash
  D:/flutter/bin/flutter analyze --no-pub --no-fatal-infos --no-fatal-warnings
  D:/flutter/bin/flutter test --no-pub
  ```

---

## 7. 给接手 AI 的建议（下一步方向）

按优先级，供参考，不必照单全收：

1. **先分析现有 dump**：用 WinDbg `!analyze -v` 打开 `aushd-crash-20261117-111942.dmp`，把 `0x0` 执行违例的调用栈还原出来。这是目前唯一能直接指向"谁调用了空指针"的证据，比继续猜方案强。
2. **验证是不是 Flutter/ANGLE 自身崩溃**：地址 `0x0` 执行违例 + 多虚拟显示器 + 200% DPI，怀疑 ANGLE/D3D11 与多显示器 DPI 切换。可以尝试：
   - 诊断开关 `AUSHD_ANGLE_PLATFORM=swiftshader` 或 `d3d9` 看是否还崩（隔离 ANGLE 后端）
   - `VK_LOADER_LAYERS_DISABLE=1` 排除 Steam Vulkan 注入干扰
   - 在只有一块显示器、100% DPI 的环境复现，确认环境变量影响
3. **减少变量做最小化复现**：写一个最小的 Flutter Windows 窗口 + libmpv attach + 全屏切换的 repro，逐步加回项目的窗口/DPI/HDR 逻辑，定位是哪一层引入崩溃。
4. **考虑真正可行的进程隔离**：v1.0.12 的方向（独立 `mpv.exe`）思路没错，只是实现踩了 IPC 时序/编码的坑。如果决定重走，参考本地备份分支 `backup/pre-rollback-1.0.14` 的 `MpvIpcPlayer` / `MpvPipeTransport`，并把本交接文档第 3 节的 OSD 三个坑全部避开。
5. **先跑通新仓库的 build-only 构建**，拿到一个能装的 baseline 安装包再开始改，确保每次改动都能真机验证。

---

## 8. 备注

- 旧仓库 `TickCAI/aushd-player` 的 main 已回退到 `4e271624cfc2`，v1.0.10~v1.0.14 的产物已清理；请以**新仓库**为唯一工作区。
- 本交接文档同时会放入新仓库根目录，方便接手 AI 在 clone 后直接阅读。
- 有任何新发现（尤其是 dump 栈结论），请更新本文档的"已尝试方案与结论"，避免后人重复踩坑。
