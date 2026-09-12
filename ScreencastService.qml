pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Wykrywanie udostępniania ekranu przez PipeWire. Na Waylandzie każde
// przechwytywanie ekranu (Discord, OBS, przeglądarka, portal) to strumień
// wideo z kompozytora do aplikacji, więc szukamy działającego węzła
// Stream/Input/Video, który nie należy do samego pulpitu.
//
// Zamiast odpytywać pw-dump co kilka sekund (tak robiła stara wyspa) trzymamy
// `pw-dump -m`: pierwszy zrzut to wszystkie obiekty, potem przychodzi tablica
// z każdą zmianą, a usunięty obiekt to {"id": N, "info": null}. Aktualizacja
// węzła zawiera pełny stan i właściwości (nie deltę), więc wystarczy
// podmienić wpis w mapie.
Singleton {
    id: root

    // ---------------------------------------------------------------
    // Ustawienia
    // ---------------------------------------------------------------

    // Odbiorcy strumienia wideo, którzy NIE są udostępnianiem ekranu:
    // plasmashell konsumuje kwin_wayland na potrzeby miniatur okien.
    property var ignoredApps: ["plasmashell"]

    property int restartDelayMs: 3000
    property int maxFailures: 3

    // ---------------------------------------------------------------
    // Stan
    // ---------------------------------------------------------------

    readonly property alias active: priv.active
    readonly property alias appName: priv.appName        // kto odbiera ekran
    readonly property alias startTime: priv.startTime    // epoch ms startu, 0 gdy nic
    readonly property alias available: priv.available    // false = pw-dump nie działa
    readonly property alias elapsedSeconds: priv.elapsedSeconds

    QtObject {
        id: priv
        property bool active: false
        property string appName: ""
        property double startTime: 0
        property bool available: true
        property int elapsedSeconds: 0
        property int failures: 0
        property double startedAt: 0
        property bool stopRequested: false

        // id węzła -> { cls, app, state } dla węzłów wideo. Reszty nie trzymamy.
        property var nodes: ({})
        property var lines: []
    }

    function stopMonitor() {
        if (!proc.running) return;
        priv.stopRequested = true;
        proc.running = false;
    }

    // Ta sama pułapka co z timerem rozmowy: Timer 1000 ms dryfuje i licznik
    // potrafi skoczyć o 2. SystemClock tyka równo z sekundą.
    SystemClock {
        id: shareClock
        precision: SystemClock.Seconds
        enabled: priv.active && priv.startTime > 0
    }

    Binding {
        target: priv
        property: "elapsedSeconds"
        value: (priv.active && priv.startTime > 0)
            ? Math.max(0, Math.floor((shareClock.date.getTime() - priv.startTime) / 1000))
            : 0
    }

    function applyUpdate(objects) {
        let changed = false;

        for (let i = 0; i < objects.length; i++) {
            const o = objects[i];
            if (o.info === null) {
                if (o.id in priv.nodes) {
                    delete priv.nodes[o.id];
                    changed = true;
                }
                continue;
            }
            if (o.type !== "PipeWire:Interface:Node") continue;

            const props = (o.info && o.info.props) || {};
            const cls = props["media.class"] || "";
            if (cls !== "Stream/Input/Video") {
                // Węzeł mógł zmienić klasę — mało prawdopodobne, ale tanie.
                if (o.id in priv.nodes) { delete priv.nodes[o.id]; changed = true; }
                continue;
            }

            priv.nodes[o.id] = {
                app: props["application.name"] || props["node.name"] || "",
                state: (o.info && o.info.state) || ""
            };
            changed = true;
        }

        if (changed) root.evaluate();
    }

    function evaluate() {
        let app = "";
        const ids = Object.keys(priv.nodes);

        for (let i = 0; i < ids.length; i++) {
            const n = priv.nodes[ids[i]];
            if (n.state !== "running") continue;
            if (root.ignoredApps.indexOf(n.app) !== -1) continue;
            app = n.app !== "" ? n.app : "Nieznana aplikacja";
            break;
        }

        const nowActive = app !== "";
        if (nowActive && !priv.active) {
            priv.startTime = Date.now();
            console.log("[screencast] start udostępniania: " + app);
        } else if (!nowActive && priv.active) {
            priv.startTime = 0;
            console.log("[screencast] koniec udostępniania");
        }

        priv.active = nowActive;
        priv.appName = app;
    }

    Timer {
        id: retry
        interval: root.restartDelayMs
        onTriggered: if (priv.available) proc.running = true
    }

    Process {
        id: proc

        command: ["pw-dump", "-m", "-N"]
        running: true

        // pw-dump drukuje tablice wieloliniowo. Granica to samotny "]" na
        // początku linii — wszystko w środku jest wcięte, więc nie ma
        // fałszywych trafień.
        stdout: SplitParser {
            splitMarker: "\n"

            onRead: data => {
                priv.lines.push(data);
                if (data !== "]") return;

                const text = priv.lines.join("\n");
                priv.lines = [];

                let objects;
                try {
                    objects = JSON.parse(text);
                } catch (e) {
                    console.warn("[screencast] nieczytelna tablica z pw-dump, pomijam");
                    return;
                }
                if (Array.isArray(objects)) root.applyUpdate(objects);
            }
        }

        onStarted: {
            priv.startedAt = Date.now();
            priv.nodes = ({});
            priv.lines = [];
        }

        onExited: (exitCode, exitStatus) => {
            priv.nodes = ({});
            priv.lines = [];
            root.evaluate();

            // SIGTERM od Quickshella daje exitCode 15 / CrashExit — patrz CavaService.
            if (priv.stopRequested) {
                priv.stopRequested = false;
                return;
            }

            if (Date.now() - priv.startedAt > 10000) priv.failures = 0;

            if (++priv.failures >= root.maxFailures) {
                priv.available = false;
                console.warn("pw-dump -m nie działa (kod " + exitCode + "), status udostępniania ekranu wyłączony.");
            } else {
                retry.restart();
            }
        }
    }
}
