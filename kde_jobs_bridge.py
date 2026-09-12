#!/usr/bin/env python3
"""
Serwer zadań KDE (transfery plików) dla wyspy.

Kopiowanie w Dolphinie, pobieranie przez integrację przeglądarki itp. NIE są
powiadomieniami. Aplikacja woła org.kde.JobViewServer.requestView, dostaje
ścieżkę obiektu i przez org.kde.JobViewV2/V3 raportuje postęp. Normalnie ten
serwer trzyma aplet powiadomień Plasmy; gdy aplet jest wyłączony, przejmuje
go ten skrypt (Quickshell nie umie wystawiać własnych obiektów D-Bus).

Nazwy magistrali: org.kde.JobViewServer i org.kde.kuiserver. Jeśli trzyma je
Plasma, prośba ląduje w kolejce i przejmujemy je automatycznie, gdy Plasma
zwolni (np. po wyłączeniu apletu) — bez restartu.

  stdout -> QML : {"type":"owner","owned":bool}
                  {"type":"job","event":"start|update|end","id":N, ...pola}
                  {"type":"log","text":"..."}
  stdin  <- QML : {"cmd":"cancel","id":N} | {"cmd":"suspend","id":N}
                  | {"cmd":"resume","id":N}

Pola zadania (płaska migawka, zawsze cała): title, infoMessage, percent,
speed, processedBytes, totalBytes, processedFiles, totalFiles, destUrl,
descriptionLabel1/2, descriptionValue1/2, suspended, killable, suspendable,
desktopEntry, applicationName, applicationIconName, error, errorMessage.
"""

import json
import os
import sys
import time

import dbus
import dbus.service
from dbus.mainloop.glib import DBusGMainLoop
from gi.repository import GLib

NAMES = ["org.kde.JobViewServer", "org.kde.kuiserver"]
SERVER_PATH = "/JobViewServer"
UPDATE_COALESCE_MS = 120     # KIO potrafi słać kilka aktualizacji na klatkę


def emit(obj):
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def log(text):
    emit({"type": "log", "text": text})


def plain(value):
    """dbus.* -> zwykłe typy Pythona (do JSON)."""
    if isinstance(value, dbus.Dictionary):
        return {str(k): plain(v) for k, v in value.items()}
    if isinstance(value, (dbus.Array, list, tuple)):
        return [plain(v) for v in value]
    if isinstance(value, (dbus.Boolean,)):
        return bool(value)
    if isinstance(value, (dbus.Int16, dbus.Int32, dbus.Int64, dbus.UInt16, dbus.UInt32, dbus.UInt64, dbus.Byte, int)):
        return int(value)
    if isinstance(value, (dbus.Double, float)):
        return float(value)
    if isinstance(value, (dbus.String, dbus.ObjectPath, dbus.Signature, str)):
        return str(value)
    if value is None:
        return None
    return str(value)


def named(name, func):
    """python-dbus bierze nazwę SYGNAŁU z func.__name__ w chwili dekoracji;
    JobViewV2 i V3 mają sygnały o tych samych nazwach, więc podmieniamy
    __name__ przed dekoracją i trzymamy je w klasie pod różnymi kluczami."""
    func.__name__ = name
    return func


# Dlaczego po dwie klasy: python-dbus szuka METODY po nazwie atrybutu klasy
# (cls.__dict__[nazwa]) i dopiero potem sprawdza interfejs, więc dwie metody
# D-Bus o tej samej nazwie (terminate w V2 i V3, requestView w V1 i V2) nie
# mogą żyć w jednej klasie. Wyszukiwanie idzie po MRO — stara wersja siedzi
# w klasie bazowej, nowa w pochodnej.


class _JobViewV2(dbus.service.Object):
    """Stare org.kde.JobViewV2.terminate(errorMessage) — aplikacje sprzed KF6."""

    @dbus.service.method("org.kde.JobViewV2", in_signature="s")
    def terminate(self, errorMessage):
        self.finish(1 if str(errorMessage) else 0, errorMessage)


class JobView(_JobViewV2):
    """Jedno zadanie. Wystawia JobViewV2 (stare API) i JobViewV3 (KF6)."""

    def __init__(self, server, job_id, props, capabilities, sender):
        self.server = server
        self.job_id = job_id
        self.sender = sender
        self.path = f"{SERVER_PATH}/JobView_{job_id}"
        self.props = {
            "title": "",
            "infoMessage": "",
            "percent": 0,
            "speed": 0,
            "processedBytes": 0,
            "totalBytes": 0,
            "processedFiles": 0,
            "totalFiles": 0,
            "processedDirectories": 0,
            "totalDirectories": 0,
            "processedItems": 0,
            "totalItems": 0,
            "destUrl": "",
            "descriptionLabel1": "",
            "descriptionValue1": "",
            "descriptionLabel2": "",
            "descriptionValue2": "",
            "suspended": False,
            "killable": bool(capabilities & 0x1),
            "suspendable": bool(capabilities & 0x2),
            "desktopEntry": "",
            "applicationName": "",
            "applicationIconName": "",
            "error": 0,
            "errorMessage": "",
        }
        self.props.update(props)
        self.started = time.time()
        self.pending = None
        self.finished = False
        super().__init__(server.bus, self.path)
        emit({"type": "job", "event": "start", "id": job_id, **self.props})

    # ---- wysyłka do QML ----

    def schedule(self):
        if self.pending is not None or self.finished:
            return
        self.pending = GLib.timeout_add(UPDATE_COALESCE_MS, self.flush)

    def flush(self):
        self.pending = None
        if not self.finished:
            emit({"type": "job", "event": "update", "id": self.job_id, **self.props})
        return False

    def finish(self, error_code=0, error_message=""):
        if self.finished:
            return
        self.finished = True
        if self.pending is not None:
            GLib.source_remove(self.pending)
            self.pending = None
        self.props["error"] = int(error_code)
        self.props["errorMessage"] = str(error_message)
        emit({"type": "job", "event": "end", "id": self.job_id, **self.props})
        self.server.forget(self)
        try:
            self.remove_from_connection()
        except Exception:
            pass

    def set_amount(self, prefix, amount, unit):
        key = prefix + str(unit)[:1].upper() + str(unit)[1:]
        if key in self.props:
            self.props[key] = int(amount)
            self.schedule()

    # ---- org.kde.JobViewV3 ----

    @dbus.service.method("org.kde.JobViewV3", in_signature="a{sv}")
    def update(self, properties):
        for k, v in properties.items():
            k = str(k)
            v = plain(v)
            if k in self.props:
                self.props[k] = v
            elif k.startswith("processed") or k.startswith("total"):
                self.props[k] = v
        self.schedule()

    @dbus.service.method("org.kde.JobViewV3", in_signature="usa{sv}")
    def terminate(self, errorCode, errorMessage, hints):
        self.finish(errorCode, errorMessage)

    # ---- org.kde.JobViewV2 (reszta starego API; terminate w klasie bazowej) ----

    @dbus.service.method("org.kde.JobViewV2", in_signature="b")
    def setSuspended(self, suspended):
        self.props["suspended"] = bool(suspended)
        self.schedule()

    @dbus.service.method("org.kde.JobViewV2", in_signature="ts")
    def setTotalAmount(self, amount, unit):
        self.set_amount("total", amount, unit)

    @dbus.service.method("org.kde.JobViewV2", in_signature="ts")
    def setProcessedAmount(self, amount, unit):
        self.set_amount("processed", amount, unit)

    @dbus.service.method("org.kde.JobViewV2", in_signature="u")
    def setPercent(self, percent):
        self.props["percent"] = int(percent)
        self.schedule()

    @dbus.service.method("org.kde.JobViewV2", in_signature="t")
    def setSpeed(self, bytesPerSecond):
        self.props["speed"] = int(bytesPerSecond)
        self.schedule()

    @dbus.service.method("org.kde.JobViewV2", in_signature="t")
    def setElapsedTime(self, elapsedTime):
        pass

    @dbus.service.method("org.kde.JobViewV2", in_signature="s")
    def setInfoMessage(self, message):
        self.props["infoMessage"] = str(message)
        self.schedule()

    @dbus.service.method("org.kde.JobViewV2", in_signature="uss", out_signature="b")
    def setDescriptionField(self, number, name, value):
        n = int(number) + 1
        if n in (1, 2):
            self.props[f"descriptionLabel{n}"] = str(name)
            self.props[f"descriptionValue{n}"] = str(value)
            self.schedule()
            return True
        return False

    @dbus.service.method("org.kde.JobViewV2", in_signature="u")
    def clearDescriptionField(self, number):
        n = int(number) + 1
        if n in (1, 2):
            self.props[f"descriptionLabel{n}"] = ""
            self.props[f"descriptionValue{n}"] = ""
            self.schedule()

    @dbus.service.method("org.kde.JobViewV2", in_signature="v")
    def setDestUrl(self, destUrl):
        self.props["destUrl"] = str(plain(destUrl))
        self.schedule()

    @dbus.service.method("org.kde.JobViewV2", in_signature="u")
    def setError(self, errorCode):
        self.props["error"] = int(errorCode)
        self.schedule()

    # ---- sygnały (te same nazwy w V2 i V3, więc emitujemy na obu) ----

    @dbus.service.signal("org.kde.JobViewV3")
    def cancelRequested(self): pass

    @dbus.service.signal("org.kde.JobViewV3")
    def suspendRequested(self): pass

    @dbus.service.signal("org.kde.JobViewV3")
    def resumeRequested(self): pass

    @dbus.service.signal("org.kde.JobViewV3")
    def updateRequested(self): pass

    cancelRequested_v2 = dbus.service.signal("org.kde.JobViewV2")(named("cancelRequested", lambda self: None))
    suspendRequested_v2 = dbus.service.signal("org.kde.JobViewV2")(named("suspendRequested", lambda self: None))
    resumeRequested_v2 = dbus.service.signal("org.kde.JobViewV2")(named("resumeRequested", lambda self: None))

    def request(self, what):
        if what == "cancel":
            self.cancelRequested(); self.cancelRequested_v2()
        elif what == "suspend":
            self.suspendRequested(); self.suspendRequested_v2()
        elif what == "resume":
            self.resumeRequested(); self.resumeRequested_v2()


class _JobViewServerV1(dbus.service.Object):
    """Stare org.kde.JobViewServer.requestView(appName, appIconName, capabilities)."""

    @dbus.service.method("org.kde.JobViewServer", in_signature="ssi", out_signature="o", sender_keyword="sender")
    def requestView(self, appName, appIconName, capabilities, sender=None):
        return self.create({"applicationName": str(appName), "applicationIconName": str(appIconName)}, capabilities, sender)


class JobViewServer(_JobViewServerV1):
    def __init__(self, bus):
        self.bus = bus
        self.jobs = {}
        self.next_id = 1
        super().__init__(bus, SERVER_PATH)
        # Klient, który zniknął z magistrali, nie zawoła terminate — sprzątamy sami.
        bus.add_signal_receiver(self.on_name_owner_changed, "NameOwnerChanged",
                                "org.freedesktop.DBus", "org.freedesktop.DBus")

    def create(self, props, capabilities, sender):
        job_id = self.next_id
        self.next_id += 1
        view = JobView(self, job_id, props, int(capabilities), sender)
        self.jobs[job_id] = view
        return dbus.ObjectPath(view.path)

    def forget(self, view):
        self.jobs.pop(view.job_id, None)

    def on_name_owner_changed(self, name, old, new):
        if new != "" or not old:
            return
        for view in list(self.jobs.values()):
            if view.sender == old:
                view.finish(0, "")

    # ---- org.kde.JobViewServerV2 (KF6; V1 w klasie bazowej) ----

    @dbus.service.method("org.kde.JobViewServerV2", in_signature="sia{sv}", out_signature="o", sender_keyword="sender")
    def requestView(self, desktopEntry, capabilities, hints, sender=None):
        return self.create({"desktopEntry": str(desktopEntry), **plain(hints)}, capabilities, sender)

    # ---- org.kde.kuiserver (stare API, KIO tylko sprawdza, że istnieje) ----

    @dbus.service.method("org.kde.kuiserver", in_signature="ss")
    def registerService(self, service, objectPath):
        pass

    @dbus.service.method("org.kde.kuiserver")
    def emitJobUrlsChanged(self):
        self.jobUrlsChanged([])

    @dbus.service.method("org.kde.kuiserver", out_signature="as")
    def registeredJobContacts(self):
        return []

    @dbus.service.method("org.kde.kuiserver", out_signature="b")
    def requiresJobTracker(self):
        return True

    @dbus.service.signal("org.kde.kuiserver", signature="as")
    def jobUrlsChanged(self, urls): pass

    @dbus.service.signal("org.kde.kuiserver", signature="b")
    def requiresJobTrackerChanged(self, value): pass


class Bridge:
    def __init__(self):
        self.bus = dbus.SessionBus()
        self.server = JobViewServer(self.bus)
        self.owned = set()
        self.names = []
        self.stdin_buf = b""

        self.bus.add_signal_receiver(self.on_name_acquired, "NameAcquired", "org.freedesktop.DBus")
        self.bus.add_signal_receiver(self.on_name_lost, "NameLost", "org.freedesktop.DBus")
        # do_not_queue=False: jeśli nazwę trzyma Plasma, czekamy w kolejce
        # i dostaniemy ją, gdy Plasma zwolni.
        for name in NAMES:
            self.names.append(dbus.service.BusName(name, self.bus, allow_replacement=True, do_not_queue=False))
        GLib.timeout_add(500, self.report_owner)
        GLib.io_add_watch(sys.stdin.fileno(), GLib.IO_IN | GLib.IO_HUP, self.on_stdin)

    def on_name_acquired(self, name):
        if str(name) in NAMES:
            self.owned.add(str(name))
            self.report_owner()

    def on_name_lost(self, name):
        if str(name) in NAMES:
            self.owned.discard(str(name))
            self.report_owner()

    def report_owner(self):
        emit({"type": "owner", "owned": NAMES[0] in self.owned})
        return False

    def on_stdin(self, fd, cond):
        chunk = os.read(fd, 4096)
        if not chunk:
            loop.quit()
            return False
        self.stdin_buf += chunk
        while b"\n" in self.stdin_buf:
            line, self.stdin_buf = self.stdin_buf.split(b"\n", 1)
            line = line.strip()
            if not line:
                continue
            try:
                cmd = json.loads(line)
            except ValueError:
                log(f"śmieci na stdin: {line[:80]!r}")
                continue
            view = self.server.jobs.get(int(cmd.get("id", 0)))
            if view is None:
                continue
            view.request(cmd.get("cmd"))
        return True


if __name__ == "__main__":
    DBusGMainLoop(set_as_default=True)
    loop = GLib.MainLoop()
    Bridge()
    try:
        loop.run()
    except KeyboardInterrupt:
        pass
