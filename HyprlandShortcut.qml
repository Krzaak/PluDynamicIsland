import QtQuick
import Quickshell.Hyprland

// Skrót globalny wyspy, wydzielony do osobnego pliku, żeby shell.qml mógł go
// ładować Loaderem tylko na Hyprlandzie. Import Quickshell.Hyprland w pliku,
// który ładuje się zawsze, oznaczałby ostrzeżenie o braku protokołu na KDE.
//
// Klawisz przypisuje kompozytor:
//   bind = SUPER, I, global, quickshell:islandToggle
Item {
    signal activated()

    GlobalShortcut {
        appid: "quickshell"
        name: "islandToggle"
        description: "Pokaż / ukryj dynamiczną wyspę"

        onPressed: activated()
    }
}
