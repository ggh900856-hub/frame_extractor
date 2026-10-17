import 'dart:async';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_video/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_video/return_code.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:gal/gal.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

const kBg = Color(0xFF0D0B1E);
const kSurface = Color(0xFF1D1A3A);
const kAccent = Color(0xFF8E7CFF);

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.initCommunicationPort();
  runApp(const FrameApp());
}

// ───────────────────────── App ─────────────────────────

class FrameApp extends StatelessWidget {
  const FrameApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'مستخرج الصور',
      locale: const Locale('ar'),
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: kBg,
        colorScheme: const ColorScheme.dark(primary: kAccent, surface: kSurface),
      ),
      builder: (context, child) {
        return Directionality(
          textDirection: TextDirection.rtl,
          child: child ?? const SizedBox.shrink(),
        );
      },
      home: const HomePage(),
    );
  }
}

// ───────────────────── Helpers / Models ─────────────────────

enum ImgFormat { jpg, png }

extension ImgFormatX on ImgFormat {
  String get ext => this == ImgFormat.png ? 'png' : 'jpg';
  // JPG بأعلى جودة ممكنة (q:v 1) — PNG بدون فقد
  String get args => this == ImgFormat.png ? '' : '-q:v 1 -pix_fmt yuvj420p';
}

bool isImage(String path) {
  final p = path.toLowerCase();
  return p.endsWith('.jpg') || p.endsWith('.jpeg') || p.endsWith('.png');
}

List<File> listImages(Directory dir) {
  if (!dir.existsSync()) return [];
  final list = dir.listSync().whereType<File>().where((f) => isImage(f.path)).toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  return list;
}

String formatSize(int bytes) {
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

String fmtTime(Duration d) {
  final m = d.inMinutes.toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  final t = (d.inMilliseconds.remainder(1000) ~/ 100).toString();
  return '$m:$s.$t';
}

String cleanFolderName(String path) {
  final raw = path.split('/').last;
  final i = raw.lastIndexOf('_');
  return i > 0 ? raw.substring(0, i) : raw;
}

class SessionInfo {
  final Directory dir;
  final String name;
  final int count;
  final File? cover;
  final DateTime modified;

  SessionInfo({
    required this.dir,
    required this.name,
    required this.count,
    required this.cover,
    required this.modified,
  });
}

Future<bool> saveImagesToGallery(BuildContext context, List<File> files) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    if (!await Gal.hasAccess(toAlbum: true)) {
      final granted = await Gal.requestAccess(toAlbum: true);
      if (!granted) {
        messenger.showSnackBar(const SnackBar(content: Text('لازم توافق على إذن الوصول للمعرض')));
        return false;
      }
    }
    for (final f in files) {
      await Gal.putImage(f.path, album: 'FrameExtractor');
    }
    messenger.showSnackBar(
      SnackBar(content: Text('تم حفظ ${files.length} صورة في المعرض (ألبوم FrameExtractor)')),
    );
    return true;
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('حدث خطأ أثناء الحفظ: $e')));
    return false;
  }
}

// ───────────────────────── Home ─────────────────────────

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _picker = ImagePicker();
  List<SessionInfo> _sessions = [];

  @override
  void initState() {
    super.initState();
    _initForegroundTask();
    _requestNotificationPermission();
    _loadSessions();
  }

  void _initForegroundTask() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'frame_extractor_channel',
        channelName: 'خدمة استخراج الصور',
        channelDescription: 'تضمن استمرار الاستخراج في الخلفية',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        allowWakeLock: true,
      ),
    );
  }

  Future<void> _requestNotificationPermission() async {
    final perm = await FlutterForegroundTask.checkNotificationPermission();
    if (perm != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
  }

  Future<void> _loadSessions() async {
    final dir = await getApplicationDocumentsDirectory();
    final root = Directory('${dir.path}/Frames');
    if (!await root.exists()) {
      if (mounted) setState(() => _sessions = []);
      return;
    }

    final infos = <SessionInfo>[];
    await for (final e in root.list()) {
      if (e is! Directory) continue;
      final images = listImages(e);
      infos.add(SessionInfo(
        dir: e,
        name: cleanFolderName(e.path),
        count: images.length,
        cover: images.isEmpty ? null : images.first,
        modified: e.statSync().modified,
      ));
    }
    infos.sort((a, b) => b.modified.compareTo(a.modified));

    if (!mounted) return;
    setState(() => _sessions = infos);
  }

  Future<void> _pickVideo() async {
    final XFile? video = await _picker.pickVideo(source: ImageSource.gallery);
    if (video == null) return;

    final appDir = await getApplicationDocumentsDirectory();
    final originalName = video.name.split('.').first;
    final dir = Directory('${appDir.path}/Frames/${originalName}_${DateTime.now().millisecondsSinceEpoch}');
    await dir.create(recursive: true);
    if (!mounted) return;

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ExtractorPage(videoPath: video.path, videoName: originalName, outDir: dir),
      ),
    );

    // لو المستخدم ماطلعش أي صورة نمسح المجلد الفاضي
    if (listImages(dir).isEmpty) {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    }
    _loadSessions();
  }

  Future<void> _deleteSession(SessionInfo s) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kSurface,
        title: const Text('حذف المجلد', style: TextStyle(fontSize: 16)),
        content: Text('هتتحذف كل صور "${s.name}" نهائياً. متأكد؟'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('حذف', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await s.dir.delete(recursive: true);
    } catch (_) {}
    _loadSessions();
  }

  void _openSession(SessionInfo s) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => GalleryPage(folder: s.dir, title: s.name)),
    ).then((_) => _loadSessions());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('مستخرج الصور من الفيديو'),
        centerTitle: true,
        backgroundColor: kBg,
        elevation: 0,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: _pickVideo,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 28),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  gradient: const LinearGradient(colors: [Color(0xFF6C5CE7), kAccent]),
                ),
                child: const Column(
                  children: [
                    Icon(Icons.video_library, size: 44, color: Colors.white),
                    SizedBox(height: 8),
                    Text(
                      'اختر فيديو لاستخراج الصور منه',
                      style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
            ),
            const Divider(height: 36, color: Colors.white12),
            const Text(
              'الصور المستخرجة:',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: kAccent),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: _sessions.isEmpty
                  ? const Center(
                      child: Text(
                        'لا توجد صور بعد، اختر فيديو وابدأ.',
                        style: TextStyle(color: Colors.grey, fontSize: 13),
                      ),
                    )
                  : ListView.builder(
                      itemCount: _sessions.length,
                      itemBuilder: (context, i) => _buildSessionCard(_sessions[i]),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSessionCard(SessionInfo s) {
    return Card(
      color: kSurface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      margin: const EdgeInsets.symmetric(vertical: 6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _openSession(s),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 76,
                  height: 76,
                  child: s.cover != null
                      ? Image.file(s.cover!, fit: BoxFit.cover, cacheWidth: 240)
                      : Container(
                          color: Colors.black26,
                          child: const Icon(Icons.image, color: Colors.white24, size: 32),
                        ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      s.name,
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text('${s.count} صورة', style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert, color: Colors.white54),
                color: kSurface,
                onSelected: (v) {
                  if (v == 'delete') _deleteSession(s);
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'delete', child: Text('حذف المجلد')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ───────────────────── Extractor ─────────────────────

class ExtractorPage extends StatefulWidget {
  final String videoPath;
  final String videoName;
  final Directory outDir;
  const ExtractorPage({
    super.key,
    required this.videoPath,
    required this.videoName,
    required this.outDir,
  });

  @override
  State<ExtractorPage> createState() => _ExtractorPageState();
}

class _ExtractorPageState extends State<ExtractorPage> {
  late VideoPlayerController _c;
  bool _ready = false;
  bool _failed = false;

  ImgFormat _format = ImgFormat.jpg;
  double _interval = 1;
  bool _busy = false;
  double _progress = 0;
  String _status = '';
  int _count = 0;

  static const _intervals = [0.5, 1.0, 2.0, 5.0, 10.0];

  @override
  void initState() {
    super.initState();
    _c = VideoPlayerController.file(File(widget.videoPath));
    _c.initialize().then((_) {
      if (!mounted) return;
      setState(() => _ready = true);
    }).catchError((_) {
      if (mounted) setState(() => _failed = true);
    });
    _c.addListener(() {
      if (mounted) setState(() {});
    });
    _refreshCount();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _refreshCount() {
    _count = listImages(widget.outDir).length;
  }

  String _intervalLabel(double v) => v == v.roundToDouble() ? '${v.toInt()}ث' : '$vث';

  Future<void> _nudge(Duration d) async {
    var t = _c.value.position + d;
    if (t < Duration.zero) t = Duration.zero;
    if (t > _c.value.duration) t = _c.value.duration;
    await _c.seekTo(t);
  }

  Future<void> _togglePlay() async {
    if (_c.value.isPlaying) {
      await _c.pause();
    } else {
      await _c.play();
    }
  }

  void _openGallery() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => GalleryPage(folder: widget.outDir, title: widget.videoName)),
    ).then((_) {
      if (mounted) setState(_refreshCount);
    });
  }

  // ───── التقاط لحظة واحدة ─────
  Future<void> _captureCurrent() async {
    if (_busy) return;
    await _c.pause();

    var pos = _c.value.position;
    final end = _c.value.duration - const Duration(milliseconds: 80);
    if (pos > end && end > Duration.zero) pos = end;

    setState(() {
      _busy = true;
      _progress = 0;
      _status = 'جاري التقاط الصورة…';
    });

    final ms = pos.inMilliseconds;
    final out = '${widget.outDir.path}/shot_${ms.toString().padLeft(8, '0')}.${_format.ext}';
    final secs = (ms / 1000).toStringAsFixed(3);

    try {
      final session = await FFmpegKit.execute(
        '-y -ss $secs -i "${widget.videoPath}" -frames:v 1 ${_format.args} "$out"',
      );
      final code = await session.getReturnCode();
      if (!mounted) return;
      final ok = ReturnCode.isSuccess(code) && await File(out).exists();
      setState(() {
        _busy = false;
        _refreshCount();
        _status = ok ? 'تم التقاط الصورة عند ${fmtTime(pos)}' : 'فشل التقاط الصورة';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = 'حدث خطأ: $e';
      });
    }
  }

  // ───── استخراج تلقائي (كل N ثانية / إطارات مفتاحية) ─────
  Future<void> _extractBatch({
    required String prefix,
    required String inputOpts,
    required String filterOpts,
  }) async {
    if (_busy) return;
    await _c.pause();

    final totalMs = _c.value.duration.inMilliseconds;
    setState(() {
      _busy = true;
      _progress = 0;
      _status = 'جاري الاستخراج…';
    });

    await FlutterForegroundTask.startService(
      notificationTitle: 'جاري استخراج الصور',
      notificationText: 'المعالجة مستمرة في الخلفية...',
    );

    try {
      final stamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final pattern = '${widget.outDir.path}/$prefix${stamp}_%04d.${_format.ext}';
      final cmd = '-y $inputOpts -i "${widget.videoPath}" $filterOpts -vsync vfr ${_format.args} "$pattern"';

      await FFmpegKit.executeAsync(
        cmd,
        (session) async {
          final code = await session.getReturnCode();
          await FlutterForegroundTask.stopService();
          if (!mounted) return;

          final ok = ReturnCode.isSuccess(code);
          setState(() {
            _busy = false;
            _refreshCount();
            _status = ok ? 'تم استخراج الصور!' : 'فشلت عملية الاستخراج';
          });
          if (ok) _openGallery();
        },
        null,
        (stats) {
          if (totalMs <= 0 || !mounted) return;
          final p = (stats.getTime() / totalMs).clamp(0.0, 1.0).toDouble();
          setState(() {
            _progress = p;
            _status = 'جاري الاستخراج… ${(p * 100).toStringAsFixed(0)}%';
          });
        },
      );
    } catch (e) {
      await FlutterForegroundTask.stopService();
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = 'حدث خطأ: $e';
      });
    }
  }

  void _extractEveryN() {
    final fps = (1 / _interval).toStringAsFixed(6);
    _extractBatch(prefix: 'auto', inputOpts: '', filterOpts: '-vf fps=$fps');
  }

  void _extractKeyframes() {
    _extractBatch(prefix: 'key', inputOpts: '-skip_frame nokey', filterOpts: '');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.videoName, maxLines: 1, overflow: TextOverflow.ellipsis),
        backgroundColor: kBg,
      ),
      body: _failed
          ? const Center(child: Text('تعذر فتح الفيديو', style: TextStyle(color: Colors.grey)))
          : !_ready
              ? const Center(child: CircularProgressIndicator(color: kAccent))
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    _buildPlayer(),
                    const SizedBox(height: 6),
                    _buildSeekBar(),
                    _buildNudgeButtons(),
                    const SizedBox(height: 14),
                    _buildFormatPicker(),
                    const SizedBox(height: 14),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: kAccent,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                      onPressed: _busy ? null : _captureCurrent,
                      icon: const Icon(Icons.camera_alt, color: Colors.white),
                      label: const Text(
                        'التقط هذه اللحظة',
                        style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
                      ),
                    ),
                    const Divider(height: 36, color: Colors.white12),
                    const Text(
                      'استخراج تلقائي',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: kAccent),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      children: _intervals
                          .map((v) => ChoiceChip(
                                label: Text(_intervalLabel(v)),
                                selected: _interval == v,
                                selectedColor: kAccent,
                                onSelected: _busy ? null : (_) => setState(() => _interval = v),
                              ))
                          .toList(),
                    ),
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        side: const BorderSide(color: kAccent),
                      ),
                      onPressed: _busy ? null : _extractEveryN,
                      icon: const Icon(Icons.burst_mode, color: kAccent),
                      label: Text('صورة كل ${_intervalLabel(_interval)}'),
                    ),
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        side: const BorderSide(color: kAccent),
                      ),
                      onPressed: _busy ? null : _extractKeyframes,
                      icon: const Icon(Icons.auto_awesome, color: kAccent),
                      label: const Text('الإطارات المفتاحية (أنضف اللقطات)'),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'الإطارات المفتاحية هي الإطارات الكاملة في الفيديو، فبتطلع أوضح وأعلى جودة. '
                      'ملحوظة: دقة الصورة بتساوي دقة الفيديو الأصلي.',
                      style: TextStyle(color: Colors.white38, fontSize: 11),
                    ),
                    const SizedBox(height: 16),
                    if (_busy)
                      LinearProgressIndicator(
                        value: _progress > 0 ? _progress : null,
                        color: kAccent,
                        backgroundColor: Colors.white12,
                        minHeight: 6,
                      ),
                    if (_status.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Center(
                          child: Text(_status, style: const TextStyle(color: Colors.white54, fontSize: 13)),
                        ),
                      ),
                    const SizedBox(height: 8),
                    TextButton.icon(
                      onPressed: _count == 0 ? null : _openGallery,
                      icon: const Icon(Icons.photo_library, color: kAccent),
                      label: Text('عرض الصور المستخرجة ($_count)', style: const TextStyle(color: kAccent)),
                    ),
                  ],
                ),
    );
  }

  Widget _buildPlayer() {
    final ar = _c.value.aspectRatio == 0 ? 16 / 9 : _c.value.aspectRatio;
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: ColoredBox(
        color: Colors.black,
        child: AspectRatio(
          aspectRatio: ar,
          child: Stack(
            alignment: Alignment.center,
            children: [
              VideoPlayer(_c),
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _togglePlay,
                child: Center(
                  child: _c.value.isPlaying
                      ? const SizedBox.shrink()
                      : const Icon(Icons.play_circle_fill, size: 60, color: Colors.white70),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSeekBar() {
    final total = _c.value.duration.inMilliseconds.toDouble();
    final pos = _c.value.position.inMilliseconds.toDouble().clamp(0.0, total <= 0 ? 1.0 : total).toDouble();
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Row(
        children: [
          Text(fmtTime(_c.value.position), style: const TextStyle(fontSize: 12)),
          Expanded(
            child: Slider(
              min: 0,
              max: total <= 0 ? 1 : total,
              value: pos,
              activeColor: kAccent,
              inactiveColor: Colors.white24,
              onChanged: (v) => _c.seekTo(Duration(milliseconds: v.toInt())),
            ),
          ),
          Text(fmtTime(_c.value.duration), style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
  }

  Widget _buildNudgeButtons() {
    Widget btn(String label, Duration d) {
      return Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 10),
              side: const BorderSide(color: Colors.white24),
            ),
            onPressed: () => _nudge(d),
            child: Text(label, style: const TextStyle(fontSize: 12, color: Colors.white)),
          ),
        ),
      );
    }

    return Directionality(
      textDirection: TextDirection.ltr,
      child: Row(
        children: [
          btn('-1ث', const Duration(seconds: -1)),
          btn('-0.1ث', const Duration(milliseconds: -100)),
          btn('+0.1ث', const Duration(milliseconds: 100)),
          btn('+1ث', const Duration(seconds: 1)),
        ],
      ),
    );
  }

  Widget _buildFormatPicker() {
    return Row(
      children: [
        const Text('الصيغة: ', style: TextStyle(color: Colors.white70)),
        const SizedBox(width: 8),
        ChoiceChip(
          label: const Text('JPG (جودة قصوى)'),
          selected: _format == ImgFormat.jpg,
          selectedColor: kAccent,
          onSelected: _busy ? null : (_) => setState(() => _format = ImgFormat.jpg),
        ),
        const SizedBox(width: 8),
        ChoiceChip(
          label: const Text('PNG (بدون فقد)'),
          selected: _format == ImgFormat.png,
          selectedColor: kAccent,
          onSelected: _busy ? null : (_) => setState(() => _format = ImgFormat.png),
        ),
      ],
    );
  }
}

// ───────────────────── Gallery ─────────────────────

class GalleryPage extends StatefulWidget {
  final Directory folder;
  final String title;
  const GalleryPage({super.key, required this.folder, required this.title});

  @override
  State<GalleryPage> createState() => _GalleryPageState();
}

class _GalleryPageState extends State<GalleryPage> {
  List<File> _files = [];
  final Set<String> _selected = {};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _files = listImages(widget.folder);
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  void _toggle(String path) {
    setState(() {
      if (!_selected.add(path)) _selected.remove(path);
    });
  }

  void _toggleAll() {
    setState(() {
      if (_selected.length == _files.length) {
        _selected.clear();
      } else {
        _selected.addAll(_files.map((f) => f.path));
      }
    });
  }

  // لو مفيش تحديد: الحفظ والمشاركة بيشتغلوا على كل الصور
  List<File> get _targets =>
      _selected.isEmpty ? _files : _files.where((f) => _selected.contains(f.path)).toList();

  Future<void> _save() async {
    if (_files.isEmpty) return;
    setState(() => _busy = true);
    await saveImagesToGallery(context, _targets);
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _share() async {
    if (_files.isEmpty) return;
    await Share.shareXFiles(_targets.map((f) => XFile(f.path)).toList());
  }

  Future<void> _deleteSelected() async {
    if (_selected.isEmpty) {
      _snack('حدد صورة واحدة على الأقل للحذف (اضغط مطولاً على الصورة)');
      return;
    }
    final count = _selected.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kSurface,
        title: const Text('حذف الصور', style: TextStyle(fontSize: 16)),
        content: Text('هتتحذف $count صورة نهائياً. متأكد؟'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('إلغاء', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('حذف', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (ok != true) return;

    for (final f in _files.where((f) => _selected.contains(f.path))) {
      try {
        await f.delete();
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _files = listImages(widget.folder);
      _selected.clear();
    });
  }

  void _openViewer(int index) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ImageViewerPage(files: _files, index: index)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final selecting = _selected.isNotEmpty;
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        title: Text(
          selecting ? '${_selected.length} محددة' : '${widget.title} (${_files.length})',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            tooltip: 'تحديد الكل',
            icon: const Icon(Icons.select_all),
            onPressed: _files.isEmpty ? null : _toggleAll,
          ),
          IconButton(
            tooltip: 'حذف المحدد',
            icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
            onPressed: _files.isEmpty ? null : _deleteSelected,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _files.isEmpty
                ? const Center(child: Text('لا توجد صور', style: TextStyle(color: Colors.grey)))
                : GridView.builder(
                    padding: const EdgeInsets.all(6),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      mainAxisSpacing: 4,
                      crossAxisSpacing: 4,
                    ),
                    itemCount: _files.length,
                    itemBuilder: (context, i) => _buildTile(i),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Text(
              selecting ? 'الحفظ والمشاركة للصور المحددة' : 'اضغط مطولاً للتحديد • الحفظ والمشاركة لكل الصور',
              style: const TextStyle(color: Colors.white38, fontSize: 11),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.amber,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed: _busy ? null : _save,
                    icon: _busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                          )
                        : const Icon(Icons.save_alt, color: Colors.black),
                    label: const Text(
                      'حفظ بالمعرض',
                      style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: kAccent,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed: _busy ? null : _share,
                    icon: const Icon(Icons.share, color: Colors.white),
                    label: const Text(
                      'مشاركة',
                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTile(int i) {
    final f = _files[i];
    final selected = _selected.contains(f.path);
    return GestureDetector(
      onTap: () => _selected.isNotEmpty ? _toggle(f.path) : _openViewer(i),
      onLongPress: () => _toggle(f.path),
      child: Stack(
        fit: StackFit.expand,
        children: [
          Image.file(f, fit: BoxFit.cover, cacheWidth: 360, gaplessPlayback: true),
          if (selected) Container(color: kAccent.withOpacity(0.35)),
          if (selected)
            const Positioned(
              top: 4,
              right: 4,
              child: Icon(Icons.check_circle, color: Colors.white, size: 24),
            ),
        ],
      ),
    );
  }
}

// ───────────────────── Image viewer ─────────────────────

class ImageViewerPage extends StatefulWidget {
  final List<File> files;
  final int index;
  const ImageViewerPage({super.key, required this.files, required this.index});

  @override
  State<ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends State<ImageViewerPage> {
  late final PageController _pc;
  late int _index;

  @override
  void initState() {
    super.initState();
    _index = widget.index;
    _pc = PageController(initialPage: widget.index);
  }

  @override
  void dispose() {
    _pc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final file = widget.files[_index];
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text(
          '${_index + 1} / ${widget.files.length}',
          style: const TextStyle(fontSize: 14),
        ),
        actions: [
          IconButton(
            tooltip: 'حفظ بالمعرض',
            icon: const Icon(Icons.save_alt),
            onPressed: () => saveImagesToGallery(context, [file]),
          ),
          IconButton(
            tooltip: 'مشاركة',
            icon: const Icon(Icons.share),
            onPressed: () => Share.shareXFiles([XFile(file.path)]),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: PageView.builder(
              controller: _pc,
              itemCount: widget.files.length,
              onPageChanged: (i) => setState(() => _index = i),
              itemBuilder: (context, i) {
                return InteractiveViewer(
                  minScale: 1,
                  maxScale: 8,
                  child: Center(child: Image.file(widget.files[i])),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: ImageInfoText(key: ValueKey(file.path), file: file),
          ),
        ],
      ),
    );
  }
}

class ImageInfoText extends StatefulWidget {
  final File file;
  const ImageInfoText({super.key, required this.file});

  @override
  State<ImageInfoText> createState() => _ImageInfoTextState();
}

class _ImageInfoTextState extends State<ImageInfoText> {
  late final Future<String> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<String> _load() async {
    final bytes = await widget.file.readAsBytes();
    final img = await decodeImageFromList(bytes);
    final s = '${img.width}×${img.height}   •   ${formatSize(bytes.length)}';
    img.dispose();
    return s;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: _future,
      builder: (context, snap) {
        return Directionality(
          textDirection: TextDirection.ltr,
          child: Text(
            snap.data ?? '…',
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
        );
      },
    );
  }
}