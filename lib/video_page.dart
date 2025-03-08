import 'package:better_player/better_player.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_preload_videos/providers/preload_provider.dart';

class VideoPage extends ConsumerWidget {
  const VideoPage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(preloadProvider);
    final notifier = ref.read(preloadProvider.notifier);

    return SafeArea(
      child: PageView.builder(
        itemCount: state.urls.length,
        scrollDirection: Axis.vertical,
        onPageChanged: (index) => notifier.onVideoIndexChanged(index),
        itemBuilder: (context, index) {
          // Is at end and isLoading
          final bool _isLoading =
              (state.isLoading && index == state.urls.length - 1);

          return state.focusedIndex == index
              ? VideoWidget(
                  isLoading: _isLoading,
                  controller: state.controllers[index]!,
                )
              : const SizedBox();
        },
      ),
    );
  }
}

/// Custom Feed Widget consisting video
class VideoWidget extends StatefulWidget {
  const VideoWidget({
    Key? key,
    required this.isLoading,
    required this.controller,
  }) : super(key: key);

  final bool isLoading;
  final BetterPlayerController controller;

  @override
  State<VideoWidget> createState() => _VideoWidgetState();
}

class _VideoWidgetState extends State<VideoWidget> {
  @override
  void initState() {
    super.initState();
    widget.controller.addEventsListener(_onPlayerEvent);
  }

  void _onPlayerEvent(BetterPlayerEvent event) {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeEventsListener(_onPlayerEvent);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool isInitialized = widget.controller.isVideoInitialized() ?? false;

    if (!isInitialized) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CupertinoActivityIndicator(color: Colors.white, radius: 8),
            SizedBox(height: 8),
            Text('Loading...'),
          ],
        ),
      );
    }

    return Column(
      children: [
        Expanded(child: BetterPlayer(controller: widget.controller)),
        AnimatedCrossFade(
          alignment: Alignment.bottomCenter,
          sizeCurve: Curves.decelerate,
          duration: const Duration(milliseconds: 400),
          firstChild: Padding(
            padding: const EdgeInsets.all(10.0),
            child: CupertinoActivityIndicator(color: Colors.white, radius: 8),
          ),
          secondChild: const SizedBox(),
          crossFadeState: widget.isLoading ? CrossFadeState.showFirst : CrossFadeState.showSecond,
        ),
      ],
    );
  }
}
