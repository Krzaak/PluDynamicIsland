import QtQuick

// Mały, okrągły przycisk sterowania muzyką.
// "big" = duży, biały przycisk play/pause na środku.
Item {
    id: btn

    property string kind: "play"
    property bool big: false

    // Stan "aktywny" z własnym kolorem tła (np. czerwony wyciszony mikrofon,
    // czerwony przycisk rozłączenia). Ma pierwszeństwo przed stylem big/zwykły.
    property bool accented: false
    property color accent: "#e5484d"

    signal clicked()

    // Wyłączony przycisk nie reaguje na kursor — inaczej podświetlałby się
    // coś, w co i tak nie da się kliknąć.
    readonly property bool hovering: mouse.containsMouse && btn.enabled

    implicitWidth: big ? 38 : 30
    implicitHeight: big ? 38 : 30
    opacity: enabled ? 1.0 : 0.3

    Behavior on opacity {
        NumberAnimation { duration: 200; easing.type: Easing.OutCubic }
    }

    // Pierścień wyskakujący spod przycisku. Rysowany pod spodem i trochę
    // większy, więc nie rusza układu — sąsiednie przyciski stoją w miejscu.
    //
    // Dodatek MUSI być parzysty. Przyciski mają parzysty rozmiar (30 i 38),
    // więc przy nieparzystym dodatku idealny środek wypada na pół piksela,
    // a anchors.centerIn zaokrągla — pierścień siada o pół piksela za wysoko
    // i odstęp na dole robi się węższy niż na górze.
    Rectangle {
        anchors.centerIn: parent
        width: parent.width + 10
        height: parent.height + 10
        radius: width / 2
        antialiasing: true

        color: "transparent"
        border.width: 1.5
        border.color: Qt.rgba(1, 1, 1, btn.big ? 0.28 : 0.20)

        opacity: btn.hovering ? 1 : 0
        scale: btn.hovering ? 1 : 0.78

        Behavior on opacity {
            NumberAnimation { duration: 150; easing.type: Easing.OutCubic }
        }
        Behavior on scale {
            NumberAnimation { duration: 260; easing.type: Easing.OutBack; easing.overshoot: 2.2 }
        }
    }

    Rectangle {
        id: bg
        anchors.fill: parent
        radius: width / 2
        antialiasing: true

        color: btn.accented
            ? (btn.hovering ? Qt.lighter(btn.accent, 1.15) : btn.accent)
            : btn.big
                ? (btn.hovering ? "#ffffff" : "#e2e2e6")
                : Qt.rgba(1, 1, 1, btn.hovering ? 0.24 : 0.08)

        Behavior on color {
            ColorAnimation { duration: 140; easing.type: Easing.OutCubic }
        }

        // Wciśnięcie ma pierwszeństwo przed najechaniem.
        scale: mouse.pressed ? 0.82 : (btn.hovering ? 1.1 : 1.0)
        Behavior on scale {
            NumberAnimation { duration: 200; easing.type: Easing.OutBack; easing.overshoot: 2.2 }
        }

        IslandIcon {
            anchors.centerIn: parent
            kind: btn.kind
            size: btn.big ? 17 : 13
            color: btn.accented
                ? "#ffffff"
                : btn.big ? "#0a0a0c" : (btn.hovering ? "#ffffff" : "#f2f2f2")
        }
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: btn.clicked()
    }
}
