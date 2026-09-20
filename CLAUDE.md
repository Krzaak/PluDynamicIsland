# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Czym to jest

Dynamiczna wyspa w stylu iOS dla **Quickshell** (Wayland, layer-shell). Czysty QML —
brak kroku budowania, brak testów, brak zależności poza tymi z systemu.

Cel: pływająca pigułka na górze ekranu, która w spoczynku pokazuje zegar, okładkę
i spektrum dźwięku, a po najechaniu rozwija się w karuzelę kart (AirPodsy | muzyka |
Discord | zegar | łączność | powiadomienia) przewijaną kółkiem. Karta łączności
otwiera nakładki Wi-Fi i Bluetootha, które zastępują karuzelę i rozciągają wyspę
do 620 × 360 px. Podczas rozmowy na Discordzie obok zwiniętej pigułki
stoi druga, mała, z nazwą kanału i timerem.

Środowisko docelowe: Quickshell 0.3.1, Qt 6.11, Wayland. Działa na **Hyprlandzie**
(tu: 0.56.2) i na KDE/KWin — różnice są wypunktowane niżej, w "Dwa kompozytory".

## Polecenia

```sh
qs -p .                                        # uruchomienie z katalogu projektu
qs -p . --no-color --log-times > IslandLogs.log 2>&1   # z logiem do pliku
timeout 8 qs -p . --no-color > IslandLogs.log 2>&1     # przebieg kontrolny
grep -acE "WARN|ERROR|error:" IslandLogs.log   # 2 = czysto (patrz niżej)
hyprctl monitors                               # nazwy monitorów (Hyprland)
kscreen-doctor -o                              # nazwy monitorów (KDE)
hyprctl globalshortcuts                        # czy skrót wyspy się zarejestrował
```

Kod wyjścia `124` z `timeout` oznacza sukces — proces dożył do końca limitu.

Dwa `WARN quickshell.desktopentry: … invalid line … "\t"` w każdym przebiegu to
nie regresja: samotny tabulator mają `valve-steamvr.desktop` i `valve-vrmonitor.desktop`
ze Steama, a wyspa skanuje wpisy `.desktop` od startu (`NotificationService.appCount`).

### Weryfikacja zmian

**`qmllint` jest tu bezużyteczny.** Nie rozwiązuje typów Quickshella i cicho
przepuszcza nawet zmyśloną właściwość na `PanelWindow`. Jedyna realna walidacja to
uruchomienie i sprawdzenie logu — QML zgłasza błędy powiązań, pętle i problemy
układu dopiero w czasie działania.

Wzorzec sondowania: tymczasowy plik `_probe_*.qml` w katalogu projektu, który
instancjonuje badany komponent i wypisuje wartości przez `console.log`, uruchamiany
przez `timeout N qs -p ./_probe_x.qml`, kasowany po pomiarze. Id-ki QML są widoczne
tylko w obrębie swojego pliku — żeby zmierzyć coś w środku komponentu, trzeba
wstrzyknąć log do niego samego, nie do sondy.

**Działająca instancja użytkownika przeładowuje pliki z tego katalogu na żywo.**
Sonda wstrzyknięta do pliku projektu wykona się także w jego instancji — a jeśli
sonda przełącza Bluetooth, skanuje albo klika, zrobi to naprawdę, na jego pulpicie,
i pomyli pomiar (dwie instancje widzą nawzajem swoje skutki). Sondy, które zmieniają
stan systemu, uruchamiaj z **kopii** projektu w katalogu roboczym sesji, nie z tego
katalogu. Sondy czysto odczytowe mogą zostać w projekcie, ale i tak kasuj je od razu.

**Wyglądu nie oceniaj na ślepo.** `grim`, `slurp` ani `wayshot` nie są tu
zainstalowane, ale Qt potrafi zrobić zrzut samo: `item.grabToImage(r =>
r.saveToFile("/tmp/x.png"), Qt.size(w, h))` w sondzie zapisuje PNG, który da się
obejrzeć. To jedyny sposób, żeby zobaczyć układ, zanim zobaczy go użytkownik.
Uwaga: zrzut zrobiony w tym samym tiku co zmiana stanu łapie animacje `Behavior`
**przed** startem (podświetlenie wygląda wtedy na nieistniejące) — daj timerowi
kilkaset ms.

Czego **nie da się** tu sprawdzić: ruchu kursora. Brak `ydotool`/`dotool`, użytkownik
nie jest w grupie `input`, a Wayland z założenia nie pozwala klientom przesuwać
wskaźnika. Hover, najechanie i klikanie musi potwierdzić użytkownik — geometrię
policz i zmierz, ale nie twierdź, że interakcja działa.

Uwaga przy liczeniu procesów: `pgrep -f 'cava -p'` łapie też własną linię poleceń
powłoki. Używaj `pgrep -xc cava`. Przy sprawdzaniu sierot pamiętaj, że użytkownik
zwykle ma **własną** działającą instancję wyspy — sprawdź rodzica przez
`ps -o ppid=`, zanim uznasz proces za wyciek. To samo dotyczy `discord_bridge.py`.

Każde uruchomienie wyspy (także `timeout 8 qs`) bez zapisanego tokena wysyła do
Discorda nowe `AUTHORIZE`, a ten pokazuje użytkownikowi kolejne okno zgody. Przy
serii przebiegów kontrolnych to normalne, ale warto uprzedzić.

## Architektura

`shell.qml` (`ShellRoot`) → `Variants` po przefiltrowanych ekranach →
jedna instancja `DynamicIsland` (`PanelWindow`). Singletony w katalogu konfiguracji
Quickshell rejestrują się same — **nie dodawaj `qmldir`**, zepsuje to niejawny
import pozostałych komponentów.

### Dwa kompozytory

Wyspa chodzi na Hyprlandzie i na KWinie. Miejsca, w których to widać:

- **Monitor.** `islandScreen` w `shell.qml`; puste = automat (ekran w punkcie
  `(0,0)`, potem pierwszy z listy). Nie wpisuj tu nazwy na stałe — to psuje
  projekt na drugiej maszynie.
- **Skrót globalny.** `hyprland-global-shortcuts-v1` ma tylko Hyprland, więc
  `GlobalShortcut` siedzi w osobnym pliku (`HyprlandShortcut.qml`) ładowanym
  `Loaderem` po `Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE")`. Import
  `Quickshell.Hyprland` w pliku ładowanym zawsze dawałby ostrzeżenie na KDE.
  Na KDE zostaje IPC (`qs -p . ipc call island toggle`).
- **Podnoszenie okien.** Hyprland wystawia `wlr-foreign-toplevel-management`
  i `ToplevelManager` widzi tam okna z `appId` (zmierzone: `kitty`, `zen`) —
  robi to więc QML (`NotificationService.raiseToplevel`). KWin tego protokołu
  nie ma i lista jest pusta, więc tam wchodzi `window_activator.py`. Dopasowanie
  w OBU ścieżkach idzie tylko po `appId`/klasie, nigdy po tytule.
- **Agent BlueZ.** Na KDE trzyma go bluedevil, na Hyprlandzie **nie ma go
  wcale** — bez własnego agenta `pair()` pada od razu. Patrz BluetoothService.
- **Demon powiadomień.** Brama na `NameHasOwner` działa tak samo; na Hyprlandzie
  nazwa `org.freedesktop.Notifications` jest zwykle wolna od startu.

### Trzy niezależne geometrie

To jest najważniejszy pomysł w tym kodzie i źródło większości dotychczasowych błędów.
Wyspa ma **trzy** rozmiary, które celowo nie są tym samym:

1. **Wizualny** — `island.width/height`, animowany sprężyście (~520 ms `OutBack`).
2. **Zasięg** — `reachWidth/reachHeight` = `max(animowany, docelowy)`. Skacze do
   rozmiaru docelowego natychmiast. Używany przez maskę wejściową okna
   (`mask: Region`) i przez podkładkę hovera.
3. **Zawartość** — treść rozwinięta ma stały rozmiar i jest wyśrodkowana, a wyspa
   ją przycina. Dzięki temu układ nie przelicza się w trakcie animacji.

Rozmiar docelowy zależy od aktywnej karty (`cardWidths[currentCard]`). Karty leżą
w pasku `cardStrip`, każda w slocie o stałej szerokości `slotWidth` (= największa
karta), z zawartością wyśrodkowaną w slocie. Pasek ma `x` liczony z **animowanej**
szerokości wyspy, więc aktywna karta zostaje w środku przez cały czas rozciągania,
a sąsiednie są poza wyspą. Przewijanie to animacja `stripOffset`, nie `x` — `x`
musi pozostać powiązaniem. Animuje się **tylko zmiana karty kółkiem**: kartę
ustawioną przez wyspę (powiadomienie, transfer, zmiana utworu, pigułka rozmowy)
widać od razu na miejscu, inaczej przejazd kart nakłada się na rozwijanie.
Każda zmiana idzie przez `setCard(karta, animowane)`, które ustawia
`animateCardChange` przed przypisaniem.

Aktywna karta jest pamiętana po **nazwie** (`currentKey`), a `currentCard` to
indeks wyprowadzony z `cardKeys` — karta AirPodsów wchodzi do karuzeli (na
lewo od muzyki, indeks 0) tylko przy połączonych słuchawkach i przesuwa indeksy
wszystkich kart. `cardDiscord` itd. to `cardKeys.indexOf(...)`, nie stałe. Nowa karta =
wpis w `cardKeys` + `cardSizes`. `airPodsShown` przestawia `Connections`, nie
powiązanie: `animateCardChange` musi zgasnąć **przed** zmianą układu, inaczej
pasek przejechałby o slot przy połączeniu słuchawek.

Zasięg **musi** wyprzedzać animację. Kursor jest szybszy niż 520 ms sprężyny: gdyby
maska szła za animacją, kursor sięgający po skrajny prawy przycisk (+191 px od środka,
przy pigułce sięgającej ±84 px) wypadłby poza region wejściowy okna, kompozytor
wysłałby „pointer leave" i wyspa zwinęłaby się pod ręką.

### Hover składa się z trzech źródeł

Qt dostarcza hover **tylko najwyższemu elementowi, który go przyjmuje**.
`HoverHandler.blocking: false` tego **nie** zmienia, wbrew nazwie właściwości.

Dlatego `hoverArea` (podkładka w rozmiarze zasięgu) leży **pod** wyspą, a stan kursora
to suma trzech źródeł:

```qml
readonly property bool pointerInside: areaHover.hovered || controlsHovered || pillHover.hovered
```

Przycisk pod kursorem przejmuje hover na wyłączność i podkładka przestaje go widzieć.
Bez sumowania wyspa zwijałaby się w chwili najechania na przycisk. **Każdy nowy
`IslandButton` musi trafić do `controlsHovered`.**

Trzecie źródło to `pillHoverArea` — podkładka pigułki rozmowy. Żyje przez **całą**
rozmowę (szerokość 0 poza nią), także gdy wyspa jest rozwinięta i pigułka schowana.
Prawy koniec pigułki wystaje poza zasięg rozwiniętej wyspy (±220 px); gdyby podkładka
znikała z pigułką, kursor na jej końcu wypadałby poza maskę → zwinięcie → pigułka
wraca pod kursor → rozwinięcie, w kółko. Maska okna bierze tę podkładkę przez
`Region { item: pillHoverArea }` — `Region.item` nie ma `enabled`, stąd sterowanie
szerokością.

Kółko obsługuje `WheelHandler` na samej wyspie, **nie** na `hoverArea` — podkładka
leży pod spodem i zdarzenia by do niej nie doszły. `MouseArea` bez `onWheel` przepuszcza.
`ListView` (łączność, powiadomienia) przyjmuje kółko tylko wtedy, gdy może się
w tę stronę przesunąć — na granicy (lista u góry + kółko w górę) `Flickable`
zdarzenie **odrzuca** i poleciałoby do wyspy jako zmiana karty. Dlatego kontener
każdej listy ma własny `WheelHandler` (`target: null`), włączony tylko gdy lista
ma co przewijać: dostaje zdarzenie po liście i je połyka. Gdy lista mieści się
w całości, kółko przełącza karty jak wszędzie indziej.

Wysokość okna (`implicitHeight`) jest wyprowadzona z najwyższej karty plus zapas
na przestrzelenie sprężyny i pasek transferu — nie wpisuj jej na sztywno, bo
wyższa karta wygląda wtedy na uciętą od dołu.

Karta w osobnym pliku (`ConnectivityCard.qml`) wystawia jedno `hovering`, które
wyspa dolicza do `controlsHovered`. Wiersze listy liczą hover **licznikiem**
(`hoveredRows`), nie OR-em po delegatach — delegaty powstają i giną, więc stałe
powiązanie nie miałoby do czego się przypiąć; delegat niszczony w trakcie hovera
musi licznik zmniejszyć (`Component.onDestruction`), inaczej wyspa nigdy się nie zwinie.

Objaw pomyłki w tym miejscu jest mylący: **kliknięcia działają, hover nie** — goły
`Item` nie przyjmuje klawiszy myszy, więc naciśnięcia przelatują niżej, a hover nie.

### Nakładki (Wi-Fi, Bluetooth) i klawiatura

`overlayMode` (`""` | `"wifi"` | `"bluetooth"`) przełącza wyspę w tryb nakładki:
pasek kart gaśnie, a `expandedWidth/Height` idą na `overlayWidth × overlayHeight`
(620 × 360). Panel żyje w `Loaderze`, więc powstaje dopiero przy otwarciu.

**Nakładka NIE jest kartą karuzeli i nie może nią zostać.** Karta musi zmieścić
się w slocie (`slotWidth` = 440), a podniesienie slotu przeliczyłoby geometrię
wszystkich pozostałych kart. Dlatego `overlayHeight` wchodzi do `maxCardHeight`
(wysokość okna ma być stała), ale `slotWidth` zostaje nietknięty.

Rzeczy, które trzeba wyłączyć na czas nakładki, bo inaczej gryzą się z formularzem:
`WheelHandler` wyspy (kółko należy wtedy do list panelu), `MouseArea` przypinająca
wyspę, przestawianie karty w `onPointerInsideChanged` oraz `showNotice` /
`showCardNotice` — wyskakująca karta powiadomień w trakcie wpisywania hasła
zabrałaby wyspę spod ręki.

**Klawiatura.** `WlrLayershell.keyboardFocus`: `Exclusive` przy otwartej nakładce,
`None` poza nią. `OnDemand` **nie wystarcza** — daje klawiaturę dopiero po
kliknięciu w powierzchnię, a pole formularza bierze kursor samo (`fPsk.take()`)
i wtedy nie dostałoby ani znaku. Ukrycie wyspy (`hiddenByUser`) musi zamykać
nakładkę: schowane okno z `Exclusive` zjadałoby wszystkie klawisze.

`Escape` obsługuje `FocusScope` (`overlayHost`), nie Loader — `TextInput` nie
połyka `Escape`, więc klawisz idzie w górę drzewa i trafia tam nawet wtedy, gdy
kursor klawiatury siedzi w polu.

**Pole tekstowe jest źródłem prawdy dla swojej zawartości.** `text: panel.cośTam`
plus `onTextChanged: panel.cośTam = text` wygląda niewinnie, ale `TextInput`
zmienia swój tekst sam i pierwszy wpisany znak **zrywa powiązanie** — od tej
chwili wyzerowanie właściwości nie czyści już pola. Formularze czytają więc
`fPsk.text` wprost, a `resetFields()` przypisuje do pól. Listy wyboru i checkboxy
mogą trzymać stan na zewnątrz, bo (jak `IslandSwitch`) swojego nie ruszają —
`IslandDropdown` celowo **nie** ustawia sobie `value`, tylko zgłasza `picked`.

**Rozwinięta lista wyboru musi wyjść poza formularz.** `z: 100` nie wystarcza
z dwóch niezależnych powodów (oba zmierzone na formularzu 802.1X): `z` działa
tylko między rodzeństwem, więc pola deklarowane po liście i tak rysowały się na
niej, a przewijany formularz ma `clip: true`, którego `z` nie omija — lista
wychodziła przycięta i przezroczysta. Dlatego `IslandDropdown` przyjmuje
`menuParent` (warstwa `menuLayer` na końcu `WifiPanel.qml`, poza `Flickable`),
a pozycję liczy `mapToItem` w chwili otwarcia, z odbiciem do góry, gdy pod
spodem brakuje miejsca. `mapToItem` **nie jest powiązaniem**, więc przewinięcie
formularza zamyka listę (`onContentYChanged`) zamiast zostawiać ją w powietrzu.

Przyciski akcji siedzą **poza** `Flickable` formularza, przypięte do dołu:
formularz 802.1X ma osiem pól i jest wyższy niż nakładka (~548 px przy 360 px
miejsca), więc w środku przewijanego obszaru „Połącz" wypadałby pod krawędź.

### BluetoothService (adapter + agent parowania)

Singleton nad `bt_agent_bridge.py`, ale trzyma też adapter, `rfkill` i mapowanie
ikon BlueZ — karta łączności i nakładka mają pokazywać dokładnie to samo, a
wcześniej obie miały własną kopię tej logiki.

- **Bez agenta parowanie nie działa.** Quickshell daje `device.pair()`, ale nie
  daje agenta; BlueZ nie ma wtedy kogo zapytać o PIN i zwraca od razu
  `AuthenticationCanceled`. Zdolność `KeyboardDisplay` (najszersza) — węższa
  kazałaby BlueZ-owi parować „just works" i cicho obniżała bezpieczeństwo.
- Metody agenta są **asynchroniczne** (`async_callbacks`): wywołanie D-Bus
  zostaje otwarte, a odpowiedź idzie dopiero po kliknięciu w wyspie. Inaczej
  metoda musiałaby zwrócić wartość od razu, czyli zgadywać za użytkownika.
- Rejestracja żyje w procesie `bluetoothd` — po jego restarcie (`Release()`,
  `NameOwnerChanged`) trzeba zarejestrować się **od nowa**, inaczej parowanie
  cicho przestaje działać aż do restartu wyspy.
- `display-pin` / `display-passkey` mają `id: 0` i **nie czekają na odpowiedź** —
  kod przepisuje się na urządzeniu.
- Zamknięcie panelu w trakcie pytania musi być **odmową** (`dismiss()`), nie
  zniknięciem: inaczej po stronie BlueZ wisi otwarte wywołanie do jego timeoutu.
- Pytanie potrafi przyjść, gdy parowanie zaczyna urządzenie — wyspa otwiera
  wtedy nakładkę sama, ale tylko gdy żadna nie jest otwarta (wyrwanie panelu
  Wi-Fi skasowałoby wpisywane hasło).
- **Testu nie da się zrobić na magistrali systemowej**: polityka przepuszcza
  wywołania `Agent1` tylko od `bluetoothd` (dostajesz „Access denied"). Agenta
  sprawdza się na `dbus-run-session`, na KOPII skryptu z `SystemBus` podmienioną
  na `SessionBus` — pamiętaj wtedy zaślepić `device_info`, bo `GetAll` na
  nieistniejącym `org.bluez` blokuje pętlę agenta aż do timeoutu.

### Kolejność i nazwy urządzeń Bluetooth

`BluetoothService.sortedDevices` to jedyna lista, z której korzystają karta
i nakładka: **połączone na górze**, potem sparowane, potem reszta, w grupach
alfabetycznie (sortowanie po samym sygnale przestawiałoby wiersze pod kursorem).
`pairedDevices` to jej podzbiór dla karty.

**Bezimiennym urządzeniom BlueZ wstawia w nazwę ich własny adres, ale
z MYŚLNIKAMI** (`07-2A-34-13-BE-04`), podczas gdy `device.address` ma
dwukropki. Dlatego pierwotne `name !== address` **nigdy nie trafiało** —
objawiało się listą pełną surowych adresów. Zmierzone przy skanowaniu:
24 urządzenia z BlueZ, z czego tylko 6 miało prawdziwą nazwę; resztę
odsiewa `hasRealName()`, który normalizuje separatory i zna jeszcze jeden
zastępnik, dosłowne `LE_UNKNOWN`.

Filtrowanie siedzi w **modelu**, nie w delegacie: delegat o zerowej wysokości
dalej liczy się do `count`, więc podpowiedź „Szukam urządzeń…" nie pokazałaby
się przy liście złożonej z samych zastępników.

### NetworkService (Wi-Fi) i nm_connect.py

`Quickshell.Networking` umie mało: `connectWithPsk(psk)` dla sieci **widocznej**,
i tyle. `connectWithSettings()` chce `NMSettings`, którego **nie da się utworzyć
z QML** — typ nie jest eksportowany (sprawdzone w `qmltypes`). Sieć ukryta,
802.1X i „łącz automatycznie" muszą więc iść po D-Bus do NetworkManagera.

- Podział: sieć **znana** → `network.connect()` (nie zakłada drugiego profilu
  obok istniejącego), sieć **nowa** → `nm_connect.py` z pełnym formularzem.
- **Sekrety idą stdin-em, nie w argv.** `/proc/<pid>/cmdline` czyta każdy proces
  tego samego użytkownika — `nmcli ... password X` wystawiłby hasło. Pomocnik
  czyta JSON do EOF, więc po `write()` trzeba ustawić `stdinEnabled = false`,
  a po wyjściu procesu przywrócić na `true` (Process jest jeden na wszystkie
  próby i zamknięte stdin zostałoby zamknięte na zawsze).
- `ssid` musi być **tablicą bajtów** (`dbus.ByteArray`), nie stringiem — sieci
  nie zawsze są poprawnym UTF-8, a NM odrzuci zły typ.
- `ok: true` z pomocnika znaczy tylko, że NM **przyjął** zlecenie. Czy hasło było
  dobre, widać dopiero po stanie sieci (`connectionFailed`, `connected`).
- `pendingNetwork` jest **wyprowadzone** z `busySsid`, nie przypisywane: przy
  sieci ukrytej obiekt sieci jeszcze nie istnieje w chwili zlecenia i ręczne
  przypisanie zostawiłoby `null` na zawsze — czyli żadnego „złe hasło", tylko
  timeout.
- `scannerEnabled` włączamy **tylko przy otwartym panelu** — ciągłe skanowanie
  przerywa transmisję na karcie. Zmierzone: bez skanera widać 1 sieć (połączoną),
  ze skanerem 15.

### Wybór odtwarzacza MPRIS

Przeglądarki wystawiają **dwa** wpisy MPRIS dla jednej karty (surowy Brave i
`plasma-browser-integration`), z czego jeden bywa pusty. Kandydaci są punktowani:
gra (4) + ma tytuł (2) + ma okładkę (1), remis wygrywa wcześniejszy. Nie zmieniaj
tego na „pierwszy z listy" ani „pierwszy grający".

### CavaService

Singleton nad podprocesem `cava` w trybie `raw` (Quickshell nie ma własnego FFT).
Cztery rzeczy, które trzeba tu wiedzieć, bo każda kiedyś zepsuła wizualizację:

- `channels = mono` w `[output]` — przy stereo cava wymaga parzystej liczby słupków.
- Polecenie kończy się na `exec cava`, żeby podmienić powłokę. Bez tego Quickshell
  ubija `sh`, a cava zostaje sierotą.
- Cava potrafi wypluć na stdout sekwencję tytułu terminala, więc parser waliduje
  każdą ramkę i pomija skażone.
- **Własnego zatrzymania nie da się poznać po kodzie wyjścia.** SIGTERM od
  Quickshella daje `exitCode 15` / `CrashExit`, nie do odróżnienia od awarii. Serwis
  trzyma jawną flagę intencji (`stopCava()`).

Proces chodzi tylko gdy coś gra, z 5 s karencji. Po dwóch prawdziwych awariach
`available` idzie na `false` i wyspa wraca do zwykłej kropki statusu.

### DiscordService

Singleton nad `discord_bridge.py` (Python), bo `Quickshell.Io.Socket` pisze i czyta
tylko tekst, a Discord RPC to ramki binarne `[op u32le][len u32le][json]`. Mostek
rozmawia z QML JSON-em linia po linii: na stdout pełne migawki stanu (`type:"state"`)
i logi, na stdin komendy `mute` / `deafen` / `leave`.

- Sekrety w `~/.config/quickshell-island/discord.json`, token obok. Celowo poza
  projektem. Nie echować sekretu ani tokena do logu / rozmowy.
- Mostek **nie kończy się** po rozłączeniu z Discordem — sam czeka i łączy ponownie.
  Kod wyjścia `3` = brak konfiguracji, serwis wtedy nie restartuje. Inne kody →
  licznik awarii jak w cavie, z tą samą pułapką `exitCode 15` od SIGTERM.
- `POST /oauth2/token/rpc` (`rpc_token`) zwraca `404` — Discord go wycofał. Realna
  ścieżka to okno zgody w Discordzie przy pierwszym uruchomieniu.
- Cloudflare odrzuca domyślny UA `urllib` (`403`, error 1010) — mostek ustawia własny.
- Stan początkowy mute/deafen z `GET_VOICE_SETTINGS` po uwierzytelnieniu.
- Test mostka bez wyspy: `python3 discord_bridge.py` (stdin EOF kończy go czysto).
  Discord musi działać, żeby cokolwiek zobaczyć — sprawdź `ls $XDG_RUNTIME_DIR/discord-ipc-*`.

### AirPodsService

Singleton nad `airpods_bridge.py` — protokół Apple AAP po L2CAP (PSM `0x1001`,
`SOCK_SEQPACKET`), którego Quickshell nie otworzy. Mostek chodzi stale, pilnuje
BlueZ przez D-Bus (UUID usługi AAP w `UUIDs` urządzenia) i sam otwiera/zamyka
kanał. Na stdout pełne migawki `type:"state"` tylko przy zmianie, na stdin
`{"cmd":"mode","value":"off|anc|transparency|adaptive"}`.

- Pakiet ucha podaje słuchawkę główną/drugą, nie L/P. Mapowanie: pierwsza
  słuchawka w pakiecie baterii = główna. Surowe bajty ucha są przeliczane przy
  każdej baterii, bo główna może się zamienić.
- Bateria `255` i status `04` = brak odczytu; trzymamy ostatni z `live: false`.
- `arrived()` nie strzela dla połączenia zastanego przy starcie
  (`startupGraceMs`) — instancja przeładowuje się na żywo i każda edycja
  rozwijałaby wyspę.
- Pauza po wyjęciu: serwis emituje `earsChanged(przed, po)` tylko przy
  prawdziwym przejściu (pierwszy odczyt ucha po połączeniu się nie liczy),
  a pauzuje/wznawia wyspa, bo to ona wybiera odtwarzacz. Warunek
  `routedHere` = nazwa domyślnego sinka zawiera adres słuchawek z `_`.
  Ustawienie `autoPause` w `airpods.json` (FileView + JsonAdapter; brak pliku
  → zapis domyślnych).
- Klik w nóżkę: słuchawki wysyłają każde wciśnięcie jako osobne AVRCP
  play/pauza (gestu nie liczą same). Mostek rejestruje w BlueZ odtwarzacz
  (`Media1.RegisterPlayer`) tylko na czas sesji AAP — wtedy AVRCP omija
  uinput i KDE — liczy wciśnięcia (`STEM_GAP_MS`) i wysyła
  `{"type":"media","action":...}`; wykonuje wyspa (`onMediaAction`), stan
  odtwarzania wraca do mostka przez `AirPodsService.playing`.
- Test zmiany trybu **przełącza słuchawki na uszach użytkownika** — uprzedź go
  i przywróć tryb po pomiarze.

### ScreencastService

Singleton nad `pw-dump -m` (tryb monitora PipeWire). Udostępnianie ekranu = węzeł
`Stream/Input/Video` w stanie `running`, którego odbiorca nie jest na `ignoredApps`
(`plasmashell` konsumuje `kwin_wayland` na miniatury okien i istnieje stale jako
`suspended` — bez filtra stanu i nazwy byłby fałszywy alarm).

- Aktualizacja węzła z `pw-dump -m` to pełny obiekt (stan + props), nie delta.
  Usunięcie to `{"id": N, "info": null}`. Tablice wieloliniowe, granica = samotny `]`.
- Pigułka udostępniania jest **czysto informacyjna**: bez podkładki hovera i bez
  regionu w masce. Nie ma karty, którą mogłaby otwierać.
- Nie da się tu zasymulować udostępniania bez portalu: `gst-plugin-pipewire` nie
  jest zainstalowany, `ffmpeg` nie ma wejścia pipewire. Logikę sprawdza się sondą
  wołającą `ScreencastService.applyUpdate([...])` z syntetycznymi węzłami; realny
  test robi użytkownik (serwis loguje `[screencast] start udostępniania: <app>`).

### NotificationService (powiadomienia + transfery plików)

Dwa mechanizmy, oba w tym singletonie:

- **Powiadomienia**: wbudowany `NotificationServer` Quickshella, wyspa jest demonem
  **zamiast Plasmy**. Quickshell nie umie wyrwać nazwy `org.freedesktop.Notifications`
  zajętej przez Plasmę i po nieudanej próbie nie ponawia — dlatego serwer siedzi
  w `Loader` i jest ładowany dopiero, gdy `dbus-send NameHasOwner` powie, że nazwa
  jest wolna (użytkownik musi wyłączyć aplet powiadomień w zasobniku Plasmy).
- **Transfery** (`org.kde.JobViewServer`, Dolphin/pobieranie): `kde_jobs_bridge.py`
  (python-dbus), bo Quickshell nie wystawia własnych obiektów D-Bus. Nazwy bierze
  z kolejkowaniem — przejmuje je sam, gdy Plasma zwolni. Protokół: V1/V2 `requestView`,
  `JobViewV2` (metody `setX`) i `JobViewV3` (`update(a{sv})`, `terminate(u,s,a{sv})`).

Pułapki:

- python-dbus szuka metody po **nazwie atrybutu klasy**, potem po interfejsie —
  `terminate`/`requestView` w dwóch wersjach muszą być w klasie bazowej i pochodnej
  (wyszukiwanie po MRO). Sygnały: nazwa z `__name__` w chwili dekoracji.
- `kioclient copy` **nie rejestruje** zadań w JobViewServerze — do testów jest
  bezużyteczny. Protokół sprawdza się fałszywym klientem na `dbus-run-session`;
  tam też testuje się serwer powiadomień z `notify-send`, bez ruszania Plasmy.
- Test end-to-end wyspy na prywatnej magistrali **i tak pokazuje okno na ekranie
  użytkownika** (Wayland jest wspólny) — nakłada się na jego wyspę i użytkownik
  potrafi w nie kliknąć w trakcie pomiaru. Uprzedź go albo licz się z tym w odczycie.
- Ikony z motywu (`image://icon/...`) ładowane przez `Image { asynchronous: true }`
  dają „Cannot create children for a parent that is in a different thread" — dostawca
  nie jest wątkowo bezpieczny. Karta ładuje je synchronicznie.
- `Notification.image` dla podpowiedzi `image-path` ze ścieżką to
  `image://icon//usr/…/x.png` — dostawca `image://icon` nie ładuje plików.
  `resolveIcon` odwija to do `file://`. Nazwa z motywu (`image://icon/dialog-information`)
  ładuje się normalnie.
- **Nie wygaszaj powiadomień** (`expire()`), dopóki wpis jest w historii.
  Zamknięcie zabiera powiadomieniu akcje, a akcja `default` to jedyne, co
  przenosi aplikację do właściwej rozmowy — bez niej klik otwiera aplikację
  „od zera". `popupDuration` odmierza tylko zejście dymka z karty. Zamykamy
  przy zdjęciu wpisu, wypadnięciu poza `historyLimit` i przy czyszczeniu
  historii; po `invoke()` Quickshell zamyka powiadomienie sam.
- Przycisk „otwórz aplikację" w historii **najpierw podnosi okno**, a `execute()`
  jest dopiero fallbackiem. `DesktopEntry.execute()` na działającej aplikacji nie
  robi nic widocznego (Discord otwarty → klik nie dawał fokusu), a aplikacji bez
  pojedynczej instancji otworzyłby drugie okno. Okna nie da się ruszyć z QML:
  KWin nie wystawia `wlr-foreign-toplevel-management` (`ToplevelManager` widzi
  zero okien), więc robi to `window_activator.py` przez D-Bus KWina —
  `/WindowsRunner` `Match`/`Run` plus `/KWin` `getWindowInfo` do weryfikacji.
  `Match` trafia też w **tytuł** okna, więc bez tej weryfikacji klik w powiadomienie
  Discorda podniósłby kartę przeglądarki z „Discord" w tytule.
- `DesktopEntries` skanuje **asynchronicznie i dopiero przy pierwszym dotknięciu**:
  pierwszy odczyt zwraca 0 wpisów i zarazem rozpala skan, komplet jest ~1,5 s
  później. Dlatego aplikacja źródłowa wpisu historii (przycisk otwierania)
  rozwiązuje się przy wyświetlaniu wiersza, a nie przy zapisie, a powiązanie
  idzie przez `NotificationService.appCount` — samo wołanie funkcji nie jest
  zależnością i nigdy by się nie przeliczyło.
- **Wpis podany przez delegat `ListView` to KOPIA**, nie ten sam obiekt: model
  jest tablicą JS, przechodzi przez `QVariant` i delegat dostaje odtworzony
  obiekt (`modelData === history[0]` daje `false` — zmierzone). Dlatego wpisy
  mają `id` nadawane w jednym miejscu (`pushHistory`) i `removeEntry` szuka po
  nim; porównanie tożsamości nie trafiało nigdy i kliknięcie po prostu nic nie
  kasowało. Objaw myli, bo QObject-y w kopii (`notification`, `action`)
  przeżywają konwersję jako wskaźniki — **otwieranie wpisu działa, usuwanie nie**.
- `action.invoke()` zamyka powiadomienie → lista akcji pustoszeje → **delegat
  Repeatera ginie w trakcie własnego onClicked**, a `card` przestaje istnieć.
  Najpierw zdejmij wpis, potem `invoke()`, a wszystko, czego potrzebujesz, złap
  do zmiennych przed wywołaniem.
- Pasek postępu transferu wisi **pod** wyspą (`jobBar`), poza jej kształtem, z
  `jobBarGap` przerwy; celowo bez regionu w masce. Powiadomienie i start transferu
  robią `showCardNotice`, które pamięta `cardBeforeNotice` i wraca do niej po
  zwinięciu — muzyka (`showNotice`) celowo nie wraca.

### AudioService (wyjście dźwięku)

Singleton nad `Quickshell.Services.Pipewire`. Sinki = węzły
`type === PwNodeType.AudioSink` bez `isStream` (strumienie aplikacji mają też bit
Sink). Przełączanie przez `Pipewire.preferredDefaultAudioSink`, WirePlumber
zapamiętuje wybór. Jak Networking, ładuje się **asynchronicznie**: `ready` idzie
na `true` dopiero po kilku sekundach, wcześniej lista jest pusta, a
`defaultAudioSink` to `null`. `nickname`/`description` są dostępne bez
bindowania węzła (`PwObjectTracker`), `audio` (głośność) już nie. Pigułka
`AudioOutputChip` na karcie muzyki jest w dwóch wariantach karty (z odtwarzaczem
i bez), oba wliczone do `controlsHovered`.

Głośność (`audio.volume`, `audio.muted`) wymaga związania węzła
`PwObjectTracker`-em tak samo jak mikrofon — bez tego `audio` jest `null`.
Wiązane jest **tylko bieżące wyjście**, nie wszystkie sinki. Skala to 0–1
liniowo, ta sama co w `wpctl get-volume` (zmierzone: 0,75 po obu stronach) —
nie procenty i nie krzywa sześcienna.

Sterowanie siedzi w `AudioOutputChip`, a nie w osobnym suwaku. Pierwsza wersja
miała własny wiersz i podniosła kartę muzyki ze 118 na 140 px — za dużo.
Zmierzone: kolumna tytułu ma 202 px, a sama pigułka 119, więc na suwak obok
zostawało ~75 px (za ciasno); pigułka z wypełnieniem mieści się w 151 px
i nie kosztuje wysokości. Klik w lewe 22 px wycisza, klik w resztę przełącza
wyjście (MouseArea ikony jest deklarowana PÓŹNIEJ, więc leży na tej większej).
Kółko zmienia głośność i jest **połykane**, żeby nie przeleciało do wyspy jako
zmiana karty.

Obrót kółka trzeba **sumować** do pełnego ząbka (`volumeWheelDelta` = 120),
dokładnie jak przy przewijaniu kart. Pierwsza wersja stosowała cały krok na
KAŻDE zdarzenie i na touchpadzie (tu: `syna2393`) jedno machnięcie palcem —
12 zdarzeń po ~10 jednostek — dawało **+60% zamiast +3%** (zmierzone). Wynik
`stepVolume` jest zaokrąglany do pełnego procentu, inaczej kółko zostawia
wartości w rodzaju 0,4733 i ten sam ruch dwa razy daje inny wynik.

Pigułka to `ClippingRectangle`, nie `Rectangle`: `clip: true` na `Rectangle`
z `radius` przycina PROSTOKĄTNIE i wypełnienie wystawałoby poza zaokrąglone rogi.

`AudioService.volumeNudged()` zgłasza zmianę głośności **spoza wyspy**, a wyspa
zamienia po nim na chwilę treść zwiniętej pigułki na pasek (`volumeNotice`).
Dwie pułapki:

- **Pierwszy odczyt nie jest zmianą.** Po starcie głośność skacze z zera na
  rzeczywistą, a po przełączeniu wyjścia — na głośność innego urządzenia.
  Stąd `knownVolume = -1` jako "brak punktu odniesienia": najbliższy odczyt
  tylko go ustawia. Bez tego wyspa mrugałaby paskiem przy każdym starcie
  i przy każdej zmianie sinka.
- **Pasek nie pokazuje się przy rozwiniętej wyspie** — widać wtedy pigułkę
  wyjścia z tą samą informacją. `onExpandedChanged` gasi też pasek w trakcie,
  inaczej wracałby po zjechaniu kursorem, na resztę czasu.

Pigułka zostaje przy `collapsedWidth × collapsedHeight` (zmierzone: 168 × 34
przed, w trakcie i po) — zmiana rozmiaru zrobiłaby z zerknięcia skaczące okno.

Mikrofon systemowy (przełącznik `micSwitch` na karcie Discorda) wycisza **wszystkie**
źródła `AudioSource`, nie tylko domyślne — aplikacja może słuchać innego wejścia
(tu kamera jest domyślna, a wbudowane ALC1220 też żyje). `micOn` = którekolwiek
nie jest wyciszone, więc OFF gwarantuje ciszę. `muted` wymaga związania węzłów
(`PwObjectTracker` na `sources`).

### Karta łączności (Wi-Fi, Bluetooth)

Karta jest **podglądem i szybkim przełącznikiem**; wszystko, co wymaga wpisywania
(hasło do nowej sieci, PIN przy parowaniu), dzieje się w nakładkach, które karta
otwiera sygnałami `openWifi` / `openBluetooth`. Lista na karcie pokazuje tylko
urządzenia **sparowane** — nowe, znalezione przy skanowaniu, są w nakładce razem
z przyciskiem parowania. Adapter, `rfkill` i mapowanie ikon są w `BluetoothService`,
a nie w karcie: wcześniej karta i nakładka miały dwie kopie tej samej logiki.

`Quickshell.Networking` i `Quickshell.Bluetooth` ładują dane **asynchronicznie**:
przez ~1–6 s po starcie `Networking.devices` jest puste, `Bluetooth.defaultAdapter`
to `null`, a tuż po pojawieniu adapter zgłasza przejściowo stan `Enabling`. Wszystko
w karcie musi znosić `null` i chwilowy stan "busy".

- Wyłączony Bluetooth w KDE to **blokada rfkill** (`bluedevilglobalrc:
  bluetoothBlocked=true`), a zablokowany adapter ignoruje `enabled = true`. Włączanie
  idzie przez `rfkill unblock bluetooth` (działa bez roota), BlueZ z AutoEnable sam
  podnosi adapter; wyłączanie to `enabled = false` + `rfkill block`, żeby aplet KDE
  zgadzał się z wyspą.
- Urządzenie znalezione przy skanowaniu znika z BlueZ kilka sekund po jego końcu:
  `modelData` delegatu robi się `null` **zanim** delegat zostanie zniszczony. Delegat
  czyta wszystko przez własne pola z gardą na `null`.
- `adapter.discovering = false`, gdy skanowanie zaczął inny klient (aplet KDE, druga
  instancja), daje ostrzeżenie BlueZ "No discovery started". Nieszkodliwe.
- `device.battery` traktuj jako 0–1 z gardą na 0–100 — dokumentacja Quickshella tego
  nie precyzuje, a żadne sparowane tu urządzenie nie zgłasza baterii, więc nie było
  jak zmierzyć.
- `modelData` delegatu to tutaj **ten sam obiekt** co element modelu (zmierzone:
  `modelData === networks[0]` daje `true`), więc zaznaczenie wiersza można trzymać
  przez porównanie tożsamości. To NIE jest sprzeczne z pułapką z historii powiadomień
  — tam model był tablicą zwykłych obiektów JS i delegat dostawał kopię; tu elementy
  są QObject-ami i przechodzą jako wskaźniki.
- Wybrane urządzenie potrafi zniknąć z BlueZ (znalezione przy skanowaniu przepada
  kilka sekund po jego końcu). Panel pilnuje tego przez `Connections` na
  `Bluetooth.devices` i czyści wybór, inaczej formularz pokazywałby dane
  urządzenia, którego już nie ma.

### Wybór monitora

Quickshell nie zna pojęcia „monitora głównego" (Wayland go nie ma), a kolejność
`Quickshell.screens` **nie** odpowiada priorytetom kompozytora — na desktopie z KDE
`screens[0]` to drugi monitor. Monitor można wskazać po nazwie w `shell.qml`
(`islandScreen`); **domyślnie jest pusto**, czyli automat: ekran w punkcie `(0,0)`,
a potem pierwszy z listy. Nie wpisuj tu nazwy na stałe — projekt chodzi na dwóch
maszynach o różnych monitorach (`DP-1` na desktopie, `eDP-1` na laptopie).

## Styl

**Język.** Kod i komentarze po polsku. Nazwy właściwości i id-ków po angielsku,
zgodnie z konwencją QML. Komunikaty dla użytkownika (`console.warn`) po polsku.

**Komentarze tłumaczą „dlaczego", nie „co".** Kod jest czytelny sam z siebie;
komentarze istnieją po to, żeby utrwalić pułapkę, która kiedyś kosztowała debugowanie.
Jeśli coś wygląda na nadmiarowe lub dziwne, komentarz ma wyjaśniać, dlaczego prostsza
wersja nie działa. Nie komentuj rzeczy oczywistych.

**Ustawienia jako nazwane właściwości na górze pliku**, z komentarzem wyjaśniającym
zakres i skutek — nie wartości wpisane w środku kodu. Przykłady: `collapseDelay`,
`noticeDuration`, `spectrumSmoothingMs`, `noiseReduction`. Gdy dobierasz liczbę
doświadczalnie, zapisz pomiar w README, żeby następny nie zgadywał od zera.

**Formatowanie.** Cztery spacje na poziom, brak tabów. Sekcje najwyższego poziomu
oddzielone blokiem trzech linii (linia myślników, opis, linia myślników), sekcje
wewnątrz komponentu jednolinijkowym `// ---- opis ----`.

**Wartości wyprowadzaj, nie powielaj.** `readonly property` z wyrażeniem zamiast
ręcznie synchronizowanych stanów.

### Rzeczy, których świadomie tu nie ma

- `qmldir` — psuje niejawny import komponentów z katalogu.
- Cień pod wyspą — `MultiEffect` wymaga paddingu warstwy, pominięte celowo.
- `DesktopEntries` / ikona aplikacji — w pigułce ma być okładka utworu, nie logo
  przeglądarki. To była wyraźna decyzja użytkownika.

### Pułapki geometryczne

Dodatki do rozmiarów muszą być **parzyste**, gdy element bazowy ma parzysty rozmiar.
Pierścień hovera z `parent.width + 9` na przycisku 30 px dawał idealny środek na
−4,5 px, a `anchors.centerIn` zaokrągla — pierścień siadał pół piksela za wysoko
i odstęp na dole był węższy. Przy zmianie rozmiarów przycisków sprawdź to ponownie.

Wewnątrz positionera (`Row`, `Column`) nie używaj `anchors` do osi prostopadłej —
ustaw `y` ręcznie. Positioner steruje tylko jedną osią i kotwice potrafią się z nim gryźć.

`clip: true` na `Rectangle` z `radius` **nie** zaokrągla przycinania — jest prostokątne.
Do zaokrąglonego przycinania używaj `ClippingRectangle` z `Quickshell.Widgets`.
