import QtQuick

// Pole tekstowe formularza: etykieta nad ramką, w środku TextInput, po prawej
// opcjonalne oko do podglądu hasła.
//
// Hover trzeba zgłaszać na zewnątrz (hovering) tak samo jak w IslandSwitch —
// pole leży nad podkładką wyspy i przejmuje kursor na wyłączność, więc bez
// tego wyspa zwinęłaby się w chwili najechania na pole.
Item {
    id: field

    // ---- ustawienia ----
    property string label: ""
    property string placeholder: ""
    property bool password: false
    property bool numeric: false
    property int maxLength: 63
    property bool invalid: false          // czerwona ramka, np. za krótkie hasło
    property color accent: "#5b8cff"

    property alias text: input.text
    property alias readOnly: input.readOnly

    signal accepted()

    // ---- stan ----
    property bool revealed: false
    readonly property bool hovering: (boxMouse.containsMouse && field.enabled) || eye.hovering
    readonly property bool focused: input.activeFocus

    // Kursor klawiatury do tego pola. Qt.callLater, a NIE wprost: wołający
    // (pick(), openHidden(), nowe pytanie agenta) zmienia najpierw stan, od
    // którego zależy `visible` tego pola, a forceActiveFocus() na elemencie
    // jeszcze niewidocznym nic nie robi. callLater odkłada to za przeliczenie
    // powiązań.
    function take() {
        Qt.callLater(() => {
            if (!field.visible || !field.enabled) return;
            input.forceActiveFocus();
            input.selectAll();
        });
    }

    implicitWidth: 200
    // 13 (etykieta) + 4 (odstęp) + 34 (ramka) — wszystko parzyste albo
    // nieparzyste świadomie: ramka 34 mieści tekst 13 px z zapasem.
    implicitHeight: label === "" ? 34 : 51
    opacity: enabled ? 1 : 0.4

    Behavior on opacity { NumberAnimation { duration: 180 } }

    Text {
        id: caption
        visible: field.label !== ""
        text: field.label
        color: "#9a9aa2"
        font.pixelSize: 11
        font.weight: Font.DemiBold
        font.letterSpacing: 0.3
    }

    Rectangle {
        id: box

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: 34
        radius: 10
        antialiasing: true
        color: field.enabled ? (field.focused ? "#1d1d22" : "#151519") : "#121215"

        border.width: 1
        border.color: field.invalid ? "#e5484d"
            : field.focused ? field.accent
            : Qt.rgba(1, 1, 1, field.hovering ? 0.18 : 0.08)

        Behavior on color { ColorAnimation { duration: 140 } }
        Behavior on border.color { ColorAnimation { duration: 140 } }

        TextInput {
            id: input

            anchors.fill: parent
            anchors.leftMargin: 10
            anchors.rightMargin: eye.visible ? 34 : 10
            verticalAlignment: TextInput.AlignVCenter

            color: "#f2f2f2"
            font.pixelSize: 13
            selectionColor: field.accent
            selectedTextColor: "#ffffff"
            clip: true
            maximumLength: field.maxLength
            activeFocusOnPress: true

            // Hasło pokazujemy dopiero po kliknięciu w oko. PasswordEchoOnEdit
            // byłoby gorsze: pokazywałoby znak w trakcie pisania, czyli
            // dokładnie wtedy, gdy ktoś może zaglądać przez ramię.
            echoMode: (field.password && !field.revealed) ? TextInput.Password : TextInput.Normal
            passwordCharacter: "•"
            passwordMaskDelay: 0

            inputMethodHints: field.numeric
                ? Qt.ImhDigitsOnly | Qt.ImhNoPredictiveText
                : (field.password ? Qt.ImhSensitiveData | Qt.ImhNoPredictiveText | Qt.ImhNoAutoUppercase
                                  : Qt.ImhNoPredictiveText | Qt.ImhNoAutoUppercase)

            // Enter zatwierdza cały formularz, nie tylko pole.
            onAccepted: field.accepted()

            // Sam TextInput nie filtruje znaków przy wklejaniu ani przy
            // klawiaturze numerycznej z symbolami, a BlueZ przyjmuje klucz
            // wyłącznie jako liczbę — stąd filtr na zmianie tekstu.
            onTextChanged: {
                if (!field.numeric) return;
                const only = text.replace(/\D/g, "");
                if (only !== text) {
                    const at = cursorPosition - (text.length - only.length);
                    text = only;
                    cursorPosition = Math.max(0, Math.min(only.length, at));
                }
            }

            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: field.placeholder
                color: "#55555e"
                font: input.font
                visible: input.text === "" && !input.activeFocus
            }
        }

        MouseArea {
            id: boxMouse
            anchors.fill: parent
            anchors.rightMargin: eye.visible ? 30 : 0
            hoverEnabled: true
            cursorShape: Qt.IBeamCursor
            acceptedButtons: Qt.LeftButton
            // Klik musi dojść do TextInputa (kursor, zaznaczanie), więc go
            // nie połykamy — ta MouseArea jest tylko po to, żeby wyspa
            // widziała hover nad polem.
            propagateComposedEvents: true
            onPressed: mouse => { input.forceActiveFocus(); mouse.accepted = false; }
        }

        // Podgląd hasła.
        Item {
            id: eye

            readonly property bool hovering: eyeMouse.containsMouse && field.enabled

            visible: field.password
            width: 26
            height: 26
            anchors.right: parent.right
            anchors.rightMargin: 4
            anchors.verticalCenter: parent.verticalCenter

            Rectangle {
                anchors.fill: parent
                radius: 8
                antialiasing: true
                color: Qt.rgba(1, 1, 1, eye.hovering ? 0.14 : 0)
                Behavior on color { ColorAnimation { duration: 140 } }
            }

            IslandIcon {
                anchors.centerIn: parent
                kind: field.revealed ? "eyeOff" : "eye"
                size: 15
                color: eye.hovering ? "#f2f2f2" : "#8a8a92"
            }

            MouseArea {
                id: eyeMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: field.revealed = !field.revealed
            }
        }
    }
}
