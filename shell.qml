//@ pragma UseQApplication

import Quickshell
import Quickshell.Io

// Punkt wejścia. Uruchom:  qs -p ~/PluDynamicIslandQuickshell
ShellRoot {
    id: root

    // Ukrywanie wyspy z zewnątrz, np. skrótem klawiszowym:
    //   qs -p ~/PluDynamicIslandQuickshell ipc call island toggle
    //
    // Quickshell ma globalne skróty tylko dla Hyprlanda (GlobalShortcut), więc
    // w KDE skrót podpina się w Ustawieniach systemowych jako polecenie.
    // Stan w PersistentProperties, bo instancja przeładowuje pliki na żywo —
    // zwykła właściwość wracałaby do false i schowana wyspa wyskakiwała po edycji.
    PersistentProperties {
        id: persist
        reloadableId: "islandState"

        property bool hidden: false
    }

    IpcHandler {
        target: "island"

        function toggle(): void { persist.hidden = !persist.hidden; }
        function hide(): void { persist.hidden = true; }
        function show(): void { persist.hidden = false; }
        function isHidden(): bool { return persist.hidden; }
    }

    // Monitor, na którym ma siedzieć wyspa.
    //
    // Quickshell nie zna pojęcia "monitora głównego" — Wayland go nie ma — a
    // kolejność Quickshell.screens NIE odpowiada priorytetom z KDE (tutaj
    // screens[0] to HDMI-A-1, czyli ten drugi). Dlatego wskazujemy po nazwie.
    // Nazwy monitorów wypisze:  kscreen-doctor -o
    property string islandScreen: "DP-1"

    readonly property var targetScreens: {
        const all = Quickshell.screens;

        const named = all.filter(s => s.name === root.islandScreen);
        if (named.length > 0) return named;

        // Monitor odłączony albo zmienił nazwę — awaryjnie ten w punkcie (0,0),
        // bo KDE tam zwykle stawia główny.
        const atOrigin = all.filter(s => s.x === 0 && s.y === 0);
        if (atOrigin.length > 0) return atOrigin;

        return all.length > 0 ? [all[0]] : [];
    }

    Variants {
        model: root.targetScreens

        DynamicIsland {
            hiddenByUser: persist.hidden
        }
    }
}
