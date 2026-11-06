import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'dashboard_screen.dart' show AppColors;

// ---------------------------------------------------------------------------
// AuthController: talks to the server's account system
// ---------------------------------------------------------------------------
class AuthController extends ChangeNotifier {
  final String base;
  AuthController(this.base);

  bool loading = true;
  bool reachable = true;
  bool hasUsers = true;
  Map<String, dynamic>? user;
  Timer? _timer;

  bool get loggedIn => user != null;
  bool get isOwner => user?['role'] == 'owner';
  String get name => (user?['name'] as String?) ?? '';
  String get email => (user?['email'] as String?) ?? '';

  Future<void> init() async {
    loading = true;
    notifyListeners();
    try {
      final s = await http
          .get(Uri.parse('$base/api/auth/state'))
          .timeout(const Duration(seconds: 6));
      final sd = json.decode(s.body) as Map<String, dynamic>;
      hasUsers = sd['has_users'] == true;
      reachable = true;
      final me = await http
          .get(Uri.parse('$base/api/auth/me'))
          .timeout(const Duration(seconds: 6));
      if (me.statusCode == 200) {
        user = Map<String, dynamic>.from((json.decode(me.body) as Map)['user'] as Map);
      } else {
        user = null;
      }
    } catch (_) {
      reachable = false;
    }
    loading = false;
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _checkSession());
    notifyListeners();
  }

  // If the login expires, go back to the login screen.
  Future<void> _checkSession() async {
    if (user == null) return;
    try {
      final r = await http
          .get(Uri.parse('$base/api/auth/me'))
          .timeout(const Duration(seconds: 5));
      if (r.statusCode == 401) {
        user = null;
        notifyListeners();
      }
    } catch (_) {}
  }

  // Returns an error message, or null when it worked.
  Future<String?> _authCall(String path, Map<String, String> body) async {
    try {
      final r = await http
          .post(
            Uri.parse('$base$path'),
            headers: {'Content-Type': 'application/json'},
            body: json.encode(body),
          )
          .timeout(const Duration(seconds: 10));
      final data = json.decode(r.body) as Map<String, dynamic>;
      if (r.statusCode == 200) {
        user = Map<String, dynamic>.from(data['user'] as Map);
        hasUsers = true;
        notifyListeners();
        return null;
      }
      return (data['error'] as String?) ?? 'Something went wrong.';
    } catch (_) {
      return 'Cannot reach the camera server.';
    }
  }

  Future<String?> login(String email, String password) =>
      _authCall('/api/auth/login', {'email': email, 'password': password});

  Future<String?> signup(String name, String email, String password, String invite) =>
      _authCall('/api/auth/signup', {
        'name': name,
        'email': email,
        'password': password,
        'invite': invite,
      });

  Future<void> logout() async {
    try {
      await http.post(Uri.parse('$base/api/auth/logout')).timeout(const Duration(seconds: 5));
    } catch (_) {}
    user = null;
    notifyListeners();
  }

  // ----- owner tools -----
  Future<String?> createInvite() async {
    try {
      final r = await http
          .post(Uri.parse('$base/api/auth/invite'))
          .timeout(const Duration(seconds: 6));
      if (r.statusCode == 200) return (json.decode(r.body) as Map)['code'] as String?;
    } catch (_) {}
    return null;
  }

  Future<List<Map<String, dynamic>>> activity() async {
    try {
      final r = await http
          .get(Uri.parse('$base/api/auth/activity'))
          .timeout(const Duration(seconds: 6));
      if (r.statusCode == 200) {
        return (json.decode(r.body) as List).cast<Map<String, dynamic>>();
      }
    } catch (_) {}
    return [];
  }

  Future<String> getLocation() async {
    try {
      final r = await http
          .get(Uri.parse('$base/api/settings'))
          .timeout(const Duration(seconds: 6));
      if (r.statusCode == 200) {
        return ((json.decode(r.body) as Map)['location'] as String?) ?? '';
      }
    } catch (_) {}
    return '';
  }

  // Returns an error message, or null when it worked.
  Future<String?> setLocation(String value) async {
    try {
      final r = await http
          .post(
            Uri.parse('$base/api/settings'),
            headers: {'Content-Type': 'application/json'},
            body: json.encode({'location': value}),
          )
          .timeout(const Duration(seconds: 6));
      if (r.statusCode == 200) return null;
      return ((json.decode(r.body) as Map)['error'] as String?) ?? 'Could not save.';
    } catch (_) {
      return 'Cannot reach the camera server.';
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

// ---------------------------------------------------------------------------
// Login / Sign up screen
// ---------------------------------------------------------------------------
class AuthScreen extends StatefulWidget {
  final AuthController auth;
  final bool isMalay;
  final ValueChanged<bool> onLanguageChanged;

  const AuthScreen({
    super.key,
    required this.auth,
    required this.isMalay,
    required this.onLanguageChanged,
  });

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _pass = TextEditingController();
  final _invite = TextEditingController();
  bool _signup = false;
  bool _busy = false;
  bool _hide = true;
  String? _error;

  // First time ever: nobody has an account yet, so this creates the owner.
  bool get _firstRun => !widget.auth.hasUsers;
  bool get _isSignup => _firstRun || _signup;
  String _t(String en, String ms) => widget.isMalay ? ms : en;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _pass.dispose();
    _invite.dispose();
    super.dispose();
  }

  String? _validate() {
    final email = _email.text.trim();
    final pass = _pass.text;
    if (_isSignup && _name.text.trim().isEmpty) {
      return _t('Please enter your name.', 'Sila masukkan nama anda.');
    }
    if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
      return _t('Please enter a valid email address.', 'Sila masukkan alamat e-mel yang sah.');
    }
    if (_isSignup) {
      if (pass.length < 8 ||
          !RegExp(r'[A-Za-z]').hasMatch(pass) ||
          !RegExp(r'\d').hasMatch(pass)) {
        return _t('Password needs at least 8 characters, with a letter and a number.',
            'Kata laluan perlu sekurang-kurangnya 8 aksara, dengan huruf dan nombor.');
      }
      if (!_firstRun && _invite.text.trim().isEmpty) {
        return _t('Enter the invite code from the camera owner.',
            'Masukkan kod jemputan daripada pemilik kamera.');
      }
    } else if (pass.isEmpty) {
      return _t('Please enter your password.', 'Sila masukkan kata laluan anda.');
    }
    return null;
  }

  Future<void> _submit() async {
    final problem = _validate();
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final String? result = _isSignup
        ? await widget.auth.signup(
            _name.text.trim(), _email.text.trim(), _pass.text, _invite.text.trim())
        : await widget.auth.login(_email.text.trim(), _pass.text);
    if (!mounted) return; // success: this screen is replaced by the app
    setState(() {
      _busy = false;
      _error = result;
    });
  }

  InputDecoration _dec(String label, IconData icon) {
    return InputDecoration(
      labelText: label,
      prefixIcon: Icon(icon),
      filled: true,
      fillColor: AppColors.surface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final first = _firstRun;
    final title = first
        ? _t('Set up your camera', 'Sediakan kamera anda')
        : (_isSignup ? _t('Create account', 'Cipta akaun') : _t('Welcome back', 'Selamat kembali'));
    final subtitle = first
        ? _t('Create the owner account. You can invite family or staff later.',
            'Cipta akaun pemilik. Anda boleh jemput keluarga atau staf kemudian.')
        : (_isSignup
            ? _t('You need an invite code from the camera owner.',
                'Anda perlukan kod jemputan daripada pemilik kamera.')
            : _t('Log in to view your camera.', 'Log masuk untuk melihat kamera anda.'));

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Align(
                    alignment: Alignment.centerRight,
                    child: ToggleButtons(
                      isSelected: [!widget.isMalay, widget.isMalay],
                      borderRadius: BorderRadius.circular(8),
                      constraints: const BoxConstraints(minHeight: 32, minWidth: 44),
                      onPressed: (i) => widget.onLanguageChanged(i == 1),
                      children: const [Text('ENG'), Text('BM')],
                    ),
                  ),
                  const SizedBox(height: 8),
                  Center(
                    child: Container(
                      width: 76,
                      height: 76,
                      decoration: BoxDecoration(
                        color: AppColors.accent.withOpacity(0.15),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.shield_rounded, size: 40, color: AppColors.accent),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'AI SmartCam',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: AppColors.dim, fontSize: 13),
                  ),
                  const SizedBox(height: 20),
                  if (_isSignup) ...[
                    TextField(
                      controller: _name,
                      textCapitalization: TextCapitalization.words,
                      decoration: _dec(_t('Your name', 'Nama anda'), Icons.person_outline_rounded),
                    ),
                    const SizedBox(height: 12),
                  ],
                  TextField(
                    controller: _email,
                    keyboardType: TextInputType.emailAddress,
                    decoration: _dec(_t('Email', 'E-mel'), Icons.mail_outline_rounded),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _pass,
                    obscureText: _hide,
                    onSubmitted: (_) => _submit(),
                    decoration: _dec(_t('Password', 'Kata laluan'), Icons.lock_outline_rounded).copyWith(
                      suffixIcon: IconButton(
                        icon: Icon(_hide ? Icons.visibility_rounded : Icons.visibility_off_rounded),
                        onPressed: () => setState(() => _hide = !_hide),
                      ),
                    ),
                  ),
                  if (_isSignup)
                    Padding(
                      padding: const EdgeInsets.only(top: 6, left: 4),
                      child: Text(
                        _t('At least 8 characters, with a letter and a number.',
                            'Sekurang-kurangnya 8 aksara, dengan huruf dan nombor.'),
                        style: const TextStyle(color: AppColors.dim, fontSize: 12),
                      ),
                    ),
                  if (_isSignup && !_firstRun) ...[
                    const SizedBox(height: 12),
                    TextField(
                      controller: _invite,
                      textCapitalization: TextCapitalization.characters,
                      decoration: _dec(_t('Invite code', 'Kod jemputan'), Icons.vpn_key_outlined),
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 14),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.danger.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: AppColors.danger.withOpacity(0.5)),
                      ),
                      child: Text(_error!, style: const TextStyle(fontSize: 13)),
                    ),
                  ],
                  const SizedBox(height: 18),
                  FilledButton(
                    onPressed: _busy ? null : _submit,
                    style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
                    child: _busy
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(
                            _isSignup ? _t('Create account', 'Cipta akaun') : _t('Log in', 'Log masuk'),
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                          ),
                  ),
                  if (!first)
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => setState(() {
                                _signup = !_signup;
                                _error = null;
                              }),
                      child: Text(_signup
                          ? _t('Already have an account? Log in', 'Sudah ada akaun? Log masuk')
                          : _t('New here? Sign up with an invite code',
                              'Baru di sini? Daftar dengan kod jemputan')),
                    ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.lock_rounded, size: 14, color: AppColors.dim),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          _t('Video is processed on your own device, never uploaded to the cloud.',
                              'Video diproses pada peranti anda sendiri, tidak dimuat naik ke awan.'),
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: AppColors.dim, fontSize: 11),
                        ),
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
// Shown when the app cannot reach the camera server
// ---------------------------------------------------------------------------
class ServerUnreachable extends StatelessWidget {
  final bool isMalay;
  final VoidCallback onRetry;

  const ServerUnreachable({super.key, required this.isMalay, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.cloud_off_rounded, size: 56, color: AppColors.dim),
                const SizedBox(height: 16),
                Text(
                  isMalay ? 'Tidak dapat hubungi pelayan kamera' : 'Cannot reach the camera server',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                Text(
                  isMalay
                      ? 'Pastikan komputer riba dihidupkan dan pelayan sedang berjalan.'
                      : 'Make sure the laptop is on and the server is running.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.dim),
                ),
                const SizedBox(height: 20),
                FilledButton.tonal(
                  onPressed: onRetry,
                  child: Text(isMalay ? 'Cuba lagi' : 'Try again'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}