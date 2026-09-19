import QtQuick
import QtQuick.Layouts

// Karta "AirPodsy": bateria lewej, prawej i etui, tryb redukcji hałasu i
// przełącznik pauzy po wyjęciu z ucha. Istnieje w karuzeli tylko wtedy, gdy
// słuchawki są połączone (AirPodsService.connected) — o tym decyduje wyspa.
//
// Stan mówią ikony, nie napisy: słuchawka niebieska = w uchu, jasna = poza
// uchem, ciemna = w etui; błyskawica = ładuje. Nazwa trybu stoi w nagłówku
// (przy najechaniu — nazwa trybu pod kursorem).
//
// Jak ConnectivityCard wystawia `hovering`, które wyspa dolicza do
// controlsHovered — pasek trybów i przełącznik mają własne MouseArea.
Item {
    id: card

    // ---------------------------------------------------------------
    // Ustawienia
    // ---------------------------------------------------------------

    property int tileHeight: 48
    property int segmentWidth: 44
    property int segmentHeight: 30

    implicitWidth: 440
    implicitHeight: 150

    // ---------------------------------------------------------------
    // Stan
    // ---------------------------------------------------------------

    readonly property bool hovering: (modeArea.containsMouse && modeArea.enabled) || pauseSwitch.hovering

    readonly property var modes: ["off", "anc", "transparency", "adaptive"]
    readonly property var modeIcons: ["noiseOff", "noiseAnc", "noiseTransparency", "noiseAdaptive"]
    readonly property var modeLabels: ["Wyłączone", "Redukcja szumu", "Przezroczystość", "Tryb adaptacyjny"]

    // Podświetlamy tryb wybrany, zanim słuchawki go potwierdzą (~1 s), żeby
    // klik dawał natychmiastową odpowiedź; potwierdzony ma pełny kolor.
    readonly property string shownMode: AirPodsService.pendingMode !== "" ? AirPodsService.pendingMode : AirPodsService.noiseMode
    readonly property int shownIndex: modes.indexOf(shownMode)
    readonly property bool modePending: AirPodsService.pendingMode !== ""

    readonly property string modeCaption: {
        if (modeBar.hoveredIndex >= 0) return modeLabels[modeBar.hoveredIndex];
        if (shownIndex < 0) return "";
        return modeLabels[shownIndex] + (modePending ? "…" : "");
    }

    function levelColor(level, charging) {
        if (charging) return "#38d47a";
        return level <= 20 ? "#e5484d" : (level <= 40 ? "#f0b232" : "#38d47a");
    }

    function earColor(ear) {
        switch (ear) {
        case "ear": return "#5b8cff";
        case "out": return "#e2e2e6";
        default: return "#5a5a62";
        }
    }

    // ---------------------------------------------------------------
    // Układ
    // ---------------------------------------------------------------

    // Kafelek baterii. `battery` to {level, charging, live} z mostka;
    // live=false znaczy, że element teraz nie raportuje (etui zamknięte),
    // a level to ostatni znany odczyt — pokazujemy go przygaszony.
    component BatteryTile: Rectangle {
        id: tile

        property string icon
        property color iconColor
        property string side     // "L" / "P" — ikony słuchawek są lustrzane, ale małe
        property var battery: ({ level: -1, charging: false, live: false })

        readonly property int level: battery ? battery.level : -1
        readonly property bool charging: battery ? battery.charging : false
        readonly property bool live: battery ? battery.live : false

        Layout.fillWidth: true
        Layout.preferredHeight: card.tileHeight
        radius: 12
        color: "#17171a"

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 9
            anchors.rightMargin: 10
            spacing: 8

            IslandIcon {
                Layout.alignment: Qt.AlignVCenter
                kind: tile.icon
                size: 24
                color: tile.iconColor
                Behavior on color { ColorAnimation { duration: 200 } }
            }

            ColumnLayout {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                spacing: 5
                opacity: tile.live ? 1 : 0.45

                RowLayout {
                    Layout.fillWidth: true
                    spacing: 3

                    Text {
                        text: tile.level >= 0 ? tile.level + "%" : "—"
                        color: "#f5f5f5"
                        font.pixelSize: 14
                        font.weight: Font.DemiBold
                    }

                    IslandIcon {
                        Layout.alignment: Qt.AlignVCenter
                        kind: "bolt"
                        size: 12
                        color: "#38d47a"
                        visible: tile.charging
                    }

                    Item { Layout.fillWidth: true }

                    Text {
                        text: tile.side
                        color: "#6a6a72"
                        font.pixelSize: 10
                        font.weight: Font.DemiBold
                        visible: text !== ""
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 3
                    radius: 1.5
                    antialiasing: true
                    color: Qt.rgba(1, 1, 1, 0.1)

                    Rectangle {
                        width: parent.width * Math.max(0, tile.level) / 100
                        height: parent.height
                        radius: parent.radius
                        antialiasing: true
                        color: card.levelColor(tile.level, tile.charging)
                        Behavior on width { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
                    }
                }
            }
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 14
        anchors.bottomMargin: 18
        spacing: 10

        // ---- nagłówek: nazwa + bieżący tryb ----
        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            IslandIcon {
                Layout.alignment: Qt.AlignVCenter
                kind: "headset"
                size: 16
                color: "#5b8cff"
            }

            Text {
                Layout.fillWidth: true
                elide: Text.ElideRight
                text: AirPodsService.name !== "" ? AirPodsService.name : "AirPods"
                color: "#f5f5f5"
                font.pixelSize: 15
                font.weight: Font.DemiBold
            }

            Text {
                text: card.modeCaption
                color: modeBar.hoveredIndex >= 0 ? "#e2e2e6" : "#9a9aa2"
                font.pixelSize: 11
                font.weight: Font.DemiBold
            }
        }

        // ---- baterie ----
        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            BatteryTile {
                icon: "budLeft"
                iconColor: card.earColor(AirPodsService.leftEar)
                side: "L"
                battery: AirPodsService.left
            }

            BatteryTile {
                icon: "budRight"
                iconColor: card.earColor(AirPodsService.rightEar)
                side: "P"
                battery: AirPodsService.right
            }

            // Etui raportuje tylko otwarte i ze słuchawką w środku; po
            // zamknięciu zostaje ostatni odczyt, przygaszony.
            BatteryTile {
                icon: "budCase"
                iconColor: live ? "#e2e2e6" : "#5a5a62"
                battery: AirPodsService.caseBattery
            }
        }

        // ---- tryb hałasu + pauza po wyjęciu ----
        RowLayout {
            Layout.fillWidth: true
            spacing: 10

            // Jedna MouseArea na cały pasek zamiast czterech: jeden `hovering`
            // do zgłoszenia wyspie, a segment pod kursorem liczymy z mouseX.
            Rectangle {
                id: modeBar

                Layout.preferredWidth: card.segmentWidth * card.modes.length
                Layout.preferredHeight: card.segmentHeight
                radius: height / 2
                color: Qt.rgba(1, 1, 1, 0.06)
                opacity: modeArea.enabled ? 1 : 0.35

                readonly property int hoveredIndex: modeArea.containsMouse
                    ? Math.min(card.modes.length - 1, Math.floor(modeArea.mouseX / card.segmentWidth)) : -1

                Rectangle {
                    x: modeBar.hoveredIndex * card.segmentWidth + 2
                    y: 2
                    width: card.segmentWidth - 4
                    height: modeBar.height - 4
                    radius: height / 2
                    color: Qt.rgba(1, 1, 1, 0.1)
                    visible: modeBar.hoveredIndex >= 0 && modeBar.hoveredIndex !== card.shownIndex
                }

                // Wybrany tryb. Niepotwierdzony = przygaszony, dopóki słuchawki
                // nie odpowiedzą.
                Rectangle {
                    x: card.shownIndex * card.segmentWidth + 2
                    y: 2
                    width: card.segmentWidth - 4
                    height: modeBar.height - 4
                    radius: height / 2
                    visible: card.shownIndex >= 0
                    color: card.modePending ? Qt.rgba(1, 1, 1, 0.3) : "#e2e2e6"

                    Behavior on x { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
                    Behavior on color { ColorAnimation { duration: 200 } }
                }

                Row {
                    anchors.fill: parent

                    Repeater {
                        model: card.modes.length

                        delegate: Item {
                            required property int index

                            width: card.segmentWidth
                            height: modeBar.height

                            IslandIcon {
                                anchors.centerIn: parent
                                kind: card.modeIcons[index]
                                size: 16
                                color: index === card.shownIndex && !card.modePending ? "#0a0a0c" : "#e2e2e6"
                                Behavior on color { ColorAnimation { duration: 200 } }
                            }
                        }
                    }
                }

                MouseArea {
                    id: modeArea

                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    // Tryb nieznany = mostek jeszcze nie dostał stanu; klik poszedłby w próżnię.
                    enabled: AirPodsService.connected && AirPodsService.noiseMode !== ""
                    onClicked: mouse => {
                        const i = Math.min(card.modes.length - 1, Math.floor(mouse.x / card.segmentWidth));
                        AirPodsService.setNoiseMode(card.modes[i]);
                    }
                }
            }

            Item { Layout.fillWidth: true }

            IslandIcon {
                Layout.alignment: Qt.AlignVCenter
                kind: "pause"
                size: 12
                color: AirPodsService.autoPause ? "#e2e2e6" : "#6a6a72"
            }

            Text {
                Layout.alignment: Qt.AlignVCenter
                text: "Pauza po wyjęciu"
                color: AirPodsService.autoPause ? "#e2e2e6" : "#9a9aa2"
                font.pixelSize: 11
                font.weight: Font.DemiBold
            }

            IslandSwitch {
                id: pauseSwitch
                Layout.alignment: Qt.AlignVCenter
                accent: "#5b8cff"
                checked: AirPodsService.autoPause
                onToggled: AirPodsService.setAutoPause(!AirPodsService.autoPause)
            }
        }
    }
}
