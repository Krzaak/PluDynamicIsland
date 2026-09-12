import QtQuick

// Mały przełącznik w stylu iOS (tor + gałka). Nie zmienia `checked` sam —
// zgłasza `toggled`, a właściciel ustawia stan, gdy system go potwierdzi.
// Dzięki temu przełącznik nie kłamie, gdy np. Wi-Fi nie da się włączyć.
Item {
    id: sw

    property bool checked: false
    property color accent: "#38d47a"
    signal toggled()

    // Do sumy hovera wyspy — patrz controlsHovered w DynamicIsland.
    readonly property bool hovering: mouse.containsMouse && sw.enabled

    implicitWidth: 34
    implicitHeight: 20
    opacity: enabled ? 1.0 : 0.35

    Behavior on opacity {
        NumberAnimation { duration: 200; easing.type: Easing.OutCubic }
    }

    Rectangle {
        id: track
        anchors.fill: parent
        radius: height / 2
        antialiasing: true
        color: sw.checked ? sw.accent : Qt.rgba(1, 1, 1, sw.hovering ? 0.22 : 0.14)

        Behavior on color {
            ColorAnimation { duration: 180; easing.type: Easing.OutCubic }
        }

        Rectangle {
            id: knob
            // Gałka 16 px w torze 20 px: po 2 px luzu z każdej strony,
            // parzyste rozmiary, więc nic nie ląduje na pół piksela.
            width: 16
            height: 16
            radius: 8
            antialiasing: true
            y: 2
            x: sw.checked ? parent.width - width - 2 : 2
            color: "#ffffff"

            Behavior on x {
                NumberAnimation { duration: 220; easing.type: Easing.OutBack; easing.overshoot: 1.1 }
            }

            scale: mouse.pressed ? 0.9 : 1.0
            Behavior on scale {
                NumberAnimation { duration: 140; easing.type: Easing.OutQuad }
            }
        }
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: sw.toggled()
    }
}
