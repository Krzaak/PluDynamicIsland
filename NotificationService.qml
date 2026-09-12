pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Notifications

// Powiadomienia pulpitu i transfery plików KDE — dwa różne mechanizmy:
//
// 1. org.freedesktop.Notifications: wbudowany NotificationServer Quickshella.
//    Rejestruje się tylko wtedy, gdy nazwa jest WOLNA — Quickshell nie umie
//    jej wyrwać Plasmie i po nieudanej próbie nie ponawia. Dlatego serwer
//    siedzi w Loaderze, a przed załadowaniem sprawdzamy właściciela nazwy
//    (dbus-send NameHasOwner) i pytamy ponownie co ownerCheckMs. W praktyce
//    trzeba wyłączyć aplet powiadomień w zasobniku Plasmy.
//
// 2. org.kde.JobViewServer (kopiowanie w Dolphinie, pobieranie): mostek
//    kde_jobs_bridge.py, bo Quickshell nie wystawia własnych obiektów D-Bus.
//    Mostek czeka w kolejce o nazwę i przejmuje ją, gdy Plasma zwolni.
Singleton {
    id: root

    // ---------------------------------------------------------------
    // Ustawienia
    // ---------------------------------------------------------------

    property int historyLimit: 30
    property int ownerCheckMs: 5000     // co ile pytać, czy nazwa Notifications jest wolna
    property int popupDuration: 5000    // po tylu ms dymek schodzi z karty (samo powiadomienie żyje dalej)

    // ---------------------------------------------------------------
    // Stan
    // ---------------------------------------------------------------

    readonly property alias serverActive: priv.serverActive   // jesteśmy demonem powiadomień
    readonly property alias jobsOwned: priv.jobsOwned         // mostek trzyma org.kde.JobViewServer
    readonly property alias history: priv.history             // wpisy, najnowszy pierwszy
    readonly property alias latest: priv.latest               // najnowszy wpis powiadomienia (z żywym obiektem) lub null
    readonly property alias jobs: priv.jobs                   // trwające transfery, najstarszy pierwszy
    readonly property var activeJob: priv.jobs.length > 0 ? priv.jobs[0] : null
    readonly property bool hasJobs: priv.jobs.length > 0

    // Zbiorczy postęp dla paska pod wyspą: średnia z trwających zadań.
    readonly property real jobProgress: {
        if (priv.jobs.length === 0) return 0;
        let sum = 0;
        for (let i = 0; i < priv.jobs.length; i++) sum += priv.jobs[i].percent;
        return Math.max(0, Math.min(1, sum / priv.jobs.length / 100));
    }

    // Trzymanie wstrzymuje wygaszanie najnowszego powiadomienia — wyspa
    // ustawia je, gdy kursor jest na niej, żeby dało się kliknąć akcję.
    property bool held: false

    // DesktopEntries skanuje pliki .desktop asynchronicznie i dopiero przy
    // PIERWSZYM dotknięciu: sonda pokazała 0 wpisów w chwili pierwszego
    // odczytu i 147 półtorej sekundy później. To powiązanie jest tym
    // dotknięciem (skan rusza razem z wyspą, a nie przy pierwszym
    // powiadomieniu) i zarazem zależnością, po której karta przelicza id
    // aplikacji, gdy lista dojedzie — samo wołanie appIdFor() w powiązaniu
    // niczego by nie przeliczyło, bo funkcja nie jest zależnością.
    readonly property int appCount: DesktopEntries.applications.values.length

    signal notified(var entry)     // nowe powiadomienie
    signal jobStarted(var job)
    signal jobEnded(var job)

    QtObject {
        id: priv
        property bool serverActive: false
        property bool jobsOwned: false
        property var history: []
        property var latest: null
        property var jobs: []
        property int nextEntryId: 1
        property var openQueue: []          // appId czekające na aktywator okien
        property bool bridgeStopRequested: false
        property int bridgeFailures: 0
        property double bridgeStartedAt: 0
    }

    // ---------------------------------------------------------------
    // Pomocnicze
    // ---------------------------------------------------------------

    // Wpis .desktop aplikacji, z której przyszło powiadomienie albo zadanie:
    // podpowiedź desktop-entry jest pewna, sama nazwa aplikacji to już
    // zgadywanie (heurystyka Quickshella po nazwie i klasie okna). null,
    // gdy nic nie pasuje — wtedy nie ma czego otwierać.
    function resolveApp(desktopEntry, appName) {
        let entry = null;
        if (desktopEntry && desktopEntry !== "") entry = DesktopEntries.byId(desktopEntry);
        if (!entry && appName && appName !== "") entry = DesktopEntries.heuristicLookup(appName);
        return entry;
    }

    // Id wpisu .desktop dla wpisu historii albo "" — nie ma czego otwierać.
    //
    // Rozwiązujemy przy wyświetlaniu wiersza, nie przy zapisie do historii:
    // lista aplikacji dojeżdża kilka sekund po starcie (patrz appCount),
    // więc powiadomienie z tego okna zapamiętałoby puste id na zawsze,
    // a karta i tak ogląda historię długo później.
    function appIdFor(entry) {
        const app = resolveApp(entry.appHint, entry.appName);
        return app ? app.id : "";
    }

    // Ikona: obraz z powiadomienia > appIcon (nazwa z motywu lub ścieżka)
    // > ikona z pliku .desktop. Pusty string = brak, karta pokaże dzwonek.
    function resolveIcon(n) {
        const asSource = s => {
            if (!s || s === "") return "";
            // Quickshell opakowuje ścieżkę z podpowiedzi image-path w image://icon/…,
            // a ten dostawca nie umie ładować plików ("Could not load icon … from
            // request"). Zmierzone z notify-send -i /ścieżka.png. Odwijamy do file://.
            if (s.startsWith("image://icon//")) return "file://" + s.substring("image://icon/".length);
            if (s.startsWith("/")) return "file://" + s;
            if (s.startsWith("file://") || s.startsWith("data:") || s.startsWith("image://")) return s;
            return Quickshell.iconPath(s, true);
        };

        let src = asSource(n.image);
        if (src !== "") return src;
        src = asSource(n.appIcon);
        if (src !== "") return src;

        const entry = resolveApp(n.desktopEntry, n.appName);
        if (entry && entry.icon && entry.icon !== "") return asSource(entry.icon);
        return "";
    }

    // Treść może przyjść z markupem (<b>, <a>, <img>) — w wyspie jest na
    // to za mało miejsca, zostawiamy goły tekst.
    function plainText(s) {
        return (s || "")
            .replace(/<br\s*\/?>/gi, " ")
            .replace(/<[^>]+>/g, "")
            .replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, "\"")
            .replace(/&apos;/g, "'").replace(/&amp;/g, "&")
            .replace(/\s+/g, " ").trim();
    }

    function formatBytes(b) {
        if (!isFinite(b) || b <= 0) return "0 B";
        const units = ["B", "KB", "MB", "GB", "TB"];
        let i = 0;
        let v = b;
        while (v >= 1000 && i < units.length - 1) { v /= 1000; i++; }
        return (i === 0 ? v : v.toFixed(v < 10 ? 1 : 0)) + " " + units[i];
    }

    function pushHistory(entry) {
        // Id nadaje wyłącznie to miejsce. Po nim rozpoznajemy wpis, gdy wraca
        // do nas kopią z wiersza historii (patrz removeEntry), więc dwa wpisy
        // z tym samym id kasowałyby się hurtem.
        entry.id = priv.nextEntryId++;

        const h = priv.history.slice();
        h.unshift(entry);
        // Wpis wypadający poza limit trzeba zamknąć, inaczej aplikacja czekałaby
        // na NotificationClosed w nieskończoność — powiadomienia żyją tu tak
        // długo, jak wpis w historii.
        while (h.length > root.historyLimit) {
            const dropped = h.pop();
            if (dropped.notification) dropped.notification.dismiss();
        }
        priv.history = h;
    }

    function clearHistory() {
        for (let i = 0; i < priv.history.length; i++)
            if (priv.history[i].notification) priv.history[i].notification.dismiss();
        priv.latest = null;
        priv.history = [];
    }

    // Otwiera aplikację, z której przyszedł wpis: najpierw próbujemy podnieść
    // jej okno, a dopiero gdy takiego okna nie ma — uruchamiamy aplikację.
    //
    // Sama kolejność jest tu istotna. `DesktopEntry.execute()` na działającej
    // aplikacji nic nie podnosi (tak zgłoszony był błąd: Discord otwarty,
    // klik nie przełącza na niego), a aplikacji bez pilnowania pojedynczej
    // instancji otworzyłby drugie okno. Podnoszenie robi window_activator.py,
    // bo QML nie ma na KWinie dostępu do listy okien — szczegóły w jego
    // nagłówku. Zwraca, czy było co otwierać.
    function openApp(appId) {
        if (!appId || appId === "") return false;
        if (!DesktopEntries.byId(appId)) {
            console.warn("Powiadomienia: nie ma już wpisu .desktop \"" + appId + "\", nie otwieram.");
            return false;
        }
        priv.openQueue = priv.openQueue.concat([appId]);
        pumpOpenQueue();
        return true;
    }

    // Otwarcie wpisu tak, jak robiła to Plasma. W powiadomieniu nie ma żadnego
    // adresu ani "miejsca" — jest akcja domyślna ("default" w
    // org.freedesktop.Notifications) i to ona przenosi aplikację do rozmowy,
    // wątku czy pliku, którego powiadomienie dotyczy. Klik w dymek Plasmy
    // robił dokładnie tyle: ActionInvoked("default").
    //
    // Samo invoke() nie daje jednak fokusu (aplikacja nie ma tokena aktywacji),
    // więc zaraz po nim podnosimy okno. Gdy akcji nie ma — a tak jest w każdym
    // wpisie, który aplikacja już zamknęła — zostaje samo okno.
    function openEntry(entry) {
        if (!entry) return false;

        const appId = appIdFor(entry);
        const actions = entry.actions || [];
        let def = null;
        for (let i = 0; i < actions.length; i++)
            if (actions[i].identifier === "default") def = actions[i];

        if (def) def.action.invoke();
        openApp(appId);
        return def !== null || appId !== "";
    }

    // Jeden proces aktywatora na raz — kolejne kliknięcia czekają w kolejce.
    function pumpOpenQueue() {
        if (activator.running || priv.openQueue.length === 0) return;
        const appId = priv.openQueue[0];
        const app = DesktopEntries.byId(appId);
        if (!app) {
            priv.openQueue = priv.openQueue.slice(1);
            pumpOpenQueue();
            return;
        }
        // startupClass (StartupWMClass z .desktop) bywa jedyną rzeczą, po
        // której da się poznać okno — Spotify ma id "spotify-launcher",
        // a klasę okna "Spotify".
        activator.command = ["python3", Quickshell.shellPath("window_activator.py"),
                             appId, app.startupClass || "", app.name || ""];
        activator.running = true;
    }

    Process {
        id: activator

        stderr: SplitParser {
            splitMarker: "\n"
            onRead: data => { const t = data.trim(); if (t !== "") console.log("[okno] " + t); }
        }

        onExited: (exitCode, exitStatus) => {
            const appId = priv.openQueue.length > 0 ? priv.openQueue[0] : "";
            priv.openQueue = priv.openQueue.slice(1);

            // 0 = okno podniesione. Każdy inny kod (brak okna, brak KWina,
            // brak python-dbus) znaczy tyle samo: nie ma czego podnosić,
            // więc uruchamiamy aplikację normalnie.
            if (exitCode !== 0 && appId !== "") {
                const app = DesktopEntries.byId(appId);
                if (app) app.execute();
            }
            pumpOpenQueue();
        }
    }

    // Wpis podany przez wiersz historii to KOPIA, nie ten sam obiekt: model
    // ListView jest tablicą JS, przechodzi przez QVariant i delegat dostaje
    // odtworzony obiekt (zmierzone: modelData === history[0] daje false).
    // Dlatego wpisy mają własne `id` i szukamy po nim — porównanie tożsamości
    // nie trafiało nigdy, więc kliknięcie po prostu nic nie kasowało.
    // QObject-y w środku kopii (notification, action) przeżywają konwersję jako
    // wskaźniki, stąd otwieranie wpisu działało mimo tego samego mechanizmu.
    function removeEntry(entry) {
        if (!entry) return;
        const id = entry.id;

        for (let i = 0; i < priv.history.length; i++)
            if (priv.history[i].id === id && priv.history[i].notification)
                priv.history[i].notification.dismiss();

        if (priv.latest && priv.latest.id === id) priv.latest = null;
        priv.history = priv.history.filter(e => e.id !== id);
    }

    // ---------------------------------------------------------------
    // Serwer powiadomień
    // ---------------------------------------------------------------

    function handleNotification(n) {
        n.tracked = true;

        const entry = {
            kind: "notification",
            appName: n.appName || "",
            summary: n.summary || "",
            body: plainText(n.body),
            icon: resolveIcon(n),
            appHint: n.desktopEntry || "",   // podpowiedź desktop-entry, rozwiązywana leniwie
            time: new Date(),
            urgency: n.urgency,
            actions: n.actions.map(a => ({ identifier: a.identifier, text: a.text, action: a })),
            notification: n
        };

        pushHistory(entry);
        priv.latest = entry;
        expiry.restart();
        root.notified(entry);
    }

    function onNotificationClosed(n) {
        // Obiekt ginie po zamknięciu — wpis w historii zostaje, ale bez akcji.
        const h = priv.history.slice();
        let changed = false;
        for (let i = 0; i < h.length; i++) {
            if (h[i].notification === n) {
                h[i] = Object.assign({}, h[i], { notification: null, actions: [] });
                if (priv.latest && priv.latest.notification === n) priv.latest = null;
                changed = true;
            }
        }
        if (changed) priv.history = h;
    }

    // Dymek schodzi z karty, ale powiadomienie ZOSTAJE otwarte. Wygaszenie
    // (expire) posyła aplikacji NotificationClosed, a wtedy giną jego akcje —
    // razem z akcją domyślną, czyli jedyną rzeczą, która przenosi aplikację do
    // właściwej rozmowy. Bez tego wpis w historii można już tylko otworzyć na
    // "stronie głównej" aplikacji. Plasma trzyma je tak samo: zamyka dopiero,
    // gdy wpis zniknie z historii.
    Timer {
        id: expiry
        interval: root.popupDuration
        running: priv.latest !== null && !root.held
        onTriggered: priv.latest = null
    }

    Loader {
        id: serverLoader
        active: false

        sourceComponent: NotificationServer {
            keepOnReload: true
            bodySupported: true
            bodyMarkupSupported: true
            actionsSupported: true
            imageSupported: true
            persistenceSupported: false

            onNotification: n => {
                root.handleNotification(n);
                n.closed.connect(() => root.onNotificationClosed(n));
            }
        }
    }

    // Czy ktoś trzyma org.freedesktop.Notifications. Gdy nikt — ładujemy serwer.
    // Po załadowaniu sprawdzamy raz jeszcze: jeśli nazwa dalej jest wolna,
    // Quickshell się nie zarejestrował (log to powie) i próbujemy od nowa.
    Process {
        id: ownerCheck
        command: ["dbus-send", "--session", "--print-reply", "--dest=org.freedesktop.DBus",
                  "/org/freedesktop/DBus", "org.freedesktop.DBus.NameHasOwner",
                  "string:org.freedesktop.Notifications"]

        stdout: StdioCollector {
            onStreamFinished: {
                const hasOwner = text.indexOf("boolean true") !== -1;
                if (!serverLoader.active) {
                    if (!hasOwner) {
                        serverLoader.active = true;
                        verify.restart();
                    }
                } else if (hasOwner) {
                    priv.serverActive = true;
                } else {
                    console.warn("Powiadomienia: serwer Quickshella nie zarejestrował się mimo wolnej nazwy, ponawiam.");
                    serverLoader.active = false;
                }
            }
        }
    }

    Timer {
        id: verify
        interval: 1500
        onTriggered: ownerCheck.running = true
    }

    Timer {
        running: !priv.serverActive
        interval: root.ownerCheckMs
        repeat: true
        triggeredOnStart: true
        onTriggered: if (!ownerCheck.running && !verify.running) ownerCheck.running = true
    }

    // ---------------------------------------------------------------
    // Transfery plików (mostek JobViewServer)
    // ---------------------------------------------------------------

    function cancelJob(id) { bridgeSend({ cmd: "cancel", id: id }); }
    function suspendJob(id) { bridgeSend({ cmd: "suspend", id: id }); }
    function resumeJob(id) { bridgeSend({ cmd: "resume", id: id }); }

    function bridgeSend(obj) {
        if (!bridge.running) return;
        bridge.write(JSON.stringify(obj) + "\n");
    }

    function jobIcon(job) {
        const entry = resolveApp(job.desktopEntry, job.applicationName);
        if (entry && entry.icon) return Quickshell.iconPath(entry.icon, true);
        if (job.applicationIconName && job.applicationIconName !== "") return Quickshell.iconPath(job.applicationIconName, true);
        return "";
    }

    // Etykieta zadania: KIO daje title ("Kopiowanie"), stare API tylko infoMessage.
    function jobTitle(job) {
        if (job.title && job.title !== "") return job.title;
        if (job.infoMessage && job.infoMessage !== "") return job.infoMessage;
        return "Transfer plików";
    }

    function handleJobMessage(msg) {
        const jobs = priv.jobs.slice();
        const idx = jobs.findIndex(j => j.id === msg.id);
        const job = Object.assign({}, msg);
        delete job.type;
        delete job.event;
        job.icon = idx >= 0 ? jobs[idx].icon : jobIcon(job);

        if (msg.event === "end") {
            if (idx >= 0) jobs.splice(idx, 1);
            priv.jobs = jobs;
            pushHistory({
                kind: "job",
                appName: job.applicationName || "",
                summary: (job.error !== 0 ? "Nie udało się: " : "Ukończono: ") + jobTitle(job),
                body: job.error !== 0 ? (job.errorMessage || "") : (job.descriptionValue1 || ""),
                icon: job.icon,
                appHint: job.desktopEntry || "",
                time: new Date(),
                urgency: job.error !== 0 ? NotificationUrgency.Critical : NotificationUrgency.Low,
                actions: [],
                notification: null
            });
            root.jobEnded(job);
            return;
        }

        if (idx >= 0) jobs[idx] = job; else jobs.push(job);
        priv.jobs = jobs;
        if (msg.event === "start") root.jobStarted(job);
    }

    Timer {
        id: bridgeRetry
        interval: 3000
        onTriggered: bridge.running = true
    }

    Process {
        id: bridge
        command: ["python3", Quickshell.shellPath("kde_jobs_bridge.py")]
        stdinEnabled: true
        running: true

        stdout: SplitParser {
            splitMarker: "\n"
            onRead: data => {
                let msg;
                try { msg = JSON.parse(data); } catch (e) { return; }
                if (msg.type === "log") console.log("[jobs] " + msg.text);
                else if (msg.type === "owner") priv.jobsOwned = !!msg.owned;
                else if (msg.type === "job") root.handleJobMessage(msg);
            }
        }

        stderr: SplitParser {
            splitMarker: "\n"
            onRead: data => { const t = data.trim(); if (t !== "") console.warn("[kde_jobs_bridge] " + t); }
        }

        onStarted: priv.bridgeStartedAt = Date.now()

        onExited: (exitCode, exitStatus) => {
            priv.jobsOwned = false;
            priv.jobs = [];
            if (priv.bridgeStopRequested) { priv.bridgeStopRequested = false; return; }
            if (Date.now() - priv.bridgeStartedAt > 10000) priv.bridgeFailures = 0;
            if (++priv.bridgeFailures >= 3) {
                console.warn("kde_jobs_bridge.py pada zaraz po starcie (kod " + exitCode + "), transfery plików wyłączone.");
            } else {
                bridgeRetry.restart();
            }
        }
    }
}
