#Requires -Version 5.1
<#
  Проверка перед уроком — диагностика и безопасные исправления камеры, микрофона, звука и интернета.
  Запускает специалист поддержки на компьютере ученика (например, через RustDesk) файлом lesson-check.bat.

  Что делает:
    1. Проверяет (ничего не меняя): камеру, микрофон, разрешения Windows, кто держит камеру/микрофон,
       службы звука, интернет (пинг, DNS, скорость), место на диске, кэш браузеров.
    2. По каждой найденной проблеме спрашивает «Исправить? Д/Н» и делает только то, на что ответили «Д».
    3. Проверяет ещё раз и сохраняет отчёт на рабочий стол + копирует его в буфер обмена (вставить в Kaiten).

  Никогда не трогает: пароли, cookies, историю и закладки браузеров, файлы пользователя, драйверы (кроме
  перезапуска уже установленной камеры), настройки сети (кроме сброса кэша DNS).

  Совместимо с Windows PowerShell 5.1 (Windows 10/11) и PowerShell 7.
#>
param(
    [string]$Fix = '',          # выполнить одно исправление (используется при перезапуске от администратора)
    [switch]$CheckOnly,         # только проверка и отчёт, без вопросов об исправлениях
    [switch]$Deep,              # глубокий ремонт: переустановка драйверов камеры/звука/Bluetooth (с точкой восстановления)
    [switch]$Undo,              # откатить то, что программа меняла
    [switch]$AdminOnly,         # служебный: часть отката, которой нужны права администратора
    [switch]$Elevated           # служебный: окно открыто программой от администратора — в конце ждём Enter
)

$script:Version = '1.4'
$script:SpeedUrl = 'https://speed.cloudflare.com/__down?bytes=8000000'   # можно заменить на файл на своём сервере
$script:PingHosts = @('8.8.8.8', '1.1.1.1')
$script:DnsHosts = @('ya.ru', 'google.com')
# Программы, которые часто держат камеру или микрофон, просто будучи открытыми, и мешают уроку в браузере.
# Мессенджеры (Telegram, WhatsApp, Viber, Discord) сюда не входят: открытыми они камеру не держат —
# если держат на самом деле (идёт звонок), это видно по журналу Windows и программа предложит их закрыть.
$script:MediaApps = @('Zoom', 'Teams', 'ms-teams', 'Skype', 'obs64', 'obs32', 'CiscoWebexStart', 'webexmta', 'ManyCam', 'XSplit.Core')
$script:Browsers = @(
    @{ Name = 'Google Chrome';  Process = 'chrome';  Root = '%LOCALAPPDATA%\Google\Chrome\User Data';            Kind = 'chromium' },
    @{ Name = 'Microsoft Edge'; Process = 'msedge';  Root = '%LOCALAPPDATA%\Microsoft\Edge\User Data';           Kind = 'chromium' },
    @{ Name = 'Яндекс Браузер'; Process = 'browser'; Root = '%LOCALAPPDATA%\Yandex\YandexBrowser\User Data';     Kind = 'chromium' },
    @{ Name = 'Opera';          Process = 'opera';   Root = '%LOCALAPPDATA%\Opera Software\Opera Stable';         Kind = 'opera'; PrefRoot = '%APPDATA%\Opera Software\Opera Stable' },
    @{ Name = 'Opera GX';       Process = 'opera';   Root = '%LOCALAPPDATA%\Opera Software\Opera GX Stable';      Kind = 'opera'; PrefRoot = '%APPDATA%\Opera Software\Opera GX Stable' },
    @{ Name = 'Firefox';        Process = 'firefox'; Root = '%LOCALAPPDATA%\Mozilla\Firefox\Profiles';           Kind = 'firefox' }
)
$script:ChromiumCacheDirs = @('Cache', 'Code Cache', 'GPUCache')
$script:TimeUrls = @('http://www.msftconnecttest.com/connecttest.txt', 'http://www.google.com/generate_204')   # обычный http: нужен только заголовок Date
$script:InetKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$script:VirtualMicPattern = 'Stereo Mix|Стерео микшер|CABLE Output|VB-Audio|Voicemeeter|Virtual|NVIDIA Broadcast|Krisp|\bOBS\b'
$script:LessonDevicePattern = 'Wi-?Fi|Wireless|WLAN|Беспровод|Ethernet|Network|Сетев|Bluetooth|Camera|Webcam|Камер|Audio|Аудио|Звук|Sound|Microphone|Микрофон|Headset|Гарнитур|USB'
$script:DisplayAudioPattern = 'HDMI|DisplayPort|Display Audio|NVIDIA High Definition|AMD High Definition|Intel\(R\) Display|Аудио для дисплеев'
$script:WebcamGuardPattern = 'Kaspersky|Касперск|ESET|Dr\.?Web|Avast|AVG|Bitdefender|Norton|360 Total'
$script:MinBrowserMajor = @{ chrome = 120; msedge = 120; firefox = 115; browser = 23; opera = 105 }   # старше — предупреждаем
# Адреса сайта уроков (часть имени), например 'livedigital' или 'school'. Запрет камеры для них — главная проблема.
$script:LessonSites = @('livedigital.space', 'school.example')   # видеоуроки (LiveDigital) и платформа школы
# Только «Hands-Free»: русское «Головной телефон» Windows пишет и для обычных проводных гарнитур
$script:HandsFreePattern = 'Hands-Free|Hands Free'
$script:ConsentRoot = 'Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore'
$script:Actions = New-Object System.Collections.Generic.List[string]
$script:DeepLog = New-Object System.Collections.Generic.List[string]
$script:UndoWriteFailed = $false
$script:AppliedFixes = New-Object System.Collections.Generic.List[string]

# ============================================================ сбор данных (только чтение)

function Test-IsAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Get-OsInfo {
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        return "$($os.Caption) (сборка $($os.BuildNumber))"
    } catch { return [Environment]::OSVersion.VersionString }
}

$script:DeviceQueryFailed = $false

function Get-PnpSnapshot {
    # Один запрос: камеры, звук и все устройства с ошибкой. Код 45 = устройство сейчас не подключено (старая
    # гарнитура, флешка) — это не поломка, такие не берём.
    $filter = "(PNPClass='Camera' OR PNPClass='Image' OR PNPClass='MEDIA' OR PNPClass='AudioEndpoint' OR PNPClass='Bluetooth' OR ConfigManagerErrorCode<>0) AND ConfigManagerErrorCode<>45"
    try {
        return @(Get-CimInstance Win32_PnPEntity -Filter $filter -OperationTimeoutSec 20 -ErrorAction Stop |
            ForEach-Object { [pscustomobject]@{ Name = $_.Name; Status = $_.Status; Code = [int]$_.ConfigManagerErrorCode; Id = $_.PNPDeviceID; Class = "$($_.PNPClass)"; Service = $_.Service } })
    } catch { $script:DeviceQueryFailed = $true; return @() }
}

function Select-PnpClass($Snapshot, [string[]]$Classes) {
    return @(@($Snapshot) | Where-Object { $null -ne $_ -and $_.Code -ne 45 -and $Classes -contains "$($_.Class)" })
}

function Get-ConsentValue([string]$Hive, [string]$Capability, [string]$Sub = '') {
    $path = "$($Hive):\$script:ConsentRoot\$Capability"
    if ($Sub) { $path = "$path\$Sub" }
    try { return (Get-ItemProperty -Path $path -Name Value -ErrorAction Stop).Value } catch { return $null }
}

function Get-ConsentUsageKeys([string]$Capability) {
    # Записи «кто пользовался камерой/микрофоном»: имя ключа + время начала/конца последнего использования
    $out = @()
    foreach ($sub in @('NonPackaged', '')) {
        $path = "HKCU:\$script:ConsentRoot\$Capability"
        if ($sub) { $path = "$path\$sub" }
        try {
            foreach ($k in Get-ChildItem -Path $path -ErrorAction Stop) {
                if ($k.PSChildName -eq 'NonPackaged') { continue }
                $p = Get-ItemProperty -Path $k.PSPath -ErrorAction SilentlyContinue
                if ($null -eq $p) { continue }
                $out += [pscustomobject]@{ Key = $k.PSChildName; Start = [int64]$p.LastUsedTimeStart; Stop = [int64]$p.LastUsedTimeStop }
            }
        } catch { }
    }
    return $out
}

function Get-RunningProcessNames { try { return @(Get-Process -ErrorAction Stop | ForEach-Object { $_.ProcessName }) } catch { return @() } }

function Get-PackagedProcesses {
    # Приложения из Microsoft Store (например «Камера Windows») записаны в реестре по имени пакета,
    # а процесс называется иначе. Сопоставляем по пути …\WindowsApps\<пакет>_<версия>…\
    $out = @()
    try {
        foreach ($p in @(Get-Process -ErrorAction Stop)) {
            $path = $null
            try { $path = $p.Path } catch { }
            if ($path -and $path -match '\\WindowsApps\\([^\\_]+)_') { $out += [pscustomobject]@{ Package = $matches[1]; Process = $p.ProcessName } }
        }
    } catch { }
    return $out
}

function Get-ServiceStates {
    $out = @()
    foreach ($n in @('Audiosrv', 'AudioEndpointBuilder', 'FrameServer')) {
        try { $s = Get-Service -Name $n -ErrorAction Stop; $out += [pscustomobject]@{ Name = $n; Status = "$($s.Status)"; StartType = "$($s.StartType)" } }
        catch { $out += [pscustomobject]@{ Name = $n; Status = 'NotFound'; StartType = '' } }
    }
    return $out
}

function Test-PingHost([string]$HostName) {
    try {
        $ping = New-Object System.Net.NetworkInformation.Ping
        $times = @()
        foreach ($i in 1..3) {
            $r = $ping.Send($HostName, 1000)
            if ($r.Status -eq 'Success') { $times += [int]$r.RoundtripTime }
        }
        if ($times.Count -eq 0) { return $null }
        return [int](($times | Measure-Object -Average).Average)
    } catch { return $null }
}

function Test-DnsHost([string]$HostName) {
    try { return @([System.Net.Dns]::GetHostAddresses($HostName)).Count -gt 0 } catch { return $false }
}

function Measure-DownloadMbps([string]$Url, [int]$MaxSeconds = 15) {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.Timeout = 10000
        $req.ReadWriteTimeout = 10000
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $resp = $req.GetResponse()
        $stream = $resp.GetResponseStream()
        $buf = New-Object byte[] 65536
        $total = 0
        while ($true) {
            $n = $stream.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            $total += $n
            if ($sw.Elapsed.TotalSeconds -ge $MaxSeconds) { break }
        }
        $stream.Close(); $resp.Close()
        return ConvertTo-Mbps -Bytes $total -Seconds $sw.Elapsed.TotalSeconds
    } catch { return $null }
}

function ConvertTo-Mbps([double]$Bytes, [double]$Seconds) {
    if ($Seconds -le 0 -or $Bytes -le 0) { return $null }
    return [math]::Round($Bytes * 8 / $Seconds / 1000000, 1)
}

function Get-FreeDiskGB {
    try {
        $drive = $env:SystemDrive; if (-not $drive) { $drive = 'C:' }
        $d = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$drive'" -ErrorAction Stop
        return [math]::Round($d.FreeSpace / 1GB, 1)
    } catch { return $null }
}

function Expand-PathVars([string]$Path) { return [Environment]::ExpandEnvironmentVariables($Path) }

function Get-BrowserCacheDirs {
    # Только папки кэша. Cookies, пароли, история и закладки лежат в других файлах и сюда не попадают.
    $out = @()
    foreach ($b in $script:Browsers) {
        $root = Expand-PathVars $b.Root
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $dirs = @()
        if ($b.Kind -eq 'chromium') {
            $profiles = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' })
            foreach ($p in $profiles) { foreach ($c in $script:ChromiumCacheDirs) { $dirs += (Join-Path $p.FullName $c) } }
        } elseif ($b.Kind -eq 'opera') {
            foreach ($c in $script:ChromiumCacheDirs) { $dirs += (Join-Path $root $c) }
        } elseif ($b.Kind -eq 'firefox') {
            foreach ($p in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) { $dirs += (Join-Path $p.FullName 'cache2') }
        }
        foreach ($d in $dirs) {
            if (Test-Path -LiteralPath $d) {
                $out += [pscustomobject]@{ Browser = $b.Name; Process = $b.Process; Path = $d; SizeMB = (Get-DirSizeMB $d) }
            }
        }
    }
    return $out
}

function Get-DirSizeMB([string]$Path) {
    try {
        $sum = (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
        if ($null -eq $sum) { $sum = 0 }
        return [math]::Round($sum / 1MB, 1)
    } catch { return 0 }
}


# Громкость и «без звука» у устройств по умолчанию — через системный звук Windows (Core Audio).
# Код на C# 5: так его соберёт Windows PowerShell 5.1 без установки чего-либо.
$script:AudioApiSource = @'
using System;
using System.Runtime.InteropServices;
namespace LessonCheck {
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    class MMDeviceEnumeratorComObject { }

    [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator {
        void EnumAudioEndpoints(int dataFlow, int stateMask, out IntPtr devices);
        void GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice endpoint);
    }

    [Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice {
        void Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object iface);
        void OpenPropertyStore(int access, out IntPtr store);
        void GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        void GetState(out int state);
    }

    [Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAudioEndpointVolume {
        void RegisterControlChangeNotify(IntPtr notify);
        void UnregisterControlChangeNotify(IntPtr notify);
        void GetChannelCount(out int count);
        void SetMasterVolumeLevel(float levelDB, ref Guid context);
        void SetMasterVolumeLevelScalar(float level, ref Guid context);
        void GetMasterVolumeLevel(out float levelDB);
        void GetMasterVolumeLevelScalar(out float level);
        void SetChannelVolumeLevel(int channel, float levelDB, ref Guid context);
        void SetChannelVolumeLevelScalar(int channel, float level, ref Guid context);
        void GetChannelVolumeLevel(int channel, out float levelDB);
        void GetChannelVolumeLevelScalar(int channel, out float level);
        void SetMute([MarshalAs(UnmanagedType.Bool)] bool mute, ref Guid context);
        void GetMute([MarshalAs(UnmanagedType.Bool)] out bool mute);
    }

    public class EndpointLevel {
        public string Id;
        public bool Muted;
        public int Level;
    }

    public static class AudioApi {
        // flow: 0 = динамики/наушники, 1 = микрофон; role 0 = устройство по умолчанию (его берёт браузер)
        static IAudioEndpointVolume Open(int flow, out string id) {
            id = null;
            IMMDeviceEnumerator en = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
            IMMDevice dev = null;
            try { en.GetDefaultAudioEndpoint(flow, 0, out dev); }
            catch (COMException) { return null; }
            if (dev == null) return null;
            dev.GetId(out id);
            Guid iid = typeof(IAudioEndpointVolume).GUID;
            object o;
            dev.Activate(ref iid, 23, IntPtr.Zero, out o);
            return (IAudioEndpointVolume)o;
        }

        public static EndpointLevel Get(int flow) {
            string id;
            IAudioEndpointVolume v = Open(flow, out id);
            if (v == null) return null;
            EndpointLevel r = new EndpointLevel();
            r.Id = id;
            bool m;
            v.GetMute(out m);
            r.Muted = m;
            float l;
            v.GetMasterVolumeLevelScalar(out l);
            r.Level = (int)Math.Round(l * 100);
            return r;
        }

        public static bool Set(int flow, bool mute, int level) {
            string id;
            IAudioEndpointVolume v = Open(flow, out id);
            if (v == null) return false;
            Guid ctx = Guid.Empty;
            v.SetMasterVolumeLevelScalar(Math.Max(0, Math.Min(100, level)) / 100f, ref ctx);
            v.SetMute(mute, ref ctx);
            return true;
        }

        public static bool Fix(int flow, int minLevel) {
            string id;
            IAudioEndpointVolume v = Open(flow, out id);
            if (v == null) return false;
            Guid ctx = Guid.Empty;
            v.SetMute(false, ref ctx);
            float l;
            v.GetMasterVolumeLevelScalar(out l);
            if (l * 100 < minLevel) v.SetMasterVolumeLevelScalar(minLevel / 100f, ref ctx);
            return true;
        }
    }
}
'@
$script:AudioApiReady = $null

function Initialize-AudioApi {
    if ($null -ne $script:AudioApiReady) { return $script:AudioApiReady }
    try { Add-Type -TypeDefinition $script:AudioApiSource -Language CSharp -ErrorAction Stop; $script:AudioApiReady = $true }
    catch { $script:AudioApiReady = $false }
    return $script:AudioApiReady
}

function ConvertTo-LevelObject($x) {
    if ($null -eq $x) { return $null }
    return [pscustomobject]@{ Id = "$($x.Id)"; Muted = [bool]$x.Muted; Level = [int]$x.Level }
}

function Get-AudioLevels {
    if (-not (Initialize-AudioApi)) { return $null }
    try {
        $cap = ConvertTo-LevelObject ([LessonCheck.AudioApi]::Get(1))
        $ren = ConvertTo-LevelObject ([LessonCheck.AudioApi]::Get(0))
        return [pscustomobject]@{ Capture = $cap; Render = $ren }
    } catch { return $null }
}

function Set-AudioEndpointState([int]$Flow, [bool]$Muted, [int]$Level) {
    if (-not (Initialize-AudioApi)) { return $false }
    try { return [bool][LessonCheck.AudioApi]::Set($Flow, $Muted, $Level) } catch { return $false }
}

function Set-AudioEndpointLevel([int]$Flow, [int]$MinLevel) {
    if (-not (Initialize-AudioApi)) { return $false }
    try { return [bool][LessonCheck.AudioApi]::Fix($Flow, $MinLevel) } catch { return $false }
}

function Get-PolicyState {
    # Запрет камеры/микрофона групповой политикой (администратор, родительский контроль, школьный ПК)
    $p = @{ CameraDenied = $false; MicDenied = $false; CameraAppsDenied = $false }
    try {
        $ap = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppPrivacy' -ErrorAction Stop
        if ($null -ne $ap.LetAppsAccessCamera -and [int]$ap.LetAppsAccessCamera -eq 2) { $p.CameraAppsDenied = $true }
        if ($null -ne $ap.LetAppsAccessMicrophone -and [int]$ap.LetAppsAccessMicrophone -eq 2) { $p.MicDenied = $true }
    } catch { }
    try {
        $c = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Camera' -ErrorAction Stop
        if ($null -ne $c.AllowCamera -and [int]$c.AllowCamera -eq 0) { $p.CameraDenied = $true }
    } catch { }
    return [pscustomobject]$p
}

function Get-AntivirusNames {
    try {
        return @(Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName AntiVirusProduct -OperationTimeoutSec 5 -ErrorAction Stop |
            ForEach-Object { "$($_.displayName)" } | Where-Object { $_ } | Select-Object -Unique)
    } catch { return @() }
}

function ConvertTo-SkewSeconds([string]$HttpDate, [datetime]$LocalUtc, [string]$Age = '') {
    # Age — сколько секунд ответ пролежал в кэше по дороге: настоящее время сервера = Date + Age
    if (-not $HttpDate) { return $null }
    try {
        $styles = [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal
        $server = [DateTime]::ParseExact($HttpDate, 'r', [Globalization.CultureInfo]::InvariantCulture, $styles)
        $ageSec = 0
        if ("$Age" -match '^\s*(\d+)\s*$') { $ageSec = [int]$matches[1] }
        return [int][math]::Round(($LocalUtc - $server.AddSeconds($ageSec)).TotalSeconds)
    } catch { return $null }
}

function Resolve-Skew($Skews, [bool]$RequireAll = $false) {
    # Несколько источников должны совпасть (до минуты). Разошлись — не верим ни одному: прокси или страница входа
    # в общественный Wi-Fi может отдать своё время.
    $vals = @(@($Skews) | Where-Object { $null -ne $_ })
    if ($vals.Count -eq 0) { return $null }
    if ($RequireAll -and $vals.Count -lt @($Skews).Count) { return $null }
    $min = ($vals | Measure-Object -Minimum).Minimum; $max = ($vals | Measure-Object -Maximum).Maximum
    if (($max - $min) -gt 60) { return $null }
    return [int][math]::Round(($vals | Measure-Object -Average).Average)
}

function Get-HttpSkew([string]$Url) {
    try {
        $req = [System.Net.HttpWebRequest]::Create($Url)
        $req.Timeout = 4000
        $req.ReadWriteTimeout = 4000
        $req.AllowAutoRedirect = $false
        $req.Headers.Add('Cache-Control', 'no-cache')
        $resp = $req.GetResponse()
        $date = $resp.Headers['Date']; $age = $resp.Headers['Age']
        $resp.Close()
        return ConvertTo-SkewSeconds $date ([DateTime]::UtcNow) $age
    } catch { return $null }
}

function Get-ClockSkewSeconds([bool]$RequireAll = $false) {
    # Часы сравниваем с заголовком Date обычных http-серверов: https при сбитых часах как раз может не работать
    return Resolve-Skew @($script:TimeUrls | ForEach-Object { Get-HttpSkew $_ }) $RequireAll
}

function Get-ProxyState {
    try {
        $p = Get-ItemProperty -Path $script:InetKey -ErrorAction Stop
        return [pscustomobject]@{ Enabled = ($null -ne $p.ProxyEnable -and [int]$p.ProxyEnable -eq 1); Server = "$($p.ProxyServer)"; Pac = "$($p.AutoConfigURL)" }
    } catch { return $null }
}

function Get-NetworkInterfacesRaw {
    try {
        return @([System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
            ForEach-Object { [pscustomobject]@{ Status = "$($_.OperationalStatus)"; Type = "$($_.NetworkInterfaceType)"; Description = "$($_.Description)"; Name = "$($_.Name)" } })
    } catch { return @() }
}

function Get-WifiSignal {
    try { return ConvertFrom-WlanOutput (& netsh wlan show interfaces 2>$null | Out-String) } catch { return $null }
}

function Get-RebootState {
    $pending = $false
    foreach ($k in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired',
                     'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')) {
        if (Test-Path -Path $k) { $pending = $true }
    }
    $days = $null
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $days = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalDays, 1)
    } catch { }
    return [pscustomobject]@{ Pending = $pending; UptimeDays = $days }
}

function Get-ProcessCpuSample {
    try {
        return @(Get-Process -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{ Id = $_.Id; Name = $_.ProcessName; Cpu = [double]$_.CPU; MemMB = [math]::Round($_.WorkingSet64 / 1MB) } })
    } catch { return @() }
}

function Get-LoadState {
    $a = Get-ProcessCpuSample
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Start-Sleep -Milliseconds 1500
    $b = Get-ProcessCpuSample
    $sec = $sw.Elapsed.TotalSeconds
    $total = $null; $free = $null; $sys = $null
    try { $sys = [int](@(Get-CimInstance Win32_Processor -OperationTimeoutSec 5 -ErrorAction Stop | Measure-Object -Property LoadPercentage -Average).Average) } catch { }
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $total = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
        $free = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
    } catch { }
    return Measure-Load $a $b $sec ([Environment]::ProcessorCount) $total $free $sys
}

function Get-OsVersion {
    try { return "$((Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).Version)" } catch { return "$([Environment]::OSVersion.Version)" }
}

function Get-BrowserVersions {
    $cands = @(
        @{ Key = 'chrome';  Name = 'Chrome';  Paths = @('%ProgramFiles%\Google\Chrome\Application\chrome.exe', '%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe', '%LOCALAPPDATA%\Google\Chrome\Application\chrome.exe') },
        @{ Key = 'msedge';  Name = 'Edge';    Paths = @('%ProgramFiles(x86)%\Microsoft\Edge\Application\msedge.exe', '%ProgramFiles%\Microsoft\Edge\Application\msedge.exe') },
        @{ Key = 'browser'; Name = 'Яндекс Браузер'; Paths = @('%LOCALAPPDATA%\Yandex\YandexBrowser\Application\browser.exe', '%ProgramFiles(x86)%\Yandex\YandexBrowser\Application\browser.exe', '%ProgramFiles%\Yandex\YandexBrowser\Application\browser.exe') },
        @{ Key = 'opera';   Name = 'Opera';   Paths = @('%LOCALAPPDATA%\Programs\Opera\opera.exe') },
        @{ Key = 'firefox'; Name = 'Firefox'; Paths = @('%ProgramFiles%\Mozilla Firefox\firefox.exe', '%ProgramFiles(x86)%\Mozilla Firefox\firefox.exe') }
    )
    $out = @()
    foreach ($c in $cands) {
        foreach ($p in $c.Paths) {
            $full = Expand-PathVars $p
            if ($full -match '%') { continue }
            if (Test-Path -LiteralPath $full) {
                $v = ''
                try { $v = "$((Get-Item -LiteralPath $full -ErrorAction Stop).VersionInfo.ProductVersion)" } catch { }
                $out += [pscustomobject]@{ Key = $c.Key; Name = $c.Name; Version = $v }
                break
            }
        }
    }
    return $out
}

# Разбор JSON-настроек браузера по позициям: найти запись и вырезать только её, остальной файл — байт в байт.
$script:JsonSpanSource = @'
using System;
using System.Collections.Generic;
namespace LessonCheck.Json {
    public class Member {
        public string Key;
        public int MemberStart;
        public int ValueStart;
        public int ValueEnd;
    }

    public static class JsonSpan {
        static int Ws(string s, int i) {
            while (i < s.Length && (s[i] == ' ' || s[i] == '\t' || s[i] == '\r' || s[i] == '\n')) i++;
            return i;
        }

        static int SkipString(string s, int i) {
            i++;
            while (i < s.Length) {
                char c = s[i];
                if (c == '\\') { i += 2; continue; }
                if (c == '"') return i + 1;
                i++;
            }
            throw new FormatException("unterminated string");
        }

        public static int SkipValue(string s, int i) {
            i = Ws(s, i);
            if (i >= s.Length) throw new FormatException("unexpected end");
            char c = s[i];
            if (c == '"') return SkipString(s, i);
            if (c == '{' || c == '[') {
                bool isObj = c == '{';
                char close = isObj ? '}' : ']';
                i = Ws(s, i + 1);
                if (i < s.Length && s[i] == close) return i + 1;
                while (true) {
                    if (isObj) {
                        i = Ws(s, i);
                        if (i >= s.Length || s[i] != '"') throw new FormatException("key expected at " + i);
                        i = Ws(s, SkipString(s, i));
                        if (i >= s.Length || s[i] != ':') throw new FormatException("colon expected at " + i);
                        i++;
                    }
                    i = Ws(s, SkipValue(s, i));
                    if (i >= s.Length) throw new FormatException("unexpected end");
                    if (s[i] == ',') { i++; continue; }
                    if (s[i] == close) return i + 1;
                    throw new FormatException("unexpected char at " + i);
                }
            }
            int j = i;
            while (j < s.Length && ",}] \t\r\n".IndexOf(s[j]) < 0) j++;
            if (j == i) throw new FormatException("value expected at " + i);
            return j;
        }

        public static List<Member> Members(string s, int objStart) {
            List<Member> list = new List<Member>();
            int i = Ws(s, objStart);
            if (i >= s.Length || s[i] != '{') throw new FormatException("object expected at " + i);
            i = Ws(s, i + 1);
            if (i < s.Length && s[i] == '}') return list;
            while (true) {
                i = Ws(s, i);
                int ms = i;
                if (i >= s.Length || s[i] != '"') throw new FormatException("key expected at " + i);
                int ke = SkipString(s, i);
                string key = s.Substring(i + 1, ke - i - 2);
                i = Ws(s, ke);
                if (i >= s.Length || s[i] != ':') throw new FormatException("colon expected at " + i);
                int vs = Ws(s, i + 1);
                int ve = SkipValue(s, vs);
                Member m = new Member();
                m.Key = key; m.MemberStart = ms; m.ValueStart = vs; m.ValueEnd = ve;
                list.Add(m);
                i = Ws(s, ve);
                if (i >= s.Length) throw new FormatException("unexpected end");
                if (s[i] == ',') { i++; continue; }
                if (s[i] == '}') return list;
                throw new FormatException("unexpected char at " + i);
            }
        }

        public static int Find(string s, int objStart, string key) {
            foreach (Member m in Members(s, objStart)) { if (m.Key == key) return m.ValueStart; }
            return -1;
        }

        public static int PathTo(string s, string[] path) {
            int at = Ws(s, 0);
            foreach (string k in path) {
                if (at >= s.Length || s[at] != '{') return -1;
                at = Find(s, at, k);
                if (at < 0) return -1;
            }
            if (at >= s.Length || s[at] != '{') return -1;
            return at;
        }

        public static string Remove(string s, int objStart, string key) {
            List<Member> ms = Members(s, objStart);
            for (int n = 0; n < ms.Count; n++) {
                if (ms[n].Key != key) continue;
                int from, to;
                if (n > 0) { from = ms[n - 1].ValueEnd; to = ms[n].ValueEnd; }
                else if (ms.Count > 1) { from = ms[n].MemberStart; to = ms[n + 1].MemberStart; }
                else { from = ms[n].MemberStart; to = ms[n].ValueEnd; }
                return s.Substring(0, from) + s.Substring(to);
            }
            return null;
        }

        public static string Insert(string s, int objStart, string key, string valueJson) {
            int i = Ws(s, objStart);
            List<Member> ms = Members(s, i);
            string member = "\"" + key + "\":" + valueJson;
            if (ms.Count == 0) { int close = Ws(s, i + 1); return s.Substring(0, i + 1) + member + s.Substring(close); }
            return s.Substring(0, ms[0].MemberStart) + member + "," + s.Substring(ms[0].MemberStart);
        }

        public static bool IsValid(string s) {
            try { int e = SkipValue(s, 0); return Ws(s, e) == s.Length; }
            catch (Exception) { return false; }
        }
    }
}
'@

# Запись с микрофона по умолчанию через стандартный звук Windows (winmm), без установки чего-либо
$script:MicSource = @'
using System;
using System.Runtime.InteropServices;
using System.Text;
namespace LessonCheck.Mic {
    public static class Recorder {
        [DllImport("winmm.dll", EntryPoint = "mciSendStringW", CharSet = CharSet.Unicode)]
        static extern int mciSendString(string command, StringBuilder buffer, int bufferSize, IntPtr callback);

        [DllImport("winmm.dll", EntryPoint = "mciGetErrorStringW", CharSet = CharSet.Unicode)]
        static extern bool mciGetErrorString(int error, StringBuilder buffer, int bufferSize);

        static string Err(int code) {
            StringBuilder sb = new StringBuilder(256);
            mciGetErrorString(code, sb, sb.Capacity);
            return "MCI " + code + ": " + sb.ToString();
        }

        public static string Record(string path, int ms) {
            int r = mciSendString("open new type waveaudio alias lcrec", null, 0, IntPtr.Zero);
            if (r != 0) return Err(r);
            try {
                mciSendString("set lcrec time format ms bitspersample 16 channels 1 samplespersec 16000 bytespersec 32000 alignment 2", null, 0, IntPtr.Zero);
                r = mciSendString("record lcrec", null, 0, IntPtr.Zero);
                if (r != 0) return Err(r);
                System.Threading.Thread.Sleep(ms);
                mciSendString("stop lcrec", null, 0, IntPtr.Zero);
                r = mciSendString("save lcrec \"" + path + "\"", null, 0, IntPtr.Zero);
                if (r != 0) return Err(r);
                return null;
            } finally {
                mciSendString("close lcrec", null, 0, IntPtr.Zero);
            }
        }
    }
}
'@
$script:JsonReady = $null
$script:MicReady = $null

function Initialize-JsonSpan {
    if ($null -ne $script:JsonReady) { return $script:JsonReady }
    try { Add-Type -TypeDefinition $script:JsonSpanSource -Language CSharp -ErrorAction Stop; $script:JsonReady = $true } catch { $script:JsonReady = $false }
    return $script:JsonReady
}

function Initialize-MicApi {
    if ($null -ne $script:MicReady) { return $script:MicReady }
    try { Add-Type -TypeDefinition $script:MicSource -Language CSharp -ErrorAction Stop; $script:MicReady = $true } catch { $script:MicReady = $false }
    return $script:MicReady
}

# ============================================================ разбор (без побочных эффектов)

function Select-VpnNames($Interfaces) {
    $pattern = 'VPN|TAP-Windows|Wintun|WireGuard|OpenVPN|Proton|NordLynx|Hotspot Shield|Cloudflare WARP|Outline|Psiphon|AdGuard|Kaspersky Secure Connection'
    return @(@($Interfaces) | Where-Object { $null -ne $_ -and $_.Status -eq 'Up' -and "$($_.Description) $($_.Name)" -match $pattern } |
        ForEach-Object { if ($_.Description) { $_.Description } else { $_.Name } } | Select-Object -Unique)
}

function ConvertFrom-WlanOutput([string]$Text) {
    # Строка «Сигнал : 72%» / «Signal : 72%» — единственная с процентом, поэтому язык и кодировка не важны
    if (-not $Text) { return $null }
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match ':\s*(\d{1,3})\s*%\s*$') { return [int]$matches[1] }
    }
    return $null
}

function Measure-Load($Before, $After, [double]$Seconds, [int]$Cores, $TotalGB, $FreeGB, $SystemPct = $null) {
    $skip = @('Idle', 'System', 'powershell', 'pwsh', 'conhost')
    $prev = @{}
    foreach ($p in @($Before)) { if ($null -ne $p) { $prev[$p.Id] = $p.Cpu } }
    $byName = @{}; $mem = @{}
    foreach ($p in @($After)) {
        if ($null -eq $p -or $skip -contains $p.Name) { continue }
        $pct = 0.0
        if ($prev.ContainsKey($p.Id) -and $Seconds -gt 0) { $pct = ($p.Cpu - $prev[$p.Id]) / $Seconds / [math]::Max(1, $Cores) * 100 }
        if ($pct -lt 0) { $pct = 0 }
        if (-not $byName.ContainsKey($p.Name)) { $byName[$p.Name] = 0.0; $mem[$p.Name] = 0 }
        $byName[$p.Name] += $pct; $mem[$p.Name] += $p.MemMB
    }
    $cpu = [int][math]::Round((@($byName.Values) | Measure-Object -Sum).Sum)
    if ($null -ne $SystemPct) { $cpu = [int]$SystemPct }   # Windows видит и системные процессы, которых не видно без прав
    $topCpu = @($byName.GetEnumerator() | Where-Object { $_.Value -ge 5 } | Sort-Object -Property Value -Descending | Select-Object -First 3 | ForEach-Object { $_.Key })
    $topMem = @($mem.GetEnumerator() | Sort-Object -Property Value -Descending | Select-Object -First 3 | ForEach-Object { $_.Key })
    return [pscustomobject]@{ CpuPct = $cpu; TopCpu = $topCpu; TopMem = $topMem; TotalGB = $TotalGB; FreeGB = $FreeGB }
}

function Get-MajorVersion([string]$Version) {
    if ("$Version" -match '^\s*(\d+)') { return [int]$matches[1] }
    return $null
}

function Get-OldBrowsers($Browsers) {
    $out = @()
    foreach ($b in @($Browsers)) {
        if ($null -eq $b) { continue }
        $major = Get-MajorVersion $b.Version
        $min = $script:MinBrowserMajor[$b.Key]
        if ($null -ne $major -and $null -ne $min -and $major -lt $min) { $out += "$($b.Name) $major" }
    }
    return $out
}

function Get-AudioResetTargets($State) {
    # Что чинить в звуке: звуковые карты с ошибкой (не аудио монитора — его часто отключают нарочно, иначе звук
    # уходит в монитор без колонок) и отключённые в Windows микрофоны/динамики, если работающих нет.
    $audio = @(@($State.Audio) | Where-Object { $null -ne $_ })
    $okRender = @($audio | Where-Object { "$($_.Id)" -match '\{0\.0\.0\.' -and $_.Code -eq 0 }).Count
    $okCapture = @($audio | Where-Object { "$($_.Id)" -match '\{0\.0\.1\.' -and $_.Code -eq 0 }).Count
    $out = @()
    foreach ($c in @(@($State.SoundCards) | Where-Object { $null -ne $_ -and $_.Code -ne 0 -and $_.Code -ne 45 })) {
        if ($c.Name -match $script:DisplayAudioPattern) { continue }
        if ($c.Code -eq 22 -and $okRender -gt 0 -and $okCapture -gt 0) { continue }
        $out += $c
    }
    foreach ($e in @($audio | Where-Object { $_.Code -eq 22 })) {
        $isCap = "$($e.Id)" -match '\{0\.0\.1\.'
        if (($isCap -and $okCapture -eq 0) -or (-not $isCap -and $okRender -eq 0)) { $out += $e }
    }
    return $out
}

function Get-EndpointName([string]$EndpointId, $Audio) {
    if (-not $EndpointId) { return 'устройство по умолчанию' }
    foreach ($a in @($Audio)) {
        if ($null -ne $a -and "$($a.Id)".ToUpperInvariant().EndsWith($EndpointId.ToUpperInvariant())) { return $a.Name }
    }
    return 'устройство по умолчанию'
}

function Test-LessonDevice($Device) {
    # Влияет ли устройство на урок: сеть, Wi-Fi, Bluetooth (наушники), USB (камера/гарнитура), камера, звук
    if (@('Net', 'Bluetooth', 'USB') -contains "$($Device.Class)") { return $true }
    return "$($Device.Name)" -match $script:LessonDevicePattern
}

function Format-DeviceList($Devices, [int]$Max) {
    # Одинаковые устройства — одной записью: «Неизвестное устройство ×9 (нет драйвера)»
    $groups = @(@($Devices) | ForEach-Object {
        $n = "$($_.Name)"; if (-not $n) { $n = 'Неизвестное устройство' }
        [pscustomobject]@{ Key = "$n ($(Get-ErrorCodeText $_.Code))"; Name = $n; Why = (Get-ErrorCodeText $_.Code) }
    } | Group-Object -Property Key | Sort-Object -Property @{ Expression = 'Count'; Descending = $true }, @{ Expression = 'Name'; Descending = $false })
    $parts = @($groups | Select-Object -First $Max | ForEach-Object {
        $g = $_.Group[0]
        if ($_.Count -gt 1) { "$($g.Name) ×$($_.Count) ($($g.Why))" } else { "$($g.Name) ($($g.Why))" }
    })
    $text = $parts -join '; '
    if ($groups.Count -gt $Max) {
        $rest = (@($groups | Select-Object -Skip $Max) | Measure-Object -Property Count -Sum).Sum
        $text += "; и ещё $rest"
    }
    return $text
}

function Format-Wrapped([string]$Text, [int]$Width, [string]$Indent) {
    # Переносим по словам, чтобы консоль не рвала слово на краю окна
    if ($Width -lt 20) { $Width = 20 }
    $lines = @(); $line = ''
    foreach ($w in ($Text -split ' ')) {
        if ($line -eq '') { $line = $w; continue }
        if (($line.Length + 1 + $w.Length) -gt $Width) { $lines += $line; $line = $Indent + $w }
        else { $line += ' ' + $w }
    }
    if ($line -ne '') { $lines += $line }
    return $lines
}

function Get-ErrorCodeText([int]$Code) {
    switch ($Code) {
        1  { return 'нет драйвера' }
        28 { return 'нет драйвера' }
        10 { return 'не запускается' }
        22 { return 'отключено' }
        43 { return 'сообщило об ошибке' }
        default { return "ошибка, код $Code" }
    }
}

function Format-Skew([int]$Seconds) {
    $abs = [math]::Abs($Seconds)
    $dir = 'спешат'; if ($Seconds -lt 0) { $dir = 'отстают' }
    if ($abs -ge 86400) { $txt = "$([math]::Round($abs / 86400, 0)) дн." }
    elseif ($abs -ge 3600) { $txt = "$([math]::Round($abs / 3600, 0)) ч" }
    else { $txt = "$([math]::Round($abs / 60, 0)) мин" }
    return "$txt ($dir)"
}

function ConvertFrom-ConsentKey([string]$Key) {
    # «C:#Program Files#Zoom#bin#Zoom.exe» → «Zoom.exe»; пакетные приложения: «Microsoft.SkypeApp_kzf8qxf38zg5c» → «Microsoft.SkypeApp»
    if ($Key -match '#') { return ($Key -split '#')[-1] }
    return ($Key -split '_')[0]
}

function Get-AppsHoldingDevice($UsageKeys) {
    # Запись с началом, но без конца использования = программа держит устройство прямо сейчас
    $names = @()
    foreach ($u in @($UsageKeys)) {
        if ($null -eq $u) { continue }
        if ($u.Start -gt 0 -and $u.Stop -eq 0) { $names += (ConvertFrom-ConsentKey $u.Key) }
    }
    return @($names | Select-Object -Unique)
}

function Test-IsBrowserName([string]$Name) {
    return $Name -match '^(chrome|msedge|browser|opera|firefox|yandex)(\.exe)?$'
}

function Get-HolderProcesses([string]$Holder, $State) {
    # Какие запущенные процессы стоят за записью «держит камеру». Нет процесса — запись устарела (программа упала).
    if ($Holder -match '\.exe$') {
        $n = $Holder -replace '\.exe$', ''
        if (@($State.Processes) -contains $n) { return @($n) }
        return @()
    }
    return @(@($State.PackagedProcs) | Where-Object { $null -ne $_ -and $_.Package -eq $Holder } | ForEach-Object { $_.Process } | Select-Object -Unique)
}

function Get-ActiveHolders($Holders, $State) {
    return @(@($Holders) | Where-Object { $_ -and -not (Test-IsBrowserName $_) -and @(Get-HolderProcesses $_ $State).Count -gt 0 })
}

function Get-HolderTitle([string]$Holder) {
    $known = @{ 'Microsoft.WindowsCamera' = 'Камера Windows'; 'Microsoft.SkypeApp' = 'Skype'; 'MSTeams' = 'Teams'; 'Microsoft.WindowsSoundRecorder' = 'Запись голоса' }
    if ($known.ContainsKey($Holder)) { return $known[$Holder] }
    return $Holder
}

function Select-RealCameras($Devices) {
    # Обычные камеры. Не считаем: сканеры (тоже класс Image) и ИК-камеры Windows Hello — их часто отключают нарочно.
    return @(@($Devices) | Where-Object {
        $null -ne $_ -and $_.Code -ne 45 -and
        $_.Name -notmatch '(\bIR\b|Infrared|ИК-)' -and
        -not ("$($_.Class)" -eq 'Image' -and "$($_.Service)" -ne 'usbvideo' -and $_.Name -notmatch '(cam|камер)')
    })
}

function Get-State([switch]$Light, $Reuse = $null) {
    # Собирает всё в один объект — его же разбирает Get-Findings и печатает Format-Report.
    # -Light: без интернета и кэша (для быстрого исправления от администратора)
    $script:DeviceQueryFailed = $false
    $usageCam = Get-ConsentUsageKeys 'webcam'
    $usageMic = Get-ConsentUsageKeys 'microphone'
    $ping = @{}; $dns = @{}; $speed = $null; $cache = @(); $skew = $null; $wifi = $null; $load = $null
    if ($null -ne $Reuse) {
        # повторная проверка после исправлений, сеть не трогали: интернет и нагрузку не меряем заново
        $ping = $Reuse.Ping; $dns = $Reuse.Dns; $speed = $Reuse.SpeedMbps; $wifi = $Reuse.WifiSignal; $load = $Reuse.Load; $skew = $Reuse.ClockSkew
        $cache = @(Get-BrowserCacheDirs)
    } elseif (-not $Light) {
        $skew = Get-ClockSkewSeconds
        $wifi = Get-WifiSignal
        $load = Get-LoadState
        foreach ($h in $script:PingHosts) { $ping[$h] = Test-PingHost $h }
        foreach ($h in $script:DnsHosts)  { $dns[$h] = Test-DnsHost $h }
        $anyPing = @($ping.Values | Where-Object { $null -ne $_ })
        if ($anyPing.Count -gt 0 -or @($dns.Values | Where-Object { $_ }).Count -gt 0) { $speed = Measure-DownloadMbps $script:SpeedUrl }
        $cache = @(Get-BrowserCacheDirs)
    }
    $pnp = @(Get-PnpSnapshot)
    $cams = @(Select-PnpClass $pnp @('Camera', 'Image'))
    $audio = @(Select-PnpClass $pnp @('AudioEndpoint'))
    $cards = @(Select-PnpClass $pnp @('MEDIA'))
    $bt = @(Select-PnpClass $pnp @('Bluetooth'))
    $blocks = @()
    if (-not $Light) { $blocks = @(Get-BrowserSiteBlocks) }
    return [pscustomobject]@{
        Time        = Get-Date
        Os          = Get-OsInfo
        IsAdmin     = Test-IsAdmin
        Cameras     = $cams
        Audio       = $audio
        DeviceQueryFailed = [bool]$script:DeviceQueryFailed
        SoundCards  = $cards
        ProblemDevices = @(@($pnp) | Where-Object { $_.Code -ne 0 -and $_.Code -ne 45 })
        AudioLevels = Get-AudioLevels
        Policy      = Get-PolicyState
        Antivirus   = @(Get-AntivirusNames)
        ClockSkew   = $skew
        Proxy       = Get-ProxyState
        Vpn         = @(Select-VpnNames (Get-NetworkInterfacesRaw))
        WifiSignal  = $wifi
        Reboot      = Get-RebootState
        Load        = $load
        OsVersion   = Get-OsVersion
        Browsers    = @(Get-BrowserVersions)
        CamConsent  = @{ User = (Get-ConsentValue 'HKCU' 'webcam'); Desktop = (Get-ConsentValue 'HKCU' 'webcam' 'NonPackaged'); Machine = (Get-ConsentValue 'HKLM' 'webcam') }
        MicConsent  = @{ User = (Get-ConsentValue 'HKCU' 'microphone'); Desktop = (Get-ConsentValue 'HKCU' 'microphone' 'NonPackaged'); Machine = (Get-ConsentValue 'HKLM' 'microphone') }
        CamHolders  = @(Get-AppsHoldingDevice $usageCam)
        MicHolders  = @(Get-AppsHoldingDevice $usageMic)
        Processes   = @(Get-RunningProcessNames)
        PackagedProcs = @(Get-PackagedProcesses)
        Services    = @(Get-ServiceStates)
        Ping        = $ping
        Dns         = $dns
        SpeedMbps   = $speed
        FreeDiskGB  = Get-FreeDiskGB
        CacheDirs   = $cache
        Bluetooth   = $bt
        SiteBlocks  = $blocks
    }
}

function New-Finding([string]$Level, [string]$Area, [string]$Text, [string]$Fix = '', [string]$Hint = '') {
    return [pscustomobject]@{ Level = $Level; Area = $Area; Text = $Text; Fix = $Fix; Hint = $Hint }
}

function Test-ConsentDenied($Consent) {
    foreach ($k in @('User', 'Desktop', 'Machine')) { if ("$($Consent[$k])" -eq 'Deny') { return $true } }
    return $false
}

function Get-Findings($State) {
    $f = New-Object System.Collections.Generic.List[object]

    # --- камера
    $queryFailed = [bool]$State.DeviceQueryFailed
    $cams = @(Select-RealCameras $State.Cameras)
    $working = @($cams | Where-Object { $_.Code -eq 0 })
    $disabled = @($cams | Where-Object { $_.Code -eq 22 })
    $broken = @($cams | Where-Object { $_.Code -ne 0 -and $_.Code -ne 22 })
    if ($queryFailed) {
        $f.Add((New-Finding 'WARN' 'Устройства' 'Не удалось получить список устройств Windows (WMI) — камеру и звук проверьте вручную в диспетчере устройств'))
    } elseif ($cams.Count -eq 0) {
        $f.Add((New-Finding 'BAD' 'Камера' 'Windows не видит ни одной камеры' '' 'Проверьте шнур/USB-порт; на ноутбуке — шторку камеры или клавишу с камерой (часто F6/F8/F10 или Fn+…)'))
    } else {
        $lvl = 'BAD'; $prefix = 'Камера'
        if ($working.Count -gt 0) {
            $f.Add((New-Finding 'OK' 'Камера' ("Найдена: " + (($working | ForEach-Object { $_.Name }) -join ', '))))
            $lvl = 'WARN'; $prefix = 'Ещё одна камера'
        }
        if ($disabled.Count -gt 0) {
            $f.Add((New-Finding $lvl 'Камера' ("$prefix отключена в диспетчере устройств: " + (($disabled | ForEach-Object { $_.Name }) -join ', ')) 'reset-camera'))
        } elseif ($broken.Count -gt 0) {
            $f.Add((New-Finding $lvl 'Камера' ("$prefix с ошибкой драйвера (код $($broken[0].Code)): " + (($broken | ForEach-Object { $_.Name }) -join ', ')) 'reset-camera'))
        }
    }
    if ($State.Policy -and $State.Policy.CameraDenied) {
        $f.Add((New-Finding 'BAD' 'Камера' 'Камера запрещена политикой Windows (настроил администратор, родительский контроль или школа)' '' 'Программой это не снять: попросите того, кто управляет компьютером, разрешить камеру'))
    } elseif ($State.Policy -and $State.Policy.CameraAppsDenied) {
        $f.Add((New-Finding 'WARN' 'Камера' 'Политика Windows запрещает приложениям камеру (настроил администратор или родительский контроль) — браузер это может тоже задеть' '' 'Если камера не работает — попросите того, кто управляет компьютером, снять запрет'))
    }
    $fsvc = @(@($State.Services) | Where-Object { $_.Name -eq 'FrameServer' })
    if ($fsvc.Count -gt 0 -and $fsvc[0].StartType -eq 'Disabled') {
        $f.Add((New-Finding 'BAD' 'Камера' 'Отключена служба камеры Windows (Windows Camera Frame Server)' 'enable-camera-service'))
    }
    if (Test-ConsentDenied $State.CamConsent) {
        $f.Add((New-Finding 'BAD' 'Камера' 'В настройках конфиденциальности Windows запрещён доступ к камере' 'allow-camera'))
    }
    $camHold = @(Get-ActiveHolders $State.CamHolders $State)
    if ($camHold.Count -gt 0) {
        $f.Add((New-Finding 'WARN' 'Камера' ("Камеру сейчас держит другая программа: " + (($camHold | ForEach-Object { Get-HolderTitle $_ }) -join ', ')) 'close-apps'))
    }

    # --- микрофон и звук
    $audio = @($State.Audio)
    $render = @($audio | Where-Object { "$($_.Id)" -match '\{0\.0\.0\.' })
    $capture = @($audio | Where-Object { "$($_.Id)" -match '\{0\.0\.1\.' })
    $okCapture = @($capture | Where-Object { $_.Code -eq 0 })
    if ($queryFailed) {
    } elseif ($audio.Count -eq 0) {
        $f.Add((New-Finding 'BAD' 'Звук' 'Windows не видит ни одного устройства звука (динамики, наушники, микрофон)' 'restart-audio' 'Проверьте, подключены ли наушники/колонки и включён ли звук'))
    } elseif ($render.Count + $capture.Count -eq 0) {
        $f.Add((New-Finding 'OK' 'Звук' ("Устройства: " + (($audio | ForEach-Object { $_.Name }) -join ', '))))
    } else {
        $okRender = @($render | Where-Object { $_.Code -eq 0 })
        if ($okCapture.Count -gt 0) {
            $f.Add((New-Finding 'OK' 'Микрофон' ("Найден: " + (($okCapture | ForEach-Object { $_.Name }) -join ', '))))
        } elseif (@($capture | Where-Object { $_.Code -eq 22 }).Count -gt 0) {
            $f.Add((New-Finding 'BAD' 'Микрофон' ("Микрофон отключён в Windows: " + ((@($capture | Where-Object { $_.Code -eq 22 }) | ForEach-Object { $_.Name }) -join ', ')) 'reset-audio-device'))
        } else {
            $f.Add((New-Finding 'BAD' 'Микрофон' 'Windows не видит микрофон' '' 'Подключите наушники с микрофоном (у многих ПК своего микрофона нет); проверьте разъём (розовый) или USB'))
        }
        if ($okRender.Count -gt 0) {
            $f.Add((New-Finding 'OK' 'Звук' ("Динамики/наушники: " + (($okRender | ForEach-Object { $_.Name }) -join ', '))))
        } elseif (@($render | Where-Object { $_.Code -eq 22 }).Count -gt 0) {
            $f.Add((New-Finding 'BAD' 'Звук' ("Динамики/наушники отключены в Windows: " + ((@($render | Where-Object { $_.Code -eq 22 }) | ForEach-Object { $_.Name }) -join ', ')) 'reset-audio-device'))
        } else {
            $f.Add((New-Finding 'BAD' 'Звук' 'Windows не видит динамики или наушники' 'restart-audio' 'Подключите наушники или колонки'))
        }
    }
    $badCards = @(Get-AudioResetTargets $State | Where-Object { "$($_.Class)" -eq 'MEDIA' })
    if (-not $queryFailed -and $badCards.Count -gt 0) {
        $f.Add((New-Finding 'BAD' 'Звук' ("Ошибка драйвера звука ($(Get-ErrorCodeText $badCards[0].Code)): " + (($badCards | ForEach-Object { $_.Name }) -join ', ')) 'reset-audio-device' 'Если перезапуск не поможет — установите драйвер звука с сайта производителя ноутбука или материнской платы'))
    }
    $lv = $State.AudioLevels
    if ($null -ne $lv) {
        if ($null -ne $lv.Capture) {
            $micName = Get-EndpointName $lv.Capture.Id $audio
            if ($lv.Capture.Muted) {
                $f.Add((New-Finding 'BAD' 'Микрофон' "Микрофон выключен в Windows («без звука»): $micName" 'unmute-audio'))
            } elseif ($lv.Capture.Level -lt 25) {
                $f.Add((New-Finding 'WARN' 'Микрофон' "Громкость микрофона в Windows всего $($lv.Capture.Level)%: $micName" 'unmute-audio'))
            }
            if ($micName -match $script:VirtualMicPattern) {
                $f.Add((New-Finding 'WARN' 'Микрофон' "По умолчанию выбран не обычный микрофон: $micName" '' 'Пуск → Параметры → Система → Звук → Ввод: выберите микрофон наушников или ноутбука (виртуальный работает, только пока запущена его программа)'))
            }
        } elseif ($okCapture.Count -gt 0) {
            $f.Add((New-Finding 'WARN' 'Микрофон' 'Микрофон по умолчанию не выбран' '' 'Пуск → Параметры → Система → Звук → Ввод: выберите микрофон'))
        }
        if ($null -ne $lv.Render) {
            $spkName = Get-EndpointName $lv.Render.Id $audio
            if ($lv.Render.Muted) {
                $f.Add((New-Finding 'BAD' 'Звук' "Звук выключен в Windows («без звука»): $spkName" 'unmute-audio'))
            } elseif ($lv.Render.Level -lt 15) {
                $f.Add((New-Finding 'WARN' 'Звук' "Громкость в Windows всего $($lv.Render.Level)%: $spkName" 'unmute-audio'))
            }
            if ($spkName -match $script:HandsFreePattern) {
                $f.Add((New-Finding 'WARN' 'Звук' "Bluetooth-гарнитура в режиме разговора (Hands-Free): $spkName — звук будет глухим" '' 'Если микрофон берёте из ноутбука: Параметры → Система → Звук → Вывод → «Наушники (… Stereo)». Если нужен микрофон гарнитуры — так и работает, но лучше проводная гарнитура'))
            }
        }
    }
    if ($null -ne $lv) {
        $okLevels = @()
        if ($null -ne $lv.Capture -and -not $lv.Capture.Muted -and $lv.Capture.Level -ge 25) { $okLevels += "микрофон $($lv.Capture.Level)%" }
        if ($null -ne $lv.Render -and -not $lv.Render.Muted -and $lv.Render.Level -ge 15) { $okLevels += "звук $($lv.Render.Level)%" }
        if ($okLevels.Count -gt 0) { $f.Add((New-Finding 'OK' 'Звук' "Громкость в Windows: $($okLevels -join ', ')")) }
    }
    if ($State.Policy -and $State.Policy.MicDenied) {
        $f.Add((New-Finding 'WARN' 'Микрофон' 'Политика Windows запрещает приложениям микрофон (настроил администратор, родительский контроль или школа) — браузер это может тоже задеть' '' 'Программой это не снять: если микрофон не работает — попросите того, кто управляет компьютером, снять запрет'))
    }
    if (Test-ConsentDenied $State.MicConsent) {
        $f.Add((New-Finding 'BAD' 'Микрофон' 'В настройках конфиденциальности Windows запрещён доступ к микрофону' 'allow-mic'))
    }
    $micHold = @(Get-ActiveHolders $State.MicHolders $State)
    if ($micHold.Count -gt 0) {
        $f.Add((New-Finding 'WARN' 'Микрофон' ("Микрофон сейчас занят другой программой: " + (($micHold | ForEach-Object { Get-HolderTitle $_ }) -join ', ')) 'close-apps'))
    }
    $badSvc = @(@($State.Services) | Where-Object { @('Audiosrv', 'AudioEndpointBuilder') -contains $_.Name -and $_.Status -ne 'Running' })
    if ($badSvc.Count -gt 0) {
        $f.Add((New-Finding 'BAD' 'Звук' ("Служба звука Windows не работает: " + (($badSvc | ForEach-Object { $t = "$($_.Name)=$($_.Status)"; if ($_.StartType -eq 'Disabled') { $t += ' (отключена)' }; $t }) -join ', ')) 'restart-audio'))
    }

    # --- программы, которые мешают уроку
    $running = @($State.Processes)
    $apps = @($script:MediaApps | Where-Object { $running -contains $_ })
    $already = @($camHold + $micHold | ForEach-Object { Get-HolderProcesses $_ $State })
    $apps = @($apps | Where-Object { $already -notcontains $_ })
    if ($apps.Count -gt 0) {
        $f.Add((New-Finding 'WARN' 'Программы' ("Открыты программы, которые могут занять камеру или микрофон: " + ($apps -join ', ')) 'close-apps'))
    }

    # --- интернет
    $pingOk = @($State.Ping.Values | Where-Object { $null -ne $_ })
    $dnsOk = @($State.Dns.Values | Where-Object { $_ })
    if ($pingOk.Count -eq 0 -and $dnsOk.Count -eq 0) {
        $f.Add((New-Finding 'BAD' 'Интернет' 'Нет интернета: не отвечают ни серверы, ни DNS' '' 'Проверьте Wi-Fi/кабель и перезагрузите роутер'))
    } elseif ($dnsOk.Count -eq 0) {
        $f.Add((New-Finding 'BAD' 'Интернет' 'Интернет есть, но не работает DNS (сайты не открываются по имени)' 'flush-dns' 'Если сброс не поможет — перезагрузите роутер'))
    } else {
        $lat = [int](($pingOk | Measure-Object -Average).Average)
        if ($pingOk.Count -eq 0) {
            $f.Add((New-Finding 'OK' 'Интернет' 'Сайты открываются (пинг закрыт сетью — это нормально)'))
        } elseif ($lat -gt 150) {
            $f.Add((New-Finding 'WARN' 'Интернет' "Высокая задержка: $lat мс (для видео лучше до 100 мс)" '' 'Подключитесь ближе к роутеру или по кабелю'))
        } else {
            $f.Add((New-Finding 'OK' 'Интернет' "Задержка $lat мс"))
        }
        $s = $State.SpeedMbps
        if ($null -eq $s) {
            $f.Add((New-Finding 'WARN' 'Интернет' 'Скорость измерить не удалось' '' 'Можно проверить вручную на сайте speedtest'))
        } elseif ($s -lt 2) {
            $f.Add((New-Finding 'BAD' 'Интернет' "Очень низкая скорость: $s Мбит/с (для видеоурока нужно от 3–5)" '' 'Закройте загрузки и видео на других устройствах, подойдите к роутеру, перезагрузите его'))
        } elseif ($s -lt 5) {
            $f.Add((New-Finding 'WARN' 'Интернет' "Скорость $s Мбит/с — может тормозить видео" '' 'Закройте загрузки и видео на других устройствах'))
        } else {
            $f.Add((New-Finding 'OK' 'Интернет' "Скорость $s Мбит/с"))
        }
    }

    # --- устройства с ошибкой, которые не камера и не звук (Wi-Fi, Bluetooth, USB, без драйвера)
    $covered = @('Camera', 'Image', 'MEDIA', 'AudioEndpoint')
    $other = @(@($State.ProblemDevices) | Where-Object { $null -ne $_ -and $covered -notcontains "$($_.Class)" -and ($_.Code -ne 22 -or @('Net', 'Bluetooth') -contains "$($_.Class)") })
    $important = @($other | Where-Object { Test-LessonDevice $_ })
    $minor = @($other | Where-Object { -not (Test-LessonDevice $_) })
    if ($important.Count -gt 0) {
        $f.Add((New-Finding 'WARN' 'Устройства' "Устройства с ошибкой: $(Format-DeviceList $important 5)" '' 'Диспетчер устройств (Win+X → Диспетчер устройств): обновите драйвер; для Wi-Fi и сети — с сайта производителя ноутбука'))
    }
    if ($minor.Count -gt 0) {
        $f.Add((New-Finding 'OK' 'Устройства' "Ещё без драйвера или с ошибкой: $(Format-DeviceList $minor 3) — на урок обычно не влияет"))
    }

    # --- антивирус с защитой веб-камеры
    $av = @(@($State.Antivirus) | Where-Object { "$_" -match $script:WebcamGuardPattern })
    if ($av.Count -gt 0) {
        $mediaTrouble = @($f | Where-Object { @('Камера', 'Микрофон') -contains $_.Area -and $_.Level -ne 'OK' }).Count -gt 0
        if ($mediaTrouble) {
            $f.Add((New-Finding 'WARN' 'Антивирус' "Антивирус может блокировать камеру и микрофон: $($av -join ', ')" '' 'В настройках антивируса найдите «веб-камера» и «микрофон» и разрешите доступ браузеру'))
        } else {
            $f.Add((New-Finding 'OK' 'Антивирус' "$($av -join ', ') — если камера не работает только в браузере, разрешите ему веб-камеру в настройках антивируса"))
        }
    }

    # --- время, прокси, VPN, Wi-Fi
    $skew = $State.ClockSkew
    if ($null -ne $skew -and [math]::Abs([int]$skew) -gt 300) {
        $f.Add((New-Finding 'BAD' 'Время' "Часы на компьютере сбиты: $(Format-Skew $skew) — сайты по https и урок могут не открываться" 'sync-time' 'Проверьте и часовой пояс: Параметры → Время и язык'))
    }
    $px = $State.Proxy
    if ($null -ne $px -and ($px.Enabled -or $px.Pac)) {
        $desc = @(); if ($px.Enabled) { $desc += $px.Server }; if ($px.Pac) { $desc += $px.Pac }
        $f.Add((New-Finding 'WARN' 'Интернет' "Включён прокси: $(($desc | Where-Object { $_ }) -join ', ') — частая причина «урок не грузится»" 'disable-proxy'))
    }
    $vpn = @(@($State.Vpn) | Where-Object { $_ })
    if ($vpn.Count -gt 0) {
        $f.Add((New-Finding 'WARN' 'Интернет' "Включён VPN: $($vpn -join ', ')" '' 'Выключите VPN на время урока — с ним видео часто тормозит или не подключается'))
    }
    $sig = $State.WifiSignal
    if ($null -ne $sig) {
        $wifiHint = 'Подойдите ближе к роутеру или подключите кабель; стены и микроволновка ослабляют Wi-Fi'
        if ($sig -lt 30) { $f.Add((New-Finding 'BAD' 'Wi-Fi' "Очень слабый сигнал Wi-Fi: $sig%" '' $wifiHint)) }
        elseif ($sig -lt 60) { $f.Add((New-Finding 'WARN' 'Wi-Fi' "Слабый сигнал Wi-Fi: $sig%" '' $wifiHint)) }
        else { $f.Add((New-Finding 'OK' 'Wi-Fi' "Сигнал Wi-Fi: $sig%")) }
    }

    # --- перезагрузка, память, процессор, версии
    $rebootHint = 'Пуск → Выключение → «Перезагрузка» (именно перезагрузка: «Завершение работы» в Windows 10/11 систему не сбрасывает). Через RustDesk потом подключитесь заново'
    $rb = $State.Reboot
    if ($null -ne $rb) {
        if ($rb.Pending) { $f.Add((New-Finding 'WARN' 'Компьютер' 'Windows ждёт перезагрузки после обновлений' '' $rebootHint)) }
        elseif ($null -ne $rb.UptimeDays -and $rb.UptimeDays -ge 7) { $f.Add((New-Finding 'WARN' 'Компьютер' "Компьютер не перезагружался $([int][math]::Floor($rb.UptimeDays)) дн." '' $rebootHint)) }
    }
    $ld = $State.Load
    if ($null -ne $ld) {
        if ($null -ne $ld.FreeGB -and $null -ne $ld.TotalGB -and $ld.TotalGB -gt 0 -and ($ld.FreeGB -lt 1 -or ($ld.FreeGB / $ld.TotalGB) -lt 0.1)) {
            $f.Add((New-Finding 'WARN' 'Компьютер' "Мало свободной памяти: $($ld.FreeGB) из $($ld.TotalGB) ГБ" '' ("Закройте лишние вкладки и программы. Больше всего памяти у: " + (@($ld.TopMem) -join ', '))))
        }
        if ($ld.CpuPct -ge 85) {
            $who = ''; if (@($ld.TopCpu).Count -gt 0) { $who = ' — больше всего: ' + (@($ld.TopCpu) -join ', ') }
            $f.Add((New-Finding 'WARN' 'Компьютер' "Процессор загружен на $($ld.CpuPct)%$who" '' 'Закройте эти программы, если они не нужны на уроке'))
        }
    }
    $osMajor = Get-MajorVersion $State.OsVersion
    if ($null -ne $osMajor -and $osMajor -lt 10) {
        $f.Add((New-Finding 'WARN' 'Компьютер' "Старая Windows ($($State.OsVersion)) — браузеры на ней больше не обновляются" '' 'Видеоуроки могут не работать; если можно — заниматься с другого устройства'))
    }
    $oldB = @(Get-OldBrowsers $State.Browsers)
    if ($oldB.Count -gt 0) {
        $f.Add((New-Finding 'WARN' 'Браузер' "Устаревший браузер: $($oldB -join ', ')" '' 'Обновите: меню браузера → Справка → О браузере (обновится сам), затем перезапустите'))
    } elseif (@(@($State.Browsers) | Where-Object { $null -ne $_ }).Count -gt 0) {
        $f.Add((New-Finding 'OK' 'Браузер' ("Версии: " + ((@($State.Browsers) | Where-Object { $null -ne $_ } | ForEach-Object { "$($_.Name) $(Get-MajorVersion $_.Version)" }) -join ', '))))
    }

    # --- компьютер
    if ($null -ne $State.FreeDiskGB -and $State.FreeDiskGB -lt 2) {
        $f.Add((New-Finding 'WARN' 'Компьютер' "Мало места на диске: $($State.FreeDiskGB) ГБ — браузер может тормозить" 'clear-cache'))
    }
    $sb = @(@($State.SiteBlocks) | Where-Object { $null -ne $_ })
    if ($sb.Count -gt 0) {
        $titles = @($sb | ForEach-Object { Get-BlockTitle $_ } | Select-Object -Unique)
        $lvl = 'WARN'
        if (@($sb | Where-Object { $_.IsDefault -or (Test-LessonSite $_.Site) }).Count -gt 0) { $lvl = 'BAD' }
        $f.Add((New-Finding $lvl 'Браузер' "Запрещено в браузере: $($titles -join '; ')" 'unblock-sites'))
    }
    $cacheMB = [math]::Round((@($State.CacheDirs) | Measure-Object -Property SizeMB -Sum).Sum, 0)
    if ($cacheMB -ge 1024) {
        $f.Add((New-Finding 'WARN' 'Браузер' "Кэш браузеров занимает $cacheMB МБ" 'clear-cache'))
    } elseif (@($State.CacheDirs).Count -gt 0) {
        $f.Add((New-Finding 'OK' 'Браузер' "Кэш браузеров: $cacheMB МБ"))
    }
    return $f
}

# ============================================================ отчёт

function Get-Mark([string]$Level) {
    switch ($Level) { 'OK' { return '[OK]' } 'WARN' { return '[!] ' } default { return '[X] ' } }
}

# Коды проблем для статистики: бот читает последнюю строку отчёта «#lesson-check …» из комментариев Kaiten.
# Коды не меняем без нужды — по ним считается статистика за месяцы.
$script:FindingCodes = @(
    @('Устройства', 'Не удалось получить список', 'devices.query'), @('Устройства', 'Устройства с ошибкой', 'devices.driver'),
    @('Камера', 'не видит ни одной камеры', 'cam.none'), @('Камера', 'запрещена политикой', 'cam.policy'),
    @('Камера', 'запрещает приложениям камеру', 'cam.policy_apps'), @('Камера', 'служба камеры', 'cam.service'),
    @('Камера', 'конфиденциальности', 'cam.privacy'), @('Камера', 'отключена в диспетчере', 'cam.disabled'),
    @('Камера', 'ошибкой драйвера', 'cam.driver'), @('Камера', 'держит другая программа', 'cam.busy'),
    @('Звук', 'ни одного устройства звука', 'snd.none'), @('Звук', 'не видит динамики', 'snd.no_output'),
    @('Звук', 'отключены в Windows', 'snd.disabled'), @('Звук', 'Ошибка драйвера звука', 'snd.driver'),
    @('Звук', 'Служба звука', 'snd.service'), @('Звук', 'Звук выключен', 'snd.muted'),
    @('Звук', 'Громкость в Windows всего', 'snd.quiet'), @('Звук', 'Hands-Free', 'snd.handsfree'),
    @('Микрофон', 'не видит микрофон', 'mic.none'), @('Микрофон', 'Микрофон отключён', 'mic.disabled'),
    @('Микрофон', 'Микрофон выключен', 'mic.muted'), @('Микрофон', 'Громкость микрофона', 'mic.quiet'),
    @('Микрофон', 'не обычный микрофон', 'mic.virtual'), @('Микрофон', 'по умолчанию не выбран', 'mic.no_default'),
    @('Микрофон', 'запрещает приложениям микрофон', 'mic.policy'), @('Микрофон', 'конфиденциальности', 'mic.privacy'),
    @('Микрофон', 'занят другой программой', 'mic.busy'),
    @('Программы', '', 'apps.open'),
    @('Интернет', 'Нет интернета', 'net.offline'), @('Интернет', 'DNS', 'net.dns'), @('Интернет', 'Высокая задержка', 'net.latency'),
    @('Интернет', 'измерить не удалось', 'net.speed_unknown'), @('Интернет', 'Очень низкая скорость', 'net.slow'),
    @('Интернет', 'может тормозить', 'net.slowish'), @('Интернет', 'прокси', 'net.proxy'), @('Интернет', 'VPN', 'net.vpn'),
    @('Антивирус', '', 'av.block'), @('Время', '', 'time.skew'),
    @('Wi-Fi', 'Очень слабый', 'wifi.very_weak'), @('Wi-Fi', 'Слабый', 'wifi.weak'),
    @('Компьютер', 'ждёт перезагрузки', 'pc.reboot_pending'), @('Компьютер', 'не перезагружался', 'pc.uptime'),
    @('Компьютер', 'памяти', 'pc.ram'), @('Компьютер', 'Процессор', 'pc.cpu'), @('Компьютер', 'Старая Windows', 'pc.old_windows'),
    @('Компьютер', 'места на диске', 'pc.disk'),
    @('Браузер', 'Устаревший', 'br.old'), @('Браузер', 'Запрещено в браузере', 'br.site_block'), @('Браузер', 'Кэш', 'br.cache'),
    @('Тест микрофона', 'тишина', 'mictest.silent'), @('Тест микрофона', 'почти не слышно', 'mictest.quiet'), @('Тест микрофона', 'Не удалось', 'mictest.error')
)

function Get-FindingCode($Finding) {
    foreach ($c in $script:FindingCodes) {
        if ($Finding.Area -eq $c[0] -and ($c[1] -eq '' -or $Finding.Text -match [regex]::Escape($c[1]))) { return $c[2] }
    }
    return 'other'
}

function Get-ProblemCodes($Findings) {
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($x in @($Findings)) {
        if ($null -eq $x -or $x.Level -eq 'OK') { continue }
        $c = Get-FindingCode $x
        if (-not $out.Contains($c)) { $out.Add($c) }
    }
    return @($out)
}

function Format-ReportTag($Findings, $Before = $null, [switch]$Crashed) {
    # Последняя строка отчёта — для бота: problems = что было найдено, left = что осталось после исправлений
    $left = @(Get-ProblemCodes $Findings)
    $all = New-Object System.Collections.Generic.List[string]
    foreach ($c in @(@(Get-ProblemCodes $Before) + $left)) { if ($c -and -not $all.Contains($c)) { $all.Add($c) } }
    $p = '-'; if ($all.Count -gt 0) { $p = ($all -join ',') }
    $l = '-'; if ($left.Count -gt 0) { $l = ($left -join ',') }
    $tag = "#lesson-check $script:Version problems=$p left=$l"
    if ($Crashed) { $tag += ' crashed=1' }
    return $tag
}

function Format-Report($State, $Findings, $Before = $null, [switch]$NoTag) {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("Проверка перед уроком v$script:Version — $($State.Time.ToString('dd.MM.yyyy HH:mm'))")
    $lines.Add("Система: $($State.Os)")
    foreach ($x in $Findings) {
        $line = "$(Get-Mark $x.Level) $($x.Area): $($x.Text)"
        if ($x.Hint -and $x.Level -ne 'OK') { $line += " — $($x.Hint)" }
        $lines.Add($line)
    }
    if ($script:Actions.Count -gt 0) {
        $lines.Add('Сделано:')
        foreach ($a in $script:Actions) { $lines.Add("  - $a") }
    }
    if ($null -ne $Before) {
        $was = @($Before | Where-Object { $_.Level -ne 'OK' }).Count
        $now = @($Findings | Where-Object { $_.Level -ne 'OK' }).Count
        $lines.Add("Проблем до исправлений: $was, после: $now")
    }
    $left = @($Findings | Where-Object { $_.Level -eq 'BAD' })
    if ($left.Count -eq 0) { $lines.Add('Итог: можно проверять в браузере на странице проверки перед уроком') }
    else { $lines.Add('Итог: осталось исправить вручную — см. строки с [X]') }
    if (-not $NoTag) { $lines.Add((Format-ReportTag $Findings $Before)) }
    return ($lines -join "`r`n")
}

function Get-ReportDirs {
    # Куда сохранить отчёт: рабочий стол (в т. ч. в OneDrive), папка программы, временная папка
    return @([Environment]::GetFolderPath('Desktop'), $PSScriptRoot, $env:TEMP, [IO.Path]::GetTempPath()) | Where-Object { $_ }
}

function Save-Report([string]$Text) {
    $name = "lesson-check-" + (Get-Date).ToString('yyyyMMdd-HHmm') + '.txt'
    $path = $null
    foreach ($desk in @(Get-ReportDirs)) {
        if (-not (Test-Path -LiteralPath $desk)) { continue }
        $try = Join-Path $desk $name
        try { [IO.File]::WriteAllText($try, $Text, (New-Object Text.UTF8Encoding($true))); $path = $try; break } catch { }
    }
    $copied = $false
    try { Set-Clipboard -Value $Text -ErrorAction Stop; $copied = $true } catch { }
    return [pscustomobject]@{ Path = $path; Copied = $copied }
}

# ============================================================ запрет камеры/микрофона для сайтов в Chrome, Edge, Яндексе, Opera

function ConvertTo-SiteName([string]$Key) {
    $s = ($Key -split ',')[0]
    $s = $s -replace '^[a-z]+://', '' -replace ':443$', '' -replace ':80$', '' -replace '^\[\*\.\]', '*.'
    return $s
}

function Get-SiteBlocksFromText([string]$Text) {
    $out = @()
    if (-not $Text -or -not (Initialize-JsonSpan)) { return $out }
    try {
        foreach ($kind in @('media_stream_camera', 'media_stream_mic')) {
            $ex = [LessonCheck.Json.JsonSpan]::PathTo($Text, [string[]]@('profile', 'content_settings', 'exceptions', $kind))
            if ($ex -ge 0) {
                foreach ($m in [LessonCheck.Json.JsonSpan]::Members($Text, $ex)) {
                    $val = $Text.Substring($m.ValueStart, $m.ValueEnd - $m.ValueStart)
                    if ($val -match '"setting"\s*:\s*2\b') { $out += [pscustomobject]@{ Kind = $kind; Key = $m.Key; Site = (ConvertTo-SiteName $m.Key); IsDefault = $false } }
                }
            }
            $def = [LessonCheck.Json.JsonSpan]::PathTo($Text, [string[]]@('profile', 'default_content_setting_values'))
            if ($def -ge 0) {
                foreach ($m in [LessonCheck.Json.JsonSpan]::Members($Text, $def)) {
                    if ($m.Key -eq $kind -and $Text.Substring($m.ValueStart, $m.ValueEnd - $m.ValueStart).Trim() -eq '2') {
                        $out += [pscustomobject]@{ Kind = $kind; Key = $kind; Site = ''; IsDefault = $true }
                    }
                }
            }
        }
    } catch { }
    return $out
}

function Remove-SiteBlocksFromText([string]$Text, $Blocks) {
    # Вырезаем только выбранные записи; если итог не разбирается как JSON — ничего не меняем
    if (-not (Initialize-JsonSpan)) { return $null }
    try {
        $t = $Text
        foreach ($b in @($Blocks)) {
            if ($b.IsDefault) { $obj = [LessonCheck.Json.JsonSpan]::PathTo($t, [string[]]@('profile', 'default_content_setting_values')) }
            else { $obj = [LessonCheck.Json.JsonSpan]::PathTo($t, [string[]]@('profile', 'content_settings', 'exceptions', $b.Kind)) }
            if ($obj -lt 0) { return $null }
            $n = [LessonCheck.Json.JsonSpan]::Remove($t, $obj, $b.Key)
            if ($null -eq $n) { return $null }
            $t = $n
        }
        if (-not [LessonCheck.Json.JsonSpan]::IsValid($t)) { return $null }
        return $t
    } catch { return $null }
}

function Get-BrowserPrefFiles {
    $out = @()
    foreach ($b in $script:Browsers) {
        if ($b.Kind -eq 'firefox') { continue }
        $rootVar = $b.Root
        if ($b.PrefRoot) { $rootVar = $b.PrefRoot }
        $root = Expand-PathVars $rootVar
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $dirs = @()
        if ($b.Kind -eq 'opera') { $dirs = @($root, (Join-Path $root 'Default')) }
        else { $dirs = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' } | ForEach-Object { $_.FullName }) }
        foreach ($d in $dirs) {
            $f = Join-Path $d 'Preferences'
            if (Test-Path -LiteralPath $f) { $out += [pscustomobject]@{ Browser = $b.Name; Process = $b.Process; File = $f } }
        }
    }
    return $out
}

function Get-BrowserSiteBlocks {
    $out = @()
    foreach ($p in @(Get-BrowserPrefFiles)) {
        $text = $null
        try { $text = [IO.File]::ReadAllText($p.File) } catch { continue }
        foreach ($b in @(Get-SiteBlocksFromText $text)) {
            $out += [pscustomobject]@{ Browser = $p.Browser; Process = $p.Process; File = $p.File; Kind = $b.Kind; Key = $b.Key; Site = $b.Site; IsDefault = $b.IsDefault }
        }
    }
    return $out
}

function Test-LessonSite([string]$Site) {
    foreach ($p in @($script:LessonSites)) { if ($p -and $Site -like "*$p*") { return $true } }
    return $false
}

function Get-BlockTitle($Block) {
    $what = 'камера'; if ($Block.Kind -eq 'media_stream_mic') { $what = 'микрофон' }
    if ($Block.IsDefault) { return "$($Block.Browser): $what запрещён(а) для всех сайтов" }
    return "$($Block.Browser): $what для $($Block.Site)"
}

function Get-SiteBlockValue([string]$Text, $Block) {
    try {
        if ($Block.IsDefault) { $obj = [LessonCheck.Json.JsonSpan]::PathTo($Text, [string[]]@('profile', 'default_content_setting_values')) }
        else { $obj = [LessonCheck.Json.JsonSpan]::PathTo($Text, [string[]]@('profile', 'content_settings', 'exceptions', $Block.Kind)) }
        if ($obj -lt 0) { return $null }
        foreach ($m in [LessonCheck.Json.JsonSpan]::Members($Text, $obj)) {
            if ($m.Key -eq $Block.Key) { return $Text.Substring($m.ValueStart, $m.ValueEnd - $m.ValueStart) }
        }
    } catch { }
    return $null
}

function Write-FileAtomic([string]$Path, [string]$Text) {
    # Сначала во временный файл рядом, потом подмена — при сбое посередине файл настроек не будет обрезан
    $tmp = "$Path.lesson-check-tmp"
    [IO.File]::WriteAllText($tmp, $Text, (New-Object Text.UTF8Encoding($false)))
    try { [IO.File]::Replace($tmp, $Path, $null) }
    catch { [IO.File]::Copy($tmp, $Path, $true); Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}

function Restore-SiteBlock($Data) {
    $text = [IO.File]::ReadAllText($Data.File)
    if (-not (Initialize-JsonSpan)) { return $false }
    if ($Data.IsDefault) { $path = [string[]]@('profile', 'default_content_setting_values') }
    else { $path = [string[]]@('profile', 'content_settings', 'exceptions', "$($Data.Kind)") }
    $obj = [LessonCheck.Json.JsonSpan]::PathTo($text, $path)
    if ($obj -lt 0) { return $false }
    if ([LessonCheck.Json.JsonSpan]::Find($text, $obj, "$($Data.Key)") -ge 0) { return $true }   # уже есть — ничего не дублируем
    $new = [LessonCheck.Json.JsonSpan]::Insert($text, $obj, "$($Data.Key)", "$($Data.Value)")
    if (-not [LessonCheck.Json.JsonSpan]::IsValid($new)) { return $false }
    Write-FileAtomic $Data.File $new
    return $true
}

function Invoke-UnblockSites($State) {
    $blocks = @(@($State.SiteBlocks) | Where-Object { $null -ne $_ })
    if ($blocks.Count -eq 0) { return 'Запретов для сайтов нет' }
    $removed = @()
    foreach ($grp in @($blocks | Group-Object -Property File)) {
        $first = $grp.Group[0]
        $chosen = @($grp.Group | Where-Object { Read-YesNo "  Снять запрет — $(Get-BlockTitle $_)?" })
        if ($chosen.Count -eq 0) { continue }
        if (@(Get-RunningProcessNames) -contains $first.Process) {
            if (-not (Read-YesNo "  Нужно закрыть $($first.Browser) (несохранённый текст на страницах пропадёт, вкладки вернёт Ctrl+Shift+T). Закрыть?")) { continue }
            try { Stop-Process -Name $first.Process -Force -ErrorAction Stop } catch { }
            Start-Sleep -Seconds 2
        }
        try {
            $text = [IO.File]::ReadAllText($first.File)
            $new = Remove-SiteBlocksFromText $text $chosen
            if ($null -eq $new) { continue }
            $backup = "$($first.File).lesson-check-$((Get-Date).ToString('yyyyMMdd-HHmmss')).bak"
            Copy-Item -LiteralPath $first.File -Destination $backup -Force -ErrorAction Stop
            foreach ($b in $chosen) {
                Add-Undo 'site-block' @{ File = $first.File; Process = $first.Process; Browser = $first.Browser; Kind = $b.Kind; Key = $b.Key; IsDefault = [bool]$b.IsDefault; Value = (Get-SiteBlockValue $text $b) } "Запрет снят — $(Get-BlockTitle $b) (полная копия настроек: $backup)"
            }
            Write-FileAtomic $first.File $new
            $removed += @($chosen | ForEach-Object { Get-BlockTitle $_ })
        } catch { }
    }
    if ($removed.Count -eq 0) { return 'Запреты не сняты' }
    $script:Actions.Add("Сняты запреты в браузере: $($removed -join '; ')")
    return "Снял запреты: $($removed.Count). Откройте урок — браузер спросит разрешение, нажмите «Разрешить»"
}

function Measure-WavLevel([byte[]]$Bytes) {
    # Пик громкости в записи 0..1 (первые 0,15 с пропускаем — там бывает щелчок начала записи)
    if ($null -eq $Bytes -or $Bytes.Length -lt 44) { return $null }
    $ascii = [Text.Encoding]::ASCII
    if ($ascii.GetString($Bytes, 0, 4) -ne 'RIFF' -or $ascii.GetString($Bytes, 8, 4) -ne 'WAVE') { return $null }
    $pos = 12; $bits = 16; $channels = 1; $rate = 16000; $dataStart = -1; $dataLen = 0
    while ($pos + 8 -le $Bytes.Length) {
        $id = $ascii.GetString($Bytes, $pos, 4); $size = [BitConverter]::ToInt32($Bytes, $pos + 4); $body = $pos + 8
        if ($id -eq 'fmt ' -and $body + 16 -le $Bytes.Length) {
            $channels = [BitConverter]::ToInt16($Bytes, $body + 2); $rate = [BitConverter]::ToInt32($Bytes, $body + 4); $bits = [BitConverter]::ToInt16($Bytes, $body + 14)
        }
        if ($id -eq 'data') { $dataStart = $body; $dataLen = [math]::Min($size, $Bytes.Length - $body); break }
        if ($size -lt 0) { break }
        $pos = $body + $size + ($size % 2)
    }
    if ($dataStart -lt 0 -or $rate -le 0 -or $channels -le 0 -or ($bits -ne 8 -and $bits -ne 16)) { return $null }
    $bytesPerSample = $bits / 8
    $skip = [int]($rate * $channels * $bytesPerSample * 0.15); $skip -= $skip % ($bytesPerSample * $channels)
    $peak = 0.0; $maxRms = 0.0; $loud = 0; $sum = 0.0; $n = 0
    $win = [int]($rate * $channels * 0.05)
    $end = $dataStart + $dataLen
    $step = [int]$bytesPerSample
    for ($i = $dataStart + $skip; $i + $step - 1 -lt $end; $i += $step) {
        if ($bits -eq 16) { $v = [math]::Abs([int][BitConverter]::ToInt16($Bytes, $i)) / 32768.0 }
        else { $v = [math]::Abs([int]$Bytes[$i] - 128) / 128.0 }
        if ($v -gt $peak) { $peak = $v }
        $sum += $v * $v; $n++
        if ($n -ge $win) {
            $rms = [math]::Sqrt($sum / $n)
            if ($rms -gt $maxRms) { $maxRms = $rms }
            if ($rms -ge 0.015) { $loud++ }
            $sum = 0.0; $n = 0
        }
    }
    return [pscustomobject]@{ Peak = [math]::Min(1.0, $peak); MaxRms = $maxRms; LoudWindows = $loud; Seconds = [math]::Round($dataLen / ($rate * $channels * $bytesPerSample), 1) }
}

function Get-MicTestFinding($Level, [bool]$MicDenied = $false) {
    if ($null -eq $Level) { return New-Finding 'WARN' 'Тест микрофона' 'Не удалось разобрать запись' '' 'Проверьте микрофон на странице проверки в браузере' }
    $pct = [int][math]::Round($Level.Peak * 100)
    if ($Level.MaxRms -lt 0.004) {
        $hint = 'Проверьте кнопку выключения микрофона на гарнитуре или клавиатуре и выбранный микрофон: Параметры → Система → Звук → Ввод'
        if ($MicDenied) { $hint = 'Доступ к микрофону запрещён в Windows (см. выше) — сначала разрешите его, потом проверьте ещё раз' }
        return New-Finding 'BAD' 'Тест микрофона' "Запись $($Level.Seconds) с — тишина (громкость до $pct%)" '' $hint
    }
    if ($Level.LoudWindows -lt 3) { return New-Finding 'WARN' 'Тест микрофона' "Голоса почти не слышно (громкость до $pct%)" '' 'Поднесите микрофон ближе или прибавьте его громкость: Параметры → Система → Звук → Ввод' }
    return New-Finding 'OK' 'Тест микрофона' "Запись $($Level.Seconds) с: голос слышен (громкость до $pct%)"
}

function Invoke-MicRecord([string]$Path, [int]$Ms) {
    if (-not (Initialize-MicApi)) { return 'запись звука недоступна' }
    try { return [LessonCheck.Mic.Recorder]::Record($Path, $Ms) } catch { return "$($_.Exception.Message)" }
}

function Invoke-WavPlay([string]$Path) {
    try { (New-Object System.Media.SoundPlayer $Path).PlaySync(); return $true } catch { return $false }
}

function Invoke-MicTest($State = $null) {
    $path = Join-Path ([IO.Path]::GetTempPath()) ('lesson-check-mic-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.wav')
    Write-Host '    Говорите что-нибудь 3 секунды... (идёт запись)' -ForegroundColor Cyan
    $err = Invoke-MicRecord $path 3000
    if ($err) { return New-Finding 'WARN' 'Тест микрофона' "Не удалось записать: $err" '' 'Проверьте микрофон на странице проверки в браузере' }
    $lvl = $null
    try { $lvl = Measure-WavLevel ([IO.File]::ReadAllBytes($path)) } catch { }
    Write-Host '    Проигрываю запись...' -ForegroundColor Gray
    $null = Invoke-WavPlay $path
    try { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue } catch { }
    $denied = $false; if ($null -ne $State) { $denied = [bool](Test-ConsentDenied $State.MicConsent) }
    return Get-MicTestFinding $lvl $denied
}

# ============================================================ исправления (только по согласию)

function Read-YesNo([string]$Question) {
    $a = Read-Host "$Question [Д/Н]"
    return ("$a".Trim().ToLower() -in @('д', 'да', 'y', 'yes', '1', 'l'))
}

function Set-ConsentValue([string]$Hive, [string]$Capability, [string]$Sub, [string]$Value) {
    $path = "$($Hive):\$script:ConsentRoot\$Capability"
    if ($Sub) { $path = "$path\$Sub" }
    if (-not (Test-Path -Path $path)) { New-Item -Path $path -Force | Out-Null }
    Set-ItemProperty -Path $path -Name Value -Value $Value -Type String -ErrorAction Stop
}

function Invoke-AllowCapability([string]$Capability, [string]$Title, [bool]$IsAdmin) {
    $changed = @()
    foreach ($pair in @(@('HKCU', ''), @('HKCU', 'NonPackaged'))) {
        if ((Get-ConsentValue $pair[0] $Capability $pair[1]) -eq 'Deny') {
            Add-Undo 'consent' @{ Hive = $pair[0]; Capability = $Capability; Sub = $pair[1]; Old = 'Deny' } "Разрешение Windows: $Title ($($pair[0]) $($pair[1]))"
            Set-ConsentValue $pair[0] $Capability $pair[1] 'Allow'
            $changed += "$($pair[0])\$Capability\$($pair[1])"
        }
    }
    if ((Get-ConsentValue 'HKLM' $Capability) -eq 'Deny') {
        if ($IsAdmin) { Add-Undo 'consent' @{ Hive = 'HKLM'; Capability = $Capability; Sub = ''; Old = 'Deny' } "Разрешение Windows: $Title (для всего компьютера)"; Set-ConsentValue 'HKLM' $Capability '' 'Allow'; $changed += "HKLM\$Capability" }
        else {
            # Своё (для пользователя) уже исправили — запишем; для всего компьютера нужен администратор
            if ($changed.Count -gt 0) { $script:Actions.Add("Разрешён доступ к $Title для пользователя") }
            return 'NEED_ADMIN'
        }
    }
    if ($changed.Count -eq 0) { return "Доступ к $Title уже разрешён" }
    $script:Actions.Add("Разрешён доступ к $Title в Windows")
    return "Разрешил доступ к $Title. Перезапустите браузер, чтобы он увидел изменение"
}

function Invoke-CloseApps($State) {
    $targets = @($script:MediaApps | Where-Object { @($State.Processes) -contains $_ })
    foreach ($h in @(Get-ActiveHolders (@($State.CamHolders) + @($State.MicHolders)) $State)) {
        foreach ($n in @(Get-HolderProcesses $h $State)) {
            if (-not (Test-IsBrowserName $n) -and $targets -notcontains $n) { $targets += $n }
        }
    }
    if ($targets.Count -eq 0) { return 'Мешающих программ не нашёл' }
    $closed = @()
    foreach ($t in $targets) {
        if (Read-YesNo "  Закрыть $t? Несохранённое в ней пропадёт") {
            try { Stop-Process -Name $t -Force -ErrorAction Stop; $closed += $t } catch { }
        }
    }
    if ($closed.Count -gt 0) { $script:Actions.Add("Закрыты программы: $($closed -join ', ')"); Add-Undo 'info' @{} "Закрыты программы: $($closed -join ', ') — откройте их сами, если нужны" }
    return "Закрыто: $(@($closed).Count) из $($targets.Count)"
}

function Invoke-RestartAudio([bool]$IsAdmin, $State = $null) {
    if (-not $IsAdmin) { return 'NEED_ADMIN' }
    foreach ($svc in @(@($State.Services) | Where-Object { $null -ne $_ -and @('Audiosrv', 'AudioEndpointBuilder') -contains $_.Name -and $_.StartType -eq 'Disabled' })) {
        Add-Undo 'service' @{ Name = $svc.Name; StartType = 'Disabled' } "Служба $($svc.Name): была отключена"
        Set-Service -Name $svc.Name -StartupType Automatic -ErrorAction SilentlyContinue
    }
    Restart-Service -Name 'AudioEndpointBuilder' -Force -ErrorAction SilentlyContinue
    Start-Service -Name 'Audiosrv' -ErrorAction SilentlyContinue
    $notRunning = @(@(Get-ServiceStates) | Where-Object { @('Audiosrv', 'AudioEndpointBuilder') -contains $_.Name -and $_.Status -ne 'Running' })
    if ($notRunning.Count -gt 0) { return "Служба звука не запустилась: $(($notRunning | ForEach-Object { $_.Name }) -join ', ')" }
    $script:Actions.Add('Перезапущена служба звука Windows')
    return 'Перезапустил службу звука'
}

function Restart-Devices($Devices) {
    # Выключить и включить. Включаем обязательно (finally), даже если что-то пошло не так, и громко говорим, если не вышло.
    $done = @(); $stuck = @()
    foreach ($d in @($Devices)) {
        $enabled = $false
        try {
            if ($d.Code -ne 22) { Disable-PnpDevice -InstanceId $d.Id -Confirm:$false -ErrorAction Stop; Start-Sleep -Seconds 2 }
        } catch { }
        finally {
            try { Enable-PnpDevice -InstanceId $d.Id -Confirm:$false -ErrorAction Stop; $enabled = $true } catch { }
        }
        if ($enabled) { $done += $d.Name } else { $stuck += $d.Name }
        if ($enabled -and $d.Code -eq 22) { Add-Undo 'device-enabled' @{ Id = $d.Id; Name = $d.Name } "Включено устройство: $($d.Name) (было отключено)" }
    }
    $warn = ''
    if ($stuck.Count -gt 0) { $warn = ". ВНИМАНИЕ: не удалось включить: $($stuck -join ', ') — включите вручную в диспетчере устройств (Win+X)" }
    return [pscustomobject]@{ Done = $done; Stuck = $stuck; Warning = $warn }
}

function Invoke-ResetAudioDevice($State, [bool]$IsAdmin) {
    if (-not $IsAdmin) { return 'NEED_ADMIN' }
    $targets = @(Get-AudioResetTargets $State)
    $r = Restart-Devices $targets
    if ($r.Done.Count -gt 0) { $script:Actions.Add("Перезапущено устройство звука: $($r.Done -join ', ')") }
    return "Перезапущено устройств звука: $($r.Done.Count)$($r.Warning)"
}

function Invoke-UnmuteAudio($State) {
    $lv = $State.AudioLevels
    $done = @()
    if ($null -ne $lv -and $null -ne $lv.Capture -and ($lv.Capture.Muted -or $lv.Capture.Level -lt 25)) {
        if (Set-AudioEndpointLevel 1 70) { $done += 'микрофон (70%)'; Add-Undo 'volume' @{ Flow = 1; Id = "$($lv.Capture.Id)"; Muted = [bool]$lv.Capture.Muted; Level = [int]$lv.Capture.Level } "Микрофон: был $(if ($lv.Capture.Muted) { 'без звука' } else { "$($lv.Capture.Level)%" })" }
    }
    if ($null -ne $lv -and $null -ne $lv.Render -and ($lv.Render.Muted -or $lv.Render.Level -lt 15)) {
        if (Set-AudioEndpointLevel 0 50) { $done += 'звук (50%)'; Add-Undo 'volume' @{ Flow = 0; Id = "$($lv.Render.Id)"; Muted = [bool]$lv.Render.Muted; Level = [int]$lv.Render.Level } "Звук: был $(if ($lv.Render.Muted) { 'без звука' } else { "$($lv.Render.Level)%" })" }
    }
    if ($done.Count -eq 0) { return 'Не удалось изменить громкость — проверьте значок динамика внизу экрана' }
    $script:Actions.Add("Включены и сделаны громче: $($done -join ', ')")
    return "Включил: $($done -join ', ')"
}

function Invoke-EnableCameraService([bool]$IsAdmin) {
    if (-not $IsAdmin) { return 'NEED_ADMIN' }
    try { Set-Service -Name 'FrameServer' -StartupType Manual -ErrorAction Stop } catch { return 'Не удалось включить службу камеры' }
    Add-Undo 'service' @{ Name = 'FrameServer'; StartType = 'Disabled' } 'Служба камеры Windows: была отключена'
    Start-Service -Name 'FrameServer' -ErrorAction SilentlyContinue
    $script:Actions.Add('Включена служба камеры Windows (Frame Server)')
    return 'Включил службу камеры. Перезапустите браузер'
}

function Invoke-SyncTime([bool]$IsAdmin) {
    if (-not $IsAdmin) { return 'NEED_ADMIN' }
    $skew = Get-ClockSkewSeconds $true   # меняем время, только если все источники согласны
    if ($null -eq $skew) { return 'Не удалось надёжно узнать точное время из интернета — включите «Установить время автоматически» в Параметры → Время и язык' }
    try { Set-Date -Date ((Get-Date).AddSeconds(-$skew)) -ErrorAction Stop | Out-Null } catch { return 'Не удалось изменить время' }
    try { Start-Service -Name 'w32time' -ErrorAction SilentlyContinue; & w32tm /resync /nowait | Out-Null } catch { }
    $script:Actions.Add("Исправлено время на компьютере (часы $(Format-Skew $skew))")
    Add-Undo 'info' @{} "Исправлено время (часы $(Format-Skew $skew)) — возвращать неверное время незачем"
    return 'Исправил время. Включите «Установить время автоматически»: Параметры → Время и язык'
}

function Test-DirectInternet {
    # Открывается ли интернет напрямую, мимо прокси
    try {
        $req = [System.Net.HttpWebRequest]::Create($script:TimeUrls[0])
        $req.Proxy = New-Object System.Net.WebProxy
        $req.Timeout = 5000
        $resp = $req.GetResponse(); $resp.Close()
        return $true
    } catch { return $false }
}

function Set-ProxyOff([bool]$RemovePac) {
    Set-ItemProperty -Path $script:InetKey -Name ProxyEnable -Value 0 -Type DWord -ErrorAction Stop
    if ($RemovePac) { Remove-ItemProperty -Path $script:InetKey -Name AutoConfigURL -ErrorAction Stop }
}

function Invoke-DisableProxy {
    $px = Get-ProxyState
    if ($null -eq $px -or (-not $px.Enabled -and -not $px.Pac)) { return 'Прокси уже выключен' }
    $was = @()
    if ($px.Enabled) { $was += "сервер $($px.Server)" }
    if ($px.Pac) { $was += "скрипт $($px.Pac)" }
    if (-not (Test-DirectInternet)) { return 'Прокси оставил: без него интернет не открывается (возможно, так устроена сеть)' }
    $pxEnable = 0; if ($px.Enabled) { $pxEnable = 1 }
    Add-Undo 'proxy' @{ ProxyEnable = $pxEnable; ProxyServer = $px.Server; AutoConfigURL = $px.Pac } "Прокси: $($was -join ', ')"
    try { Set-ProxyOff ([bool]$px.Pac) } catch { return 'Не удалось выключить прокси' }
    $script:Actions.Add("Выключен прокси (было: $($was -join ', '); вернуть: Параметры → Сеть и Интернет → Прокси)")
    return 'Выключил прокси. Перезапустите браузер'
}

function Invoke-FlushDns {
    try { Clear-DnsClientCache -ErrorAction Stop }
    catch {
        try { & ipconfig /flushdns | Out-Null } catch { return 'Не удалось сбросить кэш DNS' }
        if ($LASTEXITCODE -ne 0) { return 'Не удалось сбросить кэш DNS' }
    }
    $script:Actions.Add('Сброшен кэш DNS')
    Add-Undo 'info' @{} 'Сброшен кэш DNS — Windows соберёт его заново сама'
    return 'Сбросил кэш DNS'
}

function Invoke-ResetCamera($State, [bool]$IsAdmin) {
    if (-not $IsAdmin) { return 'NEED_ADMIN' }
    $r = Restart-Devices @(Select-RealCameras $State.Cameras | Where-Object { $_.Code -ne 0 })
    if ($r.Done.Count -gt 0) { $script:Actions.Add("Перезапущена камера: $($r.Done -join ', ')") }
    return "Перезапущено камер: $($r.Done.Count)$($r.Warning)"
}

function Clear-BrowserCaches($State, [switch]$NoPrompt) {
    $dirs = @($State.CacheDirs)
    if ($dirs.Count -eq 0) { return 'Кэш браузеров не найден' }
    $procs = @($dirs | ForEach-Object { $_.Process } | Select-Object -Unique | Where-Object { @($State.Processes) -contains $_ })
    if ($procs.Count -gt 0) {
        if (-not $NoPrompt -and -not (Read-YesNo "  Для очистки нужно закрыть браузер ($($procs -join ', ')). Несохранённый текст на открытых страницах пропадёт; вкладки потом вернёт Ctrl+Shift+T. Закрыть?")) {
            return 'Кэш не очищен: браузер оставили открытым'
        }
        foreach ($p in $procs) { try { Stop-Process -Name $p -Force -ErrorAction Stop } catch { } }
        Start-Sleep -Seconds 2
    }
    $freed = 0.0
    foreach ($d in $dirs) {
        $freed += $d.SizeMB
        Get-ChildItem -LiteralPath $d.Path -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
    $freed = [math]::Round($freed, 0)
    $script:Actions.Add("Очищен кэш браузеров: ~$freed МБ (пароли, cookies и история не тронуты)")
    Add-Undo 'info' @{} "Очищен кэш браузеров (~$freed МБ) — браузер наполнит его заново сам"
    return "Очистил кэш: ~$freed МБ"
}

function Invoke-OneFix([string]$Key, $State) {
    $admin = [bool]$State.IsAdmin
    switch ($Key) {
        'allow-camera'  { return Invoke-AllowCapability 'webcam' 'камере' $admin }
        'allow-mic'     { return Invoke-AllowCapability 'microphone' 'микрофону' $admin }
        'close-apps'    { return Invoke-CloseApps $State }
        'restart-audio' { return Invoke-RestartAudio $admin $State }
        'reset-audio-device' { return Invoke-ResetAudioDevice $State $admin }
        'unmute-audio'  { return Invoke-UnmuteAudio $State }
        'enable-camera-service' { return Invoke-EnableCameraService $admin }
        'sync-time'     { return Invoke-SyncTime $admin }
        'disable-proxy' { return Invoke-DisableProxy }
        'flush-dns'     { return Invoke-FlushDns }
        'reset-camera'  { return Invoke-ResetCamera $State $admin }
        'clear-cache'   { return Clear-BrowserCaches $State }
        'unblock-sites' { return Invoke-UnblockSites $State }
        default         { return "Неизвестное исправление: $Key" }
    }
}

function Get-FixTitle([string]$Key) {
    switch ($Key) {
        'allow-camera'  { return 'Разрешить доступ к камере в Windows' }
        'allow-mic'     { return 'Разрешить доступ к микрофону в Windows' }
        'close-apps'    { return 'Закрыть программы, которые держат камеру/микрофон' }
        'restart-audio' { return 'Перезапустить службу звука (нужны права администратора)' }
        'reset-audio-device' { return 'Перезапустить устройство звука в диспетчере устройств (нужны права администратора)' }
        'unmute-audio'  { return 'Включить микрофон и звук в Windows и прибавить громкость' }
        'enable-camera-service' { return 'Включить службу камеры Windows (нужны права администратора)' }
        'sync-time'     { return 'Исправить время на компьютере (нужны права администратора)' }
        'disable-proxy' { return 'Выключить прокси (часто остаётся от посторонних программ)' }
        'flush-dns'     { return 'Сбросить кэш DNS' }
        'reset-camera'  { return 'Перезапустить камеру в диспетчере устройств (нужны права администратора)' }
        'clear-cache'   { return 'Очистить кэш браузеров (пароли, cookies и история останутся)' }
        'unblock-sites' { return 'Снять запрет камеры/микрофона для сайтов в браузере (по каждому спрошу)' }
        default         { return $Key }
    }
}

function Start-Elevated([string]$Key) {
    # Повторный запуск этого же файла от администратора только для одного исправления.
    # Через RustDesk окно UAC видно, только если RustDesk установлен как служба; иначе попросите нажать «Да» самого ученика.
    try {
        $argLine = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Fix $Key"
        Write-Host '    Откроется окно администратора на несколько секунд...' -ForegroundColor Gray
        $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -Verb RunAs -Wait -PassThru -ErrorAction Stop
        if ($p.ExitCode -eq 0) {
            $script:Actions.Add("Выполнено от администратора: $(Get-FixTitle $Key)")
            return 'Готово (от администратора)'
        }
        return 'От имени администратора ничего не изменилось'
    } catch { return 'Не удалось получить права администратора' }
}

# ============================================================ журнал для отката (lesson-check.bat -Undo)

$script:UndoPathOverride = $null
$script:AdminUndoKinds = @('service', 'device-enabled')

$script:UndoPathResolved = $null

function Test-DirWritable([string]$Dir) {
    try {
        if (-not (Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Path $Dir -Force -ErrorAction Stop | Out-Null }
        $t = Join-Path $Dir ('.lc-' + [guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($t, 'x'); Remove-Item -LiteralPath $t -Force
        return $true
    } catch { return $false }
}

function Get-UndoPath {
    # Журнал — в папке программы (его видит и окно администратора); если туда писать нельзя — в ProgramData
    if ($script:UndoPathOverride) { return $script:UndoPathOverride }
    if ($script:UndoPathResolved) { return $script:UndoPathResolved }
    $dirs = @()
    if ($PSScriptRoot) { $dirs += $PSScriptRoot }
    if ($env:ProgramData) { $dirs += (Join-Path $env:ProgramData 'lesson-check') }
    if ($env:TEMP) { $dirs += $env:TEMP }
    foreach ($d in $dirs) { $f = Join-Path $d 'lesson-check-undo.json'; if (Test-Path -LiteralPath $f) { $script:UndoPathResolved = $f; return $f } }
    foreach ($d in $dirs) { if (Test-DirWritable $d) { $script:UndoPathResolved = (Join-Path $d 'lesson-check-undo.json'); return $script:UndoPathResolved } }
    return (Join-Path $dirs[0] 'lesson-check-undo.json')
}

function Read-UndoLog {
    $p = Get-UndoPath
    if (-not (Test-Path -LiteralPath $p)) { return @() }
    try {
        $x = [IO.File]::ReadAllText($p) | ConvertFrom-Json -ErrorAction Stop
        $out = @(); foreach ($i in $x) { if ($null -ne $i) { $out += $i } }
        return $out
    } catch {
        # Повреждённый журнал не затираем — откладываем в сторону, чтобы его можно было посмотреть
        try { Move-Item -LiteralPath $p -Destination "$p.corrupt-$((Get-Date).ToString('yyyyMMdd-HHmmss'))" -Force -ErrorAction Stop } catch { }
        Write-Host '  Журнал отката был повреждён — отложил его в сторону (.corrupt), начинаю новый' -ForegroundColor Yellow
        return @()
    }
}

function Save-UndoLog($Entries) {
    try { [IO.File]::WriteAllText((Get-UndoPath), (ConvertTo-Json -InputObject @($Entries) -Depth 6), (New-Object Text.UTF8Encoding($false))) }
    catch {
        if (-not $script:UndoWriteFailed) { Write-Host '  Не удалось записать журнал отката — откат этих изменений будет недоступен' -ForegroundColor Yellow }
        $script:UndoWriteFailed = $true
    }
}

function Add-Undo([string]$Kind, [hashtable]$Data, [string]$Title) {
    # Записываем, как было, ДО изменения. Сбой записи журнала не мешает самому исправлению.
    try {
        $e = [pscustomobject]@{ Id = [guid]::NewGuid().ToString('N'); Time = (Get-Date).ToString('s'); Kind = $Kind; Title = $Title; Data = [pscustomobject]$Data; Done = $false }
        Save-UndoLog (@(Read-UndoLog) + @($e))
    } catch { }
}

function Test-UndoNeedsAdmin($Entry) {
    if ($script:AdminUndoKinds -contains $Entry.Kind) { return $true }
    if ($Entry.Kind -eq 'consent' -and $Entry.Data.Hive -eq 'HKLM') { return $true }
    return $false
}

function Set-ProxyValues($Data) {
    Set-ItemProperty -Path $script:InetKey -Name ProxyEnable -Value ([int]$Data.ProxyEnable) -Type DWord -ErrorAction Stop
    if ($Data.ProxyServer) { Set-ItemProperty -Path $script:InetKey -Name ProxyServer -Value "$($Data.ProxyServer)" -Type String -ErrorAction Stop }
    if ($Data.AutoConfigURL) { Set-ItemProperty -Path $script:InetKey -Name AutoConfigURL -Value "$($Data.AutoConfigURL)" -Type String -ErrorAction Stop }
}

function Invoke-UndoEntry($Entry) {
    $d = $Entry.Data
    switch ($Entry.Kind) {
        'consent'        { Set-ConsentValue $d.Hive $d.Capability "$($d.Sub)" $d.Old; return $true }
        'proxy'          { Set-ProxyValues $d; return $true }
        'service'        { Set-Service -Name $d.Name -StartupType $d.StartType -ErrorAction Stop; return $true }
        'volume'         {
            # Только если по умолчанию всё то же устройство — иначе можно приглушить уже другую гарнитуру
            if ($d.Id) {
                $cur = Get-AudioLevels; $ep = $null
                if ($null -ne $cur) { if ([int]$d.Flow -eq 1) { $ep = $cur.Capture } else { $ep = $cur.Render } }
                if ($null -eq $ep -or "$($ep.Id)" -ne "$($d.Id)") { return $false }
            }
            return [bool](Set-AudioEndpointState ([int]$d.Flow) ([bool]$d.Muted) ([int]$d.Level))
        }
        'site-block'     {
            if ($d.Process -and @(Get-RunningProcessNames) -contains $d.Process) {
                if (-not (Read-YesNo "  Чтобы вернуть запрет, нужно закрыть $($d.Browser). Закрыть?")) { return $false }
                try { Stop-Process -Name $d.Process -Force -ErrorAction Stop } catch { }
                Start-Sleep -Seconds 2
            }
            return [bool](Restore-SiteBlock $d)
        }
        'device-enabled' { Disable-PnpDevice -InstanceId $d.Id -Confirm:$false -ErrorAction Stop; return $true }
        'file-restore'   {
            if ($d.Process -and @(Get-RunningProcessNames) -contains $d.Process) {
                if (-not (Read-YesNo "  Чтобы вернуть настройки, нужно закрыть $($d.Browser). Закрыть?")) { return $false }
                try { Stop-Process -Name $d.Process -Force -ErrorAction Stop } catch { }
                Start-Sleep -Seconds 2
            }
            Copy-Item -LiteralPath $d.Backup -Destination $d.File -Force -ErrorAction Stop
            return $true
        }
        default          { return $false }
    }
}

function Invoke-Undo([bool]$AdminOnlyRun = $false) {
    $all = @(Read-UndoLog)
    $pending = @($all | Where-Object { -not $_.Done })
    [array]::Reverse($pending)
    if ($pending.Count -eq 0) { return 'Откатывать нечего' }
    $reversible = @($pending | Where-Object { $_.Kind -ne 'info' })
    $info = @($pending | Where-Object { $_.Kind -eq 'info' })
    if ($AdminOnlyRun) {
        $reversible = @($reversible | Where-Object { Test-UndoNeedsAdmin $_ })
        $info = @()
    } else {
        Write-Host '  Что было изменено (последнее сверху):' -ForegroundColor Cyan
        foreach ($e in $pending) {
            if ($e.Kind -eq 'info') { Write-Host "    нельзя откатить: $($e.Title)" -ForegroundColor DarkGray }
            else { Write-Host "    можно откатить:  $($e.Title)" }
        }
        if ($reversible.Count -eq 0) {
            foreach ($e in $info) { $e.Done = $true }
            Save-UndoLog $all
            return 'Откатывать нечего: остались только необратимые действия (список выше)'
        }
        if (-not (Read-YesNo '  Откатить всё, что можно?')) { return 'Ничего не откатывал' }
    }
    $isAdmin = Test-IsAdmin
    $done = @(); $failed = @(); $needAdmin = @()
    foreach ($e in $reversible) {
        if ((Test-UndoNeedsAdmin $e) -and -not $isAdmin) { $needAdmin += $e; continue }
        $ok = $false
        try { $ok = [bool](Invoke-UndoEntry $e) } catch { $ok = $false }
        if ($ok) { $e.Done = $true; $done += $e.Title } else { $failed += $e.Title }
    }
    foreach ($e in $info) { $e.Done = $true }
    Save-UndoLog $all
    if ($needAdmin.Count -gt 0) {
        if (Read-YesNo "  Ещё $($needAdmin.Count) отката требуют прав администратора. Запросить?") {
            try {
                Start-Process -FilePath 'powershell.exe' -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Undo -AdminOnly -Elevated" -Verb RunAs -Wait -ErrorAction Stop
                $left = @(@(Read-UndoLog) | Where-Object { -not $_.Done -and $_.Kind -ne 'info' })
                $done += @($needAdmin | Where-Object { $id = $_.Id; -not (@($left | Where-Object { $_.Id -eq $id }).Count) } | ForEach-Object { $_.Title })
                $failed += @($needAdmin | Where-Object { $id = $_.Id; @($left | Where-Object { $_.Id -eq $id }).Count } | ForEach-Object { $_.Title })
            } catch { $failed += @($needAdmin | ForEach-Object { $_.Title }) }
        } else { $failed += @($needAdmin | ForEach-Object { $_.Title }) }
    }
    $msg = "Откачено: $($done.Count)"
    if ($failed.Count -gt 0) { $msg += "; не удалось: $($failed -join ', ')" }
    return $msg
}

# ============================================================ глубокий ремонт (lesson-check.bat -Deep)

function Read-Choice([string]$Prompt) { return "$(Read-Host $Prompt)".Trim() }

function Get-OsBuild([string]$Version) {
    $parts = "$Version" -split '\.'
    if ($parts.Count -ge 3 -and $parts[2] -match '^\d+$') { return [int]$parts[2] }
    return $null
}

function Get-RestorePoints {
    try {
        return @(Get-ComputerRestorePoint -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{ Time = [Management.ManagementDateTimeConverter]::ToDateTime($_.CreationTime); Description = "$($_.Description)" } })
    } catch { return @() }
}

function Select-RecentRestorePoint($Points, [datetime]$Now, [int]$Hours = 24) {
    # Windows разрешает одну новую точку в сутки, поэтому подходит и сегодняшняя
    return @(@($Points) | Where-Object { $null -ne $_ -and $_.Time -gt $Now.AddHours(-$Hours) -and $_.Time -le $Now.AddMinutes(5) } |
        Sort-Object -Property Time -Descending | Select-Object -First 1)
}

function New-LessonRestorePoint {
    try { Checkpoint-Computer -Description 'lesson-check: перед глубоким ремонтом' -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop -WarningAction SilentlyContinue; return $true } catch { return $false }
}

function Enable-SystemProtection {
    try {
        Enable-ComputerRestore -Drive "$($env:SystemDrive)\" -ErrorAction Stop
        Add-Undo 'info' @{} 'Включена защита системы (точки восстановления) — оставляем включённой'
        return $true
    } catch { return $false }
}

function Confirm-RestorePoint {
    Write-Host '  Создаю точку восстановления Windows (до минуты)...' -ForegroundColor Gray
    $null = New-LessonRestorePoint
    $rp = @(Select-RecentRestorePoint (Get-RestorePoints) (Get-Date))
    if ($rp.Count -eq 0) {
        if (Read-YesNo '  Точку восстановления создать не удалось — возможно, выключена защита системы. Включить её для системного диска и попробовать ещё раз?') {
            if (Enable-SystemProtection) {
                $null = New-LessonRestorePoint
                $rp = @(Select-RecentRestorePoint (Get-RestorePoints) (Get-Date))
            }
        }
    }
    if ($rp.Count -gt 0) {
        $line = "Точка восстановления: $($rp[0].Time.ToString('dd.MM HH:mm')) — $($rp[0].Description)"
        Write-Host "  $line" -ForegroundColor Green
        $script:DeepLog.Add($line)
        return $true
    }
    if (Read-YesNo '  Продолжить БЕЗ точки восстановления? Не рекомендуется: откатить драйверы будет нечем') {
        $script:DeepLog.Add('Без точки восстановления (специалист подтвердил)')
        return $true
    }
    return $false
}

function Get-ReinstallCandidates($State) {
    # Только камера, звуковая карта (не аудио монитора) и Bluetooth. Сеть и Wi-Fi — никогда.
    $out = @()
    foreach ($c in @(Select-RealCameras $State.Cameras)) { $out += [pscustomobject]@{ Kind = 'Камера'; Name = $c.Name; Id = $c.Id; Code = $c.Code; Class = "$($c.Class)" } }
    foreach ($c in @(@($State.SoundCards) | Where-Object { $null -ne $_ -and $_.Name -notmatch $script:DisplayAudioPattern })) {
        $out += [pscustomobject]@{ Kind = 'Звук'; Name = $c.Name; Id = $c.Id; Code = $c.Code; Class = "$($c.Class)" }
    }
    # Bluetooth: только сам модуль (USB/PCI/ACPI). Сопряжённые наушники (BTHENUM) не трогаем — иначе их придётся заново сопрягать
    foreach ($c in @(@($State.Bluetooth) | Where-Object { $null -ne $_ -and "$($_.Id)" -match '^(USB|PCI|ACPI)\\' -and $_.Name -notmatch 'Enumerator|Перечислитель|RFCOMM|Protocol TDI' })) {
        $out += [pscustomobject]@{ Kind = 'Bluetooth'; Name = $c.Name; Id = $c.Id; Code = $c.Code; Class = "$($c.Class)" }
    }
    return @($out | Where-Object { $_.Id -and $_.Class -ne 'Net' -and $_.Name -notmatch '(?i)Wi-?Fi|Wireless LAN|Ethernet|Network Adapter|Сетев' })
}

function Get-PnpUtilPath {
    # 32-битный PowerShell на 64-битной Windows не видит pnputil в System32 — он в sysnative
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess -and $env:windir) { return (Join-Path $env:windir 'sysnative\pnputil.exe') }
    return 'pnputil.exe'
}

function Invoke-PnpUtil([string[]]$PnpArgs) {
    try {
        $exe = Get-PnpUtilPath
        $out = (& $exe @PnpArgs 2>&1 | Out-String).Trim()
        return [pscustomobject]@{ Code = $LASTEXITCODE; Output = $out }
    } catch { return [pscustomobject]@{ Code = -1; Output = "$($_.Exception.Message)" } }
}

function Get-DeviceById([string]$Id) {
    try {
        $esc = $Id -replace '\\', '\\' -replace "'", "\'"
        $d = @(Get-CimInstance Win32_PnPEntity -Filter "PNPDeviceID='$esc'" -OperationTimeoutSec 10 -ErrorAction Stop)
        if ($d.Count -eq 0) { return $null }
        return [pscustomobject]@{ Name = $d[0].Name; Code = [int]$d[0].ConfigManagerErrorCode }
    } catch { return $null }
}

function Invoke-ReinstallDriver($Device, $State) {
    if ("$($Device.Class)" -eq 'Net') { return 'Сетевые устройства программа не переустанавливает' }
    $build = Get-OsBuild $State.OsVersion
    if ($null -eq $build -or $build -lt 19041) {
        return "На этой Windows (сборка $build) автоматически нельзя. Вручную: Диспетчер устройств → правый клик по «$($Device.Name)» → Удалить устройство → меню Действие → Обновить конфигурацию оборудования"
    }
    $r = Invoke-PnpUtil @('/remove-device', $Device.Id)
    $removed = ($r.Code -eq 0 -or $r.Code -eq 3010)      # 3010 = удалено, Windows просит перезагрузку
    # Пересканируем всегда: даже «неудачное» удаление могло остановить устройство
    $null = Invoke-PnpUtil @('/scan-devices')
    $back = $null
    for ($i = 0; $i -lt 10; $i++) {
        Start-Sleep -Seconds 2
        $back = Get-DeviceById $Device.Id
        if ($null -ne $back -and $back.Code -eq 0) { break }
    }
    if (-not $removed) {
        if ($null -ne $back -and $back.Code -eq 0) { return "Не удалось переустановить «$($Device.Name)» (pnputil: код $($r.Code)) — устройство работает как раньше" }
        return "ВНИМАНИЕ: не удалось переустановить «$($Device.Name)» (pnputil: код $($r.Code)), и сейчас оно не работает. Перезагрузите компьютер; не поможет — откатите точку восстановления (Win+R → rstrui)"
    }
    $script:Actions.Add("Переустановлен драйвер: $($Device.Name)")
    Add-Undo 'info' @{} "Переустановлен драйвер: $($Device.Name) — откат только точкой восстановления (Win+R → rstrui)"
    $rb = ''; if ($r.Code -eq 3010) { $rb = ' Windows просит перезагрузку — сделайте её после урока.' }
    if ($null -ne $back -and $back.Code -eq 0) { return "Готово: «$($Device.Name)» установлено заново и работает.$rb" }
    if ($null -ne $back) { return "ВНИМАНИЕ: «$($Device.Name)» вернулось с ошибкой ($(Get-ErrorCodeText $back.Code)). Перезагрузите компьютер; не поможет — откатите точку восстановления (Win+R → rstrui)" }
    return "ВНИМАНИЕ: «$($Device.Name)» пока не вернулось. Перезагрузите компьютер — обычно Windows ставит его при загрузке. Не появится — откатите точку восстановления (Win+R → rstrui)"
}

function Invoke-WuJob([scriptblock]$Block, [object[]]$JobArgs, [int]$TimeoutSec) {
    # Центр обновления иногда «висит» без конца: работаем в отдельном процессе и не ждём дольше лимита
    $job = Start-Job -ScriptBlock $Block -ArgumentList $JobArgs
    if (-not (Wait-Job -Job $job -Timeout $TimeoutSec)) {
        Stop-Job -Job $job; Remove-Job -Job $job -Force
        throw "Центр обновления не ответил за $([int][math]::Ceiling($TimeoutSec / 60)) мин"
    }
    try { $out = @(Receive-Job -Job $job -ErrorAction Stop) } finally { Remove-Job -Job $job -Force }
    return $out
}

function Search-WuDrivers {
    $rows = Invoke-WuJob {
        $session = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $searcher.ServerSelection = 2
        $res = $searcher.Search("IsInstalled=0 and IsHidden=0 and Type='Driver'")
        foreach ($u in $res.Updates) { [pscustomobject]@{ Title = "$($u.Title)"; DriverClass = "$($u.DriverClass)"; UpdateId = "$($u.Identity.UpdateID)" } }
    } @() 300
    return @($rows | ForEach-Object { [pscustomobject]@{ Title = "$($_.Title)"; DriverClass = "$($_.DriverClass)"; UpdateId = "$($_.UpdateId)" } })
}

function Select-WuOffer($Updates) {
    # Только то, что касается урока. Сеть, прошивки (BIOS), чипсет — не предлагаем.
    $allowed = @('Camera', 'Image', 'MEDIA', 'Bluetooth', 'AudioProcessingObject', 'AudioEndpoint')
    return @(@($Updates) | Where-Object { $null -ne $_ -and $allowed -contains $_.DriverClass -and $_.Title -notmatch '(?i)Wi-?Fi|Wireless LAN|WLAN|Ethernet|Network|Firmware|BIOS' })
}

function Install-WuDriver($Item) {
    $r = @(Invoke-WuJob {
        param($id)
        $session = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher(); $searcher.ServerSelection = 2
        $res = $searcher.Search("UpdateID='$id'")
        if ($res.Updates.Count -eq 0) { return [pscustomobject]@{ ResultCode = 4; RebootRequired = $false } }
        $u = $res.Updates.Item(0)
        if (-not $u.EulaAccepted) { $u.AcceptEula() }
        $coll = New-Object -ComObject Microsoft.Update.UpdateColl; $null = $coll.Add($u)
        $dl = $session.CreateUpdateDownloader(); $dl.Updates = $coll; $d = $dl.Download()
        if ($d.ResultCode -ne 2 -and $d.ResultCode -ne 3) { return [pscustomobject]@{ ResultCode = [int]$d.ResultCode; RebootRequired = $false } }
        $inst = $session.CreateUpdateInstaller(); $inst.Updates = $coll
        $x = $inst.Install()
        [pscustomobject]@{ ResultCode = [int]$x.ResultCode; RebootRequired = [bool]$x.RebootRequired }
    } @($Item.UpdateId) 900)
    if ($r.Count -eq 0) { return [pscustomobject]@{ ResultCode = 4; RebootRequired = $false } }
    return [pscustomobject]@{ ResultCode = [int]$r[-1].ResultCode; RebootRequired = [bool]$r[-1].RebootRequired }
}

function Get-BrokenLessonDevices($State) {
    $out = @(@(Get-ReinstallCandidates $State) | Where-Object { $_.Code -ne 0 })
    $out += @(@($State.ProblemDevices) | Where-Object { $null -ne $_ -and "$($_.Class)" -ne 'Net' -and "$($_.Name)" -match '(?i)Camera|Webcam|Камер|Audio|Аудио|Звук|Sound|Microphone|Микрофон|Bluetooth' })
    return $out
}

function Invoke-WuDrivers($State = $null) {
    if (@(Get-BrokenLessonDevices $State).Count -eq 0) {
        # Всё работает: новый драйвер из Центра обновления может заменить фирменный и испортить, например, микрофон ноутбука
        if (-not (Read-YesNo '  Камера, звук и Bluetooth работают без ошибок. Драйвер из Центра обновления может заменить фирменный и испортить звук. Всё равно искать?')) {
            return 'Не искал: устройства работают без ошибок'
        }
    }
    Write-Host '  Ищу драйверы в Центре обновления Windows (до 5 минут)...' -ForegroundColor Gray
    $all = @()
    try { $all = @(Search-WuDrivers) } catch { return "Центр обновления недоступен: $($_.Exception.Message)" }
    $offer = @(Select-WuOffer $all)
    $skipped = $all.Count - $offer.Count
    $note = ''; if ($skipped -gt 0) { $note = " (ещё $skipped не про камеру и звук — не предлагаю)" }
    if ($offer.Count -eq 0) { return "Новых драйверов для камеры, звука и Bluetooth нет$note" }
    $ok = @(); $bad = @(); $reboot = $false
    foreach ($o in $offer) {
        if (-not (Read-YesNo "  Установить: $($o.Title)? (заменит текущий драйвер; откат — точкой восстановления)")) { continue }
        try { $r = Install-WuDriver $o } catch { $bad += $o.Title; continue }
        if ($r.ResultCode -eq 2 -or $r.ResultCode -eq 3) {
            $ok += $o.Title
            if ($r.RebootRequired) { $reboot = $true }
        } else { $bad += $o.Title }
    }
    if ($ok.Count -gt 0) {
        $script:Actions.Add("Установлены драйверы из Центра обновления: $($ok -join ', ')")
        Add-Undo 'info' @{} "Драйверы из Центра обновления: $($ok -join ', ') — откат только точкой восстановления (Win+R → rstrui)"
    }
    $msg = "Установлено: $($ok.Count)"
    if ($bad.Count -gt 0) { $msg += "; не удалось: $($bad -join ', ')" }
    if ($reboot) { $msg += '. НУЖНА ПЕРЕЗАГРУЗКА — после неё подключитесь через RustDesk заново' }
    return $msg + $note
}

function Get-ComputerModel {
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $friendly = ''
        try { $friendly = "$((Get-CimInstance Win32_ComputerSystemProduct -ErrorAction Stop).Version)" } catch { }
        return [pscustomobject]@{ Manufacturer = "$($cs.Manufacturer)".Trim(); Model = "$($cs.Model)".Trim(); Friendly = $friendly.Trim() }
    } catch { return $null }
}

function Get-VendorDriverInfo($Model) {
    $man = ''; $name = ''
    if ($null -ne $Model) {
        $man = $Model.Manufacturer; $name = $Model.Model
        if ($man -match '(?i)lenovo' -and $Model.Friendly) { $name = $Model.Friendly }
    }
    $full = ("$man $name").Trim()
    $vendors = @(
        @{ P = 'lenovo'; Url = 'https://pcsupport.lenovo.com/'; Tool = 'Lenovo Vantage' },
        @{ P = '^hp|hewlett'; Url = 'https://support.hp.com/drivers'; Tool = 'HP Support Assistant' },
        @{ P = 'dell'; Url = 'https://www.dell.com/support/home'; Tool = 'Dell SupportAssist' },
        @{ P = 'asus'; Url = 'https://www.asus.com/support/download-center/'; Tool = 'MyASUS' },
        @{ P = 'acer'; Url = 'https://www.acer.com/support'; Tool = 'Acer Care Center' },
        @{ P = 'micro-star|^msi'; Url = 'https://www.msi.com/support'; Tool = 'MSI Center' },
        @{ P = 'huawei'; Url = 'https://consumer.huawei.com/support/'; Tool = 'PC Manager' },
        @{ P = 'samsung'; Url = 'https://www.samsung.com/support/'; Tool = 'Samsung Update' }
    )
    foreach ($v in $vendors) {
        if ($man -match "(?i)$($v.P)") { return [pscustomobject]@{ Name = $full; Url = $v.Url; Tool = $v.Tool } }
    }
    $q = [Uri]::EscapeDataString("$full драйверы официальный сайт")
    return [pscustomobject]@{ Name = $full; Url = "https://yandex.ru/search/?text=$q"; Tool = '' }
}

function Format-DeepReport($Model) {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("Глубокий ремонт (проверка перед уроком v$script:Version) — $((Get-Date).ToString('dd.MM.yyyy HH:mm'))")
    if ($null -ne $Model) { $lines.Add("Компьютер: $(("$($Model.Manufacturer) $($Model.Model) $($Model.Friendly)").Trim())") }
    if ($script:DeepLog.Count -gt 0) { $lines.Add('Сделано:'); foreach ($l in $script:DeepLog) { $lines.Add("  - $l") } }
    else { $lines.Add('Ничего не меняли') }
    $lines.Add('Откат: lesson-check.bat -Undo; драйверы — точкой восстановления (Win+R → rstrui)')
    $lines.Add("#lesson-check $script:Version deep=1 steps=$($script:DeepLog.Count)")
    return ($lines -join "`r`n")
}

function Invoke-Deep {
    Write-Host ''
    Write-Host "  ГЛУБОКИЙ РЕМОНТ v$script:Version — переустановка драйверов камеры, звука и Bluetooth" -ForegroundColor Cyan
    if (-not (Test-IsAdmin)) {
        Write-Host '  Нужны права администратора — откроется отдельное окно глубокого ремонта.' -ForegroundColor Gray
        try {
            Start-Process -FilePath 'powershell.exe' -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Deep -Elevated" -Verb RunAs -Wait -ErrorAction Stop
            return 'elevated'
        } catch { Write-Host '  Не удалось получить права администратора.' -ForegroundColor Red; return 'no-admin' }
    }
    $script:DeepLog = New-Object System.Collections.Generic.List[string]
    $model = Get-ComputerModel
    if (-not (Confirm-RestorePoint)) {
        Write-Host '  Остановлено: без точки восстановления не продолжаю.' -ForegroundColor Yellow
        return 'stopped'
    }
    $vendor = Get-VendorDriverInfo $model
    $state = Get-State -Light
    $finished = $false
    while (-not $finished) {
        Write-Host ''
        Write-Host '  1 — Переустановить драйвер (камера, звук, Bluetooth)'
        Write-Host '  2 — Найти драйверы в Центре обновления Windows'
        Write-Host "  3 — Открыть страницу драйверов производителя: $($vendor.Name)"
        Write-Host '  0 — Готово'
        $c = Read-Choice '  Выберите'
        switch ($c) {
            '1' {
                $cands = @(Get-ReinstallCandidates $state)
                if ($cands.Count -eq 0) { Write-Host '  Подходящих устройств нет' -ForegroundColor Yellow; break }
                for ($i = 0; $i -lt $cands.Count; $i++) {
                    $st = 'работает'; if ($cands[$i].Code -ne 0) { $st = Get-ErrorCodeText $cands[$i].Code }
                    Write-Host ("    {0}) [{1}] {2} — {3}" -f ($i + 1), $cands[$i].Kind, $cands[$i].Name, $st)
                }
                $n = Read-Choice '  Номер устройства (Enter — назад)'
                $idx = 0
                if (-not [int]::TryParse($n, [ref]$idx) -or $idx -lt 1 -or $idx -gt $cands.Count) { break }
                $dev = $cands[$idx - 1]
                $extra = ''; if ($dev.Kind -eq 'Bluetooth') { $extra = ' Bluetooth-наушники на это время отключатся (сопряжение сохранится).' }
                if (Read-YesNo "  Переустановить драйвер «$($dev.Name)»? Устройство на несколько секунд пропадёт.$extra") {
                    $res = Invoke-ReinstallDriver $dev $state
                    Write-Host "    $res" -ForegroundColor Gray
                    $script:DeepLog.Add($res)
                    $state = Get-State -Light
                }
            }
            '2' { $res = Invoke-WuDrivers $state; Write-Host "    $res" -ForegroundColor Gray; $script:DeepLog.Add($res) }
            '3' {
                $tool = ''; if ($vendor.Tool) { $tool = " Фирменная программа: $($vendor.Tool)." }
                Write-Host "    $($vendor.Url)$tool Качайте драйверы только с сайта производителя, не со «сборников драйверов»." -ForegroundColor Gray
                # через explorer.exe — страница откроется в обычном браузере ученика, а не от администратора
                try { Start-Process -FilePath 'explorer.exe' -ArgumentList $vendor.Url -ErrorAction Stop } catch { }
                $script:DeepLog.Add("Открыта страница драйверов: $($vendor.Url)")
            }
            { $_ -eq '0' -or $_ -eq '' } { $finished = $true }
            default { Write-Host '  Нет такого пункта' -ForegroundColor Yellow }
        }
    }
    $saved = Save-Report (Format-DeepReport $model)
    Write-ReportSaved $saved
    return 'done'
}

# ============================================================ экран

function Get-ConsoleWidth {
    try { $w = [int]$Host.UI.RawUI.WindowSize.Width; if ($w -gt 0) { return $w } } catch { }
    return 100
}

function Write-Findings($Findings) {
    $width = (Get-ConsoleWidth) - 1
    foreach ($x in $Findings) {
        $color = 'Green'; if ($x.Level -eq 'WARN') { $color = 'Yellow' } elseif ($x.Level -eq 'BAD') { $color = 'Red' }
        foreach ($l in (Format-Wrapped ("  {0} {1}: {2}" -f (Get-Mark $x.Level), $x.Area, $x.Text) $width '       ')) { Write-Host $l -ForegroundColor $color }
        if ($x.Hint -and $x.Level -ne 'OK') {
            foreach ($l in (Format-Wrapped "       → $($x.Hint)" $width '         ')) { Write-Host $l -ForegroundColor DarkGray }
        }
    }
}

function Get-FixKeys($Findings) {
    $keys = @($Findings | Where-Object { $_.Fix -and $_.Level -ne 'OK' } | ForEach-Object { $_.Fix } | Select-Object -Unique)
    return $keys
}

function Main {
    if ($Fix) {
        # Окно администратора: только одно исправление, без долгой проверки интернета. Код выхода 0 = что-то сделано.
        $st = Get-State -Light
        $st.IsAdmin = Test-IsAdmin
        $n0 = $script:Actions.Count
        Write-Host (Invoke-OneFix $Fix $st)
        Start-Sleep -Seconds 2
        if ($script:Actions.Count -gt $n0) { exit 0 } else { exit 3 }
    }
    if ($Undo) {
        Write-Host ''; Write-Host "  ОТКАТ ИЗМЕНЕНИЙ (проверка перед уроком v$script:Version)" -ForegroundColor Cyan
        Write-Host "  $(Invoke-Undo ([bool]$AdminOnly))" -ForegroundColor Gray
        Wait-ElevatedClose
        return
    }
    if ($Deep) {
        try { $null = Invoke-Deep }
        catch {
            $msg = "$($_.Exception.Message)"
            Write-Host "  Глубокий ремонт споткнулся: $msg" -ForegroundColor Red
            $script:DeepLog.Add("ПРЕРВАНО ОШИБКОЙ: $msg")
            Write-ReportSaved (Save-Report (Format-DeepReport $null))
        }
        Wait-ElevatedClose
        return
    }
    try { Invoke-Check }
    catch {
        # Что-то упало посреди проверки — всё равно отдаём отчёт: что успели проверить, что сделали, и саму ошибку
        $e = $_
        $where = ''; try { $where = " (строка $($e.InvocationInfo.ScriptLineNumber))" } catch { }
        $msg = "$($e.Exception.Message)$where"
        Write-Host ''
        Write-Host "  Программа споткнулась: $msg" -ForegroundColor Red
        $saved = Save-Report (Format-CrashReport $msg)
        Write-ReportSaved $saved
        Write-Host '  Пришлите этот отчёт разработчику программы.' -ForegroundColor Gray
    }
}

function Wait-ElevatedClose {
    if ($Elevated) { try { $null = Read-Host '  Нажмите Enter, чтобы закрыть это окно' } catch { } }
}

function Format-CrashReport([string]$Message) {
    $lines = New-Object System.Collections.Generic.List[string]
    if ($null -ne $script:LastState -and $null -ne $script:LastFindings) {
        $lines.Add((Format-Report $script:LastState $script:LastFindings -NoTag))
    } else {
        $lines.Add("Проверка перед уроком v$script:Version — $((Get-Date).ToString('dd.MM.yyyy HH:mm'))")
        if ($script:Actions.Count -gt 0) { $lines.Add('Сделано:'); foreach ($a in $script:Actions) { $lines.Add("  - $a") } }
    }
    $lines.Add("ПРОВЕРКА ПРЕРВАНА ОШИБКОЙ: $Message")
    $lines.Add((Format-ReportTag $script:LastFindings -Crashed))
    return ($lines -join "`r`n")
}

function Write-ReportSaved($Saved) {
    Write-Host ''
    if ($Saved.Path) { Write-Host "  Отчёт сохранён: $($Saved.Path)" -ForegroundColor Cyan }
    else { Write-Host '  Отчёт не удалось сохранить в файл' -ForegroundColor Red }
    if ($Saved.Copied) { Write-Host '  Отчёт скопирован — вставьте его в комментарий заявки (Ctrl+V)' -ForegroundColor Cyan }
}

function Invoke-Check {
    $script:LastState = $null; $script:LastFindings = $null
    try { $Host.UI.RawUI.WindowTitle = 'Проверка перед уроком' } catch { }
    Write-Host ''
    Write-Host "  ПРОВЕРКА ПЕРЕД УРОКОМ v$script:Version" -ForegroundColor Cyan
    Write-Host '  Сначала только проверяю, ничего не меняя (около 40 секунд)...' -ForegroundColor Gray
    Write-Host ''
    $state = Get-State
    $before = Get-Findings $state
    $script:LastState = $state; $script:LastFindings = $before
    Write-Findings $before
    $keys = @(Get-FixKeys $before)
    if (-not $CheckOnly -and $keys.Count -gt 0) {
        Write-Host ''
        Write-Host '  Что можно исправить:' -ForegroundColor Cyan
        foreach ($k in $keys) {
            if (Read-YesNo "  • $(Get-FixTitle $k)?") {
                $n0 = $script:Actions.Count
                $res = Invoke-OneFix $k $state
                if ($res -eq 'NEED_ADMIN') {
                    if (Read-YesNo '    Нужны права администратора. Запросить?') { $res = Start-Elevated $k } else { $res = 'Пропущено: нет прав администратора' }
                }
                Write-Host "    $res" -ForegroundColor Gray
                if ($script:Actions.Count -gt $n0) { $script:AppliedFixes.Add($k) }
            }
        }
    }
    if (-not $CheckOnly -and @($keys) -notcontains 'clear-cache' -and @($state.CacheDirs).Count -gt 0) {
        if (Read-YesNo '  Дополнительно: очистить кэш браузеров? (помогает, если урок «висит» или не грузится)') {
            Write-Host "    $(Clear-BrowserCaches $state)" -ForegroundColor Gray
        }
    }
    $final = $before; $finalState = $state; $was = $null
    if ($script:Actions.Count -gt 0) {
        Write-Host ''
        Write-Host '  Проверяю ещё раз...' -ForegroundColor Gray
        $reuse = $state
        if (@($script:AppliedFixes | Where-Object { @('disable-proxy', 'flush-dns', 'sync-time') -contains $_ }).Count -gt 0) { $reuse = $null }
        $finalState = Get-State -Reuse $reuse
        $final = Get-Findings $finalState
        $script:LastState = $finalState; $script:LastFindings = $final
        Write-Findings $final
        $was = $before
    }
    if (-not $CheckOnly -and (Read-YesNo '  Проверить микрофон: записать 3 секунды и сразу проиграть?')) {
        $mic = Invoke-MicTest $finalState
        Write-Findings @($mic)
        $final = @($final) + @($mic)
        $script:LastFindings = $final
    }
    $report = Format-Report $finalState $final $was
    $saved = Save-Report $report
    Write-ReportSaved $saved
    if ($script:UndoWriteFailed) { Write-Host '  Журнал отката записать не удалось — откат недоступен' -ForegroundColor Yellow }
    elseif (@(@(Read-UndoLog) | Where-Object { -not $_.Done }).Count -gt 0) { Write-Host '  Откатить изменения: lesson-check.bat -Undo' -ForegroundColor Gray }
    # Глубокий ремонт предлагаем только для поломок самих устройств: «нет устройства», ошибка драйвера,
    # тишина в записи при разрешённом и включённом микрофоне. Запреты и громкость драйвером не чинятся.
    $micBlocked = (Test-ConsentDenied $finalState.MicConsent) -or (@(@($final) | Where-Object { $_.Level -eq 'BAD' -and $_.Fix -eq 'unmute-audio' }).Count -gt 0)
    $hard = @(@($final) | Where-Object {
        $_.Level -eq 'BAD' -and (
            (@('Камера', 'Микрофон', 'Звук') -contains $_.Area -and (@('reset-camera', 'reset-audio-device', 'restart-audio') -contains $_.Fix -or $_.Text -match 'не видит')) -or
            ($_.Area -eq 'Тест микрофона' -and -not $micBlocked)) })
    if (-not $CheckOnly -and $hard.Count -gt 0) {
        if (Read-YesNo '  С камерой или звуком осталась проблема. Запустить глубокий ремонт (переустановка драйверов, с точкой восстановления)?') {
            $null = Invoke-Deep
            return
        }
    }
    Write-Host '  Дальше: откройте страницу проверки перед уроком в браузере — она проверит камеру и звук в самом браузере.' -ForegroundColor Gray
}

if ($MyInvocation.InvocationName -ne '.') { Main }
