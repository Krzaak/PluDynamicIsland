import QtQuick

// Pigułka z bieżącym wyjściem dźwięku; kliknięcie przełącza na następne.
// Wystawia `hovering` — wyspa MUSI doliczyć je do controlsHovered, inaczej
// najechanie na pigułkę zwinie wyspę (patrz DynamicIsland: hover z trzech źródeł).
Rectangle {
    id: chip

    readonly property bool hovering: mouse.containsMouse && chip.enabled
    readonly property bool switchable: AudioService.sinks.length > 1

    // Dłuższe nazwy urządzeń są obcinane, żeby nie rozpychać kolumny tytułu.
    property int maxWidth: 180

    implicitWidth: Math.min(maxWidth, content.implicitWidth + 18)
    implicitHeight: 20
    radius: 10
    antialiasing: true
    color: Qt.rgba(1, 1, 1, chip.hovering ? 0.2 : 0.08)
    enabled: switchable
    Behavior on color { ColorAnimation { duration: 140 } }

    Row {
        id: content
        anchors.centerIn: parent
        spacing: 5

        IslandIcon {
            y: (parent.height - height) / 2
            kind: AudioService.currentIcon
            size: 11
            color: chip.switchable ? "#e2e2e6" : "#9a9aa2"
        }

        Text {
            y: (parent.height - height) / 2
            width: Math.min(implicitWidth, chip.maxWidth - 18 - 16)
            elide: Text.ElideRight
            text: AudioService.currentLabel
            color: chip.switchable ? "#e2e2e6" : "#9a9aa2"
            font.pixelSize: 11
            font.weight: Font.DemiBold
        }
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: AudioService.cycleSink()
    }
}
