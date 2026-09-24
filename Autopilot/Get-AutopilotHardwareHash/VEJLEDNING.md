# Vejledning: Autopilot hardware hash via ManageEngine

Scriptet `Get-AutopilotHardwareHash.ps1` henter pc'ens Windows Autopilot hardware hash **lydløst** og registrerer pc'en direkte i Intune (Windows Autopilot) med gruppetagget **`GR_PC_DK`**. Det er lavet til at blive kørt som SYSTEM fra ManageEngine Endpoint Central, men kan også køres manuelt.

> **Status:** Scriptet er testet automatisk (14 Pester-tests på Linux med simulerede svar). Det er **ikke** kørt på en rigtig Windows-pc eller mod en rigtig tenant endnu. Start med én test-pc (afsnit 4).

## 1. Hvad scriptet gør

1. Læser serienummer (BIOS) og hardware hash (Windows' MDM-WMI-klasse `MDM_DevDetail_Ext01`). Der hentes ingen moduler fra internettet.
2. Gemmer **altid** en import-CSV lokalt i `C:\ProgramData\AutopilotHash\<serienummer>.csv` som backup.
3. Logger ind i Microsoft Graph som en app (klienthemmelighed eller certifikat).
4. Tjekker om pc'en allerede er registreret i Autopilot. Er den det, stopper scriptet med succes (og retter evt. gruppetagget, se `-UpdateGroupTag`).
5. Importerer pc'en med gruppetagget og venter på resultatet (op til 10 minutter).
6. Skriver log i `C:\ProgramData\AutopilotHash\Logs\AutopilotHash.log` og afslutter med en exit-kode (afsnit 6).

Kører ManageEngine-agenten som 32-bit, genstarter scriptet sig selv i 64-bit PowerShell, fordi hash'en kun kan læses dér.

## 2. Forudsætninger

- Windows 10 1703 eller nyere / Windows 11, Windows PowerShell 5.1
- Kørsel som **SYSTEM** eller lokal administrator
- Udgående HTTPS (port 443) til `login.microsoftonline.com` og `graph.microsoft.com`
- En app-registrering i Entra ID (afsnit 3)
- ManageEngine Endpoint Central-agent på pc'erne

## 3. Opret app-registrering i Entra ID (én gang)

1. **Entra admin center** → **Applikationer** → **App-registreringer** → **Ny registrering**
   - Navn: fx `Autopilot Hash Upload`
   - Kontotyper: *Kun denne organisation*. Ingen omdirigerings-URI.
2. **API-tilladelser** → **Tilføj en tilladelse** → **Microsoft Graph** → **Programtilladelser** → vælg **`DeviceManagementServiceConfig.ReadWrite.All`** → **Tilføj**.
3. Klik **Giv administratorsamtykke for <organisation>**. Status skal vise grønt flueben.
4. **Certifikater og hemmeligheder** → **Ny klienthemmelighed**
   - Beskrivelse: fx `ManageEngine udrulning <dato>`
   - Udløb: **så kort som muligt** (fx 30 dage), svarende til udrulningsperioden
   - Kopiér **Værdi** med det samme (den vises kun én gang)
5. Notér **Program-id (klient-id)** og **Mappe-id (lejer-id)** fra oversigten.

> **Sikkerhed:** Tilladelsen giver adgang til Autopilot-konfigurationen i hele tenanten. Hemmeligheden må aldrig ligge i scriptet, i git eller i dokumentation. Slet hemmeligheden, når udrulningen er færdig. Et certifikat (`-CertificateThumbprint`) er et alternativ, men certifikatets private nøgle skal så ligge på hver pc.

## 4. Test på én pc først

Åbn **PowerShell som administrator** på en test-pc, i mappen med scriptet:

```powershell
# Kun indsamling, ingen upload (tjek at hash kan læses)
.\Get-AutopilotHardwareHash.ps1 -SkipUpload
$LASTEXITCODE   # forventet: 10

# Med upload
.\Get-AutopilotHardwareHash.ps1 -TenantId '<lejer-id>' -ClientId '<klient-id>' -ClientSecret '<hemmelighed>'
$LASTEXITCODE   # forventet: 0
```

Kontrollér i **Intune** → **Enheder** → **Windows** → **Registrering** → **Enheder** (Windows Autopilot-enheder), at serienummeret står der med gruppetag `GR_PC_DK`. Det kan tage op til ca. 15 minutter, før enheden vises. Brug **Synkroniser**, hvis den ikke dukker op.

## 5. Udrul via ManageEngine Endpoint Central

Menunavne kan variere lidt mellem versioner af Endpoint Central.

1. **Konfigurationer** → **Tilføj konfiguration** → **Windows** → **Brugerdefineret script** (*Custom Script*) → vælg **Computer**-konfiguration (kører som SYSTEM).
2. Upload `Get-AutopilotHardwareHash.ps1` (evt. via *Script Repository*).
3. **Kommandolinje:**
   ```
   powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File Get-AutopilotHardwareHash.ps1
   ```
4. **Script-argumenter:**
   ```
   -TenantId <lejer-id> -ClientId <klient-id> -ClientSecret <hemmelighed>
   ```
   Tilføj `-UpdateGroupTag`, hvis allerede registrerede pc'er også skal have `GR_PC_DK`. `-GroupTag` kan angives, hvis et andet tag ønskes.
5. **Exit-koder for succes:** `0` (og `10`, hvis I kører med `-SkipUpload`).
6. **Timeout:** mindst **15 minutter** (scriptet venter op til 10 minutter på importen).
7. **Kørsel:** én gang pr. computer (*Run once*). Vælg målgruppe: start med en lille testgruppe, derefter resten.
8. Følg status i ManageEngine (exit-kode pr. computer) og i Intune.

> Script-argumenter kan være synlige for ManageEngine-administratorer og i pc'ens procesliste, mens scriptet kører. Derfor: kort levetid på hemmeligheden, og slet den bagefter.

## 6. Exit-koder

| Kode | Betydning | Hvad gør jeg? |
| --- | --- | --- |
| 0 | Importeret, eller allerede registreret | Intet |
| 10 | Kun lokal CSV (`-SkipUpload`) | Importér CSV manuelt (afsnit 8) |
| 1 | Ikke kørt som SYSTEM/administrator | Kør som computerkonfiguration i ManageEngine |
| 2 | Hash kunne ikke læses | Tjek Windows-version; nogle virtuelle maskiner og meget gamle builds har ingen hash |
| 3 | Login mod Entra fejlede | Forkert lejer-/klient-id, udløbet eller forkert hemmelighed |
| 4 | Graph-kald fejlede | Oftest 403: mangler tilladelse eller administratorsamtykke. Tjek også netværk/proxy |
| 5 | Importen fejlede | Se loggen. Fx **806** *ZtdDeviceAlreadyAssigned* eller **808** *ZtdDeviceAssignedToOtherTenant*: pc'en er registreret hos en anden (fx forhandler/anden tenant) og skal frigives dér først |
| 6 | Import ikke færdig inden for tiden | Tjek Intune om lidt; kør evt. igen (allerede registrerede pc'er springes over) |
| 7 | Manglende parametre | Angiv `-TenantId`, `-ClientId` og `-ClientSecret` (eller `-CertificateThumbprint`) |

Loggen ligger i `C:\ProgramData\AutopilotHash\Logs\AutopilotHash.log`. Hemmeligheden skrives aldrig i loggen.

## 7. Parametre

| Parameter | Standard | Beskrivelse |
| --- | --- | --- |
| `-TenantId` | | Lejer-id eller primært domæne |
| `-ClientId` | | App-registreringens klient-id |
| `-ClientSecret` | | Klienthemmelighed |
| `-CertificateThumbprint` | | I stedet for hemmelighed: certifikat i `Cert:\LocalMachine\My` |
| `-GroupTag` | `GR_PC_DK` | Autopilot-gruppetag |
| `-UpdateGroupTag` | fra | Ret gruppetagget på pc'er, der allerede er registreret |
| `-SkipUpload` | fra | Gem kun lokal CSV, ingen upload |
| `-WaitMinutes` | 10 | Maks. ventetid på importresultat |
| `-OutputFolder` | `C:\ProgramData\AutopilotHash` | Mappe til CSV og log |

## 8. Plan B: manuel import af CSV

Hvis upload ikke er mulig, kør med `-SkipUpload`. Hver pc skriver så `C:\ProgramData\AutopilotHash\<serienummer>.csv` i Intunes importformat med gruppetag. Saml filerne (kun én overskriftslinje) og importér i **Intune** → **Enheder** → **Windows** → **Registrering** → **Enheder** → **Importér**. Filen skal være ANSI/UTF-8 (ikke Unicode), og hold dig under 500 pc'er pr. fil.

## 9. Efter udrulningen

- Slet klienthemmeligheden i app-registreringen (eller hele appen, hvis den ikke skal bruges igen)
- Fjern konfigurationen i ManageEngine
- Tildel en Autopilot-profil til en dynamisk gruppe baseret på gruppetagget, fx regel: `(device.devicePhysicalIds -any (_ -eq "[OrderID]:GR_PC_DK"))`
