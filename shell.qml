//@ pragma UseQApplication

import QtQuick
import Quickshell
import Quickshell.Io

// Punkt wejścia. Uruchom:  qs -p ~/PluDynamicIslandQuickshell
ShellRoot {
    id: root

    // Ukrywanie wyspy z zewnątrz, np. skrótem klawiszowym:
    //   qs -p ~/PluDynamicIslandQuickshell ipc call island toggle
    //
    // Na Hyprlandzie jest też skrót globalny (niżej) — na KDE zostaje IPC,
    // bo wl-global-shortcuts wystawia tylko Hyprland.
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

    // Skrót globalny Hyprlanda. Protokół hyprland-global-shortcuts-v1 nie
    // przypisuje klawisza — robi to konfiguracja kompozytora, a my tylko
    // zgłaszamy nazwę skrótu. W ~/.config/hypr/hyprland.conf:
    //
    //   bind = SUPER, I, global, quickshell:islandToggle
    //
    // Loader, a nie gołe GlobalShortcut, bo poza Hyprlandem (KDE) protokołu
    // nie ma i sam obiekt zgłasza ostrzeżenie przy każdym starcie.
    readonly property bool onHyprland: Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") !== undefined

    Loader {
        active: root.onHyprland

        source: "HyprlandShortcut.qml"

        onLoaded: item.activated.connect(() => persist.hidden = !persist.hidden)
    }

    // Monitor, na którym ma siedzieć wyspa.
    //
    // Quickshell nie zna pojęcia "monitora głównego" — Wayland go nie ma — a
    // kolejność Quickshell.screens NIE odpowiada priorytetom kompozytora
    // (na desktopie z KDE screens[0] to HDMI-A-1, czyli ten drugi). Dlatego
    // można wskazać monitor po nazwie; pusta nazwa = wybór automatyczny.
    //
    // Nazwy monitorów wypisze:  hyprctl monitors    (Hyprland)
    //                           kscreen-doctor -o   (KDE)
    property string islandScreen: ""

    readonly property var targetScreens: {
        const all = Quickshell.screens;

        if (root.islandScreen !== "") {
            const named = all.filter(s => s.name === root.islandScreen);
            if (named.length > 0) return named;
        }

        // Bez nazwy albo monitor odłączony — ten w punkcie (0,0). Hyprland
        // i KDE stawiają tam monitor główny.
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
