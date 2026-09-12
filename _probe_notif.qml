import QtQuick
import Quickshell

ShellRoot {
    property double got: 0

    Connections {
        target: NotificationService
        function onNotified(entry) {
            got = Date.now();
            console.log("probe: przyszło, akcji=" + entry.actions.length);
        }
    }

    Timer {
        interval: 1000
        repeat: true
        running: true
        property bool done: false
        onTriggered: {
            const h = NotificationService.history;
            if (done || got === 0 || h.length === 0) return;
            const wiek = Date.now() - got;
            if (wiek < 7000) return;          // po popupDuration (5 s)
            done = true;
            const e = h[0];
            console.log("probe: po " + Math.round(wiek / 1000) + " s dymek=" + (NotificationService.latest !== null)
                        + " zywe=" + (e.notification !== null) + " akcji=" + e.actions.length);
            console.log("probe: openEntry=" + NotificationService.openEntry(e));
        }
    }
}
