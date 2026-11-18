import 'package:flutter_test/flutter_test.dart';
import 'package:zerk_play/l10n/content_zh.dart';
import 'package:zerk_play/playback/mpv/mpv_options.dart';
import 'package:zerk_play/playback/player_settings.dart';
import 'package:zerk_play/playback/render_guard.dart';
import 'package:zerk_play/ui/widgets/net_image.dart';

void main() {
  setUp(() => ContentZh.uiLanguage = 'zh');

  test('the Windows default is the d3d11 path with no dump against it', () {
    const defaults = PlayerSettings();
    expect(defaults.gpuApi, 'd3d11');
    expect(defaults.videoOutput, 'gpu');
    expect(defaults.hwdec, 'd3d11va');
    expect(defaults.gpuApiAuto, isTrue);
    final saved = defaults.copyWith(gpuApi: 'vulkan', gpuApiAuto: false).toJson();
    expect(saved['gpuApi'], 'vulkan');
    expect(saved['gpuApiAuto'], isFalse);
    expect(PlayerSettings.fromJson(saved).gpuApi, 'vulkan');
    expect(PlayerSettings.fromJson(saved).gpuApiAuto, isFalse);
    // A blob from before the API selector existed keeps the current default and
    // stays eligible for the untouched-install correction.
    final old = PlayerSettings.fromJson(const <String, dynamic>{'vo': 'gpu-next'});
    expect(old.gpuApi, 'd3d11');
    expect(old.gpuApiAuto, isTrue);
  });

  test('mpv pins a matching GPU context and avoids flip-model D3D11 swapchains', () {
    final d3d = buildMpvOptions(settings: const PlayerSettings());
    final vulkan = buildMpvOptions(settings: const PlayerSettings(gpuApi: 'vulkan', hwdec: 'd3d11va'));
    final opengl = buildMpvOptions(settings: const PlayerSettings(gpuApi: 'opengl'));
    expect(d3d['gpu-api'], 'd3d11');
    expect(d3d['gpu-context'], 'd3d11');
    expect(d3d['d3d11-flip'], 'no');
    expect(d3d['hwdec'], 'd3d11va');
    expect(d3d['vo'], 'gpu');
    expect(vulkan['gpu-api'], 'vulkan');
    expect(vulkan['gpu-context'], 'winvk');
    expect(vulkan['hwdec'], 'auto-safe');
    expect(vulkan['d3d11-flip'], isNull);
    expect(opengl['gpu-api'], 'opengl');
    expect(opengl['gpu-context'], 'win');
    expect(opengl['vo'], 'gpu');
  });

  test('the render guard remembers a dead mode instead of editing settings', () {
    // An install that never picked a backend itself is corrected to the path
    // that has not crashed; a manual pick is never touched.
    final legacy = PlayerSettings.fromJson(const <String, dynamic>{'gpuApi': 'vulkan'});
    expect(RenderGuard.migrateDefault(legacy).gpuApi, 'd3d11');
    const manual = PlayerSettings(gpuApi: 'vulkan', gpuApiAuto: false);
    expect(identical(RenderGuard.migrateDefault(manual), manual), isTrue);

    expect(
      RenderGuard.fingerprint(vo: 'gpu', api: 'd3d11', gpuContext: 'd3d11', hwdec: 'd3d11va'),
      'vo=gpu api=d3d11 context=d3d11 hwdec=d3d11va',
    );
    expect(RenderGuard.nextApi('d3d11'), 'vulkan');
    expect(RenderGuard.nextApi('vulkan'), 'opengl');
    expect(RenderGuard.nextApi('opengl'), 'd3d11');

    // The recorded combination steps one rung down, for this launch only.
    const dead = 'vo=gpu api=d3d11 context=d3d11 hwdec=d3d11va';
    final avoided = resolveMpvMode(settings: const PlayerSettings(), avoid: dead);
    expect(avoided.api, 'vulkan');
    expect(avoided.avoided, isTrue);
    // Any other mode is used exactly as asked.
    final normal = resolveMpvMode(
      settings: const PlayerSettings(),
      avoid: 'vo=gpu api=opengl context=win hwdec=no',
    );
    expect(normal.api, 'd3d11');
    expect(normal.avoided, isFalse);
  });

  test('Chinese content adaptation covers genres, languages, roles and collections', () {
    expect(ContentZh.genre('Crime'), '犯罪');
    expect(ContentZh.genre('Science Fiction'), '科幻');
    expect(ContentZh.genre('Action & Adventure'), '动作冒险');
    expect(ContentZh.genres(const ['Crime', 'Drama']), '犯罪, 剧情');
    expect(ContentZh.genre('Some custom tag'), 'Some custom tag');
    expect(ContentZh.language('English'), '英语');
    expect(ContentZh.language('Chinese (Simplified)'), '简体中文');
    expect(ContentZh.language('eng'), '英语');
    expect(ContentZh.language('zh-TW'), '繁體中文');
    expect(ContentZh.personRole('Director'), '导演');
    expect(ContentZh.collectionName('Johnny Keep Walking Collection'), 'Johnny Keep Walking 系列');
    expect(ContentZh.collectionName('年会不能停！（系列）'), '年会不能停！（系列）');

    ContentZh.uiLanguage = 'en';
    expect(ContentZh.genre('Crime'), 'Crime');
    expect(ContentZh.language('English'), 'English');
  });

  test('artwork fallback registry is scoped to the preferred URL', () {
    final primary = Uri.parse('https://image.tmdb.org/t/p/w780/zh.jpg');
    final backup = Uri.parse('http://localhost:8096/Items/1/Images/Primary');
    final other = Uri.parse('https://image.tmdb.org/t/p/w780/other.jpg');
    ArtworkFallback.register(primary, backup);
    expect(ArtworkFallback.of(primary), backup);
    expect(ArtworkFallback.of(other), isNull);
    ArtworkFallback.register(other, null);
    expect(ArtworkFallback.of(other), isNull);
  });
}
