import QtQuick
import Quickshell.Widgets

// Pigułka wyjścia dźwięku, która robi podwójną robotę: pokazuje, DOKĄD leci
// dźwięk, i JAK GŁOŚNO — tło wypełnia się do poziomu głośności, a obok nazwy
// stoi procent.
//
// Osobny suwak w kolumnie tytułu kosztował 22 px wysokości karty (118 -> 140)
// i to było za dużo. Tutaj głośność nie zabiera ani piksela: korzysta
// z elementu, który i tak tam stał.
//
// Podział kliknięć: ikona wycisza, reszta pigułki przełącza wyjście.
// Kółko zmienia głośność i jest POŁYKANE, żeby nie przeleciało do wyspy
// jako zmiana karty.
//
// Wystawia `hovering` — wyspa MUSI doliczyć je do controlsHovered, inaczej
// najechanie na pigułkę zwinie wyspę (patrz DynamicIsland: hover z trzech źródeł).
//
// ClippingRectangle, nie Rectangle: `clip: true` na Rectangle z `radius` daje
// przycinanie PROSTOKĄTNE, więc wypełnienie wystawałoby poza zaokrąglone rogi.
ClippingRectangle {
    id: chip

    readonly property bool hovering: (mouse.containsMouse && chip.switchable) || iconMouse.containsMouse
    readonly property bool switchable: AudioService.sinks.length > 1

    // Dłuższe nazwy urządzeń są obcinane, żeby nie rozpychać kolumny tytułu.
    property int maxWidth: 180

    // W trakcie nie ma czego ciągnąć (kółko daje skokowe wartości), więc
    // poziom bierzemy wprost z PipeWire.
    readonly property real level: AudioService.volume
    readonly property bool muted: AudioService.muted
    readonly property bool canVolume: AudioService.volumeReady

    implicitWidth: Math.min(maxWidth, content.implicitWidth + 18)
    implicitHeight: 20
    radius: 10
    antialiasing: true
    color: Qt.rgba(1, 1, 1, chip.hovering ? 0.2 : 0.08)

    Behavior on color { ColorAnimation { duration: 140 } }

    // ---- wypełnienie = głośność ----
    // Pod treścią, więc napis zostaje czytelny na obu połowach.
    Rectangle {
        width: chip.canVolume ? Math.max(0, Math.min(chip.width, chip.width * chip.level)) : 0
        height: chip.height
        // Wyciszone: wypełnienie zostaje jako duch, żeby było widać poziom,
        // do którego wróci odciszenie — ale nie udaje grającego dźwięku.
        color: chip.muted ? Qt.rgba(1, 1, 1, 0.05) : Qt.rgba(1, 1, 1, 0.16)

        Behavior on width { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }
        Behavior on color { ColorAnimation { duration: 160 } }
    }

    Row {
        id: content
        anchors.centerIn: parent
        spacing: 5

        // Ikona: stan wyjścia, a po kliknięciu wyciszenie.
        Item {
            id: iconBox

            width: 13
            height: 13
            y: (content.height - height) / 2

            IslandIcon {
                anchors.centerIn: parent
                kind: chip.muted ? "volumeOff" : AudioService.currentIcon
                size: 11
                color: chip.muted ? "#e5484d"
                    : (iconMouse.containsMouse ? "#ffffff" : (chip.switchable ? "#e2e2e6" : "#9a9aa2"))

                Behavior on color { ColorAnimation { duration: 140 } }
            }
        }

        Text {
            y: (content.height - height) / 2
            // Budżet dla nazwy: szerokość pigułki bez wyściółki, ikony,
            // procentu i dwóch odstępów.
            width: Math.min(implicitWidth, chip.maxWidth - 18 - 13 - 5 - percent.width - 5)
            elide: Text.ElideRight
            text: AudioService.currentLabel
            color: chip.switchable ? "#e2e2e6" : "#9a9aa2"
            font.pixelSize: 11
            font.weight: Font.DemiBold
        }

        Text {
            id: percent
            y: (content.height - height) / 2
            visible: chip.canVolume
            text: "· " + Math.round(chip.level * 100) + "%"
            color: chip.muted ? "#78787f" : "#9a9aa2"
            font.pixelSize: 10

            Behavior on color { ColorAnimation { duration: 140 } }
        }
    }

    // Przełączanie wyjścia. Pod ikoną, więc ta dostaje swoje kliknięcia
    // (późniejsze rodzeństwo jest na wierzchu).
    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        enabled: chip.switchable
        onClicked: AudioService.cycleSink()
    }

    // Wyciszenie. Obszar szerszy niż sama ikona (13 px) — w 13 pikseli
    // nikt nie trafi.
    MouseArea {
        id: iconMouse

        x: 0
        y: 0
        width: 22
        height: chip.height
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        enabled: chip.canVolume
        onClicked: AudioService.toggleMute()
    }

    // Kółko nad pigułką zmienia głośność zamiast przełączać kartę.
    // blocking (domyślnie true) połyka zdarzenie, więc nie dojdzie do
    // WheelHandlera wyspy — ta sama sztuczka, co przy listach.
    //
    // Obrót jest SUMOWANY do pełnego ząbka, nie stosowany od razu. Pierwsza
    // wersja zmieniała głośność o cały krok na każde zdarzenie i na touchpadzie
    // (tu: syna2393) jedno machnięcie palcem przeskakiwało kilkadziesiąt
    // kroków — stąd wrażenie, że w nic nie da się trafić.
    property real wheelAccum: 0

    function applyWheel(dy) {
        if (dy === 0) return;
        // Zmiana kierunku zeruje resztkę, żeby pierwszy ząbek w drugą stronę
        // nie był "ułamkowy" po niedokończonym machnięciu.
        if ((chip.wheelAccum > 0) !== (dy > 0)) chip.wheelAccum = 0;

        chip.wheelAccum += dy;
        const notch = AudioService.volumeWheelDelta;

        while (Math.abs(chip.wheelAccum) >= notch) {
            AudioService.stepVolume(chip.wheelAccum > 0 ? AudioService.volumeStep : -AudioService.volumeStep);
            chip.wheelAccum += chip.wheelAccum > 0 ? -notch : notch;
        }
    }

    WheelHandler {
        target: null
        enabled: chip.canVolume
        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad

        onWheel: event => chip.applyWheel(event.angleDelta.y)
    }
}
