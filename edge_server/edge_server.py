import datetime as dt
import functools
import hashlib
import os
import re
import secrets
import sqlite3
import subprocess
import threading
import time
import uuid
from contextlib import contextmanager

import cv2
from flask import Flask, Response, g, jsonify, request, send_from_directory
from ultralytics import YOLO
from werkzeug.security import check_password_hash, generate_password_hash

SERVER_VERSION = "v6-camera-fix"

# ===== SETTINGS (change here) =====
MODEL_PATH = "yolov8n-pose.pt"   # use the same model file as your FYP 1
CONF = 0.75                      # same threshold as your thesis
IMGSZ = 320                      # AI input size. 320 = fast. 640 = slower but better far away
FRAME_W, FRAME_H = 320, 240      # size given to the AI
HOLD_SECONDS = 2.0               # keep "person detected" for 2s so it does not flicker
EVENT_COOLDOWN = 10              # seconds between saved alert photos (your 10-second throttle)
PORT = 5000
CLIP_SECONDS = 10
DEFAULT_LOCATION = "Rumah"       # place name on the timestamp (owner can change it in the app)
SESSION_DAYS = 7                 # how long a login lasts
MAX_FAILS = 5                    # wrong passwords before the account is locked
LOCK_MINUTES = 5                 # how long the lock lasts
INVITE_HOURS = 24                # how long an invite code works
# Which camera to use. Windows renumbers cameras when devices are plugged in or your phone
# links to the laptop, so choosing by NAME is safer than by number.
# Run list_cameras.py to see the names.
CAMERA_NAME = "USB2.0 PC CAMERA"  # part of the camera's name. Use "" to choose by CAMERA_INDEX instead
CAMERA_INDEX = 0                  # only used when CAMERA_NAME is ""
# Folder where Flutter puts the built app (made by: flutter build web --release)
WEB_DIR = r"C:\Users\HP\Desktop\USIM\SEM 7\Final Year Project II\fyp_security_app\build\web"
# ==================================

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CAPTURE_DIR = os.path.join(BASE_DIR, "captures")
EVIDENCE_DIR = os.path.join(BASE_DIR, "incident_evidence")
DB_PATH = os.path.join(BASE_DIR, "smartcam.db")
COOKIE = "smartcam_session"
os.makedirs(CAPTURE_DIR, exist_ok=True)
os.makedirs(EVIDENCE_DIR, exist_ok=True)

app = Flask(__name__, static_folder=WEB_DIR, static_url_path="")
model = YOLO(MODEL_PATH)
lock = threading.Lock()
auth_lock = threading.Lock()
latest_jpeg = None     # small picture with boxes (live view)
latest_raw = None      # full-size camera frame (photos and alert evidence)
last_seen = 0.0
last_event_time = 0.0
grabber = None
location_name = DEFAULT_LOCATION
H264_OK = False
state = {
    "human_detected": False,
    "confidence": 0.0,
    "ai_active": False,
    "camera_ok": False,
    "night_vision": False,
    "siren": False,
    "recording": False,
    "last_event": "",
    "fps": 0.0,
    "infer_ms": 0,
    "camera_name": "",
}
recorder = {"active": False, "frames": [], "start": 0.0, "name": None}
schedules = []
sched_lock = threading.Lock()


# =====================================================================
# Database, accounts and login
# =====================================================================
@contextmanager
def db():
    conn = sqlite3.connect(DB_PATH, timeout=10)
    conn.row_factory = sqlite3.Row
    try:
        yield conn
        conn.commit()
    finally:
        conn.close()


def init_db():
    with db() as c:
        c.executescript(
            """
            CREATE TABLE IF NOT EXISTS users(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                email TEXT UNIQUE NOT NULL,
                name TEXT NOT NULL,
                pw_hash TEXT NOT NULL,
                role TEXT NOT NULL,
                fails INTEGER NOT NULL DEFAULT 0,
                locked_until REAL NOT NULL DEFAULT 0,
                created REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS sessions(
                token_hash TEXT PRIMARY KEY,
                user_id INTEGER NOT NULL,
                expires REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS invites(
                code TEXT PRIMARY KEY,
                created_by INTEGER NOT NULL,
                expires REAL NOT NULL,
                used INTEGER NOT NULL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS audit(
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                ts REAL NOT NULL,
                email TEXT,
                event TEXT NOT NULL,
                ip TEXT
            );
            CREATE TABLE IF NOT EXISTS settings(
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            """
        )


def get_setting(key, default=""):
    with db() as c:
        r = c.execute("SELECT value FROM settings WHERE key=?", (key,)).fetchone()
    return r["value"] if r else default


def set_setting(key, value):
    with db() as c:
        c.execute(
            "INSERT INTO settings(key, value) VALUES(?, ?) "
            "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            (key, value),
        )


def audit(event, email=""):
    # Security log: who did what, and from which address.
    try:
        with db() as c:
            c.execute(
                "INSERT INTO audit(ts, email, event, ip) VALUES(?, ?, ?, ?)",
                (time.time(), email, event, request.remote_addr),
            )
    except Exception as e:
        print("audit error:", e)


EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
BAD_LOGIN = "Incorrect email or password."
DUMMY_HASH = generate_password_hash("dummy-password-for-timing")


def password_problem(pw):
    if len(pw) < 8:
        return "Password must be at least 8 characters."
    if len(pw) > 128:
        return "Password is too long."
    if not re.search(r"[A-Za-z]", pw) or not re.search(r"\d", pw):
        return "Password must contain at least one letter and one number."
    return None


def err(message, code=400):
    return jsonify(error=message), code


def token_hash(token):
    return hashlib.sha256(token.encode()).hexdigest()


def new_session(user_id):
    token = secrets.token_urlsafe(32)
    now = time.time()
    with db() as c:
        c.execute(
            "INSERT INTO sessions(token_hash, user_id, expires) VALUES(?, ?, ?)",
            (token_hash(token), user_id, now + SESSION_DAYS * 86400),
        )
        c.execute("DELETE FROM sessions WHERE expires < ?", (now,))
    return token


def request_token():
    token = request.cookies.get(COOKIE)
    if token:
        return token
    header = request.headers.get("Authorization", "")
    if header.startswith("Bearer "):
        return header[7:]
    return None


def current_user():
    token = request_token()
    if not token:
        return None
    with db() as c:
        row = c.execute(
            "SELECT u.id, u.email, u.name, u.role FROM sessions s "
            "JOIN users u ON u.id = s.user_id "
            "WHERE s.token_hash=? AND s.expires>?",
            (token_hash(token), time.time()),
        ).fetchone()
    return dict(row) if row else None


def login_required(fn):
    @functools.wraps(fn)
    def wrapper(*args, **kwargs):
        user = current_user()
        if user is None:
            return err("Please log in.", 401)
        g.user = user
        return fn(*args, **kwargs)

    return wrapper


def owner_required(fn):
    @functools.wraps(fn)
    def wrapper(*args, **kwargs):
        user = current_user()
        if user is None:
            return err("Please log in.", 401)
        if user["role"] != "owner":
            return err("Only the owner can do this.", 403)
        g.user = user
        return fn(*args, **kwargs)

    return wrapper


def start_session(user_id):
    token = new_session(user_id)
    with db() as c:
        u = c.execute(
            "SELECT id, email, name, role FROM users WHERE id=?", (user_id,)
        ).fetchone()
    resp = jsonify(user=dict(u), token=token)  # token is used by the phone app
    resp.set_cookie(
        COOKIE, token, max_age=SESSION_DAYS * 86400, httponly=True, samesite="Lax"
    )
    return resp


@app.after_request
def security_headers(resp):
    resp.headers["X-Content-Type-Options"] = "nosniff"
    resp.headers["X-Frame-Options"] = "DENY"
    resp.headers["Referrer-Policy"] = "no-referrer"
    if request.path.startswith("/api/"):
        resp.headers["Cache-Control"] = "no-store"
    return resp


@app.route("/api/auth/state")
def auth_state():
    with db() as c:
        n = c.execute("SELECT COUNT(*) AS n FROM users").fetchone()["n"]
    return jsonify(has_users=n > 0, version=SERVER_VERSION, h264=H264_OK)


@app.route("/api/auth/signup", methods=["POST"])
def signup():
    d = request.get_json(silent=True) or {}
    name = str(d.get("name", "")).strip()[:40]
    email = str(d.get("email", "")).strip().lower()[:120]
    pw = str(d.get("password", ""))
    invite = str(d.get("invite", "")).strip().upper()

    if not name:
        return err("Please enter your name.")
    if not EMAIL_RE.match(email):
        return err("Please enter a valid email address.")
    problem = password_problem(pw)
    if problem:
        return err(problem)

    error = None
    uid = None
    with auth_lock:
        with db() as c:
            n = c.execute("SELECT COUNT(*) AS n FROM users").fetchone()["n"]
            role = "owner" if n == 0 else "member"
            if n > 0:
                inv = c.execute(
                    "SELECT code FROM invites WHERE code=? AND used=0 AND expires>?",
                    (invite, time.time()),
                ).fetchone()
            else:
                inv = None
            if n > 0 and inv is None:
                error = ("Invalid or expired invite code.", 403)
            elif c.execute("SELECT 1 FROM users WHERE email=?", (email,)).fetchone():
                error = ("An account with this email already exists.", 409)
            else:
                cur = c.execute(
                    "INSERT INTO users(email, name, pw_hash, role, created) "
                    "VALUES(?, ?, ?, ?, ?)",
                    (email, name, generate_password_hash(pw), role, time.time()),
                )
                uid = cur.lastrowid
                if n > 0:
                    c.execute("UPDATE invites SET used=1 WHERE code=?", (invite,))

    if error:
        audit("signup_rejected", email)
        return err(error[0], error[1])
    audit("signup_" + role, email)
    return start_session(uid)


@app.route("/api/auth/login", methods=["POST"])
def login():
    d = request.get_json(silent=True) or {}
    email = str(d.get("email", "")).strip().lower()[:120]
    pw = str(d.get("password", ""))[:128]

    with db() as c:
        u = c.execute("SELECT * FROM users WHERE email=?", (email,)).fetchone()

    if u is None:
        check_password_hash(DUMMY_HASH, pw)  # same time as a real check
        audit("login_failed", email)
        return err(BAD_LOGIN, 401)

    now = time.time()
    if u["locked_until"] > now:
        minutes = int((u["locked_until"] - now) // 60) + 1
        audit("login_blocked", email)
        return err(f"Too many attempts. Try again in {minutes} minute(s).", 429)

    if not check_password_hash(u["pw_hash"], pw):
        fails = u["fails"] + 1
        locked = now + LOCK_MINUTES * 60 if fails >= MAX_FAILS else 0
        with db() as c:
            c.execute(
                "UPDATE users SET fails=?, locked_until=? WHERE id=?",
                (0 if locked else fails, locked, u["id"]),
            )
        audit("account_locked" if locked else "login_failed", email)
        return err(BAD_LOGIN, 401)

    with db() as c:
        c.execute("UPDATE users SET fails=0, locked_until=0 WHERE id=?", (u["id"],))
    audit("login", email)
    return start_session(u["id"])


@app.route("/api/auth/logout", methods=["POST"])
def logout():
    token = request_token()
    user = current_user()
    if token:
        with db() as c:
            c.execute("DELETE FROM sessions WHERE token_hash=?", (token_hash(token),))
    if user:
        audit("logout", user["email"])
    resp = jsonify(ok=True)
    resp.delete_cookie(COOKIE)
    return resp


@app.route("/api/auth/me")
@login_required
def me():
    return jsonify(user=g.user)


@app.route("/api/auth/invite", methods=["POST"])
@owner_required
def create_invite():
    code = secrets.token_hex(4).upper()
    with db() as c:
        c.execute(
            "INSERT INTO invites(code, created_by, expires) VALUES(?, ?, ?)",
            (code, g.user["id"], time.time() + INVITE_HOURS * 3600),
        )
    audit("invite_created", g.user["email"])
    return jsonify(code=code, hours=INVITE_HOURS)


@app.route("/api/auth/activity")
@owner_required
def activity():
    with db() as c:
        rows = c.execute(
            "SELECT ts, email, event, ip FROM audit ORDER BY id DESC LIMIT 30"
        ).fetchall()
    return jsonify([dict(r) for r in rows])


@app.route("/api/settings", methods=["GET", "POST"])
@login_required
def settings():
    global location_name
    if request.method == "GET":
        return jsonify(location=location_name)
    if g.user["role"] != "owner":
        return err("Only the owner can do this.", 403)
    d = request.get_json(silent=True) or {}
    value = re.sub(r"[^\x20-\x7E]", "", str(d.get("location", ""))).strip()[:24]
    if not value:
        return err("Please enter a name.")
    location_name = value
    set_setting("location", value)
    audit("location_changed", g.user["email"])
    return jsonify(location=value)


# =====================================================================
# Camera
# =====================================================================
_names_cache = None
_last_say = ""


def say(msg):
    # Print a message only when it changes, so the window does not fill with repeats.
    global _last_say
    if msg != _last_say:
        print(msg)
        _last_say = msg


def list_cameras():
    """Names of the cameras Windows knows, in the same order OpenCV uses for the index."""
    global _names_cache
    try:
        import comtypes

        try:
            comtypes.CoInitialize()  # needed when this runs in a background thread
        except Exception:
            pass
        from pygrabber.dshow_graph import FilterGraph

        _names_cache = list(FilterGraph().get_input_devices())
    except Exception as e:
        say(f"Could not read camera names ({e}). Run: python -m pip install pygrabber")
    return _names_cache


def open_camera():
    """Opens the camera chosen in CAMERA_NAME (or CAMERA_INDEX).
    It NEVER falls back to another camera, so the laptop's own camera is never shown by mistake.
    Returns (camera, name), or (None, "") when the camera is not available."""
    names = list_cameras()
    if CAMERA_NAME:
        if not names:
            say("CAMERA_NAME is set but camera names are unavailable. Run: python -m pip install pygrabber")
            return None, ""
        index = next((i for i, n in enumerate(names) if CAMERA_NAME.lower() in n.lower()), None)
        if index is None:
            found = ", ".join(f"[{i}] {n}" for i, n in enumerate(names)) or "none"
            say(f"Camera '{CAMERA_NAME}' not found. Cameras found: {found}. "
                "Plug it in, or change CAMERA_NAME at the top of edge_server.py.")
            return None, ""
    else:
        index = CAMERA_INDEX

    label = names[index] if names and 0 <= index < len(names) else f"camera {index}"
    cap = cv2.VideoCapture(index, cv2.CAP_DSHOW)
    if cap.isOpened():
        cap.set(cv2.CAP_PROP_FRAME_WIDTH, 640)
        cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)
        cap.set(cv2.CAP_PROP_FOURCC, cv2.VideoWriter_fourcc(*"MJPG"))
        cap.set(cv2.CAP_PROP_BUFFERSIZE, 1)
        ok, frame = cap.read()
        if ok and frame is not None and frame.size > 0:
            say(f"USING camera [{index}] {label}")
            return cap, label
    cap.release()
    say(f"Could not read from [{index}] {label}. Is another app using it (Camera app, video call)?")
    return None, ""


class Grabber:
    """Reads the camera all the time and keeps ONLY the newest frame (this prevents lag)."""

    def __init__(self):
        self.frame = None
        self.seq = 0
        self.ok = False
        self.name = ""
        self._lock = threading.Lock()
        threading.Thread(target=self._run, daemon=True).start()

    def _run(self):
        cap = None
        fails = 0
        while True:
            if cap is None:
                self.ok = False
                cap, self.name = open_camera()
                if cap is None:
                    time.sleep(3)
                    continue
                fails = 0
            ok, frame = cap.read()
            if not ok or frame is None:
                fails += 1
                if fails > 10:
                    self.ok = False
                if fails > 30:
                    cap.release()
                    cap = None
                    time.sleep(1)
                else:
                    time.sleep(0.05)
                continue
            fails = 0
            with self._lock:
                self.frame = frame
                self.seq += 1
                self.ok = True

    def get(self):
        with self._lock:
            return self.frame, self.seq, self.ok


def enhance(frame):
    # Software "night mode": grayscale + contrast boost. Not real infrared.
    gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
    gray = cv2.createCLAHE(clipLimit=3.0, tileGridSize=(8, 8)).apply(gray)
    return cv2.cvtColor(gray, cv2.COLOR_GRAY2BGR)


def stamp_frame(img):
    # Yellow "Rumah | Tue 20/10/2026 14:37:45" on the picture, like FYP 1.
    h, w = img.shape[:2]
    text = f"{location_name} | {dt.datetime.now():%a %d/%m/%Y %H:%M:%S}"
    scale = max(0.42, w / 320 * 0.42)
    thick = 1 if w <= 400 else 2
    pos = (6, h - 8)
    cv2.putText(img, text, pos, cv2.FONT_HERSHEY_SIMPLEX, scale, (0, 0, 0), thick + 2, cv2.LINE_AA)
    cv2.putText(img, text, pos, cv2.FONT_HERSHEY_SIMPLEX, scale, (0, 255, 255), thick, cv2.LINE_AA)
    return img


# ---------- photos, clips, alert evidence ----------
def stamp_name(prefix, ext):
    return f"{prefix}_{dt.datetime.now():%Y%m%d_%H%M%S}.{ext}"


def photo_bytes():
    with lock:
        raw = latest_raw
    if raw is None:
        return None
    img = stamp_frame(raw.copy())
    ok, buf = cv2.imencode(".jpg", img, [cv2.IMWRITE_JPEG_QUALITY, 92])
    return buf.tobytes() if ok else None


def save_photo():
    data = photo_bytes()
    if data is None:
        return None
    name = stamp_name("photo", "jpg")
    with open(os.path.join(CAPTURE_DIR, name), "wb") as f:
        f.write(data)
    return name


def check_h264():
    try:
        import imageio_ffmpeg

        imageio_ffmpeg.get_ffmpeg_exe()
        return True
    except Exception:
        return False


def convert_h264(src, dst):
    # Chrome can only play H.264 video, so convert the OpenCV file.
    try:
        import imageio_ffmpeg

        exe = imageio_ffmpeg.get_ffmpeg_exe()
        r = subprocess.run(
            [exe, "-y", "-i", src, "-vcodec", "libx264", "-pix_fmt", "yuv420p",
             "-movflags", "+faststart", dst],
            capture_output=True, timeout=120,
        )
        if r.returncode != 0:
            print("ffmpeg failed:", r.stderr.decode(errors="ignore")[-300:])
        return r.returncode == 0 and os.path.exists(dst)
    except Exception as e:
        print("H.264 conversion skipped:", e)
        return False


def save_clip(frames, name, elapsed):
    fps = max(1.0, len(frames) / max(elapsed, 1.0))
    tmp = os.path.join(CAPTURE_DIR, "tmp_" + name)
    final = os.path.join(CAPTURE_DIR, name)
    h, w = frames[0].shape[:2]
    out = cv2.VideoWriter(tmp, cv2.VideoWriter_fourcc(*"mp4v"), fps, (w, h))
    for f in frames:
        out.write(f)
    out.release()
    if convert_h264(tmp, final):
        try:
            os.remove(tmp)
        except OSError:
            pass
        print("Clip saved (browser-playable):", name)
    else:
        os.replace(tmp, final)
        print("Clip saved but NOT browser-playable. Run: python -m pip install imageio-ffmpeg")


def start_clip():
    with lock:
        if recorder["active"] or latest_jpeg is None:
            return None
        name = stamp_name("clip", "mp4")
        recorder["active"] = True
        recorder["frames"] = []
        recorder["start"] = time.time()
        recorder["name"] = name
        state["recording"] = True
        return name


# ---------- main loop: AI on the newest frame ----------
def camera_loop():
    global latest_jpeg, latest_raw, last_seen, last_event_time
    last_seq = -1
    last_loop = time.time()
    fps = 0.0
    while True:
        raw, seq, cam_ok = grabber.get()
        if raw is None or not cam_ok:
            with lock:
                state["camera_ok"] = False
                state["ai_active"] = False
                state["human_detected"] = False
                latest_jpeg = None   # never show an old picture as if it were live
                latest_raw = None
            time.sleep(0.2)
            continue
        if seq == last_seq:
            time.sleep(0.01)
            continue
        last_seq = seq

        frame = cv2.resize(raw, (FRAME_W, FRAME_H))
        if state["night_vision"]:
            frame = enhance(frame)

        t0 = time.time()
        result = model(frame, conf=CONF, imgsz=IMGSZ, verbose=False)[0]
        infer_ms = int((time.time() - t0) * 1000)
        annotated = result.plot()   # frame with boxes + skeleton drawn on it
        stamp_frame(annotated)      # place, date and time on the live picture
        count = len(result.boxes)
        now = time.time()
        best = float(result.boxes.conf.max()) if count > 0 else 0.0

        dt_loop = max(now - last_loop, 0.001)
        last_loop = now
        fps = 0.9 * fps + 0.1 * (1.0 / dt_loop) if fps else 1.0 / dt_loop

        was_active = state["human_detected"]
        new_event = count > 0 and (not was_active) and (now - last_event_time) >= EVENT_COOLDOWN
        if count > 0:
            last_seen = now

        event_name = None
        if new_event:
            last_event_time = now
            event_name = save_evidence(raw, result.boxes.xyxy.cpu().numpy(), best)

        encoded_ok, buf = cv2.imencode(".jpg", annotated, [cv2.IMWRITE_JPEG_QUALITY, 80])
        finished = None
        with lock:
            latest_raw = raw
            state["camera_ok"] = True
            state["camera_name"] = grabber.name
            state["ai_active"] = True
            state["fps"] = round(fps, 1)
            state["infer_ms"] = infer_ms
            if count > 0:
                state["confidence"] = round(best, 2)
            state["human_detected"] = (now - last_seen) < HOLD_SECONDS
            if event_name:
                state["last_event"] = event_name
            if encoded_ok:
                latest_jpeg = buf.tobytes()
            if recorder["active"]:
                recorder["frames"].append(annotated)
                if now - recorder["start"] >= CLIP_SECONDS:
                    finished = (recorder["frames"], recorder["name"], now - recorder["start"])
                    recorder["active"] = False
                    recorder["frames"] = []
                    state["recording"] = False
        if finished:
            threading.Thread(target=save_clip, args=finished, daemon=True).start()


def siren_loop():
    try:
        import winsound
    except ImportError:
        return
    while True:
        if state["siren"]:
            winsound.Beep(1000, 400)
        else:
            time.sleep(0.2)


def scheduler_loop():
    while True:
        now = dt.datetime.now()
        due = []
        with sched_lock:
            for s in list(schedules):
                if now >= s["run_at"]:
                    due.append(s)
                    schedules.remove(s)
        for s in due:
            print("Running scheduled", s["kind"], s["time"])
            if s["kind"] == "photo":
                save_photo()
            else:
                start_clip()
        time.sleep(1)


# =====================================================================
# Web app and camera API (everything below needs a login)
# =====================================================================
@app.route("/")
def index():
    return send_from_directory(WEB_DIR, "index.html")


@app.route("/status")
@login_required
def status():
    with lock:
        return jsonify(dict(state))


@app.route("/snapshot")
@login_required
def snapshot():
    with lock:
        data = latest_jpeg
    if data is None:
        return ("no frame yet", 503)
    return Response(data, mimetype="image/jpeg")


@app.route("/photo")
@login_required
def photo():
    data = photo_bytes()
    if data is None:
        return ("no frame yet", 503)
    return Response(data, mimetype="image/jpeg")


@app.route("/video_feed")
@login_required
def video_feed():
    def generate():
        while True:
            with lock:
                data = latest_jpeg
            if data:
                yield b"--frame\r\nContent-Type: image/jpeg\r\n\r\n" + data + b"\r\n"
            time.sleep(0.05)

    return Response(generate(), mimetype="multipart/x-mixed-replace; boundary=frame")


@app.route("/siren", methods=["POST"])
@login_required
def siren():
    state["siren"] = not state["siren"]
    audit("siren_on" if state["siren"] else "siren_off", g.user["email"])
    return jsonify(siren=state["siren"])


@app.route("/night_mode", methods=["POST"])
@login_required
def night_mode():
    state["night_vision"] = not state["night_vision"]
    return jsonify(night_vision=state["night_vision"])


@app.route("/clip", methods=["POST"])
@login_required
def clip():
    name = start_clip()
    if name is None:
        return jsonify(error="busy or camera not ready"), 409
    return jsonify(name=name)


@app.route("/schedule", methods=["POST"])
@login_required
def add_schedule():
    kind = request.args.get("kind", "photo")
    t = request.args.get("time", "")
    if kind not in ("photo", "clip"):
        return jsonify(error="bad kind"), 400
    try:
        hh, mm = [int(x) for x in t.split(":")]
        now = dt.datetime.now()
        target = now.replace(hour=hh, minute=mm, second=0, microsecond=0)
    except Exception:
        return jsonify(error="bad time"), 400
    if target <= now:
        target += dt.timedelta(days=1)
    entry = {"id": uuid.uuid4().hex[:8], "kind": kind,
             "time": f"{hh:02d}:{mm:02d}", "run_at": target}
    with sched_lock:
        schedules.append(entry)
    return jsonify(id=entry["id"], kind=kind, time=entry["time"])


@app.route("/schedules")
@login_required
def list_schedules():
    now = dt.datetime.now()
    with sched_lock:
        items = [{"id": s["id"], "kind": s["kind"], "time": s["time"],
                  "tomorrow": s["run_at"].date() != now.date()} for s in schedules]
    return jsonify(items)


@app.route("/schedule/<sid>/delete", methods=["POST"])
@login_required
def delete_schedule(sid):
    with sched_lock:
        schedules[:] = [s for s in schedules if s["id"] != sid]
    return jsonify(ok=True)


@app.route("/captures")
@login_required
def list_captures():
    items = []
    for n in os.listdir(CAPTURE_DIR):
        p = os.path.join(CAPTURE_DIR, n)
        if n.startswith("tmp_") or not os.path.isfile(p):
            continue
        kind = "clip" if n.endswith(".mp4") else "photo"
        items.append({"name": n, "kind": kind, "time": os.path.getmtime(p)})
    items.sort(key=lambda x: x["time"], reverse=True)
    return jsonify(items[:30])


@app.route("/captures/<name>")
@login_required
def get_capture(name):
    return send_from_directory(CAPTURE_DIR, name)


@app.route("/events")
@login_required
def events():
    return jsonify(list_events())


@app.route("/evidence/<name>")
@login_required
def get_evidence(name):
    return send_from_directory(EVIDENCE_DIR, name)


# ---------- delete (owner only, permanent) ----------
def safe_remove(folder, name):
    # Only plain file names are allowed, never paths like ../
    if not name or name != os.path.basename(name) or name.startswith("."):
        return False
    path = os.path.join(folder, name)
    if os.path.isfile(path):
        os.remove(path)
        return True
    return False


@app.route("/api/evidence/<name>/delete", methods=["POST"])
@owner_required
def delete_evidence(name):
    if not name.startswith("alert_") or not safe_remove(EVIDENCE_DIR, name):
        return err("Not found.", 404)
    audit("alert_deleted", g.user["email"])
    return jsonify(ok=True)


@app.route("/api/evidence/delete_all", methods=["POST"])
@owner_required
def delete_all_evidence():
    n = 0
    for f in os.listdir(EVIDENCE_DIR):
        if f.startswith("alert_") and safe_remove(EVIDENCE_DIR, f):
            n += 1
    audit("alerts_deleted_all", g.user["email"])
    return jsonify(deleted=n)


@app.route("/api/captures/<name>/delete", methods=["POST"])
@owner_required
def delete_capture(name):
    if name.startswith("tmp_") or not safe_remove(CAPTURE_DIR, name):
        return err("Not found.", 404)
    audit("capture_deleted", g.user["email"])
    return jsonify(ok=True)


@app.route("/api/captures/delete_all", methods=["POST"])
@owner_required
def delete_all_captures():
    n = 0
    for f in os.listdir(CAPTURE_DIR):
        if not f.startswith("tmp_") and safe_remove(CAPTURE_DIR, f):
            n += 1
    audit("captures_deleted_all", g.user["email"])
    return jsonify(deleted=n)



# =====================================================================
# SNOOZE: owner only, needs the account password.
# The camera KEEPS saving evidence photos while snoozed. Only the
# pop-up alerts are silenced. Snooze ends by itself (max 60 minutes),
# and it is cancelled if the server restarts (fail-secure).
# =====================================================================
SNOOZE_CHOICES = (5, 15, 30, 60)   # minutes
snooze = {"until": 0.0, "count": 0, "by": ""}
last_snooze = {"count": 0, "ended": 0.0}
snooze_lock = threading.Lock()


def _end_snooze_locked():
    last_snooze["count"] = snooze["count"]
    last_snooze["ended"] = time.time()
    snooze["until"] = 0.0
    snooze["count"] = 0
    snooze["by"] = ""


def snooze_active():
    """True while alerts are snoozed. Ends the snooze by itself when time is up.
    (Push notifications will use this too: no push while snoozed.)"""
    with snooze_lock:
        if snooze["until"] and snooze["until"] <= time.time():
            _end_snooze_locked()
        return snooze["until"] > 0


def snooze_add_missed():
    with snooze_lock:
        if snooze["until"] > 0:
            snooze["count"] += 1


def refresh_snooze_state():
    snooze_active()  # ends it if the time is up
    with snooze_lock:
        left = max(1, int(snooze["until"] - time.time())) if snooze["until"] > 0 else 0
        by = snooze["by"]
        count = last_snooze["count"]
        ended = last_snooze["ended"]
    with lock:
        state["snooze_left"] = left
        state["snooze_by"] = by
        state["last_snooze_count"] = count
        state["last_snooze_ended"] = ended


def snooze_loop():
    while True:
        try:
            refresh_snooze_state()
        except Exception as e:
            print("snooze loop error:", e)
        time.sleep(1)


def save_evidence(raw, boxes_xyxy, conf):
    # Photos taken during a snooze get "_s" in the name.
    muted = snooze_active()
    img = raw.copy()
    sx = img.shape[1] / FRAME_W
    sy = img.shape[0] / FRAME_H
    for x1, y1, x2, y2 in boxes_xyxy:
        cv2.rectangle(img, (int(x1 * sx), int(y1 * sy)), (int(x2 * sx), int(y2 * sy)), (0, 0, 255), 2)
    stamp_frame(img)
    tag = "_s" if muted else ""
    name = f"alert_{dt.datetime.now():%Y%m%d_%H%M%S}_{int(round(conf * 100)):02d}{tag}.jpg"
    cv2.imwrite(os.path.join(EVIDENCE_DIR, name), img, [cv2.IMWRITE_JPEG_QUALITY, 90])
    if muted:
        snooze_add_missed()
    return name


def list_events(limit=50):
    # Also tells the app which photos were taken while snoozed.
    names = sorted(
        [n for n in os.listdir(EVIDENCE_DIR) if n.startswith("alert_") and n.endswith(".jpg")],
        reverse=True,
    )[:limit]
    out = []
    for n in names:
        try:
            parts = n[:-4].split("_")
            d, t, c = parts[1], parts[2], parts[3]
            snoozed = len(parts) > 4 and parts[4] == "s"
            ts = dt.datetime.strptime(d + t, "%Y%m%d%H%M%S").timestamp()
            out.append({"name": n, "time": ts, "confidence": int(c) / 100, "snoozed": snoozed})
        except Exception:
            continue
    return out


@app.route("/api/snooze", methods=["POST"])
@owner_required
def api_snooze():
    d = request.get_json(silent=True) or {}
    try:
        minutes = int(d.get("minutes", 0))
    except (TypeError, ValueError):
        minutes = 0
    if minutes not in SNOOZE_CHOICES:
        return err("Choose 5, 15, 30 or 60 minutes.")
    pw = str(d.get("password", ""))[:128]

    with db() as c:
        u = c.execute(
            "SELECT pw_hash, fails, locked_until FROM users WHERE id=?", (g.user["id"],)
        ).fetchone()
    now = time.time()
    if u["locked_until"] > now:
        audit("snooze_blocked", g.user["email"])
        return err("Too many wrong passwords. Try again in a few minutes.", 429)
    if not check_password_hash(u["pw_hash"], pw):
        fails = u["fails"] + 1
        locked = now + LOCK_MINUTES * 60 if fails >= MAX_FAILS else 0
        with db() as c:
            c.execute(
                "UPDATE users SET fails=?, locked_until=? WHERE id=?",
                (0 if locked else fails, locked, g.user["id"]),
            )
        audit("account_locked" if locked else "snooze_denied", g.user["email"])
        return err("Wrong password.", 403)

    with db() as c:
        c.execute("UPDATE users SET fails=0, locked_until=0 WHERE id=?", (g.user["id"],))
    with snooze_lock:
        snooze["until"] = time.time() + minutes * 60
        snooze["by"] = g.user["name"]
    refresh_snooze_state()
    audit(f"snooze_{minutes}min", g.user["email"])
    return jsonify(ok=True, minutes=minutes)


@app.route("/api/snooze/resume", methods=["POST"])
@owner_required
def api_snooze_resume():
    with snooze_lock:
        if snooze["until"] > 0:
            _end_snooze_locked()
    refresh_snooze_state()
    audit("snooze_resumed", g.user["email"])
    return jsonify(ok=True)


threading.Thread(target=snooze_loop, daemon=True).start()

# =====================================================================
# ANIMAL LABELS + SMART SIREN
#
# Animals (bird, cat, dog) only get a green label on the live picture.
# They NEVER make an alert, a notification, a saved photo or a siren sound.
# Cars, motorbikes, bicycles and everything else are ignored.
#
# Siren: when it is switched ON it is "armed". It stays silent until a PERSON
# is detected, then sounds for SIREN_SECONDS. Switched OFF = no sound at all
# (alerts still work). It is muted while alerts are snoozed.
#
# The functions camera_loop and siren_loop below REPLACE the older versions
# with the same names higher up in this file (the old ones are no longer used).
# =====================================================================
SERVER_VERSION = "v7-animals-siren"

ANIMAL_MODEL_PATH = "yolov8n.pt"   # standard model that knows 80 things (downloads once, ~6 MB)
ANIMAL_CLASSES = [14, 15, 16]      # 14 = bird, 15 = cat, 16 = dog. Everything else is ignored
ANIMAL_CONF = 0.50                 # how sure the AI must be before it shows an animal label
ANIMAL_EVERY_N = 3                 # look for animals on every 3rd picture (1 = every picture, slower)
SIREN_SECONDS = 8                  # how long the siren sounds for each person
SIREN_VOLUME = 0.35                # 0.0 (silent) to 1.0 (loudest)

try:
    animal_model = YOLO(ANIMAL_MODEL_PATH)
except Exception as e:
    animal_model = None
    print(f"Animal labels are OFF (could not load {ANIMAL_MODEL_PATH}): {e}")

siren_until = 0.0        # the siren may sound until this time (set when a person arrives)
siren_test_until = 0.0   # the test button makes it sound until this time


def collect_animals(animal_result):
    names = animal_result.names
    found = []
    for box in animal_result.boxes:
        x1, y1, x2, y2 = [int(v) for v in box.xyxy[0].tolist()]
        conf = float(box.conf[0])
        found.append((x1, y1, x2, y2, f"{names[int(box.cls[0])]} {int(conf * 100)}%"))
    return found


def draw_animals(img, animals):
    green = (0, 200, 0)
    for x1, y1, x2, y2, label in animals:
        cv2.rectangle(img, (x1, y1), (x2, y2), green, 2)
        (tw, th), _ = cv2.getTextSize(label, cv2.FONT_HERSHEY_SIMPLEX, 0.5, 1)
        top = max(th + 6, y1)
        cv2.rectangle(img, (x1, top - th - 6), (x1 + tw + 6, top), green, -1)
        cv2.putText(img, label, (x1 + 3, top - 4), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 0, 0), 1, cv2.LINE_AA)


def siren_should_play():
    now = time.time()
    if now < siren_test_until:
        return True                  # the Test button always works
    if not state["siren"]:
        return False                 # switched off = never sounds
    if now >= siren_until:
        return False                 # no person is being announced right now
    return not snooze_active()       # muted while snoozed


def make_siren_wav_file():
    import math
    import struct
    import wave

    path = os.path.join(BASE_DIR, "siren_tone.wav")
    rate = 22050
    data = bytearray()
    for tone in (800, 1100):          # two alternating tones
        for i in range(int(rate * 0.35)):
            v = int(32767 * SIREN_VOLUME * math.sin(2 * math.pi * tone * i / rate))
            data += struct.pack("<h", v)
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(bytes(data))
    return path


def siren_loop():
    # The sound can be cancelled at once, so it stops immediately.
    global siren_until
    try:
        import winsound
    except ImportError:
        return
    path = make_siren_wav_file()
    playing = False
    while True:
        if not state["siren"]:
            siren_until = 0.0        # switching it off cancels any person already announced
        want = siren_should_play()
        if want and not playing:
            winsound.PlaySound(path, winsound.SND_FILENAME | winsound.SND_ASYNC | winsound.SND_LOOP)
            playing = True
        elif not want and playing:
            winsound.PlaySound(None, winsound.SND_PURGE)
            playing = False
        time.sleep(0.05)


@app.route("/api/siren/test", methods=["POST"])
@login_required
def api_siren_test():
    global siren_test_until
    siren_test_until = time.time() + 2.0
    audit("siren_test", g.user["email"])
    return jsonify(ok=True)


def camera_loop():
    # Replaces the older version: adds animal labels and the smart siren.
    global latest_jpeg, latest_raw, last_seen, last_event_time, siren_until
    last_seq = -1
    last_loop = time.time()
    fps = 0.0
    frame_no = 0
    animals = []
    while True:
        raw, seq, cam_ok = grabber.get()
        if raw is None or not cam_ok:
            with lock:
                state["camera_ok"] = False
                state["ai_active"] = False
                state["human_detected"] = False
                latest_jpeg = None   # never show an old picture as if it were live
                latest_raw = None
            time.sleep(0.2)
            continue
        if seq == last_seq:
            time.sleep(0.01)
            continue
        last_seq = seq

        frame = cv2.resize(raw, (FRAME_W, FRAME_H))
        if state["night_vision"]:
            frame = enhance(frame)

        t0 = time.time()
        result = model(frame, conf=CONF, imgsz=IMGSZ, verbose=False)[0]
        infer_ms = int((time.time() - t0) * 1000)
        annotated = result.plot()   # frame with boxes + skeleton drawn on it

        # animals: label only, never an alert
        frame_no += 1
        if animal_model is not None and frame_no % ANIMAL_EVERY_N == 0:
            try:
                ar = animal_model(frame, conf=ANIMAL_CONF, classes=ANIMAL_CLASSES,
                                  imgsz=IMGSZ, verbose=False)[0]
                animals = collect_animals(ar)
            except Exception as e:
                animals = []
                say(f"Animal check problem: {e}")
        draw_animals(annotated, animals)

        stamp_frame(annotated)      # place, date and time on the live picture
        count = len(result.boxes)
        now = time.time()
        best = float(result.boxes.conf.max()) if count > 0 else 0.0

        dt_loop = max(now - last_loop, 0.001)
        last_loop = now
        fps = 0.9 * fps + 0.1 * (1.0 / dt_loop) if fps else 1.0 / dt_loop

        was_active = state["human_detected"]
        new_event = count > 0 and (not was_active) and (now - last_event_time) >= EVENT_COOLDOWN
        if count > 0 and not was_active and state["siren"] and not snooze_active():
            siren_until = now + SIREN_SECONDS   # a person just arrived: sound the siren
        if count > 0:
            last_seen = now

        event_name = None
        if new_event:
            last_event_time = now
            event_name = save_evidence(raw, result.boxes.xyxy.cpu().numpy(), best)

        encoded_ok, buf = cv2.imencode(".jpg", annotated, [cv2.IMWRITE_JPEG_QUALITY, 80])
        finished = None
        with lock:
            latest_raw = raw
            state["camera_ok"] = True
            state["camera_name"] = grabber.name
            state["ai_active"] = True
            state["fps"] = round(fps, 1)
            state["infer_ms"] = infer_ms
            if count > 0:
                state["confidence"] = round(best, 2)
            state["human_detected"] = (now - last_seen) < HOLD_SECONDS
            if event_name:
                state["last_event"] = event_name
            if encoded_ok:
                latest_jpeg = buf.tobytes()
            if recorder["active"]:
                recorder["frames"].append(annotated)
                if now - recorder["start"] >= CLIP_SECONDS:
                    finished = (recorder["frames"], recorder["name"], now - recorder["start"])
                    recorder["active"] = False
                    recorder["frames"] = []
                    state["recording"] = False
        if finished:
            threading.Thread(target=save_clip, args=finished, daemon=True).start()

if __name__ == "__main__":
    init_db()
    location_name = get_setting("location", DEFAULT_LOCATION)
    H264_OK = check_h264()
    latest = list_events(1)
    state["last_event"] = latest[0]["name"] if latest else ""
    list_cameras()
    grabber = Grabber()
    threading.Thread(target=camera_loop, daemon=True).start()
    threading.Thread(target=siren_loop, daemon=True).start()
    threading.Thread(target=scheduler_loop, daemon=True).start()
    print("=" * 60)
    print(f" AI SmartCam server {SERVER_VERSION}")
    print(f" Video clips: {'OK (H.264 converter found)' if H264_OK else 'NOT PLAYABLE. Run: python -m pip install imageio-ffmpeg'}")
    print(f" App: http://127.0.0.1:{PORT}")
    print("=" * 60)
    app.run(host="0.0.0.0", port=PORT, threaded=True)