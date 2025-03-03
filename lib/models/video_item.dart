class VideoItem {
  final String id;
  final String url;
  final String title;
  final int size;
  final int duration; // in seconds
  final Map<String, String> qualities; // Map of quality name to URL

  VideoItem({
    required this.id,
    required this.url,
    required this.title,
    required this.size,
    required this.duration,
    required this.qualities,
  });

  factory VideoItem.fromJson(Map<String, dynamic> json) {
    return VideoItem(
      id: json['id'],
      url: json['url'],
      title: json['title'],
      size: json['size'],
      duration: json['duration'],
      qualities: Map<String, String>.from(json['qualities']),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'url': url,
      'title': title,
      'size': size,
      'duration': duration,
      'qualities': qualities,
    };
  }
} 