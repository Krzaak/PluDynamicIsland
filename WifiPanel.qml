import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Networking

// Nakładka Wi-Fi: po lewej lista sieci, po prawej formularz połączenia.
//
// To NIE jest karta karuzeli. Karta musiałaby się zmieścić w slocie
// (slotWidth = 440) i podniosłaby ten slot wszystkim pozostałym kartom;
// nakładka zamiast tego zastępuje cały pasek kart i rozciąga wyspę do
// własnego rozmiaru — geometria karuzeli zostaje nietknięta.
//
// Hover sumujemy z KAŻDEGO elementu osobno (patrz controlsHovered w wyspie):
// element pod kursorem przejmuje hover na wyłączność, więc bez tej sumy
// wyspa zwijałaby się w chwili najechania na pole formularza.
Item {
    id: panel

    // ---------------------------------------------------------------
    // Ustawienia
    // ---------------------------------------------------------------

    property int listWidth: 264
    property int rowHeight: 34

    implicitWidth: 620
    implicitHeight: 360

    signal closed()

    readonly property bool hovering: btnBack.hovering || wifiSwitch.hovering
        || btnHidden.hovering || netList.hoveredRows > 0
        || fSsid.hovering || dSecurity.hovering || fPsk.hovering
        || dEap.hovering || fIdentity.hovering || fAnon.hovering
        || fEapPass.hovering || dPhase2.hovering || fCaCert.hovering
        || cbAuto.hovering || btnConnect.hovering || btnCancel.hovering
        || btnForget.hovering || btnDisconnect.hovering

    // ---------------------------------------------------------------
    // Stan formularza
    // ---------------------------------------------------------------

    // Wybrana sieć z listy albo null. Przy "sieci ukrytej" zostaje null,
    // a nazwę wpisuje użytkownik.
    property var selected: null
    property bool hiddenMode: false

    // Pola TEKSTOWE są tu źródłem prawdy i czyta się je wprost (fPsk.text).
    // Powód: TextInput zmienia swój tekst sam, przy pierwszym wpisanym znaku
    // zrywa powiązanie `text: panel.cośTam` — i od tej chwili wyzerowanie
    // właściwości nie czyściłoby już pola. Listy wyboru i checkbox trzymają
    // stan tutaj, bo te swojego nie ruszają (patrz IslandDropdown).
    property string fieldSecurity: "wpa-psk"
    property string fieldEap: "peap"
    property string fieldPhase2: "mschapv2"
    property bool fieldAuto: true

    // Zabezpieczenia: z sieci, gdy ją wybrano; z listy wyboru przy ukrytej.
    readonly property string securityKey: (selected && !hiddenMode)
        ? NetworkService.securityKey(selected.security)
        : fieldSecurity

    readonly property bool formOpen: selected !== null || hiddenMode
    readonly property bool knownNetwork: selected !== null && selected.known && !hiddenMode
    readonly property string ssid: hiddenMode ? fSsid.text : (selected ? selected.name : "")
    readonly property bool wantsPassword: NetworkService.needsPassword(securityKey)
    readonly property bool wantsEap: NetworkService.needsEap(securityKey)

    // Sieć znana ma już zapisane sekrety — nie pytamy o nie drugi raz.
    readonly property bool wantsSecrets: formOpen && !knownNetwork && (wantsPassword || wantsEap)

    readonly property bool busyHere: NetworkService.busySsid !== "" && NetworkService.busySsid === ssid

    readonly property bool canSubmit: {
        if (!formOpen || busyHere) return false;
        if (ssid === "") return false;
        if (knownNetwork) return true;
        if (wantsPassword && securityKey !== "wep" && fPsk.text.length < 8 && fPsk.text.length !== 64) return false;
        if (securityKey === "wep" && fPsk.text === "") return false;
        if (wantsEap) {
            if (fIdentity.text === "") return false;
            if (fieldEap !== "tls" && fEapPass.text === "") return false;
        }
        return true;
    }

    function resetFields() {
        fSsid.text = (selected && !hiddenMode) ? selected.name : "";
        fPsk.text = "";
        fIdentity.text = "";
        fAnon.text = "";
        fEapPass.text = "";
        fCaCert.text = "";
        fPsk.revealed = false;
        fEapPass.revealed = false;
        fieldSecurity = "wpa-psk";
        fieldEap = "peap";
        fieldPhase2 = "mschapv2";
        fieldAuto = true;
    }

    function pick(network) {
        NetworkService.clearError();
        hiddenMode = false;
        selected = network;
        resetFields();          // po ustawieniu selected — wpisuje nazwę sieci w pole
        if (!knownNetwork && wantsPassword) fPsk.take();
        else if (!knownNetwork && wantsEap) fIdentity.take();
    }

    function openHidden() {
        NetworkService.clearError();
        selected = null;
        hiddenMode = true;
        resetFields();
        fSsid.take();
    }

    function closeForm() {
        selected = null;
        hiddenMode = false;
        resetFields();
    }

    function submit() {
        if (!canSubmit) return;

        if (knownNetwork) {
            NetworkService.connectKnown(selected);
            return;
        }

        const req = {
            ssid: panel.ssid,
            security: panel.securityKey,
            hidden: panel.hiddenMode,
            autoconnect: panel.fieldAuto
        };
        if (panel.wantsPassword) req.psk = fPsk.text;
        if (panel.wantsEap) {
            req.eap = panel.fieldEap;
            req.identity = fIdentity.text;
            req.anonymousIdentity = fAnon.text;
            req.password = fEapPass.text;
            req.phase2 = panel.fieldEap === "tls" ? "" : panel.fieldPhase2;
            req.caCert = fCaCert.text;
        }
        NetworkService.connectNew(req);
    }

    // Udało się — formularz zamykamy, żeby nie zostawiać hasła na ekranie.
    Connections {
        target: NetworkService

        function onConnected(ssid) {
            if (ssid === panel.ssid) panel.closeForm();
        }
    }

    // Panel otwarty = skaner włączony. Wyłączamy go przy zamknięciu, bo
    // ciągłe skanowanie przerywa transmisję na karcie.
    Component.onCompleted: NetworkService.scanning = true
    Component.onDestruction: NetworkService.scanning = false

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
                    text: "Wi‑Fi"
                    color: "#f5f5f5"
                    font.pixelSize: 15
                    font.weight: Font.DemiBold
                }

                Text {
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                    color: NetworkService.error !== "" ? "#e5484d" : "#9a9aa2"
                    font.pixelSize: 11
                    text: {
                        if (NetworkService.error !== "") return NetworkService.error;
                        if (!NetworkService.available) return "Brak karty Wi‑Fi";
                        if (!NetworkService.hardwareEnabled) return "Wyłączone sprzętowo";
                        if (!NetworkService.enabled) return "Wyłączone";
                        if (NetworkService.busy) return "Łączę z " + NetworkService.busySsid + "…";
                        if (NetworkService.activeNetwork) return "Połączono: " + NetworkService.activeNetwork.name;
                        return NetworkService.networks.length + " sieci w zasięgu";
                    }
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

        // ---- dwie kolumny ----
        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 14

            // ---- lewa: lista sieci ----
            ColumnLayout {
                Layout.preferredWidth: panel.listWidth
                Layout.maximumWidth: panel.listWidth
                Layout.fillHeight: true
                spacing: 6

                Item {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true

                    opacity: NetworkService.enabled ? 1 : 0.35
                    enabled: NetworkService.enabled
                    Behavior on opacity { NumberAnimation { duration: 200 } }

                    // Ten sam problem co w karcie łączności: Flickable na
                    // granicy odrzuca kółko i poleciałoby do wyspy.
                    WheelHandler {
                        target: null
                        enabled: netList.contentHeight > netList.height
                        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                    }

                    ListView {
                        id: netList

                        property int hoveredRows: 0

                        anchors.fill: parent
                        model: NetworkService.networks
                        spacing: 2
                        boundsBehavior: Flickable.StopAtBounds
                        flickDeceleration: 4000

                        delegate: Item {
                            id: netRow

                            required property var modelData

                            // Sieci znikają z listy przy każdym skanowaniu,
                            // a modelData robi się null ZANIM delegat zginie —
                            // stąd wszystkie odczyty przez własne pola.
                            readonly property var net: modelData ?? null
                            readonly property string netName: net ? net.name : ""
                            readonly property bool netConnected: net ? net.connected : false
                            readonly property bool netKnown: net ? net.known : false
                            readonly property real netSignal: net ? net.signalStrength : 0
                            readonly property int netSecurity: net ? net.security : WifiSecurityType.Unknown
                            readonly property bool netOpen: netSecurity === WifiSecurityType.Open
                            readonly property bool isSelected: net !== null && panel.selected === net

                            width: ListView.view.width
                            height: panel.rowHeight

                            Rectangle {
                                anchors.fill: parent
                                anchors.rightMargin: 6
                                radius: 9
                                antialiasing: true
                                color: netRow.isSelected ? Qt.rgba(0.35, 0.55, 1.0, 0.18)
                                    : Qt.rgba(1, 1, 1, netMouse.containsMouse ? 0.08 : 0)
                                Behavior on color { ColorAnimation { duration: 120 } }
                            }

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 8
                                anchors.rightMargin: 14
                                spacing: 8

                                // Siła sygnału: cztery słupki. Czytelniejsze
                                // niż procent, a nie zajmuje miejsca na tekst.
                                Row {
                                    Layout.alignment: Qt.AlignVCenter
                                    spacing: 2

                                    Repeater {
                                        model: 4

                                        delegate: Rectangle {
                                            required property int index

                                            width: 3
                                            height: 4 + index * 3
                                            radius: 1.5
                                            antialiasing: true
                                            y: 13 - height
                                            color: netRow.netSignal * 4 > index
                                                ? (netRow.netConnected ? "#38d47a" : "#c8c8cf")
                                                : Qt.rgba(1, 1, 1, 0.16)
                                            Behavior on color { ColorAnimation { duration: 200 } }
                                        }
                                    }
                                }

                                Text {
                                    Layout.fillWidth: true
                                    elide: Text.ElideRight
                                    text: netRow.netName
                                    color: netRow.netConnected ? "#38d47a" : "#f2f2f2"
                                    font.pixelSize: 12
                                    font.weight: (netRow.netConnected || netRow.isSelected) ? Font.DemiBold : Font.Normal
                                }

                                IslandIcon {
                                    Layout.alignment: Qt.AlignVCenter
                                    kind: netRow.netOpen ? "lockOpen" : "lock"
                                    size: 12
                                    color: netRow.netOpen ? "#6a6a72" : "#8a8a92"
                                }

                                Text {
                                    Layout.alignment: Qt.AlignVCenter
                                    text: "zapisana"
                                    color: "#6a6a72"
                                    font.pixelSize: 9
                                    visible: netRow.netKnown && !netRow.netConnected
                                }
                            }

                            MouseArea {
                                id: netMouse

                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor

                                property bool counted: false

                                function syncHover() {
                                    const now = containsMouse;
                                    if (now === counted) return;
                                    counted = now;
                                    netList.hoveredRows += now ? 1 : -1;
                                }

                                onContainsMouseChanged: syncHover()
                                // Delegat zniszczony pod kursorem zostawiłby
                                // licznik zawyżony — wyspa nigdy by się nie zwinęła.
                                Component.onDestruction: if (counted) netList.hoveredRows -= 1

                                onClicked: if (netRow.net) panel.pick(netRow.net)
                            }
                        }
                    }

                    Text {
                        anchors.centerIn: parent
                        width: parent.width - 16
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.WordWrap
                        text: !NetworkService.available ? "Brak karty Wi‑Fi"
                            : !NetworkService.enabled ? "Włącz Wi‑Fi"
                            : "Szukam sieci…"
                        color: "#6a6a72"
                        font.pixelSize: 11
                        visible: netList.count === 0
                    }
                }

                IslandTextButton {
                    id: btnHidden
                    Layout.fillWidth: true
                    text: "Sieć ukryta"
                    icon: "plus"
                    enabled: NetworkService.enabled
                    onClicked: panel.openHidden()
                }
            }

            // ---- prawa: formularz ----
            // Przyciski siedzą POZA Flickable, przypięte na dole. Formularz
            // 802.1X ma osiem pól i jest wyższy niż nakładka (zmierzone:
            // ~548 px przy 360 px miejsca), więc wewnątrz przewijanego
            // obszaru "Połącz" wypadałby pod krawędź i trzeba by go szukać.
            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 8

                Item {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true

                    // Nic nie wybrane — podpowiedź zamiast pustego miejsca.
                    Text {
                        anchors.centerIn: parent
                        width: parent.width - 20
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.WordWrap
                        text: "Wybierz sieć z listy\nalbo dodaj ukrytą."
                        color: "#55555e"
                        font.pixelSize: 12
                        visible: !panel.formOpen
                    }

                    // Formularz bywa wyższy niż panel (802.1X ma sześć pól),
                    // więc przewija się we własnym Flickable.
                    Flickable {
                        id: formScroll

                        anchors.fill: parent
                        contentHeight: form.implicitHeight
                        boundsBehavior: Flickable.StopAtBounds
                        interactive: contentHeight > height
                        visible: panel.formOpen
                        clip: true

                        // Pozycja rozwiniętej listy liczona jest raz, przy
                        // otwarciu (mapToItem nie jest powiązaniem), więc
                        // przewinięcie formularza zostawiłoby ją w powietrzu.
                        onContentYChanged: {
                            dSecurity.close();
                            dEap.close();
                            dPhase2.close();
                        }

                        WheelHandler {
                            target: null
                            enabled: formScroll.interactive
                            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
                        }

                        ColumnLayout {
                            id: form

                            width: formScroll.width
                            spacing: 10

                            // Nazwa: wpisywana tylko przy sieci ukrytej.
                            IslandTextField {
                                id: fSsid
                                Layout.fillWidth: true
                                label: "Nazwa sieci"
                                placeholder: "SSID"
                                readOnly: !panel.hiddenMode
                                enabled: !panel.busyHere
                                onAccepted: panel.submit()
                            }

                            // Zabezpieczenia: przy sieci z listy tylko je pokazujemy,
                            // bo punkt dostępowy sam mówi, czego używa.
                            IslandDropdown {
                                id: dSecurity
                                Layout.fillWidth: true
                                menuParent: menuLayer
                                label: "Zabezpieczenia"
                                visible: panel.hiddenMode
                                enabled: !panel.busyHere
                                model: NetworkService.securityChoices
                                value: panel.fieldSecurity
                                onPicked: v => panel.fieldSecurity = v
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                visible: !panel.hiddenMode
                                spacing: 6

                                Text {
                                    text: "Zabezpieczenia"
                                    color: "#9a9aa2"
                                    font.pixelSize: 11
                                    font.weight: Font.DemiBold
                                }

                                Text {
                                    Layout.fillWidth: true
                                    elide: Text.ElideRight
                                    text: panel.selected ? NetworkService.securityLabel(panel.selected.security) : ""
                                    color: "#f2f2f2"
                                    font.pixelSize: 11
                                }
                            }

                            // ---- hasło (WPA/WPA2/WPA3/WEP) ----
                            IslandTextField {
                                id: fPsk
                                Layout.fillWidth: true
                                label: panel.securityKey === "wep" ? "Klucz WEP" : "Hasło"
                                placeholder: panel.securityKey === "wep" ? "klucz sieci" : "co najmniej 8 znaków"
                                password: true
                                visible: panel.wantsSecrets && panel.wantsPassword
                                enabled: !panel.busyHere
                                // Czerwona ramka dopiero, gdy coś wpisano — puste
                                // pole na starcie nie jest jeszcze błędem.
                                invalid: text !== "" && panel.securityKey !== "wep"
                                    && text.length < 8 && text.length !== 64
                                onAccepted: panel.submit()
                            }

                            // ---- 802.1X ----
                            IslandDropdown {
                                id: dEap
                                Layout.fillWidth: true
                                menuParent: menuLayer
                                label: "Metoda EAP"
                                visible: panel.wantsSecrets && panel.wantsEap
                                enabled: !panel.busyHere
                                model: NetworkService.eapChoices
                                value: panel.fieldEap
                                onPicked: v => panel.fieldEap = v
                            }

                            IslandTextField {
                                id: fIdentity
                                Layout.fillWidth: true
                                label: "Tożsamość"
                                placeholder: "np. student@uczelnia.pl"
                                visible: panel.wantsSecrets && panel.wantsEap
                                enabled: !panel.busyHere
                                onAccepted: panel.submit()
                            }

                            IslandTextField {
                                id: fAnon
                                Layout.fillWidth: true
                                label: "Tożsamość anonimowa (opcjonalna)"
                                placeholder: "np. anonymous@uczelnia.pl"
                                visible: panel.wantsSecrets && panel.wantsEap
                                enabled: !panel.busyHere
                                onAccepted: panel.submit()
                            }

                            IslandTextField {
                                id: fEapPass
                                Layout.fillWidth: true
                                // Przy TLS hasło odblokowuje klucz prywatny,
                                // a nie uwierzytelnia użytkownika.
                                label: panel.fieldEap === "tls" ? "Hasło klucza prywatnego" : "Hasło"
                                password: true
                                visible: panel.wantsSecrets && panel.wantsEap
                                enabled: !panel.busyHere
                                onAccepted: panel.submit()
                            }

                            IslandDropdown {
                                id: dPhase2
                                Layout.fillWidth: true
                                menuParent: menuLayer
                                label: "Uwierzytelnianie wewnętrzne"
                                visible: panel.wantsSecrets && panel.wantsEap && panel.fieldEap !== "tls"
                                enabled: !panel.busyHere
                                model: NetworkService.phase2Choices
                                value: panel.fieldPhase2
                                onPicked: v => panel.fieldPhase2 = v
                            }

                            IslandTextField {
                                id: fCaCert
                                Layout.fillWidth: true
                                label: "Certyfikat CA (opcjonalny)"
                                placeholder: "/etc/ssl/certs/…"
                                visible: panel.wantsSecrets && panel.wantsEap
                                enabled: !panel.busyHere
                                maxLength: 255
                                onAccepted: panel.submit()
                            }

                            IslandCheckbox {
                                id: cbAuto
                                Layout.topMargin: 2
                                text: "Łącz automatycznie"
                                visible: !panel.knownNetwork
                                enabled: !panel.busyHere
                                checked: panel.fieldAuto
                                onToggled: panel.fieldAuto = !panel.fieldAuto
                            }

                            // Sieć zapisana: hasło już jest, więc zamiast formularza
                            // zostają same akcje.
                            Text {
                                Layout.fillWidth: true
                                wrapMode: Text.WordWrap
                                visible: panel.knownNetwork
                                text: panel.selected && panel.selected.connected
                                    ? "Połączono z tą siecią."
                                    : "Hasło jest zapisane — wystarczy połączyć."
                                color: "#9a9aa2"
                                font.pixelSize: 11
                            }

                        }
                    }
                }

                // ---- przyciski ----
                RowLayout {
                    visible: panel.formOpen
                    Layout.fillWidth: true
                    Layout.topMargin: 4
                    spacing: 8

                    IslandTextButton {
                        id: btnCancel
                        text: "Anuluj"
                        onClicked: panel.closeForm()
                    }

                    Item { Layout.fillWidth: true }

                    IslandTextButton {
                        id: btnForget
                        text: "Zapomnij"
                        icon: "trash"
                        danger: true
                        visible: panel.knownNetwork
                        onClicked: {
                            NetworkService.forget(panel.selected);
                            panel.closeForm();
                        }
                    }

                    IslandTextButton {
                        id: btnDisconnect
                        text: "Rozłącz"
                        visible: panel.selected !== null && panel.selected.connected
                        onClicked: NetworkService.disconnect(panel.selected)
                    }

                    IslandTextButton {
                        id: btnConnect
                        text: "Połącz"
                        icon: "check"
                        primary: true
                        visible: !(panel.selected !== null && panel.selected.connected)
                        busy: panel.busyHere
                        enabled: panel.canSubmit
                        onClicked: panel.submit()
                    }
                }
            }
        }
    }

    // Warstwa rozwiniętych list wyboru. Musi być OSTATNIM dzieckiem panelu
    // i poza przewijanym formularzem: formularz przycina (clip), a rodzeństwo
    // deklarowane później rysuje się na wierzchu.
    Item {
        id: menuLayer
        anchors.fill: parent
        z: 50
    }
}
