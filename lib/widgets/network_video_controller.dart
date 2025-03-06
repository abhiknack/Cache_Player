import 'dart:io';
import 'dart:typed_data';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

// Define a function type for controller change listeners
typedef ControllerChangeCallback = void Function(VideoPlayerController controller);

/// A custom controller for network videos that handles buffered content properly
class NetworkVideoController {
  VideoPlayerController? _controller;
  bool _isInitialized = false;
  File? _tempFile;
  Directory? _tempDir;
  
  // Track how much of the video is buffered
  int _bufferedBytes = 0;
  int _totalBytes = 0;
  double _bufferedPercentage = 0.0;
  bool _isOffline = false;
  
  // Store the original URL
  final String _videoUrl;
  
  // Store the buffer data for seeking
  Uint8List? _bufferData;
  
  // Track buffered ranges
  final List<DurationRange> _bufferedRanges = [];
  
  // List of controller change listeners
  final List<ControllerChangeCallback> _controllerChangeListeners = [];
  
  NetworkVideoController(this._videoUrl);
  
  /// Initialize the controller with the network URL
  Future<VideoPlayerController> initialize() async {
    try {
      // Create the network controller
      _controller = VideoPlayerController.networkUrl(Uri.parse(_videoUrl));
      
      // Initialize the controller
      await _controller!.initialize();
      
      // Setup buffer tracking
      _setupBufferTracking();
      
      // Start buffering in background
      _startBuffering();
      
      _isInitialized = true;
      
      return _controller!;
    } catch (e) {
      debugPrint('Error initializing network video controller: $e');
      await dispose();
      rethrow;
    }
  }
  
  /// Setup tracking of buffered ranges
  void _setupBufferTracking() {
    _controller!.addListener(() {
      if (_controller!.value.isInitialized) {
        // Update buffered ranges
        _bufferedRanges.clear();
        _bufferedRanges.addAll(_controller!.value.buffered);
        
        // Calculate buffer percentage
        if (_controller!.value.duration.inMilliseconds > 0) {
          int totalBufferedMs = 0;
          for (var range in _bufferedRanges) {
            totalBufferedMs += (range.end.inMilliseconds - range.start.inMilliseconds);
          }
          _bufferedPercentage = totalBufferedMs / _controller!.value.duration.inMilliseconds;
          debugPrint('📊 Buffer update: ${(_bufferedPercentage * 100).toStringAsFixed(1)}% buffered');
        }
      }
    });
  }
  
  /// Start buffering the video in the background
  Future<void> _startBuffering() async {
    try {
      // Create temporary directory for buffer
      _tempDir = await getTemporaryDirectory();
      final String tempPath = _tempDir!.path;
      final String tempFilePath = '$tempPath/temp_network_video_${DateTime.now().millisecondsSinceEpoch}.mp4';
      _tempFile = File(tempFilePath);
      
      // Start downloading the video in the background
      _downloadVideo();
    } catch (e) {
      debugPrint('Error starting buffer: $e');
    }
  }
  
  /// Download the video in the background
  Future<void> _downloadVideo() async {
    try {
      final client = http.Client();
      final request = http.Request('GET', Uri.parse(_videoUrl));
      final response = await client.send(request);
      
      _totalBytes = response.contentLength ?? 0;
      int downloadedBytes = 0;
      final List<int> bytes = [];
      
      debugPrint('🌐 Starting download of video: $_videoUrl');
      debugPrint('📦 Total size: ${(_totalBytes / 1024 / 1024).toStringAsFixed(2)} MB');
      
      await for (var chunk in response.stream) {
        bytes.addAll(chunk);
        downloadedBytes += chunk.length;
        
        // Update buffer stats
        _bufferedBytes = downloadedBytes;
        if (_totalBytes > 0) {
          final progress = downloadedBytes / _totalBytes;
          debugPrint('📥 Download progress: ${(progress * 100).toStringAsFixed(1)}%');
        }
        
        // Every 5MB or when complete, update the buffer data
        if (bytes.length >= 5 * 1024 * 1024 || downloadedBytes == _totalBytes) {
          // Always keep the most complete buffer data we've seen
          _bufferData = Uint8List.fromList(bytes);
          
          try {
            // Save current position and playback state
            final currentPosition = _controller?.value.position;
            final wasPlaying = _controller?.value.isPlaying ?? false;
            
            // Write the buffer to the temp file
            await _tempFile!.writeAsBytes(_bufferData!);
            debugPrint('💾 Updated buffer file: ${(_bufferData!.length / 1024 / 1024).toStringAsFixed(2)} MB');
            
            // If we're not playing or at the beginning, we can safely recreate the controller
            // This helps with some video_player issues where the file changes aren't detected
            if (_controller != null && (!wasPlaying || (currentPosition?.inMilliseconds ?? 0) < 1000)) {
              debugPrint('🔄 Recreating controller to ensure buffer changes are recognized');
              
              // Dispose old controller
              final oldController = _controller;
              
              // Create new controller from the file with buffer data
              _controller = VideoPlayerController.file(_tempFile!);
              await _controller!.initialize();
              
              // Restore position and playback state
              if (currentPosition != null) {
                await _controller!.seekTo(currentPosition);
              }
              
              if (wasPlaying) {
                await _controller!.play();
              }
              
              // Setup buffer tracking again
              _setupBufferTracking();
              
              // Notify listeners of controller change
              for (var listener in _controllerChangeListeners) {
                listener(_controller!);
              }
              
              // Dispose old controller after setting up the new one
              await oldController?.dispose();
            }
          } catch (e) {
            debugPrint('❌ Error updating buffer: $e');
          }
        }
      }
      
      // Final update - switch to using the complete buffered file
      try {
        final currentPosition = _controller?.value.position;
        final wasPlaying = _controller?.value.isPlaying ?? false;
        
        // Create new controller from the complete file
        final oldController = _controller;
        _controller = VideoPlayerController.file(_tempFile!);
        await _controller!.initialize();
        
        // Restore position and playback state
        if (currentPosition != null) {
          await _controller!.seekTo(currentPosition);
        }
        
        if (wasPlaying) {
          await _controller!.play();
        }
        
        // Setup buffer tracking again
        _setupBufferTracking();
        
        // Notify listeners of controller change
        for (var listener in _controllerChangeListeners) {
          listener(_controller!);
        }
        
        // Dispose old controller
        await oldController?.dispose();
        
        debugPrint('✅ Switched to buffered playback');
      } catch (e) {
        debugPrint('❌ Error switching to buffered playback: $e');
      }
      
    } catch (e) {
      debugPrint('❌ Error downloading video: $e');
    }
  }
  
  /// Check if a particular position is within the buffered portion
  bool isPositionBuffered(Duration position) {
    // Basic validation
    if (_controller == null || position.inMilliseconds < 0) {
      return false;
    }

    // If we have the complete buffer data, all positions are available
    if (_bufferData != null && _totalBytes > 0 && _bufferedBytes >= _totalBytes) {
      debugPrint('✅ Position ${position.inSeconds}s is buffered (complete buffer available)');
      return true;
    }

    // If we have partial buffer data, check if the position is within what we've buffered
    if (_bufferData != null && _totalBytes > 0) {
      // Calculate position percentage
      final totalDuration = _controller!.value.duration;
      if (totalDuration.inMilliseconds > 0) {
        final positionPercentage = position.inMilliseconds / totalDuration.inMilliseconds;
        final bufferedPercentage = _bufferedBytes / _totalBytes;
        
        // Add a small margin for safety (1%)
        final isBuffered = positionPercentage <= (bufferedPercentage - 0.01);
        
        if (isBuffered) {
          debugPrint('✅ Position ${position.inSeconds}s (${(positionPercentage * 100).toStringAsFixed(1)}%) is within buffered range (${(bufferedPercentage * 100).toStringAsFixed(1)}%)');
        } else {
          debugPrint('❌ Position ${position.inSeconds}s (${(positionPercentage * 100).toStringAsFixed(1)}%) is outside buffered range (${(bufferedPercentage * 100).toStringAsFixed(1)}%)');
        }
        
        return isBuffered;
      }
    }
    
    // Check if position is within any buffered range from the controller
    for (var range in _bufferedRanges) {
      if (position >= range.start && position <= range.end) {
        debugPrint('✅ Position ${position.inSeconds}s is within buffered range ${range.start.inSeconds}s-${range.end.inSeconds}s');
        return true;
      }
    }
    
    debugPrint('❌ Position ${position.inSeconds}s is not buffered');
    return false;
  }
  
  /// Seek safely, respecting buffered ranges
  Future<void> seekTo(Duration position) async {
    if (_controller == null) return;
    
    try {
      // Debug information about seeking
      final Duration currentPosition = _controller!.value.position;
      debugPrint('⏩ Seeking from ${currentPosition.inSeconds}s to ${position.inSeconds}s');
      
      // Determine if this is a backward seek (to content we've already seen)
      bool isBackwardSeek = position < currentPosition;
      debugPrint('🔄 Direction: ${isBackwardSeek ? "BACKWARD ◀️" : "FORWARD ▶️"}');
      
      // Check if we're seeking to a position that should be in our buffer
      bool shouldBeBuffered = isBackwardSeek || isPositionBuffered(position);
      
      // For seeks to buffered content, use our buffer data
      if (shouldBeBuffered && _bufferData != null && _tempFile != null) {
        debugPrint('🔍 Using buffered data for seeking');
        debugPrint('📊 Buffer stats: ${(_bufferedBytes / 1024 / 1024).toStringAsFixed(2)}MB / ${(_totalBytes / 1024 / 1024).toStringAsFixed(2)}MB');
        
        // Save the playback state
        bool wasPlaying = _controller!.value.isPlaying;
        if (wasPlaying) {
          await _controller!.pause();
        }
        
        try {
          // CRITICAL FIX: Force the video player to use our local file by recreating the controller
          // This ensures we're not using the network for buffered content
          
          // Dispose old controller
          final oldController = _controller;
          
          // Write the current buffer to the temp file
          await _tempFile!.writeAsBytes(_bufferData!);
          debugPrint('💾 Updated temp file with buffer data');
          
          // Create new controller from the file with buffer data
          _controller = VideoPlayerController.file(_tempFile!);
          
          // Initialize the new controller
          debugPrint('🔄 Initializing new controller from file');
          await _controller!.initialize();
          debugPrint('✅ New controller initialized');
          
          // Seek to the desired position
          debugPrint('⏩ Seeking to ${position.inSeconds}s on new controller');
          await _controller!.seekTo(position);
          
          // Restore playback state
          if (wasPlaying) {
            debugPrint('▶️ Resuming playback');
            await _controller!.play();
          }
          
          // Setup buffer tracking again
          _setupBufferTracking();
          
          // Notify listeners of controller change
          debugPrint('🔔 Notifying ${_controllerChangeListeners.length} listeners of controller change');
          for (var listener in _controllerChangeListeners) {
            listener(_controller!);
          }
          
          // Dispose old controller after setting up the new one
          debugPrint('🗑️ Disposing old controller');
          await oldController?.dispose();
          
          debugPrint('✅ Seek completed using buffered data');
          return;
        } catch (e) {
          debugPrint('❌ Error during buffered seek: $e');
          // Fall back to standard seek if the buffered approach fails
        }
      } else {
        if (!shouldBeBuffered) {
          debugPrint('⚠️ Position not in buffered range');
        } else {
          debugPrint('⚠️ No buffer data available for seeking');
        }
      }
      
      // Standard seek for other cases
      bool wasPlaying = _controller!.value.isPlaying;
      if (wasPlaying) {
        await _controller!.pause();
      }
      
      await _controller!.seekTo(position);
      
      if (wasPlaying) {
        await _controller!.play();
      }
      
      debugPrint('✅ Standard seek completed');
    } catch (e) {
      debugPrint('❌ Error during seek: $e');
    }
  }
  
  /// Dispose of the controller and clean up temp files
  Future<void> dispose() async {
    // Clear all controller change listeners
    _controllerChangeListeners.clear();
    
    if (_controller != null) {
      await _controller!.dispose();
      _controller = null;
    }
    
    // Clean up temp file
    if (_tempFile != null && await _tempFile!.exists()) {
      try {
        await _tempFile!.delete();
      } catch (e) {
        debugPrint('Error deleting temp file: $e');
      }
      _tempFile = null;
    }
    
    // Clean up temp directory
    if (_tempDir != null && await _tempDir!.exists()) {
      try {
        await _tempDir!.delete(recursive: true);
      } catch (e) {
        debugPrint('Error deleting temp directory: $e');
      }
      _tempDir = null;
    }
    
    _isInitialized = false;
    _bufferedBytes = 0;
    _totalBytes = 0;
    _bufferedPercentage = 0.0;
    _isOffline = false;
    _bufferData = null;
    _bufferedRanges.clear();
  }
  
  /// Add a listener to be notified when the controller changes
  void addControllerChangeListener(ControllerChangeCallback listener) {
    _controllerChangeListeners.add(listener);
  }
  
  /// Remove a controller change listener
  void removeControllerChangeListener(ControllerChangeCallback listener) {
    _controllerChangeListeners.remove(listener);
  }
  
  bool get isInitialized => _isInitialized;
  VideoPlayerController? get controller => _controller;
  double get bufferedPercentage => _bufferedPercentage;
} 