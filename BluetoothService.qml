pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Bluetooth

// Wszystko bluetoothowe, czego Quickshell.Bluetooth nie daje, plus to, co
// karta łączności i panel Bluetootha muszą widzieć tak samo:
//
//  1. AGENT PAROWANIA (mostek bt_agent_bridge.py). Quickshell daje
//     device.pair(), ale nie daje agenta — a bez agenta BlueZ nie ma kogo
//     zapytać o PIN i parowanie pada od razu. Na KDE agenta trzyma bluedevil,
//     na Hyprlandzie nie ma go wcale (zmierzone: AgentManager1 bez żadnej
//     rejestracji). Mostek chodzi cały czas, bo pytanie potrafi przyjść także
//     wtedy, gdy to URZĄDZENIE zaczyna parowanie (np. klawiatura), a nie my.
//  2. WŁĄCZANIE adaptera przez rfkill (niżej, przy setEnabled).
//  3. Mapowanie ikon BlueZ na nasze IslandIcon.
Singleton {
    id: root

    // ---------------------------------------------------------------
    // Adapter
    // ---------------------------------------------------------------

    readonly property var adapter: Bluetooth.defaultAdapter
    readonly property bool enabled: adapter !== null && adapter.enabled
    readonly property bool blocked: adapter !== null && adapter.state === BluetoothAdapterState.Blocked
    readonly property bool busy: adapter !== null
        && (adapter.state === BluetoothAdapterState.Enabling || adapter.state === BluetoothAdapterState.Disabling)
    readonly property bool discovering: adapter !== null && adapter.discovering

    // Czy urządzenie ma PRAWDZIWĄ nazwę, czy tylko zastępnik.
    //
    // Bezimiennym urządzeniom BlueZ wstawia w nazwę ich własny adres, ale
    // z MYŚLNIKAMI ("07-2A-34-13-BE-04"), podczas gdy `address` ma dwukropki —
    // przez co porównanie `name !== address` wprost NIGDY nie trafiało
    // (zmierzone: 10 z 12 znalezionych urządzeń to były takie zastępniki).
    // Stąd normalizacja separatorów. Drugi zastępnik to dosłowne "LE_UNKNOWN".
    function hasRealName(device) {
        if (!device) return false;
        const name = String(device.name || "");
        if (name === "" || name === "LE_UNKNOWN") return false;
        return name.replace(/-/g, ":").toUpperCase() !== String(device.address || "").toUpperCase();
    }

    // Urządzenia w kolejności do pokazania: POŁĄCZONE na górze, potem
    // sparowane, potem reszta; w grupach alfabetycznie, żeby lista nie
    // przestawiała się sama przy każdym odświeżeniu sygnału.
    //
    // Bezimienne odpadają tutaj, a nie w delegacie: delegat o zerowej
    // wysokości nadal liczy się do `count`, więc podpowiedź "Szukam
    // urządzeń…" nie pokazywałaby się przy liście pełnej samych zastępników.
    //
    // Zwykła tablica, nie model Bluetooth.devices — elementy zachowują
    // tożsamość (zmierzone: element posortowanej tablicy nadal jest w
    // Bluetooth.devices.values), więc porównanie `panel.selected === dev`
    // dalej działa.
    readonly property var sortedDevices: {
        const all = Bluetooth.devices.values.filter(d => root.hasRealName(d));
        return all.sort((a, b) => {
            if (a.connected !== b.connected) return a.connected ? -1 : 1;
            if (a.paired !== b.paired) return a.paired ? -1 : 1;
            return (a.name || "").localeCompare(b.name || "");
        });
    }

    // To, co pokazuje karta łączności: bez urządzeń znalezionych przy
    // skanowaniu, bo parowanie i tak dzieje się w nakładce.
    readonly property var pairedDevices: sortedDevices.filter(d => d.paired)

    readonly property int connectedCount: {
        const all = Bluetooth.devices.values;
        let n = 0;
        for (let i = 0; i < all.length; i++) if (all[i].connected) n++;
        return n;
    }

    // Wyłączony Bluetooth to blokada rfkill, nie tylko Powered=false.
    // Zablokowany adapter ignoruje enabled=true (BlueZ zwraca Error.Blocked),
    // więc włączanie idzie przez rfkill unblock; BlueZ z AutoEnable sam potem
    // podnosi adapter, a enabled=true po zmianie stanu to zabezpieczenie,
    // gdyby AutoEnable było wyłączone. Wyłączanie blokuje rfkill, żeby stan
    // zgadzał się z tym, co pokazuje aplet pulpitu (na KDE bluedevil).
    property bool pendingEnable: false

    function setEnabled(on) {
        if (adapter === null || busy) return;
        if (on) {
            pendingEnable = true;
            rfkill.command = ["rfkill", "unblock", "bluetooth"];
            rfkill.running = true;
            if (!blocked) adapter.enabled = true;
        } else {
            pendingEnable = false;
            adapter.discovering = false;
            adapter.enabled = false;
            rfkill.command = ["rfkill", "block", "bluetooth"];
            rfkill.running = true;
        }
    }

    Connections {
        target: root.adapter

        function onStateChanged() {
            if (root.pendingEnable && !root.blocked && !root.busy) {
                root.pendingEnable = false;
                if (!root.adapter.enabled) root.adapter.enabled = true;
            }
        }
    }

    Process {
        id: rfkill
        onExited: (exitCode, exitStatus) => {
            if (exitCode !== 0)
                console.warn("rfkill zakończył się kodem " + exitCode + " — Bluetooth może nie dać się przełączyć.");
        }
    }

    // Ikony BlueZ (nazwy z freedesktop) -> nasze IslandIcon.
    function deviceIcon(name) {
        switch (name) {
        case "audio-headset":
        case "audio-headphones": return "headset";
        case "audio-card":
        case "audio-speakers": return "speaker";
        case "phone": return "phone";
        case "input-keyboard": return "keyboard";
        case "input-mouse":
        case "input-tablet": return "mouse";
        case "input-gaming": return "gamepad";
        case "computer": return "computer";
        default: return "bluetooth";
        }
    }

    // ---------------------------------------------------------------
    // Agent parowania
    // ---------------------------------------------------------------

    // ---------------------------------------------------------------
    // Ustawienia
    // ---------------------------------------------------------------

    property int restartDelayMs: 3000   // po awarii mostka: ile odczekać przed restartem
    property int maxFailures: 3         // tyle szybkich awarii z rzędu = odpuszczamy

    // ---------------------------------------------------------------
    // Stan
    // ---------------------------------------------------------------

    readonly property alias registered: priv.registered   // agent przyjęty przez BlueZ
    readonly property alias available: priv.available     // mostek w ogóle działa

    // Pytanie czekające na odpowiedź użytkownika albo null.
    // { id, kind, device: {name, address, icon, paired}, passkey, uuid, value, entered }
    //
    // kind: "pin" | "passkey" | "confirm" | "authorize" | "service"
    //     | "display-pin" | "display-passkey"
    // Dwa ostatnie są tylko do POKAZANIA — kod przepisuje się na urządzeniu
    // i odpowiedzi się nie wysyła; znikają, gdy BlueZ zawoła Cancel().
    readonly property alias request: priv.request

    readonly property bool asking: priv.request !== null
    readonly property bool needsAnswer: asking
        && priv.request.kind !== "display-pin"
        && priv.request.kind !== "display-passkey"

    signal cancelled()

    QtObject {
        id: priv

        property bool registered: false
        property bool available: true
        property var request: null
        property int failures: 0
        property double startedAt: 0
    }

    // ---------------------------------------------------------------
    // Odpowiedzi
    // ---------------------------------------------------------------

    function accept(value) { send(true, value); }
    function reject() { send(false, null); }

    function send(ok, value) {
        const req = priv.request;
        if (!req) return;
        priv.request = null;
        // Pytania "do pokazania" mają id 0 i nie czekają na nic — zamknięcie
        // ich to tylko schowanie okienka.
        if (!req.id) return;

        const msg = { cmd: "reply", id: req.id, accept: ok === true };
        if (value !== null && value !== undefined) msg.value = String(value);
        proc.write(JSON.stringify(msg) + "\n");
    }

    // Zamknięcie panelu w trakcie pytania musi być ODMOWĄ, nie zniknięciem:
    // po stronie BlueZ wisiałoby wtedy otwarte wywołanie aż do jego timeoutu,
    // a urządzenie stałoby w połowie parowania.
    function dismiss() { if (priv.request) reject(); }

    Process {
        id: proc

        command: ["python3", Quickshell.shellPath("bt_agent_bridge.py")]
        stdinEnabled: true
        running: true

        stdout: SplitParser {
            splitMarker: "\n"

            onRead: data => {
                let msg;
                try {
                    msg = JSON.parse(data);
                } catch (e) {
                    return;
                }

                if (msg.type === "log") {
                    console.log("[bt-agent] " + msg.text);
                } else if (msg.type === "ready") {
                    priv.registered = msg.registered === true;
                } else if (msg.type === "request") {
                    priv.request = msg;
                } else if (msg.type === "cancel") {
                    // BlueZ (albo timeout mostka) wycofał pytanie. Samo
                    // wyczyszczenie wystarczy — po tamtej stronie nic już
                    // nie czeka na odpowiedź.
                    if (priv.request && (priv.request.id === msg.id || !msg.id))
                        priv.request = null;
                    root.cancelled();
                }
            }
        }

        stderr: SplitParser {
            splitMarker: "\n"
            onRead: data => {
                const t = data.trim();
                if (t !== "") console.warn("[bt_agent_bridge] " + t);
            }
        }

        onStarted: priv.startedAt = Date.now()

        // Mostek kończy się sam tylko przy zamkniętym stdin. Każde inne
        // wyjście to awaria — z tą samą pułapką co w cavie: SIGTERM od
        // Quickshella przy zamykaniu daje kod 15 nie do odróżnienia od
        // padu, ale wtedy singleton i tak ginie i restart nie zdąży ruszyć.
        onExited: (exitCode, exitStatus) => {
            priv.registered = false;
            priv.request = null;

            if (Date.now() - priv.startedAt > 10000) priv.failures = 0;

            if (++priv.failures >= root.maxFailures) {
                priv.available = false;
                console.warn("bt_agent_bridge.py pada zaraz po starcie (kod " + exitCode
                    + ") — parowanie nowych urządzeń nie będzie działać.");
            } else {
                retry.restart();
            }
        }
    }

    Timer {
        id: retry
        interval: root.restartDelayMs
        onTriggered: proc.running = true
    }
}
