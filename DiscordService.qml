pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Stan rozmowy głosowej na Discordzie. Singleton nad mostkiem discord_bridge.py —
// Quickshell.Io.Socket nie umie ramek binarnych (pisze i czyta tylko tekst), więc
// z gniazdem RPC rozmawia Python, a tu przychodzi JSON linia po linii.
Singleton {
    id: root

    // ---------------------------------------------------------------
    // Ustawienia
    // ---------------------------------------------------------------

    property int restartDelayMs: 3000   // po awarii mostka: ile odczekać przed restartem
    property int maxFailures: 3         // tyle szybkich awarii z rzędu = odpuszczamy

    // ---------------------------------------------------------------
    // Stan
    // ---------------------------------------------------------------

    readonly property alias connected: priv.connected     // mostek uwierzytelniony w Discordzie
    readonly property alias inVoice: priv.inVoice
    readonly property alias channelName: priv.channelName
    readonly property alias muted: priv.muted
    readonly property alias deafened: priv.deafened
    readonly property alias callStart: priv.callStart      // epoch ms wejścia na kanał, 0 poza nim
    readonly property alias error: priv.error              // krótki opis po polsku dla karty, "" gdy OK
    readonly property alias available: priv.available      // false = mostek nie działa (brak konfiguracji, awarie)
    readonly property alias elapsedSeconds: priv.elapsedSeconds

    // Gdzie mostek szuka client_id / client_secret — do komunikatu dla użytkownika.
    readonly property string configPath: Quickshell.env("HOME") + "/.config/quickshell-island/discord.json"

    QtObject {
        id: priv
        property bool connected: false
        property bool inVoice: false
        property string channelName: ""
        property bool muted: false
        property bool deafened: false
        property double callStart: 0
        property string error: ""
        property bool available: true
        property int elapsedSeconds: 0
        property int failures: 0
        property double startedAt: 0
        property bool stopRequested: false
    }

    function setMute(muted) { send({ cmd: "mute", value: !!muted }); }
    function setDeafen(deafened) { send({ cmd: "deafen", value: !!deafened }); }
    function leave() { send({ cmd: "leave" }); }

    function send(obj) {
        if (!proc.running) return;
        proc.write(JSON.stringify(obj) + "\n");
    }

    function stopBridge() {
        if (!proc.running) return;
        priv.stopRequested = true;
        proc.running = false;
    }

    // Timer rozmowy liczony po naszej stronie z callStart, żeby mostek nie musiał
    // wysyłać ramki co sekundę. SystemClock zamiast Timer celowo: Timer z
    // interwałem 1000 ms dryfuje i co jakiś czas dwa odczyty wypadają po obu
    // stronach granicy sekundy (0,99 s -> 2,01 s), przez co licznik skakał o 2.
    // SystemClock tyka równo z sekundą zegara, więc przyrost jest zawsze 1.
    SystemClock {
        id: callClock
        precision: SystemClock.Seconds
        enabled: priv.inVoice && priv.callStart > 0
    }

    Binding {
        target: priv
        property: "elapsedSeconds"
        value: (priv.inVoice && priv.callStart > 0)
            ? Math.max(0, Math.floor((callClock.date.getTime() - priv.callStart) / 1000))
            : 0
    }

    Timer {
        id: retry
        interval: root.restartDelayMs
        onTriggered: if (priv.available) proc.running = true
    }

    Process {
        id: proc

        command: ["python3", Quickshell.shellPath("discord_bridge.py")]
        stdinEnabled: true
        running: true

        stdout: SplitParser {
            splitMarker: "\n"

            onRead: data => {
                let msg;
                try {
                    msg = JSON.parse(data);
                } catch (e) {
                    return;   // śmieci (np. traceback Pythona) — nie nasze linie
                }

                if (msg.type === "log") {
                    console.log("[discord] " + msg.text);
                } else if (msg.type === "state") {
                    priv.connected = !!msg.connected;
                    priv.inVoice = !!msg.inVoice;
                    priv.channelName = msg.channelName || "";
                    priv.muted = !!msg.muted;
                    priv.deafened = !!msg.deafened;
                    priv.callStart = Number(msg.callStart) || 0;
                    priv.error = msg.error || "";
                }
            }
        }

        stderr: SplitParser {
            splitMarker: "\n"
            onRead: data => {
                const t = data.trim();
                if (t !== "") console.warn("[discord_bridge] " + t);
            }
        }

        onStarted: priv.startedAt = Date.now()

        onExited: (exitCode, exitStatus) => {
            priv.connected = false;
            priv.inVoice = false;
            priv.channelName = "";
            priv.callStart = 0;

            // Sami zatrzymaliśmy. Ta sama pułapka co z cavą: SIGTERM od Quickshella
            // daje exitCode 15 / CrashExit, nie do odróżnienia od awarii.
            if (priv.stopRequested) {
                priv.stopRequested = false;
                return;
            }

            // Kod 3 = brak pliku konfiguracji. Restart nic nie da.
            if (exitCode === 3) {
                priv.available = false;
                priv.error = "brak konfiguracji";
                console.warn("Discord: brak " + root.configPath + " (client_id + client_secret) — karta Discorda wyłączona.");
                return;
            }

            // Mostek żył długo — pojedyncze potknięcie nie ma się sumować przez godziny.
            if (Date.now() - priv.startedAt > 10000) priv.failures = 0;

            if (++priv.failures >= root.maxFailures) {
                priv.available = false;
                priv.error = "mostek nie działa";
                console.warn("discord_bridge.py pada zaraz po starcie (kod " + exitCode + "), odpuszczam.");
            } else {
                retry.restart();
            }
        }
    }
}
