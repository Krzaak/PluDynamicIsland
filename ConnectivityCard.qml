import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Bluetooth
import Quickshell.Networking

// Karta "łączność": przełączniki Wi-Fi i Bluetooth po lewej, przewijana
// lista urządzeń Bluetooth po prawej (sparowane + znalezione przy skanowaniu),
// z poziomem baterii tam, gdzie urządzenie go zgłasza.
//
// Karta jest PODGLĄDEM i szybkim przełącznikiem. Wszystko, co wymaga
// wpisywania — hasło do nowej sieci, PIN przy parowaniu — dzieje się
// w nakładkach (WifiPanel, BluetoothPanel), które karta otwiera sygnałami
// openWifi / openBluetooth. Nakładka nie zmieściłaby się w slocie karuzeli
// (slotWidth = 440), a podniesienie slotu przestawiłoby wszystkie karty.
//
// Karta ma stały rozmiar (trzecia geometria z DynamicIsland) i wystawia
// `hovering`, które wyspa dolicza do controlsHovered — każdy element z własną
// MouseArea przejmuje hover na wyłączność i bez tego wyspa zwijałaby się
// w chwili najechania na przełącznik albo wiersz listy.
Item {
    id: card

    // ---------------------------------------------------------------
    // Ustawienia
    // ---------------------------------------------------------------

    property int rowHeight: 28
    property int leftColumnWidth: 168

    implicitWidth: 440
    implicitHeight: 150

    signal openWifi()
    signal openBluetooth()

    // ---------------------------------------------------------------
    // Stan
    // ---------------------------------------------------------------

    readonly property bool hovering: wifiSwitch.hovering || btSwitch.hovering
        || btnScan.hovering || deviceList.hoveredRows > 0
        || wifiRow.hovering || btRow.hovering

    // ---- Wi-Fi ----
    // Sieci i urządzenie idą z NetworkService — tam jest też cała obsługa
    // łączenia, wspólna z nakładką.
    readonly property var wifiNetwork: NetworkService.activeNetwork

    readonly property string wifiSubtitle: {
        if (!NetworkService.hardwareEnabled) return "Wyłączone sprzętowo";
        if (!NetworkService.enabled) return "Wyłączone";
        if (NetworkService.busy) return "Łączę…";
        if (wifiNetwork) return wifiNetwork.name + " · " + Math.round(wifiNetwork.signalStrength * 100) + "%";
        return "Brak połączenia";
    }

    // ---- Bluetooth ----
    // Adapter, rfkill i mapowanie ikon mieszkają w BluetoothService, żeby
    // karta i nakładka pokazywały dokładnie to samo.
    readonly property bool btOn: BluetoothService.enabled

    readonly property string btSubtitle: {
        if (BluetoothService.adapter === null) return "Brak adaptera";
        if (BluetoothService.busy) return "Przełączanie…";
        if (!btOn) return "Wyłączony";
        if (BluetoothService.discovering) return "Szukam urządzeń…";
        const n = BluetoothService.connectedCount;
        if (n === 0) return "Nic nie połączono";
        return n === 1 ? "1 urządzenie" : n + " urządzenia";
    }

    // ---------------------------------------------------------------
    // Układ
    // ---------------------------------------------------------------

    RowLayout {
        anchors.fill: parent
        anchors.margins: 14
        anchors.bottomMargin: 16
        spacing: 14

        // ---- lewa kolumna: przełączniki ----
        ColumnLayout {
            Layout.preferredWidth: card.leftColumnWidth
            Layout.maximumWidth: card.leftColumnWidth
            Layout.fillHeight: true
            spacing: 10

            // Wi-Fi
            Item {
                id: wifiRow

                readonly property bool hovering: wifiMouse.containsMouse

                Layout.fillWidth: true
                Layout.preferredHeight: 40

                // Podświetlenie całego wiersza: mówi, że da się w niego
                // kliknąć, a nie tylko przestawić przełącznik.
                Rectangle {
                    anchors.fill: parent
                    anchors.margins: -4
                    radius: 10
                    antialiasing: true
                    color: Qt.rgba(1, 1, 1, wifiRow.hovering ? 0.06 : 0)
                    Behavior on color { ColorAnimation { duration: 140 } }
                }

                // Pod przełącznikiem, żeby ten dostał swoje kliknięcia.
                MouseArea {
                    id: wifiMouse
                    anchors.fill: parent
                    anchors.rightMargin: 40
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: card.openWifi()
                }

                RowLayout {
                    anchors.fill: parent
                    spacing: 10

                    Rectangle {
                        Layout.preferredWidth: 36
                        Layout.preferredHeight: 36
                        radius: 11
                        antialiasing: true
                        color: NetworkService.enabled ? Qt.rgba(0.22, 0.83, 0.48, 0.16) : "#17171a"

                        Behavior on color { ColorAnimation { duration: 200 } }

                        IslandIcon {
                            anchors.centerIn: parent
                            kind: "wifi"
                            size: 18
                            color: NetworkService.enabled ? "#38d47a" : "#4a4a52"
                            Behavior on color { ColorAnimation { duration: 200 } }
                        }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 1

                        Text {
                            Layout.fillWidth: true
                            text: "Wi‑Fi"
                            color: "#f5f5f5"
                            font.pixelSize: 13
                            font.weight: Font.DemiBold
                        }

                        Text {
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                            text: card.wifiSubtitle
                            color: "#9a9aa2"
                            font.pixelSize: 11
                        }
                    }

                    IslandSwitch {
                        id: wifiSwitch
                        Layout.alignment: Qt.AlignVCenter
                        checked: NetworkService.enabled
                        enabled: NetworkService.hardwareEnabled
                        onToggled: Networking.wifiEnabled = !Networking.wifiEnabled
                    }
                }
            }

            // Bluetooth
            Item {
                id: btRow

                readonly property bool hovering: btMouse.containsMouse

                Layout.fillWidth: true
                Layout.preferredHeight: 40

                Rectangle {
                    anchors.fill: parent
                    anchors.margins: -4
                    radius: 10
                    antialiasing: true
                    color: Qt.rgba(1, 1, 1, btRow.hovering ? 0.06 : 0)
                    Behavior on color { ColorAnimation { duration: 140 } }
                }

                MouseArea {
                    id: btMouse
                    anchors.fill: parent
                    anchors.rightMargin: 40
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: card.openBluetooth()
                }

                RowLayout {
                    anchors.fill: parent
                    spacing: 10

                    Rectangle {
                        Layout.preferredWidth: 36
                        Layout.preferredHeight: 36
                        radius: 11
                        antialiasing: true
                        color: card.btOn ? Qt.rgba(0.35, 0.55, 1.0, 0.18) : "#17171a"

                        Behavior on color { ColorAnimation { duration: 200 } }

                        IslandIcon {
                            anchors.centerIn: parent
                            kind: "bluetooth"
                            size: 18
                            color: card.btOn ? "#5b8cff" : "#4a4a52"
                            Behavior on color { ColorAnimation { duration: 200 } }
                        }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 1

                        Text {
                            Layout.fillWidth: true
                            text: "Bluetooth"
                            color: "#f5f5f5"
                            font.pixelSize: 13
                            font.weight: Font.DemiBold
                        }

                        Text {
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                            text: card.btSubtitle
                            color: "#9a9aa2"
                            font.pixelSize: 11
                        }
                    }

                    IslandSwitch {
                        id: btSwitch
                        Layout.alignment: Qt.AlignVCenter
                        accent: "#5b8cff"
                        checked: card.btOn
                        enabled: BluetoothService.adapter !== null && !BluetoothService.busy
                        onToggled: BluetoothService.setEnabled(!card.btOn)
                    }
                }
            }

            Item { Layout.fillHeight: true }
        }

        // ---- prawa kolumna: lista urządzeń ----
        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 4

            RowLayout {
                Layout.fillWidth: true
                spacing: 6

                Text {
                    Layout.fillWidth: true
                    text: "Urządzenia"
                    color: "#9a9aa2"
                    font.pixelSize: 11
                    font.weight: Font.DemiBold
                    font.letterSpacing: 0.4
                }

                // Dodanie urządzenia = nakładka. Parowanie wymaga miejsca na
                // PIN i potwierdzenie kodu, więc nie zmieściłoby się tutaj.
                Item {
                    id: btnScan

                    readonly property bool hovering: scanMouse.containsMouse && btnScan.enabled

                    Layout.preferredWidth: 22
                    Layout.preferredHeight: 22
                    enabled: card.btOn
                    opacity: enabled ? 1 : 0.3

                    Rectangle {
                        anchors.fill: parent
                        radius: width / 2
                        antialiasing: true
                        color: Qt.rgba(1, 1, 1, btnScan.hovering ? 0.2 : 0.08)
                        Behavior on color { ColorAnimation { duration: 140 } }
                    }

                    IslandIcon {
                        anchors.centerIn: parent
                        kind: "plus"
                        size: 13
                        color: "#f2f2f2"
                    }

                    MouseArea {
                        id: scanMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: card.openBluetooth()
                    }
                }
            }

            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true

                // Flickable przyjmuje kółko tylko wtedy, gdy może się w tę stronę
                // przesunąć — na granicy (lista u góry + kółko w górę) zdarzenie
                // odrzuca i leciałoby do WheelHandlera wyspy, przełączając kartę.
                // Ten handler siedzi na rodzicu listy, więc dostaje zdarzenie
                // dopiero po niej, i połyka je (blocking domyślnie true), gdy lista
                // w ogóle ma co przewijać. Gdy mieści się w całości, jest wyłączony
                // i kółko przełącza karty jak wszędzie indziej.
                WheelHandler {
                    target: null
                    enabled: deviceList.contentHeight > deviceList.height
                    acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                }

                ListView {
                    id: deviceList

                    // Licznik zamiast OR po delegatach: delegaty powstają i giną,
                    // więc stałe powiązanie nie miałoby do czego się przypiąć.
                    property int hoveredRows: 0

                    anchors.fill: parent

                    // Wyłączony Bluetooth: lista zostaje (widać, co jest sparowane),
                    // ale przygaszona i bez reakcji na klik — nie da się połączyć.
                    opacity: card.btOn ? 1 : 0.35
                    enabled: card.btOn
                    Behavior on opacity {
                        NumberAnimation { duration: 200; easing.type: Easing.OutCubic }
                    }
                    model: BluetoothService.pairedDevices
                    spacing: 0
                    boundsBehavior: Flickable.StopAtBounds
                    flickDeceleration: 4000

                    delegate: Item {
                        id: row

                        required property var modelData

                        // Urządzenie znalezione przy skanowaniu znika z BlueZ kilka
                        // sekund po jego zakończeniu i modelData robi się null,
                        // zanim delegat zostanie zniszczony. Stąd wszystkie odczyty
                        // idą przez te pola, nigdy bezpośrednio po modelData.
                        readonly property var device: modelData ?? null
                        readonly property string devName: device ? device.name : ""
                        readonly property bool devPaired: device ? device.paired : false
                        readonly property bool devConnected: device ? device.connected : false
                        readonly property string devIcon: device ? device.icon : ""
                        readonly property bool devBatteryAvailable: device ? device.batteryAvailable : false

                        readonly property bool busy: device !== null && (device.pairing
                            || device.state === BluetoothDeviceState.Connecting
                            || device.state === BluetoothDeviceState.Disconnecting)
                        readonly property real batteryLevel: {
                            const b = device ? device.battery : 0;
                            return b > 1 ? b / 100 : b;
                        }

                        width: ListView.view.width
                        height: card.rowHeight

                        onDeviceChanged: rowMouse.syncHover()

                        Rectangle {
                            anchors.fill: parent
                            anchors.rightMargin: 6
                            radius: 8
                            color: Qt.rgba(1, 1, 1, rowMouse.containsMouse ? 0.08 : 0)
                            Behavior on color { ColorAnimation { duration: 120 } }
                        }

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 6
                            anchors.rightMargin: 12
                            spacing: 8

                            IslandIcon {
                                Layout.alignment: Qt.AlignVCenter
                                kind: BluetoothService.deviceIcon(row.devIcon)
                                size: 14
                                color: row.devConnected ? "#5b8cff" : (row.devPaired ? "#c8c8cf" : "#6a6a72")
                                Behavior on color { ColorAnimation { duration: 200 } }
                            }

                            Text {
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                                text: row.devName
                                color: row.devPaired ? "#f2f2f2" : "#9a9aa2"
                                font.pixelSize: 12
                                font.weight: row.devConnected ? Font.DemiBold : Font.Normal
                            }

                            // Bateria: korpus + wypełnienie + nosek, wszystko parzyste.
                            RowLayout {
                                spacing: 4
                                visible: row.devBatteryAvailable
                                Layout.alignment: Qt.AlignVCenter

                                Item {
                                    Layout.preferredWidth: 20
                                    Layout.preferredHeight: 10

                                    Rectangle {
                                        id: batteryBody
                                        x: 0; y: 0
                                        width: 18; height: 10
                                        radius: 2.5
                                        antialiasing: true
                                        color: "transparent"
                                        border.width: 1
                                        border.color: Qt.rgba(1, 1, 1, 0.45)

                                        Rectangle {
                                            x: 2; y: 2
                                            height: 6
                                            width: Math.max(1, Math.round(14 * row.batteryLevel))
                                            radius: 1.5
                                            antialiasing: true
                                            color: row.batteryLevel <= 0.2 ? "#e5484d" : (row.batteryLevel <= 0.4 ? "#f0b232" : "#38d47a")
                                        }
                                    }

                                    Rectangle {
                                        x: 18; y: 3
                                        width: 2; height: 4
                                        radius: 1
                                        color: Qt.rgba(1, 1, 1, 0.45)
                                    }
                                }

                                Text {
                                    text: Math.round(row.batteryLevel * 100) + "%"
                                    color: "#9a9aa2"
                                    font.pixelSize: 10
                                }
                            }

                            Text {
                                Layout.alignment: Qt.AlignVCenter
                                text: row.busy ? "…" : (row.devConnected ? "połączono" : "")
                                color: row.devConnected ? "#5b8cff" : "#6a6a72"
                                font.pixelSize: 10
                                visible: text !== ""
                            }
                        }

                        MouseArea {
                            id: rowMouse

                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            enabled: !row.busy

                            property bool counted: false

                            function syncHover() {
                                const now = containsMouse;
                                if (now === counted) return;
                                counted = now;
                                deviceList.hoveredRows += now ? 1 : -1;
                            }

                            onContainsMouseChanged: syncHover()
                            // Delegat zniszczony w trakcie hovera zostawiłby licznik
                            // zawyżony — a wtedy wyspa nigdy by się nie zwinęła.
                            Component.onDestruction: if (counted) deviceList.hoveredRows -= 1

                            onClicked: {
                                const d = row.device;
                                if (d === null) return;
                                if (d.connected) d.disconnect();
                                else d.connect();
                            }
                        }
                    }
                }

                // Własny, cienki wskaźnik przewijania — bez QtQuick.Controls.
                Rectangle {
                    anchors.right: parent.right
                    width: 2
                    radius: 1
                    color: Qt.rgba(1, 1, 1, 0.25)
                    visible: deviceList.contentHeight > deviceList.height
                    y: deviceList.visibleArea.yPosition * deviceList.height
                    height: Math.max(8, deviceList.visibleArea.heightRatio * deviceList.height)
                }

                // Model zawiera dokładnie to, co widać, więc count nie kłamie.
                Text {
                    anchors.centerIn: parent
                    width: parent.width - 12
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    text: BluetoothService.adapter === null ? "Brak adaptera Bluetooth"
                        : !card.btOn ? "Włącz Bluetooth"
                        : "Nic nie sparowano — kliknij +"
                    color: "#6a6a72"
                    font.pixelSize: 11
                    visible: deviceList.count === 0
                }
            }
        }
    }
}
