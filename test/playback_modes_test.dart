import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:audio_service/audio_service.dart' as system_audio;
import 'package:flutter_test/flutter_test.dart';
import 'package:mpv_audio_kit/mpv_audio_kit.dart' as mpv;
import 'package:reverb/api/ytmusic_api.dart';
import 'package:reverb/api/ytmusic_channel.dart';
import 'package:reverb/audio/audio_handler.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('repeat controls apply file, playlist, and off modes in mpv', () async {
    final player = _Player();
    final handler = AudioHandler(player: player);
    addTearDown(() => handler.customAction('dispose'));

    await Future.wait([handler.cycleRepeat(), handler.cycleRepeat()]);
    expect(player.loops, [mpv.Loop.playlist, mpv.Loop.file]);
    expect(handler.repeat.value, RepeatMode.one);

    await handler.setRepeatMode(system_audio.AudioServiceRepeatMode.none);
    expect(player.loops.last, mpv.Loop.off);
    expect(handler.repeat.value, RepeatMode.off);
  });

  test('shuffle and manual Next use the native playlist', () async {
    final player = _Player();
    final handler = AudioHandler(player: player);
    addTearDown(() => handler.customAction('dispose'));

    await handler.toggleShuffle();
    expect(handler.shuffle.value, isTrue);
    await handler.skipToNext();
    await handler.setShuffleMode(system_audio.AudioServiceShuffleMode.none);
    expect(player.actions, [
      'shuffle:true',
      'move:2:0',
      'next',
      'shuffle:false',
    ]);
  });

  test(
    'a failed stream can be retried and enters history once it plays',
    () async {
      const song = Song(id: 'track', title: 'Track', artist: 'Artist');
      final player = _Player();
      final history = <Song>[];
      var resolutions = 0;
      final handler = AudioHandler(
        player: player,
        resolveStream: (_) async => ++resolutions == 1
            ? null
            : const YtMusicStream(
                url: 'https://example.com/track',
                headers: {},
              ),
        recordHistory: (song) async => history.add(song),
      );
      addTearDown(() => handler.customAction('dispose'));

      await handler.playSongs([song], 0);
      expect(
        handler.playbackState.value.processingState,
        system_audio.AudioProcessingState.loading,
      );
      expect(history, isEmpty);

      await player.emitLoad();
      player.stream.ends.add(
        const mpv.MpvFileEndedEvent(
          reason: mpv.MpvEndFileReason.error,
          error: -1,
        ),
      );
      player.stream.states.add(mpv.MpvPlaybackState.idle);
      await pumpEventQueue();
      expect(handler.failedSong.value, song);
      expect(
        handler.playbackState.value.processingState,
        system_audio.AudioProcessingState.error,
      );
      expect(history, isEmpty);

      await handler.retryPlayback();
      expect(player.actions, ['jump:0']);
      expect(handler.failedSong.value, isNull);
      await player.emitLoad();
      player.stream.states.add(mpv.MpvPlaybackState.buffering);
      await pumpEventQueue();
      expect(
        handler.playbackState.value.processingState,
        system_audio.AudioProcessingState.buffering,
      );
      expect(history, isEmpty);

      player.stream.states.add(mpv.MpvPlaybackState.playing);
      player.stream.positions.add(const Duration(milliseconds: 300));
      player.stream.states.add(mpv.MpvPlaybackState.paused);
      player.stream.states.add(mpv.MpvPlaybackState.playing);
      player.stream.positions.add(const Duration(milliseconds: 600));
      await pumpEventQueue();
      expect(history, [song]);
      expect(
        handler.playbackState.value.processingState,
        system_audio.AudioProcessingState.ready,
      );
    },
  );

  test('a resolved stream that fails in mpv never enters history', () async {
    const song = Song(id: 'track', title: 'Track', artist: 'Artist');
    final player = _Player();
    final history = <Song>[];
    final handler = AudioHandler(
      player: player,
      resolveStream: (_) async =>
          const YtMusicStream(url: 'https://example.com/track', headers: {}),
      recordHistory: (song) async => history.add(song),
    );
    addTearDown(() => handler.customAction('dispose'));

    await handler.playSongs([song], 0);
    await player.emitLoad();
    player.stream.ends.add(
      const mpv.MpvFileEndedEvent(
        reason: mpv.MpvEndFileReason.error,
        error: -1,
      ),
    );
    await pumpEventQueue();
    expect(handler.failedSong.value, song);
    expect(history, isEmpty);
  });

  final library = Platform.environment['REVERB_TEST_LIBMPV'];
  group(
    'natural mpv playback at the end of the queue',
    () {
      late mpv.Player player;
      late AudioHandler handler;

      setUp(() async {
        mpv.MpvAudioKit.ensureInitialized(
          libmpv: library,
          hotRestartCleanup: false,
        );
        final directory = await Directory.systemTemp.createTemp(
          'reverb-playback-',
        );
        addTearDown(() => directory.delete(recursive: true));

        player = mpv.Player();
        handler = AudioHandler(player: player);
        addTearDown(() => handler.customAction('dispose'));
        await player.setRawProperty('ao', 'null');
        await player.setPrefetchPlaylist(false);
        final files = [
          await _writeSilence(directory, 'first.wav'),
          await _writeSilence(directory, 'last.wav'),
        ];
        final opened = player.stream.playlist.firstWhere(
          (playlist) => playlist.items.length == 2 && playlist.index == 1,
        );
        await player.openAll(
          files.map((file) => mpv.Media(file.uri.toString())).toList(),
          index: 1,
          play: false,
        );
        await opened.timeout(const Duration(seconds: 5));
      });

      test('repeat one loops the last track in place', () async {
        await handler.setRepeatMode(system_audio.AudioServiceRepeatMode.one);
        var reachedLaterPosition = false;
        final restarted = player.stream.position.firstWhere((position) {
          if (position > const Duration(milliseconds: 500)) {
            reachedLaterPosition = true;
          }
          return reachedLaterPosition &&
              position < const Duration(milliseconds: 250);
        });

        await handler.play();
        await restarted.timeout(const Duration(seconds: 5));
        expect(player.state.playlist.index, 1);
      });

      test('repeat all returns from the last track to the first', () async {
        await handler.setRepeatMode(system_audio.AudioServiceRepeatMode.all);
        final wrapped = player.stream.playlist.firstWhere((playlist) {
          return playlist.items.length == 2 && playlist.index == 0;
        });

        await handler.play();
        await wrapped.timeout(const Duration(seconds: 5));
        expect(await player.getRawProperty('loop-file'), 'no');
      });
    },
    skip: library == null
        ? 'Set REVERB_TEST_LIBMPV to a native libmpv library.'
        : false,
  );
}

Future<File> _writeSilence(Directory directory, String name) {
  const sampleRate = 16000;
  const dataSize = sampleRate * 2;
  final wav = ByteData(44 + dataSize);
  final bytes = wav.buffer.asUint8List();
  bytes.setAll(0, 'RIFF'.codeUnits);
  wav.setUint32(4, 36 + dataSize, Endian.little);
  bytes.setAll(8, 'WAVEfmt '.codeUnits);
  wav.setUint32(16, 16, Endian.little);
  wav.setUint16(20, 1, Endian.little);
  wav.setUint16(22, 1, Endian.little);
  wav.setUint32(24, sampleRate, Endian.little);
  wav.setUint32(28, sampleRate * 2, Endian.little);
  wav.setUint16(32, 2, Endian.little);
  wav.setUint16(34, 16, Endian.little);
  bytes.setAll(36, 'data'.codeUnits);
  wav.setUint32(40, dataSize, Endian.little);
  return File.fromUri(directory.uri.resolve(name)).writeAsBytes(bytes);
}

class _Player extends Fake implements mpv.Player {
  final loops = <mpv.Loop>[];
  final actions = <String>[];
  String? _uri;

  Future<void> emitLoad() async {
    stream.hooks.add(const mpv.MpvHookEvent(1, mpv.Hook.load));
    await pumpEventQueue();
  }

  @override
  Future<void> openAll(
    List<mpv.Media> medias, {
    bool? play,
    int index = 0,
  }) async {
    _uri = medias[index].uri;
    stream.playlists.add(mpv.Playlist(medias, index: index));
  }

  @override
  Future<void> jump(int index) async => actions.add('jump:$index');

  @override
  Future<void> continueHook(int id) async {}

  @override
  Future<void> setRawProperty(String name, String value) async {}

  @override
  final _PlayerStream stream = _PlayerStream();

  @override
  Future<void> setLoop(mpv.Loop mode) async => loops.add(mode);

  @override
  Future<void> setShuffle(bool enabled) async =>
      actions.add('shuffle:$enabled');

  @override
  Future<String?> getRawProperty(String name) async =>
      name == 'playlist-pos' ? '2' : _uri;

  @override
  Future<void> move(int from, int to) async => actions.add('move:$from:$to');

  @override
  Future<void> next() async => actions.add('next');

  @override
  Future<void> dispose() async {}
}

class _PlayerStream extends Fake implements mpv.PlayerStream {
  final hooks = StreamController<mpv.MpvHookEvent>.broadcast(sync: true);
  final states = StreamController<mpv.MpvPlaybackState>.broadcast(sync: true);
  final positions = StreamController<Duration>.broadcast(sync: true);
  final ends = StreamController<mpv.MpvFileEndedEvent>.broadcast(sync: true);
  final playlists = StreamController<mpv.Playlist>.broadcast(sync: true);

  @override
  Stream<mpv.MpvHookEvent> get hook => hooks.stream;

  @override
  Stream<mpv.MpvPlaybackState> get playbackState => states.stream;

  @override
  Stream<mpv.MpvFileEndedEvent> get endFile => ends.stream;

  @override
  Stream<Duration> get position => positions.stream;

  @override
  final duration = const Stream<Duration>.empty();

  @override
  Stream<mpv.Playlist> get playlist => playlists.stream;
}
