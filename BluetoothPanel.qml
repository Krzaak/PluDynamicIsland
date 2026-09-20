import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Bluetooth

// Nakładka Bluetooth: po lewej lista urządzeń (sparowane + znalezione przy
// skanowaniu), po prawej albo szczegóły wybranego urządzenia, albo pytanie
// agenta parowania.
//
// Pytanie agenta MA PIERWSZEŃSTWO nad wszystkim innym: BlueZ czeka wtedy na
// odpowiedź z otwartym wywołaniem D-Bus i ma na to swój limit czasu, więc
// nie może się schować za listą.
Item {
    id: panel

    // ---------------------------------------------------------------
    // Ustawienia
    // ---------------------------------------------------------------

    property int listWidth: 264
    property int rowHeight: 34
    property int scanDurationMs: 30000   // skanowanie samo się kończy, żeby nie zjadać radia

    implicitWidth: 620
    implicitHeight: 360

    signal closed()

    readonly property bool hovering: btnBack.hovering || btSwitch.hovering || btnScan.hovering
        || devList.hoveredRows > 0 || cbDiscoverable.hovering
        || fAlias.hovering || cbTrusted.hovering || cbBlocked.hovering || cbWake.hovering
        || btnPair.hovering || btnConnect.hovering || btnDisconnect.hovering
        || btnForget.hovering || fAgent.hovering || btnAgentOk.hovering || btnAgentNo.hovering

    // ---------------------------------------------------------------
    // Adapter
    // ---------------------------------------------------------------

    readonly property var adapter: BluetoothService.adapter
    readonly property bool btOn: BluetoothService.enabled
    readonly property bool btBusy: BluetoothService.busy
    readonly property bool scanning: BluetoothService.discovering

    // ---------------------------------------------------------------
    // Pytanie agenta
    // ---------------------------------------------------------------

    readonly property var ask: BluetoothService.request
    readonly property bool asking: ask !== null

    readonly property string askTitle: {
        if (!asking) return "";
        switch (ask.kind) {
        case "pin": return "Wpisz PIN";
        case "passkey": return "Wpisz klucz";
        case "confirm": return "Czy kody się zgadzają?";
        case "authorize": return "Sparować to urządzenie?";
        case "service": return "Zezwolić na usługę?";
        case "display-pin": return "Wpisz ten PIN na urządzeniu";
        case "display-passkey": return "Wpisz ten klucz na urządzeniu";
        default: return "Parowanie";
        }
    }

    readonly property string askHint: {
        if (!asking) return "";
        switch (ask.kind) {
        case "pin": return "Urządzenie prosi o kod. Zwykle 0000 albo 1234, ale sprawdź jego instrukcję.";
        case "passkey": return "Wpisz sześciocyfrowy klucz pokazany na urządzeniu.";
        case "confirm": return "Ten sam kod powinien być teraz widoczny na urządzeniu.";
        case "authorize": return "Urządzenie nie ma jak pokazać kodu — potwierdź tylko, jeśli to na pewno ono.";
        case "service": return "Usługa: " + (ask.uuid || "nieznana");
        case "display-pin":
        case "display-passkey": return "Okno zniknie samo, gdy parowanie się skończy.";
        default: return "";
        }
    }

    // Kod do przepisania albo do porównania.
    readonly property string askCode: {
        if (!asking) return "";
        if (ask.kind === "confirm" || ask.kind === "display-passkey") return ask.passkey || "";
        if (ask.kind === "display-pin") return ask.value || "";
        return "";
    }

    readonly property bool askWantsText: asking && (ask.kind === "pin" || ask.kind === "passkey")
    readonly property bool askIsDisplay: asking && (ask.kind === "display-pin" || ask.kind === "display-passkey")

    // Nowe pytanie czyści pole i od razu bierze kursor — użytkownik ma
    // kilkadziesiąt sekund, zanim BlueZ się rozmyśli.
    onAskChanged: {
        if (askWantsText) {
            fAgent.text = "";
            fAgent.take();
        }
    }

    function answerOk() {
        if (!asking) return;
        if (askWantsText) BluetoothService.accept(fAgent.text);
        else BluetoothService.accept(null);
    }

    function answerNo() { BluetoothService.reject(); }

    // ---------------------------------------------------------------
    // Wybrane urządzenie
    // ---------------------------------------------------------------

    property var selected: null

    readonly property bool devPairing: selected !== null && selected.pairing
    readonly property bool devBusy: selected !== null && (selected.pairing
        || selected.state === BluetoothDeviceState.Connecting
        || selected.state === BluetoothDeviceState.Disconnecting)

    function pick(device) {
        selected = device;
        fAlias.text = device ? device.name : "";
    }

    function clearSelection() {
        selected = null;
        fAlias.text = "";
    }

    // Wybrane urządzenie potrafi zniknąć z BlueZ (znalezione przy skanowaniu
    // przepada kilka sekund po jego końcu). Zostawiony wskaźnik byłby wtedy
    // martwy, a formularz pokazywałby dane urządzenia, którego już nie ma.
    Connections {
        target: Bluetooth.devices

        function onValuesChanged() {
            if (!panel.selected) return;
            if (Bluetooth.devices.values.indexOf(panel.selected) < 0) panel.clearSelection();
        }
    }

    function toggleScan() {
        if (!btOn) return;
        adapter.discovering = !adapter.discovering;
        if (adapter.discovering) scanTimer.restart();
    }

    Timer {
        id: scanTimer
        interval: panel.scanDurationMs
        onTriggered: if (panel.adapter) panel.adapter.discovering = false
    }

    // Skanowanie włączamy razem z panelem: po to się go otwiera.
    Component.onCompleted: if (btOn && adapter && !adapter.discovering) toggleScan()
    Component.onDestruction: {
        if (adapter && adapter.discovering) adapter.discovering = false;
        // Zamknięcie panelu w trakcie pytania musi być ODMOWĄ — inaczej
        // po stronie BlueZ zostałoby wiszące wywołanie.
        BluetoothService.dismiss();
    }

    // ---------------------------------------------------------------
    // Układ
    // ---------------------------------------------------------------

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 16
        spacing: 12

        // ---- nagłówek ----
        RowLayout {
            Layout.fillWidth: true
            spacing: 10

            IslandButton {
                id: btnBack
                kind: "back"
                onClicked: panel.closed()
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0

                Text {
                    text: "Bluetooth"
                    color: "#f5f5f5"
                    font.pixelSize: 15
                    font.weight: Font.DemiBold
                }

                Text {
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                    font.pixelSize: 11
                    color: (!BluetoothService.available || (panel.btOn && !BluetoothService.registered))
                        ? "#f0b232" : "#9a9aa2"
                    text: {
                        if (panel.adapter === null) return "Brak adaptera";
                        if (panel.btBusy) return "Przełączanie…";
                        if (!panel.btOn) return "Wyłączony";
                        // Bez agenta parowanie i tak padnie — lepiej powiedzieć
                        // to wprost, niż dać użytkownikowi klikać w "Sparuj".
                        if (!BluetoothService.available) return "Agent parowania nie działa — sprawdź log";
                        if (!BluetoothService.registered) return "Agent parowania nie zarejestrowany";
                        if (panel.scanning) return "Szukam urządzeń…";
                        return Bluetooth.devices.values.length + " urządzeń";
                    }
                }
            }

            // Skanowanie: ikona kręci się, dopóki adapter szuka.
            Item {
                id: btnScan

                readonly property bool hovering: scanMouse.containsMouse && btnScan.enabled

                Layout.preferredWidth: 26
                Layout.preferredHeight: 26
                Layout.alignment: Qt.AlignVCenter
                enabled: panel.btOn
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
                    size: 14
                    color: panel.scanning ? "#5b8cff" : "#f2f2f2"

                    RotationAnimation on rotation {
                        running: panel.scanning
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
                    onClicked: panel.toggleScan()
                }
            }

            IslandSwitch {
                id: btSwitch
                Layout.alignment: Qt.AlignVCenter
                accent: "#5b8cff"
                checked: panel.btOn
                enabled: panel.adapter !== null && !panel.btBusy
                onToggled: BluetoothService.setEnabled(!panel.btOn)
            }
        }

        // ---- dwie kolumny ----
        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 14

            // ---- lewa: lista urządzeń ----
            ColumnLayout {
                Layout.preferredWidth: panel.listWidth
                Layout.maximumWidth: panel.listWidth
                Layout.fillHeight: true
                spacing: 6

                Item {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true

                    opacity: panel.btOn ? 1 : 0.35
                    enabled: panel.btOn
                    Behavior on opacity { NumberAnimation { duration: 200 } }

                    WheelHandler {
                        target: null
                        enabled: devList.contentHeight > devList.height
                        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                    }

                    ListView {
                        id: devList

                        property int hoveredRows: 0

                        anchors.fill: parent
                        model: BluetoothService.sortedDevices
                        spacing: 2
                        boundsBehavior: Flickable.StopAtBounds
                        flickDeceleration: 4000

                        delegate: Item {
                            id: devRow

                            required property var modelData

                            // modelData robi się null ZANIM delegat zginie —
                            // stąd wszystkie odczyty przez własne pola.
                            readonly property var dev: modelData ?? null
                            readonly property string devName: dev ? dev.name : ""
                            readonly property bool devPaired: dev ? dev.paired : false
                            readonly property bool devConnected: dev ? dev.connected : false
                            readonly property string devIcon: dev ? dev.icon : ""
                            readonly property bool isSelected: dev !== null && panel.selected === dev

                            width: ListView.view.width
                            height: panel.rowHeight

                            Rectangle {
                                anchors.fill: parent
                                anchors.rightMargin: 6
                                radius: 9
                                antialiasing: true
                                color: devRow.isSelected ? Qt.rgba(0.35, 0.55, 1.0, 0.18)
                                    : Qt.rgba(1, 1, 1, devMouse.containsMouse ? 0.08 : 0)
                                Behavior on color { ColorAnimation { duration: 120 } }
                            }

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 8
                                anchors.rightMargin: 14
                                spacing: 8

                                IslandIcon {
                                    Layout.alignment: Qt.AlignVCenter
                                    kind: BluetoothService.deviceIcon(devRow.devIcon)
                                    size: 14
                                    color: devRow.devConnected ? "#5b8cff"
                                        : (devRow.devPaired ? "#c8c8cf" : "#6a6a72")
                                    Behavior on color { ColorAnimation { duration: 200 } }
                                }

                                Text {
                                    Layout.fillWidth: true
                                    elide: Text.ElideRight
                                    text: devRow.devName
                                    color: devRow.devPaired ? "#f2f2f2" : "#9a9aa2"
                                    font.pixelSize: 12
                                    font.weight: (devRow.devConnected || devRow.isSelected) ? Font.DemiBold : Font.Normal
                                }

                                Text {
                                    Layout.alignment: Qt.AlignVCenter
                                    text: devRow.devConnected ? "połączono" : (devRow.devPaired ? "sparowane" : "nowe")
                                    color: devRow.devConnected ? "#5b8cff" : "#6a6a72"
                                    font.pixelSize: 9
                                }
                            }

                            MouseArea {
                                id: devMouse

                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor

                                property bool counted: false

                                function syncHover() {
                                    const now = containsMouse;
                                    if (now === counted) return;
                                    counted = now;
                                    devList.hoveredRows += now ? 1 : -1;
                                }

                                onContainsMouseChanged: syncHover()
                                Component.onDestruction: if (counted) devList.hoveredRows -= 1

                                onClicked: if (devRow.dev) panel.pick(devRow.dev)
                            }
                        }
                    }

                    Text {
                        anchors.centerIn: parent
                        width: parent.width - 16
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.WordWrap
                        text: panel.adapter === null ? "Brak adaptera Bluetooth"
                            : !panel.btOn ? "Włącz Bluetooth"
                            : "Szukam urządzeń…"
                        color: "#6a6a72"
                        font.pixelSize: 11
                        visible: devList.count === 0
                    }
                }

                IslandCheckbox {
                    id: cbDiscoverable
                    Layout.fillWidth: true
                    text: "Widoczny dla innych"
                    enabled: panel.btOn
                    checked: panel.adapter !== null && panel.adapter.discoverable
                    onToggled: if (panel.adapter) panel.adapter.discoverable = !panel.adapter.discoverable
                }
            }

            // ---- prawa: pytanie agenta ALBO szczegóły urządzenia ----
            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true

                // ---- pytanie agenta ----
                ColumnLayout {
                    anchors.fill: parent
                    spacing: 8
                    visible: panel.asking

                    Text {
                        Layout.fillWidth: true
                        text: panel.askTitle
                        color: "#f5f5f5"
                        font.pixelSize: 14
                        font.weight: Font.DemiBold
                        wrapMode: Text.WordWrap
                    }

                    Text {
                        Layout.fillWidth: true
                        text: panel.asking && panel.ask.device
                            ? (panel.ask.device.name || panel.ask.device.address || "nieznane urządzenie")
                            : ""
                        color: "#5b8cff"
                        font.pixelSize: 12
                        elide: Text.ElideRight
                    }

                    // Kod: do porównania albo do przepisania. Duży i rozstrzelony,
                    // bo to jedyna rzecz, na którą trzeba tu patrzeć.
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 52
                        visible: panel.askCode !== ""
                        radius: 12
                        antialiasing: true
                        color: "#151519"
                        border.width: 1
                        border.color: Qt.rgba(1, 1, 1, 0.1)

                        Text {
                            anchors.centerIn: parent
                            text: panel.askCode
                            color: "#f2f2f2"
                            font.pixelSize: 26
                            font.weight: Font.DemiBold
                            font.letterSpacing: 6
                        }
                    }

                    IslandTextField {
                        id: fAgent
                        Layout.fillWidth: true
                        visible: panel.askWantsText
                        label: panel.asking && panel.ask.kind === "passkey" ? "Klucz" : "PIN"
                        placeholder: panel.asking && panel.ask.kind === "passkey" ? "sześć cyfr" : "np. 0000"
                        numeric: panel.asking && panel.ask.kind === "passkey"
                        maxLength: panel.asking && panel.ask.kind === "passkey" ? 6 : 16
                        onAccepted: panel.answerOk()
                    }

                    Text {
                        Layout.fillWidth: true
                        text: panel.askHint
                        color: "#9a9aa2"
                        font.pixelSize: 11
                        wrapMode: Text.WordWrap
                    }

                    Item { Layout.fillHeight: true }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8

                        IslandTextButton {
                            id: btnAgentNo
                            text: panel.askIsDisplay ? "Zamknij" : "Odrzuć"
                            danger: !panel.askIsDisplay
                            onClicked: {
                                if (panel.askIsDisplay) BluetoothService.accept(null);
                                else panel.answerNo();
                            }
                        }

                        Item { Layout.fillWidth: true }

                        IslandTextButton {
                            id: btnAgentOk
                            text: panel.asking && panel.ask.kind === "confirm" ? "Zgadza się" : "Potwierdź"
                            icon: "check"
                            primary: true
                            visible: !panel.askIsDisplay
                            enabled: !panel.askWantsText || fAgent.text !== ""
                            onClicked: panel.answerOk()
                        }
                    }
                }

                // ---- szczegóły urządzenia ----
                Text {
                    anchors.centerIn: parent
                    width: parent.width - 20
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    text: "Wybierz urządzenie z listy.\nNowe pojawią się podczas skanowania."
                    color: "#55555e"
                    font.pixelSize: 12
                    visible: !panel.asking && panel.selected === null
                }

                Flickable {
                    id: detailScroll

                    anchors.fill: parent
                    anchors.bottomMargin: detailActions.visible ? detailActions.height + 8 : 0
                    contentHeight: detail.implicitHeight
                    boundsBehavior: Flickable.StopAtBounds
                    interactive: contentHeight > height
                    visible: !panel.asking && panel.selected !== null
                    clip: true

                    WheelHandler {
                        target: null
                        enabled: detailScroll.interactive
                        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                    }

                    ColumnLayout {
                        id: detail

                        width: detailScroll.width
                        spacing: 10

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 10

                            Rectangle {
                                Layout.preferredWidth: 36
                                Layout.preferredHeight: 36
                                radius: 11
                                antialiasing: true
                                color: Qt.rgba(0.35, 0.55, 1.0, 0.16)

                                IslandIcon {
                                    anchors.centerIn: parent
                                    kind: BluetoothService.deviceIcon(panel.selected ? panel.selected.icon : "")
                                    size: 18
                                    color: "#5b8cff"
                                }
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 1

                                Text {
                                    Layout.fillWidth: true
                                    elide: Text.ElideRight
                                    text: panel.selected ? panel.selected.name : ""
                                    color: "#f5f5f5"
                                    font.pixelSize: 13
                                    font.weight: Font.DemiBold
                                }

                                Text {
                                    Layout.fillWidth: true
                                    elide: Text.ElideRight
                                    text: panel.selected ? panel.selected.address : ""
                                    color: "#9a9aa2"
                                    font.pixelSize: 11
                                }
                            }
                        }

                        // Zmiana nazwy działa na alias w BlueZ, więc zostaje
                        // po ponownym połączeniu. Zatwierdza Enter — bez tego
                        // nie byłoby wiadomo, kiedy pisanie się skończyło.
                        IslandTextField {
                            id: fAlias
                            Layout.fillWidth: true
                            label: "Nazwa (Enter zapisuje)"
                            placeholder: "nazwa urządzenia"
                            enabled: panel.selected !== null
                            onAccepted: if (panel.selected && text !== "") panel.selected.name = text
                        }

                        IslandCheckbox {
                            id: cbTrusted
                            text: "Zaufane — łącz bez pytania"
                            enabled: panel.selected !== null && panel.selected.paired
                            checked: panel.selected !== null && panel.selected.trusted
                            onToggled: if (panel.selected) panel.selected.trusted = !panel.selected.trusted
                        }

                        IslandCheckbox {
                            id: cbBlocked
                            text: "Zablokowane"
                            enabled: panel.selected !== null
                            checked: panel.selected !== null && panel.selected.blocked
                            onToggled: if (panel.selected) panel.selected.blocked = !panel.selected.blocked
                        }

                        IslandCheckbox {
                            id: cbWake
                            text: "Może wybudzać komputer"
                            enabled: panel.selected !== null && panel.selected.paired
                            checked: panel.selected !== null && panel.selected.wakeAllowed
                            onToggled: if (panel.selected) panel.selected.wakeAllowed = !panel.selected.wakeAllowed
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 6
                            visible: panel.selected !== null && panel.selected.batteryAvailable

                            Text {
                                text: "Bateria"
                                color: "#9a9aa2"
                                font.pixelSize: 11
                                font.weight: Font.DemiBold
                            }

                            Text {
                                Layout.fillWidth: true
                                // Dokumentacja Quickshella nie mówi, czy to 0-1
                                // czy 0-100 — garda na obie skale.
                                text: {
                                    if (!panel.selected) return "";
                                    const b = panel.selected.battery;
                                    return Math.round((b > 1 ? b / 100 : b) * 100) + "%";
                                }
                                color: "#f2f2f2"
                                font.pixelSize: 11
                            }
                        }


                    }
                }

                RowLayout {
                    id: detailActions

                    // Poza Flickable, przypięte do dołu: lista pól bywa
                    // wyższa niż nakładka i przyciski wypadałyby pod krawędź.
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    spacing: 8
                    visible: !panel.asking && panel.selected !== null

                    IslandTextButton {
                        id: btnForget
                        text: "Zapomnij"
                        icon: "trash"
                        danger: true
                        visible: panel.selected !== null && panel.selected.paired
                        onClicked: {
                            const d = panel.selected;
                            panel.clearSelection();   // forget() usuwa urządzenie z BlueZ
                            d.forget();
                        }
                    }

                    Item { Layout.fillWidth: true }

                    IslandTextButton {
                        id: btnPair
                        text: panel.devPairing ? "Paruję" : "Sparuj"
                        icon: "bluetooth"
                        primary: true
                        visible: panel.selected !== null && !panel.selected.paired
                        busy: panel.devPairing
                        enabled: panel.btOn && !panel.devBusy
                        onClicked: if (panel.selected) panel.selected.pair()
                    }

                    IslandTextButton {
                        id: btnDisconnect
                        text: "Rozłącz"
                        visible: panel.selected !== null && panel.selected.connected
                        busy: panel.selected !== null && panel.selected.state === BluetoothDeviceState.Disconnecting
                        onClicked: if (panel.selected) panel.selected.disconnect()
                    }

                    IslandTextButton {
                        id: btnConnect
                        text: "Połącz"
                        icon: "check"
                        primary: true
                        visible: panel.selected !== null && panel.selected.paired && !panel.selected.connected
                        busy: panel.selected !== null && panel.selected.state === BluetoothDeviceState.Connecting
                        enabled: panel.btOn && !panel.devBusy
                        onClicked: if (panel.selected) panel.selected.connect()
                    }
                }
            }
        }
    }
}
