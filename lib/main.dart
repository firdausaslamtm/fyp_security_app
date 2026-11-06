import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_screens.dart';
import 'dashboard_screen.dart' hide VideoScreen;
import 'video_screen.dart';

void main() {
  runApp(const AISmartCamApp());
}

class AISmartCamApp extends StatefulWidget {
  const AISmartCamApp({super.key});

  @override
  State<AISmartCamApp> createState() => _AISmartCamAppState();
}

class _AISmartCamAppState extends State<AISmartCamApp> {
  final CameraController _cam = CameraController();
  late final AuthController _auth;
  SharedPreferences? _prefs;
  bool _loaded = false;
  bool _isMalay = false;
  double _fontScale = 1.0;
  bool _wasLoggedIn = false;

  @override
  void initState() {
    super.initState();
    // The app is opened from the camera server, so the server is the page address.
    final base = kIsWeb ? Uri.base.origin : 'http://127.0.0.1:5000';
    _auth = AuthController(base);
    _auth.addListener(_onAuth);
    _auth.init();
    _load();
  }

  @override
  void dispose() {
    _auth.removeListener(_onAuth);
    _auth.dispose();
    _cam.dispose();
    super.dispose();
  }

  // Start talking to the camera only after login.
  void _onAuth() {
    if (_auth.loggedIn && !_wasLoggedIn) {
      _cam.setServer(_auth.base);
    }
    _wasLoggedIn = _auth.loggedIn;
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    _prefs = p;
    _isMalay = p.getBool('isMalay') ?? false;
    _fontScale = p.getDouble('fontScale') ?? 1.0;
    if (mounted) setState(() => _loaded = true);
  }

  void _setLanguage(bool v) {
    setState(() => _isMalay = v);
    _prefs?.setBool('isMalay', v);
  }

  void _setFont(double v) {
    setState(() => _fontScale = v);
    _prefs?.setDouble('fontScale', v);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AI SmartCam',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: AppColors.accent,
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: AppColors.bg,
      ),
      builder: (context, child) {
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(_fontScale),
          ),
          child: child!,
        );
      },
      home: _loaded
          ? AuthGate(
              auth: _auth,
              cam: _cam,
              isMalay: _isMalay,
              fontScale: _fontScale,
              onLanguageChanged: _setLanguage,
              onFontScaleChanged: _setFont,
            )
          : const Scaffold(body: Center(child: CircularProgressIndicator())),
    );
  }
}

// ---------------------------------------------------------------------------
// Decides what to show: loading, error, login, or the app
// ---------------------------------------------------------------------------
class AuthGate extends StatelessWidget {
  final AuthController auth;
  final CameraController cam;
  final bool isMalay;
  final double fontScale;
  final ValueChanged<bool> onLanguageChanged;
  final ValueChanged<double> onFontScaleChanged;

  const AuthGate({
    super.key,
    required this.auth,
    required this.cam,
    required this.isMalay,
    required this.fontScale,
    required this.onLanguageChanged,
    required this.onFontScaleChanged,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: auth,
      builder: (context, _) {
        if (auth.loading) {
          return const Scaffold(body: Center(child: CircularProgressIndicator()));
        }
        if (!auth.reachable) {
          return ServerUnreachable(isMalay: isMalay, onRetry: auth.init);
        }
        if (!auth.loggedIn) {
          return AuthScreen(
            auth: auth,
            isMalay: isMalay,
            onLanguageChanged: onLanguageChanged,
          );
        }
        return HomeShell(
          auth: auth,
          cam: cam,
          isMalay: isMalay,
          fontScale: fontScale,
          onLanguageChanged: onLanguageChanged,
          onFontScaleChanged: onFontScaleChanged,
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Bottom navigation: Home, Video, Notifications, Me
// ---------------------------------------------------------------------------
class HomeShell extends StatefulWidget {
  final AuthController auth;
  final CameraController cam;
  final bool isMalay;
  final double fontScale;
  final ValueChanged<bool> onLanguageChanged;
  final ValueChanged<double> onFontScaleChanged;

  const HomeShell({
    super.key,
    required this.auth,
    required this.cam,
    required this.isMalay,
    required this.fontScale,
    required this.onLanguageChanged,
    required this.onFontScaleChanged,
  });

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0; final PopupController _popup = PopupController();

  void _onCamChanged() {
    // If you are looking at the Notifications tab, new alerts count as read.
    if (_index == 2) widget.cam.markRead();
  }

  @override
  void initState() {
    super.initState();
widget.cam.addListener(_onCamChanged); WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _popup.attach(context, widget.cam, () => widget.isMalay); });  }

  @override
  void dispose() {
widget.cam.removeListener(_onCamChanged); _popup.detach();    super.dispose();
  }

  void _select(int i) {
    setState(() => _index = i);
    if (i == 2) widget.cam.markRead();
  }

  void _openFull() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => FullScreenLivePage(cam: widget.cam, isMalay: widget.isMalay),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.isMalay;
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: [
          HomeScreen(cam: widget.cam, isMalay: m, onOpenFull: _openFull),
          VideoScreen(cam: widget.cam, isMalay: m),
          NotificationsScreen(cam: widget.cam, isMalay: m),
          MeScreen(
            auth: widget.auth,
            cam: widget.cam,
            isMalay: m,
            fontScale: widget.fontScale,
            onLanguageChanged: widget.onLanguageChanged,
            onFontScaleChanged: widget.onFontScaleChanged,
          ),
        ],
      ),
      bottomNavigationBar: ListenableBuilder(
        listenable: widget.cam,
        builder: (context, _) {
          return NavigationBar(
            selectedIndex: _index,
            onDestinationSelected: _select,
            destinations: [
              NavigationDestination(
                icon: const Icon(Icons.home_rounded),
                label: m ? 'Utama' : 'Home',
              ),
              const NavigationDestination(
                icon: Icon(Icons.videocam_rounded),
                label: 'Video',
              ),
              NavigationDestination(
                icon: Badge(
                  isLabelVisible: widget.cam.unread > 0,
                  label: Text('${widget.cam.unread}'),
                  child: const Icon(Icons.notifications_rounded),
                ),
                label: m ? 'Notifikasi' : 'Notifications',
              ),
              NavigationDestination(
                icon: const Icon(Icons.person_rounded),
                label: m ? 'Saya' : 'Me',
              ),
            ],
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// ME tab: profile, settings, owner tools, log out
// ---------------------------------------------------------------------------
String _two(int n) => n.toString().padLeft(2, '0');

class MeScreen extends StatelessWidget {
  final AuthController auth;
  final CameraController cam;
  final bool isMalay;
  final double fontScale;
  final ValueChanged<bool> onLanguageChanged;
  final ValueChanged<double> onFontScaleChanged;

  const MeScreen({
    super.key,
    required this.auth,
    required this.cam,
    required this.isMalay,
    required this.fontScale,
    required this.onLanguageChanged,
    required this.onFontScaleChanged,
  });

  String _t(String en, String ms) => isMalay ? ms : en;

  Future<void> _invite(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final code = await auth.createInvite();
    if (!context.mounted) return;
    if (code == null) {
      messenger.showSnackBar(SnackBar(
          content: Text(_t('Could not create an invite.', 'Tidak dapat mencipta jemputan.'))));
      return;
    }
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_t('Invite code', 'Kod jemputan')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SelectableText(
              code,
              style: const TextStyle(
                fontSize: 30,
                fontWeight: FontWeight.w800,
                letterSpacing: 4,
                color: AppColors.accent,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              _t('Give this code to the person. It works once and expires in 24 hours.',
                  'Beri kod ini kepada orang itu. Ia sekali guna dan tamat dalam 24 jam.'),
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.dim, fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: code));
              messenger.showSnackBar(
                  SnackBar(content: Text(_t('Copied', 'Disalin'))));
            },
            child: Text(_t('Copy', 'Salin')),
          ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(_t('Close', 'Tutup'))),
        ],
      ),
    );
  }

  Future<void> _location(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final current = await auth.getLocation();
    if (!context.mounted) return;
    final controller = TextEditingController(text: current);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_t('Camera location name', 'Nama lokasi kamera')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: controller,
              maxLength: 24,
              decoration: const InputDecoration(hintText: 'Rumah'),
            ),
            Text(
              _t('Shown with the date and time on every live picture, photo and clip.',
                  'Dipaparkan bersama tarikh dan masa pada setiap gambar langsung, foto dan klip.'),
              style: const TextStyle(color: AppColors.dim, fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(_t('Cancel', 'Batal'))),
          TextButton(
            onPressed: () async {
              final e = await auth.setLocation(controller.text);
              if (ctx.mounted) Navigator.pop(ctx);
              messenger.showSnackBar(
                  SnackBar(content: Text(e ?? _t('Saved', 'Disimpan'))));
            },
            child: Text(_t('Save', 'Simpan')),
          ),
        ],
      ),
    );
  }

  Future<void> _log(BuildContext context) async {
    final rows = await auth.activity();
    if (!context.mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_t('Security log', 'Log keselamatan')),
        content: SizedBox(
          width: 380,
          height: 360,
          child: rows.isEmpty
              ? Center(child: Text(_t('Nothing yet.', 'Belum ada.')))
              : ListView.separated(
                  itemCount: rows.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final r = rows[i];
                    final t = DateTime.fromMillisecondsSinceEpoch(
                        ((r['ts'] as num) * 1000).round());
                    final ev = (r['event'] as String).replaceAll('_', ' ');
                    return ListTile(
                      dense: true,
                      title: Text(ev),
                      subtitle: Text('${r['email'] ?? ''}   ${r['ip'] ?? ''}'),
                      trailing: Text(
                          '${t.day}/${t.month} ${_two(t.hour)}:${_two(t.minute)}',
                          style: const TextStyle(fontSize: 12)),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(_t('Close', 'Tutup'))),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_t('Me', 'Saya')),
        centerTitle: true,
        backgroundColor: AppColors.bg,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                children: [
                  const CircleAvatar(
                    radius: 26,
                    backgroundColor: AppColors.accent,
                    child: Icon(Icons.person_rounded, color: Colors.white, size: 30),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(auth.name,
                            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                        Text(auth.email,
                            style: const TextStyle(color: AppColors.dim, fontSize: 12)),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppColors.accent.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      auth.isOwner ? _t('Owner', 'Pemilik') : _t('Member', 'Ahli'),
                      style: const TextStyle(
                          color: AppColors.accent, fontSize: 12, fontWeight: FontWeight.w700),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            ListTile(
              leading: const Icon(Icons.language_rounded),
              title: Text(_t('Language', 'Bahasa')),
              trailing: ToggleButtons(
                isSelected: [!isMalay, isMalay],
                borderRadius: BorderRadius.circular(8),
                onPressed: (index) => onLanguageChanged(index == 1),
                children: const [
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12),
                    child: Text('ENG'),
                  ),
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12),
                    child: Text('BM'),
                  ),
                ],
              ),
            ),
            const Divider(),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      _t('Text size', 'Saiz tulisan'),
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  Slider(
                    value: fontScale,
                    min: 0.8,
                    max: 1.6,
                    divisions: 4,
                    label: '${(fontScale * 100).round()}%',
                    onChanged: onFontScaleChanged,
                  ),
                ],
              ),
            ),
            const Divider(),
            ListenableBuilder(
              listenable: cam,
              builder: (context, _) {
                return ListTile(
                  leading: const Icon(Icons.dns_rounded),
                  title: Text(_t('Camera server', 'Pelayan kamera')),
                  subtitle: Text(
                    '${auth.base}  (${cam.connected ? _t('connected', 'terhubung') : _t('not connected', 'tidak terhubung')})',
                  ),
                );
              },
            ),
            if (auth.isOwner) ...[
              const Divider(),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Text(
                  _t('Owner tools', 'Alat pemilik'),
                  style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.dim),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.person_add_alt_1_rounded),
                title: Text(_t('Invite someone', 'Jemput seseorang')),
                subtitle: Text(_t('Create a code so they can sign up', 'Cipta kod supaya mereka boleh daftar')),
                onTap: () => _invite(context),
              ),
              ListTile(
                leading: const Icon(Icons.place_rounded),
                title: Text(_t('Camera location name', 'Nama lokasi kamera')),
                subtitle: Text(_t('Shown on pictures, photos and clips', 'Dipaparkan pada gambar, foto dan klip')),
                onTap: () => _location(context),
              ),
              ListTile(
                leading: const Icon(Icons.security_rounded),
                title: Text(_t('Security log', 'Log keselamatan')),
                subtitle: Text(_t('Logins, failed attempts, invites', 'Log masuk, percubaan gagal, jemputan')),
                onTap: () => _log(context),
              ),
            ],
            const SizedBox(height: 20),
            OutlinedButton.icon(
              onPressed: auth.logout,
              icon: const Icon(Icons.logout_rounded),
              label: Text(_t('Log out', 'Log keluar')),
              style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
            ),
          ],
        ),
      ),
    );
  }
}