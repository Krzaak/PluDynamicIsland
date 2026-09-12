#!/usr/bin/env python3
"""
Mostek między wyspą (Quickshell) a lokalnym RPC Discorda.

Dlaczego osobny proces: Discord rozmawia po gnieździe unixowym ramkami binarnymi
[op u32le][len u32le][json], a Quickshell.Io.Socket pisze i czyta wyłącznie tekst
(write(QString) + SplitParser). Bajty nagłówka >= 0x80 i NUL przeszłyby przez UTF-8
i się rozjechały. Ten skrypt tłumaczy ramki na JSON linia po linii:

  stdout -> QML : {"type":"state", connected, inVoice, channelName, muted,
                   deafened, callStart, error}      (zawsze pełna migawka)
                  {"type":"log", "text": "..."}
  stdin  <- QML : {"cmd":"mute","value":true} | {"cmd":"deafen","value":false}
                  | {"cmd":"leave"}

Jednorazowa konfiguracja:
  1. discord.com/developers -> New Application -> skopiuj Client ID.
  2. Zakładka OAuth2 -> Redirects -> dodaj  http://localhost  -> skopiuj Client Secret.
  3. Zapisz ~/.config/quickshell-island/discord.json:
       {"client_id": "...", "client_secret": "..."}
  4. Przy pierwszym połączeniu Discord może pokazać okno zgody. Token ląduje obok,
     w discord_token (0600), i jest używany przy kolejnych startach.

Kody wyjścia: 0 = rodzic zamknął stdin (normalne), 3 = brak konfiguracji (QML nie
restartuje). Rozłączenie z Discordem NIE kończy procesu — mostek czeka i łączy się
ponownie sam.
"""

import json
import os
import selectors
import socket
import struct
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

# ---------------------------------------------------------------
# Ustawienia
# ---------------------------------------------------------------

CONFIG_DIR = os.path.expanduser("~/.config/quickshell-island")
CONFIG_PATH = os.path.join(CONFIG_DIR, "discord.json")
TOKEN_PATH = os.path.join(CONFIG_DIR, "discord_token")

SOCKET_RETRY_S = 5       # co ile szukać gniazda, gdy Discord nie działa
AUTH_FAIL_WAIT_S = 60    # przerwa po dwóch nieudanych autoryzacjach z rzędu
HTTP_TIMEOUT_S = 10
API = "https://discord.com/api"

# ---------------------------------------------------------------
# Wyjście do QML
# ---------------------------------------------------------------

state = {
    "connected": False,
    "inVoice": False,
    "channelName": "",
    "muted": False,
    "deafened": False,
    "callStart": 0,
    "error": "",
}


def emit(obj):
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def emit_state():
    emit({"type": "state", **state})


def set_state(**kw):
    changed = False
    for k, v in kw.items():
        if state.get(k) != v:
            state[k] = v
            changed = True
    if changed:
        emit_state()


def log(text):
    emit({"type": "log", "text": text})


# ---------------------------------------------------------------
# Konfiguracja i token
# ---------------------------------------------------------------

def load_config():
    try:
        with open(CONFIG_PATH) as f:
            cfg = json.load(f)
        cid = str(cfg.get("client_id", "")).strip()
        secret = str(cfg.get("client_secret", "")).strip()
        if cid and secret:
            return cid, secret
    except (OSError, ValueError):
        pass
    return None


def load_token():
    try:
        with open(TOKEN_PATH) as f:
            return f.read().strip()
    except OSError:
        return ""


def save_token(token):
    os.makedirs(CONFIG_DIR, mode=0o700, exist_ok=True)
    fd = os.open(TOKEN_PATH, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(token)


def delete_token():
    try:
        os.remove(TOKEN_PATH)
    except OSError:
        pass


def http_post_form(url, fields):
    """POST x-www-form-urlencoded. Zwraca dict albo None. Nie loguje treści żądania,
    bo zawiera client_secret."""
    body = urllib.parse.urlencode(fields).encode()
    req = urllib.request.Request(url, data=body, method="POST")
    req.add_header("Content-Type", "application/x-www-form-urlencoded")
    # Cloudflare przed API Discorda odrzuca domyślny UA urllib ("Python-urllib/3.x")
    # kodem 403 / error 1010. Dowolny inny identyfikator przechodzi.
    req.add_header("User-Agent", "quickshell-island/1.0")
    try:
        with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT_S) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        try:
            detail = e.read().decode()[:200]
        except Exception:
            detail = ""
        log(f"HTTP {e.code} z {url.rsplit('/', 1)[-1]}: {detail}")
    except (urllib.error.URLError, OSError, ValueError) as e:
        log(f"HTTP błąd z {url.rsplit('/', 1)[-1]}: {e}")
    return None


# ---------------------------------------------------------------
# Gniazdo Discorda
# ---------------------------------------------------------------

def socket_candidates():
    runtime = os.environ.get("XDG_RUNTIME_DIR", "")
    dirs = []
    if runtime:
        dirs += [
            runtime,
            os.path.join(runtime, "app", "com.discordapp.Discord"),
            os.path.join(runtime, "snap.discord"),
        ]
    dirs.append("/tmp")
    for d in dirs:
        for n in range(10):
            yield os.path.join(d, f"discord-ipc-{n}")


def find_socket():
    for p in socket_candidates():
        if os.path.exists(p):
            return p
    return None


class StdinClosed(Exception):
    """Rodzic (Quickshell) zamknął stdin — czas się zwinąć."""


class Disconnected(Exception):
    """Discord zamknął gniazdo albo padło połączenie."""


class AuthFailed(Exception):
    """Dwie nieudane autoryzacje z rzędu."""


class Bridge:
    def __init__(self, client_id, client_secret):
        self.client_id = client_id
        self.client_secret = client_secret
        self.sel = selectors.DefaultSelector()
        self.sel.register(sys.stdin.fileno(), selectors.EVENT_READ, "stdin")
        self.stdin_buf = b""
        self.sock = None
        self.sock_buf = b""
        self.nonce = 0
        self.authenticated = False
        self.my_user_id = ""
        self.channel_id = ""
        self.used_saved_token = False
        self.auth_attempts = 0

    # ---- stdin ----

    def read_stdin(self):
        chunk = os.read(sys.stdin.fileno(), 4096)
        if not chunk:
            raise StdinClosed()
        self.stdin_buf += chunk
        while b"\n" in self.stdin_buf:
            line, self.stdin_buf = self.stdin_buf.split(b"\n", 1)
            line = line.strip()
            if not line:
                continue
            try:
                self.handle_command(json.loads(line))
            except ValueError:
                log(f"śmieci na stdin: {line[:80]!r}")

    def handle_command(self, cmd):
        name = cmd.get("cmd")
        if not self.authenticated:
            log(f"komenda {name} odrzucona: brak połączenia z Discordem")
            return
        if name == "mute":
            value = bool(cmd.get("value"))
            self.rpc("SET_VOICE_SETTINGS", {"mute": value})
            set_state(muted=value)   # optymistycznie; zdarzenie i tak to potwierdzi
        elif name == "deafen":
            value = bool(cmd.get("value"))
            self.rpc("SET_VOICE_SETTINGS", {"deaf": value})
            set_state(deafened=value)
        elif name == "leave":
            if self.channel_id:
                self.rpc("SELECT_VOICE_CHANNEL", {"channel_id": None})
        else:
            log(f"nieznana komenda: {name}")

    # ---- ramki ----

    def send(self, op, payload):
        data = json.dumps(payload).encode()
        try:
            self.sock.sendall(struct.pack("<II", op, len(data)) + data)
        except OSError as e:
            raise Disconnected(str(e))

    def rpc(self, cmd, args):
        self.nonce += 1
        self.send(1, {"cmd": cmd, "args": args, "nonce": str(self.nonce)})

    def subscribe(self, evt, args=None, on=True):
        self.nonce += 1
        self.send(1, {
            "cmd": "SUBSCRIBE" if on else "UNSUBSCRIBE",
            "evt": evt,
            "args": args or {},
            "nonce": str(self.nonce),
        })

    def read_socket(self):
        try:
            chunk = self.sock.recv(65536)
        except OSError as e:
            raise Disconnected(str(e))
        if not chunk:
            raise Disconnected("EOF")
        self.sock_buf += chunk
        while len(self.sock_buf) >= 8:
            op, length = struct.unpack("<II", self.sock_buf[:8])
            if len(self.sock_buf) < 8 + length:
                break
            body = self.sock_buf[8:8 + length]
            self.sock_buf = self.sock_buf[8 + length:]
            try:
                msg = json.loads(body.decode()) if length else {}
            except ValueError:
                log("nieczytelna ramka od Discorda, pomijam")
                continue
            self.handle_frame(op, msg)

    def handle_frame(self, op, msg):
        if op == 2:
            raise Disconnected(f"Discord zamknął połączenie: {msg.get('message', '')}")
        if op == 3:              # ping -> pong
            self.send(4, msg)
            return
        if op != 1:
            return

        cmd = msg.get("cmd")
        evt = msg.get("evt")
        data = msg.get("data") or {}

        if evt == "ERROR":
            self.handle_error(cmd, data)
            return

        if cmd == "DISPATCH":
            if evt == "READY":
                self.my_user_id = str((data.get("user") or {}).get("id", ""))
                log(f"READY, użytkownik {(data.get('user') or {}).get('username', '?')}")
                self.authorize()
            else:
                self.handle_event(evt, data)
        elif cmd == "AUTHORIZE":
            code = data.get("code")
            if not code:
                log("AUTHORIZE bez kodu")
                self.auth_failed()
                return
            # Discord unieważnia kod, gdy wymiana się ociąga, więc HTTP od razu tutaj,
            # zanim wrócimy do pętli select.
            resp = http_post_form(f"{API}/oauth2/token", {
                "client_id": self.client_id,
                "client_secret": self.client_secret,
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": "http://localhost",
            })
            token = (resp or {}).get("access_token")
            if not token:
                self.auth_failed()
                return
            save_token(token)
            self.used_saved_token = False
            self.rpc("AUTHENTICATE", {"access_token": token})
        elif cmd == "AUTHENTICATE":
            if data.get("user"):
                self.my_user_id = str(data["user"].get("id", self.my_user_id))
                self.authenticated = True
                self.auth_attempts = 0
                log(f"uwierzytelniono jako {data['user'].get('username', '?')}")
                set_state(connected=True, error="")
                self.subscribe("VOICE_SETTINGS_UPDATE")
                self.subscribe("VOICE_CHANNEL_SELECT")
                self.rpc("GET_VOICE_SETTINGS", {})
                self.rpc("GET_SELECTED_VOICE_CHANNEL", {})
            else:
                self.handle_error(cmd, data)
        elif cmd == "GET_SELECTED_VOICE_CHANNEL" or cmd == "SELECT_VOICE_CHANNEL":
            self.apply_channel(msg.get("data"))
        elif cmd in ("GET_VOICE_SETTINGS", "SET_VOICE_SETTINGS"):
            self.apply_voice_settings(data)

    def handle_error(self, cmd, data):
        message = data.get("message", "?")
        log(f"błąd RPC ({cmd}): {message}")
        if cmd == "AUTHENTICATE":
            # Token wygasł albo został cofnięty — kasujemy i idziemy pełną ścieżką.
            delete_token()
            if self.used_saved_token:
                self.used_saved_token = False
                self.authorize()
            else:
                self.auth_failed()
        elif cmd == "AUTHORIZE":
            self.auth_failed()

    def auth_failed(self):
        self.auth_attempts += 1
        if self.auth_attempts >= 2:
            raise AuthFailed()
        log("autoryzacja nieudana, ponawiam raz")
        self.authorize()

    # ---- autoryzacja ----

    def authorize(self):
        saved = load_token()
        if saved:
            self.used_saved_token = True
            self.rpc("AUTHENTICATE", {"access_token": saved})
            return

        args = {"client_id": self.client_id, "scopes": ["rpc", "identify"]}
        # rpc_token omija okno zgody — działa dla właściciela aplikacji. Bez niego
        # Discord pokaże okno zgody, co też jest w porządku, tylko wymaga kliknięcia.
        resp = http_post_form(f"{API}/oauth2/token/rpc", {
            "client_id": self.client_id,
            "client_secret": self.client_secret,
        })
        rpc_token = (resp or {}).get("rpc_token")
        if rpc_token:
            args["rpc_token"] = rpc_token
        else:
            log("brak rpc_token, Discord pokaże okno zgody")
        self.rpc("AUTHORIZE", args)

    # ---- stan głosowy ----

    def apply_voice_settings(self, data):
        if not isinstance(data, dict):
            return
        set_state(
            muted=bool(data.get("mute", state["muted"])),
            deafened=bool(data.get("deaf", state["deafened"])),
        )

    def apply_channel(self, channel):
        if not channel or not channel.get("id"):
            self.leave_channel_state()
            return

        new_id = str(channel["id"])
        if self.channel_id and self.channel_id != new_id:
            self.subscribe("VOICE_STATE_UPDATE", {"channel_id": self.channel_id}, on=False)
        if self.channel_id != new_id:
            self.subscribe("VOICE_STATE_UPDATE", {"channel_id": new_id})
        self.channel_id = new_id

        me = None
        for vs in channel.get("voice_states") or []:
            if str((vs.get("user") or {}).get("id", "")) == self.my_user_id:
                me = vs.get("voice_state") or {}
                break

        kw = {
            "inVoice": True,
            "channelName": channel.get("name") or "Kanał głosowy",
        }
        if me is not None:
            kw["muted"] = bool(me.get("self_mute", state["muted"]))
            kw["deafened"] = bool(me.get("self_deaf", state["deafened"]))
        if not state["inVoice"]:
            kw["callStart"] = int(time.time() * 1000)
        set_state(**kw)

    def leave_channel_state(self):
        if self.channel_id:
            try:
                self.subscribe("VOICE_STATE_UPDATE", {"channel_id": self.channel_id}, on=False)
            except Disconnected:
                pass
            self.channel_id = ""
        set_state(inVoice=False, channelName="", callStart=0)

    def handle_event(self, evt, data):
        if evt == "VOICE_CHANNEL_SELECT":
            if data.get("channel_id"):
                self.rpc("GET_SELECTED_VOICE_CHANNEL", {})
            else:
                self.leave_channel_state()
        elif evt == "VOICE_SETTINGS_UPDATE":
            self.apply_voice_settings(data)
        elif evt == "VOICE_STATE_UPDATE":
            if str((data.get("user") or {}).get("id", "")) != self.my_user_id:
                return
            vs = data.get("voice_state") or {}
            set_state(
                muted=bool(vs.get("self_mute", state["muted"])),
                deafened=bool(vs.get("self_deaf", state["deafened"])),
            )

    # ---- pętle ----

    def wait(self, seconds):
        """Czekanie, które nadal obsługuje stdin (żeby zauważyć zamknięcie rodzica)."""
        deadline = time.monotonic() + seconds
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return
            for key, _ in self.sel.select(timeout=remaining):
                if key.data == "stdin":
                    self.read_stdin()

    def session(self, path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(5)
        self.sock.connect(path)
        self.sock.settimeout(None)
        self.sock_buf = b""
        self.authenticated = False
        self.channel_id = ""
        self.auth_attempts = 0
        self.sel.register(self.sock, selectors.EVENT_READ, "sock")
        log(f"gniazdo połączone: {path}")
        try:
            self.send(0, {"v": 1, "client_id": self.client_id})
            while True:
                for key, _ in self.sel.select(timeout=1.0):
                    if key.data == "stdin":
                        self.read_stdin()
                    else:
                        self.read_socket()
        finally:
            self.sel.unregister(self.sock)
            try:
                self.sock.close()
            except OSError:
                pass
            self.sock = None
            self.authenticated = False
            self.channel_id = ""
            set_state(connected=False, inVoice=False, channelName="", callStart=0)

    def run(self):
        emit_state()
        while True:
            path = find_socket()
            if not path:
                set_state(error="Discord nie działa")
                self.wait(SOCKET_RETRY_S)
                continue
            try:
                self.session(path)
            except (Disconnected, OSError) as e:
                log(f"rozłączono: {e}")
                set_state(error="Discord nie działa")
                self.wait(SOCKET_RETRY_S)
            except AuthFailed:
                log(f"autoryzacja nieudana dwa razy, przerwa {AUTH_FAIL_WAIT_S} s")
                set_state(error="autoryzacja nieudana")
                self.wait(AUTH_FAIL_WAIT_S)


def main():
    cfg = load_config()
    if cfg is None:
        set_state(error="brak konfiguracji")
        log(f"brak {CONFIG_PATH} (client_id + client_secret), mostek wyłączony")
        return 3
    try:
        Bridge(*cfg).run()
    except (StdinClosed, KeyboardInterrupt):
        pass
    except BrokenPipeError:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
