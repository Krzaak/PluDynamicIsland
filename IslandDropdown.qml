import QtQuick

// Lista wyboru (typ zabezpieczeń, metoda EAP). Własna, bo QtQuick.Controls
// ciągnie za sobą styl, który w tej wyspie i tak trzeba by przykryć w całości.
//
// Rozwinięta lista NIE jest częścią układu — inaczej rozpychałaby formularz
// i zmieniała rozmiar wyspy przy każdym otwarciu.
//
// Samo `z: 100` to za mało w dwóch sytuacjach (obie zmierzone na formularzu
// 802.1X):
//  * `z` działa tylko między rodzeństwem, a lista jest dzieckiem tej listy
//    wyboru — kolejne pola formularza (deklarowane później) i tak rysowały się
//    NA niej;
//  * przewijany formularz ma `clip: true`, który ucina wszystko poza swoim
//    prostokątem, i `z` tego nie omija.
// Dlatego właściciel podaje `menuParent` — warstwę poza obszarem przycinania,
// deklarowaną na końcu pliku. Pozycja liczy się wtedy przez mapToItem
// w chwili otwarcia, z odbiciem do góry, gdy pod spodem brakuje miejsca.
Item {
    id: drop

    // model: [{ value: <cokolwiek>, label: "tekst" }, ...]
    property var model: []
    property var value: null
    property string label: ""
    property color accent: "#5b8cff"
    property int maxVisible: 5          // dłuższe listy się przewijają

    signal picked(var value)

    // Gdzie rysować rozwiniętą listę. null = w miejscu (gdy nic nie przycina).
    property Item menuParent: null

    property bool open: false
    readonly property bool hovering: (headMouse.containsMouse && drop.enabled) || drop.open

    readonly property int rowH: 28
    readonly property string valueLabel: {
        for (let i = 0; i < (model || []).length; i++)
            if (model[i].value === drop.value) return model[i].label;
        return "—";
    }

    function close() { drop.open = false; }

    // mapToItem nie jest powiązaniem — nie przeliczy się samo przy przewijaniu.
    // Liczymy raz, przy otwarciu, a właściciel zamyka listę, gdy formularz
    // odjedzie (patrz onContentYChanged w WifiPanel).
    function place() {
        const host = menu.parent;
        const below = drop.mapToItem(host, 0, head.y + head.height + 4);
        let y = below.y;

        if (host && y + menu.height > host.height) {
            const above = drop.mapToItem(host, 0, head.y - 4 - menu.height);
            y = above.y >= 0 ? above.y : Math.max(0, host.height - menu.height);
        }

        menu.menuX = below.x;
        menu.menuY = y;
    }

    onOpenChanged: if (open) place()

    implicitWidth: 200
    implicitHeight: label === "" ? 34 : 51
    opacity: enabled ? 1 : 0.4

    Behavior on opacity { NumberAnimation { duration: 180 } }

    Text {
        visible: drop.label !== ""
        text: drop.label
        color: "#9a9aa2"
        font.pixelSize: 11
        font.weight: Font.DemiBold
        font.letterSpacing: 0.3
    }

    Rectangle {
        id: head

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: 34
        radius: 10
        antialiasing: true
        color: drop.open ? "#1d1d22" : "#151519"

        border.width: 1
        border.color: drop.open ? drop.accent : Qt.rgba(1, 1, 1, drop.hovering ? 0.18 : 0.08)

        Behavior on color { ColorAnimation { duration: 140 } }
        Behavior on border.color { ColorAnimation { duration: 140 } }

        Text {
            anchors.left: parent.left
            anchors.leftMargin: 10
            anchors.right: arrow.left
            anchors.rightMargin: 4
            anchors.verticalCenter: parent.verticalCenter
            elide: Text.ElideRight
            text: drop.valueLabel
            color: "#f2f2f2"
            font.pixelSize: 13
        }

        IslandIcon {
            id: arrow
            anchors.right: parent.right
            anchors.rightMargin: 9
            anchors.verticalCenter: parent.verticalCenter
            kind: "chevron"
            size: 14
            color: drop.hovering ? "#f2f2f2" : "#8a8a92"
            rotation: drop.open ? 180 : 0
            Behavior on rotation { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
        }

        MouseArea {
            id: headMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: drop.open = !drop.open
        }
    }

    // ---- rozwinięta lista ----
    Rectangle {
        id: menu

        property real menuX: 0
        property real menuY: head.y + head.height + 4

        z: 100
        parent: drop.menuParent ?? drop
        x: menuX
        y: menuY
        width: drop.width
        height: Math.min((drop.model || []).length, drop.maxVisible) * drop.rowH + 8
        radius: 12
        antialiasing: true
        color: "#121216"
        border.width: 1
        border.color: Qt.rgba(1, 1, 1, 0.12)

        visible: opacity > 0.01
        opacity: drop.open ? 1 : 0
        scale: drop.open ? 1 : 0.96
        transformOrigin: Item.Top

        Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
        Behavior on scale { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

        // Lista bierze kółko tylko wtedy, gdy ma co przewijać. Ta sama pułapka
        // co w karcie łączności: Flickable na granicy odrzuca zdarzenie
        // i poleciałoby do wyspy jako zmiana karty.
        WheelHandler {
            target: null
            enabled: drop.open && items.contentHeight > items.height
            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
        }

        ListView {
            id: items

            anchors.fill: parent
            anchors.margins: 4
            clip: true
            interactive: contentHeight > height
            boundsBehavior: Flickable.StopAtBounds
            model: drop.model

            delegate: Rectangle {
                required property var modelData
                readonly property bool active: modelData && modelData.value === drop.value

                width: ListView.view.width
                height: drop.rowH
                radius: 8
                antialiasing: true
                color: Qt.rgba(1, 1, 1, rowMouse.containsMouse ? 0.1 : 0)

                Behavior on color { ColorAnimation { duration: 120 } }

                Text {
                    anchors.left: parent.left
                    anchors.leftMargin: 8
                    anchors.right: tick.left
                    anchors.rightMargin: 4
                    anchors.verticalCenter: parent.verticalCenter
                    elide: Text.ElideRight
                    text: modelData ? modelData.label : ""
                    color: active ? "#f2f2f2" : "#c8c8cf"
                    font.pixelSize: 12
                    font.weight: active ? Font.DemiBold : Font.Normal
                }

                IslandIcon {
                    id: tick
                    anchors.right: parent.right
                    anchors.rightMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    kind: "check"
                    size: 13
                    color: drop.accent
                    visible: active
                }

                MouseArea {
                    id: rowMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    // Jak IslandSwitch i IslandCheckbox: lista NIE ustawia
                    // sobie value sama. Gdyby to robiła, przypisanie zrywałoby
                    // powiązanie `value: cośTam` u właściciela i od pierwszego
                    // wyboru nie dałoby się już ustawić wartości z zewnątrz.
                    onClicked: {
                        if (modelData) drop.picked(modelData.value);
                        drop.open = false;
                    }
                }
            }
        }
    }
}
