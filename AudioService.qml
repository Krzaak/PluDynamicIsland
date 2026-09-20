pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Services.Pipewire

// Wyjścia dźwięku (sinki PipeWire) i przełączanie domyślnego. Cienka warstwa
// nad Quickshell.Services.Pipewire: lista sinków jest przeliczana z modelu
// węzłów, a wybór idzie przez preferredDefaultAudioSink (metadane
// default.configured.audio.sink — WirePlumber zapamiętuje je jak pavucontrol).
//
// Pipewire ładuje się asynchronicznie: przez kilka sekund po starcie `ready`
// jest false, lista pusta, a defaultAudioSink null. Wszystko poniżej znosi null.
Singleton {
    id: root

    // ---------------------------------------------------------------
    // Stan
    // ---------------------------------------------------------------

    // Sinki audio (bez strumieni aplikacji), w kolejności pojawienia się.
    readonly property alias sinks: priv.sinks
    readonly property var current: Pipewire.defaultAudioSink
    readonly property string currentLabel: current ? sinkLabel(current) : "Brak wyjścia"
    readonly property string currentIcon: current ? sinkIcon(current) : "speaker"

    // Krótka nazwa do pigułki: nickname ("ALC1220 Analog", "HDMI 0") jest
    // najkrótszy; description to pełne "Built-in Audio Analog Stereo".
    function sinkLabel(node) {
        if (!node) return "";
        return node.nickname || node.description || node.name || "?";
    }

    // Ikona po nazwie węzła — PipeWire nie zdradza form factora bez bindowania.
    function sinkIcon(node) {
        const n = ((node.name || "") + " " + (node.description || "")).toLowerCase();
        if (n.indexOf("hdmi") >= 0 || n.indexOf("displayport") >= 0) return "computer";
        if (n.indexOf("bluez") >= 0 || n.indexOf("headset") >= 0 || n.indexOf("headphone") >= 0) return "headset";
        return "speaker";
    }

    // ---- głośność bieżącego wyjścia ----
    // `audio` (a w nim volume/muted) istnieje TYLKO dla węzła związanego przez
    // PwObjectTracker — bez tego jest null, tak samo jak przy mikrofonie.
    // Wiążemy wyłącznie bieżące wyjście, nie wszystkie sinki: wiązanie każdego
    // trzymałoby otwarte obiekty PipeWire bez żadnego pożytku.
    //
    // Skala jest ta sama, co w `wpctl get-volume` (zmierzone: 0,75 po obu
    // stronach), czyli 0–1 liniowo — nie procenty i nie krzywa sześcienna.
    readonly property bool volumeReady: current !== null && current.ready && current.audio !== null
    readonly property real volume: volumeReady ? current.audio.volume : 0
    readonly property bool muted: volumeReady && current.audio.muted

    // O ile zmienia głośność jeden ZĄBEK kółka (nie pojedyncze zdarzenie).
    property real volumeStep: 0.03

    // Jeden ząbek myszy to 120 jednostek angleDelta. Touchpad przysyła zamiast
    // tego drobne porcje po kilka-kilkanaście jednostek, więc trzeba je
    // sumować — inaczej JEDNO machnięcie palcem daje kilkadziesiąt pełnych
    // kroków i głośność skacze od zera do maksimum. To ta sama stała, co
    // wheelStepDelta przy przewijaniu kart.
    property int volumeWheelDelta: 120

    function setVolume(value) {
        if (!volumeReady) return;
        current.audio.volume = Math.max(0, Math.min(1, value));
    }

    function stepVolume(delta) {
        if (!volumeReady) return;
        // Podgłośnienie wyciszonego wyjścia ma je odciszyć — inaczej procent
        // rośnie, a z głośników dalej nic nie leci.
        if (muted && delta > 0) current.audio.muted = false;
        // Zaokrąglenie do pełnego procentu: bez niego kółko zostawia wartości
        // w rodzaju 0,4733 i ten sam ruch dwa razy daje inny wynik.
        setVolume(Math.round((root.volume + delta) * 100) / 100);
    }

    function toggleMute() {
        if (volumeReady) current.audio.muted = !current.audio.muted;
    }

    // ---- zmiana głośności spoza wyspy ----
    // Klawisze multimedialne, pavucontrol, cokolwiek. Wyspa pokazuje po tym
    // pasek w zwiniętej pigułce, jak HUD głośności w iOS.
    signal volumeNudged()

    // Pierwszy odczyt po starcie i po przełączeniu wyjścia NIE jest zmianą:
    // wartość skacze z zera na rzeczywistą albo na głośność innego urządzenia,
    // a wyspa mrugałaby paskiem bez powodu. -1 = nie mamy jeszcze punktu
    // odniesienia, więc najbliższy odczyt tylko go ustawia.
    property real knownVolume: -1
    property bool knownMuted: false

    onCurrentChanged: knownVolume = -1
    onVolumeReadyChanged: if (!volumeReady) knownVolume = -1

    onVolumeChanged: noteVolume()
    onMutedChanged: noteVolume()

    function noteVolume() {
        if (!volumeReady) return;

        const hadBaseline = knownVolume >= 0;
        // Porównanie z tolerancją: głośność to float i PipeWire potrafi
        // przysłać tę samą wartość z drobną różnicą na końcówce.
        const changed = hadBaseline
            && (Math.abs(volume - knownVolume) > 0.0005 || muted !== knownMuted);

        knownVolume = volume;
        knownMuted = muted;

        if (changed) root.volumeNudged();
    }

    PwObjectTracker {
        objects: root.current ? [root.current] : []
    }

    function selectSink(node) {
        if (!node) return;
        Pipewire.preferredDefaultAudioSink = node;
    }

    // Następne wyjście z listy (cyklicznie). Przy jednym sinku nic nie robi.
    function cycleSink() {
        const s = priv.sinks;
        if (s.length < 2) return;
        let i = s.indexOf(root.current);
        i = (i + 1) % s.length;
        selectSink(s[i]);
    }

    // ---- mikrofon ----
    // Wyciszenie "systemowe" obejmuje WSZYSTKIE źródła, nie tylko domyślne:
    // aplikacja może być przypięta do innego mikrofonu (tu: kamera jest
    // domyślna, a obok żyje wbudowane wejście), więc wyciszenie samego
    // domyślnego zostawiałoby otwarty mikrofon za plecami przełącznika.
    //
    // Z tego samego powodu "włączony" znaczy "którykolwiek nie jest wyciszony" —
    // OFF ma gwarantować, że nic nie słucha.
    readonly property alias sources: priv.sources
    readonly property bool micReady: priv.boundSources.length > 0
    readonly property bool micOn: {
        const s = priv.boundSources;
        for (let i = 0; i < s.length; i++)
            if (!s[i].audio.muted) return true;
        return false;
    }

    function setMicOn(on) {
        const s = priv.boundSources;
        for (let i = 0; i < s.length; i++) s[i].audio.muted = !on;
    }

    // `audio` (a z nim `muted`) istnieje tylko dla węzłów związanych przez
    // tracker — do tego czasu jest null.
    PwObjectTracker {
        objects: priv.sources
    }

    QtObject {
        id: priv
        property var sinks: []
        property var sources: []
        readonly property var boundSources: sources.filter(n => n.ready && n.audio !== null)
    }

    function rebuild() {
        const v = Pipewire.nodes.values;
        const outSinks = [];
        const outSources = [];
        for (let i = 0; i < v.length; i++) {
            const n = v[i];
            if (n.isStream) continue;
            // AudioSink = Audio | Sink; strumienie aplikacji mają jeszcze bit Stream.
            if (n.isSink && n.type === PwNodeType.AudioSink) outSinks.push(n);
            else if (n.type === PwNodeType.AudioSource) outSources.push(n);
        }
        priv.sinks = outSinks;
        priv.sources = outSources;
    }

    Connections {
        target: Pipewire.nodes
        function onObjectInsertedPost() { root.rebuild(); }
        function onObjectRemovedPost() { root.rebuild(); }
    }

    Component.onCompleted: rebuild()
}
