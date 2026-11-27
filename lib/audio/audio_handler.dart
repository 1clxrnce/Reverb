// audio_handler.dart
// Playback engine: mpv for streaming, audio_service for notification / lock screen.
//
// Songs are queued with placeholder URLs like "sunoh-song://dQw4w9WgXcQ".
// mpv's on_load hook swaps those for real YouTube stream URLs just-in-time.

import 'dart:async';

import 'package:audio_service/audio_service.dart' as asvc;
import 'package:audio_session/audio_session.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:mpv_audio_kit/mpv_audio_kit.dart' as mpv;

import '../api/ytmusic_api.dart';
import '../api/ytmusic_channel.dart';
import '../services/firestore_service.dart';

const _kScheme = 'sunoh-song://';

enum RepeatMode { off, all, one }

class AudioHandler extends asvc.BaseAudioHandler with asvc.SeekHandler {
  AudioHandler({
    mpv.Player? player,
    Future<void> Function(Song)? recordHistory,
    Future<YtMusicStream?> Function(String)? resolveStream,
  }) : _writeHistory = recordHistory,
       _resolveStream = resolveStream ?? YtMusicChannel.instance.resolve {
    _player = player ?? _buildPlayer();
    _subs.add(_player.stream.hook.listen(_onHook));
    _subs.add(_player.stream.playbackState.listen(_onPlayerState));
    _subs.add(_player.stream.endFile.listen(_onEndFile));
    _subs.add(_player.stream.position.listen(_onPosition));
    _subs.add(_player.stream.duration.listen(_onDuration));
    _subs.add(_player.stream.playlist.listen(_syncQueue));
    unawaited(_initSession());
    _broadcastPlaybackState();
  }

  late final mpv.Player _player;
  final Future<void> Function(Song)? _writeHistory;
  final Future<YtMusicStream?> Function(String) _resolveStream;
  Song? _attemptSong;
  Song? _pendingHistory;
  int _loadGeneration = 0;
  bool _disposing = false;
  List<Song> _requestedSongs = const [];
  final _byId = <String, Song>{};
  late final _firestore = FirestoreService();
  late final _auth = FirebaseAuth.instance;
  final _subs = <StreamSubscription<dynamic>>[];
  Timer? _sleepTimer;
  Timer? _sleepTicker;
  bool _pausedByInterruption = false;
  Future<void> _queueOperation = Future.value();

  final _current = ValueNotifier<Song?>(null);
  final _playing = ValueNotifier<bool>(false);
  final _processing = ValueNotifier(asvc.AudioProcessingState.idle);
  final _failedSong = ValueNotifier<Song?>(null);
  final _position = ValueNotifier<Duration>(Duration.zero);
  final _duration = ValueNotifier<Duration>(Duration.zero);
  final _songQueue = ValueNotifier<List<Song>>(const []);
  final _volume = ValueNotifier<double>(100.0);
  final _shuffle = ValueNotifier<bool>(false);
  final _repeat = ValueNotifier<RepeatMode>(RepeatMode.off);
  final _sleepRemaining = ValueNotifier<Duration?>(null);

  ValueListenable<Song?> get current => _current;
  ValueListenable<bool> get playing => _playing;
  ValueListenable<asvc.AudioProcessingState> get processing => _processing;
  ValueListenable<Song?> get failedSong => _failedSong;
  ValueListenable<Duration> get position => _position;
  ValueListenable<Duration> get duration => _duration;
  ValueListenable<List<Song>> get songQueue => _songQueue;
  ValueListenable<double> get volume => _volume;
  ValueListenable<bool> get shuffle => _shuffle;
  ValueListenable<RepeatMode> get repeat => _repeat;
  ValueListenable<Duration?> get sleepRemaining => _sleepRemaining;

  mpv.Player _buildPlayer() {
    final p = mpv.Player(
      configuration: const mpv.PlayerConfiguration(
        autoPlay: true,
        initialVolume: 100.0,
        logLevel: mpv.LogLevel.info,
      ),
    );
    p.registerHook(mpv.Hook.load, timeout: const Duration(seconds: 10));
    return p;
  }

  Future<void> _onHook(mpv.MpvHookEvent event) async {
    if (event.hook != mpv.Hook.load) {
      await _player.continueHook(event.id);
      return;
    }

    var generation = _loadGeneration;
    Song? song;
    try {
      final raw = await _player.getRawProperty('stream-open-filename') ?? '';
      if (generation != _loadGeneration) return;
      song = _byId[_idFromUri(raw)];
      if (song == null) return;

      generation = ++_loadGeneration;
      _attemptSong = song;
      _pendingHistory = null;
      _setProcessing(asvc.AudioProcessingState.loading);
      final stream = await _resolveStream(song.id);
      if (generation != _loadGeneration) return;
      if (stream == null) {
        _failPlayback(song);
        return;
      }

      await _applyHeaders(stream.headers);
      if (generation != _loadGeneration) return;
      await _player.setRawProperty('stream-open-filename', stream.url);
      if (generation == _loadGeneration) _pendingHistory = song;
    } catch (e, st) {
      debugPrint('[audio] hook failed: $e\n$st');
      if (song != null && generation == _loadGeneration) _failPlayback(song);
    } finally {
      if (!_disposing) await _player.continueHook(event.id);
    }
  }

  Future<void> _applyHeaders(Map<String, String>? headers) async {
    final value = (headers == null || headers.isEmpty)
        ? ''
        : headers.entries
              .where((e) => !e.key.contains(',') && !e.value.contains(','))
              .map((e) => '${e.key}: ${e.value}')
              .join(',');

    try {
      await _player.setRawProperty('http-header-fields', value);
    } catch (e) {
      debugPrint('[audio] headers failed: $e');
    }
  }

  void _onPlayerState(mpv.MpvPlaybackState state) {
    final processing = switch (state) {
      mpv.MpvPlaybackState.idle => asvc.AudioProcessingState.idle,
      mpv.MpvPlaybackState.loading => asvc.AudioProcessingState.loading,
      mpv.MpvPlaybackState.buffering => asvc.AudioProcessingState.buffering,
      mpv.MpvPlaybackState.playing ||
      mpv.MpvPlaybackState.paused => asvc.AudioProcessingState.ready,
      mpv.MpvPlaybackState.completed => asvc.AudioProcessingState.completed,
    };
    if (_attemptSong == null &&
        _processing.value == asvc.AudioProcessingState.error) {
      return;
    }
    if (processing == asvc.AudioProcessingState.idle &&
        _processing.value == asvc.AudioProcessingState.loading) {
      return;
    }
    _setProcessing(processing, playing: state == mpv.MpvPlaybackState.playing);
  }

  void _onEndFile(mpv.MpvFileEndedEvent event) {
    final song = _attemptSong;
    final endedBeforePlaying =
        event.reason == mpv.MpvEndFileReason.eof && _pendingHistory != null;
    _loadGeneration++;
    _attemptSong = null;
    _pendingHistory = null;
    if (song != null &&
        (event.reason == mpv.MpvEndFileReason.error ||
            event.error < 0 ||
            endedBeforePlaying)) {
      _failPlayback(song);
    }
  }

  void _setProcessing(asvc.AudioProcessingState state, {bool playing = false}) {
    _playing.value = playing;
    _processing.value = state;
    _broadcastPlaybackState();
  }

  void _failPlayback(Song song) {
    _attemptSong = null;
    _pendingHistory = null;
    _failedSong.value = song;
    _setProcessing(asvc.AudioProcessingState.error);
  }

  void _beginPlaybackRequest() {
    _loadGeneration++;
    _attemptSong = null;
    _pendingHistory = null;
    _failedSong.value = null;
    _position.value = Duration.zero;
    _duration.value = Duration.zero;
    _setProcessing(asvc.AudioProcessingState.loading);
  }

  void _onPosition(Duration position) {
    _position.value = position;
    final song = _pendingHistory;
    if (song != null && _playing.value && position > Duration.zero) {
      _pendingHistory = null;
      unawaited(_recordPlayHistory(song));
    }
    _broadcastPlaybackState();
  }

  void _onDuration(Duration v) {
    _duration.value = v;
    final song = _current.value;
    if (song != null && v > Duration.zero) {
      mediaItem.add(_toMediaItem(song, duration: v));
    }
    _broadcastPlaybackState();
  }

  void _syncQueue(mpv.Playlist pl) {
    final songs = pl.items
        .map((m) => _byId[_idFromUri(m.uri)])
        .whereType<Song>()
        .toList();

    _songQueue.value = songs;
    queue.add(songs.map(_toMediaItem).toList());

    final idx = pl.index;
    if (idx >= 0 && idx < songs.length) {
      final newSong = songs[idx];
      _current.value = newSong;
      mediaItem.add(_toMediaItem(newSong, duration: _duration.value));
    }
    _broadcastPlaybackState();
  }

  asvc.MediaItem _toMediaItem(Song song, {Duration? duration}) {
    return asvc.MediaItem(
      id: song.id,
      title: song.title,
      artist: song.artist.isEmpty ? 'Unknown artist' : song.artist,
      album: song.album,
      artUri: song.artwork != null ? Uri.tryParse(song.artwork!) : null,
      duration: duration ?? song.duration,
    );
  }

  void _broadcastPlaybackState() {
    final songs = _songQueue.value;
    final currentId = _current.value?.id;
    final index = currentId == null
        ? null
        : songs.indexWhere((s) => s.id == currentId);

    playbackState.add(
      asvc.PlaybackState(
        controls: [
          asvc.MediaControl.skipToPrevious,
          _playing.value ? asvc.MediaControl.pause : asvc.MediaControl.play,
          asvc.MediaControl.skipToNext,
          asvc.MediaControl.stop,
        ],
        systemActions: const {
          asvc.MediaAction.seek,
          asvc.MediaAction.seekForward,
          asvc.MediaAction.seekBackward,
        },
        androidCompactActionIndices: const [0, 1, 2],
        processingState: _processing.value,
        errorMessage: _processing.value == asvc.AudioProcessingState.error
            ? 'Could not play ${_failedSong.value?.title ?? 'this track'}.'
            : null,
        playing: _playing.value,
        updatePosition: _position.value,
        bufferedPosition: _position.value,
        speed: 1.0,
        queueIndex: index != null && index >= 0 ? index : null,
        repeatMode: switch (_repeat.value) {
          RepeatMode.off => asvc.AudioServiceRepeatMode.none,
          RepeatMode.all => asvc.AudioServiceRepeatMode.all,
          RepeatMode.one => asvc.AudioServiceRepeatMode.one,
        },
        shuffleMode: _shuffle.value
            ? asvc.AudioServiceShuffleMode.all
            : asvc.AudioServiceShuffleMode.none,
      ),
    );
  }

  Future<void> _recordPlayHistory(Song song) async {
    try {
      final writeHistory = _writeHistory;
      if (writeHistory != null) {
        await writeHistory(song);
        return;
      }
      final user = _auth.currentUser;
      if (user == null) return;
      await _firestore.recordPlay(user.uid, song);
    } catch (e, st) {
      debugPrint('[audio] history failed: $e\n$st');
    }
  }

  Future<void> _runQueueOperation(Future<void> Function() operation) {
    final result = _queueOperation.then((_) => operation());
    _queueOperation = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<void> playSongs(List<Song> songs, int startIndex) =>
      _runQueueOperation(() => _openSongs(songs, startIndex));

  Future<void> _openSongs(List<Song> songs, int startIndex) async {
    if (songs.isEmpty) return;
    _requestedSongs = List.of(songs);
    for (final song in songs) {
      _byId[song.id] = song;
    }

    final index = startIndex.clamp(0, songs.length - 1);
    final song = songs[index];
    _current.value = song;
    mediaItem.add(_toMediaItem(song));
    _beginPlaybackRequest();

    try {
      await _player.openAll(
        songs.map((song) => mpv.Media(song.placeholderUri)).toList(),
        index: index,
        play: true,
      );
      if (_shuffle.value) await _applyShuffle(true);
    } catch (error, stack) {
      debugPrint('[audio] opening queue failed: $error\n$stack');
      _failPlayback(song);
    }
  }

  Future<void> retryPlayback() => _runQueueOperation(() async {
    final song = _failedSong.value;
    if (song == null) return;

    final index = _songQueue.value.indexWhere((track) => track.id == song.id);
    if (index < 0) {
      await _openSongs(
        _requestedSongs,
        _requestedSongs.indexWhere((track) => track.id == song.id),
      );
      return;
    }

    _beginPlaybackRequest();
    try {
      await _player.jump(index);
    } catch (error, stack) {
      debugPrint('[audio] retry failed: $error\n$stack');
      _failPlayback(song);
    }
  });

  Future<void> resume() => play();

  @override
  Future<void> pause() => _player.pause();
  Future<void> next() => skipToNext();
  Future<void> previous() => skipToPrevious();

  @override
  Future<void> play() => _processing.value == asvc.AudioProcessingState.error
      ? retryPlayback()
      : _player.play();

  @override
  Future<void> stop() async {
    _loadGeneration++;
    _attemptSong = null;
    _pendingHistory = null;
    _failedSong.value = null;
    await _player.pause();
    await seek(Duration.zero);
    _setProcessing(asvc.AudioProcessingState.idle);
    await super.stop();
  }

  @override
  Future<void> skipToNext() => _runQueueOperation(() async {
    if (_repeat.value == RepeatMode.one) {
      await seek(Duration.zero);
      await _player.play();
      return;
    }
    await _player.next();
  });

  @override
  Future<void> skipToPrevious() => _runQueueOperation(() async {
    if (_position.value > const Duration(seconds: 3)) {
      await seek(Duration.zero);
      return;
    }
    await _player.previous();
  });

  @override
  Future<void> seek(Duration pos) => _player.seek(pos);

  @override
  Future<void> skipToQueueItem(int index) => _runQueueOperation(() async {
    if (index < 0 || index >= _songQueue.value.length) return;
    await _player.jump(index);
  });

  @override
  Future<void> setRepeatMode(asvc.AudioServiceRepeatMode repeatMode) =>
      _runQueueOperation(
        () => _applyRepeat(switch (repeatMode) {
          asvc.AudioServiceRepeatMode.one => RepeatMode.one,
          asvc.AudioServiceRepeatMode.all ||
          asvc.AudioServiceRepeatMode.group => RepeatMode.all,
          _ => RepeatMode.off,
        }),
      );

  Future<void> cycleRepeat() => _runQueueOperation(
    () => _applyRepeat(switch (_repeat.value) {
      RepeatMode.off => RepeatMode.all,
      RepeatMode.all => RepeatMode.one,
      RepeatMode.one => RepeatMode.off,
    }),
  );

  Future<void> _applyRepeat(RepeatMode mode) async {
    await _player.setLoop(switch (mode) {
      RepeatMode.off => mpv.Loop.off,
      RepeatMode.all => mpv.Loop.playlist,
      RepeatMode.one => mpv.Loop.file,
    });
    _repeat.value = mode;
    _broadcastPlaybackState();
  }

  @override
  Future<void> setShuffleMode(asvc.AudioServiceShuffleMode shuffleMode) =>
      _runQueueOperation(() async {
        final enabled = shuffleMode != asvc.AudioServiceShuffleMode.none;
        if (enabled != _shuffle.value) await _applyShuffle(enabled);
      });

  Future<void> toggleShuffle() =>
      _runQueueOperation(() => _applyShuffle(!_shuffle.value));

  Future<void> _applyShuffle(bool enabled) async {
    await _player.setShuffle(enabled);
    _shuffle.value = enabled;
    _broadcastPlaybackState();
    if (enabled) {
      // Keep every other track ahead of the listener in the shuffled queue.
      final index = int.tryParse(
        await _player.getRawProperty('playlist-pos') ?? '',
      );
      if (index != null && index > 0) await _player.move(index, 0);
    }
  }

  Future<void> setVolume(double vol) async {
    final clamped = vol.clamp(0.0, 100.0);
    _volume.value = clamped;
    await _player.setVolume(clamped);
  }

  void setSleepTimer(Duration? duration) {
    _sleepTimer?.cancel();
    _sleepTicker?.cancel();
    _sleepTimer = null;
    _sleepTicker = null;

    if (duration == null || duration <= Duration.zero) {
      _sleepRemaining.value = null;
      return;
    }

    final deadline = DateTime.now().add(duration);
    _sleepRemaining.value = duration;
    _sleepTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) {
        _sleepRemaining.value = Duration.zero;
      } else {
        _sleepRemaining.value = left;
      }
    });
    _sleepTimer = Timer(duration, () {
      unawaited(_player.pause());
      _sleepTicker?.cancel();
      _sleepRemaining.value = null;
    });
  }

  Future<void> _initSession() async {
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());

      _subs.add(
        session.interruptionEventStream.listen((e) {
          if (e.begin) {
            if (_playing.value) {
              _pausedByInterruption = true;
              unawaited(_player.pause());
            }
          } else if (_pausedByInterruption &&
              e.type != AudioInterruptionType.unknown) {
            _pausedByInterruption = false;
            unawaited(_player.play());
          }
        }),
      );

      _subs.add(
        session.becomingNoisyEventStream.listen((_) {
          unawaited(_player.pause());
        }),
      );
    } catch (e) {
      debugPrint('[audio] session init failed (non-fatal): $e');
    }
  }

  String? _idFromUri(String uri) {
    if (!uri.startsWith(_kScheme)) return null;
    final id = uri.substring(_kScheme.length);
    return id.isEmpty ? null : id;
  }

  @override
  Future<void> customAction(String name, [Map<String, dynamic>? extras]) async {
    if (name == 'dispose') {
      await _disposeInternal();
    }
  }

  Future<void> _disposeInternal() async {
    _sleepTimer?.cancel();
    _sleepTicker?.cancel();
    for (final sub in _subs) {
      await sub.cancel();
    }
    _subs.clear();
    await _queueOperation;
    _disposing = true;
    _loadGeneration++;
    await _player.dispose();
    _current.dispose();
    _playing.dispose();
    _processing.dispose();
    _failedSong.dispose();
    _position.dispose();
    _duration.dispose();
    _songQueue.dispose();
    _volume.dispose();
    _shuffle.dispose();
    _repeat.dispose();
    _sleepRemaining.dispose();
  }
}
