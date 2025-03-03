import 'package:flutter/foundation.dart';
import '../models/video_item.dart';
import 'video_cache_component.dart';
import 'video_buffer_component.dart';
import 'video_delivery_component.dart';

class VideoProxyManager {
  late VideoCacheComponent _cacheComponent;
  late VideoBufferComponent _bufferComponent;
  late VideoDeliveryComponent _deliveryComponent;
  bool _initialized = false;
  
  // Singleton pattern
  static final VideoProxyManager _instance = VideoProxyManager._internal();
  
  factory VideoProxyManager() {
    return _instance;
  }
  
  VideoProxyManager._internal();
  
  Future<void> initialize({
    int maxCacheSize = 1024 * 1024 * 1024, // 1GB
    int maxBufferSize = 200 * 1024 * 1024, // 200MB
    int maxConcurrentStreams = 5,
  }) async {
    if (_initialized) return;
    
    _cacheComponent = VideoCacheComponent(maxCacheSize: maxCacheSize);
    await _cacheComponent.initialize();
    
    _bufferComponent = VideoBufferComponent(
      cacheComponent: _cacheComponent,
      maxBufferSize: maxBufferSize,
    );
    
    _deliveryComponent = VideoDeliveryComponent(
      bufferComponent: _bufferComponent,
      cacheComponent: _cacheComponent,
      maxConcurrentStreams: maxConcurrentStreams,
    );
    
    _initialized = true;
    debugPrint('Video Proxy Manager initialized');
  }
  
  Future<Map<String, dynamic>> requestVideo(VideoItem video) async {
    _ensureInitialized();
    return await _deliveryComponent.requestVideo(video);
  }
  
  Future<void> preloadVideo(VideoItem video) async {
    _ensureInitialized();
    await _bufferComponent.bufferVideo(video);
  }
  
  Future<void> clearCache() async {
    _ensureInitialized();
    await _cacheComponent.clearCache();
    _bufferComponent.clearBuffer();
  }
  
  Future<void> adaptVideoQuality(String videoId, String quality) async {
    _ensureInitialized();
    await _deliveryComponent.adaptVideoQuality(videoId, quality);
  }
  
  void _ensureInitialized() {
    if (!_initialized) {
      throw Exception('VideoProxyManager not initialized. Call initialize() first.');
    }
  }
} 