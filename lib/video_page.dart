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
class VideoWidget extends StatelessWidget {
  const VideoWidget({
    Key? key,
    required this.isLoading,
    required this.controller,
  });

  final bool isLoading;
  final BetterPlayerController controller;
  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: Future.value(controller.isVideoInitialized()),
      builder: (context, snapshot) {
        if (!snapshot.hasData || !snapshot.data!) {
          return const Center(
            child: Column(
              children: [
                CupertinoActivityIndicator(
                  color: Colors.white,
                  radius: 8,
                ),
                Text('Loading...'),
              ],
            ),
          );
        }

        return Column(
          children: [
            Expanded(child: BetterPlayer(controller: controller)),
            AnimatedCrossFade(
              alignment: Alignment.bottomCenter,
              sizeCurve: Curves.decelerate,
              duration: const Duration(milliseconds: 400),
              firstChild: Padding(
                padding: const EdgeInsets.all(10.0),
                child: CupertinoActivityIndicator(
                  color: Colors.white,
                  radius: 8,
                ),
              ),
              secondChild: const SizedBox(),
              crossFadeState:
                  isLoading ? CrossFadeState.showFirst : CrossFadeState.showSecond,
            ),
          ],
        );
      },
    );
  }
}
