import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_preload_videos/service/navigation_service.dart';
import 'package:flutter_preload_videos/video_page.dart';
import 'package:injectable/injectable.dart';

import 'providers/preload_provider.dart';
import 'injection.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  configureInjection(Environment.prod);
  runApp(const ProviderScope(child: MyApp()));
}

class MyApp extends ConsumerWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final NavigationService _navigationService = getIt<NavigationService>();
    
    // Initialize video preloading when app starts
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(preloadProvider.notifier).getVideosFromApi();
    });

    return MaterialApp(
      key: _navigationService.navigationKey,
      debugShowCheckedModeBanner: false,
      home: const VideoPage(),
    );
  }
}
