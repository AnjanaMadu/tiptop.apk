import 'dart:async';
import 'dart:math';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:html/parser.dart' as parser;
import 'package:video_player/video_player.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:intl/intl.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Colors.black,
  ));
  runApp(const TelegramVideoApp());
}

class TelegramVideoApp extends StatelessWidget {
  const TelegramVideoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Telegram Viewer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF000000),
        colorScheme: const ColorScheme.dark(primary: Colors.white),
        sliderTheme: SliderThemeData(
          trackHeight: 4,
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
          overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
          activeTrackColor: Colors.white,
          inactiveTrackColor: Colors.white.withOpacity(0.3),
          thumbColor: Colors.white,
          trackShape: const RoundedRectSliderTrackShape(),
        ),
      ),
      home: const FeedScreen(),
    );
  }
}

// -------------------- MODELS --------------------

enum MediaType { video, photo }

class MediaItem {
  final MediaType type;
  final String url;
  final String thumbnailUrl;

  MediaItem({required this.type, required this.url, required this.thumbnailUrl});
}

class Post {
  final String postId;
  final List<MediaItem> media;
  final String timestamp;
  final int views;

  Post({required this.postId, required this.media, required this.timestamp, required this.views});
}

// -------------------- SCRAPER SERVICE --------------------

class ScraperService {
  static const String channel = "ewInstagram";
  static const String baseUrl = "https://t.me/s/$channel";

  Future<int> getLatestPostId() async {
    try {
      final response = await http.get(Uri.parse(baseUrl)).timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return 10000;
      var document = parser.parse(response.body);
      var messages = document.querySelectorAll('div.tgme_widget_message');
      int maxId = 0;
      for (var msg in messages) {
        String? dataPost = msg.attributes['data-post'];
        if (dataPost != null) {
          int id = int.tryParse(dataPost.split('/').last) ?? 0;
          if (id > maxId) maxId = id;
        }
      }
      return maxId > 0 ? maxId : 10000;
    } catch (e) {
      return 10000;
    }
  }

  Future<List<Post>> fetchPosts({int? before}) async {
    try {
      final String url = before != null ? "$baseUrl?before=$before" : baseUrl;
      final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) return [];

      var document = parser.parse(response.body);
      var messages = document.querySelectorAll('div.tgme_widget_message');
      List<Post> posts = [];

      for (var message in messages) {
        try {
          String? dataPost = message.attributes['data-post'];
          if (dataPost == null || !dataPost.contains('/')) continue;
          String postId = dataPost.split('/').last;

          var timeElement = message.querySelector('time.time');
          String timestamp = timeElement?.attributes['datetime'] ?? "";

          var viewsElement = message.querySelector('span.tgme_widget_message_views');
          int views = _parseViews(viewsElement?.text.trim() ?? "0");

          List<MediaItem> mediaItems = [];
          
          var groupedWrap = message.querySelector('div.tgme_widget_message_grouped_wrap');
          if (groupedWrap != null) {
            var photoWraps = groupedWrap.querySelectorAll('a.tgme_widget_message_photo_wrap');
            for (var wrap in photoWraps) {
              String? url = _extractUrl(wrap.attributes['style'] ?? "");
              if (url != null) mediaItems.add(MediaItem(type: MediaType.photo, url: url, thumbnailUrl: url));
            }
          } else if (message.querySelector('a.tgme_widget_message_video_player') != null) {
            var player = message.querySelector('a.tgme_widget_message_video_player')!;
            var thumb = player.querySelector('i.tgme_widget_message_video_thumb');
            String thumbUrl = _extractUrl(thumb?.attributes['style'] ?? "") ?? "";
            String videoUrl = player.querySelector('video.tgme_widget_message_video')?.attributes['src'] ?? "";
            if (videoUrl.isNotEmpty) mediaItems.add(MediaItem(type: MediaType.video, url: videoUrl, thumbnailUrl: thumbUrl));
          } else if (message.querySelector('a.tgme_widget_message_photo_wrap') != null) {
             var wrap = message.querySelector('a.tgme_widget_message_photo_wrap')!;
             String? url = _extractUrl(wrap.attributes['style'] ?? "");
             if (url != null) mediaItems.add(MediaItem(type: MediaType.photo, url: url, thumbnailUrl: url));
          }

          if (mediaItems.isNotEmpty) {
            posts.add(Post(postId: postId, media: mediaItems, timestamp: timestamp, views: views));
          }
        } catch (_) {}
      }
      posts.sort((a, b) => int.parse(b.postId).compareTo(int.parse(a.postId)));
      return posts;
    } catch (e) {
      return [];
    }
  }

  String? _extractUrl(String style) {
    RegExp exp = RegExp(r"url\('([^']+)'\)");
    return exp.firstMatch(style)?.group(1);
  }

  int _parseViews(String text) {
    try {
      if (text.contains('K')) return (double.parse(text.replaceAll('K', '')) * 1000).toInt();
      if (text.contains('M')) return (double.parse(text.replaceAll('M', '')) * 1000000).toInt();
      return int.parse(text.replaceAll(RegExp(r'[^0-9]'), ''));
    } catch (_) { return 0; }
  }
}

// -------------------- MAIN FEED SCREEN --------------------

class FeedScreen extends StatefulWidget {
  const FeedScreen({super.key});

  @override
  State<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends State<FeedScreen> {
  final ScraperService _scraper = ScraperService();
  final PageController _pageController = PageController();
  final Map<int, VideoPlayerController> _videoControllers = {};
  
  List<Post> _posts = [];
  bool _isLoading = false;
  String _mode = 'latest'; 
  int? _minPostId; 

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    _loadPosts();
  }

  @override
  void dispose() {
    for (var c in _videoControllers.values) c.dispose();
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _loadPosts({bool refresh = false}) async {
    if (_isLoading) return;
    setState(() {
      _isLoading = true;
      if (refresh) {
        _disposeAllControllers();
        _posts.clear();
        _minPostId = null;
      }
    });

    try {
      List<Post> newPosts = [];
      if (_mode == 'latest') {
        newPosts = await _scraper.fetchPosts(before: _minPostId);
      } else if (_mode == 'random' && refresh) {
        int maxId = await _scraper.getLatestPostId();
        int randomStart = Random().nextInt(maxId > 10 ? maxId - 10 : maxId);
        newPosts = await _scraper.fetchPosts(before: randomStart);
      } else if (_mode == 'random' && !refresh) {
        newPosts = await _scraper.fetchPosts(before: _minPostId);
      }

      if (newPosts.isNotEmpty) {
        List<int> ids = newPosts.map((p) => int.parse(p.postId)).toList();
        _minPostId = ids.reduce(min);
        
        setState(() {
          _posts.addAll(newPosts);
        });

        if (refresh || _posts.length == newPosts.length) {
          _onPageChanged(0);
        }
      }
    } finally {
      setState(() => _isLoading = false);
    }
  }

  void _disposeAllControllers() {
    for (var c in _videoControllers.values) c.dispose();
    _videoControllers.clear();
  }

  void _onPageChanged(int index) {
    _playControllerAtIndex(index);
    _pauseControllerAtIndex(index - 1);
    _pauseControllerAtIndex(index + 1);
    _initControllerAtIndex(index + 1);
    _initControllerAtIndex(index + 2);
    _disposeControllerAtIndex(index - 2);
    if (index >= _posts.length - 3) _loadPosts();
  }

  Future<void> _initControllerAtIndex(int index) async {
    if (index < 0 || index >= _posts.length) return;
    if (_videoControllers.containsKey(index)) return;

    final post = _posts[index];
    if (post.media.first.type != MediaType.video) return;

    final controller = VideoPlayerController.networkUrl(Uri.parse(post.media.first.url));
    _videoControllers[index] = controller;
    
    try {
      await controller.initialize();
      controller.setLooping(true);
      if (mounted) setState(() {});
    } catch (e) {
      _videoControllers.remove(index);
    }
  }

  void _playControllerAtIndex(int index) {
    if (index < 0 || index >= _posts.length) return;
    if (!_videoControllers.containsKey(index)) {
      _initControllerAtIndex(index).then((_) {
        _videoControllers[index]?.play();
      });
    } else {
      _videoControllers[index]?.play();
    }
  }

  void _pauseControllerAtIndex(int index) {
    _videoControllers[index]?.pause();
  }

  void _disposeControllerAtIndex(int index) {
    if (_videoControllers.containsKey(index)) {
      _videoControllers[index]?.dispose();
      _videoControllers.remove(index);
    }
  }

  void _switchMode(String newMode) {
    if (_mode == newMode) return;
    setState(() => _mode = newMode);
    _loadPosts(refresh: true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          if (_posts.isEmpty && _isLoading)
            const Center(child: CircularProgressIndicator(color: Colors.white)),
          
          if (_posts.isNotEmpty)
            PageView.builder(
              controller: _pageController,
              scrollDirection: Axis.vertical,
              itemCount: _posts.length,
              onPageChanged: _onPageChanged,
              itemBuilder: (context, index) {
                return FeedItem(
                  post: _posts[index],
                  controller: _videoControllers[index], 
                );
              },
            ),

          // Top Mode Switcher (Always visible or can be auto-hidden too if preferred)
          Positioned(
            top: 50, left: 0, right: 0,
            child: Center(
              child: GlassContainer(
                borderRadius: 30,
                padding: const EdgeInsets.all(4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ModeButton(title: "Latest", isActive: _mode == 'latest', onTap: () => _switchMode('latest')),
                    ModeButton(title: "Random", isActive: _mode == 'random', onTap: () => _switchMode('random')),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// -------------------- FEED ITEM (Handling Interaction) --------------------

class FeedItem extends StatefulWidget {
  final Post post;
  final VideoPlayerController? controller;

  const FeedItem({super.key, required this.post, this.controller});

  @override
  State<FeedItem> createState() => _FeedItemState();
}

class _FeedItemState extends State<FeedItem> {
  bool _showControls = true;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    _startHideTimer();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  void _startHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _showControls = false);
    });
  }

  void _onInteraction() {
    setState(() => _showControls = true);
    _startHideTimer();
  }

  @override
  Widget build(BuildContext context) {
    bool isVideo = widget.post.media.first.type == MediaType.video;

    return GestureDetector(
      onTap: _onInteraction,
      onPanDown: (_) => _onInteraction(), // Capture touches even when dragging
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Media Layer
          Container(
            color: Colors.black,
            child: isVideo
              ? VideoPostPlayer(
                  media: widget.post.media.first, 
                  controller: widget.controller,
                  onInteract: _onInteraction, // Pass up interaction
                )
              : PhotoAlbumViewer(mediaItems: widget.post.media),
          ),

          // Gradient Overlay
          Positioned(
            bottom: 0, left: 0, right: 0,
            child: IgnorePointer( // Let touches pass through gradient
              child: AnimatedOpacity(
                opacity: _showControls ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 300),
                child: Container(
                  height: 250,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Colors.black.withOpacity(0.9)],
                    ),
                  ),
                ),
              ),
            ),
          ),

          // Info & Controls Layer (Auto Hiding)
          Positioned(
            bottom: 24, left: 16, right: 16,
            child: AnimatedOpacity(
              opacity: _showControls ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 300),
              child: GlassContainer(
                borderRadius: 24,
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text("Post #${widget.post.postId}", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 16)),
                        Row(
                          children: [
                            const Icon(Icons.remove_red_eye, size: 14, color: Colors.white70),
                            const SizedBox(width: 4),
                            Text(NumberFormat.compact().format(widget.post.views), style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
                          ],
                        ),
                      ],
                    ),
                    if (isVideo && widget.controller != null && widget.controller!.value.isInitialized) ...[
                       const SizedBox(height: 12),
                       _SmoothVideoScrubber(
                         controller: widget.controller!,
                         onScrubStart: () {
                            _hideTimer?.cancel(); // Don't hide while dragging
                            setState(() => _showControls = true);
                         },
                         onScrubEnd: _startHideTimer,
                       ),
                    ]
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// -------------------- SMOOTH SCRUBBER --------------------

class _SmoothVideoScrubber extends StatefulWidget {
  final VideoPlayerController controller;
  final VoidCallback onScrubStart;
  final VoidCallback onScrubEnd;

  const _SmoothVideoScrubber({
    required this.controller,
    required this.onScrubStart,
    required this.onScrubEnd,
  });

  @override
  State<_SmoothVideoScrubber> createState() => _SmoothVideoScrubberState();
}

class _SmoothVideoScrubberState extends State<_SmoothVideoScrubber> {
  bool _isDragging = false;
  double _dragValue = 0.0;

  String _format(Duration d) {
    String two(int n) => n.toString().padLeft(2, "0");
    return "${d.inMinutes}:${two(d.inSeconds.remainder(60))}";
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: widget.controller,
      builder: (context, VideoPlayerValue value, child) {
        final totalDuration = value.duration.inMilliseconds.toDouble();
        // If dragging, use local state. If not, use controller state.
        final currentPos = _isDragging ? _dragValue : value.position.inMilliseconds.toDouble();
        final safePos = currentPos.clamp(0.0, totalDuration);

        return Row(
          children: [
            Text(_format(Duration(milliseconds: safePos.toInt())), 
              style: const TextStyle(color: Colors.white, fontSize: 11, fontFeatures: [FontFeature.tabularFigures()])),
            Expanded(
              child: Slider(
                value: safePos,
                min: 0,
                max: totalDuration > 0 ? totalDuration : 1.0,
                onChangeStart: (v) {
                  widget.onScrubStart();
                  setState(() {
                    _isDragging = true;
                    _dragValue = v;
                  });
                },
                onChanged: (v) {
                  // Live Update: Update UI immediately, seek controller smoothly
                  setState(() => _dragValue = v);
                  widget.controller.seekTo(Duration(milliseconds: v.toInt()));
                },
                onChangeEnd: (v) {
                  setState(() {
                    _isDragging = false;
                  });
                  widget.onScrubEnd();
                },
              ),
            ),
            Text(_format(value.duration), 
              style: const TextStyle(color: Colors.white70, fontSize: 11, fontFeatures: [FontFeature.tabularFigures()])),
          ],
        );
      },
    );
  }
}

// -------------------- VIDEO PLAYER --------------------

class VideoPostPlayer extends StatefulWidget {
  final MediaItem media;
  final VideoPlayerController? controller;
  final VoidCallback onInteract;

  const VideoPostPlayer({super.key, required this.media, this.controller, required this.onInteract});

  @override
  State<VideoPostPlayer> createState() => _VideoPostPlayerState();
}

class _VideoPostPlayerState extends State<VideoPostPlayer> {
  bool _showPlayButton = false;
  Timer? _iconHideTimer;

  void _togglePlay() {
    widget.onInteract(); // Reset hide timer on FeedItem
    if (widget.controller == null || !widget.controller!.value.isInitialized) return;

    setState(() {
      if (widget.controller!.value.isPlaying) {
        widget.controller!.pause();
        _showPlayButton = true; // Show Pause icon
      } else {
        widget.controller!.play();
        _showPlayButton = true; // Show Play icon briefly
        _startIconTimer();
      }
    });
  }

  void _startIconTimer() {
    _iconHideTimer?.cancel();
    _iconHideTimer = Timer(const Duration(milliseconds: 1000), () {
      if (mounted && widget.controller!.value.isPlaying) {
        setState(() => _showPlayButton = false);
      }
    });
  }

  @override
  void dispose() {
    _iconHideTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    bool isReady = widget.controller != null && widget.controller!.value.isInitialized;

    return GestureDetector(
      onTap: _togglePlay,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // 1. Thumbnail
          if (!isReady)
            CachedNetworkImage(
              imageUrl: widget.media.thumbnailUrl,
              fit: BoxFit.contain,
              width: double.infinity,
              height: double.infinity,
            ),
          
          // 2. Video
          if (isReady)
            SizedBox.expand(
              child: FittedBox(
                fit: BoxFit.contain,
                child: SizedBox(
                  width: widget.controller!.value.size.width,
                  height: widget.controller!.value.size.height,
                  child: VideoPlayer(widget.controller!),
                ),
              ),
            ),

          // 3. Play/Pause Glass Icon
          if (isReady && (_showPlayButton || !widget.controller!.value.isPlaying))
            GlassContainer(
              borderRadius: 50,
              padding: const EdgeInsets.all(20),
              child: Icon(
                widget.controller!.value.isPlaying ? Icons.pause : Icons.play_arrow,
                size: 32,
                color: Colors.white,
              ),
            ),
          
          if (!isReady)
            const CircularProgressIndicator(strokeWidth: 2, color: Colors.white54),
        ],
      ),
    );
  }
}

// -------------------- PHOTO VIEWER & HELPERS --------------------

class PhotoAlbumViewer extends StatefulWidget {
  final List<MediaItem> mediaItems;
  const PhotoAlbumViewer({super.key, required this.mediaItems});
  @override
  State<PhotoAlbumViewer> createState() => _PhotoAlbumViewerState();
}

class _PhotoAlbumViewerState extends State<PhotoAlbumViewer> {
  int _idx = 0;
  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        PageView.builder(
          itemCount: widget.mediaItems.length,
          onPageChanged: (i) => setState(() => _idx = i),
          itemBuilder: (context, index) => CachedNetworkImage(
            imageUrl: widget.mediaItems[index].url,
            fit: BoxFit.contain,
            placeholder: (c, u) => const Center(child: CircularProgressIndicator(color: Colors.white24)),
          ),
        ),
        if (widget.mediaItems.length > 1)
          Positioned(
            top: 20, right: 20,
            child: GlassContainer(
              borderRadius: 12,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Text("${_idx + 1}/${widget.mediaItems.length}", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          )
      ],
    );
  }
}

class GlassContainer extends StatelessWidget {
  final Widget child;
  final double borderRadius;
  final EdgeInsets padding;

  const GlassContainer({super.key, required this.child, this.borderRadius = 20, this.padding = EdgeInsets.zero});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.3),
            borderRadius: BorderRadius.circular(borderRadius),
            border: Border.all(color: Colors.white.withOpacity(0.1)),
          ),
          child: child,
        ),
      ),
    );
  }
}

class ModeButton extends StatelessWidget {
  final String title;
  final bool isActive;
  final VoidCallback onTap;
  const ModeButton({super.key, required this.title, required this.isActive, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        decoration: BoxDecoration(
          color: isActive ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(title, style: TextStyle(color: isActive ? Colors.black : Colors.white70, fontWeight: FontWeight.bold, fontSize: 13)),
      ),
    );
  }
}