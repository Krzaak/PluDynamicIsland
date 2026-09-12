# PluDynamicIsland

Dynamiczna wyspa w stylu iOS dla [Quickshell](https://quickshell.org) (Wayland, layer-shell).

## Uruchomienie

```sh
qs -p ~/PluDynamicIslandQuickshell
```

Na stałe (wtedy wystarczy samo `qs`):

```sh
mkdir -p ~/.config/quickshell
ln -s ~/PluDynamicIslandQuickshell ~/.config/quickshell/island
qs -c island
```

Logi: `qs -p . --log-times > IslandLogs.log 2>&1`

## Jak to działa

- **W spoczynku** — mała pigułka z miniaturką okładki tego, co gra, zegarem
  i wizualizacją spektrum dźwięku. Miniaturka pojawia się dopiero, gdy okładka
  faktycznie się wczyta — inaczej siedziałby tam pusty kwadracik.
- **Po najechaniu / kliknięciu** — rozwija się w karuzelę pięciu kart
  przewijaną kółkiem myszy: **muzyka** (okładka, tytuł, wykonawca, pasek
  postępu, przyciski, pigułka z wyjściem dźwięku — klik przełącza na następny
  sink PipeWire), **Discord** (kanał, timer, mute / deafen / rozłącz),
  **zegar** (duży zegar + data), **łączność** (przełączniki Wi‑Fi i Bluetooth,
  lista urządzeń Bluetooth z baterią) i **powiadomienia** (świeże powiadomienie
  na całej karcie jak dymek, trwający transfer plików, historia z przyciskiem
  otwarcia aplikacji przy każdym wpisie). Kropki na dole
  pokazują aktywną kartę.
  Kliknięcie przypina wyspę w stanie rozwiniętym (`pinned`).
- **Przy nowym powiadomieniu** — rozwija się sama na ~4,5 s na karcie
  powiadomień, potem wraca na kartę, na której była. Świeże powiadomienie
  zajmuje całą kartę, niższą niż historia (`popupHeight` 118 px zamiast
  `historyHeight` 170 px): ikona, tytuł, do dwóch linii treści, akcje. Znika
  z niej po wygaśnięciu (`popupDuration`, 5 s) albo po kliknięciu — wtedy
  karta pokazuje historię. Najechanie wstrzymuje zwijanie i wygaszanie,
  żeby dało się kliknąć akcję.
- **Przy starcie transferu plików** (kopiowanie w Dolphinie, pobieranie) —
  rozwija się na ~3 s ze szczegółami, a potem przez cały transfer pod wyspą
  wisi cienki pasek postępu, z małą przerwą od krawędzi.
- **Przy zmianie utworu lub play/pauzie** — rozwija się sama na ~3 s na karcie
  muzyki, jak powiadomienie w iOS.
- **Podczas rozmowy na Discordzie** — obok zwiniętej pigułki stoi druga, mała:
  pulsująca kropka, nazwa kanału, timer i ikona wyciszenia. Najechanie na nią
  rozwija wyspę od razu na karcie Discorda.
- **Podczas udostępniania ekranu** — po lewej od zwiniętej pigułki stoi
  informacyjna pigułka z czerwoną pulsującą kropką, nazwą aplikacji, która
  odbiera ekran, i timerem. Nie reaguje na kursor.

### Karty

Wyspa pamięta ostatnio używaną kartę. Dopóki nie przewiniesz ręcznie, karta
startowa podąża za odtwarzaczem: muzyka, gdy coś gra, inaczej zegar. Po
zakończeniu rozmowy karta Discorda oddaje miejsce muzyce (lub zegarowi).

Podczas rozmowy, gdy obok siebie stoją dwie pigułki, każda otwiera swoją kartę:
główna muzykę (zegar, gdy nic nie gra), pigułka rozmowy Discorda. Pamięć
ostatniej karty działa wtedy tylko przy przewijaniu kółkiem.

Timer rozmowy liczy `SystemClock`, nie `Timer` — `Timer` z interwałem 1000 ms
dryfuje i co jakiś czas dwa odczyty wypadały po obu stronach granicy sekundy,
przez co licznik skakał o 2. `SystemClock` tyka równo z sekundą zegara
(zmierzone: stale ~6 ms po pełnej sekundzie).

Każda karta ma własny rozmiar docelowy (`cardWidths` / `cardHeights`), a wyspa
animuje się do rozmiaru aktywnej. Zawartość kart ma stały rozmiar i jest
wyśrodkowana w slocie o szerokości największej karty (`slotWidth`), więc przy
animacji nic się nie przelicza — sąsiednie karty są po prostu poza wyspą.

**Przejazd karuzeli animuje się tylko wtedy, gdy kartę zmieniasz kółkiem.**
Kartę ustawioną przez samą wyspę — powiadomienie, start transferu, zmiana
utworu, najechanie na pigułkę rozmowy, powrót po auto-rozwinięciu — dostajesz
od razu na miejscu: wyspa rozwija się wtedy jednocześnie z przejazdem kart
i widać przewijanie, którego nikt nie zamawiał. Decyduje `animateCardChange`,
ustawiane przez `setCard(karta, animowane)` **przed** zmianą karty; flaga
zostaje do następnej zmiany, bo `Behavior` sprawdza `enabled` dopiero w chwili,
gdy powiązanie `stripOffset` przeliczy się na nową wartość — nie ma czego
zerować po animacji. Zmierzone: automatyczna zmiana to jeden skok `stripOffset`
(0 → 1760, bez klatek pośrednich), ręczna jedzie 440 px w ~420 ms.

Kółko: jeden ząbek (`wheelStepDelta` = 120 jednostek `angleDelta`) to jedna
karta; touchpad sumuje drobne porcje. Po przeskoku kolejne zdarzenia są
ignorowane przez `wheelCooldownMs`, inaczej bezwładność touchpada przeskakiwałaby
dwie karty naraz. Kółko w dół i przesunięcie w prawo idą do następnej karty.

Wyspa nie rezerwuje miejsca na ekranie (`ExclusionMode.Ignore`), a dzięki
masce wejściowej (`mask: Region`) łapie myszkę **wyłącznie na swoim kształcie** —
reszta paska przepuszcza kliknięcia do okien pod spodem.

### Dlaczego maska i hover mają osobny rozmiar (`reachWidth`/`reachHeight`)

Maska wejściowa i obszar reagujący na kursor **nie** idą za animowaną szerokością
wyspy, tylko od razu skaczą do rozmiaru docelowego. Gdyby szły za animacją
(520 ms), kursor jadący do skrajnego przycisku wyprzedziłby rozwijającą się
wyspę, wypadł poza region wejściowy okna, kompozytor wysłałby „pointer leave"
i wyspa zwinęłaby się w trakcie sięgania po przycisk.

Hover siedzi w osobnym `Item` (`hoverArea`) z `HoverHandler`, **pod** wyspą.

Położenie pod spodem jest istotne. Qt dostarcza hover **tylko najwyższemu
elementowi, który go przyjmuje** — i nie zmienia tego `blocking: false` na
`HoverHandler`, wbrew temu, co sugeruje nazwa tej właściwości. Gdy podkładka
leżała na wierzchu, przyciski nie dostawały hovera w ogóle (klikanie działało,
bo goły `Item` nie przyjmuje klawiszy myszy — stąd mylące wrażenie, że wszystko
jest w porządku).

Dlatego stan kursora składa się z **trzech** źródeł:

```qml
readonly property bool pointerInside: areaHover.hovered || controlsHovered || pillHover.hovered
```

Przycisk pod kursorem przejmuje hover na wyłączność i podkładka przestaje go
widzieć — bez zsumowania źródeł wyspa zwijałaby się w chwili najechania
na przycisk. Trzecie źródło to podkładka pigułki rozmowy (`pillHoverArea`),
która żyje przez **całą** rozmowę, także gdy wyspa jest rozwinięta i pigułka
schowana: prawy koniec pigułki wystaje poza zasięg rozwiniętej wyspy, więc gdyby
podkładka znikała razem z pigułką, kursor na jej końcu wypadałby poza maskę,
wyspa by się zwijała, pigułka wracała pod kursor i tak w kółko.

## Pliki

| Plik | Rola |
| --- | --- |
| `shell.qml` | Punkt wejścia; wybór monitora (`islandScreen`). |
| `DynamicIsland.qml` | Samo okno wyspy: stan, animacje, oba widoki. |
| `IslandButton.qml` | Okrągły przycisk sterowania (hover: pierścień + powiększenie). |
| `IslandIcon.qml` | Ikony (play/pause/next/prev, mikrofon, słuchawki, rozłącz, logo Discorda) rysowane wektorowo (`QtQuick.Shapes`). |
| `CavaService.qml` | Singleton: spektrum dźwięku z [cavy](https://github.com/karlstav/cava). |
| `DiscordService.qml` | Singleton: stan rozmowy głosowej i komendy mute/deafen/rozłącz przez mostek. |
| `ScreencastService.qml` | Singleton: wykrywanie udostępniania ekranu z `pw-dump -m` (PipeWire). |
| `ConnectivityCard.qml` | Karta łączności: przełączniki Wi‑Fi / Bluetooth, lista urządzeń Bluetooth. |
| `NotificationService.qml` | Singleton: serwer powiadomień (Quickshell) + mostek transferów KDE, historia. |
| `NotificationCard.qml` | Karta powiadomień: dymek na całej karcie / trwający transfer nad historią. |
| `AudioService.qml` | Singleton: sinki PipeWire i przełączanie domyślnego wyjścia. |
| `AudioOutputChip.qml` | Pigułka z bieżącym wyjściem dźwięku na karcie muzyki. |
| `kde_jobs_bridge.py` | Serwer `org.kde.JobViewServer` w Pythonie — postęp kopiowania i pobierania z KDE. |
| `window_activator.py` | Podnosi okno aplikacji przez D-Bus KWina (przycisk „otwórz" w historii). |
| `IslandSwitch.qml` | Przełącznik w stylu iOS (tor + gałka), zgłasza `toggled`, stanu sam nie zmienia. |
| `discord_bridge.py` | Mostek Python ↔ lokalne RPC Discorda (gniazdo unixowe), JSON linia po linii. |

## Wybór monitora

W `shell.qml`, właściwość `islandScreen` (domyślnie `"DP-1"`).

Quickshell nie zna pojęcia „monitora głównego" — Wayland go nie ma — a kolejność
`Quickshell.screens` **nie** odpowiada priorytetom z KDE (na tej maszynie
`screens[0]` to HDMI-A-1, czyli ten drugi). Dlatego monitor wskazujemy po nazwie.
Nazwy wypisze:

```sh
kscreen-doctor -o
```

Jak podanej nazwy nie ma (monitor odłączony, zmiana nazwy), wyspa spada na ten
w punkcie `(0,0)`, a w ostateczności na pierwszy z listy — nie znika.

## Ustawienia

Na górze `DynamicIsland.qml`:

| Właściwość | Domyślnie | Znaczenie |
| --- | --- | --- |
| `uiLocale` | `"pl_PL"` | Język daty w widoku zegara. |
| `topMargin` | `8` | Odstęp od górnej krawędzi ekranu. |
| `collapseDelay` | `220` | Opóźnienie zwijania po zjechaniu myszką (ms). |
| `noticeDuration` | `3200` | Czas auto-rozwinięcia przy zmianie utworu (ms). |
| `notificationDuration` | `4500` | Czas auto-rozwinięcia przy nowym powiadomieniu (ms). |
| `jobNoticeDuration` | `3000` | Czas auto-rozwinięcia na starcie transferu plików (ms). |
| `jobBarGap` | `4` | Przerwa między wyspą a paskiem postępu pod nią (px). |
| `wheelStepDelta` | `120` | Ile `angleDelta` kółka na jedną kartę (120 = jeden ząbek). |
| `wheelCooldownMs` | `260` | Blokada kolejnego przeskoku po zmianie karty (ms). |
| `pillGap` | `8` | Odstęp pigułek (rozmowa, udostępnianie) od wyspy (px). |
| `pillMaxWidth` | `200` | Maksymalna szerokość pigułek; dłuższe nazwy kanałów / aplikacji są obcinane. |

Rozmiary wyspy: `collapsedWidth/Height` oraz `cardWidths/cardHeights` per karta
(`expandedWidth/Height` wynikają z aktywnej karty). `slotWidth` musi być nie
mniejszy niż największa szerokość karty.

## Discord

Karta Discorda i pigułka rozmowy biorą stan z lokalnego RPC Discorda (to samo
gniazdo, którego używają gry do „Rich Presence"). Działa z natywnym klientem;
ścieżki dla Flatpaka i Snapa też są sprawdzane.

### Konfiguracja (jednorazowo)

1. [discord.com/developers](https://discord.com/developers/applications) →
   *New Application* → skopiuj **Client ID**.
2. Zakładka *OAuth2* → *Redirects* → dodaj `http://localhost` → skopiuj
   **Client Secret**.
3. Zapisz `~/.config/quickshell-island/discord.json` (uprawnienia `0600`):

   ```json
   {"client_id": "...", "client_secret": "..."}
   ```

4. Przy pierwszym połączeniu Discord pokaże **okno zgody** — kliknij
   *Authorize*. Token ląduje w `~/.config/quickshell-island/discord_token`
   i jest używany przy kolejnych startach. Gdy wygaśnie, mostek kasuje go
   i prosi o zgodę jeszcze raz.

Plik z sekretami leży celowo poza katalogiem projektu, żeby nie wyciekł przy
kopiowaniu repozytorium. Bez niego karta pokazuje „Brak konfiguracji", reszta
wyspy działa normalnie.

### Dlaczego mostek w Pythonie

Discord rozmawia ramkami binarnymi `[op u32le][len u32le][json]`, a
`Quickshell.Io.Socket` pisze i czyta wyłącznie tekst (`write(QString)` +
`SplitParser`) — bajty nagłówka ≥ 0x80 i NUL przeszłyby przez UTF‑8 i się
rozjechały. `discord_bridge.py` tłumaczy ramki na JSON linia po linii przez
stdin/stdout, a `DiscordService.qml` trzyma go jako `Process`, tak samo jak
cavę.

Rzeczy, na które trzeba uważać:

- Mostek **nigdy nie kończy się sam** po rozłączeniu z Discordem — czeka i łączy
  się ponownie co 5 s. Jedyny celowy koniec to kod `3` (brak pliku konfiguracji),
  po którym serwis go nie restartuje.
- Endpoint `POST /oauth2/token/rpc` (`rpc_token`, omijający okno zgody) zwraca
  dziś `404` — Discord go wycofał. Kod nadal próbuje, ale realnie liczy się
  ścieżka z oknem zgody.
- Cloudflare przed API Discorda odrzuca domyślny User-Agent `urllib`
  kodem `403` (error 1010). Mostek wysyła własny.
- Discord unieważnia `code` z `AUTHORIZE`, gdy wymiana na token się ociąga, więc
  żądanie HTTP idzie od razu po odebraniu ramki, zanim mostek wróci do `select`.
- Stan początkowy mute/deafen bierze się z `GET_VOICE_SETTINGS` zaraz po
  uwierzytelnieniu — bez tego przyciski pokazywałyby „niewyciszony" aż do
  pierwszej zmiany.

Ręczny test mostka (bez wyspy):

```sh
python3 discord_bridge.py                          # wypisuje stan i logi JSON-em
echo '{"cmd":"mute","value":true}' | python3 discord_bridge.py
```

## Udostępnianie ekranu

Na Waylandzie każde przechwytywanie ekranu (Discord, OBS, przeglądarka) to
strumień wideo z kompozytora do aplikacji przez PipeWire. `ScreencastService`
szuka węzła `Stream/Input/Video` w stanie `running`, którego odbiorcą nie jest
pulpit (`ignoredApps`, domyślnie `plasmashell` — konsumuje `kwin_wayland` na
potrzeby miniatur okien i istnieje zawsze, w stanie `suspended`).

Zamiast odpytywać `pw-dump` co kilka sekund, serwis trzyma `pw-dump -m`
(tryb monitora): pierwszy zrzut to wszystkie obiekty, potem przychodzi tablica
z każdą zmianą. Aktualizacja węzła zawiera pełny stan i właściwości (nie deltę),
a usunięty obiekt to `{"id": N, "info": null}`. Tablice są wieloliniowe —
granicą jest samotny `]` na początku linii, wszystko w środku jest wcięte.

Jeśli udostępnianie nie jest wykrywane, sprawdź w trakcie sharowania, jak
nazywa się odbiorca i w jakim jest stanie:

```sh
pw-dump | grep -B2 -A30 '"Stream/Input/Video"' | grep -E 'application.name|node.name|"state"'
```

Timer udostępniania, jak timer rozmowy, liczy `SystemClock`, nie `Timer`.

## Powiadomienia i transfery plików

To dwa **różne** mechanizmy i wyspa obsługuje oba, ale każdy inaczej.

### Powiadomienia (org.freedesktop.Notifications)

Wyspa jest **demonem powiadomień zamiast Plasmy** — wbudowany
`NotificationServer` Quickshella. Dzięki temu działają przyciski akcji
i kliknięcie w powiadomienie (akcja domyślna), a aplikacje dostają poprawne
`NotificationClosed`.

Haczyk: Quickshell **nie potrafi wyrwać nazwy** zajętej przez Plasmę, a po
nieudanej próbie nie ponawia. Dlatego trzeba raz wyłączyć aplet powiadomień
Plasmy:

1. Prawy przycisk na zasobniku systemowym → *Konfiguruj zasobnik systemowy…*
   → *Wpisy* → **Powiadomienia** → *Wyłączone*.
2. Sprawdź, że nazwa jest wolna: `busctl --user list | grep Notifications`
   nie powinno nic wypisać.
3. Wyspa sama to zauważy (pyta co `ownerCheckMs`, domyślnie 5 s) i zarejestruje
   serwer — nagłówek karty zmieni się z „Powiadomienia (Plasma trzyma serwer)"
   na „Powiadomienia".

Co z tym tracisz: historię i ustawienia powiadomień w Plasmie („Nie przeszkadzać",
reguły per aplikacja). Historia jest w wyspie (`historyLimit`, domyślnie 30,
tylko w pamięci — znika z restartem).

Treść z markupem (`<b>`, `<a>`, `<img>`) jest sprowadzana do gołego tekstu —
w wyspie nie ma na to miejsca. Ikona: obraz z powiadomienia → `appIcon`
(nazwa z motywu lub ścieżka) → ikona z pliku `.desktop` → dzwonek.

### Otwieranie powiadomienia (jak w Plasmie)

Wiersz historii po najechaniu pokazuje przy prawej krawędzi dwa przyciski:
**otwarcie** wpisu i **zdjęcie** go z historii (czerwony ×, ten sam akcent co
przyciski rozłączania). Świeże powiadomienie otwiera kliknięcie w całą kartę.
Otwarcie — z wiersza czy z dymka — robi zawsze to samo: **akcja domyślna
powiadomienia, potem podniesienie okna**, i zdejmuje wpis, bo sprawa jest
załatwiona. Kliknięcie w resztę wiersza, jak dotąd, tylko go zdejmuje.

Oba sloty przycisków są zarezerwowane zawsze, także w wierszu, którego nie ma
czym otworzyć — inaczej czas i nazwa aplikacji skakałyby w bok przy każdym
najechaniu. Slot łapie hover również wtedy, gdy przycisk jest wygaszony, więc
wjazd kursorem od prawej krawędzi wyłania go pod palcem. Wszystkie trzy okrągłe
przyciski karty (oba w wierszu plus czyszczenie całej historii w nagłówku) to
jeden komponent `CardButton` — różnią się średnicą i kolorem podświetlenia.

W powiadomieniu **nie ma żadnego adresu ani „miejsca"**, do którego można by
skoczyć — `org.freedesktop.Notifications` niesie tylko listę akcji, a wśród nich
umownie nazwaną `default`. To ją wywołuje kliknięcie w dymek Plasmy i to ona
sprawia, że Discord otwiera się na tej rozmowie, a klient poczty na tym mailu.
Wyspa robi więc dokładnie to samo: `invoke()` na akcji `default`, a zaraz po niej
podniesienie okna, bo samo `invoke()` nie daje aplikacji fokusu na Wayland.

**Dlatego powiadomienia nie są tu wygaszane.** `popupDuration` (5 s) odmierza
tylko czas, po którym dymek schodzi z karty — samo powiadomienie zostaje otwarte
tak długo, jak wpis jest w historii. Wcześniej wyspa wołała `expire()`, aplikacja
dostawała `NotificationClosed`, a wraz z nim **znikały akcje**: wpis w historii
dało się już tylko otworzyć na „stronie głównej" aplikacji, nigdy na właściwej
rozmowie. Zamknięcie przychodzi teraz dopiero, gdy wpis zostanie zdjęty, wyleci
poza `historyLimit` albo zamknie go sama aplikacja. (Po wywołaniu akcji Quickshell
zamyka powiadomienie sam — zmierzone: klient dostaje `ActionInvoked`, a po nim
`NotificationClosed` z powodem `2`.)

Wpisy mają własne `id`, nadawane wyłącznie w `pushHistory`, i po nim rozpoznaje
je `removeEntry`. Nie da się inaczej: delegat `ListView` dostaje **kopię** wpisu,
bo model jest tablicą JS i przechodzi przez `QVariant` (zmierzone:
`modelData === history[0]` to `false`). Porównanie tożsamości nie trafiało nigdy,
więc kliknięcie nie kasowało nic — a objaw mylił, bo QObject-y w kopii
(`notification`, `action`) przeżywają konwersję jako wskaźniki i otwieranie wpisu
działało normalnie.

Wpis, którego aplikacja już nie ma otwartego (albo transfer plików), akcji nie ma —
wtedy przycisk robi samo okno: podnosi je lub, gdy go nie ma, uruchamia aplikację.

**Najpierw okno, dopiero potem uruchomienie.** `DesktopEntry.execute()` na
działającej aplikacji nie daje nic widocznego — Discord był otwarty, a klik
nie przełączał na niego — aplikacji bez pilnowania pojedynczej instancji
otworzyłby zaś drugie okno. Dlatego wyspa próbuje najpierw podnieść istniejące
okno przez `window_activator.py`, a `execute()` zostaje fallbackiem na wypadek,
gdy okna nie ma (kod wyjścia `1`), KWin nie odpowiada (`2`) albo kompozytor jest
inny. Kliknięcia stoją w kolejce — jeden proces aktywatora na raz.

Dlaczego osobny skrypt, a nie QML: KWin **nie wystawia**
`wlr-foreign-toplevel-management`, więc `ToplevelManager` Quickshella widzi
zero okien (zmierzone sondą), a plasma-window-management to protokół Waylanda,
do którego QML nie ma dostępu. Zostaje D-Bus KWina i trzy wywołania:

| Obiekt | Metoda | Po co |
| --- | --- | --- |
| `/WindowsRunner` | `org.kde.krunner1.Match(fraza)` | okna pasujące do frazy (runner KRunnera) |
| `/KWin` | `org.kde.KWin.getWindowInfo(uuid)` | `resourceClass`, `resourceName`, `desktopFile` okna |
| `/WindowsRunner` | `org.kde.krunner1.Run(matchId, "")` | aktywacja okna |

`Match` dopasowuje **także po tytule okna**, więc samo jego trafienie niczego
nie dowodzi: przy frazie „discord" wygrałaby karta przeglądarki z Discordem
w tytule. Dlatego każdy kandydat przechodzi przez `getWindowInfo` i liczy się
wyłącznie plik `.desktop` okna albo jego klasa. Id dopasowania ma postać
`<numer>_{uuid}`, a `getWindowInfo` chce samego `{uuid}`.

Fraz do `Match` jest kilka, bo id wpisu `.desktop` nierzadko nie jest tym, co
KWin zna jako klasę okna: Spotify ma id `spotify-launcher`, klasę `Spotify`
i `resourceName` `spotify`. Kolejność: id → `StartupWMClass` → nazwa aplikacji
→ ostatni człon id (`org.kde.dolphin` → `dolphin`).

Ręczny test bez wyspy: `python3 window_activator.py discord discord Discord`
(kod `0` = podniesione, `1` = nie ma okna, `2` = nie ma KWina).

Aplikację rozpoznaje `NotificationService.appIdFor()`: podpowiedź `desktop-entry`
z powiadomienia (pewna) → `DesktopEntries.heuristicLookup()` po nazwie aplikacji
(zgadywanie). Gdy nic nie pasuje — a tak bywa np. przy Brave — slot przycisku
zostaje pusty. Slot jest zarezerwowany **zawsze**, żeby pojawienie się przycisku
nie przesuwało czasu i nazwy aplikacji w wierszu.

Dwie rzeczy zmierzone sondą, obie potrafią zmylić:

- `DesktopEntries` skanuje pliki `.desktop` **asynchronicznie i dopiero przy
  pierwszym dotknięciu**: pierwszy odczyt zwraca 0 wpisów i zarazem rozpala
  skan, a komplet (tu 147) jest półtorej sekundy później. Dlatego id aplikacji
  jest liczone przy wyświetlaniu wiersza, a nie przy zapisie do historii
  (inaczej powiadomienie z pierwszych sekund życia wyspy zapamiętałoby pustkę
  na zawsze), a powiązanie w wierszu przechodzi przez `NotificationService.appCount`
  — to ono jest zależnością, po której wiersz przelicza się, gdy lista dojedzie.
  Samo wołanie funkcji w powiązaniu nigdy by się nie odświeżyło.
- Skan startuje teraz razem z wyspą, więc w logu pojawiają się dwa
  `WARN quickshell.desktopentry: Encountered invalid line in desktop entry (no =) "\t"`.
  To **nie jest** regresja wyspy: samotny tabulator mają w sobie
  `valve-steamvr.desktop` i `valve-vrmonitor.desktop` ze Steama. Kontrolny
  `grep -acE "WARN|ERROR|error:"` daje przez to `2`, nie `0`.

### Transfery plików (org.kde.JobViewServer)

Kopiowanie w Dolphinie, pobieranie przez integrację przeglądarki i inne
zadania KIO **nie są powiadomieniami**. Aplikacja woła
`org.kde.JobViewServer.requestView`, dostaje obiekt i przez
`org.kde.JobViewV3.update({percent, speed, processedBytes, …})` raportuje
postęp (stare aplikacje używają `JobViewV2` z osobnymi metodami `setPercent`,
`setSpeed`…). Ten serwer też normalnie trzyma aplet Plasmy.

Quickshell nie umie wystawiać własnych obiektów D-Bus, więc serwer to
`kde_jobs_bridge.py` (python-dbus). Prosi o nazwy `org.kde.JobViewServer`
i `org.kde.kuiserver` **z kolejkowaniem** — dopóki trzyma je Plasma, czeka,
a przejmuje je automatycznie w chwili, gdy aplet zostanie wyłączony.
Wyspa dostaje pełne migawki zadania JSON-em linia po linii (jak mostek Discorda).

Pułapki, które kosztowały:

- python-dbus szuka metody po **nazwie atrybutu klasy** i dopiero potem
  sprawdza interfejs. `terminate` (V2 i V3) oraz `requestView` (V1 i V2) mają
  te same nazwy w różnych interfejsach, więc stara wersja siedzi w klasie
  bazowej, nowa w pochodnej — wyszukiwanie idzie po MRO. Sygnały nazwę biorą
  z `__name__` w chwili dekoracji, więc te podmienia się przed dekoracją.
- `kioclient copy` **nie rejestruje zadania** w JobViewServerze (nie używa
  KUiServerJobTracker), więc nie nadaje się do testów. Realny test to Dolphin.
  Bez Dolphina protokół sprawdza fałszywy klient na prywatnej magistrali
  (`dbus-run-session`), tak samo cały serwer powiadomień z `notify-send`.
- Klient, który zniknie z magistrali bez `terminate`, zostawiłby zadanie na
  zawsze — mostek nasłuchuje `NameOwnerChanged` i sam je kończy.

Ręczny test mostka: uruchom `python3 kde_jobs_bridge.py` na prywatnej
magistrali (`dbus-run-session`) i wołaj `requestView` z drugiego procesu.

## Łączność (Wi‑Fi, Bluetooth)

Czwarta karta. Dane idą z wbudowanych modułów Quickshella: `Quickshell.Networking`
(NetworkManager) i `Quickshell.Bluetooth` (BlueZ) — bez podprocesów, poza
`rfkill` do przełączania Bluetootha.

- **Wi‑Fi**: przełącznik oraz nazwa aktualnej sieci z siłą sygnału. Łączenie
  z sieciami zostaje w KDE. Przy wyłączonym sprzętowo Wi‑Fi przełącznik jest
  nieaktywny.
- **Bluetooth**: przełącznik i lista urządzeń — sparowane oraz znalezione przy
  skanowaniu (ikona lupy w nagłówku listy, skan kończy się sam po
  `scanDurationMs`). Kliknięcie w sparowane urządzenie łączy lub rozłącza,
  w niesparowane — paruje (potwierdzenie PIN-u pokazuje agent KDE). Urządzenie,
  które zgłasza baterię, dostaje ikonę z poziomem i procentami.
- Kółko nad listą przewija listę, gdy jest co przewijać; gdy lista mieści się
  w całości, kółko przełącza karty jak zwykle. Żeby przełączyć kartę przy długiej
  liście, zjedź kursorem na lewą część karty.

Ustawienia na górze `ConnectivityCard.qml`:

| Właściwość | Domyślnie | Znaczenie |
| --- | --- | --- |
| `rowHeight` | `28` | Wysokość wiersza listy urządzeń (px). |
| `leftColumnWidth` | `168` | Szerokość kolumny z przełącznikami (px). |
| `scanDurationMs` | `15000` | Po tylu ms skanowanie samo się kończy. |

Dlaczego przełącznik Bluetootha idzie przez `rfkill`: wyłączony Bluetooth w KDE
to blokada rfkill, a zablokowany adapter ignoruje `enabled = true` (BlueZ zwraca
`Error.Blocked`). Włączanie robi `rfkill unblock bluetooth` (bez roota), po czym
BlueZ z `AutoEnable` sam podnosi adapter; wyłączanie ustawia `enabled = false`
i blokuje rfkill, żeby aplet KDE pokazywał to samo, co wyspa.

Zmierzone: moduły Quickshella ładują dane asynchronicznie — adapter pojawia się
1–6 s po starcie, a tuż po pojawieniu zgłasza przejściowo stan `Enabling`
(karta pokazuje wtedy „Przełączanie…" i blokuje przełącznik na ułamek sekundy).

## Wizualizacja dźwięku (cava)

Słupki w zwiniętej pigułce to spektrum z **cavy** — Quickshell nie ma własnego
FFT, więc dane idą z podprocesu.

Wymaga pakietu `cava`. Bez niego (albo gdy proces nie wstanie) wyspa po dwóch
nieudanych próbach wraca do zwykłej zielonej kropki statusu — nic się nie psuje.

Szczegóły, na które trzeba uważać przy konfiguracji cavy w trybie `raw`:

- `channels = mono` w `[output]` — przy stereo cava **wymaga parzystej liczby
  słupków** i inaczej odmawia startu.
- Cava potrafi wypluć na stdout sekwencję tytułu terminala, więc każda klatka
  jest walidowana i skażone są pomijane.
- Polecenie kończy się na `exec cava`, żeby podmienić powłokę na cavę —
  bez tego Quickshell ubijałby `sh`, a cava zostawałaby sierotą.
- **Nie da się rozpoznać własnego zatrzymania po kodzie wyjścia.** Quickshell
  ubija proces SIGTERM-em, co daje `exitCode 15` / `CrashExit` — nie do
  odróżnienia od cavy, która padła sama. Dlatego serwis trzyma jawną flagę
  intencji (`stopCava()`), a nie zgaduje z kodu. Bez tego każda pauza dłuższa
  niż karencja liczyła się jako awaria i po dwóch takich wizualizacja
  wyłączała się na dobre.

Proces chodzi **tylko gdy coś faktycznie gra** (`CavaService.wanted`), z 5 s
karencji, żeby pauza w utworze nie kosztowała restartu i ponownej nauki
`autosens`.

### Żwawość słupków

Wygładzanie siedzi w **dwóch** miejscach — parser nie rusza danych w żaden
sposób poza skalowaniem `n / 100`:

| Pokrętło | Gdzie | Domyślnie | Efekt |
| --- | --- | --- | --- |
| `noiseReduction` | `CavaService.qml` | `35` | Filtry integral + gravity w cavie, 0–100. Cava sama domyślnie daje 77, co wygląda zaspanie. |
| `framerate` | `CavaService.qml` | `60` | Filtr cavy liczy się per klatka, więc wyższy framerate **sam w sobie** przyspiesza reakcję. |
| `spectrumSmoothingMs` | `DynamicIsland.qml` | `28` | Animacja wysokości słupka. Musi być krótsza niż odstęp klatek (~17 ms przy 60 fps), inaczej słupek nigdy nie dobiega do celu. |

Zmierzone na muzyce (punkty zmiany na sekundę, zakres 0–100):

| fps | `noiseReduction` | zmienność/s |
| --- | --- | --- |
| 30 | 77 (domyślne cavy) | 66 |
| 60 | 50 | 171 |
| **60** | **35** | **~190** ← ustawione |
| 60 | 15 | 252 |

Poniżej ~15 skok między klatkami przekracza 4 punkty i pięć 2-pikselowych
słupków zaczyna migotać.

## Uwaga o MPRIS

Przeglądarki wystawiają czasem **dwa** wpisy MPRIS dla jednej karty (np. surowy
Brave i `plasma-browser-integration`). Wyspa punktuje kandydatów —
gra (4) + ma tytuł (2) + ma okładkę (1) — i bierze najlepszego, więc trafia na ten
z czystym tytułem i okładką.

## Do zrobienia

- Cień pod wyspą (`MultiEffect` wymaga paddingu warstwy — pominięte, żeby nie
  ryzykować renderu).
- Podpięcie powiadomień (`Quickshell.Services.Notifications`) pod ten sam
  mechanizm `notice`.
- Głośność / wskaźnik baterii w widoku zwiniętym.
- Discord: uczestnicy kanału z avatarami i wskaźnikiem mówienia
  (`SPEAKING_START/STOP`), auto-rozwinięcie przy wejściu/wyjściu osób —
  świadomie pominięte, wyspa ma nie otwierać się sama od Discorda.
