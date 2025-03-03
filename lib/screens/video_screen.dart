import 'package:flutter/material.dart';
import '../models/video_item.dart';
import '../widgets/proxy_video_player.dart';
import '../cache/video_proxy_manager.dart';

class VideoScreen extends StatefulWidget {
  const VideoScreen({Key? key}) : super(key: key);

  @override
  _VideoScreenState createState() => _VideoScreenState();
}

class _VideoScreenState extends State<VideoScreen> {
  final List<VideoItem> _videos = [
    VideoItem(
      id: 'video1',
      url: 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4',
      title: 'Big Buck Bunny',
      size: 5 * 1024 * 1024, // Approximate
      duration: 600,
      qualities: {
        'SD': 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4',
        'HD': 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4',
      },
    ),
    VideoItem(
      id: 'video2',
      url: 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ElephantsDream.mp4',
      title: 'Elephants Dream',
      size: 6 * 1024 * 1024, // Approximate
      duration: 650,
      qualities: {
        'SD': 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ElephantsDream.mp4',
        'HD': 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ElephantsDream.mp4',
      },
    ),
  ];
  
  VideoItem? _selectedVideo;
  bool _initialized = false;
  
  @override
  void initState() {
    super.initState();
    _initializeProxy();
  }
  
  Future<void> _initializeProxy() async {
    final proxyManager = VideoProxyManager();
    await proxyManager.initialize();
    setState(() {
      _initialized = true;
    });
  }
  
  void _selectVideo(VideoItem video) {
    setState(() {
      _selectedVideo = video;
    });
  }
  
  void _preloadVideo(VideoItem video) async {
    final proxyManager = VideoProxyManager();
    
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Preloading ${video.title}...')),
    );
    
    await proxyManager.preloadVideo(video);
    
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${video.title} preloaded!')),
    );
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Video Proxy Demo'),
        actions: [
          IconButton(
            icon: Icon(Icons.delete),
            onPressed: () async {
              final proxyManager = VideoProxyManager();
              await proxyManager.clearCache();
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Cache cleared')),
              );
            },
          ),
        ],
      ),
      body: _initialized
          ? Column(
              children: [
                if (_selectedVideo != null)
                  Expanded(
                    flex: 3,
                    child: ProxyVideoPlayer(video: _selectedVideo!),
                  ),
                Expanded(
                  flex: 2,
                  child: ListView.builder(
                    itemCount: _videos.length,
                    itemBuilder: (context, index) {
                      final video = _videos[index];
                      return ListTile(
                        title: Text(video.title),
                        subtitle: Text('Duration: ${video.duration}s'),
                        onTap: () => _selectVideo(video),
                        trailing: IconButton(
                          icon: Icon(Icons.download),
                          onPressed: () => _preloadVideo(video),
                        ),
                      );
                    },
                  ),
                ),
              ],
            )
          : Center(
              child: CircularProgressIndicator(),
            ),
    );
  }
} 