import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Services.Mpris
import Quickshell.Wayland
import Quickshell.Widgets

// Pływająca "wyspa" na górze ekranu: w spoczynku pokazuje tylko zegar,
// po najechaniu myszką (lub kliknięciu wyspy) rozwija się w karuzelę kart
// (AirPods | muzyka | Discord | zegar | łączność | powiadomienia) przewijaną
// kółkiem; karta AirPodsów istnieje tylko wtedy, gdy słuchawki są połączone.
// Karta łączności otwiera nakładki Wi-Fi i Bluetootha, które zastępują całą
// karuzelę i rozciągają wyspę do własnego rozmiaru. Dodatkowo sama się rozwija
// na chwilę, gdy zmieni się utwór — tak jak w iOS. Podczas rozmowy na
// Discordzie obok zwiniętej pigułki stoi druga, mała, z nazwą kanału i timerem.
PanelWindow {
    id: root

    // Variants przekazuje tu ekran, na którym ma żyć ta instancja wyspy.
    // Domyślne null, a nie undefined — inaczej Quickshell krzyczy przy
    // użyciu komponentu bez Variants.
    property var modelData: null
    screen: modelData

    // ---------------------------------------------------------------
    // Ustawienia
    // ---------------------------------------------------------------

    property string uiLocale: "pl_PL"
    property int topMargin: 8
    property int collapseDelay: 220     // ile ms po zjechaniu myszką wyspa się zwija
    property int noticeDuration: 3200   // jak długo trwa auto-rozwinięcie przy zmianie utworu
    property int notificationDuration: 4500   // ...przy nowym powiadomieniu
    property int jobNoticeDuration: 3000      // ...na starcie transferu plików
    property int airPodsNoticeDuration: 3500  // ...po połączeniu AirPodsów
    property int jobBarGap: 4                 // przerwa między wyspą a paskiem postępu pod nią

    // Dogładzanie słupków widma po stronie QML. Przy 60 fps klatka przychodzi
    // co ~17 ms, więc 28 ms to niecałe dwie klatki — słupek zdąży prawie
    // dobiec do celu, zanim przyjdzie następny. Poprzednie 90 ms oznaczało,
    // że nie dobiegał nigdy, i to właśnie dawało wrażenie ospałości.
    property int spectrumSmoothingMs: 28

    // Przewijanie kart kółkiem. Jeden ząbek kółka to 120 jednostek angleDelta;
    // touchpad przysyła drobne porcje, które się sumują. Po przeskoku karty
    // kolejne zdarzenia są ignorowane przez wheelCooldownMs, żeby jedno
    // machnięcie (z bezwładnością touchpada) nie przeskoczyło dwóch kart.
    property int wheelStepDelta: 120
    property int wheelCooldownMs: 260

    property int pillGap: 8             // odstęp pigułek (rozmowa, udostępnianie) od wyspy
    property int pillMaxWidth: 200      // dłuższe nazwy kanałów / aplikacji są obcinane

    // Rozmiar nakładek (Wi-Fi, Bluetooth). Wpisany tutaj, a nie brany
    // z implicitWidth panelu, bo panele siedzą w Loaderze i przy zamkniętej
    // nakładce w ogóle nie istnieją — a wysokość OKNA musi być stała, żeby
    // otwarcie nakładki nie przestawiało rozmiaru powierzchni layer-shella.
    property int overlayWidth: 620
    property int overlayHeight: 360

    // ---------------------------------------------------------------
    // Okno
    // ---------------------------------------------------------------

    anchors {
        top: true
        left: true
        right: true
    }

    // Wysokość okna idzie za najwyższą kartą, nie jest wpisana na sztywno:
    // karta wyższa niż okno wyglądała na uciętą od dołu (powiadomienia, 170 px
    // przy dawnych 160 px okna). Zapas na dole kryje przestrzelenie sprężyny
    // (OutBack z overshoot 0.9 wychodzi ~3% ponad cel, czyli ~4 px przy
    // rozwijaniu z pigułki) i pasek postępu transferu wiszący pod wyspą.
    // Karta powiadomień zmienia wysokość (dymek jest niższy niż historia),
    // ale okno liczy się od jej wyższego wariantu — inaczej każde powiadomienie
    // przestawiałoby rozmiar okna layer-shell tam i z powrotem.
    //
    // Karta AirPodsów i nakładki wchodzą do rachunku ZAWSZE, także gdy ich
    // akurat nie widać — z tego samego powodu: ani połączenie słuchawek, ani
    // otwarcie formularza nie ma przestawiać rozmiaru okna layer-shella.
    readonly property int maxCardHeight: Math.max(...cardHeights, airpods.implicitHeight,
                                                  notifications.historyHeight, overlayHeight)
    property int bottomReserve: 6
    implicitHeight: topMargin + maxCardHeight + bottomReserve + jobBarGap + jobBar.height
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore   // nie rezerwujemy miejsca — wyspa "unosi się" nad oknami

    // Klawiatura TYLKO na czas formularza. Exclusive, nie OnDemand: OnDemand
    // daje klawiaturę dopiero po kliknięciu w powierzchnię, a pole formularza
    // bierze kursor samo (fPsk.take()) i wtedy nie dostałoby ani znaku.
    // Poza nakładką None — wyspa nie ma prawa łapać klawiszy, bo przykryłaby
    // skróty kompozytora.
    WlrLayershell.keyboardFocus: root.overlayOpen
        ? WlrKeyboardFocus.Exclusive
        : WlrKeyboardFocus.None

    // Ukrycie skrótem (IpcHandler w shell.qml). Najpierw wygaszamy treść, potem
    // chowamy całe okno: samo przezroczyste okno nadal łapałoby kursor maską
    // i rozwijało się pod niewidoczną ręką.
    property bool hiddenByUser: false
    property real shownOpacity: hiddenByUser ? 0 : 1
    Behavior on shownOpacity {
        NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
    }
    contentItem.opacity: shownOpacity
    visible: !hiddenByUser || shownOpacity > 0

    // Przypięta wyspa wróciłaby po odkryciu od razu rozwinięta, a schowane
    // okno z klawiaturą Exclusive zjadałoby wszystkie klawisze — stąd i
    // zamknięcie nakładki.
    onHiddenByUserChanged: if (hiddenByUser) { pinned = false; overlayMode = ""; }

    // Rozmiar DOCELOWY wyspy — bez animacji. Maska wejściowa i obszar reagujący
    // na kursor muszą wyprzedzać animację rozwijania: gdyby szły za animowaną
    // szerokością (520 ms), kursor jadący do skrajnego przycisku wyprzedziłby
    // ją, wypadł poza region wejściowy okna, dostalibyśmy "pointer leave"
    // i wyspa zwinęłaby się w trakcie sięgania po przycisk.
    //
    // Bierzemy większy z rozmiarów: przy rozwijaniu od razu docelowy,
    // przy zwijaniu maska kurczy się razem z wyspą.
    readonly property int reachWidth: Math.ceil(Math.max(island.width, expanded ? expandedWidth : collapsedWidth))
    readonly property int reachHeight: Math.ceil(Math.max(island.height, expanded ? expandedHeight : collapsedHeight))

    // Myszkę łapie wyłącznie sam kształt wyspy (plus pigułka rozmowy, gdy jest).
    // Bez tego niewidoczny pasek na całej szerokości ekranu zjadałby kliknięcia
    // w pasek zadań / pulpit.
    mask: Region {
        x: Math.round((root.width - root.reachWidth) / 2)
        y: root.topMargin
        width: root.reachWidth
        height: root.reachHeight
        radius: Math.min(island.radius, root.reachHeight / 2)

        // Region pigułki bierze geometrię podkładki hovera, nie samej pigułki —
        // podkładka ma szerokość 0 poza rozmową, więc wtedy nic nie łapie.
        Region {
            item: pillHoverArea
            radius: root.collapsedHeight / 2
        }
    }

    // ---------------------------------------------------------------
    // Stan
    // ---------------------------------------------------------------

    property bool hovered: false

    // Kursor jest "na wyspie", gdy stoi nad podkładką ALBO nad którymś
    // przyciskiem ALBO nad pigułką rozmowy. Sumujemy wszystkie źródła, bo
    // przycisk pod kursorem przejmuje hover na wyłączność i podkładka przestaje
    // go widzieć — bez tego wyspa zwijałaby się w chwili najechania na przycisk.
    readonly property bool controlsHovered: btnPrev.hovering || btnPlay.hovering || btnNext.hovering
        || btnMic.hovering || btnDeaf.hovering || btnLeave.hovering
        || outputChip.hovering || outputChipIdle.hovering || micSwitch.hovering
        || connectivity.hovering || notifications.hovering || airpods.hovering
        || (overlay.item ? overlay.item.hovering : false)
    readonly property bool pointerInside: areaHover.hovered || controlsHovered || pillHover.hovered

    onPointerInsideChanged: {
        // Pod otwartą nakładką karuzeli nie widać, a przestawienie karty
        // zmieniłoby ją użytkownikowi pod ręką na czas po zamknięciu.
        if (pointerInside && !root.overlayOpen) {
            // Przy dwóch pigułkach każda otwiera swoją kartę: pigułka rozmowy
            // Discorda, główna muzykę (zegar, gdy nic nie gra). Ustawiamy ją PRZED
            // hovered, żeby wyspa od razu rosła do rozmiaru tej karty, a nie
            // najpierw do poprzedniej i dopiero potem przesuwała. Poza rozmową
            // jest jedna pigułka i wyspa pamięta ostatnio używaną kartę.
            if (pillHover.hovered) root.setCard(root.cardDiscord, false);
            else if (root.inVoice && !root.expanded) root.setCard(root.hasPlayer ? root.cardMusic : root.cardClock, false);
            collapseTimer.stop();
            root.hovered = true;
        } else {
            collapseTimer.restart();
        }
    }
    property bool pinned: false
    property bool notice: false   // krótkie auto-rozwinięcie, "powiadomienie"

    // ---- nakładki (Wi-Fi, Bluetooth) ----
    // "" | "wifi" | "bluetooth". Nakładka zastępuje pasek kart i rozciąga
    // wyspę do overlayWidth x overlayHeight. Świadomie NIE jest kartą
    // karuzeli: karta musiałaby zmieścić się w slocie (slotWidth = 440),
    // a podniesienie slotu przestawiłoby geometrię wszystkich kart.
    property string overlayMode: ""
    readonly property bool overlayOpen: overlayMode !== ""

    function openOverlay(mode) {
        root.pinned = false;      // nakładka i tak trzyma wyspę rozwiniętą
        root.overlayMode = mode;
    }

    function closeOverlay() { root.overlayMode = ""; }

    readonly property bool expanded: hovered || pinned || notice || overlayOpen

    // Karta (nazwa, nie indeks), do której wrócić po auto-rozwinięciu;
    // "" = nie wracać (muzyka zostaje na muzyce). Powiadomienie i transfer
    // pokazują swoją kartę tylko na chwilę — użytkownik, który jej nie dotknął,
    // ma dostać z powrotem tę, na której skończył.
    property string keyBeforeNotice: ""

    onNoticeChanged: {
        if (notice || keyBeforeNotice === "") return;
        const card = cardKeys.indexOf(keyBeforeNotice);
        if (!hovered && !pinned && card >= 0) setCard(card, false);
        keyBeforeNotice = "";
    }

    // Kursor na wyspie wstrzymuje wygaszanie powiadomienia, żeby dało się
    // kliknąć akcję.
    Binding {
        target: NotificationService
        property: "held"
        value: root.hovered || root.pinned
    }

    // ---- karty ----
    // Rozwinięta wyspa to karuzela: każda karta ma własny rozmiar docelowy,
    // wyspa animuje się do rozmiaru aktywnej.
    //
    // Karta AirPodsów istnieje tylko przy połączonych słuchawkach, na lewo od
    // muzyki, więc indeksy wszystkich kart przesuwają się wtedy o jeden. Dlatego aktywna
    // karta jest pamiętana po NAZWIE (currentKey), a indeks z niej wyprowadzony —
    // przy indeksie trzymanym wprost połączenie słuchawek przełączyłoby
    // użytkownikowi kartę pod ręką (muzyka -> AirPodsy).
    readonly property var cardKeys: airPodsShown
        ? ["airpods", "music", "discord", "clock", "connectivity", "notifications"]
        : ["music", "discord", "clock", "connectivity", "notifications"]
    readonly property int cardMusic: cardKeys.indexOf("music")
    readonly property int cardAirPods: cardKeys.indexOf("airpods")   // -1 bez słuchawek
    readonly property int cardDiscord: cardKeys.indexOf("discord")
    readonly property int cardClock: cardKeys.indexOf("clock")
    readonly property int cardConnectivity: cardKeys.indexOf("connectivity")
    readonly property int cardNotifications: cardKeys.indexOf("notifications")
    readonly property int cardCount: cardKeys.length

    // Ustawiane w Connections na AirPodsService, nie powiązaniem: przed zmianą
    // układu kart trzeba zgasić animateCardChange, a powiązanie nie daje
    // kontroli nad kolejnością. Bez tego po ostatnim przewinięciu kółkiem
    // pasek kart przejechałby przy połączeniu słuchawek o jeden slot.
    property bool airPodsShown: false
    Component.onCompleted: airPodsShown = AirPodsService.connected

    // Wartość początkowa podąża za odtwarzaczem (muzyka, gdy coś gra, inaczej
    // zegar) dopóki użytkownik pierwszy raz nie przewinie — wtedy powiązanie
    // pęka i wyspa pamięta ostatnio używaną kartę.
    property string currentKey: hasPlayer ? "music" : "clock"
    // Karta, której już nie ma (AirPodsy rozłączone w trakcie) -> pierwsza.
    // Connections niżej i tak przestawia wtedy currentKey na muzykę.
    readonly property int currentCard: Math.max(0, cardKeys.indexOf(currentKey))

    readonly property var cardSizes: ({
        music: [hasPlayer ? 440 : 296, hasPlayer ? 118 : 98],
        airpods: [airpods.implicitWidth, airpods.implicitHeight],
        discord: [440, 118],
        clock: [296, 98],
        connectivity: [connectivity.implicitWidth, connectivity.implicitHeight],
        notifications: [notifications.implicitWidth, notifications.implicitHeight]
    })
    readonly property var cardWidths: cardKeys.map(k => cardSizes[k][0])
    readonly property var cardHeights: cardKeys.map(k => cardSizes[k][1])

    // Slot karuzeli = największa karta. Musi być stały, żeby przesunięcie
    // paska było liniowe w indeksie.
    readonly property int slotWidth: 440

    // Przejazd karuzeli animuje się TYLKO wtedy, gdy kartę zmienia użytkownik
    // kółkiem. Kartę ustawioną przez samą wyspę (powiadomienie, start transferu,
    // zmiana utworu, najechanie na pigułkę rozmowy) chcemy mieć na miejscu od
    // razu: wyspa rozwija się wtedy jednocześnie z przejazdem kart i widać
    // przewijanie, którego nikt nie zamawiał.
    //
    // Flagę ustawiamy PRZED zmianą karty i zostaje ona do następnej zmiany —
    // nie ma czego zerować po animacji, a Behavior sprawdza `enabled` dopiero
    // w chwili, gdy powiązanie stripOffset przeliczy się na nową wartość.
    property bool animateCardChange: false

    function setCard(card, animated) {
        if (card < 0 || card >= root.cardCount) return;
        root.animateCardChange = animated === true;
        root.currentKey = root.cardKeys[card];
    }

    function stepCard(delta) {
        const next = Math.max(0, Math.min(root.cardCount - 1, root.currentCard + delta));
        if (next !== root.currentCard) root.setCard(next, true);
    }

    // Wybór odtwarzacza. Przeglądarki potrafią wystawić dwa wpisy MPRIS dla tej
    // samej karty — np. surowy Brave (tytuł "(12) Coś tam - YouTube", bez
    // okładki) i plasma-browser-integration (czysty tytuł + okładka). Dlatego
    // punktujemy kandydatów zamiast brać pierwszego z brzegu. Przy remisie
    // wygrywa wcześniejszy, więc wybór nie skacze w tę i z powrotem.
    readonly property var player: {
        const all = Mpris.players.values;
        let best = null;
        let bestScore = -1;

        for (let i = 0; i < all.length; i++) {
            const p = all[i];
            const score = (p.isPlaying ? 4 : 0)
                + ((p.trackTitle || "") !== "" ? 2 : 0)
                + ((p.trackArtUrl || "") !== "" ? 1 : 0);

            if (score > bestScore) {
                best = p;
                bestScore = score;
            }
        }

        return best;
    }

    readonly property bool hasPlayer: player !== null
    readonly property bool isPlaying: hasPlayer && player.isPlaying
    // Przeglądarki wkładają w tytuł licznik powiadomień ("(12) Coś tam") —
    // obcinamy go, bo to szum, a nie nazwa utworu.
    readonly property string trackTitle: {
        if (!hasPlayer) return "";
        return (player.trackTitle || "").replace(/^\(\d+\)\s*/, "");
    }
    readonly property string trackArtist: hasPlayer ? (player.trackArtist || "") : ""

    readonly property string artUrl: {
        if (!hasPlayer) return "";
        const u = player.trackArtUrl || "";
        if (u === "") return "";
        return u.startsWith("/") ? "file://" + u : u;
    }

    readonly property real trackLength: (hasPlayer && player.lengthSupported) ? player.length : 0
    readonly property bool hasProgress: hasPlayer && player.positionSupported && trackLength > 0
    readonly property real progress: hasProgress
        ? Math.max(0, Math.min(1, player.position / trackLength))
        : 0

    // Wyspa dopasowuje rozmiar do aktywnej karty.
    readonly property int collapsedWidth: 168
    readonly property int collapsedHeight: 34
    readonly property int expandedWidth: overlayOpen ? overlayWidth : cardWidths[currentCard]
    readonly property int expandedHeight: overlayOpen ? overlayHeight : cardHeights[currentCard]

    // ---- Discord ----
    readonly property bool inVoice: DiscordService.inVoice

    // Teksty karty Discorda poza rozmową. Błąd z mostka jest krótkim kluczem,
    // tu zamieniamy go na coś, co mówi użytkownikowi, co zrobić.
    readonly property string discordTitle: inVoice
        ? DiscordService.channelName
        : (DiscordService.connected ? "Nie jesteś na kanale" : "Discord niepołączony")
    readonly property string discordSubtitle: {
        if (inVoice) return formatTime(DiscordService.elapsedSeconds);
        if (DiscordService.connected) return "Wejdź na kanał głosowy";
        switch (DiscordService.error) {
        case "brak konfiguracji": return "Brak ~/.config/quickshell-island/discord.json";
        case "Discord nie działa": return "Uruchom Discorda";
        case "autoryzacja nieudana": return "Autoryzacja nieudana, sprawdź log";
        case "mostek nie działa": return "Mostek nie działa, sprawdź log";
        default: return "Łączenie…";
        }
    }

    function formatTime(seconds) {
        if (!isFinite(seconds) || seconds < 0) return "0:00";
        const total = Math.floor(seconds);
        const m = Math.floor(total / 60);
        const s = total % 60;
        return m + ":" + (s < 10 ? "0" : "") + s;
    }

    // ---------------------------------------------------------------
    // Czas, zdarzenia
    // ---------------------------------------------------------------

    SystemClock {
        id: clock
        precision: SystemClock.Seconds
    }

    // Krótkie auto-rozwinięcie przy zmianie utworu / play-pauza (jak Dynamic Island)
    Connections {
        target: root.player

        function onPostTrackChanged() { root.showNotice(); }
        function onIsPlayingChanged() { root.showNotice(); }
    }

    // Powiadomienie dotyczy muzyki, więc pokazuje kartę muzyki — nawet jeśli
    // wyspa została zostawiona na innej — i już na niej zostaje.
    function showNotice() {
        if (!root.hasPlayer || root.trackTitle === "") return;
        if (root.overlayOpen) return;
        root.keyBeforeNotice = "";
        root.setCard(root.cardMusic, false);
        root.notice = true;
        noticeTimer.interval = root.noticeDuration;
        noticeTimer.restart();
    }

    // Powiadomienie pulpitu / start transferu: karta powiadomień na chwilę,
    // potem powrót do poprzedniej.
    function showCardNotice(card, duration) {
        // Nakładka ma pierwszeństwo: wyskakująca karta powiadomień w trakcie
        // wpisywania hasła zabrałaby wyspę spod ręki. Wpis i tak zostaje
        // w historii, więc nic nie ginie.
        if (root.overlayOpen) return;
        if (root.currentCard !== card && root.keyBeforeNotice === "")
            root.keyBeforeNotice = root.currentKey;
        root.setCard(card, false);
        root.notice = true;
        noticeTimer.interval = duration;
        noticeTimer.restart();
    }

    Timer {
        id: noticeTimer
        interval: root.noticeDuration
        onTriggered: root.notice = false
    }

    Connections {
        target: NotificationService

        function onNotified(entry) { root.showCardNotice(root.cardNotifications, root.notificationDuration); }
        function onJobStarted(job) { root.showCardNotice(root.cardNotifications, root.jobNoticeDuration); }
    }

    // Parowanie potrafi zacząć URZĄDZENIE (klawiatura, telefon), a nie my.
    // BlueZ pyta wtedy naszego agenta z otwartym wywołaniem D-Bus i własnym
    // limitem czasu — bez tego pytanie nie miałoby się gdzie pokazać i po
    // prostu by wygasło.
    //
    // Tylko przy ZAMKNIĘTEJ nakładce: wyrwanie panelu Wi-Fi w trakcie
    // wpisywania hasła skasowałoby to, co użytkownik już wpisał. Pytanie
    // odrzuci wtedy limit czasu i wystarczy sparować jeszcze raz.
    Connections {
        target: BluetoothService

        function onAskingChanged() {
            if (BluetoothService.asking && !root.overlayOpen) root.openOverlay("bluetooth");
        }
    }

    // AirPodsy: karta wchodzi do karuzeli i wychodzi z niej razem z połączeniem.
    // Przyjście słuchawek pokazuje ją na chwilę (bateria na pierwszy rzut oka),
    // potem wyspa wraca do poprzedniej karty.
    Connections {
        target: AirPodsService

        function onConnectedChanged() {
            root.animateCardChange = false;
            root.airPodsShown = AirPodsService.connected;
            if (!AirPodsService.connected) root.pausedByEar = false;
            if (!AirPodsService.connected && root.currentKey === "airpods")
                root.setCard(root.hasPlayer ? root.cardMusic : root.cardClock, false);
        }

        function onArrived() { root.showCardNotice(root.cardAirPods, root.airPodsNoticeDuration); }

        // Pauza po wyjęciu słuchawki i wznowienie po włożeniu, jak w iOS.
        // Tylko gdy dźwięk idzie przez AirPodsy (routedHere). Wznawiamy
        // wyłącznie to, co sami zapauzowaliśmy, i dopiero gdy w uszach jest
        // znów tyle słuchawek, ile było przed pauzą — wyjęcie drugiej przy
        // już zapauzowanej muzyce niczego nie zmienia.
        function onEarsChanged(previous, current) {
            if (!AirPodsService.autoPause || !AirPodsService.routedHere) return;
            if (current < previous) {
                if (root.isPlaying && root.player.canPause) {
                    root.player.pause();
                    root.pausedByEar = true;
                    root.earsBeforePause = previous;
                }
            } else if (root.pausedByEar && current >= root.earsBeforePause) {
                root.pausedByEar = false;
                if (root.hasPlayer && !root.isPlaying && root.player.canPlay) root.player.play();
            }
        }
    }

    // Klik w nóżkę (1 = play/pauza, 2 = następny, 3 = poprzedni). Gest liczy
    // mostek — AirPodsy wysyłają każde wciśnięcie osobno.
    Connections {
        target: AirPodsService

        function onMediaAction(action) {
            if (!root.hasPlayer) return;
            const p = root.player;
            if (action === "playpause" && p.canTogglePlaying) p.togglePlaying();
            else if (action === "next" && p.canGoNext) p.next();
            else if (action === "previous" && p.canGoPrevious) p.previous();
        }
    }

    Binding {
        target: AirPodsService
        property: "playing"
        value: root.isPlaying
    }

    // Muzyka zapauzowana przez wyjęcie słuchawki — do wznowienia po włożeniu.
    // Gaśnie, gdy użytkownik sam coś zrobi z odtwarzaniem albo słuchawki
    // się rozłączą; inaczej włożenie słuchawek godzinę później puściłoby
    // muzykę, której nikt nie chciał.
    property bool pausedByEar: false
    property int earsBeforePause: 0
    onIsPlayingChanged: if (isPlaying) pausedByEar = false
    onPlayerChanged: pausedByEar = false

    // Drobne opóźnienie zwijania — żeby wyspa nie migała przy krawędzi.
    Timer {
        id: collapseTimer
        interval: root.collapseDelay
        onTriggered: root.hovered = false
    }

    // Koniec rozmowy: karta Discorda traci sens, wracamy do muzyki (lub zegara).
    Connections {
        target: DiscordService

        function onInVoiceChanged() {
            if (!DiscordService.inVoice && root.currentCard === root.cardDiscord)
                root.setCard(root.hasPlayer ? root.cardMusic : root.cardClock, false);
        }
    }

    // Cava kosztuje proces i ~30 przebudzeń na sekundę, więc chodzi tylko
    // wtedy, gdy faktycznie coś gra. Sam serwis dokłada jeszcze karencję,
    // żeby pauza w utworze nie restartowała procesu.
    Binding {
        target: CavaService
        property: "wanted"
        value: root.isPlaying
    }

    // MPRIS nie wysyła pozycji sam z siebie — trzeba go dopytać.
    // Robimy to tylko wtedy, gdy pasek postępu jest w ogóle widoczny.
    Timer {
        running: root.expanded && root.currentCard === root.cardMusic && root.isPlaying && root.hasProgress
        interval: 500
        repeat: true
        onTriggered: root.player.positionChanged()
    }

    // ---------------------------------------------------------------
    // Wyspa
    // ---------------------------------------------------------------

    // Podkładka łapiąca kursor, w rozmiarze DOCELOWYM wyspy — dzięki temu
    // kursor sięgający po skrajny przycisk nie ucieka przed animacją.
    //
    // Leży POD wyspą celowo. Qt dostarcza hover tylko najwyższemu elementowi,
    // który go przyjmuje, więc gdyby leżała na wierzchu (tak było wcześniej),
    // zjadałaby hover przyciskom — klikanie działało, bo goły Item nie
    // przyjmuje klawiszy myszy, ale podświetlanie już nie. Teraz przyciski
    // dostają hover jako pierwsze, a ta podkładka łapie resztę powierzchni.
    Item {
        id: hoverArea

        anchors.top: parent.top
        anchors.topMargin: root.topMargin
        anchors.horizontalCenter: parent.horizontalCenter
        width: root.reachWidth
        height: root.reachHeight

        HoverHandler { id: areaHover }
    }

    // Podkładka hovera pigułki rozmowy. Żyje przez CAŁĄ rozmowę, także gdy
    // wyspa jest rozwinięta i pigułka schowana: prawy koniec pigułki wystaje
    // poza zasięg rozwiniętej wyspy (±220 px), więc gdyby podkładka znikała
    // razem z pigułką, kursor stojący na jej końcu wypadałby poza maskę,
    // wyspa by się zwijała, pigułka wracała pod kursor — i tak w kółko.
    Item {
        id: pillHoverArea

        x: Math.round((root.width + root.collapsedWidth) / 2) + root.pillGap
        y: root.topMargin
        width: root.inVoice ? voicePill.implicitWidth : 0
        height: root.collapsedHeight

        HoverHandler { id: pillHover }
    }

    ClippingRectangle {
        id: island

        anchors.top: parent.top
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.topMargin: root.topMargin

        width: root.expanded ? root.expandedWidth : root.collapsedWidth
        height: root.expanded ? root.expandedHeight : root.collapsedHeight
        radius: root.expanded ? 30 : height / 2

        color: "#0a0a0c"
        border.width: 1
        border.color: Qt.rgba(1, 1, 1, 0.08)
        contentUnderBorder: true

        // Sprężyste, płynne rozciąganie w stylu iOS
        Behavior on width {
            NumberAnimation { duration: 520; easing.type: Easing.OutBack; easing.overshoot: 0.9 }
        }
        Behavior on height {
            NumberAnimation { duration: 520; easing.type: Easing.OutBack; easing.overshoot: 0.9 }
        }
        Behavior on radius {
            NumberAnimation { duration: 400; easing.type: Easing.OutCubic }
        }

        scale: mouseArea.pressed ? 0.97 : 1.0
        Behavior on scale {
            NumberAnimation { duration: 160; easing.type: Easing.OutQuad }
        }

        // Klikanie w wyspę przypina ją rozwiniętą. Hover NIE jest tu obsługiwany —
        // ta MouseArea ma rozmiar animowanej wyspy, więc gubiłaby kursor
        // (patrz hoverArea wyżej). Kółka też nie bierze (brak onWheel), więc
        // zdarzenia lecą do WheelHandlera niżej.
        MouseArea {
            id: mouseArea
            anchors.fill: parent
            // Nakładka i tak trzyma wyspę rozwiniętą, a klik w tło formularza
            // przypinałby ją tylko po to, żeby po zamknięciu została otwarta.
            enabled: !root.overlayOpen
            onClicked: root.pinned = !root.pinned
        }

        // Kółko przewija karty. Siedzi na wyspie, nie na podkładce hovera —
        // podkładka leży pod spodem i zdarzenia by do niej nie doszły.
        WheelHandler {
            id: wheel

            target: null
            // Pod nakładką kółko należy do jej list, nie do karuzeli.
            enabled: root.expanded && !root.overlayOpen
            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
            property real accum: 0

            onWheel: event => {
                if (wheelCooldown.running) return;

                // Kółko w dół (ujemne y) i przesunięcie w prawo (dodatnie x)
                // idą do następnej karty.
                const dy = event.angleDelta.y;
                const dx = event.angleDelta.x;
                accum += dy !== 0 ? -dy : dx;

                if (Math.abs(accum) >= root.wheelStepDelta) {
                    root.stepCard(accum > 0 ? 1 : -1);
                    accum = 0;
                    wheelCooldown.restart();
                }
            }

            onEnabledChanged: accum = 0
        }

        Timer {
            id: wheelCooldown
            interval: root.wheelCooldownMs
            onTriggered: wheel.accum = 0
        }

        // ---- widok zwinięty: sam zegar + kropka statusu ----------------

        RowLayout {
            anchors.centerIn: parent
            spacing: 7

            opacity: root.expanded ? 0 : 1
            visible: opacity > 0.01

            Behavior on opacity {
                NumberAnimation {
                    duration: root.expanded ? 110 : 320
                    easing.type: Easing.OutCubic
                }
            }

            // Miniaturka okładki tego, co gra. Pokazujemy ją dopiero, gdy
            // obrazek naprawdę się wczytał — inaczej w pigułce siedziałby
            // pusty szary kwadracik.
            ClippingRectangle {
                Layout.preferredWidth: 22
                Layout.preferredHeight: 22
                Layout.alignment: Qt.AlignVCenter
                radius: 7
                color: "#17171a"
                visible: miniArt.status === Image.Ready

                Image {
                    id: miniArt
                    anchors.fill: parent
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    cache: true
                    sourceSize.width: 64
                    sourceSize.height: 64
                    source: root.artUrl
                }
            }

            Text {
                text: Qt.formatTime(clock.date, "HH:mm")
                color: "#f2f2f2"
                font.pixelSize: 14
                font.weight: Font.DemiBold
            }

            // Wizualizacja spektrum z cavy w miejscu dawnej kropki statusu.
            Row {
                id: spectrum

                spacing: 2
                height: 16
                Layout.preferredHeight: 16
                Layout.alignment: Qt.AlignVCenter
                visible: root.hasPlayer && CavaService.available

                Repeater {
                    model: CavaService.barCount

                    delegate: Rectangle {
                        required property int index
                        readonly property real level: CavaService.levels[index] ?? 0

                        width: 2
                        radius: 1
                        antialiasing: true
                        color: root.isPlaying ? "#38d47a" : "#4a4a4f"

                        // Minimum 3 px, żeby w ciszy została czytelna kreska,
                        // a nie znikające słupki.
                        height: 3 + level * 13
                        // Row ustawia tylko x, więc pionowe wyśrodkowanie robimy
                        // sami — anchors wewnątrz positionera potrafią się gryźć.
                        y: (spectrum.height - height) / 2

                        Behavior on height {
                            NumberAnimation {
                                duration: root.spectrumSmoothingMs
                                easing.type: Easing.OutQuad
                            }
                        }
                    }
                }
            }

            // Awaryjnie, gdy cavy nie ma albo nie wstała — stara kropka statusu.
            Rectangle {
                width: 6; height: 6; radius: 3
                antialiasing: true
                color: root.isPlaying ? "#38d47a" : "#4a4a4f"
                visible: root.hasPlayer && !CavaService.available
                Layout.alignment: Qt.AlignVCenter

                SequentialAnimation on opacity {
                    running: root.isPlaying && !CavaService.available
                    loops: Animation.Infinite
                    NumberAnimation { from: 1.0; to: 0.35; duration: 700; easing.type: Easing.InOutSine }
                    NumberAnimation { from: 0.35; to: 1.0; duration: 700; easing.type: Easing.InOutSine }
                }
            }

            // Wyłączony mikrofon systemowy. Tylko stan OFF — włączony to norma
            // i stała ikona byłaby szumem, a o wyciszeniu łatwo zapomnieć.
            // Bez micReady: przez pierwsze sekundy micOn jest false, bo
            // PipeWire jeszcze nie wstał, i ikona mignęłaby na starcie.
            IslandIcon {
                Layout.alignment: Qt.AlignVCenter
                kind: "micOff"
                size: 14
                color: "#e5484d"
                visible: AudioService.micReady && !AudioService.micOn
            }
        }

        // ---- widok rozwinięty: pasek kart ------------------------------
        // Każda karta ma zawartość o stałym rozmiarze, wyśrodkowaną w slocie
        // o szerokości największej karty. Wyspa animuje swój rozmiar i przycina —
        // dzięki temu przy animacji nic się nie rozjeżdża, treść po prostu
        // "wyłania się" spod krawędzi, tak jak w iOS. Sąsiednie karty są
        // poza wyspą, bo slot jest szerszy niż każda z nich.

        Item {
            id: cardStrip

            width: root.slotWidth * root.cardCount
            height: parent.height

            property real stripOffset: root.currentCard * root.slotWidth
            Behavior on stripOffset {
                enabled: root.animateCardChange
                NumberAnimation { duration: 420; easing.type: Easing.OutCubic }
            }

            // Środek liczony z ANIMOWANEJ szerokości wyspy — aktywna karta
            // zostaje w środku przez cały czas rozciągania.
            x: (island.width - root.slotWidth) / 2 - stripOffset

            opacity: (root.expanded && !root.overlayOpen) ? 1 : 0
            visible: opacity > 0.01

            Behavior on opacity {
                NumberAnimation {
                    duration: root.expanded ? 380 : 130
                    easing.type: Easing.OutCubic
                }
            }

            // ---- karta: muzyka ----
            Item {
                x: root.cardMusic * root.slotWidth
                width: root.slotWidth
                height: parent.height

                // Z odtwarzaczem: okładka, tytuł, postęp, kontrolki.
                Item {
                    anchors.centerIn: parent
                    width: root.cardWidths[root.cardMusic]
                    height: root.cardHeights[root.cardMusic]
                    visible: root.hasPlayer

                    RowLayout {
                        anchors.fill: parent
                        anchors.margins: 14
                        anchors.bottomMargin: 16
                        spacing: 13

                        ClippingRectangle {
                            Layout.preferredWidth: 72
                            Layout.preferredHeight: 72
                            Layout.alignment: Qt.AlignVCenter
                            radius: 17
                            color: "#17171a"

                            IslandIcon {
                                anchors.centerIn: parent
                                kind: "play"
                                size: 26
                                color: "#4a4a52"
                                visible: art.status !== Image.Ready
                            }

                            Image {
                                id: art
                                anchors.fill: parent
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                                cache: true
                                sourceSize.width: 144
                                sourceSize.height: 144
                                source: root.artUrl
                            }
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            Layout.alignment: Qt.AlignVCenter
                            spacing: 2

                            Text {
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                                text: root.trackTitle !== "" ? root.trackTitle : "Nic nie gra"
                                color: "#f5f5f5"
                                font.pixelSize: 15
                                font.weight: Font.DemiBold
                            }

                            Text {
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                                text: root.trackArtist
                                color: "#9a9aa2"
                                font.pixelSize: 12
                                visible: root.trackArtist !== ""
                            }

                            // Wyjście dźwięku i głośność w jednym: klik w ikonę
                            // wycisza, klik w resztę przełącza wyjście, kółko
                            // zmienia głośność.
                            AudioOutputChip {
                                id: outputChip
                                Layout.topMargin: 4
                                maxWidth: 180
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                Layout.topMargin: 4
                                spacing: 7
                                visible: root.hasProgress

                                Text {
                                    text: root.formatTime(root.hasPlayer ? root.player.position : 0)
                                    color: "#78787f"
                                    font.pixelSize: 10
                                }

                                Rectangle {
                                    Layout.fillWidth: true
                                    Layout.preferredHeight: 3
                                    Layout.alignment: Qt.AlignVCenter
                                    radius: 1.5
                                    antialiasing: true
                                    color: Qt.rgba(1, 1, 1, 0.13)

                                    Rectangle {
                                        width: parent.width * root.progress
                                        height: parent.height
                                        radius: parent.radius
                                        antialiasing: true
                                        color: "#ededf0"

                                        Behavior on width {
                                            NumberAnimation { duration: 450; easing.type: Easing.OutCubic }
                                        }
                                    }
                                }

                                Text {
                                    text: root.formatTime(root.trackLength)
                                    color: "#78787f"
                                    font.pixelSize: 10
                                }
                            }
                        }

                        RowLayout {
                            // 7 zamiast 5, żeby pierścienie hovera sąsiadów się nie stykały
                            spacing: 7
                            Layout.alignment: Qt.AlignVCenter

                            IslandButton {
                                id: btnPrev
                                kind: "prev"
                                enabled: root.hasPlayer && root.player.canGoPrevious
                                onClicked: root.player.previous()
                            }

                            IslandButton {
                                id: btnPlay
                                kind: root.isPlaying ? "pause" : "play"
                                big: true
                                enabled: root.hasPlayer && root.player.canTogglePlaying
                                onClicked: root.player.togglePlaying()
                            }

                            IslandButton {
                                id: btnNext
                                kind: "next"
                                enabled: root.hasPlayer && root.player.canGoNext
                                onClicked: root.player.next()
                            }
                        }
                    }
                }

                // Bez odtwarzacza: krótka informacja zamiast pustej karty.
                Item {
                    anchors.centerIn: parent
                    width: root.cardWidths[root.cardMusic]
                    height: root.cardHeights[root.cardMusic]
                    visible: !root.hasPlayer

                    RowLayout {
                        anchors.centerIn: parent
                        spacing: 12

                        Rectangle {
                            Layout.preferredWidth: 44
                            Layout.preferredHeight: 44
                            radius: 12
                            color: "#17171a"

                            IslandIcon {
                                anchors.centerIn: parent
                                kind: "play"
                                size: 18
                                color: "#4a4a52"
                            }
                        }

                        ColumnLayout {
                            spacing: 2

                            Text {
                                text: "Nic nie gra"
                                color: "#f5f5f5"
                                font.pixelSize: 15
                                font.weight: Font.DemiBold
                            }

                            Text {
                                text: "Włącz coś, a pojawi się tutaj"
                                color: "#9a9aa2"
                                font.pixelSize: 12
                            }

                            AudioOutputChip {
                                id: outputChipIdle
                                Layout.topMargin: 4
                                maxWidth: 200
                            }
                        }
                    }
                }
            }

            // ---- karta AirPodsów (tylko przy połączonych słuchawkach) ----
            Item {
                x: root.cardAirPods * root.slotWidth
                width: root.slotWidth
                height: parent.height
                visible: root.airPodsShown

                AirPodsCard {
                    id: airpods
                    anchors.centerIn: parent
                    width: implicitWidth
                    height: implicitHeight
                }
            }

            // ---- karta: Discord ----
            Item {
                x: root.cardDiscord * root.slotWidth
                width: root.slotWidth
                height: parent.height

                Item {
                    anchors.centerIn: parent
                    width: root.cardWidths[root.cardDiscord]
                    height: root.cardHeights[root.cardDiscord]

                    RowLayout {
                        anchors.fill: parent
                        anchors.margins: 14
                        anchors.bottomMargin: 16
                        spacing: 13

                        ClippingRectangle {
                            Layout.preferredWidth: 72
                            Layout.preferredHeight: 72
                            Layout.alignment: Qt.AlignVCenter
                            radius: 17
                            color: "#17171a"

                            IslandIcon {
                                anchors.centerIn: parent
                                kind: "discord"
                                size: 34
                                color: DiscordService.connected ? "#5865f2" : "#4a4a52"

                                Behavior on color {
                                    ColorAnimation { duration: 300 }
                                }
                            }
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            Layout.alignment: Qt.AlignVCenter
                            spacing: 2

                            Text {
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                                text: root.discordTitle
                                color: "#f5f5f5"
                                font.pixelSize: 15
                                font.weight: Font.DemiBold
                            }

                            Text {
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                                text: root.discordSubtitle
                                color: root.inVoice ? "#38d47a" : "#9a9aa2"
                                font.pixelSize: 12
                                visible: text !== ""
                            }

                            // Mikrofon dla całego systemu (wszystkie źródła
                            // PipeWire), niezależny od wyciszenia w Discordzie.
                            RowLayout {
                                Layout.topMargin: 4
                                spacing: 7

                                IslandSwitch {
                                    id: micSwitch
                                    Layout.alignment: Qt.AlignVCenter
                                    checked: AudioService.micOn
                                    enabled: AudioService.micReady
                                    onToggled: AudioService.setMicOn(!AudioService.micOn)
                                }

                                Text {
                                    Layout.alignment: Qt.AlignVCenter
                                    text: AudioService.micOn ? "Mikrofon systemowy" : "Mikrofon wyłączony"
                                    color: AudioService.micOn ? "#e2e2e6" : "#e5484d"
                                    font.pixelSize: 11
                                    font.weight: Font.DemiBold
                                    opacity: micSwitch.opacity
                                }
                            }
                        }

                        RowLayout {
                            spacing: 7
                            Layout.alignment: Qt.AlignVCenter

                            IslandButton {
                                id: btnMic
                                kind: DiscordService.muted ? "micOff" : "mic"
                                accented: DiscordService.muted
                                enabled: DiscordService.connected
                                onClicked: DiscordService.setMute(!DiscordService.muted)
                            }

                            IslandButton {
                                id: btnDeaf
                                kind: DiscordService.deafened ? "headsetOff" : "headset"
                                accented: DiscordService.deafened
                                enabled: DiscordService.connected
                                onClicked: DiscordService.setDeafen(!DiscordService.deafened)
                            }

                            IslandButton {
                                id: btnLeave
                                kind: "callEnd"
                                big: true
                                accented: true
                                enabled: root.inVoice
                                onClicked: DiscordService.leave()
                            }
                        }
                    }
                }
            }

            // ---- karta: duży zegar + data ----
            Item {
                x: root.cardClock * root.slotWidth
                width: root.slotWidth
                height: parent.height

                ColumnLayout {
                    anchors.centerIn: parent
                    width: root.cardWidths[root.cardClock] - 28
                    spacing: 1

                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        text: Qt.formatTime(clock.date, "HH:mm:ss")
                        color: "#f5f5f5"
                        font.pixelSize: 30
                        font.weight: Font.Light
                    }

                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        text: clock.date.toLocaleDateString(Qt.locale(root.uiLocale), "dddd, d MMMM")
                        color: "#9a9aa2"
                        font.pixelSize: 12
                    }
                }
            }

            // ---- karta: łączność (Wi-Fi, Bluetooth, urządzenia) ----
            Item {
                x: root.cardConnectivity * root.slotWidth
                width: root.slotWidth
                height: parent.height

                ConnectivityCard {
                    id: connectivity
                    anchors.centerIn: parent
                    width: implicitWidth
                    height: implicitHeight

                    onOpenWifi: root.openOverlay("wifi")
                    onOpenBluetooth: root.openOverlay("bluetooth")
                }
            }

            // ---- karta: powiadomienia i transfery ----
            Item {
                x: root.cardNotifications * root.slotWidth
                width: root.slotWidth
                height: parent.height

                NotificationCard {
                    id: notifications
                    anchors.centerIn: parent
                    width: implicitWidth
                    height: implicitHeight
                }
            }
        }

        // ---- kropki: która karta jest aktywna ---------------------------

        Row {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 6
            spacing: 4

            opacity: cardStrip.opacity
            visible: cardStrip.visible

            Repeater {
                model: root.cardCount

                delegate: Rectangle {
                    required property int index
                    readonly property bool active: index === root.currentCard

                    width: active ? 10 : 4
                    height: 4
                    radius: 2
                    antialiasing: true
                    color: active ? "#f2f2f2" : Qt.rgba(1, 1, 1, 0.25)

                    Behavior on width {
                        NumberAnimation { duration: 260; easing.type: Easing.OutCubic }
                    }
                    Behavior on color {
                        ColorAnimation { duration: 200 }
                    }
                }
            }
        }

        // ---- nakładki: Wi-Fi i Bluetooth -------------------------------
        // Zastępują cały pasek kart. Panel powstaje dopiero przy otwarciu —
        // skaner Wi-Fi i skanowanie Bluetootha włączają się w jego
        // Component.onCompleted i mają zgasnąć razem z nim.
        //
        // focus na hoście, nie na Loaderze: Escape ma działać także wtedy,
        // gdy kursor klawiatury siedzi w polu tekstowym. TextInput nie
        // połyka Escape, więc klawisz idzie w górę drzewa i trafia tutaj.
        FocusScope {
            id: overlayHost

            anchors.centerIn: parent
            width: root.overlayWidth
            height: root.overlayHeight

            focus: root.overlayOpen
            opacity: root.overlayOpen ? 1 : 0
            visible: opacity > 0.01
            enabled: root.overlayOpen

            Behavior on opacity {
                NumberAnimation { duration: root.overlayOpen ? 260 : 120; easing.type: Easing.OutCubic }
            }

            Keys.onEscapePressed: event => {
                root.closeOverlay();
                event.accepted = true;
            }

            Loader {
                id: overlay

                anchors.fill: parent
                active: root.overlayOpen
                source: root.overlayMode === "wifi" ? "WifiPanel.qml"
                    : root.overlayMode === "bluetooth" ? "BluetoothPanel.qml"
                    : ""

                onLoaded: item.closed.connect(root.closeOverlay)
            }
        }
    }

    // ---------------------------------------------------------------
    // Pasek postępu transferu — pod wyspą, z małą przerwą
    // ---------------------------------------------------------------

    // Celowo poza wyspą, nie w środku: ma być widoczny także przy zwiniętej
    // pigułce, a nie zabierać jej miejsca. Idzie za animowaną szerokością
    // i wysokością wyspy, więc przy rozwijaniu zjeżdża razem z krawędzią.
    Rectangle {
        id: jobBar

        readonly property bool shown: NotificationService.hasJobs

        anchors.horizontalCenter: parent.horizontalCenter
        y: island.y + island.height + root.jobBarGap
        width: Math.max(40, island.width - 24)
        height: 3
        radius: 1.5
        antialiasing: true
        color: Qt.rgba(1, 1, 1, 0.16)

        opacity: shown ? 1 : 0
        visible: opacity > 0.01
        Behavior on opacity { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }

        Rectangle {
            width: parent.width * NotificationService.jobProgress
            height: parent.height
            radius: parent.radius
            antialiasing: true
            color: "#5b8cff"
            Behavior on width { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
        }
    }

    // ---------------------------------------------------------------
    // Pigułka rozmowy — obok zwiniętej wyspy, tylko podczas rozmowy
    // ---------------------------------------------------------------

    Rectangle {
        id: voicePill

        readonly property bool shown: root.inVoice && !root.expanded

        x: pillHoverArea.x
        y: pillHoverArea.y
        height: root.collapsedHeight
        implicitWidth: Math.min(root.pillMaxWidth, pillRow.implicitWidth + 24)
        width: implicitWidth
        radius: height / 2

        color: "#0a0a0c"
        border.width: 1
        border.color: Qt.rgba(1, 1, 1, 0.08)

        // visible ustawione twardo, nie z opacity: pigułka ma zniknąć w chwili
        // rozwinięcia, żeby nie wystawała spod rosnącej wyspy. Animowane jest
        // tylko pojawianie się.
        visible: shown
        opacity: shown ? 1 : 0
        scale: shown ? 1 : 0.9
        transformOrigin: Item.Left

        Behavior on opacity {
            NumberAnimation { duration: 220; easing.type: Easing.OutCubic }
        }
        Behavior on scale {
            NumberAnimation { duration: 320; easing.type: Easing.OutBack; easing.overshoot: 1.2 }
        }

        RowLayout {
            id: pillRow

            anchors.centerIn: parent
            width: Math.min(implicitWidth, root.pillMaxWidth - 24)
            spacing: 6

            // Pulsująca kropka — trwa rozmowa.
            Rectangle {
                Layout.preferredWidth: 6
                Layout.preferredHeight: 6
                Layout.alignment: Qt.AlignVCenter
                radius: 3
                antialiasing: true
                color: "#38d47a"

                SequentialAnimation on opacity {
                    running: voicePill.shown
                    loops: Animation.Infinite
                    NumberAnimation { from: 1.0; to: 0.35; duration: 700; easing.type: Easing.InOutSine }
                    NumberAnimation { from: 0.35; to: 1.0; duration: 700; easing.type: Easing.InOutSine }
                }
            }

            Text {
                Layout.fillWidth: true
                Layout.maximumWidth: 110
                elide: Text.ElideRight
                text: DiscordService.channelName
                color: "#f2f2f2"
                font.pixelSize: 12
                font.weight: Font.DemiBold
            }

            Text {
                text: root.formatTime(DiscordService.elapsedSeconds)
                color: "#9a9aa2"
                font.pixelSize: 12
            }

            // Deafen ma pierwszeństwo — wyciszone słuchawki oznaczają też mikrofon.
            IslandIcon {
                Layout.alignment: Qt.AlignVCenter
                kind: DiscordService.deafened ? "headsetOff" : "micOff"
                size: 13
                color: "#e5484d"
                visible: DiscordService.muted || DiscordService.deafened
            }
        }
    }

    // ---------------------------------------------------------------
    // Pigułka udostępniania ekranu — po lewej od zwiniętej wyspy
    // ---------------------------------------------------------------

    // Czysto informacyjna: nie ma podkładki hovera ani regionu w masce, więc
    // kursor przechodzi przez nią do okien pod spodem. Nie ma karty, którą
    // mogłaby otwierać — udostępnianie to stan, nie sterowanie.
    Rectangle {
        id: screencastPill

        readonly property bool shown: ScreencastService.active && !root.expanded

        // Lewa strona, lustrzanie do pigułki rozmowy po prawej.
        x: Math.round((root.width - root.collapsedWidth) / 2) - root.pillGap - width
        y: root.topMargin
        height: root.collapsedHeight
        width: Math.min(root.pillMaxWidth, screencastRow.implicitWidth + 24)
        radius: height / 2

        color: "#0a0a0c"
        border.width: 1
        border.color: Qt.rgba(1, 1, 1, 0.08)

        visible: shown
        opacity: shown ? 1 : 0
        scale: shown ? 1 : 0.9
        transformOrigin: Item.Right

        Behavior on opacity {
            NumberAnimation { duration: 220; easing.type: Easing.OutCubic }
        }
        Behavior on scale {
            NumberAnimation { duration: 320; easing.type: Easing.OutBack; easing.overshoot: 1.2 }
        }

        RowLayout {
            id: screencastRow

            anchors.centerIn: parent
            width: Math.min(implicitWidth, root.pillMaxWidth - 24)
            spacing: 6

            // Czerwona pulsująca kropka — jak wskaźnik nagrywania.
            Rectangle {
                Layout.preferredWidth: 6
                Layout.preferredHeight: 6
                Layout.alignment: Qt.AlignVCenter
                radius: 3
                antialiasing: true
                color: "#ff4b4b"

                SequentialAnimation on opacity {
                    running: screencastPill.shown
                    loops: Animation.Infinite
                    NumberAnimation { from: 1.0; to: 0.25; duration: 600; easing.type: Easing.InOutSine }
                    NumberAnimation { from: 0.25; to: 1.0; duration: 600; easing.type: Easing.InOutSine }
                }
            }

            Text {
                Layout.fillWidth: true
                Layout.maximumWidth: 110
                elide: Text.ElideRight
                text: ScreencastService.appName
                color: "#f2f2f2"
                font.pixelSize: 12
                font.weight: Font.DemiBold
            }

            Text {
                text: root.formatTime(ScreencastService.elapsedSeconds)
                color: "#ffb450"
                font.pixelSize: 12
            }
        }
    }
}
