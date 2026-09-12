import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Bluetooth
import Quickshell.Networking

// Karta "łączność": przełączniki Wi-Fi i Bluetooth po lewej, przewijana
// lista urządzeń Bluetooth po prawej (sparowane + znalezione przy skanowaniu),
// z poziomem baterii tam, gdzie urządzenie go zgłasza.
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
    property int scanDurationMs: 15000      // skanowanie samo się kończy, żeby nie zjadać radia

    implicitWidth: 440
    implicitHeight: 150

    // ---------------------------------------------------------------
    // Stan
    // ---------------------------------------------------------------

    readonly property bool hovering: wifiSwitch.hovering || btSwitch.hovering
        || btnScan.hovering || deviceList.hoveredRows > 0

    // ---- Wi-Fi ----
    readonly property var wifiDevice: {
        const all = Networking.devices.values;
        for (let i = 0; i < all.length; i++)
            if (all[i].type === DeviceType.Wifi) return all[i];
        return null;
    }

    readonly property var wifiNetwork: {
        if (!wifiDevice || !wifiDevice.networks) return null;
        const nets = wifiDevice.networks.values;
        for (let i = 0; i < nets.length; i++)
            if (nets[i].connected) return nets[i];
        return null;
    }

    readonly property string wifiSubtitle: {
        if (!Networking.wifiHardwareEnabled) return "Wyłączone sprzętowo";
        if (!Networking.wifiEnabled) return "Wyłączone";
        if (wifiNetwork) return wifiNetwork.name + " · " + Math.round(wifiNetwork.signalStrength * 100) + "%";
        return "Brak połączenia";
    }

    // ---- Bluetooth ----
    readonly property var adapter: Bluetooth.defaultAdapter
    readonly property bool btOn: adapter !== null && adapter.enabled
    readonly property bool btBlocked: adapter !== null && adapter.state === BluetoothAdapterState.Blocked
    readonly property bool btBusy: adapter !== null
        && (adapter.state === BluetoothAdapterState.Enabling || adapter.state === BluetoothAdapterState.Disabling)

    readonly property int connectedCount: {
        const all = Bluetooth.devices.values;
        let n = 0;
        for (let i = 0; i < all.length; i++) if (all[i].connected) n++;
        return n;
    }

    readonly property string btSubtitle: {
        if (adapter === null) return "Brak adaptera";
        if (btBusy) return "Przełączanie…";
        if (!btOn) return "Wyłączony";
        if (adapter.discovering) return "Szukam urządzeń…";
        if (connectedCount === 0) return "Nic nie połączono";
        return connectedCount === 1 ? "1 urządzenie" : connectedCount + " urządzenia";
    }

    // Wyłączony Bluetooth w KDE to blokada rfkill, nie tylko Powered=false.
    // Zablokowany adapter ignoruje enabled=true (BlueZ zwraca Error.Blocked),
    // więc włączanie idzie przez rfkill unblock; BlueZ z AutoEnable sam potem
    // podnosi adapter, a enabled=true po zmianie stanu to zabezpieczenie,
    // gdyby AutoEnable było wyłączone. Wyłączanie blokuje rfkill, żeby stan
    // zgadzał się z tym, co pokazuje aplet KDE.
    property bool pendingEnable: false

    function setBluetooth(on) {
        if (adapter === null || btBusy) return;
        if (on) {
            pendingEnable = true;
            rfkill.command = ["rfkill", "unblock", "bluetooth"];
            rfkill.running = true;
            if (!btBlocked) adapter.enabled = true;
        } else {
            pendingEnable = false;
            adapter.discovering = false;
            adapter.enabled = false;
            rfkill.command = ["rfkill", "block", "bluetooth"];
            rfkill.running = true;
        }
    }

    Connections {
        target: card.adapter

        function onStateChanged() {
            if (card.pendingEnable && !card.btBlocked && !card.btBusy) {
                card.pendingEnable = false;
                if (!card.adapter.enabled) card.adapter.enabled = true;
            }
        }
    }

    Process {
        id: rfkill
        onExited: (exitCode, exitStatus) => {
            if (exitCode !== 0) console.warn("rfkill zakończył się kodem " + exitCode + " — Bluetooth może nie dać się przełączyć.");
        }
    }

    function toggleScan() {
        if (!btOn) return;
        adapter.discovering = !adapter.discovering;
        if (adapter.discovering) scanTimer.restart();
    }

    Timer {
        id: scanTimer
        interval: card.scanDurationMs
        onTriggered: if (card.adapter) card.adapter.discovering = false
    }

    // Ikony BlueZ (nazwy z freedesktop) -> nasze IslandIcon.
    function deviceIcon(name) {
        switch (name) {
        case "audio-headset":
        case "audio-headphones": return "headset";
        case "audio-card":
        case "audio-speakers": return "speaker";
        case "phone": return "phone";
        case "input-keyboard": return "keyboard";
        case "input-mouse":
        case "input-tablet": return "mouse";
        case "input-gaming": return "gamepad";
        case "computer": return "computer";
        default: return "bluetooth";
        }
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
            RowLayout {
                Layout.fillWidth: true
                spacing: 10

                Rectangle {
                    Layout.preferredWidth: 36
                    Layout.preferredHeight: 36
                    radius: 11
                    color: Networking.wifiEnabled ? Qt.rgba(0.22, 0.83, 0.48, 0.16) : "#17171a"

                    Behavior on color { ColorAnimation { duration: 200 } }

                    IslandIcon {
                        anchors.centerIn: parent
                        kind: "wifi"
                        size: 18
                        color: Networking.wifiEnabled ? "#38d47a" : "#4a4a52"
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
                    checked: Networking.wifiEnabled
                    enabled: Networking.wifiHardwareEnabled
                    onToggled: Networking.wifiEnabled = !Networking.wifiEnabled
                }
            }

            // Bluetooth
            RowLayout {
                Layout.fillWidth: true
                spacing: 10

                Rectangle {
                    Layout.preferredWidth: 36
                    Layout.preferredHeight: 36
                    radius: 11
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
                    enabled: card.adapter !== null && !card.btBusy
                    onToggled: card.setBluetooth(!card.btOn)
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

                // Skanowanie: ikona kręci się, dopóki adapter szuka.
                Item {
                    id: btnScan

                    readonly property bool hovering: scanMouse.containsMouse && btnScan.enabled
                    readonly property bool scanning: card.adapter !== null && card.adapter.discovering

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
                        id: scanIcon
                        anchors.centerIn: parent
                        kind: "refresh"
                        size: 13
                        color: btnScan.scanning ? "#5b8cff" : "#f2f2f2"

                        RotationAnimation on rotation {
                            running: btnScan.scanning
                            loops: Animation.Infinite
                            from: 0; to: 360
                            duration: 1100
                            onRunningChanged: if (!running) scanIcon.rotation = 0
                        }
                    }

                    MouseArea {
                        id: scanMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: card.toggleScan()
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
                    model: Bluetooth.devices
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

                        // Znalezione urządzenia bez nazwy zgłaszają adres jako
                        // nazwę — szum, którego nie da się sensownie sparować.
                        readonly property bool named: device !== null && devName !== "" && devName !== device.address
                        readonly property bool busy: device !== null && (device.pairing
                            || device.state === BluetoothDeviceState.Connecting
                            || device.state === BluetoothDeviceState.Disconnecting)
                        readonly property real batteryLevel: {
                            const b = device ? device.battery : 0;
                            return b > 1 ? b / 100 : b;
                        }

                        width: ListView.view.width
                        height: named ? card.rowHeight : 0
                        visible: named

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
                                kind: card.deviceIcon(row.devIcon)
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
                                text: row.busy ? "…"
                                    : row.devConnected ? "połączono"
                                    : row.devPaired ? ""
                                    : "sparuj"
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
                                const now = containsMouse && row.named;
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
                                if (!d.paired) d.pair();
                                else if (d.connected) d.disconnect();
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

                // Podpowiedź tylko przy NAPRAWDĘ pustej liście. Przy wyłączonym
                // Bluetoothie sparowane urządzenia dalej są na liście, więc napis
                // nakładałby się na nie — zamiast tego lista jest przygaszona.
                Text {
                    anchors.centerIn: parent
                    text: card.adapter === null ? "Brak adaptera Bluetooth"
                        : !card.btOn ? "Włącz Bluetooth"
                        : "Brak urządzeń — kliknij lupę"
                    color: "#6a6a72"
                    font.pixelSize: 11
                    visible: deviceList.count === 0
                }
            }
        }
    }
}
