# expose-port.sh

Ein Shell-Script um Game Server Ports über eine Oracle Cloud ARM Instanz ins Internet zu exponieren – ohne direkte öffentliche IP auf dem Heimserver.

## Wie es funktioniert

```
Internet
   │
   ▼
Oracle ARM (Public IP)
   │  nftables DNAT
   │  Tailscale VPN
   ▼
Proxmox Subnet Router
   │  LAN
   ▼
Wings VM – Pterodactyl Wings (Docker)
```

Der Oracle ARM Server empfängt den Traffic auf dem öffentlichen Port und leitet ihn per DNAT über Tailscale an den internen Wings Server weiter. Der Heimserver braucht keine öffentliche IP – nur Tailscale.

---

## Voraussetzungen

- Oracle Cloud ARM Instanz (Free Tier reicht)
- Zwei NICs auf der Oracle Instanz:
  - `enp0s6` – Management/SSH
  - `enp1s0` – Game Traffic (mit Public IP)
- Tailscale auf Oracle und auf dem Heimserver installiert
- Subnet Router auf dem Heimserver der das LAN advertised
- Pterodactyl Wings läuft auf `192.168.0.21` (Standardwert im Script – bei abweichender Wings VM IP `WINGS_IP` anpassen)

---

## Installation

Script herunterladen:

```bash
curl -O https://raw.githubusercontent.com/Mozra-the-great/expose-port/main/expose-port.sh
chmod +x expose-port.sh
```

---

## Verwendung

```bash
sudo ./expose-port.sh [--dry-run] <port> [tcp|udp|both]
```

- `<port>`: Dezimalzahl von 1 bis 65535, nur Ziffern, **ohne führende Nullen** (`080` wird abgelehnt,
  weil manche Tools es als Oktalzahl lesen), ohne Vorzeichen und ohne Leerzeichen.
- Protokoll: `tcp`, `udp` oder `both` (Standard).
- `--dry-run`: zeigt die Befehle, die das System verändern würden (`nft`, `sysctl`, `ip`,
  `systemctl`), mit dem Präfix `[dry-run]`, statt sie auszuführen. Lesende Abfragen laufen
  trotzdem, deshalb braucht auch `--dry-run` root.

Schlägt ein veränderender Befehl fehl, bricht das Script mit Exit-Code 1 ab und nennt den
fehlgeschlagenen Befehl samt Ausgabe. Wurden davor schon Änderungen gemacht, listet es diese auf
(**kein** automatisches Rollback). Mit `sudo nft list table ip gamenat -a` lässt sich der Stand
prüfen; eine bestehende `/etc/nftables.conf` bleibt bei einem Fehler von `nft` unverändert (sie wird erst
überschrieben, wenn `nft list ruleset` erfolgreich war). Zusätzliche Argumente werden abgelehnt;
`--dry-run` muss deshalb als erstes Argument stehen.

### Beispiele

```bash
sudo ./expose-port.sh 25565 both    # Minecraft
sudo ./expose-port.sh 25566 both    # Zweiter Minecraft Server
sudo ./expose-port.sh 2456  both    # Valheim
sudo ./expose-port.sh 27015 both    # CS2
sudo ./expose-port.sh 7777  both    # Terraria
sudo ./expose-port.sh 28015 both    # Rust
sudo ./expose-port.sh 19132 udp     # Bedrock Edition
sudo ./expose-port.sh --dry-run 25565 both   # nur anzeigen, nichts ändern
```

---

## Was das Script automatisch macht

| Schritt | Beschreibung |
|---------|-------------|
| ✅ nftables DNAT | Leitet eingehenden Traffic auf den Wings Server weiter |
| ✅ IP Forwarding | Aktiviert `net.ipv4.ip_forward` falls nötig |
| ✅ Policy Routing | Stellt sicher dass Antwortpakete über die richtige NIC zurückgehen |
| ✅ Persistenz | Speichert alle Regeln in `/etc/nftables.conf` |
| ✅ Boot | Aktiviert nftables als Systemd Service |
| ✅ Duplikat-Check | Warnt wenn der Port bereits weitergeleitet wird |
| ✅ Fehlerprüfung | Bricht bei jedem fehlgeschlagenen Befehl ab und meldet bereits Angewendetes |

---

## Was danach noch manuell nötig ist

### 1. Oracle Security List

In der [Oracle Cloud Console](https://cloud.oracle.com):

**Networking → Virtual Cloud Networks → VCN → Subnets → public subnet → Security List → Add Ingress Rules**

| Stateless | Source CIDR | Protocol | Destination Port |
|-----------|-------------|----------|-----------------|
| No | `0.0.0.0/0` | TCP | `<PORT>` |
| No | `0.0.0.0/0` | UDP | `<PORT>` |

### 2. Pterodactyl Panel Allocation

Unter `http://<panel-ip>/admin/nodes/1/allocation`:

- **IP Address**: `0.0.0.0`
- **Ports**: `<PORT>`
- Klick **Submit**

---

## Konfiguration anpassen

Am Anfang des Scripts können folgende Variablen angepasst werden:

```sh
WINGS_IP="192.168.0.21"     # Interne IP der Wings VM
PUBLIC_IFACE="enp1s0"       # NIC mit Public IP
TAILSCALE_IFACE="tailscale0" # Tailscale Interface
NFT_TABLE="gamenat"          # nftables Tabellenname
```

Die Pfade `NFT_CONFIG` (Standard `/etc/nftables.conf`) und `SYSCTL_CONF` (Standard
`/etc/sysctl.conf`) lassen sich über gleichnamige Umgebungsvariablen überschreiben; die Tests
nutzen das, damit sie nie unter `/etc` schreiben. Achtung: Mit `sudo -E` oder einer Root-Shell,
in der diese Variablen gesetzt sind, würde die Persistenz sonst still woanders landen als dort, wo
der `nftables`-Dienst sie lädt.

---

## Troubleshooting

### Port bleibt geschlossen nach dem Script

1. Oracle Security List geprüft?
2. Tailscale Verbindung aktiv?
   ```bash
   tailscale status
   ping 192.168.0.21
   ```
3. Wings läuft?
   ```bash
   systemctl status wings
   ```
4. Lauscht der Game Server auf dem Port?
   ```bash
   ssh root@192.168.0.21
   ss -tlnp | grep <PORT>
   ```

### Regeln nach Reboot weg

```bash
sudo systemctl enable nftables
sudo nft list ruleset > /etc/nftables.conf
```

### Alle aktuellen Weiterleitungen anzeigen

```bash
sudo nft list table ip gamenat
```

### Eine Weiterleitung entfernen

```bash
# Regel-Handles anzeigen
sudo nft list table ip gamenat -a

# Regel löschen (handle = Nummer aus obigem Befehl)
sudo nft delete rule ip gamenat prerouting handle <NUMMER>
sudo nft list ruleset > /etc/nftables.conf
```

---

## Unterstützte Spiele & Standard-Ports

| Spiel | Port | Protokoll |
|-------|------|-----------|
| Minecraft Java | `25565` | TCP+UDP |
| Minecraft Bedrock | `19132` | UDP |
| Valheim | `2456-2457` | UDP |
| CS2 | `27015` | TCP+UDP |
| Rust | `28015` | TCP+UDP |
| Terraria | `7777` | TCP |
| Palworld | `8211` | UDP |
| ARK | `7777` | UDP |
| Garry's Mod | `27015` | UDP |

---

## Tests & CI

```bash
sh tests/test_args.sh                            # Argument-Handling (ohne root, ohne Systemzugriff)
sh tests/test_run.sh                             # --dry-run und Fehlerpfade gegen gemockte Tools
shellcheck --shell=sh expose-port.sh tests/*.sh
```

Das Script wird weder lokal noch in CI auf dem echten System ausgeführt: es verändert nftables,
sysctl und Routing als root. `test_args.sh` deckt nur Pfade ab, die vor jeder Änderung abbrechen
(kein root, kein Port, ungültiger Port/Protokoll). `test_run.sh` führt das Script komplett aus,
aber nur gegen Mocks von `nft`, `ip`, `sysctl`, `systemctl`, `apt-get`, `curl` und `id`, die die
Aufrufe protokollieren (inklusive Fehlerfälle: die meisten veränderenden Befehle werden zum
Scheitern gebracht). Alle anderen Systemtools sind Stubs, die den Test fehlschlagen lassen, falls sie
aufgerufen würden. Beide Tests verweigern den Start als echter root.

---

## Lizenz

GNU General Public License v3.0 — siehe [LICENSE](LICENSE).
