pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Networking

// Wi-Fi: lista sieci, skanowanie i zakładanie nowych połączeń.
//
// Quickshell.Networking sam w sobie umie mało: connectWithPsk(psk) dla sieci
// WIDOCZNEJ i zabezpieczonej hasłem — i tyle. connectWithSettings() chce
// obiektu NMSettings, którego NIE DA SIĘ utworzyć z QML (typ nie jest
// eksportowany; sprawdzone w qmltypes), więc sieć ukryta, 802.1X i wybór
// "łącz automatycznie" muszą iść przez nm_connect.py, który rozmawia
// z NetworkManagerem po D-Bus.
//
// Podział jest taki:
//   sieć ZNANA (ma profil)  -> network.connect()      — bez pytania o hasło
//   sieć nowa               -> nm_connect.py          — z pełnym formularzem
// Dzięki temu "połącz" na znanej sieci nie zakłada drugiego profilu obok
// istniejącego, a nowa dostaje wszystkie pola.
Singleton {
    id: root

    // ---------------------------------------------------------------
    // Ustawienia
    // ---------------------------------------------------------------

    // Po ilu ms od zlecenia przestajemy pokazywać "łączę". NetworkManager
    // przy złym haśle potrafi milczeć — próbuje ponownie, zamiast od razu
    // zgłosić błąd — a kręcące się w nieskończoność kółko wygląda na zawieszenie.
    property int connectTimeoutMs: 25000

    // ---------------------------------------------------------------
    // Urządzenie i sieci
    // ---------------------------------------------------------------

    readonly property var device: {
        const all = Networking.devices.values;
        for (let i = 0; i < all.length; i++)
            if (all[i].type === DeviceType.Wifi) return all[i];
        return null;
    }

    readonly property bool available: device !== null
    readonly property string iface: device ? device.name : ""
    readonly property bool enabled: Networking.wifiEnabled
    readonly property bool hardwareEnabled: Networking.wifiHardwareEnabled

    // Lista do pokazania: najpierw połączona, potem znane, potem reszta wg
    // siły sygnału. Sieci bez nazwy (ukryte, widziane tylko jako punkt
    // dostępowy) odpadają — nie ma po czym ich kliknąć, a do ukrytej i tak
    // wchodzi się przez formularz z ręcznie wpisanym SSID-em.
    readonly property var networks: {
        if (!device || !device.networks) return [];
        const all = device.networks.values.filter(n => (n.name || "") !== "");

        return all.slice().sort((a, b) => {
            if (a.connected !== b.connected) return a.connected ? -1 : 1;
            if (a.known !== b.known) return a.known ? -1 : 1;
            return b.signalStrength - a.signalStrength;
        });
    }

    readonly property var activeNetwork: {
        const all = networks;
        for (let i = 0; i < all.length; i++) if (all[i].connected) return all[i];
        return null;
    }

    // ---------------------------------------------------------------
    // Skanowanie
    // ---------------------------------------------------------------

    // scannerEnabled to prośba do NetworkManagera o CIĄGŁE odświeżanie listy.
    // Trzymamy je włączone tylko, gdy panel jest otwarty — skanowanie zrywa
    // co chwilę transmisję na karcie i przy zamkniętym panelu nikt z tego
    // nie korzysta.
    property bool scanning: false

    onScanningChanged: if (device) device.scannerEnabled = scanning
    onDeviceChanged: if (device) device.scannerEnabled = scanning

    // ---------------------------------------------------------------
    // Nazwy zabezpieczeń
    // ---------------------------------------------------------------

    // Enum Quickshella -> nazwa dla użytkownika.
    function securityLabel(type) {
        switch (type) {
        case WifiSecurityType.Open: return "Otwarta";
        case WifiSecurityType.Owe: return "Otwarta (szyfrowana)";
        case WifiSecurityType.Sae: return "WPA3 Personal";
        case WifiSecurityType.Wpa2Psk: return "WPA2 Personal";
        case WifiSecurityType.WpaPsk: return "WPA Personal";
        case WifiSecurityType.Wpa2Eap: return "WPA2 Enterprise";
        case WifiSecurityType.WpaEap: return "WPA Enterprise";
        case WifiSecurityType.Wpa3SuiteB192: return "WPA3 Enterprise 192-bit";
        case WifiSecurityType.StaticWep: return "WEP";
        case WifiSecurityType.DynamicWep: return "WEP dynamiczny (802.1X)";
        case WifiSecurityType.Leap: return "LEAP";
        default: return "Nieznane";
        }
    }

    // Enum Quickshella -> key-mgmt NetworkManagera (to, czego chce nm_connect.py).
    function securityKey(type) {
        switch (type) {
        case WifiSecurityType.Open: return "open";
        case WifiSecurityType.Owe: return "owe";
        case WifiSecurityType.Sae: return "sae";
        case WifiSecurityType.Wpa2Psk:
        case WifiSecurityType.WpaPsk: return "wpa-psk";
        case WifiSecurityType.StaticWep: return "wep";
        case WifiSecurityType.Wpa2Eap:
        case WifiSecurityType.WpaEap:
        case WifiSecurityType.Wpa3SuiteB192:
        case WifiSecurityType.DynamicWep:
        case WifiSecurityType.Leap: return "wpa-eap";
        default: return "wpa-psk";
        }
    }

    function needsPassword(key) { return key === "wpa-psk" || key === "sae" || key === "wep"; }
    function needsEap(key) { return key === "wpa-eap"; }

    // Zabezpieczenia do wyboru w formularzu sieci ukrytej — tam nikt nam nie
    // powie, czego sieć używa.
    readonly property var securityChoices: [
        { value: "wpa-psk", label: "WPA/WPA2 Personal" },
        { value: "sae", label: "WPA3 Personal" },
        { value: "wpa-eap", label: "WPA/WPA2 Enterprise (802.1X)" },
        { value: "wep", label: "WEP" },
        { value: "owe", label: "Otwarta (szyfrowana, OWE)" },
        { value: "open", label: "Otwarta" }
    ]

    readonly property var eapChoices: [
        { value: "peap", label: "PEAP" },
        { value: "ttls", label: "TTLS" },
        { value: "tls", label: "TLS (certyfikat)" },
        { value: "pwd", label: "PWD" }
    ]

    readonly property var phase2Choices: [
        { value: "mschapv2", label: "MSCHAPv2" },
        { value: "gtc", label: "GTC" },
        { value: "md5", label: "MD5" },
        { value: "pap", label: "PAP" },
        { value: "chap", label: "CHAP" },
        { value: "", label: "(żadne)" }
    ]

    // ---------------------------------------------------------------
    // Łączenie
    // ---------------------------------------------------------------

    // Nazwa sieci, z którą właśnie się łączymy ("" = z żadną). Panel po tym
    // pokazuje kropki na przycisku i blokuje formularz.
    property string busySsid: ""
    property string error: ""

    readonly property bool busy: busySsid !== ""

    signal connected(string ssid)
    signal failed(string ssid, string reason)

    function clearError() { root.error = ""; }

    function finish(ssid, reason) {
        if (root.busySsid !== ssid) return;
        root.busySsid = "";
        connectTimer.stop();
        if (reason === "") {
            root.error = "";
            root.connected(ssid);
        } else {
            root.error = reason;
            root.failed(ssid, reason);
        }
    }

    // Sieć znana — profil już jest, wystarczy go podnieść.
    function connectKnown(network) {
        if (!network) return;
        root.error = "";
        root.busySsid = network.name;
        connectTimer.restart();
        network.connect();
    }

    function disconnect(network) {
        if (network) network.disconnect();
    }

    function forget(network) {
        if (!network) return;
        // Bez emitowania `connected`: zapomnienie sieci nie jest sukcesem
        // połączenia, a panel po tym sygnale zamknąłby formularz tak,
        // jakby udało się połączyć.
        if (network.name === root.busySsid) {
            root.busySsid = "";
            connectTimer.stop();
        }
        network.forget();
    }

    // Sieć nowa: wszystko, co użytkownik wpisał, idzie JSON-em na stdin
    // pomocnika. Celowo nie przez argv — /proc/<pid>/cmdline czyta każdy
    // proces tego użytkownika, a tam byłoby hasło.
    function connectNew(params) {
        if (!params || !params.ssid) return;
        if (connector.running) {
            root.error = "Poprzednie łączenie jeszcze trwa.";
            return;
        }

        root.error = "";
        root.busySsid = params.ssid;
        connectTimer.restart();

        const req = Object.assign({ iface: root.iface }, params);
        connector.command = ["python3", Quickshell.shellPath("nm_connect.py")];
        connector.pendingRequest = JSON.stringify(req);
        connector.running = true;
    }

    function findByName(ssid) {
        const all = networks;
        for (let i = 0; i < all.length; i++) if (all[i].name === ssid) return all[i];
        return null;
    }

    // Sieć, na którą czekamy. WYPROWADZONA z busySsid, nie ustawiana ręcznie:
    // przy sieci ukrytej obiekt sieci jeszcze nie istnieje w chwili zlecenia,
    // więc ręczne przypisanie zostawiłoby tu null na zawsze i nie byłoby czego
    // słuchać — zostawałby sam timeout zamiast konkretnego "złe hasło".
    // Powiązanie przelicza się, gdy sieć pojawi się przy kolejnym skanowaniu.
    readonly property var pendingNetwork: busySsid === "" ? null : findByName(busySsid)

    Connections {
        target: root.pendingNetwork
        ignoreUnknownSignals: true

        function onConnectedChanged() {
            if (root.pendingNetwork && root.pendingNetwork.connected)
                root.finish(root.pendingNetwork.name, "");
        }

        function onConnectionFailed(reason) {
            root.finish(root.pendingNetwork ? root.pendingNetwork.name : root.busySsid,
                        root.failReason(reason));
        }
    }

    function failReason(reason) {
        switch (reason) {
        case ConnectionFailReason.NoSecrets: return "Złe hasło.";
        case ConnectionFailReason.WifiAuthTimeout: return "Uwierzytelnianie przekroczyło czas — sprawdź hasło.";
        case ConnectionFailReason.WifiClientFailed: return "Sieć odrzuciła połączenie.";
        case ConnectionFailReason.WifiClientDisconnected: return "Sieć rozłączyła połączenie.";
        case ConnectionFailReason.WifiNetworkLost: return "Sieć zniknęła z zasięgu.";
        default: return "Nie udało się połączyć.";
        }
    }

    Timer {
        id: connectTimer
        interval: root.connectTimeoutMs
        onTriggered: {
            // Brak potwierdzenia nie znaczy na pewno błędu — NM bywa wolny —
            // ale zostawienie kropek na zawsze wygląda jak zawieszenie.
            if (root.busySsid !== "")
                root.finish(root.busySsid, "Brak odpowiedzi — sprawdź hasło albo zasięg.");
        }
    }

    Process {
        id: connector

        property string pendingRequest: ""

        stdinEnabled: true

        stdout: SplitParser {
            splitMarker: "\n"
            onRead: data => {
                const line = data.trim();
                if (line === "") return;
                let res;
                try {
                    res = JSON.parse(line);
                } catch (e) {
                    console.warn("Sieć: nieczytelna odpowiedź pomocnika: " + line);
                    return;
                }
                // ok:true znaczy tylko, że NetworkManager PRZYJĄŁ zlecenie —
                // na powodzenie czekamy dalej, przez stan sieci.
                if (!res.ok) root.finish(root.busySsid, res.error || "Nie udało się połączyć.");
            }
        }

        stderr: SplitParser {
            splitMarker: "\n"
            onRead: data => { const t = data.trim(); if (t !== "") console.warn("[sieć] " + t); }
        }

        onStarted: {
            // Pomocnik czyta stdin do końca pliku, więc po zapisaniu prośby
            // trzeba stdin zamknąć — inaczej obie strony czekałyby na siebie.
            connector.write(connector.pendingRequest);
            connector.pendingRequest = "";
            connector.stdinEnabled = false;
        }

        onExited: (exitCode, exitStatus) => {
            // stdinEnabled trzeba przywrócić, bo Process jest jeden na wszystkie
            // kolejne próby, a zamknięte stdin zostałoby zamknięte na zawsze.
            connector.stdinEnabled = true;
            if (exitCode === 2) root.finish(root.busySsid, "NetworkManager nie odpowiada.");
        }
    }
}
