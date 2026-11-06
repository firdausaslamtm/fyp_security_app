import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:video_player/video_player.dart';

import 'dashboard_screen.dart' show AppColors, CameraController;

class VideoScreen extends StatefulWidget {
  final CameraController cam;
  final bool isMalay;

  const VideoScreen({super.key, required this.cam, required this.isMalay});

  @override
  State<VideoScreen> createState() => _VideoScreenState();
}

class _VideoScreenState extends State<VideoScreen> {
  List<Map<String, dynamic>> _schedules = [];
  List<Map<String, dynamic>> _captures = [];
  Timer? _timer;

  CameraController get cam => widget.cam;
  String? get _base => cam.serverUrl;
  String _t(String en, String ms) => widget.isMalay ? ms : en;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  bool _needServer() {
    if (_base != null) return false;
    _snack(_t('Demo mode has no real camera. Open the app from the camera server.',
        'Mod demo tiada kamera sebenar. Buka app dari pelayan kamera.'));
    return true;
  }

  String _hhmm(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  String _when(num epochSeconds) {
    final d = DateTime.fromMillisecondsSinceEpoch((epochSeconds * 1000).round());
    final now = DateTime.now();
    final today = d.year == now.year && d.month == now.month && d.day == now.day;
    return today ? _hhmm(d) : '${d.day}/${d.month} ${_hhmm(d)}';
  }

  Future<void> _refresh() async {
    final base = _base;
    if (base == null || !cam.connected) return;
    try {
      final s = await http.get(Uri.parse('$base/schedules')).timeout(const Duration(seconds: 2));
      final c = await http.get(Uri.parse('$base/captures')).timeout(const Duration(seconds: 2));
      if (!mounted) return;
      setState(() {
        _schedules = (json.decode(s.body) as List).cast<Map<String, dynamic>>();
        _captures = (json.decode(c.body) as List).cast<Map<String, dynamic>>();
      });
    } catch (_) {}
  }

  // ---------- actions ----------
  Future<void> _run(Future<bool> action) async {
    final ok = await action;
    if (!ok) _snack(_t('Cannot reach the camera server.', 'Tidak dapat hubungi pelayan kamera.'));
  }

Future<void> _testSiren() async { if (_needServer()) return; try { await http.post(Uri.parse('$_base/api/siren/test')).timeout(const Duration(seconds: 3)); _snack(_t('Test sound is playing on the laptop for 2 seconds.', 'Bunyi ujian dimainkan pada komputer riba selama 2 saat.')); } catch (_) { _snack(_t('Cannot reach the camera server.', 'Tidak dapat hubungi pelayan kamera.')); } } Future<void> _photoNow() async {    if (_needServer()) return;
    final bytes = await cam.takePhoto();
    if (!mounted) return;
    if (bytes == null) {
      _snack(_t('Could not get a photo. Is the camera online?',
          'Tidak dapat gambar. Adakah kamera dalam talian?'));
      return;
    }
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipRRect(borderRadius: BorderRadius.circular(12), child: Image.memory(bytes)),
              TextButton(onPressed: () => Navigator.pop(ctx), child: Text(_t('Close', 'Tutup'))),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _schedule(String kind) async {
    if (_needServer()) return;
    final picked = await showTimePicker(context: context, initialTime: TimeOfDay.now());
    if (picked == null || !mounted) return;
    final hhmm =
        '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
    try {
      final r = await http
          .post(Uri.parse('$_base/schedule?kind=$kind&time=$hhmm'))
          .timeout(const Duration(seconds: 3));
      if (r.statusCode == 200) {
        _snack(kind == 'photo'
            ? _t('Photo scheduled for $hhmm', 'Gambar dijadualkan pada $hhmm')
            : _t('Video clip scheduled for $hhmm', 'Klip video dijadualkan pada $hhmm'));
        _refresh();
      } else {
        _snack(_t('Could not schedule.', 'Tidak dapat menjadualkan.'));
      }
    } catch (_) {
      _snack(_t('Cannot reach the camera server.', 'Tidak dapat hubungi pelayan kamera.'));
    }
  }

  Future<void> _deleteSchedule(String id) async {
    try {
      await http.post(Uri.parse('$_base/schedule/$id/delete')).timeout(const Duration(seconds: 3));
    } catch (_) {}
    _refresh();
  }

  // ---------- deleting saved photos and clips (owner only) ----------
  Future<bool> _confirm(String title, String message) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(_t('Cancel', 'Batal')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: AppColors.danger),
            child: Text(_t('Delete', 'Padam')),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _deleteCapture(String name, String kind) async {
    final yes = await _confirm(
      kind == 'clip' ? _t('Delete this video?', 'Padam video ini?') : _t('Delete this photo?', 'Padam gambar ini?'),
      _t('It will be permanently removed from the laptop. This cannot be undone.',
          'Ia akan dipadam kekal daripada komputer riba. Tindakan ini tidak boleh dibatalkan.'),
    );
    if (!yes) return;
    try {
      final r = await http
          .post(Uri.parse('$_base/api/captures/$name/delete'))
          .timeout(const Duration(seconds: 5));
      _snack(r.statusCode == 200 || r.statusCode == 404
          ? _t('Deleted', 'Dipadam')
          : _t('Could not delete. Only the owner can delete.',
              'Tidak dapat memadam. Hanya pemilik boleh memadam.'));
    } catch (_) {
      _snack(_t('Cannot reach the camera server.', 'Tidak dapat hubungi pelayan kamera.'));
    }
    _refresh();
  }

  Future<void> _deleteAllCaptures() async {
    final yes = await _confirm(
      _t('Delete ALL saved photos and videos?', 'Padam SEMUA gambar dan video disimpan?'),
      _t('Everything in Saved captures will be permanently removed from the laptop. This cannot be undone.',
          'Semua dalam Tangkapan disimpan akan dipadam kekal daripada komputer riba. Tindakan ini tidak boleh dibatalkan.'),
    );
    if (!yes) return;
    try {
      final r = await http
          .post(Uri.parse('$_base/api/captures/delete_all'))
          .timeout(const Duration(seconds: 10));
      _snack(r.statusCode == 200
          ? _t('All captures deleted', 'Semua tangkapan dipadam')
          : _t('Could not delete. Only the owner can delete.',
              'Tidak dapat memadam. Hanya pemilik boleh memadam.'));
    } catch (_) {
      _snack(_t('Cannot reach the camera server.', 'Tidak dapat hubungi pelayan kamera.'));
    }
    _refresh();
  }

  Future<bool> _waitForCapture(String name) async {
    for (var i = 0; i < 40; i++) {
      await Future.delayed(const Duration(seconds: 1));
      try {
        final c = await http.get(Uri.parse('$_base/captures')).timeout(const Duration(seconds: 2));
        final list = json.decode(c.body) as List;
        if (list.any((e) => e['name'] == name)) return true;
      } catch (_) {}
    }
    return false;
  }

  Future<void> _clipNow() async {
    if (_needServer()) return;
    String? name;
    try {
      final r = await http.post(Uri.parse('$_base/clip')).timeout(const Duration(seconds: 3));
      if (r.statusCode == 200) {
        name = (json.decode(r.body) as Map)['name'] as String?;
      } else if (r.statusCode == 409) {
        _snack(_t('Already recording. Please wait.', 'Sedang merakam. Sila tunggu.'));
        return;
      }
    } catch (_) {}
    if (name == null) {
      _snack(_t('Cannot reach the camera server.', 'Tidak dapat hubungi pelayan kamera.'));
      return;
    }
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        content: Row(
          children: [
            const CircularProgressIndicator(),
            const SizedBox(width: 16),
            Expanded(child: Text(_t('Recording 10 seconds...', 'Merakam 10 saat...'))),
          ],
        ),
      ),
    );
    final ready = await _waitForCapture(name);
    if (!mounted) return;
    Navigator.of(context).pop(); // close the recording dialog
    if (!ready) {
      _snack(_t('The clip did not finish. Check the server window.',
          'Klip tidak siap. Semak tetingkap pelayan.'));
      return;
    }
    _refresh();
    _openCapture(name, 'clip');
  }

  void _openCapture(String name, String kind) {
    final url = '$_base/captures/$name';
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (kind == 'clip')
                _ClipPlayer(url: url, isMalay: widget.isMalay)
              else
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.network(url),
                ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: Text(_t('Close', 'Tutup')),
                  ),
                  if (cam.canDelete)
                    TextButton(
                      onPressed: () {
                        Navigator.pop(ctx);
                        _deleteCapture(name, kind);
                      },
                      style: TextButton.styleFrom(foregroundColor: AppColors.danger),
                      child: Text(_t('Delete', 'Padam')),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _status() {
    String yn(bool v) => v ? _t('Yes', 'Ya') : _t('No', 'Tidak');
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_t('System status', 'Status sistem')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${_t('Mode', 'Mod')}: ${cam.demo ? 'Demo' : 'Live'}'),
            const SizedBox(height: 6),
            Text('${_t('Camera connected', 'Kamera terhubung')}: ${yn(cam.connected)}'),
            const SizedBox(height: 6),
            Text('${_t('Edge AI active', 'AI aktif')}: ${yn(cam.aiActive)}'),
            const SizedBox(height: 6),
            Text('${_t('Night vision', 'Penglihatan malam')}: ${yn(cam.nightVision)}'),
            const SizedBox(height: 6),
            Text('${_t('Siren', 'Siren')}: ${yn(cam.siren)}'),
            const SizedBox(height: 6),
            Text('${_t('Server', 'Pelayan')}: ${cam.serverUrl ?? '-'}'),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(_t('Close', 'Tutup'))),
        ],
      ),
    );
  }

  // ---------- screen ----------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_t('Video requests', 'Permintaan video')),
        centerTitle: true,
        backgroundColor: AppColors.bg,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: _t('Refresh', 'Muat semula'),
            onPressed: _refresh,
          ),
        ],
      ),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: cam,
          builder: (context, _) {
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _SectionHeader(text: _t('Capture', 'Tangkap')),
                _Tile(
                  icon: Icons.photo_camera_rounded,
                  title: _t('Take a photo now', 'Ambil gambar sekarang'),
                  subtitle: _t('Get the current camera picture', 'Dapatkan gambar kamera semasa'),
                  onTap: _photoNow,
                ),
                _Tile(
                  icon: Icons.schedule_rounded,
                  title: _t('Photo at a set time', 'Gambar pada masa tertentu'),
                  subtitle: _t('Pick a time, get a photo then', 'Pilih masa, dapat gambar waktu itu'),
                  onTap: () => _schedule('photo'),
                ),
                _Tile(
                  icon: Icons.videocam_rounded,
                  title: _t('10-second video clip now', 'Klip video 10 saat sekarang'),
                  subtitle: _t('Record a short clip right away', 'Rakam klip pendek terus'),
                  onTap: _clipNow,
                ),
                _Tile(
                  icon: Icons.more_time_rounded,
                  title: _t('Video clip at a set time', 'Klip video pada masa tertentu'),
                  subtitle: _t('Pick a time, get a clip then', 'Pilih masa, dapat klip waktu itu'),
                  onTap: () => _schedule('clip'),
                ),
                const SizedBox(height: 16),
                _SectionHeader(text: _t('Controls', 'Kawalan')),
                _Tile(
                  icon: Icons.campaign_rounded,
                  title: _t('Siren', 'Siren'),
                  subtitle: cam.siren ? _t('Armed: sounds only when a person is detected', 'Aktif: berbunyi hanya apabila manusia dikesan') : _t('Off: alerts still come, no sound', 'Mati: amaran masih dihantar, tiada bunyi'),                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [TextButton(onPressed: _testSiren, child: Text(_t('Test', 'Uji'))), Switch(value: cam.siren, onChanged: (_) => _run(cam.toggleSiren()))]),
                  onTap: () => _run(cam.toggleSiren()),
                ),
                _Tile(
                  icon: Icons.nightlight_round,
                  title: _t('Night mode', 'Mod malam'),
                  subtitle: cam.nightVision
                      ? _t('On (brighter grayscale picture)', 'Hidup (gambar kelabu lebih cerah)')
                      : _t('Off', 'Mati'),
                  trailing: Switch(value: cam.nightVision, onChanged: (_) => _run(cam.toggleNight())),
                  onTap: () => _run(cam.toggleNight()),
                ),
                _Tile(
                  icon: Icons.info_outline_rounded,
                  title: _t('System status', 'Status sistem'),
                  subtitle: _t('Camera, AI, night mode, siren', 'Kamera, AI, mod malam, siren'),
                  onTap: _status,
                ),
                if (_schedules.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _SectionHeader(text: _t('Scheduled', 'Dijadualkan')),
                  for (final s in _schedules)
                    _Tile(
                      icon: s['kind'] == 'photo' ? Icons.photo_camera_rounded : Icons.videocam_rounded,
                      title: s['kind'] == 'photo'
                          ? _t('Photo at ${s['time']}', 'Gambar pada ${s['time']}')
                          : _t('Video clip at ${s['time']}', 'Klip video pada ${s['time']}'),
                      subtitle: s['tomorrow'] == true ? _t('Tomorrow', 'Esok') : _t('Today', 'Hari ini'),
                      trailing: IconButton(
                        icon: const Icon(Icons.close_rounded),
                        onPressed: () => _deleteSchedule(s['id'] as String),
                      ),
                      onTap: () {},
                    ),
                ],
                if (_captures.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _SectionHeader(
                    text: _t('Saved captures', 'Tangkapan disimpan'),
                    action: cam.canDelete
                        ? TextButton.icon(
                            onPressed: _deleteAllCaptures,
                            icon: const Icon(Icons.delete_sweep_rounded, size: 18),
                            label: Text(_t('Delete all', 'Padam semua')),
                            style: TextButton.styleFrom(foregroundColor: AppColors.danger),
                          )
                        : null,
                  ),
                  for (final c in _captures.take(10))
                    _Tile(
                      icon: c['kind'] == 'clip' ? Icons.play_circle_rounded : Icons.image_rounded,
                      title: c['kind'] == 'clip'
                          ? _t('Video clip', 'Klip video')
                          : _t('Photo', 'Gambar'),
                      subtitle: _when(c['time'] as num),
                      trailing: cam.canDelete
                          ? IconButton(
                              icon: const Icon(Icons.delete_outline_rounded, color: AppColors.danger),
                              tooltip: _t('Delete', 'Padam'),
                              onPressed: () => _deleteCapture(c['name'] as String, c['kind'] as String),
                            )
                          : null,
                      onTap: () => _openCapture(c['name'] as String, c['kind'] as String),
                    ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
class _ClipPlayer extends StatefulWidget {
  final String url;
  final bool isMalay;
  const _ClipPlayer({required this.url, required this.isMalay});

  @override
  State<_ClipPlayer> createState() => _ClipPlayerState();
}

class _ClipPlayerState extends State<_ClipPlayer> {
  late final VideoPlayerController _c;
  bool _ready = false;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _c = VideoPlayerController.networkUrl(Uri.parse(widget.url));
    _c.initialize().then((_) {
      if (!mounted) return;
      setState(() => _ready = true);
      _c.setLooping(true);
      _c.play();
    }).catchError((_) {
      if (mounted) setState(() => _error = true);
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text(widget.isMalay
            ? 'Klip tidak boleh dimainkan di sini. Ia disimpan dalam folder captures di komputer riba.'
            : 'This clip cannot be played here. It is saved in the captures folder on the laptop.'),
      );
    }
    if (!_ready) {
      return const Padding(
        padding: EdgeInsets.all(32),
        child: CircularProgressIndicator(),
      );
    }
    return GestureDetector(
      onTap: () => setState(() => _c.value.isPlaying ? _c.pause() : _c.play()),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: AspectRatio(aspectRatio: _c.value.aspectRatio, child: VideoPlayer(_c)),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String text;
  final Widget? action;
  const _SectionHeader({required this.text, this.action});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(text, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          ),
          if (action != null) action!,
        ],
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final Widget? trailing;

  const _Tile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                CircleAvatar(
                  backgroundColor: AppColors.surfaceHigh,
                  child: Icon(icon, color: AppColors.accent),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 2),
                      Text(subtitle, style: const TextStyle(color: AppColors.dim, fontSize: 12)),
                    ],
                  ),
                ),
                trailing ?? const Icon(Icons.chevron_right_rounded, color: AppColors.dim),
              ],
            ),
          ),
        ),
      ),
    );
  }
}