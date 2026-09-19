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
