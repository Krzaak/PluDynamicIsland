//@ pragma UseQApplication

import Quickshell

// Punkt wejścia. Uruchom:  qs -p ~/PluDynamicIslandQuickshell
ShellRoot {
    id: root

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

        DynamicIsland {}
    }
}
