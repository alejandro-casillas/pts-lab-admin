#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Configura el estandar PTS para equipos Student.

.DESCRIPTION
    Aplica de forma controlada el estandar de usuario estudiante:
      - MLGPO para No administradores:
          * bloquea Configuracion y Panel de control;
          * fija el fondo institucional;
          * impide cambiar el fondo.
      - Branding institucional:
          * copia assets\wallpapers\fondo-pts.jpg a
            C:\ProgramData\PTS\Branding\fondo-pts.jpg.
      - AppLocker:
          * EXE, MSI, Script y Appx;
          * AuditOnly por defecto cuando se usa -Apply;
          * puede pasar a Enforcement de forma EXPLICITA con
            -Apply -EnforceAppLocker.
          * DLL queda NotConfigured.

    Antes de modificar:
      - valida privilegios, estandar y laboratorio;
      - valida que el equipo sea Student;
      - valida cuentas Alumnos y Soporte;
      - exige que AppLocker este limpio o ya pertenezca al estandar PTS;
      - exige que MLGPO este limpio o coincida exactamente con PTS;
      - respalda artefactos existentes antes de reemplazarlos.

    Por defecto NO modifica Windows.

    Primera fase recomendada:

        .\scripts\04-ConfigureStudentPolicies.ps1
        .\scripts\04-ConfigureStudentPolicies.ps1 -Apply

    La segunda orden aplica AppLocker en AuditOnly.

    Solo despues de validar eventos y compatibilidad:

        .\scripts\04-ConfigureStudentPolicies.ps1 -EnforceAppLocker
        .\scripts\04-ConfigureStudentPolicies.ps1 -Apply -EnforceAppLocker

.NOTES
    Proyecto: pts-lab-admin
    Preparatoria Tonala Sur

    IMPORTANTE:
    -Apply SI modifica configuracion del sistema.
    -EnforceAppLocker NO hace cambios por si solo; cambia el objetivo
    de la simulacion/aplicacion a Enforcement.
#>

[CmdletBinding()]
param (
    [switch]$Apply,
    [switch]$EnforceAppLocker
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# ------------------------------------------------------------
# 1. CONSTANTES
# ------------------------------------------------------------

$PtsPolicyVersion = "1.0"

$NonAdministratorsSid = "S-1-5-32-545"
$AdministratorsSid = "S-1-5-32-544"
$EveryoneSid = "S-1-1-0"

$AppLockerRuntimeDirectory = "C:\Windows\System32\AppLocker"

# GUID legacy conocidos de 02-CleanLegacyPolicies.ps1.
$LegacyAppLockerRuleIds = @(
    "921cc481-6e17-4653-8f75-050b80acca20",
    "a61c8b2c-a319-4cd0-9690-d2177cad7b51",
    "fd686d83-a829-4351-8ff4-27c7de5755d2",
    "a9e18c21-ff8f-43cf-b9fc-db40eed693ba"
)

# IDs estables del estandar PTS v1.
$PtsRuleIds = [ordered]@{
    ExeAdminAll                  = "4bf5f944-f2a5-4c17-9c92-e77bd7158ee8"
    ExeWindows                   = "594f9c0b-a3b3-4b7d-9175-17a46895abf9"
    ExeProgramFiles              = "f869eb0b-5210-40e9-bb7f-dcb2c3d901ae"

    ExeOneDrive                  = "2d46e927-1845-4b07-a616-56c5e0a6d011"
    ExeOneDriveFileCoAuth        = "a4877e11-d922-4e4b-91c6-11f81016d022"
    ExeOneDriveLauncher          = "8f0c9e33-728b-4b1e-b851-92e10526d033"
    ExeOneDriveStandaloneUpdater = "5b2d1144-883a-4f5c-a1e9-44d32036d044"
    ExeOneDriveSyncService       = "9e6f3355-094b-4a7d-b6c8-77e43046d055"
    ExeDefenderSessionHelper     = "3a1b2266-1c8a-4d9f-a2e1-88f54056d066"

    MsiAdminAll                  = "1444fe79-9a61-4e5d-a8bf-cdde10415221"
    MsiWindowsInstaller          = "8caa5f95-c2ad-4466-9536-dceaafc31909"

    ScriptAdminAll               = "aa4f8c7f-a64f-48fa-95bb-ae232df15aa2"
    ScriptWindows                = "7468fb46-8099-4f0c-97da-8bd03173fd5e"
    ScriptProgramFiles           = "8789b473-c787-4d99-b962-5dd01a5e43cf"

    AppxAdminAll                 = "b07aef89-a514-482f-917e-7a6b6b149104"
    AppxMicrosoftWin             = "05763886-3811-4cda-8c1b-12b3554975c4"
    AppxMicrosoftCorp            = "d10e18a7-5c24-490c-953a-1b68e6e76f6f"
    AppxDenyStore                = "28b62bb6-8d94-4f82-97e4-cdd633dc4440"
    AppxDenyInstaller            = "add55965-359c-467c-9a4b-d8b5178fb432"
}

if ($EnforceAppLocker) {
    $DesiredAppLockerEnforcement = "Enabled"
    $DesiredAppLockerLabel = "ENFORCE"
}
else {
    $DesiredAppLockerEnforcement = "AuditOnly"
    $DesiredAppLockerLabel = "AUDIT ONLY"
}

# ------------------------------------------------------------
# 2. RUTAS DEL PROYECTO
# ------------------------------------------------------------

$ScriptDirectory = $PSScriptRoot
$ProjectRoot = Split-Path $ScriptDirectory -Parent

$StandardPath = Join-Path $ProjectRoot "config\standard.json"
$LabsDirectory = Join-Path $ProjectRoot "config\labs"
$LogsDirectory = Join-Path $ProjectRoot "logs"
$BackupsDirectory = Join-Path $ProjectRoot "backups"
$ToolsDirectory = Join-Path $ProjectRoot "tools"

$LgpoPath = Join-Path $ToolsDirectory "LGPO.exe"

$WallpaperSource = Join-Path `
    $ProjectRoot `
    "assets\wallpapers\fondo-pts.jpg"

$BrandingDirectory = "C:\ProgramData\PTS\Branding"
$WallpaperDestination = Join-Path `
    $BrandingDirectory `
    "fondo-pts.jpg"

$NonAdminPolicyDirectory = Join-Path `
    "C:\Windows\System32\GroupPolicyUsers" `
    $NonAdministratorsSid

$NonAdminRegistryPol = Join-Path `
    $NonAdminPolicyDirectory `
    "User\Registry.pol"

$ComputerName = $env:COMPUTERNAME
$Timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"

$LogPath = Join-Path `
    $LogsDirectory `
    "$ComputerName-StudentPolicies-$Timestamp.txt"

$BackupRoot = Join-Path `
    $BackupsDirectory `
    "$ComputerName-StudentPolicies-$Timestamp"

$WorkingRoot = Join-Path `
    $env:TEMP `
    "PTS-StudentPolicies-$Timestamp"

$DesiredLgpoTextPath = Join-Path $WorkingRoot "pts-nonadmins.txt"
$DesiredAppLockerXmlPath = Join-Path $WorkingRoot "pts-applocker.xml"

# ------------------------------------------------------------
# 3. UTILIDADES
# ------------------------------------------------------------

function ConvertTo-AsciiText {
    param (
        [AllowEmptyString()]
        [string]$Text
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return $Text
    }

    $normalized = $Text.Normalize(
        [System.Text.NormalizationForm]::FormD
    )

    $sb = New-Object System.Text.StringBuilder

    foreach ($c in $normalized.ToCharArray()) {
        $category =
        [System.Globalization.CharUnicodeInfo]::
        GetUnicodeCategory($c)

        if (
            $category -ne
            [System.Globalization.UnicodeCategory]::NonSpacingMark
        ) {
            [void]$sb.Append($c)
        }
    }

    return $sb.ToString()
}

function Write-PolicyLog {
    param (
        [AllowEmptyString()]
        [string]$Message = ""
    )

    $cleanMessage = ConvertTo-AsciiText $Message

    Write-Host $cleanMessage

    $cleanMessage |
    Out-File `
        -FilePath $LogPath `
        -Append `
        -Encoding ascii
}

function Stop-Policy {
    param (
        [Parameter(Mandatory)]
        [string]$Message
    )

    Write-PolicyLog ""
    Write-PolicyLog "[ABORT] $Message"
    Write-PolicyLog ""
    Write-PolicyLog "No se realizaron mas cambios."
    exit 1
}

function Test-IsAdministrator {

    $identity =
    [System.Security.Principal.WindowsIdentity]::GetCurrent()

    $principal =
    New-Object `
        System.Security.Principal.WindowsPrincipal($identity)

    return $principal.IsInRole(
        [System.Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

function Test-LocalGroupMembershipBySid {
    param (
        [Parameter(Mandatory)]
        [string]$UserName,

        [Parameter(Mandatory)]
        [string]$GroupSid
    )

    $user = Get-LocalUser -Name $UserName -ErrorAction Stop
    $group = Get-LocalGroup -SID $GroupSid -ErrorAction Stop

    $members = @(
        Get-LocalGroupMember `
            -Group $group `
            -ErrorAction Stop
    )

    foreach ($member in $members) {
        if (
            $null -ne $member.SID -and
            $member.SID.Value -eq $user.SID.Value
        ) {
            return $true
        }
    }

    return $false
}

function ConvertTo-LgpoString {
    param (
        [Parameter(Mandatory)]
        [string]$Value
    )

    return $Value.Replace("\", "\\")
}

function Get-NormalizedLgpoEntries {
    param (
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string[]]$Lines
    )

    $content = @(
        $Lines |
        ForEach-Object { $_.TrimEnd() } |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace($_) -and
            -not $_.TrimStart().StartsWith(";")
        }
    )

    if (($content.Count % 4) -ne 0) {
        throw "El texto LGPO no contiene grupos validos de 4 lineas."
    }

    $entries = @()

    for ($i = 0; $i -lt $content.Count; $i += 4) {
        $entries += (
            "{0}|{1}|{2}|{3}" -f `
                $content[$i], `
                $content[$i + 1], `
                $content[$i + 2], `
                $content[$i + 3]
        )
    }

    return @($entries | Sort-Object)
}

function Invoke-LgpoParseNonAdmins {
    param (
        [Parameter(Mandatory)]
        [string]$RegistryPolPath
    )

    $output = @(
        & $LgpoPath `
            /parse `
            /q `
            /un `
            $RegistryPolPath `
            2>&1
    )

    if ($LASTEXITCODE -ne 0) {
        throw "LGPO.exe /parse fallo con codigo $LASTEXITCODE. Salida: $($output -join ' | ')"
    }

    return @($output | ForEach-Object { $_.ToString() })
}

function Invoke-LgpoApplyText {
    param (
        [Parameter(Mandatory)]
        [string]$TextPath
    )

    $stdoutPath = Join-Path $WorkingRoot "lgpo-stdout.txt"
    $stderrPath = Join-Path $WorkingRoot "lgpo-stderr.txt"

    $process = Start-Process `
        -FilePath $LgpoPath `
        -ArgumentList @(
        "/t",
        "`"$TextPath`""
    ) `
        -Wait `
        -PassThru `
        -NoNewWindow `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath

    $stdout = @()
    $stderr = @()

    if (Test-Path $stdoutPath) {
        $stdout = @(
            Get-Content $stdoutPath -ErrorAction SilentlyContinue
        )
    }

    if (Test-Path $stderrPath) {
        $stderr = @(
            Get-Content $stderrPath -ErrorAction SilentlyContinue
        )
    }

    $output = @($stdout) + @($stderr)

    if ($process.ExitCode -ne 0) {
        throw (
            "LGPO.exe /t fallo con codigo {0}. Salida: {1}" -f `
                $process.ExitCode,
            ($output -join " | ")
        )
    }

    return @(
        $output |
        ForEach-Object { $_.ToString() }
    )
}

function Get-AppLockerPolicyFingerprint {
    param (
        [Parameter(Mandatory)]
        [xml]$PolicyXml
    )

    $fingerprint = @()

    foreach (
        $collection in
        @($PolicyXml.SelectNodes("/AppLockerPolicy/RuleCollection"))
    ) {
        if ($null -eq $collection) {
            continue
        }

        $type = [string]$collection.Type
        $mode = [string]$collection.EnforcementMode

        $fingerprint += "COLLECTION|$type|$mode"

        foreach ($rule in @($collection.ChildNodes)) {

            if (
                $rule.NodeType -ne
                [System.Xml.XmlNodeType]::Element
            ) {
                continue
            }

            $base = (
                "RULE|{0}|{1}|{2}|{3}|{4}|{5}" -f `
                    $type, `
                    $rule.LocalName, `
                    $rule.Id, `
                    $rule.UserOrGroupSid, `
                    $rule.Action, `
                    $rule.Name
            )

            $fingerprint += $base

            if ($rule.LocalName -eq "FilePathRule") {
                $fingerprint += (
                    "PATH|{0}|{1}" -f `
                        $rule.Id, `
                        $rule.Conditions.FilePathCondition.Path
                )
            }
            elseif ($rule.LocalName -eq "FilePublisherRule") {
                $condition =
                $rule.Conditions.FilePublisherCondition

                $fingerprint += (
                    "PUBLISHER|{0}|{1}|{2}|{3}|{4}|{5}" -f `
                        $rule.Id, `
                        $condition.PublisherName, `
                        $condition.ProductName, `
                        $condition.BinaryName, `
                        $condition.BinaryVersionRange.LowSection, `
                        $condition.BinaryVersionRange.HighSection
                )
            }
        }
    }

    return @($fingerprint | Sort-Object)
}

function Test-StringArrayEqual {
    param (
        [Parameter(Mandatory)]
        [string[]]$A,

        [Parameter(Mandatory)]
        [string[]]$B
    )

    if ($A.Count -ne $B.Count) {
        return $false
    }

    for ($i = 0; $i -lt $A.Count; $i++) {
        if ($A[$i] -ne $B[$i]) {
            return $false
        }
    }

    return $true
}

function Test-RuntimeContainsAnyGuid {
    param (
        [Parameter(Mandatory)]
        [System.IO.FileInfo[]]$Files,

        [Parameter(Mandatory)]
        [string[]]$Guids
    )

    $found = @()

    foreach ($file in $Files) {
        try {
            $bytes = [System.IO.File]::ReadAllBytes($file.FullName)

            $text =
            [System.Text.Encoding]::ASCII.GetString($bytes) +
            [System.Text.Encoding]::Unicode.GetString($bytes)

            foreach ($guid in $Guids) {
                if (
                    $text.IndexOf(
                        $guid,
                        [System.StringComparison]::OrdinalIgnoreCase
                    ) -ge 0
                ) {
                    if ($found -notcontains $guid) {
                        $found += $guid
                    }
                }
            }
        }
        catch {
            # La funcion solo inventaria coincidencias conocidas.
            continue
        }
    }

    return @($found)
}

# ------------------------------------------------------------
# 4. COMPROBACIONES BASICAS
# ------------------------------------------------------------

if (-not (Test-Path $StandardPath)) {
    Write-Error "No se encontro config\standard.json."
    exit 1
}

if (-not (Test-Path $LogsDirectory)) {
    Write-Error "No se encontro el directorio logs."
    exit 1
}

if (-not (Test-Path $BackupsDirectory)) {
    Write-Error "No se encontro el directorio backups."
    exit 1
}

if (-not (Test-Path $LgpoPath)) {
    Write-Error "No se encontro tools\LGPO.exe."
    Write-Error "Este script usa la utilidad oficial LGPO.exe para administrar MLGPO No administradores."
    exit 1
}

if (-not (Test-Path $WallpaperSource)) {
    Write-Error "No se encontro assets\wallpapers\fondo-pts.jpg."
    exit 1
}

try {
    New-Item `
        -ItemType Directory `
        -Path $WorkingRoot `
        -Force |
    Out-Null
}
catch {
    Write-Error "No se pudo crear directorio temporal: $($_.Exception.Message)"
    exit 1
}

# ------------------------------------------------------------
# 5. CARGAR ESTANDAR
# ------------------------------------------------------------

try {
    $Standard =
    Get-Content $StandardPath -Raw -ErrorAction Stop |
    ConvertFrom-Json
}
catch {
    Write-Error `
        "No se pudo leer standard.json: $($_.Exception.Message)"
    exit 1
}

$StudentUser = $Standard.accounts.student.username
$SupportUser = $Standard.accounts.support.username

# ------------------------------------------------------------
# 6. ENCABEZADO
# ------------------------------------------------------------

Write-PolicyLog "============================================================"
Write-PolicyLog " PTS LAB ADMIN - CONFIGURE STUDENT POLICIES"
Write-PolicyLog "============================================================"
Write-PolicyLog ""
Write-PolicyLog "Equipo:             $ComputerName"
Write-PolicyLog "Fecha:              $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-PolicyLog "Usuario actual:     $env:USERNAME"
Write-PolicyLog "Estandar:           $($Standard.standardVersion)"
Write-PolicyLog "PTS Student Policy: $PtsPolicyVersion"
Write-PolicyLog "AppLocker objetivo: $DesiredAppLockerLabel"

if ($Apply) {
    Write-PolicyLog "Modo:               APPLY - CAMBIOS REALES"
}
else {
    Write-PolicyLog "Modo:               SIMULACION - SIN CAMBIOS"
}

Write-PolicyLog ""

# ------------------------------------------------------------
# 7. PREFLIGHT - ADMINISTRADOR Y USUARIOS
# ------------------------------------------------------------

Write-PolicyLog "-------------------- PREFLIGHT --------------------"

if (-not (Test-IsAdministrator)) {
    Stop-Policy "PowerShell no esta ejecutandose como administrador."
}

Write-PolicyLog "[OK] Sesion elevada como administrador."

if ($env:USERNAME -ieq $StudentUser) {
    Stop-Policy "No ejecute este script desde la cuenta '$StudentUser'."
}

Write-PolicyLog "[OK] El script no se esta ejecutando desde '$StudentUser'."

try {
    $Student =
    Get-LocalUser -Name $StudentUser -ErrorAction SilentlyContinue

    $Support =
    Get-LocalUser -Name $SupportUser -ErrorAction SilentlyContinue

    if ($null -eq $Student) {
        Stop-Policy "No existe el usuario '$StudentUser'. Ejecute 03 primero."
    }

    if ($null -eq $Support) {
        Stop-Policy "No existe el usuario '$SupportUser'."
    }

    if (-not $Student.Enabled) {
        Stop-Policy "La cuenta '$StudentUser' esta deshabilitada."
    }

    if (-not $Support.Enabled) {
        Stop-Policy "La cuenta '$SupportUser' esta deshabilitada."
    }

    if (
        Test-LocalGroupMembershipBySid `
            -UserName $StudentUser `
            -GroupSid $AdministratorsSid
    ) {
        Stop-Policy "'$StudentUser' pertenece a Administradores."
    }

    if (
        -not (
            Test-LocalGroupMembershipBySid `
                -UserName $StudentUser `
                -GroupSid $NonAdministratorsSid
        )
    ) {
        Stop-Policy "'$StudentUser' no pertenece a Usuarios."
    }

    if (
        -not (
            Test-LocalGroupMembershipBySid `
                -UserName $SupportUser `
                -GroupSid $AdministratorsSid
        )
    ) {
        Stop-Policy "'$SupportUser' no pertenece a Administradores."
    }

    $StudentSid = $Student.SID.Value

    Write-PolicyLog "[OK] Usuario '$StudentUser' valido."
    Write-PolicyLog "     SID: $StudentSid"
    Write-PolicyLog "[OK] Usuario '$SupportUser' valido y administrador."
}
catch {
    Stop-Policy `
        "No fue posible validar usuarios: $($_.Exception.Message)"
}

# ------------------------------------------------------------
# 8. PREFLIGHT - SESION ALUMNOS
# ------------------------------------------------------------

$ProfileIsLoaded = $false

try {
    $UserProfile = Get-CimInstance Win32_UserProfile -Filter "SID = '$StudentSid'" -ErrorAction Stop

    if ($null -ne $UserProfile -and $UserProfile.Loaded) {
        $ProfileIsLoaded = $true
    }
}
catch {
    Stop-Policy `
        "No fue posible consultar Win32_UserProfile para '$StudentUser': $($_.Exception.Message)"
}

if ($ProfileIsLoaded) {
    Stop-Policy (
        "El perfil de '$StudentUser' esta cargado (sesion activa o no descargada). " +
        "Cierre completamente la sesion de '$StudentUser' y vuelva a ejecutar este script desde '$SupportUser'."
    )
}

Write-PolicyLog "[OK] El perfil de '$StudentUser' no esta cargado."

# ------------------------------------------------------------
# 9. PREFLIGHT - LABORATORIO Y ROL
# ------------------------------------------------------------

Write-PolicyLog ""
Write-PolicyLog "-------------------- LABORATORIO --------------------"

$MatchingLabs = @()

try {
    $LabFiles =
    Get-ChildItem `
        -Path $LabsDirectory `
        -Filter "*.json" `
        -File `
        -ErrorAction Stop

    foreach ($LabFile in $LabFiles) {
        try {
            $RawContent =
            Get-Content $LabFile.FullName -Raw -ErrorAction Stop

            if ([string]::IsNullOrWhiteSpace($RawContent)) {
                continue
            }

            $LabConfig = $RawContent | ConvertFrom-Json

            if (
                $null -eq $LabConfig.lab -or
                [string]::IsNullOrWhiteSpace(
                    $LabConfig.lab.computerPrefix
                )
            ) {
                continue
            }

            $Prefix = $LabConfig.lab.computerPrefix

            if (
                $ComputerName.StartsWith(
                    $Prefix,
                    [System.StringComparison]::OrdinalIgnoreCase
                )
            ) {
                $MatchingLabs += $LabConfig.lab
            }
        }
        catch {
            Write-PolicyLog `
                "[WARN] Configuracion invalida ignorada: $($LabFile.Name)"
        }
    }
}
catch {
    Stop-Policy `
        "No fue posible cargar configuraciones de laboratorio: $($_.Exception.Message)"
}

if ($MatchingLabs.Count -eq 0) {
    Stop-Policy "El equipo no pertenece a ningun laboratorio configurado."
}

if ($MatchingLabs.Count -gt 1) {
    Stop-Policy "El hostname coincide con multiples laboratorios."
}

$Lab = $MatchingLabs[0]
$ExpectedRole = "UNKNOWN"
$ComputerNumber = $null
$Prefix = $Lab.computerPrefix
$Suffix = $ComputerName.Substring($Prefix.Length)
$ParsedNumber = 0

if ([int]::TryParse($Suffix, [ref]$ParsedNumber)) {
    $ComputerNumber = $ParsedNumber

    if (
        $Lab.teacherComputer -and
        $ParsedNumber -eq $Lab.teacherComputer.number
    ) {
        $ExpectedRole = "Teacher"
    }
    elseif (
        $Lab.studentComputers -and
        $ParsedNumber -ge $Lab.studentComputers.first -and
        $ParsedNumber -le $Lab.studentComputers.last
    ) {
        $ExpectedRole = "Student"
    }
}

if ($ExpectedRole -ne "Student") {
    Stop-Policy `
        "Este script solo configura equipos Student. Rol detectado: $ExpectedRole"
}

Write-PolicyLog "[OK] Laboratorio identificado."
Write-PolicyLog "     ID:      $($Lab.id)"
Write-PolicyLog "     Nombre:  $($Lab.name)"
Write-PolicyLog "     Numero:  $ComputerNumber"
Write-PolicyLog "     Rol:     $ExpectedRole"

# ------------------------------------------------------------
# 10. PREFLIGHT - APPIDSVC
# ------------------------------------------------------------

Write-PolicyLog ""
Write-PolicyLog "-------------------- APPLOCKER SERVICE --------------------"

$AppIdService = $null

try {
    $AppIdService = Get-Service -Name "AppIDSvc" -ErrorAction Stop
}
catch {
    Stop-Policy "No fue posible consultar el servicio AppIDSvc: $($_.Exception.Message)"
}

$currentStatus = $AppIdService.Status
$currentStartType = $AppIdService.StartType

Write-PolicyLog "Servicio AppIDSvc:"
Write-PolicyLog "  Estado:      $currentStatus"
Write-PolicyLog "  Tipo inicio: $currentStartType"

$needsStartTypeChange = ($currentStartType -ne "Automatic")
$needsStatusChange = ($currentStatus -ne "Running")

if (-not $Apply) {
    if ($needsStartTypeChange) {
        Write-PolicyLog "  [PLAN] Configurar inicio automatico (sc.exe config appidsvc start=auto)."
    }
    if ($needsStatusChange) {
        Write-PolicyLog "  [PLAN] Iniciar servicio Application Identity (AppIDSvc)."
    }
    if (-not $needsStartTypeChange -and -not $needsStatusChange) {
        Write-PolicyLog "  [SKIP] AppIDSvc ya esta en ejecucion y configurado en inicio automatico."
    }
    Write-PolicyLog "[OK] Verificacion de AppIDSvc completada (simulacion)."
}
else {
    if (-not $needsStartTypeChange -and -not $needsStatusChange) {
        Write-PolicyLog "  [SKIP] AppIDSvc ya esta en ejecucion y configurado en inicio automatico."
    }
    else {
        if ($needsStartTypeChange) {
            Write-PolicyLog "  [APPLY] Configurando AppIDSvc en inicio automatico..."
            $scError = $null
            try {
                $process = Start-Process `
                    -FilePath "sc.exe" `
                    -ArgumentList @("config", "appidsvc", "start=auto") `
                    -Wait `
                    -PassThru `
                    -NoNewWindow

                if ($process.ExitCode -ne 0) {
                    $scError = "sc.exe config appidsvc fallo con codigo de salida $($process.ExitCode)."
                }
            }
            catch {
                $scError = $_.Exception.Message
            }

            if ($null -ne $scError) {
                Stop-Policy "No fue posible configurar AppIDSvc en inicio automatico: $scError"
            }
        }

        if ($needsStatusChange) {
            Write-PolicyLog "  [APPLY] Iniciando servicio AppIDSvc..."
            $startError = $null
            try {
                Start-Service -Name "AppIDSvc" -ErrorAction Stop
            }
            catch {
                $startError = $_.Exception.Message
            }

            if ($null -ne $startError) {
                Stop-Policy "No fue posible iniciar el servicio AppIDSvc: $startError"
            }
        }
    }

    $AppIdServiceFinal = $null
    try {
        $AppIdServiceFinal = Get-Service -Name "AppIDSvc" -ErrorAction Stop
    }
    catch {
        Stop-Policy "No fue posible verificar el servicio AppIDSvc tras la configuracion: $($_.Exception.Message)"
    }

    if ($AppIdServiceFinal.StartType -ne "Automatic" -or $AppIdServiceFinal.Status -ne "Running") {
        Stop-Policy (
            "Verificacion final de AppIDSvc fallo. " +
            "Estado: $($AppIdServiceFinal.Status), Tipo inicio: $($AppIdServiceFinal.StartType)."
        )
    }

    Write-PolicyLog "[OK] AppIDSvc esta en ejecucion y configurado en inicio automatico."
}

# ------------------------------------------------------------
# 11. CONSTRUIR MLGPO PTS DESEADO
# ------------------------------------------------------------

$WallpaperLgpoPath = ConvertTo-LgpoString $WallpaperDestination

$DesiredLgpoText = @"
User:Non-Administrators
Software\Microsoft\Windows\CurrentVersion\Policies\Explorer
NoControlPanel
DWORD:1

User:Non-Administrators
Software\Microsoft\Windows\CurrentVersion\Policies\System
Wallpaper
SZ:$WallpaperLgpoPath

User:Non-Administrators
Software\Microsoft\Windows\CurrentVersion\Policies\System
WallpaperStyle
SZ:4

User:Non-Administrators
Software\Microsoft\Windows\CurrentVersion\Policies\ActiveDesktop
NoChangingWallPaper
DWORD:1
"@

$DesiredLgpoText |
Out-File `
    -FilePath $DesiredLgpoTextPath `
    -Encoding unicode

$DesiredLgpoEntries =
Get-NormalizedLgpoEntries `
    -Lines ($DesiredLgpoText -split "`r?`n")

# ------------------------------------------------------------
# 12. CONSTRUIR APPLOCKER PTS DESEADO
# ------------------------------------------------------------

$StorePackage = $null
$DesktopInstallerPackage = $null

try {
    $StorePackage =
    Get-AppxPackage `
        -AllUsers `
        -Name "Microsoft.WindowsStore" `
        -ErrorAction SilentlyContinue |
    Select-Object -First 1

    $DesktopInstallerPackage =
    Get-AppxPackage `
        -AllUsers `
        -Name "Microsoft.DesktopAppInstaller" `
        -ErrorAction SilentlyContinue |
    Select-Object -First 1
}
catch {
    Write-PolicyLog `
        "[WARN] No fue posible inventariar paquetes Store/App Installer: $($_.Exception.Message)"
}

$AppxDenyRules = ""

if ($null -ne $StorePackage) {
    $publisher = [System.Security.SecurityElement]::Escape(
        [string]$StorePackage.Publisher
    )

    $productName = [System.Security.SecurityElement]::Escape(
        [string]$StorePackage.Name
    )

    $AppxDenyRules += @"
    <FilePublisherRule Id="$($PtsRuleIds.AppxDenyStore)" Name="PTS - Deny Microsoft Store for Alumnos" Description="Impide abrir/instalar mediante Microsoft Store en la cuenta Alumnos." UserOrGroupSid="$StudentSid" Action="Deny">
      <Conditions>
        <FilePublisherCondition PublisherName="$publisher" ProductName="$productName" BinaryName="*">
          <BinaryVersionRange LowSection="*" HighSection="*" />
        </FilePublisherCondition>
      </Conditions>
    </FilePublisherRule>
"@
}

if ($null -ne $DesktopInstallerPackage) {
    $publisher = [System.Security.SecurityElement]::Escape(
        [string]$DesktopInstallerPackage.Publisher
    )

    $productName = [System.Security.SecurityElement]::Escape(
        [string]$DesktopInstallerPackage.Name
    )

    $AppxDenyRules += @"
    <FilePublisherRule Id="$($PtsRuleIds.AppxDenyInstaller)" Name="PTS - Deny App Installer for Alumnos" Description="Impide usar App Installer/winget desde la cuenta Alumnos." UserOrGroupSid="$StudentSid" Action="Deny">
      <Conditions>
        <FilePublisherCondition PublisherName="$publisher" ProductName="$productName" BinaryName="*">
          <BinaryVersionRange LowSection="*" HighSection="*" />
        </FilePublisherCondition>
      </Conditions>
    </FilePublisherRule>
"@
}

$DesiredAppLockerXmlString = @"
<AppLockerPolicy Version="1">
  <RuleCollection Type="Exe" EnforcementMode="$DesiredAppLockerEnforcement">
    <FilePathRule Id="$($PtsRuleIds.ExeAdminAll)" Name="PTS - Administrators - All EXE" Description="Administradores pueden ejecutar cualquier ejecutable." UserOrGroupSid="$AdministratorsSid" Action="Allow">
      <Conditions>
        <FilePathCondition Path="*" />
      </Conditions>
    </FilePathRule>
    <FilePathRule Id="$($PtsRuleIds.ExeWindows)" Name="PTS - Windows - EXE" Description="Permite ejecutables ubicados bajo Windows." UserOrGroupSid="$EveryoneSid" Action="Allow">
      <Conditions>
        <FilePathCondition Path="%WINDIR%\*" />
      </Conditions>
    </FilePathRule>
    <FilePathRule Id="$($PtsRuleIds.ExeProgramFiles)" Name="PTS - Program Files - EXE" Description="Permite ejecutables bajo Program Files y Program Files x86." UserOrGroupSid="$EveryoneSid" Action="Allow">
      <Conditions>
        <FilePathCondition Path="%PROGRAMFILES%\*" />
      </Conditions>
    </FilePathRule>
    <FilePublisherRule Id="$($PtsRuleIds.ExeOneDrive)" Name="PTS - OneDrive - OneDrive.exe" Description="Permite ejecutable legitimo de OneDrive." UserOrGroupSid="$EveryoneSid" Action="Allow">
      <Conditions>
        <FilePublisherCondition PublisherName="O=MICROSOFT CORPORATION, L=REDMOND, S=WASHINGTON, C=US" ProductName="MICROSOFT ONEDRIVE" BinaryName="ONEDRIVE.EXE">
          <BinaryVersionRange LowSection="*" HighSection="*" />
        </FilePublisherCondition>
      </Conditions>
    </FilePublisherRule>
    <FilePublisherRule Id="$($PtsRuleIds.ExeOneDriveFileCoAuth)" Name="PTS - OneDrive - FileCoAuth.exe" Description="Permite ejecutable legitimo de OneDrive FileCoAuth." UserOrGroupSid="$EveryoneSid" Action="Allow">
      <Conditions>
        <FilePublisherCondition PublisherName="O=MICROSOFT CORPORATION, L=REDMOND, S=WASHINGTON, C=US" ProductName="MICROSOFT ONEDRIVE" BinaryName="FILECOAUTH.EXE">
          <BinaryVersionRange LowSection="*" HighSection="*" />
        </FilePublisherCondition>
      </Conditions>
    </FilePublisherRule>
    <FilePublisherRule Id="$($PtsRuleIds.ExeOneDriveLauncher)" Name="PTS - OneDrive - OneDriveLauncher.exe" Description="Permite ejecutable legitimo de OneDriveLauncher." UserOrGroupSid="$EveryoneSid" Action="Allow">
      <Conditions>
        <FilePublisherCondition PublisherName="O=MICROSOFT CORPORATION, L=REDMOND, S=WASHINGTON, C=US" ProductName="MICROSOFT ONEDRIVE" BinaryName="ONEDRIVELAUNCHER.EXE">
          <BinaryVersionRange LowSection="*" HighSection="*" />
        </FilePublisherCondition>
      </Conditions>
    </FilePublisherRule>
    <FilePublisherRule Id="$($PtsRuleIds.ExeOneDriveStandaloneUpdater)" Name="PTS - OneDrive - OneDriveStandaloneUpdater.exe" Description="Permite ejecutable legitimo de OneDriveStandaloneUpdater." UserOrGroupSid="$EveryoneSid" Action="Allow">
      <Conditions>
        <FilePublisherCondition PublisherName="O=MICROSOFT CORPORATION, L=REDMOND, S=WASHINGTON, C=US" ProductName="MICROSOFT ONEDRIVE" BinaryName="ONEDRIVESTANDALONEUPDATER.EXE">
          <BinaryVersionRange LowSection="*" HighSection="*" />
        </FilePublisherCondition>
      </Conditions>
    </FilePublisherRule>
    <FilePublisherRule Id="$($PtsRuleIds.ExeOneDriveSyncService)" Name="PTS - OneDrive - OneDrive.Sync.Service.exe" Description="Permite ejecutable legitimo de OneDrive.Sync.Service." UserOrGroupSid="$EveryoneSid" Action="Allow">
      <Conditions>
        <FilePublisherCondition PublisherName="O=MICROSOFT CORPORATION, L=REDMOND, S=WASHINGTON, C=US" ProductName="MICROSOFT ONEDRIVE SYNC SERVICE" BinaryName="ONEDRIVE.SYNC.SERVICE.EXE">
          <BinaryVersionRange LowSection="*" HighSection="*" />
        </FilePublisherCondition>
      </Conditions>
    </FilePublisherRule>
    <FilePublisherRule Id="$($PtsRuleIds.ExeDefenderSessionHelper)" Name="PTS - Defender - DefenderSessionHelper.exe" Description="Permite ejecutable legitimo de DefenderSessionHelper." UserOrGroupSid="$EveryoneSid" Action="Allow">
      <Conditions>
        <FilePublisherCondition PublisherName="O=MICROSOFT CORPORATION, L=REDMOND, S=WASHINGTON, C=US" ProductName="MICROSOFT&#174; WINDOWS&#174; OPERATING SYSTEM" BinaryName="DEFENDERSESSIONHELPER.EXE">
          <BinaryVersionRange LowSection="*" HighSection="*" />
        </FilePublisherCondition>
      </Conditions>
    </FilePublisherRule>
  </RuleCollection>

  <RuleCollection Type="Msi" EnforcementMode="$DesiredAppLockerEnforcement">
    <FilePathRule Id="$($PtsRuleIds.MsiAdminAll)" Name="PTS - Administrators - All MSI" Description="Administradores pueden ejecutar cualquier Windows Installer." UserOrGroupSid="$AdministratorsSid" Action="Allow">
      <Conditions>
        <FilePathCondition Path="*" />
      </Conditions>
    </FilePathRule>
    <FilePathRule Id="$($PtsRuleIds.MsiWindowsInstaller)" Name="PTS - Windows Installer Cache" Description="Permite instaladores administrados desde Windows Installer cache." UserOrGroupSid="$EveryoneSid" Action="Allow">
      <Conditions>
        <FilePathCondition Path="%WINDIR%\Installer\*" />
      </Conditions>
    </FilePathRule>
  </RuleCollection>

  <RuleCollection Type="Script" EnforcementMode="$DesiredAppLockerEnforcement">
    <FilePathRule Id="$($PtsRuleIds.ScriptAdminAll)" Name="PTS - Administrators - All Scripts" Description="Administradores pueden ejecutar cualquier script." UserOrGroupSid="$AdministratorsSid" Action="Allow">
      <Conditions>
        <FilePathCondition Path="*" />
      </Conditions>
    </FilePathRule>
    <FilePathRule Id="$($PtsRuleIds.ScriptWindows)" Name="PTS - Windows - Scripts" Description="Permite scripts administrados bajo Windows." UserOrGroupSid="$EveryoneSid" Action="Allow">
      <Conditions>
        <FilePathCondition Path="%WINDIR%\*" />
      </Conditions>
    </FilePathRule>
    <FilePathRule Id="$($PtsRuleIds.ScriptProgramFiles)" Name="PTS - Program Files - Scripts" Description="Permite scripts administrados bajo Program Files." UserOrGroupSid="$EveryoneSid" Action="Allow">
      <Conditions>
        <FilePathCondition Path="%PROGRAMFILES%\*" />
      </Conditions>
    </FilePathRule>
  </RuleCollection>

  <RuleCollection Type="Appx" EnforcementMode="$DesiredAppLockerEnforcement">
    <FilePublisherRule Id="$($PtsRuleIds.AppxAdminAll)" Name="PTS - Administrators - All packaged apps" Description="Administradores pueden instalar y ejecutar cualquier aplicacion empaquetada firmada." UserOrGroupSid="$AdministratorsSid" Action="Allow">
      <Conditions>
        <FilePublisherCondition PublisherName="*" ProductName="*" BinaryName="*">
          <BinaryVersionRange LowSection="*" HighSection="*" />
        </FilePublisherCondition>
      </Conditions>
    </FilePublisherRule>
    <FilePublisherRule Id="$($PtsRuleIds.AppxMicrosoftWin)" Name="PTS - Microsoft Windows packaged apps" Description="Permite aplicaciones empaquetadas publicadas por Microsoft Windows." UserOrGroupSid="$EveryoneSid" Action="Allow">
      <Conditions>
        <FilePublisherCondition PublisherName="CN=Microsoft Windows, O=Microsoft Corporation, L=Redmond, S=Washington, C=US" ProductName="*" BinaryName="*">
          <BinaryVersionRange LowSection="*" HighSection="*" />
        </FilePublisherCondition>
      </Conditions>
    </FilePublisherRule>
    <FilePublisherRule Id="$($PtsRuleIds.AppxMicrosoftCorp)" Name="PTS - Microsoft Corporation packaged apps" Description="Permite aplicaciones empaquetadas publicadas por Microsoft Corporation." UserOrGroupSid="$EveryoneSid" Action="Allow">
      <Conditions>
        <FilePublisherCondition PublisherName="CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US" ProductName="*" BinaryName="*">
          <BinaryVersionRange LowSection="*" HighSection="*" />
        </FilePublisherCondition>
      </Conditions>
    </FilePublisherRule>
$AppxDenyRules  </RuleCollection>

  <RuleCollection Type="Dll" EnforcementMode="NotConfigured" />
</AppLockerPolicy>
"@

$DesiredAppLockerXmlString |
Out-File `
    -FilePath $DesiredAppLockerXmlPath `
    -Encoding utf8

try {
    [xml]$DesiredAppLockerXml = $DesiredAppLockerXmlString
}
catch {
    Stop-Policy `
        "El XML AppLocker generado no es valido: $($_.Exception.Message)"
}

$DesiredAppLockerFingerprint =
Get-AppLockerPolicyFingerprint `
    -PolicyXml $DesiredAppLockerXml

# ------------------------------------------------------------
# 13. INVENTARIO BRANDING
# ------------------------------------------------------------

Write-PolicyLog ""
Write-PolicyLog "-------------------- BRANDING --------------------"
Write-PolicyLog "Origen:  $WallpaperSource"
Write-PolicyLog "Destino: $WallpaperDestination"

$WallpaperSourceHash =
(Get-FileHash -Path $WallpaperSource -Algorithm SHA256).Hash

$BrandingCompliant = $false

if (Test-Path $WallpaperDestination) {
    try {
        $WallpaperDestinationHash =
        (Get-FileHash `
            -Path $WallpaperDestination `
            -Algorithm SHA256
        ).Hash

        if ($WallpaperSourceHash -eq $WallpaperDestinationHash) {
            $BrandingCompliant = $true
            Write-PolicyLog "[OK] Wallpaper institucional ya coincide."
            Write-PolicyLog "     SHA256: $WallpaperSourceHash"
        }
        else {
            Write-PolicyLog "[INFO] Existe wallpaper destino pero no coincide con el asset actual."
        }
    }
    catch {
        Write-PolicyLog "[WARN] No fue posible comparar wallpaper destino."
    }
}
else {
    Write-PolicyLog "[INFO] Wallpaper institucional aun no esta instalado."
}

# ------------------------------------------------------------
# 14. INVENTARIO MLGPO PTS
# ------------------------------------------------------------

Write-PolicyLog ""
Write-PolicyLog "-------------------- MLGPO NO ADMINISTRADORES --------------------"

$MlgpoState = "Clean"
$CurrentLgpoEntries = @()

if (Test-Path $NonAdminPolicyDirectory) {

    if (-not (Test-Path $NonAdminRegistryPol)) {
        $MlgpoState = "Unknown"
        Write-PolicyLog "[WARN] Existe MLGPO No administradores pero no User\Registry.pol."
    }
    else {
        try {
            $ParsedLines =
            Invoke-LgpoParseNonAdmins `
                -RegistryPolPath $NonAdminRegistryPol

            $CurrentLgpoEntries =
            Get-NormalizedLgpoEntries `
                -Lines $ParsedLines

            if (
                Test-StringArrayEqual `
                    -A $CurrentLgpoEntries `
                    -B $DesiredLgpoEntries
            ) {
                $MlgpoState = "PTS"
                Write-PolicyLog "[OK] MLGPO coincide exactamente con PTS Student Policy."
            }
            elseif ($CurrentLgpoEntries.Count -eq 0) {
                $MlgpoState = "Clean"
                Write-PolicyLog "[OK] MLGPO presente pero sin configuraciones de registro."
            }
            else {
                $MlgpoState = "Unknown"
                Write-PolicyLog "[WARN] MLGPO contiene configuraciones no reconocidas."
                Write-PolicyLog "       No sera sobrescrito automaticamente."
            }
        }
        catch {
            $MlgpoState = "Unknown"
            Write-PolicyLog `
                "[WARN] No fue posible analizar MLGPO: $($_.Exception.Message)"
        }
    }
}
else {
    Write-PolicyLog "[OK] No existe MLGPO No administradores. Estado limpio."
}

Write-PolicyLog "Estado MLGPO: $MlgpoState"

if ($MlgpoState -eq "Unknown") {
    Stop-Policy `
        "MLGPO No administradores esta en estado desconocido. Ejecute/revise 02 antes de aplicar 04."
}

# ------------------------------------------------------------
# 15. INVENTARIO APPLOCKER DECLARADO
# ------------------------------------------------------------

Write-PolicyLog ""
Write-PolicyLog "-------------------- APPLOCKER --------------------"

$CurrentAppLockerXmlString = $null
$CurrentAppLockerFingerprint = @()
$CurrentAppLockerState = "Clean"
$CurrentRuleCount = 0

try {
    $CurrentAppLockerXmlString =
    Get-AppLockerPolicy `
        -Local `
        -Xml `
        -ErrorAction Stop

    [xml]$CurrentAppLockerXml = $CurrentAppLockerXmlString

    foreach (
        $collection in
        @($CurrentAppLockerXml.SelectNodes("/AppLockerPolicy/RuleCollection"))
    ) {
        if ($null -eq $collection) {
            continue
        }

        $CurrentRuleCount += @(
            $collection.ChildNodes |
            Where-Object {
                $_.NodeType -eq
                [System.Xml.XmlNodeType]::Element
            }
        ).Count
    }

    Write-PolicyLog "Politica declarada local: $CurrentRuleCount regla(s)."

    if ($CurrentRuleCount -eq 0) {
        $CurrentAppLockerState = "Clean"
        Write-PolicyLog "[OK] AppLocker declarado esta limpio."
    }
    else {
        $CurrentRuleIds = @()

        foreach (
            $collection in
            @($CurrentAppLockerXml.SelectNodes("/AppLockerPolicy/RuleCollection"))
        ) {
            foreach ($rule in @($collection.ChildNodes)) {
                if (
                    $rule.NodeType -eq
                    [System.Xml.XmlNodeType]::Element
                ) {
                    $CurrentRuleIds += [string]$rule.Id
                }
            }
        }

        $UnknownRuleIds = @(
            $CurrentRuleIds |
            Where-Object {
                $_ -notin @($PtsRuleIds.Values)
            }
        )

        if ($UnknownRuleIds.Count -gt 0) {
            $CurrentAppLockerState = "Unknown"
            Write-PolicyLog "[WARN] AppLocker contiene reglas no reconocidas:"
            foreach ($id in $UnknownRuleIds) {
                Write-PolicyLog "       $id"
            }
        }
        else {
            $CurrentAppLockerFingerprint =
            Get-AppLockerPolicyFingerprint `
                -PolicyXml $CurrentAppLockerXml

            if (
                Test-StringArrayEqual `
                    -A $CurrentAppLockerFingerprint `
                    -B $DesiredAppLockerFingerprint
            ) {
                $CurrentAppLockerState = "PTSDesired"
                Write-PolicyLog `
                    "[OK] AppLocker coincide exactamente con PTS ($DesiredAppLockerLabel)."
            }
            else {
                $CurrentAppLockerState = "PTSOther"
                Write-PolicyLog `
                    "[INFO] AppLocker usa IDs PTS pero no coincide con el objetivo actual."
                Write-PolicyLog `
                    "       Puede ser otro modo (Audit/Enforce) o un SID Alumnos anterior."
            }
        }
    }
}
catch {
    Stop-Policy `
        "No fue posible inspeccionar AppLocker declarado: $($_.Exception.Message)"
}

if ($CurrentAppLockerState -eq "Unknown") {
    Stop-Policy `
        "AppLocker declarado contiene reglas desconocidas. No se reemplazara automaticamente."
}

# ------------------------------------------------------------
# 16. INVENTARIO APPLOCKER RUNTIME
# ------------------------------------------------------------

$RuntimeFiles = @(
    Get-ChildItem `
        -Path "$AppLockerRuntimeDirectory\*.AppLocker" `
        -ErrorAction SilentlyContinue
)

Write-PolicyLog ""
Write-PolicyLog "Runtime AppLocker: $($RuntimeFiles.Count) archivo(s) *.AppLocker."

$LegacyRuntimeGuidsFound = @()

if ($RuntimeFiles.Count -gt 0) {
    $LegacyRuntimeGuidsFound = @(
        Test-RuntimeContainsAnyGuid `
            -Files $RuntimeFiles `
            -Guids $LegacyAppLockerRuleIds
    )
}

if ($LegacyRuntimeGuidsFound.Count -gt 0) {
    Write-PolicyLog "[WARN] Runtime contiene GUID legacy conocidos:"
    foreach ($guid in $LegacyRuntimeGuidsFound) {
        Write-PolicyLog "       $guid"
    }

    Stop-Policy `
        "Se detecto runtime AppLocker legacy. Ejecute 02 y reinicie antes de aplicar 04."
}

if (
    $CurrentAppLockerState -eq "Clean" -and
    $RuntimeFiles.Count -gt 0
) {
    Stop-Policy `
        "AppLocker declarado esta limpio pero existen archivos runtime. Estado residual desconocido; no se aplicara 04."
}

Write-PolicyLog "[OK] No se detectaron GUID legacy conocidos en runtime."
Write-PolicyLog "Estado AppLocker declarado: $CurrentAppLockerState"

# ------------------------------------------------------------
# 17. PLAN
# ------------------------------------------------------------

Write-PolicyLog ""
Write-PolicyLog "-------------------- PLAN --------------------"

$ActionsPlanned = 0
$PlanBranding = -not $BrandingCompliant
$PlanMlgpo = ($MlgpoState -ne "PTS")
$PlanAppLocker = ($CurrentAppLockerState -ne "PTSDesired")

if ($PlanBranding) {
    Write-PolicyLog "[PLAN] Instalar/actualizar wallpaper institucional."
    Write-PolicyLog "       $WallpaperDestination"
    $ActionsPlanned++
}
else {
    Write-PolicyLog "[SKIP] Wallpaper institucional ya cumple el estandar."
}

if ($PlanMlgpo) {
    Write-PolicyLog "[PLAN] Aplicar MLGPO PTS a No administradores:"
    Write-PolicyLog "       - bloquear Configuracion y Panel de control"
    Write-PolicyLog "       - fijar fondo institucional"
    Write-PolicyLog "       - impedir cambiar fondo"
    $ActionsPlanned++
}
else {
    Write-PolicyLog "[SKIP] MLGPO PTS ya coincide exactamente."
}

if ($PlanAppLocker) {
    Write-PolicyLog "[PLAN] Aplicar AppLocker PTS en modo: $DesiredAppLockerLabel"
    Write-PolicyLog "       EXE:    Windows + Program Files + Administradores"
    Write-PolicyLog "       MSI:    Windows Installer cache + Administradores"
    Write-PolicyLog "       Script: Windows + Program Files + Administradores"
    Write-PolicyLog "       Appx:   Microsoft + Administradores; deny Store/App Installer para Alumnos"
    Write-PolicyLog "       DLL:    NotConfigured"
    $ActionsPlanned++
}
else {
    Write-PolicyLog "[SKIP] AppLocker PTS ya coincide con el objetivo."
}

Write-PolicyLog ""

if ($ActionsPlanned -eq 0) {
    Write-PolicyLog "[INFO] El equipo ya cumple PTS Student Policy v$PtsPolicyVersion."
    Write-PolicyLog ""
    Write-PolicyLog "No se realizaron cambios."
    exit 0
}

# ------------------------------------------------------------
# 18. SIMULACION
# ------------------------------------------------------------

if (-not $Apply) {

    Write-PolicyLog "============================================================"
    Write-PolicyLog " SIMULACION FINALIZADA"
    Write-PolicyLog "============================================================"
    Write-PolicyLog ""
    Write-PolicyLog "No se modifico ninguna configuracion del sistema."
    Write-PolicyLog ""
    Write-PolicyLog "Objetivo AppLocker: $DesiredAppLockerLabel"
    Write-PolicyLog ""
    Write-PolicyLog "Para aplicar en AuditOnly:"
    Write-PolicyLog ""
    Write-PolicyLog "  .\scripts\04-ConfigureStudentPolicies.ps1 -Apply"
    Write-PolicyLog ""
    Write-PolicyLog "Para SIMULAR Enforcement (no aplicar aun sin pruebas):"
    Write-PolicyLog ""
    Write-PolicyLog "  .\scripts\04-ConfigureStudentPolicies.ps1 -EnforceAppLocker"
    Write-PolicyLog ""
    exit 0
}

# ------------------------------------------------------------
# 19. BACKUP
# ------------------------------------------------------------

Write-PolicyLog "-------------------- BACKUP --------------------"

try {
    New-Item `
        -ItemType Directory `
        -Path $BackupRoot `
        -Force |
    Out-Null

    Write-PolicyLog "[OK] Backup creado:"
    Write-PolicyLog "     $BackupRoot"
}
catch {
    Stop-Policy `
        "No fue posible crear directorio de backup: $($_.Exception.Message)"
}

if (Test-Path $WallpaperDestination) {
    try {
        $BrandingBackupDir = Join-Path $BackupRoot "branding"
        New-Item -ItemType Directory -Path $BrandingBackupDir -Force |
        Out-Null

        Copy-Item `
            -Path $WallpaperDestination `
            -Destination (Join-Path $BrandingBackupDir "fondo-pts.jpg") `
            -Force `
            -ErrorAction Stop

        Write-PolicyLog "[OK] Wallpaper anterior respaldado."
    }
    catch {
        Stop-Policy `
            "No fue posible respaldar wallpaper anterior: $($_.Exception.Message)"
    }
}

if (Test-Path $NonAdminPolicyDirectory) {
    try {
        $MlgpoBackupParent =
        Join-Path $BackupRoot "GroupPolicyUsers"

        New-Item `
            -ItemType Directory `
            -Path $MlgpoBackupParent `
            -Force |
        Out-Null

        Copy-Item `
            -Path $NonAdminPolicyDirectory `
            -Destination (Join-Path $MlgpoBackupParent $NonAdministratorsSid) `
            -Recurse `
            -Force `
            -ErrorAction Stop

        Write-PolicyLog "[OK] MLGPO existente respaldado."
    }
    catch {
        Stop-Policy `
            "No fue posible respaldar MLGPO: $($_.Exception.Message)"
    }
}

if ($CurrentRuleCount -gt 0) {
    try {
        $AppLockerBackupPath =
        Join-Path $BackupRoot "applocker-before.xml"

        $CurrentAppLockerXmlString |
        Out-File `
            -FilePath $AppLockerBackupPath `
            -Encoding utf8

        Write-PolicyLog "[OK] AppLocker declarado anterior respaldado."
    }
    catch {
        Stop-Policy `
            "No fue posible respaldar AppLocker declarado: $($_.Exception.Message)"
    }
}

# ------------------------------------------------------------
# 20. APLICAR BRANDING
# ------------------------------------------------------------

if ($PlanBranding) {
    Write-PolicyLog ""
    Write-PolicyLog "-------------------- BRANDING APPLY --------------------"

    try {
        New-Item `
            -ItemType Directory `
            -Path $BrandingDirectory `
            -Force |
        Out-Null

        Copy-Item `
            -Path $WallpaperSource `
            -Destination $WallpaperDestination `
            -Force `
            -ErrorAction Stop

        $destHash =
        (Get-FileHash `
            -Path $WallpaperDestination `
            -Algorithm SHA256
        ).Hash

        if ($destHash -ne $WallpaperSourceHash) {
            Stop-Policy "SHA256 del wallpaper copiado no coincide con el asset."
        }

        Write-PolicyLog "[OK] Wallpaper institucional instalado."
        Write-PolicyLog "     SHA256: $destHash"
    }
    catch {
        Stop-Policy `
            "Fallo al instalar wallpaper institucional: $($_.Exception.Message)"
    }
}

# ------------------------------------------------------------
# 21. APLICAR MLGPO
# ------------------------------------------------------------

if ($PlanMlgpo) {
    Write-PolicyLog ""
    Write-PolicyLog "-------------------- MLGPO APPLY --------------------"

    try {
        $LgpoOutput =
        Invoke-LgpoApplyText `
            -TextPath $DesiredLgpoTextPath

        Write-PolicyLog "[OK] MLGPO PTS aplicado mediante LGPO.exe."

        foreach ($line in $LgpoOutput) {
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                Write-PolicyLog "       $line"
            }
        }
    }
    catch {
        Stop-Policy `
            "Fallo al aplicar MLGPO: $($_.Exception.Message)"
    }
}

# ------------------------------------------------------------
# 22. APLICAR APPLOCKER
# ------------------------------------------------------------

if ($PlanAppLocker) {
    Write-PolicyLog ""
    Write-PolicyLog "-------------------- APPLOCKER APPLY --------------------"

    try {
        Set-AppLockerPolicy `
            -XmlPolicy $DesiredAppLockerXmlPath `
            -ErrorAction Stop

        Write-PolicyLog `
            "[OK] AppLocker PTS aplicado en modo $DesiredAppLockerLabel."
    }
    catch {
        Stop-Policy `
            "Fallo al aplicar AppLocker PTS: $($_.Exception.Message)"
    }
}

# ------------------------------------------------------------
# 23. ACTUALIZACION DE DIRECTIVAS
# ------------------------------------------------------------

if ($PlanMlgpo -or $PlanAppLocker) {
    Write-PolicyLog ""
    Write-PolicyLog "-------------------- ACTUALIZACION --------------------"

    if ($PlanMlgpo) {
        try {
            $GpUpdateUser =
            Start-Process `
                -FilePath "gpupdate.exe" `
                -ArgumentList "/force" `
                -Wait `
                -PassThru `
                -NoNewWindow

            if ($GpUpdateUser.ExitCode -eq 0) {
                Write-PolicyLog "[OK] gpupdate /force finalizo correctamente."
            }
            else {
                Write-PolicyLog `
                    "[WARN] gpupdate /force termino con codigo $($GpUpdateUser.ExitCode)."
            }
        }
        catch {
            Write-PolicyLog `
                "[WARN] No fue posible ejecutar gpupdate /force: $($_.Exception.Message)"
        }
    }

    if ($PlanAppLocker) {
        try {
            $GpUpdateComputer =
            Start-Process `
                -FilePath "gpupdate.exe" `
                -ArgumentList @(
                "/target:computer",
                "/force"
            ) `
                -Wait `
                -PassThru `
                -NoNewWindow

            if ($GpUpdateComputer.ExitCode -eq 0) {
                Write-PolicyLog `
                    "[OK] gpupdate /target:computer /force finalizo correctamente."
            }
            else {
                Write-PolicyLog `
                    "[WARN] gpupdate /target:computer /force termino con codigo $($GpUpdateComputer.ExitCode)."
                $PostCheckOk = $false
            }
        }
        catch {
            Write-PolicyLog `
                "[WARN] No fue posible ejecutar gpupdate /target:computer: $($_.Exception.Message)"
            $PostCheckOk = $false
        }
    }
}

# ------------------------------------------------------------
# 24. POST-CHECK
# ------------------------------------------------------------

Write-PolicyLog ""
Write-PolicyLog "-------------------- POST-CHECK --------------------"

$PostCheckOk = $true

# Branding
try {
    if (-not (Test-Path $WallpaperDestination)) {
        Write-PolicyLog "[WARN] Wallpaper destino no existe."
        $PostCheckOk = $false
    }
    else {
        $postWallpaperHash =
        (Get-FileHash `
            -Path $WallpaperDestination `
            -Algorithm SHA256
        ).Hash

        if ($postWallpaperHash -eq $WallpaperSourceHash) {
            Write-PolicyLog "[OK] Branding: wallpaper coincide con asset."
        }
        else {
            Write-PolicyLog "[WARN] Branding: SHA256 no coincide."
            $PostCheckOk = $false
        }
    }
}
catch {
    Write-PolicyLog "[WARN] No fue posible verificar branding."
    $PostCheckOk = $false
}

# MLGPO
try {
    if (-not (Test-Path $NonAdminRegistryPol)) {
        Write-PolicyLog "[WARN] MLGPO: Registry.pol no existe."
        $PostCheckOk = $false
    }
    else {
        $postLgpoLines =
        Invoke-LgpoParseNonAdmins `
            -RegistryPolPath $NonAdminRegistryPol

        $postLgpoEntries =
        Get-NormalizedLgpoEntries `
            -Lines $postLgpoLines

        if (
            Test-StringArrayEqual `
                -A $postLgpoEntries `
                -B $DesiredLgpoEntries
        ) {
            Write-PolicyLog "[OK] MLGPO No administradores coincide con PTS."
        }
        else {
            Write-PolicyLog "[WARN] MLGPO no coincide con PTS despues de aplicar."
            $PostCheckOk = $false
        }
    }
}
catch {
    Write-PolicyLog `
        "[WARN] No fue posible verificar MLGPO: $($_.Exception.Message)"
    $PostCheckOk = $false
}

# AppLocker Local
try {
    $postAppLockerString =
    Get-AppLockerPolicy `
        -Local `
        -Xml `
        -ErrorAction Stop

    [xml]$postAppLockerXml = $postAppLockerString

    $postFingerprint =
    Get-AppLockerPolicyFingerprint `
        -PolicyXml $postAppLockerXml

    if (
        Test-StringArrayEqual `
            -A $postFingerprint `
            -B $DesiredAppLockerFingerprint
    ) {
        Write-PolicyLog `
            "[OK] AppLocker Local coincide con PTS ($DesiredAppLockerLabel)."
    }
    else {
        Write-PolicyLog "[WARN] AppLocker Local no coincide con el objetivo."
        $PostCheckOk = $false
    }
}
catch {
    Write-PolicyLog "[WARN] No fue posible verificar AppLocker Local."
    $PostCheckOk = $false
}

# AppLocker Effective
try {
    $postEffectiveString =
    Get-AppLockerPolicy `
        -Effective `
        -Xml `
        -ErrorAction Stop

    [xml]$postEffectiveXml = $postEffectiveString

    $effectiveFingerprint =
    Get-AppLockerPolicyFingerprint `
        -PolicyXml $postEffectiveXml

    if (
        Test-StringArrayEqual `
            -A $effectiveFingerprint `
            -B $DesiredAppLockerFingerprint
    ) {
        Write-PolicyLog `
            "[OK] AppLocker Effective coincide con PTS ($DesiredAppLockerLabel)."
    }
    else {
        Write-PolicyLog `
            "[WARN] AppLocker Effective no coincide aun con el objetivo."
        $PostCheckOk = $false
    }
}
catch {
    Write-PolicyLog "[WARN] No fue posible verificar AppLocker Effective."
    $PostCheckOk = $false
}

# ------------------------------------------------------------
# 25. RESULTADO
# ------------------------------------------------------------

Write-PolicyLog ""

if ($PostCheckOk) {
    Write-PolicyLog "============================================================"
    Write-PolicyLog " PTS STUDENT POLICY APLICADA"
    Write-PolicyLog "============================================================"
}
else {
    Write-PolicyLog "============================================================"
    Write-PolicyLog " PTS STUDENT POLICY APLICADA CON ADVERTENCIAS"
    Write-PolicyLog "============================================================"
}

Write-PolicyLog ""
Write-PolicyLog "AppLocker: $DesiredAppLockerLabel"
Write-PolicyLog ""
Write-PolicyLog "Backup:"
Write-PolicyLog "$BackupRoot"
Write-PolicyLog ""
Write-PolicyLog "Log:"
Write-PolicyLog "$LogPath"
Write-PolicyLog ""
Write-PolicyLog "SIGUIENTE PASO:"

if (-not $EnforceAppLocker) {
    Write-PolicyLog "1. Cerrar sesion de Soporte e iniciar Alumnos."
    Write-PolicyLog "2. Confirmar fondo PTS y bloqueo de Configuracion/Panel."
    Write-PolicyLog "3. Probar Office, navegadores, USB y software legitimo."
    Write-PolicyLog "4. Probar EXE/MSI/scripts desde Downloads, AppData y USB."
    Write-PolicyLog "5. Revisar eventos AppLocker antes de Enforcement."
    Write-PolicyLog ""
    Write-PolicyLog "NO activar Enforcement hasta revisar el Audit."
}
else {
    Write-PolicyLog "Validar funcionalmente Alumnos y ejecutar 01-Audit/07-Verify cuando corresponda."
}

Write-PolicyLog ""

try {
    Remove-Item `
        -Path $WorkingRoot `
        -Recurse `
        -Force `
        -ErrorAction SilentlyContinue
}
catch {
    # No altera el resultado del despliegue.
}
