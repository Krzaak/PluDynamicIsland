#!/usr/bin/env python3
"""
Agent parowania BlueZ dla wyspy.

Quickshell.Bluetooth daje device.pair(), ale NIE daje agenta — a bez agenta
BlueZ nie ma kogo zapytać o PIN i parowanie kończy się od razu błędem
org.bluez.Error.AuthenticationCanceled. Normalnie agenta trzyma aplet pulpitu
(bluedevil w KDE, blueman w GNOME); na Hyprlandzie nie ma żadnego — zmierzone
przez AgentManager1, gdzie nic nie było zarejestrowane. Dlatego wyspa wystawia
własnego, a Quickshell nie umie wystawiać obiektów D-Bus, więc idzie to
mostkiem jak JobViewServer.

Zdolność agenta to "KeyboardDisplay", czyli najszersza: BlueZ może poprosić
o wpisanie PIN-u i klucza, pokazać własny do przepisania na urządzeniu albo
poprosić o potwierdzenie sześciu cyfr. Węższa zdolność (np. "NoInputNoOutput")
kazałaby BlueZ-owi parować "just works" i cicho obniżała bezpieczeństwo
połączenia, więc jej tu nie ma.

  stdout -> QML : {"type":"ready","registered":bool}
                  {"type":"request","id":N,"kind":...,"device":{...}, ...}
                  {"type":"cancel","id":N}
                  {"type":"log","text":"..."}
  stdin  <- QML : {"cmd":"reply","id":N,"accept":bool,"value":"1234"}

Rodzaje pytań (kind) i co QML ma pokazać:
  pin             pole tekstowe, 1-16 znaków, odpowiedź w "value"
  passkey         pole liczbowe 0-999999, odpowiedź w "value"
  confirm         sześć cyfr w "passkey" do porównania z ekranem urządzenia,
                  odpowiedź samym "accept"
  authorize       zgoda na parowanie bez żadnego kodu ("just works")
  service         zgoda na usługę, UUID w "uuid"
  display-pin     TYLKO do pokazania (PIN w "value"), odpowiedzi się nie wysyła
  display-passkey TYLKO do pokazania (klucz w "passkey", wpisane cyfry
                  w "entered"), odpowiedzi się nie wysyła

Test bez wyspy:  python3 bt_agent_bridge.py
(potem w drugim oknie `bluetoothctl` -> `pair <adres>`; EOF na stdin kończy
mostek czysto).
"""

import json
import os
import sys

import dbus
import dbus.service
from dbus.mainloop.glib import DBusGMainLoop
from gi.repository import GLib

BLUEZ = "org.bluez"
AGENT_PATH = "/pl/plutex/island/btagent"
AGENT_IFACE = "org.bluez.Agent1"
CAPABILITY = "KeyboardDisplay"

# Ile czekamy na odpowiedź użytkownika, zanim sami odrzucimy parowanie.
# BlueZ ma własny limit i zwykle odzywa się pierwszy przez Cancel(); to jest
# tylko siatka bezpieczeństwa, żeby nie zostać z wiszącym wywołaniem D-Bus,
# gdyby wyspa zniknęła w trakcie pytania.
REPLY_TIMEOUT_MS = 120_000

# Rejestracja potrafi nie wyjść, bo bluetoothd jeszcze nie wstał albo nazwę
# agenta trzyma inny aplet. Próbujemy dalej zamiast kończyć — adapter i aplety
# pojawiają się i znikają w trakcie sesji.
RETRY_MS = 3_000


def emit(obj):
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def log(text):
    emit({"type": "log", "text": text})


class Rejected(dbus.DBusException):
    _dbus_error_name = "org.bluez.Error.Rejected"


class Canceled(dbus.DBusException):
    _dbus_error_name = "org.bluez.Error.Canceled"


def device_info(bus, path):
    """Nazwa i adres urządzenia do pokazania w formularzu.

    Pytamy BlueZ zamiast przekazywać samą ścieżkę, bo w chwili pytania
    urządzenie bywa świeżo znalezione i wyspa może go jeszcze nie mieć
    w swoim modelu."""
    info = {"path": str(path), "name": "", "address": "", "icon": "", "paired": False}
    try:
        props = dbus.Interface(bus.get_object(BLUEZ, path), "org.freedesktop.DBus.Properties")
        all_props = props.GetAll("org.bluez.Device1")
        info["name"] = str(all_props.get("Alias") or all_props.get("Name") or "")
        info["address"] = str(all_props.get("Address") or "")
        info["icon"] = str(all_props.get("Icon") or "")
        info["paired"] = bool(all_props.get("Paired", False))
    except dbus.DBusException as exc:
        log(f"nie odczytałem urządzenia {path}: {exc}")
    return info


class Agent(dbus.service.Object):
    """org.bluez.Agent1.

    Każda metoda pytająca jest asynchroniczna (async_callbacks): wywołanie
    D-Bus zostaje otwarte, a odpowiedź wysyłamy dopiero, gdy użytkownik
    kliknie w wyspie. Bez tego metoda musiałaby zwrócić wartość od razu,
    czyli zgadywać za użytkownika."""

    def __init__(self, bus):
        super().__init__(bus, AGENT_PATH)
        self.bus = bus
        self.next_id = 1
        self.pending = {}   # id -> (ok, err, timeout_source)

    # ---- rozmowa z wyspą ----

    def ask(self, kind, device_path, ok, err, **extra):
        req_id = self.next_id
        self.next_id += 1

        source = GLib.timeout_add(REPLY_TIMEOUT_MS, self._expire, req_id)
        self.pending[req_id] = (ok, err, source)

        payload = {
            "type": "request",
            "id": req_id,
            "kind": kind,
            "device": device_info(self.bus, device_path),
        }
        payload.update(extra)
        emit(payload)
        return req_id

    def _expire(self, req_id):
        entry = self.pending.pop(req_id, None)
        if entry is not None:
            _, err, _ = entry
            log(f"pytanie {req_id} bez odpowiedzi — odrzucam")
            err(Canceled())
            emit({"type": "cancel", "id": req_id})
        return False

    def reply(self, req_id, accept, value):
        entry = self.pending.pop(req_id, None)
        if entry is None:
            return
        ok, err, source = entry
        GLib.source_remove(source)

        if not accept:
            err(Rejected())
            return
        try:
            ok(value)
        except Exception as exc:                      # noqa: BLE001
            log(f"odpowiedź na {req_id} nie przeszła: {exc}")
            err(Rejected())

    def cancel_all(self, reason):
        for req_id in list(self.pending):
            entry = self.pending.pop(req_id, None)
            if entry is None:
                continue
            _, err, source = entry
            GLib.source_remove(source)
            err(Canceled())
            emit({"type": "cancel", "id": req_id, "reason": reason})

    # ---- metody agenta ----

    @dbus.service.method(AGENT_IFACE, in_signature="", out_signature="")
    def Release(self):
        # BlueZ zwalnia agenta np. przy własnym restarcie. Rejestrujemy się
        # ponownie, inaczej po restarcie bluetoothd parowanie cicho przestaje
        # działać aż do restartu wyspy.
        global registered
        log("BlueZ zwolnił agenta")
        registered = False
        self.cancel_all("release")
        emit({"type": "ready", "registered": False})
        GLib.timeout_add(RETRY_MS, register_agent)

    @dbus.service.method(AGENT_IFACE, in_signature="o", out_signature="s",
                         async_callbacks=("ok", "err"))
    def RequestPinCode(self, device, ok, err):
        self.ask("pin", device, lambda v: ok(dbus.String("" if v is None else str(v))), err)

    @dbus.service.method(AGENT_IFACE, in_signature="o", out_signature="u",
                         async_callbacks=("ok", "err"))
    def RequestPasskey(self, device, ok, err):
        # Klucz to liczba 0-999999; BlueZ odrzuci wszystko spoza zakresu.
        self.ask("passkey", device, lambda v: ok(dbus.UInt32(int(str(v or "0").strip() or 0) % 1_000_000)), err)

    @dbus.service.method(AGENT_IFACE, in_signature="ou", out_signature="",
                         async_callbacks=("ok", "err"))
    def RequestConfirmation(self, device, passkey, ok, err):
        self.ask("confirm", device, lambda v: ok(), err, passkey=f"{int(passkey):06d}")

    @dbus.service.method(AGENT_IFACE, in_signature="o", out_signature="",
                         async_callbacks=("ok", "err"))
    def RequestAuthorization(self, device, ok, err):
        self.ask("authorize", device, lambda v: ok(), err)

    @dbus.service.method(AGENT_IFACE, in_signature="os", out_signature="",
                         async_callbacks=("ok", "err"))
    def AuthorizeService(self, device, uuid, ok, err):
        self.ask("service", device, lambda v: ok(), err, uuid=str(uuid))

    @dbus.service.method(AGENT_IFACE, in_signature="os", out_signature="")
    def DisplayPinCode(self, device, pincode):
        # Tu niczego nie zwracamy — PIN ma przepisać użytkownik NA URZĄDZENIU.
        # Okno zamyka Cancel() albo koniec parowania.
        emit({
            "type": "request",
            "id": 0,
            "kind": "display-pin",
            "device": device_info(self.bus, device),
            "value": str(pincode),
        })

    @dbus.service.method(AGENT_IFACE, in_signature="ouq", out_signature="")
    def DisplayPasskey(self, device, passkey, entered):
        emit({
            "type": "request",
            "id": 0,
            "kind": "display-passkey",
            "device": device_info(self.bus, device),
            "passkey": f"{int(passkey):06d}",
            "entered": int(entered),
        })

    @dbus.service.method(AGENT_IFACE, in_signature="", out_signature="")
    def Cancel(self):
        log("BlueZ anulował parowanie")
        self.cancel_all("bluez")


agent = None
bus = None
registered = False


def register_agent():
    """Rejestracja w AgentManager1. Powtarzana, dopóki nie wyjdzie."""
    global registered
    if registered:
        return False
    try:
        manager = dbus.Interface(bus.get_object(BLUEZ, "/org/bluez"), "org.bluez.AgentManager1")
        manager.RegisterAgent(AGENT_PATH, CAPABILITY)
    except dbus.DBusException as exc:
        name = exc.get_dbus_name() or ""
        if name.endswith("AlreadyExists"):
            # Agenta trzyma inny aplet (bluedevil, blueman). Nie wypychamy go
            # siłą — czekamy, aż zniknie.
            log("agenta trzyma już inny program, czekam")
        else:
            log(f"rejestracja agenta nie wyszła: {exc}")
        return True   # GLib powtórzy za RETRY_MS

    # Domyślny agent dostaje pytania, których nikt inny nie obsłużył. Brak
    # tego wywołania nie psuje parowania inicjowanego z wyspy, więc błąd
    # tylko logujemy.
    try:
        manager.RequestDefaultAgent(AGENT_PATH)
    except dbus.DBusException as exc:
        log(f"nie zostałem agentem domyślnym: {exc}")

    registered = True
    emit({"type": "ready", "registered": True})
    log("agent zarejestrowany")
    return False


def on_bluez_owner_changed(name, old, new):
    """bluetoothd zniknął albo wrócił — po powrocie trzeba się zarejestrować
    od nowa, bo rejestracja żyje tylko w jego procesie."""
    global registered
    if str(name) != BLUEZ:
        return
    if not str(new):
        registered = False
        agent.cancel_all("bluez-gone")
        emit({"type": "ready", "registered": False})
        log("bluetoothd zniknął")
    else:
        registered = False
        GLib.timeout_add(RETRY_MS, register_agent)


class Stdin:
    def __init__(self):
        self.buf = b""
        GLib.io_add_watch(sys.stdin.fileno(), GLib.IO_IN | GLib.IO_HUP, self.on_read)

    def on_read(self, fd, cond):
        chunk = os.read(fd, 4096)
        if not chunk:
            loop.quit()
            return False
        self.buf += chunk
        while b"\n" in self.buf:
            line, self.buf = self.buf.split(b"\n", 1)
            line = line.strip()
            if not line:
                continue
            try:
                cmd = json.loads(line)
            except ValueError:
                log(f"śmieci na stdin: {line[:80]!r}")
                continue
            if cmd.get("cmd") == "reply":
                agent.reply(int(cmd.get("id", 0)), bool(cmd.get("accept")), cmd.get("value"))
        return True


if __name__ == "__main__":
    DBusGMainLoop(set_as_default=True)
    loop = GLib.MainLoop()
    bus = dbus.SystemBus()          # BlueZ siedzi na magistrali systemowej
    agent = Agent(bus)
    bus.add_signal_receiver(
        on_bluez_owner_changed,
        signal_name="NameOwnerChanged",
        dbus_interface="org.freedesktop.DBus",
        arg0=BLUEZ,
    )
    if register_agent():
        GLib.timeout_add(RETRY_MS, register_agent)
    Stdin()
    try:
        loop.run()
    except KeyboardInterrupt:
        pass
