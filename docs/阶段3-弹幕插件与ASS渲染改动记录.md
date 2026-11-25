# 阶段3：弹幕插件 API + mpv ASS 渲染改动记录

> 属于《下一阶段开发方案-热更弹幕账号挂载.md》的阶段3。目标：给桌面播放器叠加弹幕（bullet-comments），数据源插件化、由签名配置下发，渲染走 mpv 原生字幕轨，零 Dart 帧循环开销。

## 一、背景与决策

- 渲染方式（已确认）：**插件化数据源 + mpv ASS 渲染**。弹幕转成一份 SubStation Alpha 文件，作为 mpv 的**辅助字幕轨（secondary-sid）**挂载。
  - 为什么用字幕轨而不是 Flutter 浮层：mpv 自己驱动时间轴，seek/暂停/倍速/逐帧全部免费跟随，不占 Dart 主线程，性能与同步精度都更好。
  - 为什么用 `secondary-sid` 而不是 `sid`：辅助轨不抢占主字幕，用户能同时看真字幕 + 弹幕。
- 数据源：抽象成 `DanmakuProvider`，**具体源由阶段1 的签名配置 `danmakuSources` 下发**（URL 模板），加新源不用改 Dart。
- Android（Media3 后端）无辅助字幕通道，本阶段**不支持弹幕**（no-op），桌面（Windows/Linux，mpv）支持。

## 二、数据层（`lib/data/danmaku/`，新建）

### `danmaku.dart`
- `Danmaku`：`timeMs / text / mode(scroll|top|bottom) / color(0xRRGGBB) / fontSize`。
- `DanmakuCodec`：
  - `parseBilibiliXml`：解析 `<d p="time,mode,size,color,...">文本</d>`，mode 4→bottom、5→top、其余→scroll；XML 反转义；按时间排序；坏行跳过不抛。
  - `parseJson`：AusHD 契约 `{items:[{timeMs,text,color,mode,size}]}`，mode 字符串；兼容裸数组。
  - `parseAuto`：按首字符 `<`/`{`/`[` 自动分派。

### `danmaku_service.dart`
- `DanmakuMedia`：tmdbId/doubanId/title/season/episode + 稳定 `key`。
- `DanmakuProvider` 抽象：`supports(media)` / `fetch(media)`（无结果返回空、不抛）。
- `TemplateDanmakuProvider`：URL 模板填充 `{tmdb}{douban}{title}{season}{episode}`，GET 后 `parseAuto`。
- `DanmakuService extends ChangeNotifier`：
  - `enabled`（需有源才为真）、`providers`、`providerId`（返回实际生效源）。
  - `applyConfigSources(sources, {client})`：从签名配置构建源列表，保留仍存在的当前选择。
  - 本地持久化（LocalStore 键 `aushd.danmaku.v1`）：开关 + 所选源重启不丢；`restorePrefs()` 恢复。
  - `load(media)`：门控（未启用/不支持→空）+ 内存缓存（上限 40 条），任何失败→空，绝不抛给播放层。

## 三、渲染层（`lib/playback/danmaku/danmaku_ass.dart`，新建）

- `render(items)`：生成完整 ASS 文档。
  - 3 个样式：Scroll / Top / Bottom；CJK 字体名 `Noto Sans CJK SC`。
  - 滚动行用 `\move(x1,y,x2,y)` 右→左匀速滚动，8 条泳道轮转避免叠字；时长随文本长度（6–14s）。
  - 顶部/底部为静态行（5s）。
  - 颜色 `0xRRGGBB` → ASS 的 `&HBBGGRR&`（`\1c` 覆盖）；字号 `\fs`；文本转义 `{`/`}`/`\`/换行。
- `writeTemp(items, {key})`：写到临时目录 `aushd_danmaku/<key>.ass`，空列表也产出合法文件（便于统一 attach/detach）。

## 四、播放接入

- `PlayerBackend` 新增 `attachSecondarySubtitle(filePath)` / `detachSecondarySubtitle()`。
  - mpv：`sub-add <file> auto` + `secondary-sid=auto`（attach），`secondary-sid=no`（detach）。
  - Media3：两者 no-op（Android 无弹幕）。
- `PlaybackSession`：
  - 新增可选 `danmaku` 字段（由 `playback_launcher` 从 `services.danmaku` 注入）。
  - `_onFileLoaded` 应用主字幕后 `unawaited(_refreshDanmaku(cur))`。
  - `_refreshDanmaku`：未启用→detach；否则按当前片/集构造 `DanmakuMedia`→`service.load`→空则 detach→非空写 ASS 文件并 attach。
  - **代次守卫**（`_danmakuGen`）：切集/退出时 in-flight 的 fetch 不会把弹幕挂到错误的视频上；`_finish` 也自增代次，避免关闭后落地。

## 五、UI

- 设置 → 字幕段末尾新增"弹幕"分区：开关（无源时禁用并提示）+ 源选择（有源才显示）。
- 页面监听 `danmaku` 子服务的通知，切换即时重绘。

## 六、l10n

- 双文件新增 4 键：danmaku / danmakuHint / danmakuSource / danmakuNoSources（en/zh 同步，JSON 校验、无重复键）。

## 七、测试与验证

- 新增 `test/danmaku_test.dart`（140 行）：
  - Codec：Bilibili XML 模式/时间/颜色/转义映射、坏行跳过；JSON items/裸数组；parseAuto 分派。
  - ASS：结构完整、滚动 `\move`、颜色 BBGGRR、时间戳 HH:MM:SS.cc、文本转义、空列表合法头。
  - Service：未启用返回空、启用后 fetch + 缓存命中不重复请求、fetch 异常吞掉返回空、无源时 enabled=false。
- 云端 CI run `45537671183`：**全绿 6/6**（Validate / Tests and compile gate / Build windows / androidtv / linux / Publish release），一次通过。

## 八、诚实边界

- **未对真实弹幕源联调**：CI 不联网测试，`TemplateDanmakuProvider` 的 URL 模板与 `parseAuto` 需真机接真实源验证；目前 `danmakuSources` 依赖签名配置下发，未配置时弹幕整条链路静默休眠。
- Android 不支持弹幕（Media3 无辅助字幕轨），开关在 Android 上也会因无源/后端不支持而不生效——这是设计取舍，非缺陷。
- ASS 字体依赖系统/`assets/mpv/fonts` 的 CJK 字体；若目标机缺字会显示方块，需随包带字体（沿用现有字体资产）。
- 弹幕与主字幕共用 `sub-scale`/样式体系，字号缩放会同时影响真字幕；如需独立缩放，后续可加弹幕专属 scale。
- 泳道/时长是经验值，密集弹幕可能仍拥挤；V1 优先"能用且同步准"，密度优化留后续。

## 九、下一步

- 真机：配好签名配置的 `danmakuSources` → 设置里开弹幕 → 播放桌面端视频验证叠加、seek/暂停跟随、不抢主字幕。
- 之后进入阶段4（自有账号 + 云同步）。
