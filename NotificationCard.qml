import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Services.Notifications
import Quickshell.Widgets

// Karta powiadomień: świeże powiadomienie (dopóki nie wygaśnie albo nie zostanie
// kliknięte) zajmuje całą kartę jak dymek — historia jest wtedy schowana.
// Trwający transfer to "bohater" u góry z paskiem postępu, pod nim historia;
// transfer trwa minutami, więc nie zasłania historii na stałe. Gdy nie ma
// czego wyróżnić, historia zajmuje całą kartę.
//
// Stały rozmiar (trzecia geometria z DynamicIsland) i jedno `hovering`
// doliczane do controlsHovered — jak ConnectivityCard.
Item {
    id: card

    // ---------------------------------------------------------------
    // Ustawienia
    // ---------------------------------------------------------------

    property int rowHeight: 26

    // Podświetlenie przycisku zdejmowania wpisu — jak czerwone przyciski
    // sterowania (IslandButton.accent).
    property color deleteAccent: "#e5484d"

    // Dwie wysokości: historia potrzebuje miejsca na listę, dymek tylko na
    // ikonę, tytuł, dwie linie treści i akcje — wyspa nie musi być wtedy
    // tak wysoka. Wyspa animuje przejście między nimi sprężyną.
    property int historyHeight: 170
    property int popupHeight: 118

    implicitWidth: 440
    implicitHeight: popup ? popupHeight : historyHeight

    // ---------------------------------------------------------------
    // Stan
    // ---------------------------------------------------------------

    readonly property var job: NotificationService.activeJob
    readonly property var latest: NotificationService.latest

    // Transfer ma pierwszeństwo przed powiadomieniem — jest "żywy".
    readonly property string heroKind: job !== null ? "job" : (latest !== null ? "notification" : "")
    readonly property bool hasHero: heroKind !== ""

    // Dymek: powiadomienie na całej karcie. Kończy się, gdy serwis wyzeruje
    // `latest` (wygaśnięcie po popupDuration, kliknięcie, zamknięcie przez
    // aplikację) — wtedy karta wraca do historii.
    readonly property bool popup: heroKind === "notification"

    readonly property bool hovering: btnClear.hovering || btnCancel.hovering
        || historyList.hoveredRows > 0 || actionRow.hoveredCount > 0 || heroMouse.containsMouse

    function timeLabel(d) {
        return Qt.formatTime(d, "HH:mm");
    }

    function urgencyColor(u) {
        return u === NotificationUrgency.Critical ? "#e5484d" : "#5b8cff";
    }

    // ---------------------------------------------------------------
    // Okrągły przycisk karty
    // ---------------------------------------------------------------

    // Nagłówek historii i wiersze używają tego samego kształtu — różnią się
    // tylko średnicą i kolorem podświetlenia. `shown` gasi przycisk, ale
    // ZOSTAWIA jego miejsce w układzie: gdyby znikał, czas i nazwa aplikacji
    // skakałyby w bok przy każdym najechaniu na wiersz. Slot łapie hover także
    // wygaszony — dzięki temu wjazd kursorem od prawej wyłania przycisk.
    component CardButton: Item {
        id: btn

        property string kind: "close"
        property real diameter: 18
        property real iconSize: 10
        property color hoverColor: Qt.rgba(1, 1, 1, 0.22)
        property color idleColor: Qt.rgba(1, 1, 1, 0.1)
        property bool shown: true

        readonly property bool hovering: btnMouse.containsMouse && btn.enabled

        signal clicked()

        implicitWidth: diameter
        implicitHeight: diameter
        opacity: shown ? (enabled ? 1 : 0.3) : 0
        Behavior on opacity { NumberAnimation { duration: 140; easing.type: Easing.OutCubic } }

        Rectangle {
            anchors.fill: parent
            radius: width / 2
            antialiasing: true
            color: btn.hovering ? btn.hoverColor : btn.idleColor
            Behavior on color { ColorAnimation { duration: 120 } }
        }

        IslandIcon {
            anchors.centerIn: parent
            kind: btn.kind
            size: btn.iconSize
            color: "#f2f2f2"
        }

        MouseArea {
            id: btnMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: btn.clicked()
        }
    }

    // ---------------------------------------------------------------
    // Układ
    // ---------------------------------------------------------------

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 14
        anchors.bottomMargin: 16
        spacing: 6

        // ---- bohater ----
        Item {
            id: hero

            Layout.fillWidth: true
            Layout.preferredHeight: 66
            Layout.fillHeight: card.popup
            visible: card.hasHero

            // Kliknięcie w powiadomienie wywołuje domyślną akcję (jeśli jest)
            // i je zamyka — tak jak kliknięcie w dymek Plasmy.
            MouseArea {
                id: heroMouse
                anchors.fill: parent
                hoverEnabled: true
                enabled: card.heroKind === "notification"
                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: {
                    const e = card.latest;
                    if (!e) return;
                    NotificationService.openEntry(e);
                    NotificationService.removeEntry(e);
                }
            }

            RowLayout {
                anchors.fill: parent
                spacing: 12

                // Ikona aplikacji / obraz; dzwonek albo strzałka, gdy brak.
                ClippingRectangle {
                    Layout.preferredWidth: card.popup ? 60 : 48
                    Layout.preferredHeight: card.popup ? 60 : 48
                    Layout.alignment: Qt.AlignVCenter
                    radius: card.popup ? 16 : 13
                    color: "#17171a"

                    IslandIcon {
                        anchors.centerIn: parent
                        kind: card.heroKind === "job" ? "download" : "bell"
                        size: card.popup ? 26 : 22
                        color: "#4a4a52"
                        visible: heroImage.status !== Image.Ready
                    }

                    // asynchronous celowo wyłączone: ikony z motywu idą przez
                    // image://icon i Qt ładuje je w wątku QQuickPixmapReader, a ten
                    // dostawca nie jest wątkowo bezpieczny ("Cannot create children
                    // for a parent that is in a different thread"). Ikony są małe.
                    Image {
                        id: heroImage
                        anchors.fill: parent
                        anchors.margins: card.heroKind === "job" ? 10 : 0
                        fillMode: Image.PreserveAspectFit
                        asynchronous: false
                        sourceSize.width: 96
                        sourceSize.height: 96
                        source: card.heroKind === "job" ? (card.job.icon || "")
                              : card.heroKind === "notification" ? (card.latest.icon || "") : ""
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignVCenter
                    spacing: 2

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 6

                        Text {
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                            text: card.heroKind === "job" ? NotificationService.jobTitle(card.job)
                                : card.heroKind === "notification" ? card.latest.summary : ""
                            color: "#f5f5f5"
                            font.pixelSize: card.popup ? 15 : 14
                            font.weight: Font.DemiBold
                        }

                        Text {
                            text: card.heroKind === "notification"
                                ? (card.latest.appName !== "" ? card.latest.appName + " · " : "") + card.timeLabel(card.latest.time)
                                : ""
                            color: "#78787f"
                            font.pixelSize: 10
                            visible: text !== ""
                        }
                    }

                    // W dymku treść ma miejsce na dwie linie; przy transferze
                    // (pół karty) mieści się jedna.
                    Text {
                        Layout.fillWidth: true
                        elide: Text.ElideRight
                        wrapMode: card.popup ? Text.WordWrap : Text.NoWrap
                        maximumLineCount: card.popup ? 2 : 1
                        text: card.heroKind === "job"
                            ? (card.job.descriptionValue1 !== "" ? card.job.descriptionValue1 : card.job.infoMessage)
                            : card.heroKind === "notification" ? card.latest.body : ""
                        color: "#9a9aa2"
                        font.pixelSize: 12
                        visible: text !== ""
                    }

                    // Transfer: procent, prędkość, ile z ilu, pasek.
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        visible: card.heroKind === "job"

                        Text {
                            text: {
                                if (card.heroKind !== "job") return "";
                                const j = card.job;
                                let parts = [j.percent + "%"];
                                if (j.speed > 0) parts.push(NotificationService.formatBytes(j.speed) + "/s");
                                if (j.totalBytes > 0) parts.push(NotificationService.formatBytes(j.processedBytes) + " / " + NotificationService.formatBytes(j.totalBytes));
                                else if (j.totalFiles > 0) parts.push(j.processedFiles + " / " + j.totalFiles + " plików");
                                if (j.suspended) parts.push("wstrzymano");
                                return parts.join(" · ");
                            }
                            color: "#9a9aa2"
                            font.pixelSize: 11
                        }

                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 3
                            Layout.alignment: Qt.AlignVCenter
                            radius: 1.5
                            antialiasing: true
                            color: Qt.rgba(1, 1, 1, 0.13)

                            Rectangle {
                                width: parent.width * (card.heroKind === "job" ? card.job.percent / 100 : 0)
                                height: parent.height
                                radius: parent.radius
                                antialiasing: true
                                color: "#5b8cff"
                                Behavior on width { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
                            }
                        }
                    }

                    // Powiadomienie: przyciski akcji (bez "default" — to kliknięcie w całość).
                    Row {
                        id: actionRow

                        property int hoveredCount: 0

                        Layout.topMargin: 2
                        spacing: 6
                        visible: card.heroKind === "notification" && repeaterActions.count > 0

                        Repeater {
                            id: repeaterActions
                            model: card.heroKind === "notification"
                                ? card.latest.actions.filter(a => a.identifier !== "default").slice(0, 3)
                                : []

                            delegate: Rectangle {
                                required property var modelData

                                readonly property bool hovering: actionMouse.containsMouse

                                width: actionText.implicitWidth + 18
                                height: 20
                                radius: 10
                                antialiasing: true
                                color: Qt.rgba(1, 1, 1, hovering ? 0.22 : 0.1)
                                Behavior on color { ColorAnimation { duration: 120 } }

                                Text {
                                    id: actionText
                                    anchors.centerIn: parent
                                    text: modelData.text
                                    color: "#f2f2f2"
                                    font.pixelSize: 11
                                    font.weight: Font.DemiBold
                                }

                                MouseArea {
                                    id: actionMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    property bool counted: false
                                    onContainsMouseChanged: {
                                        if (containsMouse === counted) return;
                                        counted = containsMouse;
                                        actionRow.hoveredCount += containsMouse ? 1 : -1;
                                    }
                                    Component.onDestruction: if (counted) actionRow.hoveredCount -= 1
                                    // Kolejność ma znaczenie: invoke() zamyka powiadomienie,
                                    // to zeruje listę akcji i niszczy TEN delegat w trakcie
                                    // obsługi kliknięcia — po invoke() `card` już nie istnieje.
                                    onClicked: {
                                        const entry = card.latest;
                                        const action = modelData.action;
                                        if (entry) NotificationService.removeEntry(entry);
                                        action.invoke();
                                    }
                                }
                            }
                        }
                    }
                }

                // Anuluj transfer (tylko gdy zadanie da się ubić).
                IslandButton {
                    id: btnCancel
                    Layout.alignment: Qt.AlignVCenter
                    kind: "close"
                    accented: true
                    visible: card.heroKind === "job"
                    enabled: card.heroKind === "job" && card.job.killable
                    onClicked: NotificationService.cancelJob(card.job.id)
                }
            }
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 1
            color: Qt.rgba(1, 1, 1, 0.08)
            visible: card.hasHero && !card.popup
        }

        // ---- historia (schowana, gdy dymek zajmuje całą kartę) ----
        RowLayout {
            Layout.fillWidth: true
            spacing: 6
            visible: !card.popup

            Text {
                Layout.fillWidth: true
                text: NotificationService.serverActive ? "Powiadomienia" : "Powiadomienia (Plasma trzyma serwer)"
                color: "#9a9aa2"
                font.pixelSize: 11
                font.weight: Font.DemiBold
                font.letterSpacing: 0.4
            }

            // Czyści całą historię — stąd inny rozmiar niż przyciski wiersza.
            CardButton {
                id: btnClear

                diameter: 22
                iconSize: 12
                kind: "close"
                idleColor: Qt.rgba(1, 1, 1, 0.08)
                hoverColor: Qt.rgba(1, 1, 1, 0.2)
                enabled: NotificationService.history.length > 0
                onClicked: NotificationService.clearHistory()
            }
        }

        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            visible: !card.popup

            // Połyka kółko na granicy listy, żeby nie przełączało karty —
            // szczegóły przy bliźniaczym handlerze w ConnectivityCard.
            WheelHandler {
                target: null
                enabled: historyList.contentHeight > historyList.height
                acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
            }

            ListView {
                id: historyList

                property int hoveredRows: 0

                anchors.fill: parent
                model: NotificationService.history
                boundsBehavior: Flickable.StopAtBounds
                flickDeceleration: 4000

                delegate: Item {
                    id: row

                    required property var modelData

                    // Aplikacja źródłowa wpisu: podpowiedź desktop-entry albo
                    // heurystyka po nazwie. Warunek na appCount nie jest ozdobą —
                    // to on sprawia, że powiązanie przelicza się, gdy lista
                    // aplikacji dojedzie po starcie wyspy.
                    readonly property string appId: NotificationService.appCount > 0
                        ? NotificationService.appIdFor(modelData) : ""

                    // Wpis z żywą akcją domyślną otwiera się na TEJ rozmowie,
                    // nawet gdy aplikacji nie da się rozpoznać z pliku .desktop.
                    readonly property bool hasDefault: {
                        const a = modelData.actions || [];
                        for (let i = 0; i < a.length; i++)
                            if (a[i].identifier === "default") return true;
                        return false;
                    }
                    readonly property bool launchable: appId !== "" || hasDefault

                    // Hover wiersza to suma podkładki i przycisku otwierania:
                    // przycisk leży NA podkładce i zabiera jej hover na wyłączność,
                    // więc sama podkładka gasłaby w chwili najechania na przycisk.
                    readonly property bool hovered: rowMouse.containsMouse || btnOpen.hovering || btnDelete.hovering

                    width: ListView.view.width
                    height: card.rowHeight

                    // Licznik hovera listy — OR po delegatach nie zadziała, bo
                    // delegaty powstają i giną. Delegat zniszczony pod kursorem
                    // musi oddać swój głos, inaczej wyspa nigdy się nie zwinie.
                    property bool counted: false
                    onHoveredChanged: {
                        if (hovered === counted) return;
                        counted = hovered;
                        historyList.hoveredRows += hovered ? 1 : -1;
                    }
                    Component.onDestruction: if (counted) historyList.hoveredRows -= 1

                    Rectangle {
                        anchors.fill: parent
                        anchors.rightMargin: 6
                        radius: 7
                        color: Qt.rgba(1, 1, 1, row.hovered ? 0.08 : 0)
                        Behavior on color { ColorAnimation { duration: 120 } }
                    }

                    // Podkładka wiersza leży POD układem, żeby przycisk otwierania
                    // (jego dziecko) dostawał zdarzenia przed nią. Teksty i ikony
                    // myszy nie przyjmują, więc reszta wiersza i tak trafia tutaj.
                    MouseArea {
                        id: rowMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor

                        // Kliknięcie w wiersz usuwa go z historii.
                        onClicked: NotificationService.removeEntry(row.modelData)
                    }

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 6
                        anchors.rightMargin: 12
                        spacing: 8

                        Rectangle {
                            Layout.preferredWidth: 6
                            Layout.preferredHeight: 6
                            Layout.alignment: Qt.AlignVCenter
                            radius: 3
                            antialiasing: true
                            color: row.modelData.kind === "job" ? "#38d47a" : card.urgencyColor(row.modelData.urgency)
                        }

                        Image {
                            Layout.preferredWidth: 14
                            Layout.preferredHeight: 14
                            Layout.alignment: Qt.AlignVCenter
                            fillMode: Image.PreserveAspectFit
                            asynchronous: false
                            sourceSize.width: 28
                            sourceSize.height: 28
                            source: row.modelData.icon || ""
                            visible: status === Image.Ready
                        }

                        Text {
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                            text: row.modelData.summary !== "" ? row.modelData.summary : row.modelData.body
                            color: "#f2f2f2"
                            font.pixelSize: 12
                        }

                        Text {
                            elide: Text.ElideRight
                            Layout.maximumWidth: 90
                            text: row.modelData.appName
                            color: "#6a6a72"
                            font.pixelSize: 10
                            visible: text !== ""
                        }

                        Text {
                            text: card.timeLabel(row.modelData.time)
                            color: "#6a6a72"
                            font.pixelSize: 10
                        }

                        // Otwarcie wpisu i zdjęcie go z historii. Oba sloty są
                        // zarezerwowane zawsze, także gdy wpisu nie ma czym otworzyć.
                        Row {
                            Layout.alignment: Qt.AlignVCenter
                            spacing: 4

                            CardButton {
                                id: btnOpen

                                kind: "open"
                                enabled: row.launchable
                                shown: row.hovered && row.launchable

                                // Otwarcie delegatu nie rusza, usunięcie wpisu
                                // niszczy go w trakcie obsługi kliknięcia — stąd
                                // kopia wpisu do zmiennej i ta kolejność.
                                onClicked: {
                                    const entry = row.modelData;
                                    if (!NotificationService.openEntry(entry)) return;
                                    NotificationService.removeEntry(entry);
                                }
                            }

                            CardButton {
                                id: btnDelete

                                kind: "close"
                                iconSize: 9
                                hoverColor: card.deleteAccent
                                shown: row.hovered

                                onClicked: NotificationService.removeEntry(row.modelData)
                            }
                        }
                    }
                }
            }

            Rectangle {
                anchors.right: parent.right
                width: 2
                radius: 1
                color: Qt.rgba(1, 1, 1, 0.25)
                visible: historyList.contentHeight > historyList.height
                y: historyList.visibleArea.yPosition * historyList.height
                height: Math.max(8, historyList.visibleArea.heightRatio * historyList.height)
            }

            Text {
                anchors.centerIn: parent
                text: NotificationService.serverActive ? "Brak powiadomień" : "Wyłącz aplet powiadomień w zasobniku Plasmy"
                color: "#6a6a72"
                font.pixelSize: 11
                visible: historyList.count === 0
            }
        }
    }
}
