import 'dart:io';
import 'dart:convert';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart';
import '../models/video_item.dart';

class VideoCacheComponent {
  final int maxCacheSize; // in bytes
  late Directory _cacheDir;
  Map<String, VideoItem> _cachedVideos = {};
  
  VideoCacheComponent({this.maxCacheSize = 1024 * 1024 * 1024}); // 1GB default
  
  Future<void> initialize() async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      _cacheDir = Directory('${appDir.path}/video_cache');
    } catch (e) {
      // Fallback to temporary directory if app documents directory is not available
      debugPrint('Error accessing app documents directory: $e');
      final tempDir = await Directory.systemTemp.createTemp('video_cache');
      _cacheDir = tempDir;
    }
    
    if (!await _cacheDir.exists()) {
      await _cacheDir.create(recursive: true);
    }
    
    // Load cache index
    await _loadCacheIndex();
  }
  
  Future<void> _loadCacheIndex() async {
    try {
      final indexFile = File('${_cacheDir.path}/cache_index.json');
      if (await indexFile.exists()) {
        final indexData = await indexFile.readAsString();
        final List<dynamic> index = jsonDecode(indexData);
        _cachedVideos = {
          for (var item in index)
            item['id']: VideoItem.fromJson(item)
        };
      }
    } catch (e) {
      debugPrint('Error loading cache index: $e');
    }
  }
  
  Future<void> _saveCacheIndex() async {
    try {
      final indexFile = File('${_cacheDir.path}/cache_index.json');
      final indexData = jsonEncode(_cachedVideos.values.map((v) => v.toJson()).toList());
      await indexFile.writeAsString(indexData);
    } catch (e) {
      debugPrint('Error saving cache index: $e');
    }
  }
  
  Future<bool> hasVideo(String videoId) async {
    return _cachedVideos.containsKey(videoId) && 
           await File('${_cacheDir.path}/$videoId.mp4').exists();
  }
  
  Future<File?> getVideo(String videoId) async {
    if (await hasVideo(videoId)) {
      return File('${_cacheDir.path}/$videoId.mp4');
    }
    return null;
  }
  
  Future<void> storeVideo(VideoItem video, File videoFile) async {
    final cacheFile = File('${_cacheDir.path}/${video.id}.mp4');
    
    // Check if we need to free up space
    await _ensureSpace(video.size);
    
    // Copy file to cache
    await videoFile.copy(cacheFile.path);
    
    // Update index
    _cachedVideos[video.id] = video;
    await _saveCacheIndex();
  }
  
  Future<void> _ensureSpace(int requiredSize) async {
    int currentSize = await _getCurrentCacheSize();
    
    if (currentSize + requiredSize > maxCacheSize) {
      // Sort videos by least recently accessed
      final videoEntries = _cachedVideos.entries.toList()
        ..sort((a, b) => a.value.size.compareTo(b.value.size));
      
      // Remove videos until we have enough space
      for (var entry in videoEntries) {
        if (currentSize + requiredSize <= maxCacheSize) break;
        
        final videoFile = File('${_cacheDir.path}/${entry.key}.mp4');
        if (await videoFile.exists()) {
          final fileSize = await videoFile.length();
          await videoFile.delete();
          currentSize -= fileSize;
          _cachedVideos.remove(entry.key);
        }
      }
      
      await _saveCacheIndex();
    }
  }
  
  Future<int> _getCurrentCacheSize() async {
    int totalSize = 0;
    final cacheFiles = await _cacheDir.list().toList();
    
    for (var file in cacheFiles) {
      if (file is File && !file.path.endsWith('cache_index.json')) {
        totalSize += await file.length();
      }
    }
    
    return totalSize;
  }
  
  Future<void> clearCache() async {
    final cacheFiles = await _cacheDir.list().toList();
    for (var file in cacheFiles) {
      if (file is File) {
        await file.delete();
      }
    }
    _cachedVideos.clear();
    await _saveCacheIndex();
  }
  
  // Method to adapt video quality if needed
  Future<File> adaptVideoQuality(String videoId, String targetQuality) async {
    // In a real implementation, this would transcode the video
    // For now, we'll just return the existing file
    return File('${_cacheDir.path}/$videoId.mp4');
  }
} 