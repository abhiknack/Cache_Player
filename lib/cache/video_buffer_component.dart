import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/video_item.dart';
import 'video_cache_component.dart';

class VideoBufferComponent {
  final int maxBufferSize; // in bytes
  final VideoCacheComponent cacheComponent;
  
  // Map of video ID to buffered data
  final Map<String, Uint8List> _bufferedVideos = {};
  // Map of video ID to download progress
  final Map<String, double> _downloadProgress = {};
  
  VideoBufferComponent({
    required this.cacheComponent,
    this.maxBufferSize = 200 * 1024 * 1024, // 200MB default
  });
  
  bool isVideoBuffered(String videoId) {
    return _bufferedVideos.containsKey(videoId);
  }
  
  double getDownloadProgress(String videoId) {
    return _downloadProgress[videoId] ?? 0.0;
  }
  
  Uint8List? getBufferedVideo(String videoId) {
    return _bufferedVideos[videoId];
  }
  
  Future<void> bufferVideo(VideoItem video, {Function(double)? onProgress}) async {
    // Check if already buffered
    if (isVideoBuffered(video.id)) {
      return;
    }
    
    // Check if in disk cache
    final cachedFile = await cacheComponent.getVideo(video.id);
    if (cachedFile != null) {
      _bufferedVideos[video.id] = await cachedFile.readAsBytes();
      _downloadProgress[video.id] = 1.0;
      onProgress?.call(1.0);
      return;
    }
    
    // Download from network
    try {
      final client = http.Client();
      final request = http.Request('GET', Uri.parse(video.url));
      final response = await client.send(request);
      
      final contentLength = response.contentLength ?? 0;
      int downloadedBytes = 0;
      final List<int> bytes = [];
      
      _downloadProgress[video.id] = 0.0;
      
      await for (var chunk in response.stream) {
        bytes.addAll(chunk);
        downloadedBytes += chunk.length;
        
        if (contentLength > 0) {
          final progress = downloadedBytes / contentLength;
          _downloadProgress[video.id] = progress;
          onProgress?.call(progress);
        }
      }
      
      // Ensure we have enough space in buffer
      _ensureBufferSpace(bytes.length);
      
      // Store in buffer
      final Uint8List videoData = Uint8List.fromList(bytes);
      _bufferedVideos[video.id] = videoData;
      _downloadProgress[video.id] = 1.0;
      
      // Save to disk cache in background
      _saveToCache(video, videoData);
      
    } catch (e) {
      debugPrint('Error buffering video: $e');
      _downloadProgress.remove(video.id);
      rethrow;
    }
  }
  
  void _ensureBufferSpace(int requiredSize) {
    int currentSize = 0;
    for (var data in _bufferedVideos.values) {
      currentSize += data.length;
    }
    
    if (currentSize + requiredSize > maxBufferSize) {
      // Remove oldest items until we have enough space
      final keys = _bufferedVideos.keys.toList();
      for (var key in keys) {
        if (currentSize + requiredSize <= maxBufferSize) break;
        
        currentSize -= _bufferedVideos[key]!.length;
        _bufferedVideos.remove(key);
        _downloadProgress.remove(key);
      }
    }
  }
  
  Future<void> _saveToCache(VideoItem video, Uint8List data) async {
    try {
      final tempDir = await Directory.systemTemp.createTemp('video_buffer');
      final tempFile = File('${tempDir.path}/${video.id}.mp4');
      await tempFile.writeAsBytes(data);
      
      await cacheComponent.storeVideo(video, tempFile);
      
      // Clean up temp file
      await tempFile.delete();
      await tempDir.delete();
    } catch (e) {
      debugPrint('Error saving to cache: $e');
    }
  }
  
  void clearBuffer() {
    _bufferedVideos.clear();
    _downloadProgress.clear();
  }
} 