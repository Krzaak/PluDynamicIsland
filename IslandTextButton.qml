import QtQuick

// Przycisk z napisem ("Połącz", "Anuluj", "Sparuj"). IslandButton jest okrągły
// i tylko na ikonę, a formularz potrzebuje szerokiej pigułki z tekstem.
//
// "primary" = wypełniony akcentem (akcja domyślna), zwykły = obrysowany.
Item {
    id: btn

    property string text: ""
    property string icon: ""
    property bool primary: false
    property bool danger: false
    property bool busy: false          // czeka na system: kropki zamiast napisu
    property color accent: "#5b8cff"

    signal clicked()

    readonly property bool hovering: mouse.containsMouse && btn.enabled
    readonly property color tint: danger ? "#e5484d" : accent

    implicitWidth: Math.max(88, row.implicitWidth + 28)
    implicitHeight: 32
    opacity: enabled ? 1 : 0.35

    Behavior on opacity { NumberAnimation { duration: 180 } }

    Rectangle {
        id: bg

        anchors.fill: parent
        radius: height / 2
        antialiasing: true

        color: btn.primary
            ? (btn.hovering ? Qt.lighter(btn.tint, 1.15) : btn.tint)
            : Qt.rgba(1, 1, 1, btn.hovering ? 0.16 : 0.07)

        border.width: btn.primary ? 0 : 1
        border.color: btn.danger && !btn.primary
            ? Qt.rgba(0.9, 0.28, 0.3, btn.hovering ? 0.7 : 0.4)
            : Qt.rgba(1, 1, 1, btn.hovering ? 0.2 : 0.1)

        Behavior on color { ColorAnimation { duration: 140 } }
        Behavior on border.color { ColorAnimation { duration: 140 } }

        scale: mouse.pressed ? 0.95 : 1.0
        Behavior on scale { NumberAnimation { duration: 150; easing.type: Easing.OutQuad } }

        Row {
            id: row

            anchors.centerIn: parent
            spacing: 6
            opacity: btn.busy ? 0 : 1

            Behavior on opacity { NumberAnimation { duration: 120 } }

            IslandIcon {
                visible: btn.icon !== ""
                kind: btn.icon
                size: 14
                color: btn.primary ? "#ffffff" : (btn.danger ? "#e5484d" : "#f2f2f2")
                // Row ustawia tylko x — pionowo centrujemy sami, bo anchors
                // wewnątrz positionera potrafią się z nim gryźć.
                y: (row.height - height) / 2
            }

            Text {
                text: btn.text
                color: btn.primary ? "#ffffff" : (btn.danger ? "#e5484d" : "#f2f2f2")
                font.pixelSize: 12
                font.weight: Font.DemiBold
                y: (row.height - height) / 2
            }
        }

        // Trzy pulsujące kropki na czas czekania na NetworkManagera/BlueZ.
        Row {
            anchors.centerIn: parent
            spacing: 4
            visible: btn.busy

            Repeater {
                model: 3

                delegate: Rectangle {
                    required property int index

                    width: 5
                    height: 5
                    radius: 2.5
                    antialiasing: true
                    color: btn.primary ? "#ffffff" : "#f2f2f2"

                    SequentialAnimation on opacity {
                        running: btn.busy
                        loops: Animation.Infinite
                        PauseAnimation { duration: index * 160 }
                        NumberAnimation { from: 1; to: 0.25; duration: 320; easing.type: Easing.InOutSine }
                        NumberAnimation { from: 0.25; to: 1; duration: 320; easing.type: Easing.InOutSine }
                        PauseAnimation { duration: (2 - index) * 160 }
                    }
                }
            }
        }
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        enabled: !btn.busy
        onClicked: btn.clicked()
    }
}
