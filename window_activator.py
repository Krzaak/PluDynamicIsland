#!/usr/bin/env python3
"""
Podnosi okno działającej aplikacji na KWin/Wayland. Uruchamiany na żądanie
przez wyspę (przycisk "otwórz" w historii powiadomień), kończy się od razu.

Dlaczego osobne narzędzie, a nie QML: Quickshell widzi okna tylko przez
wlr-foreign-toplevel-management, którego KWin nie wystawia — ToplevelManager
zwraca tam pustą listę (zmierzone). Plasma ma własny protokół Waylanda
(plasma-window-management), do którego QML nie ma dostępu. Zostaje D-Bus KWina:

  /WindowsRunner  org.kde.krunner1.Match(fraza)        -> pasujące okna (runner KRunnera)
  /KWin           org.kde.KWin.getWindowInfo(uuid)     -> resourceClass, desktopFile, caption
  /WindowsRunner  org.kde.krunner1.Run(matchId, "")    -> aktywacja okna

Match dopasowuje TAKŻE po tytule okna, więc samo jego trafienie niczego nie
dowodzi: przy frazie "discord" wygrałaby karta przeglądarki z Discordem
w tytule. Dlatego każdy kandydat jest weryfikowany przez getWindowInfo —
liczy się plik .desktop okna albo jego klasa, nigdy tytuł.

  użycie : window_activator.py <appId> [startupClass] [appName]
  wyjście: 0 - okno aktywowane
           1 - aplikacja nie ma okna (wyspa ma ją wtedy uruchomić)
           2 - KWin nie odpowiada (nie ma go albo to inny kompozytor)

Diagnostyka idzie na stderr, żeby nie mieszać się z kodem wyjścia.
"""

import sys

import dbus

KWIN = "org.kde.KWin"
RUNNER_PATH = "/WindowsRunner"
RUNNER_IFACE = "org.kde.krunner1"
KWIN_PATH = "/KWin"
KWIN_IFACE = "org.kde.KWin"


def log(text):
    sys.stderr.write(text + "\n")
    sys.stderr.flush()


def norm(value):
    return str(value or "").strip().lower()


def base_id(value):
    """Id wpisu .desktop bez ścieżki i rozszerzenia — KWin podaje raz tak, raz tak."""
    name = norm(value).rsplit("/", 1)[-1]
    return name[:-8] if name.endswith(".desktop") else name


def main(argv):
    app_id = argv[0] if argv else ""
    startup_class = argv[1] if len(argv) > 1 else ""
    app_name = argv[2] if len(argv) > 2 else ""
    if not app_id:
        log("brak appId")
        return 1

    # Frazy do wyszukania. Ostatni człon id (org.kde.dolphin -> dolphin) bywa
    # jedyną rzeczą, jaką KWin zna jako klasę okna.
    terms = []
    for term in (app_id, startup_class, app_name, app_id.rsplit(".", 1)[-1]):
        if term and term not in terms:
            terms.append(term)

    # Wartości, które uznajemy za dowód, że to okno TEJ aplikacji.
    wanted = {base_id(app_id)}
    if startup_class:
        wanted.add(norm(startup_class))

    try:
        bus = dbus.SessionBus()
        runner = dbus.Interface(bus.get_object(KWIN, RUNNER_PATH), RUNNER_IFACE)
        kwin = dbus.Interface(bus.get_object(KWIN, KWIN_PATH), KWIN_IFACE)
    except dbus.DBusException as exc:
        log(f"KWin nie odpowiada: {exc}")
        return 2

    seen = set()
    for term in terms:
        try:
            matches = runner.Match(term)
        except dbus.DBusException as exc:
            log(f"Match({term}) nie wyszło: {exc}")
            return 2

        for match in matches:
            match_id = str(match[0])
            if match_id in seen:
                continue
            seen.add(match_id)

            # Id dopasowania to "<numer>_{uuid}", a getWindowInfo chce samego {uuid}.
            uuid = match_id.split("_", 1)[-1]
            try:
                info = kwin.getWindowInfo(uuid)
            except dbus.DBusException as exc:
                log(f"getWindowInfo({uuid}) nie wyszło: {exc}")
                continue

            fields = {
                base_id(info.get("desktopFile", "")),
                norm(info.get("resourceClass", "")),
                norm(info.get("resourceName", "")),
            }
            if not (fields & wanted):
                continue

            runner.Run(match_id, "")
            log(f"aktywowano {info.get('resourceClass', '?')}: {info.get('caption', '')}")
            return 0

    log(f"brak okna dla {app_id}")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
