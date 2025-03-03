import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import '../models/video_item.dart';
import 'video_buffer_component.dart';
import 'video_cache_component.dart';

enum VideoSource {
  buffer,
  cache,
  network
}

class VideoDeliveryComponent {
  final VideoBufferComponent bufferComponent;
  final VideoCacheComponent cacheComponent;
  final int maxConcurrentStreams;
  
  int _activeStreams = 0;
  
  VideoDeliveryComponent({
    required this.bufferComponent,
    required this.cacheComponent,
    this.maxConcurrentStreams = 5,
  });
  
  Future<Map<String, dynamic>> requestVideo(VideoItem video) async {
    // Check if admission control passes
    if (!_admissionControl()) {
      return {
        'success': false,
        'source': VideoSource.network,
        'message': 'Proxy overloaded, stream directly from source',
        'videoUrl': video.url,
      };
    }
    
    // Try to get video from buffer first (fastest)
    if (bufferComponent.isVideoBuffered(video.id)) {
      _activeStreams++;
      return {
        'success': true,
        'source': VideoSource.buffer,
        'message': 'Serving from memory buffer',
        'data': bufferComponent.getBufferedVideo(video.id),
        'onComplete': () => _activeStreams--,
      };
    }
    
    // Try to get from disk cache next
    final cachedFile = await cacheComponent.getVideo(video.id);
    if (cachedFile != null) {
      // Start buffering it for next time
      bufferComponent.bufferVideo(video);
      
      _activeStreams++;
      return {
        'success': true,
        'source': VideoSource.cache,
        'message': 'Serving from disk cache',
        'file': cachedFile,
        'onComplete': () => _activeStreams--,
      };
    }
    
    // Start buffering from network in background
    bufferComponent.bufferVideo(video, onProgress: (progress) {
      debugPrint('Buffering progress: ${(progress * 100).toStringAsFixed(1)}%');
    });
    
    // Return network source since we don't have it cached yet
    return {
      'success': true,
      'source': VideoSource.network,
      'message': 'Streaming from original source while buffering',
      'videoUrl': video.url,
    };
  }
  
  bool _admissionControl() {
    // Simple admission control based on concurrent streams
    return _activeStreams < maxConcurrentStreams;
  }
  
  Future<void> adaptVideoQuality(String videoId, String quality) async {
    // This would handle quality adaptation in a real implementation
    await cacheComponent.adaptVideoQuality(videoId, quality);
  }
} 