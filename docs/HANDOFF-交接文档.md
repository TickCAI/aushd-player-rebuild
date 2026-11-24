# AusHD Player Rebuild — 开发交接文档

> 面向后续开发（人或 agent）。当前状态截至 **发现中心 v4 合并完成**。
> 读完本文应能直接接手下一步工作，不必回溯历史对话。

---

## 0. 一句话现状

项目 `D:\projects\aushd-player-rebuild`（AusHD Player，Flutter TV 播放器）。主线已完成：首页 IA 重做 → 智能片单 → 发现中心 v1→v2→v3→**v4（当前）**。
- 当前分支：`main`，HEAD = `d38a162db142bbdfa3d5e156ef63612c72b4fa99`（Merge feat/discovery-v4）。
- 本地 main = 远端 main，工作区**干净**。
- 最近 CI：run `45002072755` 全绿 6/6（analyze / 单测 / Windows / Linux / AndroidTV / 发版）。
- 最新文档：`docs/发现中心v4-详情页跳转与筛选面板改动记录.md`。

---

## 1. 工程硬约束（必读，违反会踩坑）

| 约束 | 细节 |
|---|---|
| 本机无 flutter/dart/7z | **所有验证靠 GitHub Actions CI**，本机跑不了 build/test/analyze |
| 两个 workflow | `build.yml`（Validate + analyze/test gate + Build windows/linux/androidtv + Publish release）、`window-soak.yml` |
| CI 命令 | analyze 带 `--no-fatal-infos --no-fatal-warnings`，**只有 error 才 fail**；warning/info（约 80 条）不影响通过 |
| PAT 获取 | `git credential fill`（protocol=https + host=github.com + 空行）→ password 行 `.Substring(9).Trim()`；**从不入库、不落文档** |
| 网络 | github.com:443 时通时不通；push/fetch 用 `git -c http.proxy=` 重试 3–8 次。gh proxy 7897 **已死**，别用 |
| CI 派发 | `POST /repos/TickCAI/aushd-player-rebuild/actions/workflows/build.yml/dispatches`，body `{ref, inputs:{tag, skip_distribution:true}}` |
| 中文文件 | **一律用 write/edit 工具（UTF-8）**，绝不用 PowerShell 5.1 `Set-Content`（曾把 JSON body 写成 ASCII → 中文路径变 `????` → Windows 非法 → git reset 崩） |
| 合并 PR | **用 GitHub merges API**（`POST /repos/.../merges`，body `{base:'main', head:'<branch>', commit_message}`），避免中文路径经 PS JSON 写坏 |
| 工具 | 本会话 `bash` 不可用，用 `pwsh`；read/edit/write/glob/grep 走专用工具 |
| 视觉 | 图片生成/理解后端常 429 限流，用户发的截图近期**看不了**（VISION_BACKEND_UNAVAILABLE）；按文字需求实现，别反复重试 |

---

## 2. 版本演进（已完成，勿重做）

| 版本 | merge commit | 关键内容 |
|---|---|---|
| home-v2 | `2207349` | 平台→"出品方" facet；智能片单重做（SmartSpec 4 权重）；Seerr/TMDB hybrid |
| 发现中心 v2 | `34fe861` | 真实抓取 + 无限下拉；发现(SeerrMedia)与已拥有(EmbyItem)视觉分离；7 分类 |
| 发现中心 v3 | `e347200` | 卡片"待播"；按 TMDB id 核对库；修标题叠加；搜索 + 4 维度筛选（类型/排序/年份/流派） |
| **发现中心 v4** | **`d38a162`** | 见第 3 节五点改动 |

教训沉淀：
- 单测里比较权重必须用**同一 spec id**，否则 stableJitter 不同导致断言失败。
- v2 早期把发现内容与本地库混排（`resolveMixed`）违背"视觉分离"，已废弃；智能片单退回纯本地 `resolve()`，发现归 DiscoverPage。

---

## 3. 发现中心 v4 五点改动（当前交付）

| 用户反馈 | 实现位置与方式 |
|---|---|
| ①点击不该直接播放，应进详情页再播放/选集 | `lib/ui/pages/discover_page.dart` `_openCard`：库命中→`openItem`（Emby 详情），未命中→`openRequest`（Seerr 详情）。删除原 `playItem` + `toggleWatch` 直连。详情页内播放/选集沿用现有逻辑未改 |
| ②筛选要详细列表分类，不要点击循环 | 新增 `lib/ui/widgets/discovery_filter_panel.dart`（侧滑面板，分区列 类型/排序/年份/地区/影片分类）；页面顶部一个筛选触发 chip；`DiscoveryFilters` 加 `region` 维度、genreOptions 扩到 19 类、新增 regionOptions(12) |
| ③下滑时筛选栏与海报叠加 | GridView `Clip.none`→`Clip.hardEdge`；header 块包进不透明 `Container(color: Zc.background)` |
| ④"出品方"→"流媒体" | `lib/ui/pages/library_page.dart`：facet 文案改流媒体；选项改固定主流平台白名单 `_streamingPlatforms`（爱奇艺/腾讯/优酷/芒果/哔哩/Netflix/Disney+/HBO/Prime/Apple/BBC），按 studio 名子串模糊匹配，只列库里存在的；服务端不再传 Studios，改本地过滤 |
| ⑤首页四行改发现抓取 | `lib/ui/pages/home_page.dart` `_discoveryRow`：热门趋势=trending(week)、热门剧集=popularShows、本周推荐=todayPicks、为你推荐=trending(week)，各取发现首页 + `recommender.resolve` 库匹配；未配 TMDB/Seerr 整行隐藏。删除旧 `_forYou` 与 seerr trending 独立行 |

首页行结构（≤12 行）：继续观看 / 我的媒体库 / 本周更新(本地) / **热门趋势(发现)** / **热门剧集(发现)** / 新片速递 / 冷门佳作 / 我的片单 / 我的收藏 / **本周推荐(发现)** / **为你推荐(发现)**。
`SmartSpec.oneEp/classics/picks` 常量保留在数据层但首页不再引用。

修复记录：首轮 CI `45001273865` analyze 报 1 error —— 我臆造的图标 `filter_alt_outlined_rounded` 不存在，改成 `Icons.filter_alt_outlined`（commit `6b4e95b`）后重跑全绿。

---

## 4. 关键 API / 文件定位（继续开发直接用）

| 用途 | 位置 |
|---|---|
| `Recommender.resolve(List<SeerrMedia>, {hidePlayed})` | `lib/data/recommendations.dart:174` — 按 `tmdb.<id>` 批量查库，命中换 EmbyItem，返回 `MixedItems`，保持 1:1 顺序 |
| `openItem(BuildContext, EmbyItem)` | `lib/ui/pages/routes.dart:29` — 进 Emby 详情页（series/season/collection 分发），**非直接播放** |
| `openRequest(BuildContext, SeerrMedia)` | `lib/ui/pages/routes.dart:37` — 进 Seerr 详情页（`RequestPage`），含播放/请求按钮 |
| `playItem(BuildContext, EmbyItem, ...)` | `lib/ui/core/playback_launcher.dart` — 直接播放（发现页已不再直接调用） |
| `ProfileService` / `ListEntry` | `lib/data/user_profile.dart` — 待播清单，`toggle(item)` 加/移，`available` 依赖 HubLink.features.profiles |
| `TmdbApi.discover(tv,{page,language,sortBy,watchProviders,watchRegion,voteCountGte,withoutGenres,extra})` | `lib/data/tmdb_api.dart:99` — `with_original_language`/`with_genres` 经 extra 透传；defaultLanguage=`zh-CN` |
| `showSidePanel` / `showMultiSelectSidePanel` / `PanelOption` | `lib/ui/widgets/side_panel.dart` — 侧滑面板（单选/多选带搜索） |
| `mixedCard(...)` | `lib/ui/widgets/mixed_cards.dart:45` — SeerrMedia→openRequest、EmbyItem→openItem（首页发现行走这条，天然进详情） |
| `RequestPosterCard` 状态覆盖 | `lib/ui/widgets/cards.dart` — `statusLabel/statusIcon/statusColor` 可选参数，默认行为不变 |
| l10n | `lib/l10n/app_en.arb`（template，getter 由 gen-l10n 生成）+ `app_zh.arb`；`l10n.yaml` output-class=L10n, nullable-getter:false。**新 key 必须同时进两个 arb** |
| 中文映射 | `lib/l10n/content_zh.dart` — `ContentZh.region(raw)` 地区归一化 |

设计 token：`Zc`(background/surface/surfaceHigh/outline/text/textMuted/textFaint/accent/accentSoft/request/success/cinema/rating/danger/warning，**无 divider 用 outline**)；`Zt`(display/headline/title/rowTitle/body/label/caption/meta)；`Zs`(posterWidth/landscapeWidth/cardGap/radius/radiusLarge/rowGap)；`Zm`(fast/normal/curve)。

---

## 5. 诚实边界（已知局限）

- 云端 CI **不连真实 TMDB/Seerr**，只验证编译/单测/构建；抓取内容、筛选、平台匹配的实际效果需真机配 key 验证。
- 库核对按 `tmdb.<id>`；部分 Jellyfin 配置库条目未写 provider id 则无法命中，归入未拥有。
- 流媒体平台靠 studio 名**子串匹配**，依赖刮削器把平台写进 Studios；写成了约定外名字会漏（可在 `_streamingPlatforms.frags` 加关键词）。
- Seerr fallback 的流派/年份是客户端过滤，精度取决于元数据；TMDB 为服务端筛选更准。
- 首页发现行未配 TMDB/Seerr 时整行隐藏（非显示空行），兼容纯本地 Emby 安装。
- 近几轮**看不到用户截图**（视觉后端限流），叠加问题定位基于文字 + 代码分析（header 与海报重叠）。

---

## 6. 下一步 / Open objectives

全部已合并，无强制待办。可选后续：

1. **真机验收**（需配 TMDB/Seerr key）：①发现卡片进详情、详情页内播放；②筛选面板逐项生效；③下滑无叠加；④媒体库"流媒体"只列主流平台且能筛出；⑤首页四行抓到真实内容、命中库进 Emby 详情。
2. 真机若反馈流媒体漏匹配 → 扩 `_streamingPlatforms.frags`。
3. 若用户还想调首页行顺序/标题/卡片样式 → 改 `home_page._buildRows`，注意 ≤12 行、标题不重复。
4. 若视觉后端恢复，可回看历史截图核对叠加/对齐细节。

---

## 7. 标准作业流程（改代码时照做）

1. 建分支：`git checkout -b feat/<topic> main`。
2. 改代码（write/edit，UTF-8）→ l10n 两文件同步 → 单测同步（改 signature 记得补 `|region` 段）。
3. 提交 → push（重试）→ dispatch build.yml → 轮询 jobs。
4. 有 error 就修（warning/info 可忽略），重派直到全绿 6/6。
5. 写中文文档到 `docs/` → 提交 push → GitHub merges API 合并 main。
6. fetch → checkout main → `git reset --hard origin/main` → 确认 status 干净。
