import 'dart:async';
import 'dart:math' show max;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_preload_videos/providers/preload_provider.dart';
import 'package:video_player/video_player.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

class VideoPage extends ConsumerWidget {
  const VideoPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(preloadProvider);
    final notifier = ref.read(preloadProvider.notifier);

    return SafeArea(
      child: PageView.builder(
        itemCount: state.urls.length,
        scrollDirection: Axis.vertical,
        onPageChanged: (index) => notifier.onVideoIndexChanged(index),
        itemBuilder: (context, index) {
          // Is at end and isLoading
          final bool _isLoading =
              (state.isLoading && index == state.urls.length - 1);

          // Skip if controller is null or index doesn't match focused index
          if (state.controllers[index] == null) {
            print('[DEBUG] VideoWidget: Skipping widget for index $index');
            return const SizedBox(
              child: Text('Skipping widget for index ',
              style: TextStyle(color: Colors.white) ,),
            );
          }
          
          return VideoWidget(
            isLoading: _isLoading,
            controller: state.controllers[index]!,
          );
        },
      ),
    );
  }
}

/// Custom Feed Widget consisting video
class VideoWidget extends StatefulWidget {
  const VideoWidget({
    Key? key,
    required this.isLoading,
    required this.controller,
  }) : super(key: key);

  final bool isLoading;
  final VideoPlayerController controller;

  @override
  State<VideoWidget> createState() => _VideoWidgetState();
}

class _VideoWidgetState extends State<VideoWidget> {
  late StreamSubscription<List<ConnectivityResult>> _connectivitySubscription;
  bool _wasPlayingBeforeDisconnect = false;
  Timer? _reconnectionTimer;
  Timer? _disposalGuard;

  @override
  void initState() {
    super.initState();
    _startPlayback();
    
    // Setup connectivity listener with debounce to avoid rapid state changes
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen((List<ConnectivityResult> results) {
      print('[DEBUG] VideoWidget: Connectivity changed: $results');
      
      // Cancel any pending timers to avoid multiple operations
      _reconnectionTimer?.cancel();
      _disposalGuard?.cancel();
      
      final hasConnection = !results.contains(ConnectivityResult.none) && results.isNotEmpty;
      
      if (!hasConnection) {
        // Network is gone - store current playing state and pause cleanly
        _wasPlayingBeforeDisconnect = widget.controller.value.isPlaying;
        print('[DEBUG] VideoWidget: Network lost, was playing: $_wasPlayingBeforeDisconnect');
        
        if (widget.controller.value.isPlaying) {
          // Safely pause without forcing anything
          widget.controller.pause();
        }
      } else {
        // Network is back - wait a moment for stable connection
        if (_wasPlayingBeforeDisconnect) {
          print('[DEBUG] VideoWidget: Network is back, waiting for stable connection');
          
          // Add a short delay to ensure connection is stable
          _reconnectionTimer = Timer(const Duration(seconds: 3), () {
            if (!mounted) return;
            
            print('[DEBUG] VideoWidget: Attempting to resume playback');
            _startPlayback();
          });
        }
      }
    });
  }
  
  void _startPlayback() {
    // Safe playback start with error handling
    if (!mounted) return;
    
    print('[DEBUG] VideoWidget: Starting playback');
    try {
      widget.controller.play().then((_) {
        print('[DEBUG] VideoWidget: Playback started successfully');
      }).catchError((error) {
        print('[DEBUG] VideoWidget: Error starting playback: $error');
      });
    } catch (e) {
      print('[DEBUG] VideoWidget: Exception during play: $e');
    }
  }

  @override
  void dispose() {
    print('[DEBUG] VideoWidget: Disposing resources');
    
    // Cancel all timers first
    _reconnectionTimer?.cancel();
    _disposalGuard?.cancel();
    
    // Use disposal guard to ensure clean disconnection
    try {
      _connectivitySubscription.cancel();
    } catch (e) {
      print('[DEBUG] VideoWidget: Error canceling connectivity subscription: $e');
    }
    
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              VideoPlayer(widget.controller),
              // Add transparent touch detector to restart playback if needed
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: () {
                    if (!widget.controller.value.isPlaying) {
                      print('[DEBUG] VideoWidget: Manual tap to restart playback');
                      _startPlayback();
                    }
                  },
                ),
              ),
            ],
          ),
        ),
        AnimatedCrossFade(
          alignment: Alignment.bottomCenter,
          sizeCurve: Curves.decelerate,
          duration: const Duration(milliseconds: 400),
          firstChild: Padding(
            padding: const EdgeInsets.all(10.0),
            child: CupertinoActivityIndicator(
              color: Colors.white,
              radius: 8,
            ),
          ),
          secondChild: const SizedBox(),
          crossFadeState: widget.isLoading ? CrossFadeState.showFirst : CrossFadeState.showSecond,
        ),
      ],
    );
  }
}
