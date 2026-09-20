#!/usr/bin/env python3
"""
Zakłada i uruchamia połączenie Wi-Fi. Wołany przez wyspę na żądanie
(formularz "Połącz"), kończy się od razu.

Dlaczego nie Quickshell: WifiNetwork daje tylko connectWithPsk(psk), a
connectWithSettings() chce obiektu NMSettings, którego z QML NIE DA SIĘ
utworzyć (typ nie jest eksportowany do QML — sprawdzone w qmltypes). Sieci
ukrytej, 802.1X ani wyboru "łącz automatycznie" nie da się więc zrobić
z samego QML-a.

Dlaczego nie `nmcli`: hasło byłoby w argv, a /proc/<pid>/cmdline czyta na
Linuksie każdy proces tego samego użytkownika (i root). Tutaj cała prośba —
razem z hasłem — przychodzi jednym JSON-em na STDIN i nigdzie nie ląduje
w linii poleceń.

  stdin  : {"ssid": "...", "security": "wpa-psk"|"sae"|"wpa-eap"|"wep"|"owe"|"open",
            "psk": "...", "hidden": bool, "autoconnect": bool, "iface": "wlp59s0",
            "eap": "peap"|"ttls"|"tls"|"pwd", "identity": "...",
            "anonymousIdentity": "...", "password": "...",
            "phase2": "mschapv2"|"gtc"|"md5"|"pap"|"", "caCert": "/ścieżka"}
  stdout : {"ok": true, "path": "/org/freedesktop/NetworkManager/ActiveConnection/N"}
           {"ok": false, "error": "tekst dla użytkownika"}

  kod wyjścia: 0 - zlecone, 1 - odmowa NetworkManagera, 2 - brak NM / D-Bus

Uwaga: zwrócenie ok:true znaczy tylko tyle, że NetworkManager PRZYJĄŁ
zlecenie. Czy uwierzytelnienie się powiodło, widać dopiero po stanie sieci —
wyspa czyta to z Quickshell.Networking, nie stąd.
"""

import json
import sys
import uuid

import dbus

NM = "org.freedesktop.NetworkManager"
NM_PATH = "/org/freedesktop/NetworkManager"


def fail(message, code=1):
    sys.stdout.write(json.dumps({"ok": False, "error": message}, ensure_ascii=False) + "\n")
    sys.stdout.flush()
    return code


def build_settings(req):
    """Prośba z wyspy -> słownik ustawień NetworkManagera.

    Nazwy kluczy i typy są narzucone przez NM: ssid MUSI być tablicą bajtów
    (sieci nie zawsze są poprawnym UTF-8), a nie stringiem."""
    ssid = str(req.get("ssid") or "")
    if not ssid:
        raise ValueError("pusta nazwa sieci")

    security = str(req.get("security") or "open")

    settings = {
        "connection": dbus.Dictionary({
            "id": dbus.String(ssid),
            "type": dbus.String("802-11-wireless"),
            "uuid": dbus.String(str(uuid.uuid4())),
            "autoconnect": dbus.Boolean(bool(req.get("autoconnect", True))),
        }, signature="sv"),
        "802-11-wireless": dbus.Dictionary({
            "ssid": dbus.ByteArray(ssid.encode("utf-8")),
            "mode": dbus.String("infrastructure"),
            # Przy sieci ukrytej NM musi wysłać aktywne skanowanie z SSID-em,
            # inaczej nigdy jej nie zobaczy.
            "hidden": dbus.Boolean(bool(req.get("hidden", False))),
        }, signature="sv"),
        "ipv4": dbus.Dictionary({"method": dbus.String("auto")}, signature="sv"),
        "ipv6": dbus.Dictionary({"method": dbus.String("auto")}, signature="sv"),
    }

    if security in ("wpa-psk", "sae"):
        psk = str(req.get("psk") or "")
        # WPA liczy 8-63 znaki hasła albo 64 znaki klucza szesnastkowego.
        # NM odrzuciłby krótsze błędem, który nic nie mówi użytkownikowi.
        if len(psk) < 8 and len(psk) != 64:
            raise ValueError("hasło WPA ma mieć co najmniej 8 znaków")
        settings["802-11-wireless-security"] = dbus.Dictionary({
            "key-mgmt": dbus.String(security),
            "psk": dbus.String(psk),
        }, signature="sv")

    elif security == "wep":
        key = str(req.get("psk") or "")
        if not key:
            raise ValueError("brak klucza WEP")
        settings["802-11-wireless-security"] = dbus.Dictionary({
            "key-mgmt": dbus.String("none"),
            "wep-key0": dbus.String(key),
            # 1 = klucz szesnastkowy/ASCII, 2 = hasło. Klucz WEP ma 5, 10, 13
            # albo 26 znaków; cokolwiek innego to hasło do przeliczenia.
            "wep-key-type": dbus.UInt32(1 if len(key) in (5, 10, 13, 26) else 2),
            "auth-alg": dbus.String("open"),
        }, signature="sv")

    elif security == "wpa-eap":
        identity = str(req.get("identity") or "")
        if not identity:
            raise ValueError("brak tożsamości 802.1X")
        eap = str(req.get("eap") or "peap")

        eap_settings = {
            "eap": dbus.Array([dbus.String(eap)], signature="s"),
            "identity": dbus.String(identity),
        }
        if req.get("anonymousIdentity"):
            eap_settings["anonymous-identity"] = dbus.String(str(req["anonymousIdentity"]))
        if req.get("caCert"):
            # NM chce ścieżki jako bajtów zakończonych zerem, ze schematem file://
            path = str(req["caCert"])
            eap_settings["ca-cert"] = dbus.ByteArray(b"file://" + path.encode("utf-8") + b"\x00")
        if eap == "tls":
            # TLS uwierzytelnia certyfikatem klienta, nie hasłem.
            if req.get("clientCert"):
                path = str(req["clientCert"])
                eap_settings["client-cert"] = dbus.ByteArray(b"file://" + path.encode("utf-8") + b"\x00")
            if req.get("privateKey"):
                path = str(req["privateKey"])
                eap_settings["private-key"] = dbus.ByteArray(b"file://" + path.encode("utf-8") + b"\x00")
            if req.get("password"):
                eap_settings["private-key-password"] = dbus.String(str(req["password"]))
        else:
            password = str(req.get("password") or "")
            if not password:
                raise ValueError("brak hasła 802.1X")
            eap_settings["password"] = dbus.String(password)
            phase2 = str(req.get("phase2") or "")
            if phase2:
                eap_settings["phase2-auth"] = dbus.String(phase2)

        settings["802-11-wireless-security"] = dbus.Dictionary({
            "key-mgmt": dbus.String("wpa-eap"),
        }, signature="sv")
        settings["802-1x"] = dbus.Dictionary(eap_settings, signature="sv")

    elif security == "owe":
        settings["802-11-wireless-security"] = dbus.Dictionary({
            "key-mgmt": dbus.String("owe"),
        }, signature="sv")

    elif security != "open":
        raise ValueError(f"nieznane zabezpieczenia: {security}")

    return settings


def main():
    try:
        req = json.loads(sys.stdin.read() or "{}")
    except ValueError as exc:
        return fail(f"zepsuty JSON na wejściu: {exc}")

    try:
        settings = build_settings(req)
    except ValueError as exc:
        return fail(str(exc))

    try:
        bus = dbus.SystemBus()
        nm = dbus.Interface(bus.get_object(NM, NM_PATH), NM)
    except dbus.DBusException as exc:
        return fail(f"NetworkManager nie odpowiada: {exc}", 2)

    iface = str(req.get("iface") or "")
    try:
        device = nm.GetDeviceByIpIface(iface) if iface else "/"
    except dbus.DBusException:
        return fail(f"nie znam urządzenia {iface}")

    try:
        # specific_object "/" = wybór punktu dostępowego zostawiamy NM-owi.
        # Przy sieci ukrytej innej drogi zresztą nie ma, bo AP jeszcze nie
        # istnieje w jego widoku.
        _, active = nm.AddAndActivateConnection(settings, device, "/")
    except dbus.DBusException as exc:
        return fail(f"NetworkManager odmówił: {exc.get_dbus_message() or exc}")

    sys.stdout.write(json.dumps({"ok": True, "path": str(active)}) + "\n")
    sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
