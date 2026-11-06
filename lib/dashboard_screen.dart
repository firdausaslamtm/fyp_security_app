import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'api.dart';

// ---------------------------------------------------------------------------
// Colors
// ---------------------------------------------------------------------------
class AppColors {
  static const bg = Color(0xFF12141A);
  static const surface = Color(0xFF1B1E27);
  static const surfaceHigh = Color(0xFF262A35);
  static const accent = Color(0xFFE94B8A);
  static const ok = Color(0xFF4CD6A0);
  static const warn = Color(0xFFFFB454);
  static const danger = Color(0xFFFF5C5C);
  static const dim = Color(0xFF9CA3B0);
}

String _two(int n) => n.toString().padLeft(2, '0');

String _dateTime(DateTime d) {
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  return '${days[d.weekday - 1]} ${_two(d.day)}/${_two(d.month)}/${d.year} '
      '${_two(d.hour)}:${_two(d.minute)}:${_two(d.second)}';
}

// ---------------------------------------------------------------------------
// Models
// ---------------------------------------------------------------------------
class Detection {
  final Rect box; // normalized 0..1. Rect.zero = no box supplied
  final double confidence;
  const Detection(this.box, this.confidence);
}

class SecurityAlert {
  final DateTime time;
  final double confidence;
  final String? image; // evidence photo file name on the server (null in demo)
  final bool snoozed; // photo was saved while alerts were snoozed
  const SecurityAlert(this.time, this.confidence, {this.image, this.snoozed = false});
}

// ---------------------------------------------------------------------------
// CameraController: one shared brain for all tabs.
// ---------------------------------------------------------------------------
class CameraController extends ChangeNotifier {
  String? serverUrl; // null = demo mode
  bool connected = false;
  bool aiActive = false;
  bool nightVision = false;
  bool siren = false;
  bool isOwner = false; // only the owner can snooze and delete
  bool canDelete = false; // same as isOwner
  Detection? detection;
  final List<SecurityAlert> alerts = [];
  int unread = 0;

  // snooze
  int snoozeLeft = 0; // seconds left. 0 = not snoozed
  String snoozeBy = '';
  int? snoozeSummary; // set when a snooze ends: how many people were seen
  bool get snoozed => snoozeLeft > 0;

  // pop-up for a new alert
  SecurityAlert? popupAlert;
  int popupSeq = 0;

  Timer? _timer;
  int _tick = 0;
  bool _busy = false;
  bool _firstStatusDone = false;
  bool _roleLoaded = false;
  int _prevSnooze = 0;
  String _lastEvent = '';

  bool get demo => serverUrl == null;

  void setServer(String? url) {
    serverUrl = url;
    connected = false;
    aiActive = false;
    detection = null;
    _firstStatusDone = false;
    _roleLoaded = false;
    _lastEvent = '';
    _prevSnooze = 0;
    snoozeLeft = 0;
    snoozeBy = '';
    snoozeSummary = null;
    popupAlert = null;
    isOwner = url == null;
    canDelete = url == null;
    alerts.clear();
    unread = 0;
    _timer?.cancel();
    _timer = Timer.periodic(
      demo ? const Duration(milliseconds: 200) : const Duration(milliseconds: 700),
      (_) => demo ? _demoTick() : _poll(),
    );
    notifyListeners();
  }

  void _demoTick() {
    _tick++;
    connected = true;
    aiActive = true;
    final phase = _tick % 100;
    Detection? d;
    if (phase >= 30 && phase < 60) {
      final t = (phase - 30) / 30;
      d = Detection(
        Rect.fromLTWH(0.08 + 0.55 * t, 0.22, 0.22, 0.62),
        0.85 + 0.08 * math.sin(phase / 3),
      );
    }
    if (d != null && detection == null) {
      alerts.insert(0, SecurityAlert(DateTime.now(), d.confidence));
      if (alerts.length > 50) alerts.removeLast();
      unread++;
    }
    detection = d;
    notifyListeners();
  }

  Future<void> _poll() async {
    if (_busy) return;
    _busy = true;
    final url = serverUrl;
    try {
      final res = await http
          .get(Uri.parse('$url/status'))
          .timeout(const Duration(seconds: 2));
      if (res.statusCode != 200) throw Exception('bad status');
      if (url != serverUrl) return; // address changed while waiting

      final data = json.decode(res.body) as Map<String, dynamic>;
      Detection? d;
      if (data['human_detected'] == true) {
        final b = (data['box'] as List?)?.map((e) => (e as num).toDouble()).toList();
        d = Detection(
          (b != null && b.length == 4) ? Rect.fromLTWH(b[0], b[1], b[2], b[3]) : Rect.zero,
          (data['confidence'] as num?)?.toDouble() ?? 0,
        );
      }
      detection = d;
      connected = data['camera_ok'] != false;
      aiActive = data['ai_active'] != false;
      nightVision = data['night_vision'] == true;
      siren = data['siren'] == true;

      // snooze state
      final left = (data['snooze_left'] as num?)?.toInt() ?? 0;
      if (_prevSnooze > 0 && left == 0) {
        snoozeSummary = (data['last_snooze_count'] as num?)?.toInt() ?? 0;
      }
      _prevSnooze = left;
      snoozeLeft = left;
      snoozeBy = (data['snooze_by'] as String?) ?? '';

      if (!_roleLoaded) {
        _roleLoaded = true;
        _loadRole();
      }

      // Alerts come from the evidence photos saved on the server.
      final le = (data['last_event'] as String?) ?? '';
      if (!_firstStatusDone) {
        _firstStatusDone = true;
        _lastEvent = le;
        _syncEvents(initial: true);
      } else if (le != _lastEvent) {
        _lastEvent = le;
        _syncEvents();
      }
      notifyListeners();
    } catch (_) {
      if (url != serverUrl) return;
      connected = false;
      aiActive = false;
      detection = null;
      _firstStatusDone = false;
      _roleLoaded = false;
      notifyListeners();
    } finally {
      _busy = false;
    }
  }

  // Finds out if this account is the owner (owners can snooze and delete).
  Future<void> _loadRole() async {
    final url = serverUrl;
    if (url == null) return;
    try {
      final r = await http
          .get(Uri.parse('$url/api/auth/me'))
          .timeout(const Duration(seconds: 4));
      if (r.statusCode == 200 && url == serverUrl) {
        final u = (json.decode(r.body) as Map)['user'] as Map;
        isOwner = u['role'] == 'owner';
        canDelete = isOwner;
        notifyListeners();
      }
    } catch (_) {
      _roleLoaded = false;
    }
  }

  Future<void> _syncEvents({bool initial = false}) async {
    final url = serverUrl;
    if (url == null) return;
    try {
      final r = await http.get(Uri.parse('$url/events')).timeout(const Duration(seconds: 3));
      if (r.statusCode != 200 || url != serverUrl) return;
      final list = (json.decode(r.body) as List).cast<Map<String, dynamic>>();
      final known = alerts.map((a) => a.image).toSet();
      final fresh = <SecurityAlert>[];
      for (final e in list) {
        final t = (e['time'] as num).toDouble();
        fresh.add(SecurityAlert(
          DateTime.fromMillisecondsSinceEpoch((t * 1000).round()),
          (e['confidence'] as num).toDouble(),
          image: e['name'] as String,
          snoozed: e['snoozed'] == true,
        ));
      }
      final newOnes = fresh.where((a) => !known.contains(a.image)).toList();
      // Photos saved while snoozed are silent: no badge and no pop-up.
      final loud = newOnes.where((a) => !a.snoozed).toList();
      alerts
        ..clear()
        ..addAll(fresh);
      if (!initial && loud.isNotEmpty) {
        unread += loud.length;
        popupAlert = loud.first; // newest first
        popupSeq++;
      }
      notifyListeners();
    } catch (_) {}
  }

  void markRead() {
    if (unread != 0) {
      unread = 0;
      notifyListeners();
    }
  }

  void dismissSnoozeSummary() {
    snoozeSummary = null;
    notifyListeners();
  }

  // ----- snooze (owner only, needs the password) -----
  // Returns an error message, or null when it worked.
  Future<String?> startSnooze(int minutes, String password) async {
    if (demo) return 'Snooze needs the camera server.';
    try {
      final r = await http
          .post(
            Uri.parse('$serverUrl/api/snooze'),
            headers: {'Content-Type': 'application/json'},
            body: json.encode({'minutes': minutes, 'password': password}),
          )
          .timeout(const Duration(seconds: 8));
      if (r.statusCode == 200) {
        snoozeLeft = minutes * 60;
        _prevSnooze = snoozeLeft;
        snoozeSummary = null;
        notifyListeners();
        return null;
      }
      final d = json.decode(r.body) as Map<String, dynamic>;
      return (d['error'] as String?) ?? 'Could not snooze.';
    } catch (_) {
      return 'Cannot reach the camera server.';
    }
  }

  Future<bool> resumeAlerts() async {
    if (demo) return false;
    try {
      final r = await http
          .post(Uri.parse('$serverUrl/api/snooze/resume'))
          .timeout(const Duration(seconds: 6));
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  // Deletes one alert photo from the laptop. Returns false if it failed.
  Future<bool> deleteAlert(SecurityAlert a) async {
    if (a.image != null && !demo) {
      try {
        final r = await http
            .post(Uri.parse('$serverUrl/api/evidence/${a.image}/delete'))
            .timeout(const Duration(seconds: 5));
        if (r.statusCode != 200 && r.statusCode != 404) return false;
      } catch (_) {
        return false;
      }
    }
    alerts.removeWhere((x) => x.image == a.image && x.time == a.time);
    if (unread > alerts.length) unread = alerts.length;
    notifyListeners();
    return true;
  }

  Future<bool> deleteAllAlerts() async {
    if (!demo) {
      try {
        final r = await http
            .post(Uri.parse('$serverUrl/api/evidence/delete_all'))
            .timeout(const Duration(seconds: 10));
        if (r.statusCode != 200) return false;
      } catch (_) {
        return false;
      }
    }
    alerts.clear();
    unread = 0;
    notifyListeners();
    return true;
  }

  Future<bool> _post(String path) async {
    if (demo) return true;
    try {
      await http.post(Uri.parse('$serverUrl$path')).timeout(const Duration(seconds: 2));
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> toggleSiren() {
    siren = !siren;
    notifyListeners();
    return _post('/siren');
  }

  Future<bool> toggleNight() {
    nightVision = !nightVision;
    notifyListeners();
    return _post('/night_mode');
  }

  /// Full-size photo with the date and time on it. Null if it fails (or demo).
  Future<Uint8List?> takePhoto() async {
    if (demo) return null;
    try {
      final r = await http
          .get(Uri.parse('$serverUrl/photo'))
          .timeout(const Duration(seconds: 4));
      if (r.statusCode == 200) return r.bodyBytes;
    } catch (_) {}
    return null;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

// ---------------------------------------------------------------------------
// Snooze dialog: choose minutes, confirm with the password
// ---------------------------------------------------------------------------
Future<void> showSnoozeDialog(BuildContext context, CameraController cam, bool isMalay) async {
  String t(String en, String ms) => isMalay ? ms : en;
  final messenger = ScaffoldMessenger.of(context);
  final passCtrl = TextEditingController();
  int minutes = 15;
  bool hide = true;
  bool busy = false;
  String? error;

  final done = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setS) => AlertDialog(
        title: Text(t('Snooze alerts', 'Tangguh amaran')),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                t('The camera keeps recording and saving photos. You just will not get alert pop-ups.',
                    'Kamera terus merakam dan menyimpan gambar. Anda cuma tidak akan dapat pop-up amaran.'),
                style: const TextStyle(color: AppColors.dim, fontSize: 12),
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                children: [
                  for (final m in [5, 15, 30, 60])
                    ChoiceChip(
                      label: Text('$m min'),
                      selected: minutes == m,
                      onSelected: busy ? null : (_) => setS(() => minutes = m),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              TextField(
                controller: passCtrl,
                obscureText: hide,
                decoration: InputDecoration(
                  labelText: t('Enter your password to confirm', 'Masukkan kata laluan untuk sahkan'),
                  suffixIcon: IconButton(
                    icon: Icon(hide ? Icons.visibility_rounded : Icons.visibility_off_rounded),
                    onPressed: () => setS(() => hide = !hide),
                  ),
                ),
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(error!,
                      style: const TextStyle(color: AppColors.danger, fontSize: 13)),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: busy ? null : () => Navigator.pop(ctx, false),
            child: Text(t('Cancel', 'Batal')),
          ),
          FilledButton(
            onPressed: busy
                ? null
                : () async {
                    if (passCtrl.text.isEmpty) {
                      setS(() => error = t('Please enter your password.', 'Sila masukkan kata laluan anda.'));
                      return;
                    }
                    setS(() {
                      busy = true;
                      error = null;
                    });
                    final e = await cam.startSnooze(minutes, passCtrl.text);
                    if (e == null) {
                      if (ctx.mounted) Navigator.pop(ctx, true);
                    } else {
                      setS(() {
                        busy = false;
                        error = e;
                      });
                    }
                  },
            child: Text(t('Snooze', 'Tangguh')),
          ),
        ],
      ),
    ),
  );

  if (done == true) {
    messenger.showSnackBar(SnackBar(
      content: Text(t('Alerts snoozed for $minutes minutes', 'Amaran ditangguhkan selama $minutes minit')),
    ));
  }
}

// ---------------------------------------------------------------------------
// Pop-up banner for a new alert (shows on top of every screen)
// ---------------------------------------------------------------------------
class PopupController {
  OverlayEntry? _entry;

  void attach(BuildContext context, CameraController cam, bool Function() isMalay) {
    detach();
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    _entry = OverlayEntry(
      builder: (_) => Positioned(
        top: 0,
        left: 0,
        right: 0,
        child: AlertPopup(cam: cam, isMalay: isMalay),
      ),
    );
    overlay.insert(_entry!);
  }

  void detach() {
    final e = _entry;
    _entry = null;
    if (e != null) {
      e.remove();
      e.dispose();
    }
  }
}

class AlertPopup extends StatefulWidget {
  final CameraController cam;
  final bool Function() isMalay;
  const AlertPopup({super.key, required this.cam, required this.isMalay});

  @override
  State<AlertPopup> createState() => _AlertPopupState();
}

class _AlertPopupState extends State<AlertPopup> {
  int _seenSeq = 0;
  Timer? _hide;
  SecurityAlert? _alert;

  @override
  void initState() {
    super.initState();
    _seenSeq = widget.cam.popupSeq;
    widget.cam.addListener(_onCam);
  }

  @override
  void dispose() {
    _hide?.cancel();
    widget.cam.removeListener(_onCam);
    super.dispose();
  }

  void _onCam() {
    final cam = widget.cam;
    if (cam.popupSeq != _seenSeq && cam.popupAlert != null) {
      _seenSeq = cam.popupSeq;
      _hide?.cancel();
      setState(() => _alert = cam.popupAlert);
      _hide = Timer(const Duration(seconds: 9), () {
        if (mounted) setState(() => _alert = null);
      });
    }
  }

  void _close() {
    _hide?.cancel();
    setState(() => _alert = null);
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.isMalay();
    String t(String en, String ms) => m ? ms : en;
    final a = _alert;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          child: a == null
              ? const SizedBox.shrink()
              : Material(
                  key: ValueKey(a.time),
                  elevation: 8,
                  color: AppColors.surfaceHigh,
                  borderRadius: BorderRadius.circular(16),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            const CircleAvatar(
                              radius: 18,
                              backgroundColor: AppColors.danger,
                              child: Icon(Icons.person_rounded, color: Colors.white, size: 20),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(t('Person detected', 'Manusia dikesan'),
                                      style: const TextStyle(fontWeight: FontWeight.w700)),
                                  Text(
                                    '${_dateTime(a.time)}  ·  ${(a.confidence * 100).round()}%',
                                    style: const TextStyle(color: AppColors.dim, fontSize: 12),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.close_rounded, size: 20),
                              onPressed: _close,
                            ),
                          ],
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            if (widget.cam.isOwner)
                              TextButton(
                                onPressed: () {
                                  _close();
                                  showSnoozeDialog(context, widget.cam, m);
                                },
                                child: Text(t('Snooze', 'Tangguh')),
                              ),
                            FilledButton(
                              onPressed: () {
                                _close();
                                showEvidence(context, widget.cam, a, m);
                              },
                              child: Text(t('View', 'Lihat')),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Delete confirmations
// ---------------------------------------------------------------------------
Future<bool> _askConfirm(
  BuildContext context,
  String title,
  String message,
  bool isMalay,
) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(isMalay ? 'Batal' : 'Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: TextButton.styleFrom(foregroundColor: AppColors.danger),
          child: Text(isMalay ? 'Padam' : 'Delete'),
        ),
      ],
    ),
  );
  return ok == true;
}

Future<void> confirmDeleteAlert(
  BuildContext context,
  CameraController cam,
  SecurityAlert a,
  bool isMalay,
) async {
  String t(String en, String ms) => isMalay ? ms : en;
  final messenger = ScaffoldMessenger.of(context);
  final yes = await _askConfirm(
    context,
    t('Delete this photo?', 'Padam gambar ini?'),
    t('It will be permanently removed from the laptop. This cannot be undone.',
        'Ia akan dipadam kekal daripada komputer riba. Tindakan ini tidak boleh dibatalkan.'),
    isMalay,
  );
  if (!yes) return;
  final done = await cam.deleteAlert(a);
  messenger.showSnackBar(SnackBar(
    content: Text(done
        ? t('Deleted', 'Dipadam')
        : t('Could not delete. Only the owner can delete.',
            'Tidak dapat memadam. Hanya pemilik boleh memadam.')),
  ));
}

Future<void> confirmDeleteAllAlerts(
  BuildContext context,
  CameraController cam,
  bool isMalay,
) async {
  String t(String en, String ms) => isMalay ? ms : en;
  final messenger = ScaffoldMessenger.of(context);
  final yes = await _askConfirm(
    context,
    t('Delete ALL alert photos?', 'Padam SEMUA gambar amaran?'),
    t('Every alert photo will be permanently removed from the laptop. This cannot be undone.',
        'Semua gambar amaran akan dipadam kekal daripada komputer riba. Tindakan ini tidak boleh dibatalkan.'),
    isMalay,
  );
  if (!yes) return;
  final done = await cam.deleteAllAlerts();
  messenger.showSnackBar(SnackBar(
    content: Text(done
        ? t('All alert photos deleted', 'Semua gambar amaran dipadam')
        : t('Could not delete. Only the owner can delete.',
            'Tidak dapat memadam. Hanya pemilik boleh memadam.')),
  ));
}

// ---------------------------------------------------------------------------
// Opens the evidence photo of one alert
// ---------------------------------------------------------------------------
void showEvidence(BuildContext context, CameraController cam, SecurityAlert a, bool isMalay) {
  String t(String en, String ms) => isMalay ? ms : en;
  final base = cam.serverUrl;
  final url = (a.image != null && base != null) ? '$base/evidence/${a.image}' : null;
  final pct = (a.confidence * 100).round();

  showDialog(
    context: context,
    builder: (ctx) => Dialog(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(t('Person detected', 'Manusia dikesan'),
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            if (url != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: InteractiveViewer(
                  child: Image.network(
                    url,
                    headers: Api.imageHeaders,
                    fit: BoxFit.contain,
                    loadingBuilder: (c, child, progress) => progress == null
                        ? child
                        : const Padding(
                            padding: EdgeInsets.all(32),
                            child: CircularProgressIndicator(),
                          ),
                    errorBuilder: (_, __, ___) => Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(t('Photo not available.', 'Gambar tidak tersedia.')),
                    ),
                  ),
                ),
              )
            else
              Container(
                height: 160,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.surfaceHigh,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  t('Demo alert: no real photo.', 'Amaran demo: tiada gambar sebenar.'),
                  style: const TextStyle(color: AppColors.dim),
                ),
              ),
            const SizedBox(height: 10),
            Text(_dateTime(a.time)),
            const SizedBox(height: 2),
            Text('${t('Confidence', 'Keyakinan')}: $pct%',
                style: const TextStyle(color: AppColors.dim, fontSize: 12)),
            if (a.snoozed)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(t('Saved while alerts were snoozed', 'Disimpan semasa amaran ditangguhkan'),
                    style: const TextStyle(color: AppColors.warn, fontSize: 12)),
              ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(t('Close', 'Tutup')),
                ),
                if (cam.canDelete)
                  TextButton(
                    onPressed: () {
                      Navigator.pop(ctx);
                      confirmDeleteAlert(context, cam, a, isMalay);
                    },
                    style: TextButton.styleFrom(foregroundColor: AppColors.danger),
                    child: Text(t('Delete', 'Padam')),
                  ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
// HOME tab
// ---------------------------------------------------------------------------
class HomeScreen extends StatelessWidget {
  final CameraController cam;
  final bool isMalay;
  final VoidCallback onOpenFull;

  const HomeScreen({
    super.key,
    required this.cam,
    required this.isMalay,
    required this.onOpenFull,
  });

  String _t(String en, String ms) => isMalay ? ms : en;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI SmartCam'),
        centerTitle: true,
        backgroundColor: AppColors.bg,
        elevation: 0,
      ),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: cam,
          builder: (context, _) {
            final latest = cam.alerts.take(3).toList();
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              children: [
                if (cam.demo)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(
                      children: [
                        const _Pill(label: 'Demo', color: AppColors.warn),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _t('Fake data. Set the camera address in the Me tab.',
                                'Data palsu. Tetapkan alamat kamera di tab Saya.'),
                            style: const TextStyle(color: AppColors.dim, fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ),
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 520),
                    child: AspectRatio(
                      aspectRatio: 4 / 3,
                      child: LiveView(cam: cam, isMalay: isMalay, onTap: onOpenFull),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                _StatusBar(cam: cam, isMalay: isMalay),
                _SnoozeSection(cam: cam, isMalay: isMalay),
                const SizedBox(height: 18),
                Text(
                  _t('Latest alerts', 'Amaran terkini'),
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                if (latest.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Text(
                      _t('No detections yet.', 'Tiada pengesanan lagi.'),
                      style: const TextStyle(color: AppColors.dim),
                    ),
                  )
                else
                  for (final a in latest)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _AlertTile(
                        alert: a,
                        cam: cam,
                        title: _t('Person detected', 'Manusia dikesan'),
                        snoozedLabel: _t('Snoozed', 'Ditangguh'),
                        onTap: () => showEvidence(context, cam, a, isMalay),
                        onDelete: cam.canDelete
                            ? () => confirmDeleteAlert(context, cam, a, isMalay)
                            : null,
                      ),
                    ),
              ],
            );
          },
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Snooze area on the Home tab
// ---------------------------------------------------------------------------
class _SnoozeSection extends StatelessWidget {
  final CameraController cam;
  final bool isMalay;
  const _SnoozeSection({required this.cam, required this.isMalay});

  String _t(String en, String ms) => isMalay ? ms : en;
  String _clock(int s) => '${s ~/ 60}:${_two(s % 60)}';

  @override
  Widget build(BuildContext context) {
    final items = <Widget>[];

    final summary = cam.snoozeSummary;
    if (summary != null && !cam.snoozed) {
      final text = summary == 0
          ? _t('Alerts are back on. No one was detected while snoozed.',
              'Amaran dihidupkan semula. Tiada sesiapa dikesan semasa ditangguhkan.')
          : _t('Alerts are back on. $summary detection(s) while snoozed. See them in the Notifications tab.',
              'Amaran dihidupkan semula. $summary pengesanan semasa ditangguhkan. Lihat di tab Notifikasi.');
      items.add(_InfoCard(
        icon: Icons.notifications_active_rounded,
        color: AppColors.ok,
        text: text,
        actionLabel: 'OK',
        onAction: cam.dismissSnoozeSummary,
      ));
    }

    if (cam.snoozed) {
      final who = cam.snoozeBy.isNotEmpty ? '  ·  ${cam.snoozeBy}' : '';
      final title = '${_t('Alerts snoozed', 'Amaran ditangguhkan')}  ·  ${_clock(cam.snoozeLeft)}$who';
      items.add(_InfoCard(
        icon: Icons.notifications_paused_rounded,
        color: AppColors.warn,
        text: title,
        subtext: _t('The camera is still recording.', 'Kamera masih merakam.'),
        actionLabel: cam.isOwner ? _t('Resume now', 'Sambung sekarang') : null,
        onAction: cam.isOwner ? () => cam.resumeAlerts() : null,
      ));
    } else if (cam.isOwner && cam.connected) {
      items.add(OutlinedButton.icon(
        onPressed: () => showSnoozeDialog(context, cam, isMalay),
        icon: const Icon(Icons.notifications_paused_rounded),
        label: Text(_t('Snooze alerts', 'Tangguh amaran')),
        style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
      ));
    }

    if (items.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final w in items)
            Padding(padding: const EdgeInsets.only(bottom: 8), child: w),
        ],
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;
  final String? subtext;
  final String? actionLabel;
  final VoidCallback? onAction;

  const _InfoCard({
    required this.icon,
    required this.color,
    required this.text,
    this.subtext,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withOpacity(0.5)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(text, style: const TextStyle(fontWeight: FontWeight.w600)),
                if (subtext != null)
                  Text(subtext!, style: const TextStyle(color: AppColors.dim, fontSize: 12)),
              ],
            ),
          ),
          if (actionLabel != null && onAction != null)
            TextButton(onPressed: onAction, child: Text(actionLabel!)),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Full screen live video (opens when you tap the video on Home)
// ---------------------------------------------------------------------------
class FullScreenLivePage extends StatelessWidget {
  final CameraController cam;
  final bool isMalay;

  const FullScreenLivePage({super.key, required this.cam, required this.isMalay});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text(isMalay ? 'Kamera langsung' : 'Live camera'),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Center(
          child: AspectRatio(
            aspectRatio: 4 / 3,
            child: LiveView(cam: cam, isMalay: isMalay),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// NOTIFICATIONS tab
// ---------------------------------------------------------------------------
class NotificationsScreen extends StatelessWidget {
  final CameraController cam;
  final bool isMalay;

  const NotificationsScreen({super.key, required this.cam, required this.isMalay});

  String _t(String en, String ms) => isMalay ? ms : en;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: cam,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(
            title: Text(_t('Notifications', 'Notifikasi')),
            centerTitle: true,
            backgroundColor: AppColors.bg,
            elevation: 0,
            actions: [
              if (cam.canDelete && cam.alerts.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.delete_sweep_rounded),
                  tooltip: _t('Delete all', 'Padam semua'),
                  onPressed: () => confirmDeleteAllAlerts(context, cam, isMalay),
                ),
            ],
          ),
          body: SafeArea(
            child: cam.alerts.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        _t('No alerts yet. They appear here when a person is detected.',
                            'Tiada amaran lagi. Ia muncul di sini apabila manusia dikesan.'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: AppColors.dim),
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(16),
                    itemCount: cam.alerts.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (_, i) {
                      final a = cam.alerts[i];
                      return _AlertTile(
                        alert: a,
                        cam: cam,
                        title: _t('Person detected', 'Manusia dikesan'),
                        snoozedLabel: _t('Snoozed', 'Ditangguh'),
                        onTap: () => showEvidence(context, cam, a, isMalay),
                        onDelete: cam.canDelete
                            ? () => confirmDeleteAlert(context, cam, a, isMalay)
                            : null,
                      );
                    },
                  ),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// LiveView: camera picture + detection box + pause button
// ---------------------------------------------------------------------------
class LiveView extends StatefulWidget {
  final CameraController cam;
  final bool isMalay;
  final VoidCallback? onTap;

  const LiveView({super.key, required this.cam, required this.isMalay, this.onTap});

  @override
  State<LiveView> createState() => _LiveViewState();
}

class _LiveViewState extends State<LiveView> {
  bool _paused = false;

  String _t(String en, String ms) => widget.isMalay ? ms : en;

  Widget _content(CameraController cam) {
    if (cam.demo) return _DemoFeed(night: cam.nightVision);

    if (!cam.connected) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.videocam_off_rounded, size: 44, color: AppColors.dim),
            const SizedBox(height: 8),
            Text(
              _t('Camera offline', 'Kamera luar talian'),
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 2),
            Text(
              _t('Check the address in the Me tab.', 'Semak alamat di tab Saya.'),
              style: const TextStyle(color: AppColors.dim, fontSize: 12),
            ),
          ],
        ),
      );
    }

    final url = '${cam.serverUrl}/video_feed';
    return MjpegView(key: ValueKey(url), url: url, paused: _paused);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.cam,
      builder: (context, _) {
        final cam = widget.cam;
        final detected = cam.detection != null;
        return GestureDetector(
          onTap: widget.onTap,
          child: Container(
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: detected ? AppColors.danger : AppColors.surfaceHigh,
                width: detected ? 3 : 1,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(15),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _content(cam),
                  if (detected && !_paused && cam.detection!.box != Rect.zero)
                    CustomPaint(
                      painter: _BoxPainter(cam.detection!, _t('Person', 'Manusia')),
                    ),
                  if (_paused && cam.connected)
                    const Center(
                      child: Icon(Icons.pause_circle_filled_rounded,
                          size: 56, color: Colors.white70),
                    ),
                  Positioned(
                    top: 10,
                    left: 10,
                    child: _Pill(
                      label: !cam.connected
                          ? _t('Offline', 'Luar talian')
                          : (_paused ? _t('Paused', 'Dijeda') : _t('Live', 'Langsung')),
                      color: !cam.connected
                          ? AppColors.dim
                          : (_paused ? AppColors.warn : AppColors.danger),
                      filled: true,
                    ),
                  ),
                  if (cam.snoozed && cam.connected)
                    Positioned(
                      top: 40,
                      left: 10,
                      child: _Pill(
                        label: _t('Snoozed', 'Ditangguh'),
                        color: AppColors.warn,
                        filled: true,
                      ),
                    ),
                  if (cam.nightVision)
                    const Positioned(
                      top: 10,
                      right: 10,
                      child: _Pill(label: 'IR', color: AppColors.ok, filled: true),
                    ),
                  if (cam.connected)
                    Positioned(
                      bottom: 8,
                      right: 8,
                      child: IconButton.filledTonal(
                        onPressed: () => setState(() => _paused = !_paused),
                        tooltip: _paused ? _t('Resume', 'Sambung') : _t('Pause', 'Jeda'),
                        icon: Icon(_paused ? Icons.play_arrow_rounded : Icons.pause_rounded),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Small widgets
// ---------------------------------------------------------------------------
class _Pill extends StatelessWidget {
  final String label;
  final Color color;
  final bool filled;
  const _Pill({required this.label, required this.color, this.filled = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: filled ? color.withOpacity(0.9) : color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(20),
        border: filled ? null : Border.all(color: color.withOpacity(0.6)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: filled ? Colors.black : color,
        ),
      ),
    );
  }
}

class _StatusBar extends StatelessWidget {
  final CameraController cam;
  final bool isMalay;
  const _StatusBar({required this.cam, required this.isMalay});

  @override
  Widget build(BuildContext context) {
    String t(String en, String ms) => isMalay ? ms : en;
    final detected = cam.detection != null;
    return Row(
      children: [
        Expanded(
          child: _StatusChip(
            icon: cam.connected ? Icons.videocam_rounded : Icons.videocam_off_rounded,
            label: cam.connected
                ? t('Camera connected', 'Kamera terhubung')
                : t('Camera offline', 'Kamera luar talian'),
            color: cam.connected ? AppColors.ok : AppColors.danger,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _StatusChip(
            icon: Icons.memory_rounded,
            label: cam.aiActive ? t('Edge AI active', 'AI aktif') : t('Edge AI idle', 'AI tidak aktif'),
            color: cam.aiActive ? AppColors.ok : AppColors.warn,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _StatusChip(
            icon: detected ? Icons.person_rounded : Icons.shield_outlined,
            label: detected ? t('Person detected', 'Manusia dikesan') : t('Area clear', 'Kawasan selamat'),
            color: detected ? AppColors.danger : AppColors.ok,
          ),
        ),
      ],
    );
  }
}

class _StatusChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  const _StatusChip({required this.icon, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.5)),
      ),
      child: Column(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(height: 4),
          Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11, height: 1.2),
          ),
        ],
      ),
    );
  }
}

class _AlertTile extends StatelessWidget {
  final SecurityAlert alert;
  final CameraController cam;
  final String title;
  final String snoozedLabel;
  final VoidCallback onTap;
  final VoidCallback? onDelete; // null = no delete button (members)

  const _AlertTile({
    required this.alert,
    required this.cam,
    required this.title,
    required this.onTap,
    this.snoozedLabel = 'Snoozed',
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final pct = (alert.confidence * 100).round();
    final base = cam.serverUrl;
    final thumb = (alert.image != null && base != null) ? '$base/evidence/${alert.image}' : null;

    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SizedBox(
                  width: 56,
                  height: 56,
                  child: thumb != null
                      ? Image.network(
                          thumb,
                          headers: Api.imageHeaders,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Container(
                            color: AppColors.surfaceHigh,
                            child: const Icon(Icons.person_rounded, color: AppColors.danger),
                          ),
                        )
                      : Container(
                          color: AppColors.surfaceHigh,
                          child: const Icon(Icons.person_rounded, color: AppColors.danger),
                        ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(_dateTime(alert.time),
                        style: const TextStyle(color: AppColors.dim, fontSize: 12)),
                    if (alert.snoozed)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: _Pill(label: snoozedLabel, color: AppColors.warn),
                      ),
                  ],
                ),
              ),
              _Pill(label: '$pct%', color: pct >= 75 ? AppColors.ok : AppColors.warn),
              const SizedBox(width: 4),
              if (onDelete != null)
                IconButton(
                  icon: const Icon(Icons.delete_outline_rounded, color: AppColors.danger),
                  tooltip: 'Delete',
                  onPressed: onDelete,
                )
              else
                const Icon(Icons.chevron_right_rounded, color: AppColors.dim),
            ],
          ),
        ),
      ),
    );
  }
}

class _DemoFeed extends StatelessWidget {
  final bool night;
  const _DemoFeed({required this.night});

  @override
  Widget build(BuildContext context) {
    final colors = night
        ? const [Color(0xFF062B1A), Color(0xFF0B4F2E)]
        : const [Color(0xFF2B3140), Color(0xFF4A5368)];
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: colors,
        ),
      ),
      child: const Center(
        child: Text('Demo feed', style: TextStyle(color: Colors.white38, fontSize: 14)),
      ),
    );
  }
}

class _BoxPainter extends CustomPainter {
  final Detection detection;
  final String label;
  _BoxPainter(this.detection, this.label);

  @override
  void paint(Canvas canvas, Size size) {
    final b = detection.box;
    final rect = Rect.fromLTWH(
      b.left * size.width,
      b.top * size.height,
      b.width * size.width,
      b.height * size.height,
    );
    final stroke = Paint()
      ..color = AppColors.danger
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;
    canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(4)), stroke);

    final tp = TextPainter(
      text: TextSpan(
        text: ' $label ${(detection.confidence * 100).round()}% ',
        style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final tagTop = math.max(0.0, rect.top - tp.height - 2);
    canvas.drawRect(
      Rect.fromLTWH(rect.left, tagTop, tp.width, tp.height + 2),
      Paint()..color = AppColors.danger,
    );
    tp.paint(canvas, Offset(rect.left, tagTop + 1));
  }

  @override
  bool shouldRepaint(covariant _BoxPainter old) => true;
}

// ---------------------------------------------------------------------------
// MjpegView: shows the camera video.
// Phones/Windows: reads the live stream. Chrome: fetches pictures repeatedly.
// When `paused` is true, the picture freezes.
// ---------------------------------------------------------------------------
class MjpegView extends StatefulWidget {
  final String url; // ends with /video_feed
  final bool paused;
  const MjpegView({super.key, required this.url, this.paused = false});

  @override
  State<MjpegView> createState() => _MjpegViewState();
}

class _MjpegViewState extends State<MjpegView> {
  http.Client? _client;
  StreamSubscription<List<int>>? _sub;
  final List<int> _buf = [];
  Uint8List? _frame;
  bool _failed = false;

  Timer? _pollTimer;
  int _stamp = 0;

  String get _snapshotUrl => widget.url.replaceFirst('/video_feed', '/snapshot');

  @override
  void initState() {
    super.initState();
    if (kIsWeb) {
      _pollTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
        if (mounted && !widget.paused) setState(() => _stamp++);
      });
    } else {
      _connect();
    }
  }

  Future<void> _connect() async {
    _client = http.Client();
    try {
      final res = await _client!.send(http.Request('GET', Uri.parse(widget.url)));
      _sub = res.stream.listen(
        (chunk) {
          _buf.addAll(chunk);
          _extractFrames();
        },
        onError: (_) => _fail(),
        onDone: _fail,
      );
    } catch (_) {
      _fail();
    }
  }

  void _fail() {
    if (mounted) setState(() => _failed = true);
  }

  int _find(int a, int b, int from) {
    for (var i = from; i < _buf.length - 1; i++) {
      if (_buf[i] == a && _buf[i + 1] == b) return i;
    }
    return -1;
  }

  void _extractFrames() {
    while (true) {
      final start = _find(0xFF, 0xD8, 0);
      if (start < 0) {
        _buf.clear();
        return;
      }
      final end = _find(0xFF, 0xD9, start + 2);
      if (end < 0) {
        if (start > 0) _buf.removeRange(0, start);
        if (_buf.length > 2 * 1024 * 1024) _buf.clear();
        return;
      }
      final frame = Uint8List.fromList(_buf.sublist(start, end + 2));
      _buf.removeRange(0, end + 2);
      if (mounted && !widget.paused) setState(() => _frame = frame);
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _sub?.cancel();
    _client?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) {
      return Image.network(
        '$_snapshotUrl?t=$_stamp',
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => const Center(
          child: Text('Stream unavailable', style: TextStyle(color: AppColors.dim)),
        ),
      );
    }
    if (_frame != null) {
      return Image.memory(_frame!, fit: BoxFit.cover, gaplessPlayback: true);
    }
    return Center(
      child: _failed
          ? const Text('Stream unavailable', style: TextStyle(color: AppColors.dim))
          : const CircularProgressIndicator(color: AppColors.accent),
    );
  }
}