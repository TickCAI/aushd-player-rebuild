import '../../core/host.dart';
import '../dialogue_downmix.dart';
import '../player_settings.dart';
import '../subtitle_style.dart';

/// The render path mpv will actually take, resolved once so that the options
/// map and the "[session] mode" log line can never disagree about it.
final class MpvMode {
  const MpvMode({required this.vo, required this.api, required this.gpuContext});

  final String vo;
  final String api;
  final String gpuContext;

  String describe() => 'vo=$vo api=$api context=$gpuContext';
}

MpvMode resolveMpvMode({required PlayerSettings settings}) {
  final linux = Host.isLinux;
  final own = !settings.mpvConfOnly;
  final api = settings.safeGpuApi;
  final vo = linux ? 'libmpv' : (own ? settings.videoOutput : 'gpu-next');
  // gpu-next only supports d3d11/vulkan on Windows. If the user picked OpenGL
  // to work around an AMD D3D11 crash, silently pair it with the legacy gpu VO
  // rather than letting mpv_initialize fail before the player page appears.
  final effectiveVo = (!linux && api == 'opengl' && vo == 'gpu-next') ? 'gpu' : vo;
  // Without an explicit context mpv probes one that can fall back to ANGLE's
  // D3D11 backend even when OpenGL was selected, so "OpenGL" would not leave
  // the AMD D3D11 driver path that faults on swapchain teardown. winvk uses
  // the Vulkan WSI; win is native WGL.
  final gpuContext = switch (api) {
    'd3d11' => 'd3d11',
    'vulkan' => 'winvk',
    _ => 'win',
  };
  return MpvMode(vo: effectiveVo, api: api, gpuContext: gpuContext);
}

Map<String, String> buildMpvOptions({
  int? wid,
  required PlayerSettings settings,
  bool acceptInvalidCertificates = false,
  String? logFile,
  String? osdFontsDir,
}) {
  final downmix = settings.stereoDownmix;
  final spdif = downmix ? '' : settings.mpvSpdif;
  final bitstream = spdif.isNotEmpty;
  final own = !settings.mpvConfOnly;
  final linux = Host.isLinux;
  final mode = resolveMpvMode(settings: settings);
  final api = mode.api;
  final gpuContext = mode.gpuContext;
  final effectiveVo = mode.vo;
  final d3dDecode = settings.hwdec.startsWith('d3d11') ||
      settings.hwdec.startsWith('dxva2') ||
      settings.hwdec.startsWith('nvdec');
  return {
    if (wid != null) 'wid': '$wid',
    'log-file': ?logFile,
    'osd-fonts-dir': ?osdFontsDir,
    'config': 'no',
    'load-scripts': 'no',
    'osc': 'no',
    'ytdl': 'no',
    'load-console': 'no',
    'load-select': 'no',
    'load-positioning': 'no',
    'load-commands': 'no',
    'load-auto-profiles': 'no',
    'load-stats-overlay': 'yes',
    'input-default-bindings': 'no',
    'input-builtin-bindings': 'no',
    'input-vo-keyboard': 'yes',
    'input-gamepad': 'no',
    'input-cursor': 'yes',
    'cursor-autohide': '1500',
    'osd-bar': 'no',
    'osd-on-seek': 'no',
    'osd-level': '1',
    if (!linux) 'force-window': 'yes',
    // The three crashes on record all happened inside the driver, and the only
    // evidence that could ever name the failing call was in mpv's own vo/gpu
    // log lines - which this used to switch off entirely with
    // `msg-level: ffmpeg=error`. Keep ffmpeg quiet, keep the renderer loud.
    'msg-level': 'all=info,vo=v,vd=v,ao=v,ffmpeg=warn',
    'keep-open': 'yes',
    'idle': 'yes',

    'vo': effectiveVo,
    // Windows used to be hard-coded to d3d11. Some AMD drivers crash inside
    // amdxx64.dll when a D3D11 swapchain is resized by fullscreen or torn
    // down on exit, so the default is now Vulkan and the API is selectable.
    // D3D11 hardware decoding is tied to that API, so fall back to mpv's safe
    // automatic decoder on the other backends.
    if (!linux) 'gpu-api': api,
    if (!linux) 'gpu-context': gpuContext,
    if (own) ...{
      // Flip-model swapchains are what the AMD UMD trips over on a fullscreen
      // transition; blt presentation avoids that rebuild.
      if (!linux && api == 'd3d11') 'd3d11-flip': 'no',
      'hwdec': d3dDecode && (linux || api != 'd3d11') ? 'auto-safe' : settings.hwdec,
      if (!linux) 'target-colorspace-hint': settings.hdrPassthrough ? 'yes' : 'no',
      'video-sync': !settings.smoothMotion ? 'audio' : (bitstream ? 'display-vdrop' : 'display-resample'),
      'interpolation': settings.smoothMotion ? 'yes' : 'no',
      'tscale': 'oversample',
      ...switch (settings.videoQuality) {
        VideoQuality.fast => {'scale': 'bilinear', 'dscale': 'bilinear', 'cscale': 'bilinear', 'dither-depth': 'no'},
        VideoQuality.balanced => {'scale': 'spline36', 'dscale': 'mitchell'},
        VideoQuality.high => {'profile': 'high-quality'},
      },
      'deband': settings.deband ? 'yes' : 'no',
      'tone-mapping': settings.toneMapping,
      if (settings.targetPrim != 'auto') 'target-prim': settings.targetPrim,
      if (settings.targetTrc != 'auto') 'target-trc': settings.targetTrc,
      if (settings.targetPeak > 0) 'target-peak': '${settings.targetPeak}',
    },

    'cache': 'yes',
    'demuxer-max-bytes': '512MiB',
    'demuxer-max-back-bytes': '128MiB',
    'demuxer-readahead-secs': '60',
    'stream-buffer-size': '4MiB',
    'network-timeout': '30',
    'user-agent': 'AusHDPlayer/1.0 (${linux ? 'Linux' : 'Windows'}; libmpv)',
    'tls-verify': acceptInvalidCertificates ? 'no' : 'yes',

    'audio-spdif': spdif,
    if (bitstream) ...{'audio-stream-silence': 'yes', 'audio-buffer': '0.5'},
    if (!linux) 'audio-exclusive': settings.audioExclusive ? 'yes' : 'no',
    'audio-channels': downmix ? 'stereo' : 'auto',
    if (downmix) 'af': '@${DialogueDownmix.mpvLabel}:${DialogueDownmix.mpvFilter}',
    'audio-pitch-correction': 'yes',
    'volume': settings.volume.round().toString(),
    'volume-max': '150',

    'sub-auto': 'no',
    'audio-file-auto': 'no',
    ...SubtitleStyle.mpvOptions(settings),
    'sub-fix-timing': 'yes',
    'blend-subtitles': 'no',
  };
}
