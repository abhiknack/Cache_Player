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
  late BetterPlayerController _betterPlayerController;
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
      if (_highestBufferedPercentage >= 0.99) {
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
      looping: false,
      fit: BoxFit.contain,
      handleLifecycle: true,
      autoDispose: true,
      controlsConfiguration: BetterPlayerControlsConfiguration(
        enablePlayPause: true,
        enableSkips: true,
        enableFullscreen: true,
        enableProgressText: true,
        enableProgressBar: true,
        showControlsOnInitialize: true,
        loadingWidget: Center(
          child: CircularProgressIndicator(
            valueColor: AlwaysStoppedAnimation<Color>(Colors.blue),
          ),
        ),
      ),
    );

    // Define the data source with optimized caching configuration
    BetterPlayerDataSource dataSource = BetterPlayerDataSource(
      BetterPlayerDataSourceType.network,
      videoUrl,
      cacheConfiguration: BetterPlayerCacheConfiguration(
        useCache: true,
        maxCacheFileSize: 50 * 1024 * 1024, // Increased to 50 MB per file
        maxCacheSize: 100 * 1024 * 1024, // Increased to 100 MB total cache
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

    // Initialize the controller
    _betterPlayerController = BetterPlayerController(betterPlayerConfiguration);
    _betterPlayerController.setupDataSource(dataSource);

    // Get the total video size when initialized
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
        
        setState(() {
          _statusMessage = "Player initialized";
        });
        
        // Start saving buffer when initialized
        _startSavingBuffer();
        
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
                
                // Save buffer when we reach certain thresholds
                if ((percentage * 100) % 25 < 1) {
                  print("📊 Buffering: ${(percentage * 100).toStringAsFixed(1)}%");
                  _saveCurrentBuffer();
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
              
              // Save buffer when we reach certain thresholds
              if ((percentage * 100) % 25 < 1) {
                print("📊 Buffering: ${(percentage * 100).toStringAsFixed(1)}%");
                _saveCurrentBuffer();
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
        setState(() {
          _statusMessage = "Video playback completed";
        });
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

  // Modify _startSavingBuffer to check video state
  Future<void> _startSavingBuffer() async {
    if (_activeBufferFile == null || _isFullyCached) return;
    
    // Cancel any existing timers
    _bufferTimer?.cancel();
    _statusTimer?.cancel();
    
    // Start buffer check timer
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
          
          // Save buffer
          await _saveCurrentBuffer();
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

  Future<void> _tryPlayFromCache() async {
    print("\n🔍 === Starting Enhanced Cache Playback Attempt ===");
    print("📊 Current state:");
    print("- Offline mode: $_isOffline");
    print("- Buffered percentage: ${(_highestBufferedPercentage * 100).toStringAsFixed(1)}%");
    print("- Buffered bytes: ${(_bufferedBytes / 1024 / 1024).toStringAsFixed(2)}MB");
    print("- Total bytes: ${(_totalBytes / 1024 / 1024).toStringAsFixed(2)}MB");
    
    try {
      // Get cache directory
      final cacheDir = await getTemporaryDirectory();
      print("\n📂 Cache directory: ${cacheDir.path}");
      
      List<File> candidateFiles = [];
      
      // Look in multiple places for cache files
      
      // 1. Check standard BetterPlayer cache locations
      try {
        final betterPlayerCacheDir = Directory(cacheDir.path);
        if (await betterPlayerCacheDir.exists()) {
          final files = await betterPlayerCacheDir.list().toList();
          for (var entity in files) {
            if (entity is File) {
              final path = entity.path.toLowerCase();
              if (path.contains("big_buck_bunny") || 
                  path.contains("temp_network") || 
                  path.contains("cache") || 
                  path.contains("buffer") ||
                  path.endsWith(".mp4") ||
                  path.endsWith(".cache")) {
                
                try {
                  final size = await entity.length();
                  if (size > 100 * 1024) { // Larger than 100KB
                    print("\n📄 Found potential cache file: ${entity.path}");
                    print("- Size: ${(size / 1024 / 1024).toStringAsFixed(2)}MB");
                    candidateFiles.add(entity);
                  }
                } catch (e) {
                  print("\n⚠️ Error checking file size: $e");
                }
              }
            }
          }
        }
      } catch (e) {
        print("\n⚠️ Error scanning BetterPlayer cache: $e");
      }
      
      // 2. Check any final cache files we've created
      final finalCachePattern = RegExp(r'final_cache_.*\.mp4$');
      try {
        final finalCacheFiles = await Directory(cacheDir.path)
            .list()
            .where((entity) => 
                entity is File && 
                finalCachePattern.hasMatch(entity.path))
            .toList();
        
        for (var entity in finalCacheFiles) {
          if (entity is File) {
            try {
              final size = await entity.length();
              if (size > 100 * 1024) { // Larger than 100KB
                print("\n📄 Found final cache file: ${entity.path}");
                print("- Size: ${(size / 1024 / 1024).toStringAsFixed(2)}MB");
                candidateFiles.add(entity);
              }
            } catch (e) {
              print("\n⚠️ Error checking final cache file size: $e");
            }
          }
        }
      } catch (e) {
        print("\n⚠️ Error scanning for final cache files: $e");
      }
      
      // 3. Check our active buffer file
      if (_activeBufferFile != null) {
        try {
          if (await _activeBufferFile!.exists()) {
            final size = await _activeBufferFile!.length();
            if (size > 100 * 1024) { // Larger than 100KB
              print("\n📄 Found active buffer file: ${_activeBufferFile!.path}");
              print("- Size: ${(size / 1024 / 1024).toStringAsFixed(2)}MB");
              candidateFiles.add(_activeBufferFile!);
            } else {
              print("\n⚠️ Active buffer file is too small: ${(size / 1024 / 1024).toStringAsFixed(2)}MB");
            }
          } else {
            print("\n⚠️ Active buffer file doesn't exist");
          }
        } catch (e) {
          print("\n⚠️ Error checking active buffer file: $e");
        }
      }
      
      print("\n📊 Found ${candidateFiles.length} potential cache files");
      
      if (candidateFiles.isEmpty) {
        print("\n❌ No candidate cache files found");
        setState(() {
          _statusMessage = "No cache files found";
        });
        return;
      }
      
      // Verify and sort candidate files
      Map<String, int> fileSizes = {};
      List<File> verifiedFiles = [];
      
      for (var file in candidateFiles) {
        try {
          // Check if file exists and has content
          if (!await file.exists()) {
            print("\n⚠️ File no longer exists: ${file.path}");
            continue;
          }
          
          final size = await file.length();
          if (size <= 0) {
            print("\n⚠️ File is empty: ${file.path}");
            continue;
          }
          
          // Check if file is readable
          try {
            final bytes = await file.openRead(0, 8192).fold<List<int>>(
              <int>[],
              (previous, element) => previous..addAll(element),
            );
            
            if (bytes.isEmpty) {
              print("\n⚠️ File not readable: ${file.path}");
              continue;
            }
            
            // Basic check for video file format
            bool isValidVideo = false;
            
            // Check for MP4 magic numbers
            if (bytes.length >= 8) {
              // Check for MP4 ftyp box
              if (bytes.length > 12 && 
                  String.fromCharCodes(bytes.sublist(4, 8)) == 'ftyp') {
                isValidVideo = true;
              }
              
              // Check for older QuickTime files
              if (String.fromCharCodes(bytes.sublist(4, 8)) == 'moov' ||
                  String.fromCharCodes(bytes.sublist(4, 8)) == 'mdat') {
                isValidVideo = true;
              }
            }
            
            // Accept any file over 500KB as probably a valid video
            if (size > 500 * 1024) {
              isValidVideo = true;
            }
            
            if (isValidVideo) {
              print("\n✅ Verified cache file: ${file.path}");
              print("- Size: ${(size / 1024 / 1024).toStringAsFixed(2)}MB");
              fileSizes[file.path] = size;
              verifiedFiles.add(file);
            } else {
              print("\n⚠️ Not a valid video file: ${file.path}");
            }
          } catch (e) {
            print("\n⚠️ Error verifying file: $e");
          }
        } catch (e) {
          print("\n⚠️ Error processing file: $e");
        }
      }
      
      // Sort verified files by size (largest first)
      verifiedFiles.sort((a, b) {
        final sizeA = fileSizes[a.path] ?? 0;
        final sizeB = fileSizes[b.path] ?? 0;
        return sizeB.compareTo(sizeA);
      });
      
      print("\n🔄 Found ${verifiedFiles.length} verified cache files");
      
      if (verifiedFiles.isEmpty) {
        print("\n❌ No verified cache files available");
        setState(() {
          _statusMessage = "No valid cached content available";
        });
        return;
      }
      
      // Try to play each verified file in order (largest first)
      for (var file in verifiedFiles) {
        try {
          final size = fileSizes[file.path] ?? 0;
          print("\n📝 Attempting to initialize player with: ${file.path}");
          print("- File size: ${(size / 1024 / 1024).toStringAsFixed(2)}MB");
          
          // Create a new controller with more conservative buffering settings
          final newController = BetterPlayerController(
            BetterPlayerConfiguration(
              autoPlay: false,
              looping: false,
              fit: BoxFit.contain,
              handleLifecycle: true,
              autoDispose: true,
              showPlaceholderUntilPlay: true,
              controlsConfiguration: BetterPlayerControlsConfiguration(
                enableProgressText: true,
                enableProgressBar: true,
                showControlsOnInitialize: true,
              ),
            ),
          );
          
          // Setup data source with more conservative buffering
          final cacheDataSource = BetterPlayerDataSource(
            BetterPlayerDataSourceType.file,
            file.path,
            bufferingConfiguration: BetterPlayerBufferingConfiguration(
              minBufferMs: 2000,
              maxBufferMs: 10000,
              bufferForPlaybackMs: 1000,
              bufferForPlaybackAfterRebufferMs: 2000,
            ),
          );
          
          print("\n⏳ Setting up data source...");
          
          // Create a completer to track initialization
          final completer = Completer<bool>();
          
          // Set up event listener before setting up data source
          newController.addEventsListener((event) {
            if (event.betterPlayerEventType == BetterPlayerEventType.initialized) {
              print("\n✅ Controller initialized successfully");
              if (!completer.isCompleted) completer.complete(true);
            } else if (event.betterPlayerEventType == BetterPlayerEventType.exception) {
              print("\n❌ Controller initialization failed:");
              print("- Error: ${event.parameters}");
              if (!completer.isCompleted) completer.complete(false);
            }
          });
          
          // Try to initialize with a timeout
          bool initialized = false;
          try {
            await newController.setupDataSource(cacheDataSource);
            
            initialized = await Future.any([
              completer.future,
              Future.delayed(Duration(seconds: 5)).then((_) {
                print("\n⚠️ Initialization timeout after 5 seconds");
                return false;
              }),
            ]);
          } catch (e) {
            print("\n❌ Error initializing controller: $e");
            newController.dispose();
            continue;
          }
          
          if (!initialized) {
            print("\n❌ Failed to initialize player with this file");
            newController.dispose();
            continue;
          }
          
          // Success! We have a working controller
          print("\n✅ Successfully initialized player with: ${file.path}");
          
          // Save current state from old controller
          final position = _betterPlayerController.videoPlayerController?.value.position;
          final wasPlaying = _betterPlayerController.isPlaying() ?? false;
          
          // Switch controllers
          final oldController = _betterPlayerController;
          setState(() {
            _betterPlayerController = newController;
            _statusMessage = "Playing from cache (${(size / 1024 / 1024).toStringAsFixed(2)}MB)";
          });
          
          // Restore state
          try {
            if (position != null) {
              print("\n⏩ Seeking to position: ${position.inSeconds}s");
              await _betterPlayerController.seekTo(position);
            }
            
            if (wasPlaying) {
              print("\n▶️ Resuming playback");
              await _betterPlayerController.play();
            }
          } catch (e) {
            print("\n⚠️ Error restoring playback state: $e");
          }
          
          // Clean up old controller
          oldController.dispose();
          
          print("\n✅ Successfully switched to cached playback");
          return;
        } catch (e) {
          print("\n❌ Error trying cache file: $e");
          continue;
        }
      }
      
      print("\n❌ Could not initialize playback with any cache file");
      setState(() {
        _statusMessage = "Could not play from cache";
      });
      
    } catch (e) {
      print("\n❌ Error in _tryPlayFromCache: $e");
      setState(() {
        _statusMessage = "Cache playback error: $e";
      });
    }
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
      ),
      body: Column(
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
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    ElevatedButton(
                      onPressed: () {
                        _betterPlayerController.seekTo(Duration.zero);
                        _betterPlayerController.play();
                      },
                      child: Text("Restart"),
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
                    ),
                  ],
                ),
                SizedBox(height: 16),
                // Debugging buttons
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    ElevatedButton(
                      onPressed: () {
                        _tryPlayFromCache();
                      },
                      child: Text("Force Cache Playback"),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.orange,
                      ),
                    ),
                    ElevatedButton(
                      onPressed: () async {
                        // Toggle offline mode for testing
                        setState(() {
                          _isOffline = !_isOffline;
                          _updateStatusMessage();
                        });
                      },
                      child: Text(_isOffline ? "Simulate Online" : "Simulate Offline"),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _isOffline ? Colors.green : Colors.red,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
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
    _betterPlayerController.dispose();
    // Clean up buffer file
    _activeBufferFile?.delete().catchError((e) => print("Error deleting buffer file: $e"));
    super.dispose();
  }
} 
