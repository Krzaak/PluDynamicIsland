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

    QtObject {
        id: priv
        property var sinks: []
    }

    function rebuild() {
        const v = Pipewire.nodes.values;
        const out = [];
        for (let i = 0; i < v.length; i++) {
            const n = v[i];
            // AudioSink = Audio | Sink; strumienie aplikacji mają jeszcze bit Stream.
            if (n.isSink && !n.isStream && n.type === PwNodeType.AudioSink) out.push(n);
        }
        priv.sinks = out;
    }

    Connections {
        target: Pipewire.nodes
        function onObjectInsertedPost() { root.rebuild(); }
        function onObjectRemovedPost() { root.rebuild(); }
    }

    Component.onCompleted: rebuild()
}
