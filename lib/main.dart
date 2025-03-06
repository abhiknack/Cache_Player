import 'dart:io';
import 'package:better_player/better_player.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'dart:async';
import 'dart:math';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Video Player with Caching',
      theme: ThemeData(
        primarySwatch: Colors.blue,
      ),
      home: VideoScreen(),
    );
  }
}

class VideoScreen extends StatefulWidget {
  @override
  _VideoScreenState createState() => _VideoScreenState();
}

class _VideoScreenState extends State<VideoScreen> {
  BetterPlayerController _betterPlayerController = BetterPlayerController(
    BetterPlayerConfiguration(
      autoPlay: false,
      looping: true,
      fit: BoxFit.contain,
      placeholder: Center(child: CircularProgressIndicator()),
      handleLifecycle: true,
      autoDispose: true,
    )
  );
  final String videoUrl =
      "https://firebasestorage.googleapis.com/v0/b/nibbl-b8d73.appspot.com/o/marin%5B1%5D.mp4?alt=media&token=7a39c3bd-4788-411b-a88d-c88441196107";
  
  bool _isOffline = false;
  double _bufferedPercentage = 0.0;
  double _highestBufferedPercentage = 0.0;  // Track highest buffer percentage
  String _statusMessage = "Initializing player...";
  File? _activeBufferFile;
  int _totalBytes = 0;  // Track total video size
  int _bufferedBytes = 0;  // Track buffered bytes
  
  @override
  void initState() {
    super.initState();
    _setupPlayer();
    _monitorConnectivity();
    _initializeBufferFile();
  }
  
  void _monitorConnectivity() {
    Connectivity().onConnectivityChanged.listen((ConnectivityResult result) async {
      final wasOffline = _isOffline;
      final newIsOffline = (result == ConnectivityResult.none);
      
      // Only handle state change if there's actually a change
      if (wasOffline != newIsOffline) {
        setState(() {
          _isOffline = newIsOffline;
          _updateStatusMessage();
        });
        
        if (_isOffline) {
          // If we just went offline, try to continue with buffered content
          _continueWithBufferedContent();
        } else {
          // If we're back online, restore network playback if needed
          _restoreNetworkPlayback();
        }
      }
    });
  }
  
  void _updateBufferPercentage(double newPercentage) {
    if (newPercentage > _highestBufferedPercentage) {
      _highestBufferedPercentage = newPercentage;
      
      // If we've reached 100% buffering, save to permanent cache and stop all monitoring
      if (_highestBufferedPercentage >= 0.99 && !_isFullyCached) {
        _saveToCache().then((_) {
          // Stop all monitoring and buffering operations
          _stopAllMonitoring();
          setState(() {
            _statusMessage = "Video fully cached - Using cached version";
          });
          // Switch to cached playback
          _tryPlayFromCache();
        });
      }
    }
    setState(() {
      _bufferedPercentage = _highestBufferedPercentage;
      _updateStatusMessage();
    });
  }

  // Add function to get current cache size
  Future<String> _getCacheSizeString() async {
    try {
      int maxSize = 0;
      
      // Check active buffer file size
      if (_activeBufferFile != null && await _activeBufferFile!.exists()) {
        final bufferSize = await _activeBufferFile!.length();
        print("📊 Active buffer size: ${(bufferSize / 1024 / 1024).toStringAsFixed(1)}MB");
        maxSize = bufferSize;
      }
      
      // Check cache directory for all related files
      final cacheDir = await getTemporaryDirectory();
      final cacheKey = "big_buck_bunny";
      final dir = Directory(cacheDir.path);
      
      if (await dir.exists()) {
        final files = await dir.list().toList();
        
        // Find the largest file size among all cache files
        for (var file in files) {
          if (file is File && 
              (file.path.contains(cacheKey) || file.path.contains('temp_network_video'))) {
            try {
              final size = await file.length();
              print("📁 Found cache file: ${file.path} (${(size / 1024 / 1024).toStringAsFixed(1)}MB)");
              if (size > maxSize) {
                maxSize = size;
              }
            } catch (e) {
              print("⚠️ Error reading file size: $e");
            }
          }
        }
      }

      // Update our tracking variables
      _bufferedBytes = maxSize;
      if (maxSize > _totalBytes) {
        _totalBytes = maxSize;
      }
      
      final sizeInMB = (maxSize / 1024 / 1024).toStringAsFixed(1);
      print("📊 Total cache size: ${sizeInMB}MB");
      return "(${sizeInMB}MB cached)";
    } catch (e) {
      print("❌ Error getting cache size: $e");
      return "(0.0MB cached)";
    }
  }

  void _updateStatusMessage() async {
    if (!mounted || _isFullyCached) return;  // Skip if fully cached
    final cacheSizeStr = await _getCacheSizeString();
    setState(() {
      if (_isOffline) {
        _statusMessage = "OFFLINE MODE - ${(_highestBufferedPercentage * 100).toStringAsFixed(0)}% buffered $cacheSizeStr";
      } else {
        _statusMessage = "Connected - ${(_highestBufferedPercentage * 100).toStringAsFixed(0)}% buffered $cacheSizeStr";
      }
    });
  }

  Future<void> _initializeBufferFile() async {
    try {
      final cacheDir = await getTemporaryDirectory();
      final String tempPath = '${cacheDir.path}/current_buffer_${DateTime.now().millisecondsSinceEpoch}.mp4';
      
      // Clean up any existing buffer file
      _activeBufferFile = File(tempPath);
      if (await _activeBufferFile!.exists()) {
        await _activeBufferFile!.delete();
      }
      
      // Create the file with write permissions
      await _activeBufferFile!.create(recursive: true);
      
      // Verify the file was created and is writable
      if (await _activeBufferFile!.exists()) {
        // Try to write a small test byte to verify permissions
        try {
          await _activeBufferFile!.writeAsBytes([0], mode: FileMode.write, flush: true);
          print("✅ Buffer file initialized and writable at: $tempPath");
        } catch (e) {
          print("⚠️ Buffer file created but not writable: $e");
          // Try to recreate with full permissions
          await _activeBufferFile!.delete();
          await _activeBufferFile!.create(recursive: true);
          // Verify again
          await _activeBufferFile!.writeAsBytes([0], mode: FileMode.write, flush: true);
          print("✅ Buffer file recreated with proper permissions at: $tempPath");
        }
      } else {
        print("❌ Failed to create buffer file");
      }
    } catch (e) {
      print("❌ Error initializing buffer file: $e");
      // Try one more time in the root of temp directory
      try {
        final cacheDir = await getTemporaryDirectory();
        final String tempPath = '${cacheDir.path}/buffer_${DateTime.now().millisecondsSinceEpoch}.mp4';
        _activeBufferFile = File(tempPath);
        await _activeBufferFile!.create(recursive: true);
        print("✅ Buffer file created in root temp directory: $tempPath");
      } catch (e) {
        print("❌ Failed to create buffer file in root directory: $e");
      }
    }
  }

  void _setupPlayer() {
    // Define better player configuration
    BetterPlayerConfiguration betterPlayerConfiguration = BetterPlayerConfiguration(
      autoPlay: true,
      looping: true,
      fit: BoxFit.contain,
      handleLifecycle: true,
      autoDispose: true,
      controlsConfiguration: BetterPlayerControlsConfiguration(
        enablePlayPause: true,
        enableSkips: true,
        enableFullscreen: true,
        enableProgressText: true,
        enableProgressBar: true,
        enablePlaybackSpeed: true,
        showControlsOnInitialize: true,
        loadingWidget: Center(
          child: CircularProgressIndicator(
            valueColor: AlwaysStoppedAnimation<Color>(Colors.blue),
          ),
        ),
      ),
      playerVisibilityChangedBehavior: onVisibilityChanged,
    );

    // Check for existing cache first
    _tryPlayFromCache().then((bool cacheExists) {
      if (!cacheExists) {
        print("🎬 No cache found, setting up network source");
        
        // Only setup network source if no cache exists
        BetterPlayerDataSource dataSource = BetterPlayerDataSource(
          BetterPlayerDataSourceType.network,
          videoUrl,
          cacheConfiguration: BetterPlayerCacheConfiguration(
            useCache: true,
            maxCacheFileSize: 50 * 1024 * 1024,
            maxCacheSize: 100 * 1024 * 1024,
            key: "big_buck_bunny",
          ),
          bufferingConfiguration: BetterPlayerBufferingConfiguration(
            minBufferMs: 50000,
            maxBufferMs: 120000,
            bufferForPlaybackMs: 2500,
            bufferForPlaybackAfterRebufferMs: 5000,
          ),
          notificationConfiguration: BetterPlayerNotificationConfiguration(
            showNotification: false,
          ),
        );

        // Dispose of the default controller before creating a new one
        _betterPlayerController.dispose();

        // Initialize the controller with network source
        _betterPlayerController = BetterPlayerController(betterPlayerConfiguration);
        
        if (mounted) {
          // Only setup data source if the widget is still mounted
          _betterPlayerController.setupDataSource(dataSource);
          
          // Setup event listeners for network source
          _setupEventListeners();
        }
      }
    });
  }

  // Add function to stop all monitoring operations
  Timer? _bufferTimer;
  Timer? _statusTimer;
  bool _isFullyCached = false;

  void _stopAllMonitoring() {
    if (_isFullyCached) return; // Already stopped
    
    // Stop buffer timer
    _bufferTimer?.cancel();
    _bufferTimer = null;

    // Stop status update timer
    _statusTimer?.cancel();
    _statusTimer = null;

    // Mark as fully cached
    _isFullyCached = true;

    print("🛑 Stopped all monitoring - Video is complete");
  }

  // Modify _startSavingBuffer to not save continuously
  Future<void> _startSavingBuffer() async {
    if (_activeBufferFile == null || _isFullyCached) return;
    
    // Cancel any existing timers
    _bufferTimer?.cancel();
    _statusTimer?.cancel();
    
    // Start buffer check timer - only for monitoring progress
    _bufferTimer = Timer.periodic(Duration(seconds: 1), (timer) async {
      if (!mounted || _isFullyCached || 
          (_betterPlayerController.videoPlayerController?.value.position.inMilliseconds ?? 0) >= 
          (_betterPlayerController.videoPlayerController?.value.duration?.inMilliseconds ?? 0)) {
        timer.cancel();
        return;
      }
      
      try {
        // Check if we have any buffered data
        final bufferedRanges = _betterPlayerController.videoPlayerController?.value.buffered ?? [];
        final duration = _betterPlayerController.videoPlayerController?.value.duration;
        
        if (bufferedRanges.isNotEmpty && duration != null) {
          // Calculate total buffered duration
          int totalBufferedMs = 0;
          for (var range in bufferedRanges) {
            totalBufferedMs += (range.end.inMilliseconds - range.start.inMilliseconds);
          }
          
          // Update buffer percentage
          final percentage = totalBufferedMs / duration.inMilliseconds;
          _updateBufferPercentage(percentage);
        }
      } catch (e) {
        print("⚠️ Error in buffer check: $e");
      }
    });

    // Start status update timer with longer interval
    _statusTimer = Timer.periodic(Duration(seconds: 5), (timer) {
      if (!mounted || _isFullyCached) {
        timer.cancel();
        return;
      }
      _updateStatusMessage();
    });
  }

  // Modify _saveCurrentBuffer to update status after saving
  Future<void> _saveCurrentBuffer() async {
    try {
      if (_activeBufferFile == null) {
        print("❌ No active buffer file available");
        return;
      }

      print("🔍 Starting advanced buffer save process...");
      
      // Get the cache directory
      final cacheDir = await getTemporaryDirectory();
      print("📂 Cache directory: ${cacheDir.path}");

      // APPROACH 1: Try to access the actual data from the video player
      bool saveSuccessful = false;
      
      try {
        final videoPlayerValue = _betterPlayerController.videoPlayerController?.value;
        if (videoPlayerValue != null && videoPlayerValue.initialized) {
          // First, check if we can get the raw cache data from BetterPlayer
          if (_betterPlayerController.betterPlayerDataSource != null) {
            // Get the current URL and cache key
            final videoUrl = _betterPlayerController.betterPlayerDataSource!.url;
            final cacheKey = _betterPlayerController.betterPlayerDataSource!.cacheConfiguration?.key ?? "video_cache";
            
            print("🔗 Video URL: $videoUrl");
            print("🔑 Cache key: $cacheKey");
            
            // These are common ExoPlayer cache paths we need to check
            List<String> potentialCachePaths = [
              "${cacheDir.path}/exoplayer", 
              "${cacheDir.path}/androidx.media3",
              "${cacheDir.path}/cache",
              "${cacheDir.path}",
              "${cacheDir.path}/media",
              "${cacheDir.path}/video_cache",
              "${cacheDir.path}/$cacheKey"
            ];
            
            // Use a recursive search through all of these paths
            for (final basePath in potentialCachePaths) {
              if (saveSuccessful) break;
              
              // Search for ExoPlayer cache files
              try {
                final dir = Directory(basePath);
                if (await dir.exists()) {
                  print("📂 Searching in: $basePath");
                  
                  // Attempt to find all video cache files (recursively if needed)
                  final files = await dir.list(recursive: true).where((entity) {
                    return entity is File && 
                           (entity.path.endsWith('.exo') || 
                            entity.path.endsWith('.cache') ||
                            entity.path.endsWith('.mp4') ||
                            entity.path.endsWith('.tmp') ||
                            entity.path.contains(cacheKey) ||
                            entity.path.contains('video_cache'));
                  }).toList();
                  
                  print("🔍 Found ${files.length} potential cache files in $basePath");
                  
                  // Process all the files
                  for (final entity in files) {
                    if (entity is File) {
                      try {
                        final size = await entity.length();
                        
                        // Only consider files with substantial content
                        if (size > 500 * 1024) { // Files larger than 500KB
                          print("📄 Found large file: ${entity.path} (${(size / 1024 / 1024).toStringAsFixed(2)}MB)");
                          
                          // Try to read the first 16KB to check if it's a valid video file
                          final header = await entity.openRead(0, 16384).first;
                          
                          // Check for MP4 signatures
                          bool isVideoFile = false;
                          if (header.length >= 12) {
                            final signature = String.fromCharCodes(header.sublist(4, 8));
                            if (signature == 'ftyp' || signature == 'moov' || signature == 'mdat') {
                              isVideoFile = true;
                              print("✅ File has valid video signature: $signature");
                            }
                          }
                          
                          // For ExoPlayer cache files, we need a different check
                          if (!isVideoFile && entity.path.endsWith('.exo')) {
                            // ExoPlayer cache files have a specific structure
                            // We can check for certain byte patterns
                            isVideoFile = true;
                            print("✅ Found ExoPlayer cache file");
                          }
                          
                          if (isVideoFile || size > 1 * 1024 * 1024) { // Assume large files are valid
                            // Create a fresh buffer file with timestamp
                            final timestamp = DateTime.now().millisecondsSinceEpoch;
                            final newBufferPath = '${cacheDir.path}/buffer_${timestamp}.mp4';
                            final newBufferFile = File(newBufferPath);
                            
                            print("📤 Copying ${(size / 1024 / 1024).toStringAsFixed(2)}MB cache file to buffer...");
                            try {
                              // For ExoPlayer cache files, we need to extract the actual media data
                              if (entity.path.endsWith('.exo')) {
                                // Read the entire file
                                final bytes = await entity.readAsBytes();
                                
                                // ExoPlayer cache files have a header we need to skip
                                // The exact format depends on the version, but we can look for video signatures
                                int startOffset = 0;
                                for (int i = 0; i < bytes.length - 8; i++) {
                                  if (i + 8 < bytes.length) {
                                    final possibleSig = String.fromCharCodes(bytes.sublist(i + 4, i + 8));
                                    if (possibleSig == 'ftyp' || possibleSig == 'moov' || possibleSig == 'mdat') {
                                      startOffset = i;
                                      print("📌 Found video data at offset: $startOffset");
                                      break;
                                    }
                                  }
                                }
                                
                                // Write just the media portion
                                if (startOffset < bytes.length) {
                                  await newBufferFile.writeAsBytes(bytes.sublist(startOffset));
                                } else {
                                  // If we couldn't find a clear media boundary, write the whole thing
                                  await newBufferFile.writeAsBytes(bytes);
                                }
                              } else {
                                // For normal video files, just do a direct copy
                                // Read the entire source file to memory
                                final bytes = await entity.readAsBytes();
                                
                                if (bytes.isNotEmpty) {
                                  // Write to our buffer file
                                  await newBufferFile.writeAsBytes(bytes, flush: true);
                                  print("✅ Wrote ${(bytes.length / 1024 / 1024).toStringAsFixed(2)}MB to buffer");
                                  
                                  // Verify the new file
                                  final newSize = await newBufferFile.length();
                                  if (newSize > 0 && newSize == bytes.length) {
                                    // Create final cache file too
                                    final finalCachePath = '${cacheDir.path}/final_cache_${cacheKey}_$timestamp.mp4';
                                    final finalCacheFile = File(finalCachePath);
                                    
                                    await finalCacheFile.writeAsBytes(bytes, flush: true);
                                    print("💾 Created permanent cache: $finalCachePath (${(newSize / 1024 / 1024).toStringAsFixed(2)}MB)");
                                    
                                    // Update our active buffer file reference
                                    _activeBufferFile = newBufferFile;
                                    
                                    // Update tracking
                                    _bufferedBytes = newSize;
                                    if (newSize > _totalBytes) {
                                      _totalBytes = newSize;
                                    }
                                    
                                    // Update status
                                    _updateStatusMessage();
                                    
                                    // Mark as successful
                                    saveSuccessful = true;
                                    break;
                                  }
                                }
                              }
                            } catch (e) {
                              print("❌ Error copying cache file: $e");
                              try {
                                await newBufferFile.delete();
                              } catch (_) {}
                            }
                          }
                        }
                      } catch (e) {
                        print("⚠️ Error examining potential cache file: $e");
                      }
                    }
                  }
                }
              } catch (e) {
                print("⚠️ Error searching directory $basePath: $e");
              }
            }
          }
        }
      } catch (e) {
        print("⚠️ Error accessing video player data: $e");
      }
      
      // APPROACH 2: If the first approach failed, try to capture buffer data directly from player
      if (!saveSuccessful) {
        try {
          print("🔄 Trying alternative buffer extraction approach...");
          
          // The buffered ranges might give us clues about what's actually in memory
          final bufferedRanges = _betterPlayerController.videoPlayerController?.value.buffered ?? [];
          final duration = _betterPlayerController.videoPlayerController?.value.duration;
          
          if (bufferedRanges.isNotEmpty && duration != null && duration.inMilliseconds > 0) {
            // Calculate total buffered duration
            int totalBufferedMs = 0;
            for (var range in bufferedRanges) {
              totalBufferedMs += (range.end.inMilliseconds - range.start.inMilliseconds);
            }
            
            final bufferPercentage = totalBufferedMs / duration.inMilliseconds;
            print("📊 Buffer percentage: ${(bufferPercentage * 100).toStringAsFixed(1)}%");
            
            // In case of direct temp file from BetterPlayer's VideoPlayerController...
            final videoController = _betterPlayerController.videoPlayerController;
            if (videoController != null) {
              // Get any data source path that might be a file
              final dataSource = _betterPlayerController.betterPlayerDataSource?.url;
              if (dataSource != null && dataSource.startsWith('/')) {
                final sourceFile = File(dataSource);
                if (await sourceFile.exists()) {
                  final size = await sourceFile.length();
                  print("🎯 Found direct video file: $dataSource (${(size / 1024 / 1024).toStringAsFixed(2)}MB)");
                  
                  if (size > 100 * 1024) { // Only if it has substantial content
                    // Create a timestamp for unique file names
                    final timestamp = DateTime.now().millisecondsSinceEpoch;
                    final newBufferPath = '${cacheDir.path}/direct_buffer_${timestamp}.mp4';
                    final newBufferFile = File(newBufferPath);
                    
                    try {
                      // Copy bytes directly
                      final bytes = await sourceFile.readAsBytes();
                      await newBufferFile.writeAsBytes(bytes, flush: true);
                      
                      // Verify copy
                      final newSize = await newBufferFile.length();
                      if (newSize > 0 && newSize == size) {
                        print("✅ Successfully copied direct video file: ${(newSize / 1024 / 1024).toStringAsFixed(2)}MB");
                        
                        // Create permanent cache too
                        final finalCachePath = '${cacheDir.path}/final_direct_cache_${timestamp}.mp4';
                        final finalCacheFile = File(finalCachePath);
                        await finalCacheFile.writeAsBytes(bytes, flush: true);
                        
                        // Update references
                        _activeBufferFile = newBufferFile;
                        _bufferedBytes = newSize;
                        if (newSize > _totalBytes) {
                          _totalBytes = newSize;
                        }
                        
                        _updateStatusMessage();
                        saveSuccessful = true;
                      }
                    } catch (e) {
                      print("❌ Error copying direct video file: $e");
                    }
                  }
                }
              }
            }
          }
        } catch (e) {
          print("⚠️ Error in alternative buffer extraction: $e");
        }
      }
      
      // APPROACH 3: If all else fails, try to use ExoPlayer's internal cache files directly
      if (!saveSuccessful) {
        try {
          print("🔍 Scanning all files in cache directory for video content...");
          
          // Do a deep scan of all files in the cache directory
          final allFiles = await Directory(cacheDir.path)
              .list(recursive: true)
              .where((entity) => entity is File)
              .cast<File>()
              .toList();
          
          print("📂 Found ${allFiles.length} total files in cache");
          
          // Filter and sort by size (largest first)
          List<File> sizedFiles = [];
          Map<String, int> fileSizes = {};
          
          for (var file in allFiles) {
            try {
              final size = await file.length();
              // Only consider files with substantial size
              if (size > 200 * 1024) { // > 200KB
                sizedFiles.add(file);
                fileSizes[file.path] = size;
              }
            } catch (e) {
              // Skip files we can't access
            }
          }
          
          // Sort by size (largest first)
          sizedFiles.sort((a, b) {
            final sizeA = fileSizes[a.path] ?? 0;
            final sizeB = fileSizes[b.path] ?? 0;
            return sizeB.compareTo(sizeA);
          });
          
          print("📊 Found ${sizedFiles.length} files larger than 200KB");
          
          // Examine each large file for video content
          for (var file in sizedFiles) {
            if (saveSuccessful) break;
            
            final size = fileSizes[file.path] ?? 0;
            print("📄 Examining: ${file.path} (${(size / 1024 / 1024).toStringAsFixed(2)}MB)");
            
            try {
              // Read first 16KB to check for video signatures
              final header = await file.openRead(0, 16384).first;
              
              // Check for common video signatures
              bool isLikelyVideo = false;
              
              // Look for MP4 markers
              for (int i = 0; i < header.length - 8; i++) {
                if (i + 8 <= header.length) {
                  final possibleSig = String.fromCharCodes(header.sublist(i + 4, min(i + 8, header.length)));
                  if (possibleSig == 'ftyp' || possibleSig == 'moov' || possibleSig == 'mdat') {
                    isLikelyVideo = true;
                    print("✅ Found video signature at offset $i: $possibleSig");
                    break;
                  }
                }
              }
              
              // For very large files, assume they might be video even without signature
              if (!isLikelyVideo && size > 1 * 1024 * 1024) {
                isLikelyVideo = true;
                print("🤔 Large file might be video content");
              }
              
              if (isLikelyVideo) {
                // Create a fresh buffer with timestamp
                final timestamp = DateTime.now().millisecondsSinceEpoch;
                final newBufferPath = '${cacheDir.path}/recovered_${timestamp}.mp4';
                final newBufferFile = File(newBufferPath);
                
                try {
                  // Read entire file
                  final bytes = await file.readAsBytes();
                  
                  // Write to new buffer
                  await newBufferFile.writeAsBytes(bytes, flush: true);
                  
                  // Verify
                  final newSize = await newBufferFile.length();
                  if (newSize > 0 && newSize == bytes.length) {
                    print("✅ Successfully recovered: ${(newSize / 1024 / 1024).toStringAsFixed(2)}MB");
                    
                    // Create permanent copy
                    final finalCachePath = '${cacheDir.path}/final_recovered_${timestamp}.mp4';
                    final finalCacheFile = File(finalCachePath);
                    await finalCacheFile.writeAsBytes(bytes, flush: true);
                    
                    // Update references
                    _activeBufferFile = newBufferFile;
                    _bufferedBytes = newSize;
                    if (newSize > _totalBytes) {
                      _totalBytes = newSize;
                    }
                    
                    _updateStatusMessage();
                    saveSuccessful = true;
                    break;
                  }
                } catch (e) {
                  print("❌ Error recovering video: $e");
                  try {
                    await newBufferFile.delete();
                  } catch (_) {}
                }
              }
            } catch (e) {
              print("⚠️ Error examining file: $e");
            }
          }
        } catch (e) {
          print("❌ Error in deep cache scanning: $e");
        }
      }
      
      // If we reach here and haven't succeeded, report failure
      if (!saveSuccessful) {
        print("❌ Could not save buffer after trying all approaches");
      }
    } catch (e) {
      print("❌ Critical error in _saveCurrentBuffer: $e");
    }
  }

  // Add new function to continue playback from buffer when going offline
  Future<void> _continueWithBufferedContent() async {
    try {
      // Save the current buffer percentage
      final savedBufferPercentage = _highestBufferedPercentage;
      
      // Get current playback state
      final currentPosition = _betterPlayerController.videoPlayerController?.value.position;
      final wasPlaying = _betterPlayerController.isPlaying() ?? false;
      
      // Check if we have buffered content at current position
      final bufferedRanges = _betterPlayerController.videoPlayerController?.value.buffered ?? [];
      bool isCurrentPositionBuffered = false;
      
      if (currentPosition != null) {
        for (var range in bufferedRanges) {
          if (currentPosition >= range.start && currentPosition <= range.end) {
            isCurrentPositionBuffered = true;
            break;
          }
        }
      }
      
      // If current position is buffered, try to continue from buffer
      if (isCurrentPositionBuffered) {
        print("📱 Continuing playback from buffer at position ${currentPosition?.inSeconds}s");
        
        // First try our active buffer file
        if (_activeBufferFile != null && await _activeBufferFile!.exists() && await _activeBufferFile!.length() > 0) {
          // Create new controller for buffered content
          final newController = BetterPlayerController(
            BetterPlayerConfiguration(
              autoPlay: wasPlaying,
              looping: false,
              fit: BoxFit.contain,
            ),
          );
          
          // Setup data source from buffer file
          final bufferDataSource = BetterPlayerDataSource(
            BetterPlayerDataSourceType.file,
            _activeBufferFile!.path,
          );
          
          await newController.setupDataSource(bufferDataSource);
          
          // Store old controller
          final oldController = _betterPlayerController;
          
          // Switch to new controller
          setState(() {
            _betterPlayerController = newController;
            _statusMessage = "Playing from buffered content";
          });
          
          // Restore position and state
          if (currentPosition != null) {
            await _betterPlayerController.seekTo(currentPosition);
          }
          if (wasPlaying) {
            await _betterPlayerController.play();
          }
          
          // Dispose old controller
          oldController.dispose();
          
          print("✅ Successfully switched to buffered playback");
          
          // After switching controllers, restore the buffer percentage
          _updateBufferPercentage(savedBufferPercentage);
          return;
        }
      }
      
      // If we couldn't continue from current position, try to find any cached content
      await _tryPlayFromCache();
      
    } catch (e) {
      print("❌ Error continuing from buffer: $e");
      // If all else fails, try regular cache playback
      await _tryPlayFromCache();
    }
  }

  // Add new function to restore network playback when coming back online
  Future<void> _restoreNetworkPlayback() async {
    try {
      // Only restore if we're currently playing from a file
      final currentSource = _betterPlayerController.betterPlayerDataSource;
      if (currentSource?.type == BetterPlayerDataSourceType.file) {
        print("🌐 Restoring network playback");
        
        // Save current state
        final currentPosition = _betterPlayerController.videoPlayerController?.value.position;
        final wasPlaying = _betterPlayerController.isPlaying() ?? false;
        
        // Create new controller
        final newController = BetterPlayerController(
          BetterPlayerConfiguration(
            autoPlay: wasPlaying,
            looping: false,
            fit: BoxFit.contain,
          ),
        );
        
        // Setup network source
        final networkDataSource = BetterPlayerDataSource(
          BetterPlayerDataSourceType.network,
          videoUrl,
          cacheConfiguration: BetterPlayerCacheConfiguration(
            useCache: true,
            maxCacheFileSize: 50 * 1024 * 1024,
            maxCacheSize: 100 * 1024 * 1024,
            key: "big_buck_bunny",
          ),
        );
        
        await newController.setupDataSource(networkDataSource);
        
        // Store old controller
        final oldController = _betterPlayerController;
        
        // Switch to new controller
        setState(() {
          _betterPlayerController = newController;
          _statusMessage = "Restored network playback";
        });
        
        // Restore position and state
        if (currentPosition != null) {
          await _betterPlayerController.seekTo(currentPosition);
        }
        if (wasPlaying) {
          await _betterPlayerController.play();
        }
        
        // Start buffer saving
        _startSavingBuffer();
        
        // Dispose old controller
        oldController.dispose();
        
        print("✅ Successfully restored network playback");
      }
    } catch (e) {
      print("❌ Error restoring network playback: $e");
    }
  }

  Future<bool> _verifyVideoFile(File file, String description) async {
    print("🔍 Verifying $description...");
    
    try {
      // First check if file exists and has content
      if (!await file.exists()) {
        print("❌ File does not exist");
        return false;
      }
      
      final size = await file.length();
      if (size <= 0) {
        print("❌ File is empty");
        return false;
      }
      
      print("📊 File size: ${(size / 1024 / 1024).toStringAsFixed(1)}MB");
      
      // Try to read first few bytes to verify it's readable
      try {
        final bytes = await file.openRead(0, 1024).first;
        if (bytes.isEmpty) {
          print("❌ File is not readable");
          return false;
        }
      } catch (e) {
        print("❌ Error reading file: $e");
        return false;
      }
      
      // If we can read the file and it has content, consider it valid
      print("✅ File verification passed");
      return true;
    } catch (e) {
      print("❌ Verification error: $e");
      return false;
    }
  }

  Future<bool> _tryPlayFromCache() async {
    print("\n🔍 === Starting Enhanced Cache Playback Attempt ===");
    
    try {
      // Get cache directory
      final cacheDir = await getTemporaryDirectory();
      final cacheKey = "big_buck_bunny";
      
      // Check for final cache file first
      final finalCachePattern = RegExp(r'final_cache_.*\.mp4$');
      final files = await Directory(cacheDir.path).list().toList();
      
      File? cachedFile;
      int maxSize = 0;
      
      // Look for the largest final cache file
      for (var entity in files) {
        if (entity is File && finalCachePattern.hasMatch(entity.path)) {
          try {
            final size = await entity.length();
            if (size > maxSize) {
              maxSize = size;
              cachedFile = entity;
            }
          } catch (e) {
            print("⚠️ Error checking cache file size: $e");
          }
        }
      }
      
      if (cachedFile != null && maxSize > 0) {
        print("✅ Found cached file: ${cachedFile.path} (${(maxSize / 1024 / 1024).toStringAsFixed(2)}MB)");
        
        // Create new controller for cached content
        final newController = BetterPlayerController(
          BetterPlayerConfiguration(
            autoPlay: true,
            looping: true,
            fit: BoxFit.contain,
          ),
        );
        
        // Setup data source from cache file
        final cacheDataSource = BetterPlayerDataSource(
          BetterPlayerDataSourceType.file,
          cachedFile.path,
        );
        
        await newController.setupDataSource(cacheDataSource);
        
        // Switch to new controller
        final oldController = _betterPlayerController;
        setState(() {
          _betterPlayerController = newController;
          _isFullyCached = true;
          _statusMessage = "Playing from cache (${(maxSize / 1024 / 1024).toStringAsFixed(2)}MB)";
        });
        
        // Dispose old controller
        oldController.dispose();
        
        return true;
      }
    } catch (e) {
      print("❌ Error checking cache: $e");
    }
    
    return false;
  }

  // Add new function to save fully buffered video to cache
  Future<void> _saveToCache() async {
    try {
      print("📦 Starting final cache save...");
      
      // Get the cache directory
      final cacheDir = await getTemporaryDirectory();
      final cacheKey = "big_buck_bunny";
      final dir = Directory(cacheDir.path);
      
      // List to store all potential cache files
      List<File> cacheFiles = [];
      
      // First, check our active buffer file
      if (_activeBufferFile != null && await _activeBufferFile!.exists()) {
        final size = await _activeBufferFile!.length();
        print("📊 Active buffer file: ${(size / 1024 / 1024).toStringAsFixed(1)}MB");
        cacheFiles.add(_activeBufferFile!);
      }
      
      // Then check all files in cache directory
      if (await dir.exists()) {
        final files = await dir.list().toList();
        for (var file in files) {
          if (file is File && 
              (file.path.contains(cacheKey) || 
               file.path.contains('temp_network_video') ||
               file.path.contains('current_buffer'))) {
            try {
              final size = await file.length();
              if (size > 0) {
                print("📁 Found cache file: ${file.path} (${(size / 1024 / 1024).toStringAsFixed(1)}MB)");
                cacheFiles.add(file);
              }
            } catch (e) {
              print("⚠️ Error reading file: $e");
            }
          }
        }
      }
      
      if (cacheFiles.isEmpty) {
        print("❌ No cache files found");
        return;
      }
      
      // Pre-calculate file sizes
      Map<String, int> fileSizes = {};
      for (var file in cacheFiles) {
        try {
          final size = await file.length();
          fileSizes[file.path] = size;
          print("📊 Cache file size: ${file.path} = ${(size / 1024 / 1024).toStringAsFixed(1)}MB");
        } catch (e) {
          fileSizes[file.path] = 0;
          print("⚠️ Error reading file size: $e");
        }
      }
      
      // Sort files by size (largest first)
      cacheFiles.sort((a, b) {
        final sizeA = fileSizes[a.path] ?? 0;
        final sizeB = fileSizes[b.path] ?? 0;
        return sizeB.compareTo(sizeA);
      });
      
      // Get the largest file
      File? largestFile = cacheFiles.isNotEmpty ? cacheFiles.first : null;
      int maxSize = largestFile != null ? (fileSizes[largestFile.path] ?? 0) : 0;

      if (largestFile != null && maxSize > 0) {
        // Create final cache file with unique timestamp
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        final finalCachePath = '${cacheDir.path}/final_cache_${cacheKey}_$timestamp.mp4';
        final finalCacheFile = File(finalCachePath);
        
        // Copy the largest cache file to our final cache
        print("📝 Copying largest cache file (${(maxSize / 1024 / 1024).toStringAsFixed(1)}MB)...");
        
        try {
          // Read the source file
          final bytes = await largestFile.readAsBytes();
          
          // Write to the new file
          await finalCacheFile.writeAsBytes(bytes, flush: true);
          
          // Verify the copy
          final finalSize = await finalCacheFile.length();
          if (finalSize == maxSize) {
            print("✅ Successfully created final cache: ${(finalSize / 1024 / 1024).toStringAsFixed(1)}MB");
            
            // Update tracking variables
            _bufferedBytes = finalSize;
            if (finalSize > _totalBytes) {
              _totalBytes = finalSize;
            }
            
            // Update status message
            setState(() {
              _statusMessage = "Video fully cached (${(finalSize / 1024 / 1024).toStringAsFixed(1)}MB)";
            });
            
            // Also update our active buffer
            if (_activeBufferFile != null) {
              await finalCacheFile.copy(_activeBufferFile!.path);
              print("✓ Updated active buffer with final cache");
            }
            
            print("✅ Cache file saved successfully");
            return;
          } else {
            print("❌ Final cache size mismatch: expected $maxSize, got $finalSize");
            await finalCacheFile.delete();
          }
        } catch (e) {
          print("❌ Error copying cache file: $e");
          try {
            await finalCacheFile.delete();
          } catch (_) {}
        }
      }
      
      print("❌ No valid cache files found to save");
    } catch (e) {
      print("❌ Error creating final cache: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("Better Player with Caching"),
        actions: [
          // Add a button to show cache files
          IconButton(
            icon: Icon(Icons.folder),
            onPressed: () {
              _showCacheFiles(context);
            },
            tooltip: "Show cached files",
          ),
        ],
      ),
      body: SingleChildScrollView(
        child: Column(
          children: [
            // Status message
            Container(
              color: _isOffline ? Colors.red[100] : Colors.green[100],
              padding: EdgeInsets.all(8),
              width: double.infinity,
              child: Text(
                _statusMessage,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: _isOffline ? Colors.red[900] : Colors.green[900],
                ),
              ),
            ),
            
            AspectRatio(
              aspectRatio: 16 / 9,
              child: BetterPlayer(
                controller: _betterPlayerController,
              ),
            ),
            
            // Debug controls section
            Container(
              margin: EdgeInsets.only(top: 20),
              padding: EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.grey[200],
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    "Playback Controls",
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      ElevatedButton(
                        onPressed: () {
                          _betterPlayerController.seekTo(Duration.zero);
                          _betterPlayerController.play();
                        },
                        child: Text("Restart"),
                        style: ElevatedButton.styleFrom(
                          padding: EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                        ),
                      ),
                      ElevatedButton(
                        onPressed: () {
                          final currentPosition = _betterPlayerController.videoPlayerController?.value.position;
                          if (currentPosition != null) {
                            // When seeking backward, especially in offline mode,
                            // we need special handling
                            if (_isOffline) {
                              _seekBackwardOffline(currentPosition - Duration(seconds: 10));
                            } else {
                              _betterPlayerController.seekTo(
                                currentPosition - Duration(seconds: 10),
                              );
                            }
                          }
                        },
                        child: Text("- 10s"),
                        style: ElevatedButton.styleFrom(
                          padding: EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                        ),
                      ),
                      ElevatedButton(
                        onPressed: () {
                          final currentPosition = _betterPlayerController.videoPlayerController?.value.position;
                          if (currentPosition != null) {
                            _betterPlayerController.seekTo(
                              currentPosition + Duration(seconds: 10),
                            );
                          }
                        },
                        child: Text("+ 10s"),
                        style: ElevatedButton.styleFrom(
                          padding: EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            
            // Debug buttons section with more prominent styling
            Container(
              margin: EdgeInsets.symmetric(vertical: 20, horizontal: 16),
              padding: EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.blue[50],
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.blue[300]!),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    "Debugging Controls",
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.blue[800],
                    ),
                    textAlign: TextAlign.center,
                  ),
                  SizedBox(height: 20),
                  ElevatedButton(
                    onPressed: () {
                      _tryPlayFromCache();
                    },
                    child: Padding(
                      padding: EdgeInsets.all(12),
                      child: Text(
                        "Force Cache Playback",
                        style: TextStyle(fontSize: 16),
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.orange,
                    ),
                  ),
                  SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () async {
                      // Toggle offline mode for testing
                      setState(() {
                        _isOffline = !_isOffline;
                        _updateStatusMessage();
                      });
                    },
                    child: Padding(
                      padding: EdgeInsets.all(12),
                      child: Text(
                        _isOffline ? "Simulate Online" : "Simulate Offline",
                        style: TextStyle(fontSize: 16),
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _isOffline ? Colors.green : Colors.red,
                    ),
                  ),
                ],
              ),
            ),
            
            // Add new section to display cache files
            Container(
              margin: EdgeInsets.symmetric(vertical: 20, horizontal: 16),
              padding: EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.grey[100],
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey[400]!),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    "Cached Files",
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.grey[800],
                    ),
                    textAlign: TextAlign.center,
                  ),
                  SizedBox(height: 10),
                  FutureBuilder<List<Map<String, String>>>(
                    future: _listCacheFiles(),
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return Center(
                          child: Padding(
                            padding: const EdgeInsets.all(20.0),
                            child: CircularProgressIndicator(),
                          ),
                        );
                      } else if (snapshot.hasError) {
                        return Container(
                          padding: EdgeInsets.all(16),
                          color: Colors.red[50],
                          child: Text(
                            'Error loading cache files: ${snapshot.error}',
                            style: TextStyle(color: Colors.red),
                          ),
                        );
                      } else if (!snapshot.hasData || snapshot.data!.isEmpty) {
                        return Container(
                          padding: EdgeInsets.all(16),
                          alignment: Alignment.center,
                          child: Text(
                            'No cache files found',
                            style: TextStyle(
                              color: Colors.grey[600],
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        );
                      } else {
                        return Container(
                          constraints: BoxConstraints(maxHeight: 300),
                          child: ListView.builder(
                            shrinkWrap: true,
                            itemCount: snapshot.data!.length,
                            itemBuilder: (context, index) {
                              final item = snapshot.data![index];
                              return Container(
                                margin: EdgeInsets.symmetric(vertical: 4),
                                padding: EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(4),
                                  border: Border.all(color: Colors.grey[300]!),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      item['filename'] ?? 'Unknown file',
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 15,
                                      ),
                                    ),
                                    SizedBox(height: 4),
                                    Text(
                                      'Path: ${item['path'] ?? 'Unknown path'}',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.grey[700],
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.end,
                                      children: [
                                        Container(
                                          padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: Colors.blue[100],
                                            borderRadius: BorderRadius.circular(4),
                                          ),
                                          child: Text(
                                            item['size'] ?? '0 B',
                                            style: TextStyle(
                                              fontWeight: FontWeight.bold,
                                              color: Colors.blue[800],
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        );
                      }
                    },
                  ),
                  SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () {
                      setState(() {
                        // Refresh the UI when this button is pressed
                      });
                    },
                    child: Text("Refresh Cache List"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.grey[700],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
  
  // Special handling for backward seeking when offline
  Future<void> _seekBackwardOffline(Duration position) async {
    print("◀️ Special backward seeking in offline mode to ${position.inSeconds}s");
    
    // If we're playing from a file already, we can just do a normal seek
    final dataSource = _betterPlayerController.betterPlayerDataSource;
    if (dataSource?.type == BetterPlayerDataSourceType.file) {
      print("📁 Already playing from file, using normal seek");
      await _betterPlayerController.seekTo(position);
      return;
    }
    
    // Otherwise, we need to try to switch to cached playback
    await _tryPlayFromCache();
    
    // After switching to cache, seek to the desired position
    await _betterPlayerController.seekTo(position);
    print("✅ Completed offline backward seek to ${position.inSeconds}s");
  }

  @override
  void dispose() {
    // Ensure proper cleanup
    _bufferTimer?.cancel();
    _statusTimer?.cancel();
    
    // Safely dispose controller
    try {
      _betterPlayerController.dispose();
    } catch (e) {
      print("⚠️ Error disposing controller: $e");
    }
    
    // Clean up buffer file
    try {
      _activeBufferFile?.delete().catchError((e) => print("Error deleting buffer file: $e"));
    } catch (e) {
      print("⚠️ Error deleting buffer file: $e");
    }
    
    super.dispose();
  }
  
  // This method tries to play the next available cache file when the current one fails
  Future<void> _tryNextCachedFile() async {
    print("\n🔄 Current cache file failed during playback, trying next available file...");
    
    try {
      // Get the current file path that failed
      final currentPath = _betterPlayerController.betterPlayerDataSource?.url;
      if (currentPath == null) {
        print("\n⚠️ Cannot determine current file path");
        return;
      }
      
      // Get cache directory
      final cacheDir = await getTemporaryDirectory();
      
      // Find all potential cache files again
      List<File> candidateFiles = [];
      
      // Check standard cache locations
      try {
        final files = await Directory(cacheDir.path)
            .list(recursive: true)
            .where((entity) => 
                entity is File && 
                entity.path != currentPath &&  // Skip the current file
                entity.path.endsWith('.mp4'))
            .cast<File>()
            .toList();
        
        for (var file in files) {
          try {
            final fileSize = await file.length();
            if (fileSize > 500 * 1024) { // Only consider substantial files
              print("\n📄 Found alternate cache file: ${file.path}");
              print("- Size: ${(fileSize / 1024 / 1024).toStringAsFixed(2)}MB");
              candidateFiles.add(file);
            }
          } catch (e) {
            // Skip files we can't access
          }
        }
      } catch (e) {
        print("\n⚠️ Error scanning for alternate cache files: $e");
      }
      
      if (candidateFiles.isEmpty) {
        print("\n❌ No alternate cache files available");
        setState(() {
          _statusMessage = "No alternate cache available";
        });
        return;
      }
      
      // Sort by size (largest first)
      Map<String, int> fileSizes = {};
      for (var file in candidateFiles) {
        try {
          final size = await file.length();
          fileSizes[file.path] = size;
        } catch (e) {
          fileSizes[file.path] = 0;
        }
      }
      
      candidateFiles.sort((a, b) {
        final sizeA = fileSizes[a.path] ?? 0;
        final sizeB = fileSizes[b.path] ?? 0;
        return sizeB.compareTo(sizeA);
      });
      
      print("\n🔍 Found ${candidateFiles.length} alternate cache files");
      
      // Save current state from the failing controller
      final position = _betterPlayerController.videoPlayerController?.value.position;
      final wasPlaying = _betterPlayerController.isPlaying() ?? false;
      
      // Try each file until one works
      for (var file in candidateFiles) {
        try {
          final fileSize = fileSizes[file.path] ?? 0;
          print("\n📝 Trying alternate cache file: ${file.path}");
          
          // Create new controller
          final newController = BetterPlayerController(BetterPlayerConfiguration(
            autoPlay: false,
            looping: false,
            fit: BoxFit.contain,
          ));
          
          // Setup data source
          final dataSource = BetterPlayerDataSource(
            BetterPlayerDataSourceType.file,
            file.path,
            videoExtension: ".mp4",
            cacheConfiguration: BetterPlayerCacheConfiguration(
              useCache: false, // Don't cache a cache file
            ),
          );
          
          // Create a completer to track initialization
          final completer = Completer<bool>();
          
          // Set up event listener
          newController.addEventsListener((event) {
            if (event.betterPlayerEventType == BetterPlayerEventType.initialized) {
              completer.complete(true);
            } else if (event.betterPlayerEventType == BetterPlayerEventType.exception) {
              completer.complete(false);
            }
          });
          
          // Try to initialize with a timeout
          await newController.setupDataSource(dataSource);
          
          bool initialized = await Future.any([
            completer.future,
            Future.delayed(Duration(seconds: 5)).then((_) => false),
          ]);
          
          if (!initialized) {
            print("\n❌ Failed to initialize with alternate cache file");
            newController.dispose();
            continue;
          }
          
          // Success! We have a working controller
          print("\n✅ Successfully initialized with alternate cache file");
          
          // Switch controllers
          final oldController = _betterPlayerController;
          final currentFileSize = fileSizes[file.path] ?? 0;
          setState(() {
            _betterPlayerController = newController;
            _statusMessage = "Using alternate cache (${(currentFileSize / 1024 / 1024).toStringAsFixed(2)}MB)";
          });
          
          // Restore state
          try {
            if (position != null) {
              await _betterPlayerController.seekTo(position);
            }
            
            if (wasPlaying) {
              await _betterPlayerController.play();
            }
          } catch (e) {
            print("\n⚠️ Error restoring playback state: $e");
          }
          
          // Clean up old controller
          oldController.dispose();
          
          print("\n✅ Successfully switched to alternate cached playback");
          return;
        } catch (e) {
          print("\n❌ Error trying alternate cache file: $e");
          continue;
        }
      }
      
      print("\n❌ Could not play from any alternate cache file");
      setState(() {
        _statusMessage = "No working cache available";
      });
      
    } catch (e) {
      print("\n❌ Error in _tryNextCachedFile: $e");
    }
  }

  // Add the missing _setupEventListeners method
  void _setupEventListeners() {
    // Get the total video size when initialized and setup other event handlers
    _betterPlayerController.addEventsListener((BetterPlayerEvent event) async {
      if (event.betterPlayerEventType == BetterPlayerEventType.initialized) {
        print("✅ Player initialized successfully");
        
        try {
          // Make a HEAD request to get the content length
          final client = HttpClient();
          final request = await client.headUrl(Uri.parse(videoUrl));
          final response = await request.close();
          
          if (response.contentLength != null && response.contentLength! > 0) {
            _totalBytes = response.contentLength!;
            print("📊 Total video size: ${(_totalBytes / 1024 / 1024).toStringAsFixed(2)}MB");
          }
          client.close();
        } catch (e) {
          print("⚠️ Error getting video size: $e");
        }
        
        if (mounted) {
          setState(() {
            _statusMessage = "Player initialized";
          });
          
          // Start saving buffer when initialized
          _startSavingBuffer();
        }
        
      } else if (event.betterPlayerEventType == BetterPlayerEventType.exception) {
        print("❌ Exception occurred: ${event.parameters}");
        
        if (_isOffline) {
          _tryPlayFromCache();
        }
      } else if (event.betterPlayerEventType == BetterPlayerEventType.progress) {
        try {
          final progress = event.parameters?["progress"];
          if (progress != null) {
            double percentage = 0;
            if (progress is Duration) {
              final duration = _betterPlayerController.videoPlayerController?.value.duration;
              if (duration != null && duration.inMilliseconds > 0) {
                percentage = (progress.inMilliseconds / duration.inMilliseconds);
                _updateBufferPercentage(percentage);
                
                // Update buffered bytes based on percentage of total size
                if (_totalBytes > 0) {
                  _bufferedBytes = (percentage * _totalBytes).round();
                  print("💾 Buffered bytes: ${(_bufferedBytes / 1024 / 1024).toStringAsFixed(2)}MB / ${(_totalBytes / 1024 / 1024).toStringAsFixed(2)}MB");
                }
              }
            } else if (progress is num) {
              percentage = progress.toDouble();
              _updateBufferPercentage(percentage);
              
              // Update buffered bytes based on percentage
              if (_totalBytes > 0) {
                _bufferedBytes = (percentage * _totalBytes).round();
                print("💾 Buffered bytes: ${(_bufferedBytes / 1024 / 1024).toStringAsFixed(2)}MB / ${(_totalBytes / 1024 / 1024).toStringAsFixed(2)}MB");
              }
            }
          }
        } catch (e) {
          print("⚠️ Progress calculation error: $e");
        }
      } else if (event.betterPlayerEventType == BetterPlayerEventType.finished) {
        print("✅ Video finished playing");
        // Stop all monitoring when video finishes
        _stopAllMonitoring();
        if (mounted) {
          setState(() {
            _statusMessage = "Video playback completed";
          });
        }
      } else if (event.betterPlayerEventType == BetterPlayerEventType.bufferingUpdate) {
        if (_betterPlayerController.videoPlayerController != null) {
          final bufferedRanges = _betterPlayerController.videoPlayerController!.value.buffered;
          final duration = _betterPlayerController.videoPlayerController!.value.duration;
          
          if (bufferedRanges.isNotEmpty && duration?.inMilliseconds != null && duration!.inMilliseconds > 0) {
            int totalBufferedMs = 0;
            for (var range in bufferedRanges) {
              totalBufferedMs += (range.end.inMilliseconds - range.start.inMilliseconds);
            }
            
            final newPercentage = totalBufferedMs / duration.inMilliseconds;
            _updateBufferPercentage(newPercentage);
            
            // Update buffered bytes based on percentage of total size
            if (_totalBytes > 0) {
              _bufferedBytes = (newPercentage * _totalBytes).round();
              print("💾 Buffered bytes: ${(_bufferedBytes / 1024 / 1024).toStringAsFixed(2)}MB / ${(_totalBytes / 1024 / 1024).toStringAsFixed(2)}MB");
            }
          }
        }
      }
    });
  }

  // Add the visibility changed handler function
  void onVisibilityChanged(double visibilityFraction) {
    if (visibilityFraction <= 0) {
      _betterPlayerController.pause();
    } else if (_betterPlayerController.isPlaying() ?? false) {
      _betterPlayerController.play();
    }
  }

  // Add these new methods for displaying cache files
  Future<void> _showCacheFiles(BuildContext context) async {
    // Show loading indicator
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => Center(
        child: CircularProgressIndicator(),
      ),
    );
    
    try {
      final cacheInfo = await _listCacheFiles();
      
      // Dismiss loading indicator
      Navigator.of(context).pop();
      
      // Show cache files in a dialog
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: Text("Cache Directory Files"),
          content: Container(
            width: double.maxFinite,
            height: 400,
            child: cacheInfo.isEmpty
                ? Center(child: Text("No files found in cache directory"))
                : ListView.builder(
                    itemCount: cacheInfo.length,
                    itemBuilder: (context, index) {
                      final item = cacheInfo[index];
                      return ListTile(
                        title: Text(
                          item['filename'] ?? 'Unknown file',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        subtitle: Text(
                          "Path: ${item['path'] ?? 'Unknown path'}",
                          style: TextStyle(fontSize: 12),
                        ),
                        trailing: Text(
                          item['size'] ?? '0 B',
                          style: TextStyle(
                            color: Colors.blue,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        dense: true,
                      );
                    },
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
              },
              child: Text("Close"),
            ),
            TextButton(
              onPressed: () async {
                Navigator.of(context).pop();
                await _clearAllCacheFiles();
                // Show confirmation
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text("Cache files cleared"),
                    duration: Duration(seconds: 2),
                  ),
                );
              },
              child: Text("Clear Cache", style: TextStyle(color: Colors.red)),
            ),
          ],
        ),
      );
    } catch (e) {
      // Dismiss loading indicator
      Navigator.of(context).pop();
      
      // Show error
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("Error listing cache files: $e"),
          backgroundColor: Colors.red,
        ),
      );
    }
  }
  
  Future<List<Map<String, String>>> _listCacheFiles() async {
    List<Map<String, String>> result = [];
    
    try {
      final cacheDir = await getTemporaryDirectory();
      print("📂 Scanning cache directory: ${cacheDir.path}");
      
      if (!await cacheDir.exists()) {
        print("❌ Cache directory doesn't exist");
        return result;
      }
      
      // Get all files in the directory and subdirectories
      final entities = await cacheDir.list(recursive: true).toList();
      print("📊 Found ${entities.length} files/directories in cache");
      
      // Filter to files only and sort by size
      final files = entities.whereType<File>().toList();
      
      // Get sizes for all files
      for (var file in files) {
        try {
          final size = await file.length();
          final sizeFormatted = _formatFileSize(size);
          final filename = file.path.split('/').last;
          
          result.add({
            'filename': filename,
            'path': file.path,
            'size': sizeFormatted,
            'raw_size': size.toString(), // For sorting
          });
        } catch (e) {
          print("⚠️ Error getting file size: $e");
          result.add({
            'filename': file.path.split('/').last,
            'path': file.path,
            'size': 'Error',
            'raw_size': '0',
          });
        }
      }
      
      // Sort by size (largest first)
      result.sort((a, b) {
        final sizeA = int.tryParse(a['raw_size'] ?? '0') ?? 0;
        final sizeB = int.tryParse(b['raw_size'] ?? '0') ?? 0;
        return sizeB.compareTo(sizeA);
      });
      
      return result;
    } catch (e) {
      print("❌ Error listing cache files: $e");
      return [];
    }
  }
  
  String _formatFileSize(int bytes) {
    const suffixes = ['B', 'KB', 'MB', 'GB', 'TB'];
    var i = 0;
    double size = bytes.toDouble();
    
    while (size >= 1024 && i < suffixes.length - 1) {
      size /= 1024;
      i++;
    }
    
    return '${size.toStringAsFixed(2)} ${suffixes[i]}';
  }
  
  Future<void> _clearAllCacheFiles() async {
    try {
      final cacheDir = await getTemporaryDirectory();
      
      // Delete all files first
      final entities = await cacheDir.list(recursive: true).toList();
      for (var entity in entities) {
        if (entity is File) {
          try {
            await entity.delete();
          } catch (e) {
            print("⚠️ Error deleting file ${entity.path}: $e");
          }
        }
      }
      
      // Reset our tracking variables
      setState(() {
        _highestBufferedPercentage = 0.0;
        _bufferedPercentage = 0.0;
        _totalBytes = 0;
        _bufferedBytes = 0;
        _isFullyCached = false;
      });
      
      // Reset buffer file
      await _initializeBufferFile();
      
      print("✅ Cache files cleared successfully");
    } catch (e) {
      print("❌ Error clearing cache files: $e");
    }
  }

  // Add method to refresh cached files when needed
  void _refreshCacheList() {
    if (mounted) {
      setState(() {
        // Trigger rebuild to refresh cache list
      });
    }
  }
} 
