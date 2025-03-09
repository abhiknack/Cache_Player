import 'dart:async';
import 'dart:developer';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_preload_videos/core/constants.dart';
import 'package:flutter_preload_videos/service/api_service.dart';
import 'package:video_player/video_player.dart';
import 'package:better_player/better_player.dart';
// Model class for our state
class PreloadState {
  final List<String> urls;
  final Map<int, VideoPlayerController?> controllers;
  final int focusedIndex;
  final int reloadCounter;
  final bool isLoading;

  const PreloadState({
    required this.urls,
    required this.controllers,
    required this.focusedIndex,
    required this.reloadCounter,
    required this.isLoading,
  });

  PreloadState copyWith({
    List<String>? urls,
    Map<int, VideoPlayerController?>? controllers,
    int? focusedIndex,
    int? reloadCounter,
    bool? isLoading,
  }) {
    return PreloadState(
      urls: urls ?? this.urls,
      controllers: controllers ?? this.controllers,
      focusedIndex: focusedIndex ?? this.focusedIndex,
      reloadCounter: reloadCounter ?? this.reloadCounter,
      isLoading: isLoading ?? this.isLoading,
    );
  }

  // Initial state factory
  factory PreloadState.initial() => PreloadState(
        urls: [],
        controllers: {},
        focusedIndex: 0,
        reloadCounter: 0,
        isLoading: false,
      );
}

// Isolate task to fetch videos
void _getVideosTask(SendPort mySendPort) async {
  ReceivePort isolateReceivePort = ReceivePort();

  mySendPort.send(isolateReceivePort.sendPort);

  await for (var message in isolateReceivePort) {
    if (message is List) {
      final int index = message[0];
      final SendPort isolateResponseSendPort = message[1];

      final List<String> urls =
          await ApiService.getVideos(id: index + kPreloadLimit);

      isolateResponseSendPort.send(urls);
    }
  }
}

// Create the provider
class PreloadNotifier extends StateNotifier<PreloadState> {
  PreloadNotifier() : super(PreloadState.initial());

  void setLoading() {
    state = state.copyWith(isLoading: true);
  }

  // Method to get initial videos
  Future<void> getVideosFromApi() async {
    // Fetch first batch of videos from api
    final List<String> _urls = await ApiService.getVideos();
    
    final updatedUrls = [...state.urls, ..._urls];
    state = state.copyWith(urls: updatedUrls);

    // Initialize 1st video
    await _initializeControllerAtIndex(0);

    // Play 1st video
    _playControllerAtIndex(0);

    // Initialize 2nd video
    await _initializeControllerAtIndex(1);

    state = state.copyWith(reloadCounter: state.reloadCounter + 1);
  }

  // Method to handle video index changes
  Future<void> onVideoIndexChanged(int index) async {
    // Condition to fetch new videos
    final bool shouldFetch = (index + kPreloadLimit) % kNextLimit == 0 &&
        state.urls.length == index + kPreloadLimit;

    if (shouldFetch) {
      await _createIsolate(index);
    }

    // Next / Prev video decider
    if (index > state.focusedIndex) {
      _playNext(index);
    } else {
      _playPrevious(index);
    }

    state = state.copyWith(focusedIndex: index);
  }

  // Method to update URLs
  void updateUrls(List<String> urls) {
    final updatedUrls = [...state.urls, ...urls];
    state = state.copyWith(
      urls: updatedUrls,
      reloadCounter: state.reloadCounter + 1,
      isLoading: false,
    );

    // Initialize new url
    _initializeControllerAtIndex(state.focusedIndex + 1);
    
    log('🚀🚀🚀 NEW VIDEOS ADDED');
  }

  // Isolate to fetch videos in the background
  Future<void> _createIsolate(int index) async {
    // Set loading to true
    setLoading();

    ReceivePort mainReceivePort = ReceivePort();

    Isolate.spawn<SendPort>(_getVideosTask, mainReceivePort.sendPort);

    SendPort isolateSendPort = await mainReceivePort.first;

    ReceivePort isolateResponseReceivePort = ReceivePort();

    isolateSendPort.send([index, isolateResponseReceivePort.sendPort]);

    final isolateResponse = await isolateResponseReceivePort.first;
    final urls = isolateResponse as List<String>;

    // Update new urls
    updateUrls(urls);
  }

  void _playNext(int index) {
    // Stop [index - 1] controller
    _stopControllerAtIndex(index - 1);

    // Dispose [index - 2] controller
    _disposeControllerAtIndex(index - 2);

    // Play current video (already initialized)
    _playControllerAtIndex(index);

    // Initialize [index + 1] controller
    _initializeControllerAtIndex(index + 1);
  }

  void _playPrevious(int index) {
    // Stop [index + 1] controller
    _stopControllerAtIndex(index + 1);

    // Dispose [index + 2] controller
    _disposeControllerAtIndex(index + 2);

    // Play current video (already initialized)
    _playControllerAtIndex(index);

    // Initialize [index - 1] controller
    _initializeControllerAtIndex(index - 1);
  }

  Future<void> _initializeControllerAtIndex(int index) async {
    if (state.urls.length > index && index >= 0) {
      // Create new controller
      final VideoPlayerController controller = VideoPlayerController.networkUrl(Uri.parse(state.urls[index]));
      
     

      // Add to [controllers] list first so the UI can show loading state
      final updatedControllers = {...state.controllers};
      updatedControllers[index] = controller;
      state = state.copyWith(controllers: updatedControllers);

      // Setup data source and wait for initialization
      await controller.initialize();
      
      log('🚀🚀🚀 INITIALIZED $index');
    }
  }

  void _playControllerAtIndex(int index) {
    if (state.urls.length > index && index >= 0) {
      // Get controller at [index]
      final VideoPlayerController? controller = state.controllers[index];

      if (controller != null) {
        // Play controller
        controller.play();
        log('🚀🚀🚀 PLAYING $index');
      }
    }
  }

  void _stopControllerAtIndex(int index) {
    if (state.urls.length > index && index >= 0) {
      // Get controller at [index]
      final VideoPlayerController? controller = state.controllers[index];

      if (controller != null) {
        // Pause
        controller.pause();

        // Reset position to beginning
        controller.seekTo(const Duration());

        log('🚀🚀🚀 STOPPED $index');
      }
    }
  }

  void _disposeControllerAtIndex(int index) {
    if (state.urls.length > index && index >= 0) {
      // Get controller at [index]
      final VideoPlayerController? controller = state.controllers[index];

      if (controller != null) {
        // Dispose controller
        controller.dispose();
        
        final updatedControllers = {...state.controllers};
        updatedControllers.remove(index);
        state = state.copyWith(controllers: updatedControllers);

        log('🚀🚀🚀 DISPOSED $index');
      }
    }
  }
}

// Create the provider
final preloadProvider = StateNotifierProvider<PreloadNotifier, PreloadState>((ref) {
  return PreloadNotifier();
}); 