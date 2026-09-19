pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// AirPodsy: bateria (lewa, prawa, etui), czujnik ucha i tryb redukcji hałasu.
// Singleton nad airpods_bridge.py — protokół Apple (AAP) idzie po gnieździe
// L2CAP, którego Quickshell nie ma. Mostek sam pilnuje BlueZ i łączy się, gdy
// słuchawki się połączą, więc chodzi cały czas (bezczynny czeka na D-Bus).
Singleton {
    id: root

    // ---------------------------------------------------------------
    // Ustawienia
    // ---------------------------------------------------------------

    property int restartDelayMs: 3000   // po awarii mostka: ile odczekać przed restartem
    property int maxFailures: 3         // tyle szybkich awarii z rzędu = odpuszczamy

    // Zmiana trybu trwa w słuchawkach ~1 s (zmierzone: 1,0–1,6 s od wysłania
    // do potwierdzenia). Do tego czasu karta podświetla wybrany tryb jako
    // "w toku"; jeśli potwierdzenie nie przyjdzie, wraca do rzeczywistego.
    property int modeConfirmTimeoutMs: 3000

    // Połączenie zastane przy starcie (także przy przeładowaniu plików na
    // żywo) nie jest "przyjściem" słuchawek — bez tego każda edycja kodu
    // rozwijałaby wyspę na karcie AirPodsów.
    property int startupGraceMs: 5000

    // ---------------------------------------------------------------
    // Stan
    // ---------------------------------------------------------------

    readonly property alias connected: priv.connected     // kanał AAP otwarty, dane płyną
    readonly property alias name: priv.name
    readonly property alias noiseMode: priv.noiseMode     // "off" | "anc" | "transparency" | "adaptive" | ""
    readonly property alias pendingMode: priv.pendingMode // wysłany, jeszcze niepotwierdzony; "" gdy brak
    readonly property alias left: priv.left               // {level, charging, live}; level -1 = brak odczytu
    readonly property alias right: priv.right
    readonly property alias caseBattery: priv.caseBattery // "case" to słowo kluczowe JS
    readonly property alias leftEar: priv.leftEar         // "ear" | "out" | "case" | ""
    readonly property alias rightEar: priv.rightEar
    readonly property alias available: priv.available
    readonly property alias address: priv.address        // "08:E6:…", "" bez połączenia

    // Ile słuchawek jest w uszach (0–2).
    readonly property int earCount: (priv.leftEar === "ear" ? 1 : 0) + (priv.rightEar === "ear" ? 1 : 0)

    // Czy dźwięk idzie teraz przez AirPodsy. Sink BlueZ nazywa się
    // "bluez_output.08_E6_4B_7F_72_42.1" — adres z podkreślnikami. Pauza po
    // wyjęciu z ucha ma sens tylko wtedy: muzyka z głośników nie ma się
    // zatrzymywać, bo ktoś zdjął słuchawki leżące obok.
    readonly property bool routedHere: {
        const sink = AudioService.current;
        if (!priv.connected || priv.address === "" || !sink) return false;
        return (sink.name || "").indexOf(priv.address.replace(/:/g, "_")) >= 0;
    }

    // Pauza muzyki po wyjęciu słuchawki z ucha (i wznowienie po włożeniu).
    // Zapisywane w pliku, żeby przeżyło restart, nie tylko przeładowanie.
    readonly property bool autoPause: settings.autoPause
    function setAutoPause(on) { settings.autoPause = !!on; }

    // Połączenie po starcie — wyspa pokazuje wtedy na chwilę kartę AirPodsów.
    signal arrived()

    // Zmiana liczby słuchawek w uszach. Tylko prawdziwe przejścia: pierwszy
    // odczyt po połączeniu (ucho "" -> "ear") nie jest wkładaniem słuchawek
    // i nie może wznawiać muzyki, którą użytkownik sam zapauzował.
    signal earsChanged(int previous, int current)

    // Gest nóżki rozpoznany przez mostek: "playpause" | "next" | "previous".
    // Wykonuje go wyspa, bo to ona wybiera odtwarzacz (punktacja MPRIS).
    signal mediaAction(string action)

    // Stan odtwarzania do zameldowania słuchawkom (ustawia wyspa przez
    // Binding). Mostek podaje go BlueZ jako status swojego odtwarzacza AVRCP.
    property bool playing: false
    onPlayingChanged: sendPlayback()

    function sendPlayback() {
        if (proc.running) proc.write(JSON.stringify({ cmd: "playback", playing: root.playing }) + "\n");
    }

    QtObject {
        id: priv
        property bool connected: false
        property string name: ""
        property string noiseMode: ""
        property string pendingMode: ""
        property var left: ({ level: -1, charging: false, live: false })
        property var right: ({ level: -1, charging: false, live: false })
        property var caseBattery: ({ level: -1, charging: false, live: false })
        property string leftEar: ""
        property string rightEar: ""
        property bool available: true
        property string address: ""
        property int failures: 0
        property double startedAt: 0
        property double serviceStart: Date.now()
    }

    function setNoiseMode(mode) {
        if (!priv.connected || !proc.running) return;
        if (mode === priv.noiseMode) {
            priv.pendingMode = "";
            return;
        }
        priv.pendingMode = mode;
        pendingTimer.restart();
        proc.write(JSON.stringify({ cmd: "mode", value: mode }) + "\n");
    }

    // Katalog jest wspólny z konfiguracją Discorda. Brak pliku = pierwszy start:
    // zapisujemy domyślne, żeby było co edytować ręcznie.
    FileView {
        id: settingsFile
        path: Quickshell.env("HOME") + "/.config/quickshell-island/airpods.json"
        watchChanges: true
        onFileChanged: reload()
        onAdapterUpdated: writeAdapter()
        onLoadFailed: error => {
            if (error === FileViewError.FileNotFound) writeAdapter();
        }

        JsonAdapter {
            id: settings
            property bool autoPause: true
        }
    }

    Timer {
        id: pendingTimer
        interval: root.modeConfirmTimeoutMs
        onTriggered: priv.pendingMode = ""
    }

    Timer {
        id: retry
        interval: root.restartDelayMs
        onTriggered: if (priv.available) proc.running = true
    }

    Process {
        id: proc

        command: ["python3", Quickshell.shellPath("airpods_bridge.py")]
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
                    console.log("[airpods] " + msg.text);
                } else if (msg.type === "media") {
                    root.mediaAction(msg.action);
                } else if (msg.type === "state") {
                    const was = priv.connected;
                    const earKnown = priv.leftEar !== "" && priv.rightEar !== "";
                    const earsBefore = root.earCount;
                    priv.name = msg.name || "";
                    priv.address = msg.address || "";
                    priv.noiseMode = msg.noiseMode || "";
                    priv.left = msg.left;
                    priv.right = msg.right;
                    priv.caseBattery = msg["case"];
                    priv.leftEar = msg.leftEar || "";
                    priv.rightEar = msg.rightEar || "";
                    priv.connected = !!msg.connected;

                    // Słuchawki potwierdzają każdy tryb, także ten wymuszony
                    // przez siebie (wyjęcie jednej = "off"), więc pending gasi
                    // dopiero trafienie w wybrany tryb albo timeout.
                    if (priv.pendingMode !== "" && priv.noiseMode === priv.pendingMode) {
                        priv.pendingMode = "";
                        pendingTimer.stop();
                    }
                    if (!priv.connected) priv.pendingMode = "";

                    if (!was && priv.connected && Date.now() - priv.serviceStart > root.startupGraceMs)
                        root.arrived();
                    if (was && priv.connected && earKnown && root.earCount !== earsBefore)
                        root.earsChanged(earsBefore, root.earCount);
                }
            }
        }

        stderr: SplitParser {
            splitMarker: "\n"
            onRead: data => {
                const t = data.trim();
                if (t !== "") console.warn("[airpods_bridge] " + t);
            }
        }

        onStarted: {
            priv.startedAt = Date.now();
            root.sendPlayback();
        }

        // Mostek kończy się sam tylko przy zamkniętym stdin, więc każde wyjście
        // w trakcie działania to awaria (albo SIGTERM przy zamykaniu Quickshella —
        // wtedy singleton i tak ginie razem z nim, restart nie zdąży ruszyć).
        onExited: (exitCode, exitStatus) => {
            priv.connected = false;
            priv.pendingMode = "";

            if (Date.now() - priv.startedAt > 10000) priv.failures = 0;

            if (++priv.failures >= root.maxFailures) {
                priv.available = false;
                console.warn("airpods_bridge.py pada zaraz po starcie (kod " + exitCode + "), karta AirPodsów wyłączona.");
            } else {
                retry.restart();
            }
        }
    }
}
