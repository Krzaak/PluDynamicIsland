#!/usr/bin/env python3
"""
Mostek między wyspą (Quickshell) a AirPodsami.

Bateria, czujnik ucha i tryb redukcji hałasu idą własnym protokołem Apple (AAP)
po kanale L2CAP (PSM 0x1001), a nie po niczym, co BlueZ wystawia przez D-Bus.
Quickshell nie ma gniazd Bluetooth, więc rozmawia z nimi ten skrypt. Protokół
za projektem LibrePods (github.com/kavishdevar/librepods), potwierdzony
pomiarem na A3439 (product id 0x2030) — patrz README.

Mostek sam pilnuje BlueZ przez D-Bus: gdy połączy się urządzenie z usługą AAP
(UUID niżej), otwiera kanał; gdy się rozłączy, zamyka. QML nie musi nic wiedzieć
o tym, które urządzenie to AirPodsy.

  stdout -> QML : {"type":"state", connected, name, address, noiseMode,
                   left/right/case: {level, charging, live}, leftEar, rightEar}
                  {"type":"log", "text": "..."}
                  {"type":"media", "action":"playpause|next|previous"}
  stdin  <- QML : {"cmd":"mode","value":"off|anc|transparency|adaptive"}
                  {"cmd":"playback","playing":bool}

Klik w nóżkę: AirPodsy 5 NIE rozpoznają same podwójnego/potrójnego kliku —
każde wciśnięcie wysyłają osobno jako AVRCP play/pauza, a gest liczy host
(iPhone). BlueZ zamienia to domyślnie na klawisz multimedialny i KDE wykonuje
każde wciśnięcie od razu, więc podwójny klik = pauza + wznowienie. Dlatego na
czas połączenia mostek rejestruje w BlueZ własny odtwarzacz (Media1.RegisterPlayer,
jak mpris-proxy): komendy AVRCP trafiają wtedy do niego zamiast na klawiaturę
(zmierzone: KDE nie dostaje wtedy nic), mostek liczy wciśnięcia i wysyła QML-owi
gotową akcję — wyspa wykonuje ją na wybranym przez siebie odtwarzaczu.

level = -1, gdy nigdy nie przyszedł odczyt; live = false, gdy element nie
raportuje (etui zamknięte / poza zasięgiem) i level to ostatnia znana wartość.
Ucho: "ear" | "out" | "case" | "" (nieznane).

Kod wyjścia 0 = rodzic zamknął stdin.
"""

import json
import socket
import sys

import dbus
import dbus.service
from dbus.mainloop.glib import DBusGMainLoop
from gi.repository import GLib

# ---------------------------------------------------------------
# Ustawienia
# ---------------------------------------------------------------

# Usługa, którą ogłaszają AirPodsy (i Beatsy na tym samym protokole). iPhone
# jej nie ma, więc nie łapiemy telefonu, choć ma ten sam vendor 0x004C.
AAP_UUID = "74ec2172-0bad-4d01-8f77-997b2be0722a"
AAP_PSM = 0x1001

CONNECT_DELAY_MS = 1500     # po Connected=true kanał AAP bywa jeszcze niegotowy
RETRY_MS = 5000             # kolejna próba, dopóki urządzenie jest połączone
CONNECT_TIMEOUT_S = 5

# Po tylu ms od ostatniego wciśnięcia nóżki gest jest zamknięty: 1 = play/pauza,
# 2 = następny, 3 = poprzedni. Zmierzone odstępy w podwójnym i potrójnym kliku:
# 0,39–0,56 s — krótsze okno rozbijałoby wolniejszy podwójny klik na dwa
# pojedyncze. Tyle też trwa opóźnienie pojedynczego kliku.
STEM_GAP_MS = 700

# ---------------------------------------------------------------
# Protokół
# ---------------------------------------------------------------

HANDSHAKE = bytes.fromhex("00000400010002000000000000000000")
# "Set specific features" — bez niego część funkcji (tryb adaptacyjny)
# bywa niedostępna dla hosta spoza Apple.
FEATURES = bytes.fromhex("040004004d00ff0000000000000000")
REQUEST_NOTIFICATIONS = bytes.fromhex("040004000f00ffffffff")

HEADER = b"\x04\x00\x04\x00"
OP_BATTERY = 0x04
OP_EAR = 0x06
OP_CONTROL = 0x09
CONTROL_NOISE = 0x0D

COMP_RIGHT = 0x02
COMP_LEFT = 0x04
COMP_CASE = 0x08

BATTERY_CHARGING = 0x01
BATTERY_DISCONNECTED = 0x04
BATTERY_UNKNOWN_LEVEL = 0xFF    # przychodzi przez chwilę po otwarciu etui

EAR = {0x00: "ear", 0x01: "out", 0x02: "case"}
NOISE = {0x01: "off", 0x02: "anc", 0x03: "transparency", 0x04: "adaptive"}
NOISE_BY_NAME = {v: k for k, v in NOISE.items()}

# ---------------------------------------------------------------
# Wyjście do QML
# ---------------------------------------------------------------


def blank_battery():
    return {"level": -1, "charging": False, "live": False}


def blank_state():
    return {
        "connected": False,
        "name": "",
        "address": "",
        "noiseMode": "",
        "left": blank_battery(),
        "right": blank_battery(),
        "case": blank_battery(),
        "leftEar": "",
        "rightEar": "",
    }


state = blank_state()
last_emitted = None


def emit(obj):
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def emit_state():
    """Migawka tylko przy zmianie — AirPodsy powtarzają te same pakiety seriami."""
    global last_emitted
    snapshot = json.dumps(state, sort_keys=True)
    if snapshot == last_emitted:
        return
    last_emitted = snapshot
    emit({"type": "state", **state})


def log(text):
    emit({"type": "log", "text": text})


# ---------------------------------------------------------------
# Odtwarzacz dla BlueZ (przejmowanie klików w nóżkę)
# ---------------------------------------------------------------

PLAYER_PATH = "/org/quickshell/island/airpods_player"
PLAYER_IFACE = "org.mpris.MediaPlayer2.Player"


class StemPlayer(dbus.service.Object):
    """Minimalny odtwarzacz MPRIS, którego BlueZ używa jako celu AVRCP.
    Nic nie odtwarza — tylko liczy wciśnięcia i melduje stan słuchawkom."""

    def __init__(self, bus, on_action):
        super().__init__(bus, PLAYER_PATH)
        self.on_action = on_action
        self.playing = False
        self.presses = 0
        self.gap_source = None

    def props(self):
        return {
            "PlaybackStatus": dbus.String("Playing" if self.playing else "Paused"),
            "LoopStatus": dbus.String("None"),
            "Shuffle": dbus.Boolean(False),
            "Position": dbus.Int64(0),
            "Rate": dbus.Double(1.0),
            "Metadata": dbus.Dictionary({"mpris:trackid": dbus.ObjectPath("/org/quickshell/island/track")},
                                        signature="sv"),
            "CanGoNext": dbus.Boolean(True),
            "CanGoPrevious": dbus.Boolean(True),
            "CanPlay": dbus.Boolean(True),
            "CanPause": dbus.Boolean(True),
            "CanSeek": dbus.Boolean(False),
            "CanControl": dbus.Boolean(True),
        }

    def set_playing(self, playing):
        if playing == self.playing:
            return
        self.playing = playing
        self.PropertiesChanged(PLAYER_IFACE, {"PlaybackStatus": self.props()["PlaybackStatus"]}, [])

    # ---- liczenie gestu ----

    def press(self):
        self.presses += 1
        if self.gap_source is not None:
            GLib.source_remove(self.gap_source)
        self.gap_source = GLib.timeout_add(STEM_GAP_MS, self.finish_gesture)

    def finish_gesture(self):
        self.gap_source = None
        n, self.presses = self.presses, 0
        self.on_action({1: "playpause", 2: "next"}.get(n, "previous"))
        return False

    # ---- D-Bus ----

    @dbus.service.method("org.freedesktop.DBus.Properties", in_signature="ss", out_signature="v")
    def Get(self, iface, name):
        return self.props()[name]

    @dbus.service.method("org.freedesktop.DBus.Properties", in_signature="s", out_signature="a{sv}")
    def GetAll(self, iface):
        return self.props() if iface == PLAYER_IFACE else {}

    @dbus.service.method("org.freedesktop.DBus.Properties", in_signature="ssv")
    def Set(self, iface, name, value):
        pass

    @dbus.service.signal("org.freedesktop.DBus.Properties", signature="sa{sv}as")
    def PropertiesChanged(self, iface, changed, invalidated):
        pass

    # Słuchawki wysyłają Play albo Pause zależnie od tego, co myślą o stanie
    # (zmierzone: bywa samo Play) — oba to po prostu wciśnięcie.
    @dbus.service.method(PLAYER_IFACE)
    def Play(self):
        self.press()

    @dbus.service.method(PLAYER_IFACE)
    def Pause(self):
        self.press()

    @dbus.service.method(PLAYER_IFACE)
    def PlayPause(self):
        self.press()

    @dbus.service.method(PLAYER_IFACE)
    def Stop(self):
        pass

    # Inne słuchawki podłączone w tym samym czasie mają własne przyciski
    # następny/poprzedni — te przechodzą wprost.
    @dbus.service.method(PLAYER_IFACE)
    def Next(self):
        self.on_action("next")

    @dbus.service.method(PLAYER_IFACE)
    def Previous(self):
        self.on_action("previous")

    @dbus.service.method(PLAYER_IFACE, in_signature="x")
    def Seek(self, offset):
        pass


# ---------------------------------------------------------------
# Mostek
# ---------------------------------------------------------------


class Bridge:
    def __init__(self):
        self.bus = dbus.SystemBus()
        self.sock = None
        self.sock_watch = None
        self.device_path = None      # urządzenie, z którym jest (albo ma być) sesja
        self.retry_source = None
        self.failed_attempts = 0

        # Pakiet ucha podaje słuchawkę "główną" i "drugą", nie lewą i prawą.
        # Która jest główna, mówi kolejność w pakiecie baterii: pierwsza
        # wymieniona słuchawka to główna (zmierzone: główna w etui = ładuje się
        # prawa, a prawa szła w pakiecie pierwsza). Główna potrafi się zamienić,
        # więc surowe bajty ucha trzymamy i przeliczamy przy każdej baterii.
        self.primary_is_right = True
        self.raw_ear = None

        self.player = StemPlayer(self.bus, lambda action: emit({"type": "media", "action": action}))
        self.player_adapter = None     # ścieżka adaptera, na którym jest zarejestrowany

        self.bus.add_signal_receiver(
            self.on_properties_changed,
            dbus_interface="org.freedesktop.DBus.Properties",
            signal_name="PropertiesChanged",
            bus_name="org.bluez",
            path_keyword="path",
        )
        self.bus.add_signal_receiver(
            self.on_interfaces_added,
            dbus_interface="org.freedesktop.DBus.ObjectManager",
            signal_name="InterfacesAdded",
            bus_name="org.bluez",
        )

        GLib.io_add_watch(sys.stdin.fileno(), GLib.IO_IN | GLib.IO_HUP, self.on_stdin)
        emit_state()
        self.scan_devices()

    # ---- BlueZ ----

    def device_props(self, path):
        try:
            obj = self.bus.get_object("org.bluez", path)
            return obj.GetAll("org.bluez.Device1", dbus_interface="org.freedesktop.DBus.Properties")
        except dbus.DBusException:
            return None

    @staticmethod
    def is_airpods(props):
        return AAP_UUID in [str(u).lower() for u in props.get("UUIDs", [])]

    def scan_devices(self):
        try:
            manager = dbus.Interface(self.bus.get_object("org.bluez", "/"),
                                     "org.freedesktop.DBus.ObjectManager")
            objects = manager.GetManagedObjects()
        except dbus.DBusException as e:
            log(f"BlueZ niedostępny: {e.get_dbus_message()}")
            return
        for path, ifaces in objects.items():
            props = ifaces.get("org.bluez.Device1")
            if props and props.get("Connected") and self.is_airpods(props):
                self.device_connected(str(path))
                return

    def on_interfaces_added(self, path, ifaces):
        props = ifaces.get("org.bluez.Device1")
        if props and props.get("Connected") and self.is_airpods(props):
            self.device_connected(str(path))

    def on_properties_changed(self, iface, changed, invalidated, path=None):
        if iface != "org.bluez.Device1":
            return
        path = str(path)
        if "Connected" in changed:
            if changed["Connected"]:
                props = self.device_props(path)
                if props and self.is_airpods(props):
                    self.device_connected(path)
            elif path == self.device_path:
                log("AirPodsy rozłączone")
                self.close_session()
                self.device_path = None
                self.cancel_retry()
        if "Alias" in changed and path == self.device_path:
            state["name"] = str(changed["Alias"])
            emit_state()

    def device_connected(self, path):
        if self.device_path is not None:
            return    # jedna para naraz; druga poczeka na rozłączenie pierwszej
        self.device_path = path
        self.failed_attempts = 0
        self.schedule_connect(CONNECT_DELAY_MS)

    # ---- sesja AAP ----

    def cancel_retry(self):
        if self.retry_source is not None:
            GLib.source_remove(self.retry_source)
            self.retry_source = None

    def schedule_connect(self, delay_ms):
        self.cancel_retry()
        self.retry_source = GLib.timeout_add(delay_ms, self.try_connect)

    def try_connect(self):
        self.retry_source = None
        if self.device_path is None or self.sock is not None:
            return False
        props = self.device_props(self.device_path)
        if not props or not props.get("Connected"):
            self.device_path = None
            return False

        address = str(props.get("Address", ""))
        sock = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_SEQPACKET, socket.BTPROTO_L2CAP)
        sock.settimeout(CONNECT_TIMEOUT_S)
        try:
            sock.connect((address, AAP_PSM))
            for packet in (HANDSHAKE, FEATURES, REQUEST_NOTIFICATIONS):
                sock.send(packet)
        except OSError as e:
            sock.close()
            self.failed_attempts += 1
            # Loguj pierwszą porażkę i potem rzadko — przy słuchawkach, które
            # nie przyjmują AAP, ponawianie co 5 s zasypałoby log.
            if self.failed_attempts == 1 or self.failed_attempts % 12 == 0:
                log(f"kanał AAP niedostępny ({e}), próba {self.failed_attempts}")
            self.schedule_connect(RETRY_MS)
            return False

        sock.setblocking(False)
        self.sock = sock
        self.sock_watch = GLib.io_add_watch(sock.fileno(), GLib.IO_IN | GLib.IO_HUP | GLib.IO_ERR,
                                            self.on_socket)
        state.update(blank_state())
        state["connected"] = True
        state["name"] = str(props.get("Alias", props.get("Name", "AirPods")))
        state["address"] = address
        self.raw_ear = None
        log(f"połączono z {state['name']}")
        self.register_player(self.device_path.rsplit("/", 1)[0])
        emit_state()
        return False

    # ---- odtwarzacz AVRCP ----
    # Tylko na czas połączenia z AirPodsami: zarejestrowany odtwarzacz
    # przejmuje przyciski WSZYSTKICH słuchawek na adapterze, więc bez AirPodsów
    # inne słuchawki mają działać po staremu, przez klawisze KDE. Gdy mostek
    # padnie, BlueZ sam wyrejestruje odtwarzacz (śledzi właściciela na D-Bus).

    def register_player(self, adapter):
        if self.player_adapter is not None:
            return
        try:
            media = dbus.Interface(self.bus.get_object("org.bluez", adapter), "org.bluez.Media1")
            media.RegisterPlayer(dbus.ObjectPath(PLAYER_PATH), self.player.props())
            self.player_adapter = adapter
        except dbus.DBusException as e:
            log(f"nie udało się przejąć przycisków słuchawek: {e.get_dbus_message()}")

    def unregister_player(self):
        if self.player_adapter is None:
            return
        try:
            media = dbus.Interface(self.bus.get_object("org.bluez", self.player_adapter), "org.bluez.Media1")
            media.UnregisterPlayer(dbus.ObjectPath(PLAYER_PATH))
        except dbus.DBusException:
            pass   # adapter zniknął razem z rejestracją
        self.player_adapter = None

    def close_session(self):
        self.unregister_player()
        if self.sock_watch is not None:
            GLib.source_remove(self.sock_watch)
            self.sock_watch = None
        if self.sock is not None:
            try:
                self.sock.close()
            except OSError:
                pass
            self.sock = None
        state.update(blank_state())
        emit_state()

    def on_socket(self, fd, condition):
        try:
            packet = self.sock.recv(4096)
        except BlockingIOError:
            return True
        except OSError as e:
            packet = b""
            log(f"kanał AAP: {e}")
        if not packet:
            self.sock_watch = None
            self.close_session()
            # Kanał padł, ale urządzenie może wciąż być połączone (np. iPhone
            # przejął słuchawki i oddał) — próbujemy wrócić.
            if self.device_path is not None:
                self.schedule_connect(RETRY_MS)
            return False
        self.handle_packet(packet)
        return True

    def send_packet(self, packet):
        if self.sock is None:
            return
        try:
            self.sock.send(packet)
        except OSError as e:
            log(f"wysyłanie do AirPodsów nieudane: {e}")

    # ---- pakiety ----

    def handle_packet(self, p):
        if len(p) < 7 or p[:4] != HEADER:
            return
        op = p[4]
        if op == OP_BATTERY:
            self.handle_battery(p)
        elif op == OP_EAR and len(p) >= 8:
            self.raw_ear = (p[6], p[7])
            self.apply_ear()
        elif op == OP_CONTROL and len(p) >= 8 and p[6] == CONTROL_NOISE:
            mode = NOISE.get(p[7])
            if mode:
                state["noiseMode"] = mode
                emit_state()

    def handle_battery(self, p):
        count = p[6]
        first_bud = None
        for i in range(count):
            off = 7 + i * 5
            if off + 5 > len(p):
                break
            comp, level, status = p[off], p[off + 2], p[off + 3]
            key = {COMP_LEFT: "left", COMP_RIGHT: "right", COMP_CASE: "case"}.get(comp)
            if key is None:
                continue
            if first_bud is None and comp in (COMP_LEFT, COMP_RIGHT):
                first_bud = comp
            entry = dict(state[key])
            live = status != BATTERY_DISCONNECTED and level != BATTERY_UNKNOWN_LEVEL
            entry["live"] = live
            if live:
                entry["level"] = level
                entry["charging"] = status == BATTERY_CHARGING
            else:
                entry["charging"] = False
            state[key] = entry
        if first_bud is not None:
            self.primary_is_right = first_bud == COMP_RIGHT
        self.apply_ear()
        emit_state()

    def apply_ear(self):
        if self.raw_ear is None:
            return
        primary, secondary = (EAR.get(b, "") for b in self.raw_ear)
        if self.primary_is_right:
            state["rightEar"], state["leftEar"] = primary, secondary
        else:
            state["leftEar"], state["rightEar"] = primary, secondary
        emit_state()

    # ---- stdin ----

    def on_stdin(self, fd, condition):
        line = sys.stdin.readline()
        if not line:
            GLib.idle_add(loop.quit)
            return False
        try:
            cmd = json.loads(line)
        except ValueError:
            log(f"śmieci na stdin: {line[:80]!r}")
            return True
        if cmd.get("cmd") == "playback":
            self.player.set_playing(bool(cmd.get("playing")))
        elif cmd.get("cmd") == "mode":
            code = NOISE_BY_NAME.get(cmd.get("value"))
            if code is None:
                log(f"nieznany tryb: {cmd.get('value')}")
            elif self.sock is None:
                log("tryb odrzucony: brak połączenia z AirPodsami")
            else:
                self.send_packet(bytes([4, 0, 4, 0, OP_CONTROL, 0, CONTROL_NOISE, code, 0, 0, 0]))
        else:
            log(f"nieznana komenda: {cmd.get('cmd')}")
        return True


loop = None


def main():
    global loop
    DBusGMainLoop(set_as_default=True)
    loop = GLib.MainLoop()
    Bridge()
    try:
        loop.run()
    except KeyboardInterrupt:
        pass
    # Bez close_session(): wypisałaby migawkę do stdout, który rodzic już
    # zamknął (BrokenPipe). Gniazdo i tak zamknie system przy wyjściu.
    return 0


if __name__ == "__main__":
    sys.exit(main())
