import 'dart:io';
import 'package:better_player/better_player.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'dart:async';

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
      "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4";
  
  bool _isOffline = false;
  double _bufferedPercentage = 0.0;
  String _statusMessage = "Initializing player...";
  File? _activeBufferFile;
  
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
          await _continueWithBufferedContent();
        } else {
          // If we're back online, restore network playback if needed
          await _restoreNetworkPlayback();
        }
      }
    });
  }
  
  void _updateStatusMessage() {
    setState(() {
      if (_isOffline) {
        _statusMessage = "OFFLINE MODE - ${(_bufferedPercentage * 100).toStringAsFixed(0)}% buffered";
      } else {
        _statusMessage = "Connected - ${(_bufferedPercentage * 100).toStringAsFixed(0)}% buffered";
      }
    });
  }

  Future<void> _initializeBufferFile() async {
    try {
      final cacheDir = await getTemporaryDirectory();
      final String tempPath = '${cacheDir.path}/current_buffer_${DateTime.now().millisecondsSinceEpoch}.mp4';
      _activeBufferFile = File(tempPath);
      print("📁 Initialized buffer file at: $tempPath");
    } catch (e) {
      print("❌ Error initializing buffer file: $e");
    }
  }

  void _setupPlayer() {
    // Define better player configuration
    BetterPlayerConfiguration betterPlayerConfiguration = BetterPlayerConfiguration(
      autoPlay: true,
      looping: false,
      fit: BoxFit.contain,
      handleLifecycle: true, // This will pause video when app goes to background
      autoDispose: true, // This will dispose controller when widget is disposed
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
        key: "big_buck_bunny", // Ensure we have a predictable cache key
      ),
      bufferingConfiguration: BetterPlayerBufferingConfiguration(
        minBufferMs: 50000, // 50 seconds
        maxBufferMs: 120000, // 120 seconds
        bufferForPlaybackMs: 2500, // 2.5 seconds
        bufferForPlaybackAfterRebufferMs: 5000, // 5 seconds
      ),
      notificationConfiguration: BetterPlayerNotificationConfiguration(
        showNotification: false, // Disable notifications to reduce memory usage
      ),
    );

    // Initialize the controller
    _betterPlayerController = BetterPlayerController(betterPlayerConfiguration);
    _betterPlayerController.setupDataSource(dataSource);

    // Add error handling and buffer tracking
    _betterPlayerController.addEventsListener((BetterPlayerEvent event) {
      if (event.betterPlayerEventType == BetterPlayerEventType.initialized) {
        print("✅ Player initialized successfully");
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
                
                // Update buffered percentage for status message
                setState(() {
                  _bufferedPercentage = percentage;
                  _updateStatusMessage();
                });
                
                // Save buffer when we reach certain thresholds
                if ((percentage * 100) % 25 < 1) {
                  print("📊 Buffering: ${(percentage * 100).toStringAsFixed(1)}%");
                  _saveCurrentBuffer();
                }
              }
            } else if (progress is num) {
              percentage = progress.toDouble();
              
              // Update buffered percentage for status message
              setState(() {
                _bufferedPercentage = percentage;
                _updateStatusMessage();
              });
              
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
      } else if (event.betterPlayerEventType == BetterPlayerEventType.bufferingUpdate) {
        // Update buffering information based on the controller's buffered ranges
        if (_betterPlayerController.videoPlayerController != null) {
          final bufferedRanges = _betterPlayerController.videoPlayerController!.value.buffered;
          final duration = _betterPlayerController.videoPlayerController!.value.duration;
          
          if (bufferedRanges.isNotEmpty && duration?.inMilliseconds != null && duration!.inMilliseconds > 0) {
            // Calculate total buffered duration
            int totalBufferedMs = 0;
            for (var range in bufferedRanges) {
              totalBufferedMs += (range.end.inMilliseconds - range.start.inMilliseconds);
            }
            
            // Update buffered percentage
            setState(() {
              _bufferedPercentage = totalBufferedMs / duration.inMilliseconds;
              _updateStatusMessage();
            });
          }
        }
      }
    });
  }

  // Add this new function to continuously save buffer
  Future<void> _startSavingBuffer() async {
    if (_activeBufferFile == null) return;
    
    Timer.periodic(Duration(seconds: 5), (timer) async {
      if (!mounted) {
        timer.cancel();
        return;
      }
      await _saveCurrentBuffer();
    });
  }

  // Add this new function to save current buffer
  Future<void> _saveCurrentBuffer() async {
    try {
      if (_activeBufferFile == null) return;
      
      final cacheDir = await getTemporaryDirectory();
      final cacheKey = "big_buck_bunny";
      
      // Check the cache directory for all cache files
      final dir = Directory(cacheDir.path);
      final files = dir.listSync();
      
      File? largestFile;
      int maxSize = 0;
      
      // Find the largest cache file
      for (var file in files) {
        if (file is File && file.path.contains(cacheKey)) {
          final size = await file.length();
          if (size > maxSize) {
            maxSize = size;
            largestFile = file;
          }
        }
      }
      
      // Copy the largest cache file to our buffer file
      if (largestFile != null) {
        await largestFile.copy(_activeBufferFile!.path);
        print("💾 Updated buffer file: ${(maxSize / 1024).toStringAsFixed(1)}KB");
      }
    } catch (e) {
      print("❌ Error saving buffer: $e");
    }
  }

  // Add new function to continue playback from buffer when going offline
  Future<void> _continueWithBufferedContent() async {
    try {
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

  // Modify the existing _tryPlayFromCache function to be more aggressive
  Future<void> _tryPlayFromCache() async {
    print("🔍 Trying to play from cache due to offline or error...");
    
    try {
      File? cacheFile;
      int maxSize = 0;
      
      // First try to use our active buffer file
      if (_activeBufferFile != null && await _activeBufferFile!.exists()) {
        final size = await _activeBufferFile!.length();
        if (size > 0) {
          cacheFile = _activeBufferFile;
          maxSize = size;
          print("✅ Using active buffer file: ${_activeBufferFile!.path} (${(size / 1024).toStringAsFixed(1)}KB)");
        }
      }
      
      // Also check the cache directory for potentially larger files
      final cacheDir = await getTemporaryDirectory();
      final cacheKey = "big_buck_bunny";
      
      final dir = Directory(cacheDir.path);
      final files = dir.listSync();
      
      for (var file in files) {
        if (file is File && file.path.contains(cacheKey)) {
          final size = await file.length();
          if (size > maxSize) {
            maxSize = size;
            cacheFile = file;
          }
        }
      }
      
      if (cacheFile != null && maxSize > 0) {
        print("✅ Using cache file: ${cacheFile.path} (${(maxSize / 1024).toStringAsFixed(1)}KB)");
        
        // Save current state
        final position = _betterPlayerController.videoPlayerController?.value.position;
        final wasPlaying = _betterPlayerController.isPlaying() ?? false;
        
        // Create new controller
        final newController = BetterPlayerController(
          BetterPlayerConfiguration(
            autoPlay: wasPlaying,
            looping: false,
            fit: BoxFit.contain,
          ),
        );
        
        // Setup the data source
        final cacheDataSource = BetterPlayerDataSource(
          BetterPlayerDataSourceType.file,
          cacheFile.path,
        );
        
        await newController.setupDataSource(cacheDataSource);
        
        // Store old controller
        final oldController = _betterPlayerController;
        
        // Switch to new controller
        setState(() {
          _betterPlayerController = newController;
          _statusMessage = "Playing from cached content (${(maxSize / 1024 / 1024).toStringAsFixed(1)}MB)";
        });
        
        // Restore position and state
        if (position != null) {
          await _betterPlayerController.seekTo(position);
        }
        if (wasPlaying) {
          await _betterPlayerController.play();
        }
        
        // Dispose old controller
        oldController.dispose();
        
        print("✅ Successfully switched to cached playback");
      } else {
        print("❌ No usable cache file found");
        setState(() {
          _statusMessage = "No cached content available";
        });
      }
    } catch (e) {
      print("❌ Error trying to play from cache: $e");
      setState(() {
        _statusMessage = "Error playing from cache: $e";
      });
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