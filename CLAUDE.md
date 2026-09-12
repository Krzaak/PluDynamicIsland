# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Czym to jest

Dynamiczna wyspa w stylu iOS dla **Quickshell** (Wayland, layer-shell). Czysty QML —
brak kroku budowania, brak testów, brak zależności poza tymi z systemu.

Cel: pływająca pigułka na górze ekranu, która w spoczynku pokazuje zegar, okładkę
i spektrum dźwięku, a po najechaniu rozwija się w karuzelę kart (muzyka | Discord |
zegar | łączność) przewijaną kółkiem. Podczas rozmowy na Discordzie obok zwiniętej pigułki
stoi druga, mała, z nazwą kanału i timerem.

Środowisko docelowe: Quickshell 0.3.1, Qt 6.11, KDE/KWin na Wayland.

## Polecenia

```sh
qs -p .                                        # uruchomienie z katalogu projektu
qs -p . --no-color --log-times > IslandLogs.log 2>&1   # z logiem do pliku
timeout 8 qs -p . --no-color > IslandLogs.log 2>&1     # przebieg kontrolny
grep -acE "WARN|ERROR|error:" IslandLogs.log   # 2 = czysto (patrz niżej)
kscreen-doctor -o                              # nazwy monitorów (dla islandScreen)
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
`animateCardChange` przed przypisaniem — nie przypisuj `currentCard` wprost.

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

### Karta łączności (Wi-Fi, Bluetooth)

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

### Wybór monitora

Quickshell nie zna pojęcia „monitora głównego" (Wayland go nie ma), a kolejność
`Quickshell.screens` **nie** odpowiada priorytetom KDE — na tej maszynie `screens[0]`
to drugi monitor. Monitor wskazuje się po nazwie w `shell.qml` (`islandScreen`),
z awaryjnym zejściem na ekran w punkcie `(0,0)`, a potem na pierwszy z listy.

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
