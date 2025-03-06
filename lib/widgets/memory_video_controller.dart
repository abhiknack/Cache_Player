import 'dart:io';
import 'dart:typed_data';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart';

// Define a function type for controller change listeners
typedef ControllerChangeCallback = void Function(VideoPlayerController controller);

/// A custom controller that allows playing videos directly from memory buffer
class MemoryVideoController {
  VideoPlayerController? _controller;
  bool _isInitialized = false;
  File? _tempFile;
  Directory? _tempDir;
  // Track how much of the video is buffered
  int _bufferedBytes = 0;
  int _totalBytes = 0;
  double _bufferedPercentage = 0.0;
  bool _isOffline = false;
  // Store the original complete data to ensure we don't lose it during updates
  Uint8List? _completeBufferData;
  
  // List of controller change listeners
  final List<ControllerChangeCallback> _controllerChangeListeners = [];
  
  /// Initializes a video player controller from a Uint8List buffer
  Future<VideoPlayerController> initialize(Uint8List videoData) async {
    try {
      // Store the complete buffer data - keeping this at the very beginning
      _completeBufferData = Uint8List.fromList(videoData);
      debugPrint('📦 Storing complete buffer: ${_completeBufferData!.length} bytes');
      
      // Create temporary file to hold the buffer data
      _tempDir = await getTemporaryDirectory();
      final String tempPath = _tempDir!.path;
      final String tempFilePath = '$tempPath/temp_buffer_video_${DateTime.now().millisecondsSinceEpoch}.mp4';
      _tempFile = File(tempFilePath);
      
      // Write buffer data to temp file
      debugPrint('💾 Writing complete data to temp file');
      await _tempFile!.writeAsBytes(_completeBufferData!);
      
      // Update buffering stats
      _bufferedBytes = videoData.length;
      _totalBytes = videoData.length;
      _bufferedPercentage = 1.0; // Assume fully buffered initially
      
      // Verify the file exists and has content
      if (!await _tempFile!.exists() || await _tempFile!.length() == 0) {
        throw Exception('Failed to create temporary file for video playback');
      }
      
      // Create controller from the temp file
      _controller?.dispose(); // Dispose any existing controller
      _controller = VideoPlayerController.file(_tempFile!);
      
      // Set up a listener to detect when the controller is initialized
      // This helps us know when the video is ready to play
      Completer<void> initCompleter = Completer<void>();
      
      void initListener() {
        if (_controller!.value.isInitialized) {
          _controller!.removeListener(initListener);
          if (!initCompleter.isCompleted) {
            initCompleter.complete();
          }
        } else if (_controller!.value.hasError) {
          _controller!.removeListener(initListener);
          if (!initCompleter.isCompleted) {
            initCompleter.completeError(_controller!.value.errorDescription ?? 'Unknown error');
          }
        }
      }
      
      _controller!.addListener(initListener);
      
      // Initialize the controller
      await _controller!.initialize();
      
      // Setup listener for network errors to detect offline status
      _controller!.addListener(_networkErrorListener);
      
      _isInitialized = true;
      
      return _controller!;
    } catch (e) {
      debugPrint('Error initializing memory video controller: $e');
      // Clean up resources on error
      await dispose();
      rethrow;
    }
  }
  
  /// Listen for network errors that might indicate offline status
  void _networkErrorListener() {
    if (_controller != null && _controller!.value.hasError) {
      // If we have a player error and we have partial buffer, assume we're offline
      if (_bufferedBytes > 0) {
        _isOffline = true;
        debugPrint('Network error detected, switching to offline mode with buffered content');
      }
    }
  }
  
  /// Check if a particular position (in milliseconds) is within the buffered portion
  bool isPositionBuffered(Duration position) {
    // Basic validation
    if (_controller == null || position.inMilliseconds < 0) {
      return false;
    }
    
    // If we have the complete buffer data, all positions are available
    if (_completeBufferData != null) {
      debugPrint('✅ Position ${position.inSeconds}s is buffered (complete buffer available)');
      return true;
    }
    
    // If fully buffered, all positions are available
    if (_bufferedPercentage >= 0.99) {
      debugPrint('✅ Position ${position.inSeconds}s is buffered (fully buffered)');
      return true;
    }
    
    // Check if position is within the buffered range
    // Get the total duration and estimate based on percentage
    final totalDuration = _controller!.value.duration;
    
    // If we have duration info, calculate if the position is within buffered range
    if (totalDuration.inMilliseconds > 0) {
      final positionPercentage = position.inMilliseconds / totalDuration.inMilliseconds;
      
      // Check if the position is within any of the buffered ranges reported by the controller
      if (_controller!.value.buffered.isNotEmpty) {
        for (var range in _controller!.value.buffered) {
          if (position >= range.start && position <= range.end) {
            debugPrint('✅ Position ${position.inSeconds}s is within buffered range ${range.start.inSeconds}s-${range.end.inSeconds}s');
            return true;
          }
        }
      }
      
      // Fall back to percentage-based calculation if no buffered ranges or position not in ranges
      // Add a small margin for safety (1%)
      final isBuffered = positionPercentage <= (_bufferedPercentage - 0.01);
      
      if (isBuffered) {
        debugPrint('✅ Position ${position.inSeconds}s (${(positionPercentage * 100).toStringAsFixed(1)}%) is within buffered range (${(_bufferedPercentage * 100).toStringAsFixed(1)}%)');
      } else {
        debugPrint('❌ Position ${position.inSeconds}s (${(positionPercentage * 100).toStringAsFixed(1)}%) is outside buffered range (${(_bufferedPercentage * 100).toStringAsFixed(1)}%)');
      }
      
      return isBuffered;
    }
    
    debugPrint('❌ Cannot determine if position is buffered (unknown duration)');
    return false;
  }
  
  /// Updates the controller with new buffer data (for progressive playback)
  Future<void> updateBuffer(Uint8List newData) async {
    if (_tempFile == null || !await _tempFile!.exists()) {
      throw Exception('Cannot update buffer: No temporary file exists');
    }
    
    // Only update if we're getting more data
    if (newData.length > _bufferedBytes) {
      debugPrint('📈 Buffer update: ${_bufferedBytes} bytes → ${newData.length} bytes');
      
      // Update buffering stats
      _bufferedBytes = newData.length;
      if (_totalBytes < _bufferedBytes) {
        _totalBytes = _bufferedBytes;
      }
      _bufferedPercentage = _totalBytes > 0 ? _bufferedBytes / _totalBytes : 0.0;
      
      // Always keep the most complete buffer data we've seen
      // This is critical for backward seeking to work properly
      if (_completeBufferData == null || newData.length > _completeBufferData!.length) {
        debugPrint('📦 Updating complete buffer: ${newData.length} bytes');
        _completeBufferData = Uint8List.fromList(newData);
        
        // Write the updated data to the file
        try {
          // Save current position and playback state
          final currentPosition = _controller?.value.position;
          final wasPlaying = _controller?.value.isPlaying ?? false;
          
          // Write the complete buffer to the file
          await _tempFile!.writeAsBytes(_completeBufferData!);
          debugPrint('💾 Updated temp file with complete buffer data');
          
          // If we're not playing or at the beginning, we can safely recreate the controller
          // This helps with some video_player issues where the file changes aren't detected
          if (_controller != null && (!wasPlaying || (currentPosition?.inMilliseconds ?? 0) < 1000)) {
            debugPrint('🔄 Recreating controller to ensure buffer changes are recognized');
            
            // Dispose old controller
            final oldController = _controller;
            
            // Create new controller
            _controller = VideoPlayerController.file(_tempFile!);
            await _controller!.initialize();
            
            // Restore position and playback state
            if (currentPosition != null) {
              await _controller!.seekTo(currentPosition);
            }
            
            if (wasPlaying) {
              await _controller!.play();
            }
            
            // Setup listener for network errors
            _controller!.addListener(_networkErrorListener);
            
            // Notify listeners of controller change
            for (var listener in _controllerChangeListeners) {
              listener(_controller!);
            }
            
            // Dispose old controller after setting up the new one
            await oldController?.dispose();
          }
        } catch (e) {
          debugPrint('❌ Error updating temp file: $e');
          // If we couldn't update the file, at least keep the buffer in memory
        }
      } else {
        debugPrint('ℹ️ Not updating complete buffer - new data is not more complete');
      }
    } else {
      debugPrint('ℹ️ Skipping buffer update - no new data (${newData.length} ≤ ${_bufferedBytes} bytes)');
    }
    
    // Reset offline status when we get new data
    _isOffline = false;
  }
  
  /// Seek safely, respecting buffered ranges when offline
  Future<void> seekTo(Duration position) async {
    if (_controller == null) return;
    
    try {
      // Debug information about seeking
      final Duration currentPosition = _controller!.value.position;
      debugPrint('⏩ Seeking from ${currentPosition.inSeconds}s to ${position.inSeconds}s');
      
      // Determine if this is a backward seek (to content we've already seen)
      bool isBackwardSeek = position < currentPosition;
      debugPrint('🔄 Direction: ${isBackwardSeek ? "BACKWARD ◀️" : "FORWARD ▶️"}');
      
      // For backward seeks, we ALWAYS want to use our complete buffer
      // This is the key fix - we assume backward seeks should always use the buffer
      if (isBackwardSeek && _completeBufferData != null && _tempFile != null) {
        debugPrint('🔍 Backward seek detected - using complete buffer data');
        
        // Save the playback state
        bool wasPlaying = _controller!.value.isPlaying;
        if (wasPlaying) {
          await _controller!.pause();
        }
        
        try {
          // CRITICAL FIX: Force the video player to use our local file by recreating the controller
          // This ensures we're not using the network for backward seeks
          
          // Dispose old controller
          final oldController = _controller;
          
          // Ensure the temp file has the complete data
          await _tempFile!.writeAsBytes(_completeBufferData!);
          debugPrint('💾 Wrote complete buffer data (${_completeBufferData!.length} bytes) to temp file');
          
          // Create new controller from the file with complete data
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
          
          // Setup listener for network errors
          _controller!.addListener(_networkErrorListener);
          
          // Notify listeners of controller change
          debugPrint('🔔 Notifying ${_controllerChangeListeners.length} listeners of controller change');
          for (var listener in _controllerChangeListeners) {
            listener(_controller!);
          }
          
          // Dispose old controller after setting up the new one
          debugPrint('🗑️ Disposing old controller');
          await oldController?.dispose();
          
          debugPrint('✅ Backward seek completed to ${position.inSeconds}s using complete buffer');
          return;
        } catch (e) {
          debugPrint('❌ Error during aggressive backward seek: $e');
          // Fall back to standard seek if the aggressive approach fails
        }
      }
      
      // For forward seeks or if aggressive backward seek failed
      
      // Check if we're seeking to a position that should be in our buffer
      bool shouldBeBuffered = isBackwardSeek || isPositionBuffered(position);
      
      // If we're seeking to a position that should be buffered but we're offline or
      // the controller reports it's not buffered, we need to ensure we use our complete buffer
      if (shouldBeBuffered && (_isOffline || !_controller!.value.isBuffering)) {
        debugPrint('🔍 Seeking to position that should be buffered');
        
        // If we have the complete buffer data, we can ensure it's available
        if (_completeBufferData != null && _tempFile != null) {
          debugPrint('📦 Using complete buffer data for seeking');
          
          // Save the playback state
          bool wasPlaying = _controller!.value.isPlaying;
          if (wasPlaying) {
            await _controller!.pause();
          }
          
          // Ensure the temp file has the complete data
          await _tempFile!.writeAsBytes(_completeBufferData!);
          
          // Now perform the seek
          await _controller!.seekTo(position);
          
          // If it was playing before, resume playback
          if (wasPlaying) {
            await _controller!.play();
          }
          
          debugPrint('✅ Seek completed to ${position.inSeconds}s using complete buffer');
          return;
        }
      }
      
      // If we can't use the buffer or it's a forward seek to unbuffered content
      if (_isOffline && !isPositionBuffered(position)) {
        debugPrint('❌ Cannot seek to unbuffered position while offline');
        return;
      }
      
      // Save the playback state
      bool wasPlaying = _controller!.value.isPlaying;
      if (wasPlaying) {
        await _controller!.pause();
      }
      
      // Standard seek for other cases
      await _controller!.seekTo(position);
      
      // If it was playing before, resume playback
      if (wasPlaying) {
        await _controller!.play();
      }
      
      debugPrint('✅ Seek completed to ${position.inSeconds}s');
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
    
    // Clean up temp directory if it was created just for this purpose
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
    _completeBufferData = null;
  }
  
  /// Add a listener to be notified when the controller changes
  void addControllerChangeListener(ControllerChangeCallback listener) {
    _controllerChangeListeners.add(listener);
  }
  
  /// Remove a controller change listener
  void removeControllerChangeListener(ControllerChangeCallback listener) {
    _controllerChangeListeners.remove(listener);
  }
  
  /// Notify all listeners about a controller change
  void _notifyControllerChangeListeners() {
    if (_controller != null) {
      for (final listener in _controllerChangeListeners) {
        listener(_controller!);
      }
    }
  }
  
  bool get isInitialized => _isInitialized;
  bool get isOffline => _isOffline;
  double get bufferedPercentage => _bufferedPercentage;
  VideoPlayerController? get controller => _controller;
} 