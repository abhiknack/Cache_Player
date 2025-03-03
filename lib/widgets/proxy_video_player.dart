import 'dart:io';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import '../models/video_item.dart';
import '../cache/video_proxy_manager.dart';
import '../cache/video_delivery_component.dart';

class ProxyVideoPlayer extends StatefulWidget {
  final VideoItem video;
  
  const ProxyVideoPlayer({
    Key? key,
    required this.video,
  }) : super(key: key);

  @override
  _ProxyVideoPlayerState createState() => _ProxyVideoPlayerState();
}

class _ProxyVideoPlayerState extends State<ProxyVideoPlayer> {
  VideoPlayerController? _controller;
  bool _isInitialized = false;
  bool _isLoading = true;
  String _statusMessage = 'Loading...';
  
  @override
  void initState() {
    super.initState();
    _initializePlayer();
  }
  
  Future<void> _initializePlayer() async {
    setState(() {
      _isLoading = true;
      _statusMessage = 'Requesting video...';
    });
    
    try {
      final proxyManager = VideoProxyManager();
      final result = await proxyManager.requestVideo(widget.video);
      
      if (!result['success']) {
        // Fall back to network source
        _initializeNetworkController(widget.video.url);
        _statusMessage = result['message'];
        return;
      }
      
      switch (result['source']) {
        case VideoSource.buffer:
          // Not directly supported by video_player, but could be implemented
          // with a custom data source in a full implementation
          _initializeNetworkController(widget.video.url);
          _statusMessage = 'Buffered video not directly supported, using network source';
          break;
          
        case VideoSource.cache:
          _initializeFileController(result['file']);
          _statusMessage = 'Playing from cache';
          break;
          
        case VideoSource.network:
          _initializeNetworkController(result['videoUrl']);
          _statusMessage = result['message'];
          break;
          
        default:
          _initializeNetworkController(widget.video.url);
          _statusMessage = 'Using default network source';
      }
    } catch (e) {
      debugPrint('Error initializing player: $e');
      _initializeNetworkController(widget.video.url);
      _statusMessage = 'Error: $e, falling back to network source';
    }
  }
  
  void _initializeFileController(File file) {
    _controller = VideoPlayerController.file(file);
    _completeInitialization();
  }
  
  void _initializeNetworkController(String url) {
    _controller = VideoPlayerController.networkUrl(Uri.parse(url));
    _completeInitialization();
  }
  
  Future<void> _completeInitialization() async {
    await _controller!.initialize();
    await _controller!.play();
    
    setState(() {
      _isInitialized = true;
      _isLoading = false;
    });
  }
  
  @override
  void dispose() {
    _controller!.dispose();
    super.dispose();
  }
  
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        AspectRatio(
          aspectRatio: _isInitialized && _controller != null ? _controller!.value.aspectRatio : 16 / 9,
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (_isInitialized && _controller != null)
                VideoPlayer(_controller!)
              else
                Container(color: Colors.black),
                
              if (_isLoading)
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text(
                      _statusMessage,
                      style: TextStyle(color: Colors.white),
                    ),
                  ],
                ),
            ],
          ),
        ),
        if (_controller != null)
          VideoProgressIndicator(
            _controller!,
            allowScrubbing: true,
            padding: EdgeInsets.all(16),
          ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (_controller != null)
              IconButton(
                icon: Icon(_controller!.value.isPlaying ? Icons.pause : Icons.play_arrow),
                onPressed: () {
                  setState(() {
                    _controller!.value.isPlaying
                        ? _controller!.pause()
                        : _controller!.play();
                  });
                },
              ),
            Text(_statusMessage),
          ],
        ),
      ],
    );
  }
} 