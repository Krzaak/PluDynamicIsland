import QtQuick

// Pole wyboru z podpisem po prawej. Jak IslandSwitch, sam się nie przełącza —
// zgłasza `toggled`, a stan ustawia właściciel.
Item {
    id: box

    property bool checked: false
    property string text: ""
    property color accent: "#5b8cff"

    signal toggled()

    readonly property bool hovering: mouse.containsMouse && box.enabled

    implicitWidth: mark.width + 8 + caption.implicitWidth
    implicitHeight: 18
    opacity: enabled ? 1 : 0.4

    Behavior on opacity { NumberAnimation { duration: 180 } }

    Rectangle {
        id: mark

        width: 18
        height: 18
        radius: 6
        antialiasing: true
        anchors.verticalCenter: parent.verticalCenter

        color: box.checked ? box.accent : Qt.rgba(1, 1, 1, box.hovering ? 0.16 : 0.08)
        border.width: box.checked ? 0 : 1
        border.color: Qt.rgba(1, 1, 1, box.hovering ? 0.28 : 0.16)

        Behavior on color { ColorAnimation { duration: 150 } }

        IslandIcon {
            anchors.centerIn: parent
            kind: "check"
            size: 13
            color: "#ffffff"
            opacity: box.checked ? 1 : 0
            scale: box.checked ? 1 : 0.6

            Behavior on opacity { NumberAnimation { duration: 140 } }
            Behavior on scale {
                NumberAnimation { duration: 200; easing.type: Easing.OutBack; easing.overshoot: 2.0 }
            }
        }
    }

    Text {
        id: caption

        anchors.left: mark.right
        anchors.leftMargin: 8
        anchors.verticalCenter: parent.verticalCenter
        text: box.text
        color: box.hovering ? "#f2f2f2" : "#c8c8cf"
        font.pixelSize: 12

        Behavior on color { ColorAnimation { duration: 140 } }
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: box.toggled()
    }
}
