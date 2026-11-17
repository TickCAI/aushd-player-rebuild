import 'dart:async';
import 'dart:convert' show utf8;
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// The entry point of the reader isolate.
///
/// Uses PeekNamedPipe + short reads on a polling loop instead of a blocking
/// ReadFile. A blocking native read cannot be interrupted by Isolate.kill,
/// which would leak the isolate and keep the process alive after dispose.
/// Polling lets the isolate service its message port and exit cleanly.
void _pipeReaderLoop(Map<String, dynamic> args) {
  final int handle = args['handle'] as int;
  final SendPort out = args['port'] as SendPort;
  // No control port: closing the handle in the main isolate makes
  // PeekNamedPipe fail below, which ends the loop and lets the isolate exit.

  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final peek = kernel32.lookupFunction<
      Int32 Function(IntPtr, Pointer<Void>, Uint32, Pointer<Uint32>,
          Pointer<Uint32>, Pointer<Uint32>),
      int Function(int, Pointer<Void>, int, Pointer<Uint32>,
          Pointer<Uint32>, Pointer<Uint32>)>('PeekNamedPipe');
  final readFile = kernel32.lookupFunction<
      Int32 Function(IntPtr, Pointer<Uint8>, Uint32, Pointer<Uint32>, Pointer<Void>),
      int Function(int, Pointer<Uint8>, int, Pointer<Uint32>, Pointer<Void>)>('ReadFile');

  final buffer = malloc<Uint8>(16384);
  final read = malloc<Uint32>();
  final avail = malloc<Uint32>();
  final peeked = malloc<Uint32>();
  final left = malloc<Uint32>();
  // Buffer raw bytes, not Dart strings: a UTF-8 sequence (e.g. a Chinese
  // character) can be split across two ReadFile calls. Decoding per read would
  // corrupt it, so only decode a complete line after splitting on 0x0A.
  final pending = BytesBuilder();

  void emitLines() {
    final data = pending.takeBytes();
    var start = 0;
    for (var i = 0; i < data.length; i++) {
      if (data[i] != 0x0A) continue;
      out.send(utf8.decode(data.sublist(start, i), allowMalformed: true));
      start = i + 1;
    }
    if (start < data.length) pending.add(data.sublist(start));
  }

  Future<void> loop() async {
    while (true) {
      avail.value = 0;
      // PeekNamedPipe(h, lpBuffer, nBufferSize, lpBytesRead,
      //                lpTotalBytesAvail, lpBytesLeftThisMessage)
      final ok = peek(handle, nullptr, 0, peeked, avail, left);
      if (ok == 0) {
        // ignore: avoid_print
        print('[pipe-reader] PeekNamedPipe failed: ${GetLastError()} handle=$handle');
        break; // broken pipe
      }
      if (avail.value > 0) {
        read.value = 0;
        final got = readFile(handle, buffer, 16384, read, nullptr);
        if (got == 0 || read.value == 0) break;
        pending.add(Uint8List.fromList(buffer.asTypedList(read.value)));
        emitLines();
      } else {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
    out.send(null); // EOF sentinel
    malloc.free(buffer);
    malloc.free(read);
    malloc.free(avail);
    malloc.free(peeked);
    malloc.free(left);
  }

  loop();
}

/// A minimal synchronous client for mpv's Windows named-pipe JSON IPC.
///
/// Reads happen on a dedicated isolate so no read ever stalls the Flutter UI
/// thread. Writes are short JSON lines and run synchronously.
final class MpvPipeTransport {
  MpvPipeTransport._(this._handle, this._readIsolate);

  final int _handle;
  final Isolate _readIsolate;
  bool _closed = false;

  static const _genericReadWrite = 0xC0000000;
  static const _shareReadWrite = 0x00000003;
  static const _openExisting = 3;

  /// Connects to `\\.\pipe\<name>`, retrying while mpv starts up.
  static Future<MpvPipeTransport> connect({
    required String pipeName,
    required void Function(String line) onLine,
    required void Function() onDone,
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final name = r'\\.\pipe\' + pipeName;
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final createFileW = kernel32.lookupFunction<
        IntPtr Function(Pointer<Utf16>, Uint32, Uint32, Pointer<Void>, Uint32, Uint32, IntPtr),
        int Function(Pointer<Utf16>, int, int, Pointer<Void>, int, int, int)>('CreateFileW');
    final writeFile = kernel32.lookupFunction<
        Int32 Function(IntPtr, Pointer<Void>, Uint32, Pointer<Uint32>, Pointer<Void>),
        int Function(int, Pointer<Void>, int, Pointer<Uint32>, Pointer<Void>)>('WriteFile');

    final deadline = DateTime.now().add(timeout);
    int handle = INVALID_HANDLE_VALUE;
    while (DateTime.now().isBefore(deadline)) {
      final wide = name.toNativeUtf16();
      try {
        handle = createFileW(wide, _genericReadWrite, _shareReadWrite, nullptr, _openExisting, 0, 0);
      } finally {
        malloc.free(wide);
      }
      if (handle != INVALID_HANDLE_VALUE && handle != 0) break;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (handle == INVALID_HANDLE_VALUE || handle == 0) {
      throw StateError('could not connect to mpv IPC pipe $name');
    }

    final receive = ReceivePort();
    final donePort = ReceivePort();
    receive.listen((message) {
      if (message is String) {
        onLine(message);
      } else if (message == null) {
        onDone();
      }
    });
    donePort.listen((_) {});

    final isolate = await Isolate.spawn(
      _pipeReaderLoop,
      {'handle': handle, 'port': receive.sendPort},
      onExit: donePort.sendPort,
      onError: donePort.sendPort,
    );
    final transport = MpvPipeTransport._(handle, isolate);
    transport._ports = [receive, donePort];
    transport._writeFile = writeFile;
    return transport;
  }

  late final List<ReceivePort> _ports;
  late final int Function(int, Pointer<Void>, int, Pointer<Uint32>, Pointer<Void>) _writeFile;

  /// Sends one already newline-terminated JSON command to mpv.
  void write(String line) {
    if (_closed) return;
    // A JSON command carries user-visible text (titles, localized strings,
    // subtitles). codeUnits are UTF-16 code units, not UTF-8 bytes: truncating
    // them with & 0xFF corrupts non-ASCII text and can even emit 0x0A/0x00,
    // splitting one command into several and breaking the JSON framing.
    final bytes = utf8.encode(line);
    final buffer = malloc<Uint8>(bytes.length);
    final written = malloc<Uint32>();
    try {
      for (var i = 0; i < bytes.length; i++) {
        buffer[i] = bytes[i];
      }
      var offset = 0;
      while (offset < bytes.length) {
        written.value = 0;
        final ok = _writeFile(
          _handle,
          buffer.elementAt(offset).cast<Void>(),
          bytes.length - offset,
          written,
          nullptr,
        );
        if (ok == 0 || written.value == 0) break;
        offset += written.value;
      }
    } finally {
      malloc.free(buffer);
      malloc.free(written);
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    CloseHandle(_handle);
    _readIsolate.kill(priority: Isolate.beforeNextEvent);
    for (final port in _ports) {
      port.close();
    }
  }
}
