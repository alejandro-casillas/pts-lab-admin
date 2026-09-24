#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Retira configuracion legacy conocida de los equipos PTS.

.DESCRIPTION
    Elimina de forma controlada configuraciones antiguas que seran
    reemplazadas posteriormente por el estandar de pts-lab-admin.

    Actualmente administra:
      - Politica AppLocker local legacy (declarada y runtime).
      - MLGPO legacy "No administradores" (S-1-5-32-545).

    Antes de modificar:
      - valida privilegios y configuracion del proyecto;
      - valida que el equipo pertenezca a un laboratorio configurado;
      - valida usuarios requeridos;
      - inventaria AppLocker (politica declarada Y archivos runtime);
      - crea respaldo restaurable de los artefactos que va a tocar.

    Por defecto NO modifica Windows.

    Para realizar cambios reales debe utilizarse explicitamente:

        .\scripts\02-CleanLegacyPolicies.ps1 -Apply

    NOTA: Si se eliminan archivos runtime de AppLocker, se requiere
    reiniciar Windows antes de considerar la limpieza verificada.

.NOTES
    Proyecto: pts-lab-admin
    Preparatoria Tonala Sur

    IMPORTANTE:
    Este script SI puede modificar configuracion del sistema cuando
    se ejecuta con -Apply.
#>

[CmdletBinding()]
param (
    [switch]$Apply
)

$ErrorActionPreference = "Stop"

# ------------------------------------------------------------
# 1. CONSTANTES
# ------------------------------------------------------------

$NonAdministratorsSid = "S-1-5-32-545"

$ExpectedLegacyExePaths = @(
    "%PROGRAMFILES%\*",
    "%WINDIR%\*",
    "*"
)

$ExpectedLegacyExeSids = @(
    "S-1-1-0",
    "S-1-1-0",
    "S-1-5-32-544"
)

# GUID de las reglas AppLocker legacy conocidas.
# EXE: 921cc481, a61c8b2c, fd686d83
# APPX: a9e18c21
$ExpectedLegacyAppLockerRuleIds = @(
    "921cc481-6e17-4653-8f75-050b80acca20",
    "a61c8b2c-a319-4cd0-9690-d2177cad7b51",
    "fd686d83-a829-4351-8ff4-27c7de5755d2",
    "a9e18c21-ff8f-43cf-b9fc-db40eed693ba"
)

$AppLockerRuntimeDirectory = "C:\Windows\System32\AppLocker"

# ------------------------------------------------------------
# 2. RUTAS DEL PROYECTO
# ------------------------------------------------------------

$ScriptDirectory = $PSScriptRoot
$ProjectRoot = Split-Path $ScriptDirectory -Parent

$StandardPath = Join-Path $ProjectRoot "config\standard.json"
$LabsDirectory = Join-Path $ProjectRoot "config\labs"
$LogsDirectory = Join-Path $ProjectRoot "logs"
$BackupsDirectory = Join-Path $ProjectRoot "backups"

$ComputerName = $env:COMPUTERNAME
$Timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"

$LogPath = Join-Path `
    $LogsDirectory `
    "$ComputerName-CleanLegacy-$Timestamp.txt"

$BackupRoot = Join-Path `
    $BackupsDirectory `
    "$ComputerName-CleanLegacy-$Timestamp"

$LegacyUserPolicyDirectory = Join-Path `
    "C:\Windows\System32\GroupPolicyUsers" `
    $NonAdministratorsSid

$LegacyRegistryPol = Join-Path `
    $LegacyUserPolicyDirectory `
    "User\Registry.pol"

# ------------------------------------------------------------
# 3. UTILIDADES
# ------------------------------------------------------------

function ConvertTo-AsciiText {
    param (
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

function Write-CleanLog {
    param (
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

function Stop-Clean {
    param (
        [string]$Message
    )

    Write-CleanLog ""
    Write-CleanLog "[ABORT] $Message"
    Write-CleanLog ""
    Write-CleanLog "No se realizaron mas cambios."
    exit 1
}

function Test-IsAdministrator {

    $identity =
    [System.Security.Principal.WindowsIdentity]::GetCurrent()

    $principal =
    New-Object `
        System.Security.Principal.WindowsPrincipal($identity)

    return $principal.IsInRole(
        [System.Security.Principal.WindowsBuiltInRole]::
        Administrator
    )
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

Write-CleanLog "============================================================"
Write-CleanLog " PTS LAB ADMIN - CLEAN LEGACY POLICIES"
Write-CleanLog "============================================================"
Write-CleanLog ""
Write-CleanLog "Equipo:          $ComputerName"
Write-CleanLog "Fecha:           $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-CleanLog "Usuario actual:  $env:USERNAME"
Write-CleanLog "Estandar:        $($Standard.standardVersion)"

if ($Apply) {
    Write-CleanLog "Modo:            APPLY - CAMBIOS REALES"
}
else {
    Write-CleanLog "Modo:            SIMULACION - SIN CAMBIOS"
}

Write-CleanLog ""

# ------------------------------------------------------------
# 7. PREFLIGHT - ADMINISTRADOR
# ------------------------------------------------------------

Write-CleanLog "-------------------- PREFLIGHT --------------------"

if (-not (Test-IsAdministrator)) {
    Stop-Clean "PowerShell no esta ejecutandose como administrador."
}

Write-CleanLog "[OK] Sesion elevada como administrador."

# ------------------------------------------------------------
# 8. PREFLIGHT - USUARIOS
# ------------------------------------------------------------

try {
    $Student =
    Get-LocalUser `
        -Name $StudentUser `
        -ErrorAction SilentlyContinue

    $Support =
    Get-LocalUser `
        -Name $SupportUser `
        -ErrorAction SilentlyContinue

    if ($null -eq $Student) {
        Stop-Clean "No existe el usuario '$StudentUser'."
    }

    if ($null -eq $Support) {
        Stop-Clean "No existe el usuario '$SupportUser'."
    }

    Write-CleanLog "[OK] Usuario '$StudentUser' encontrado."
    Write-CleanLog "[OK] Usuario '$SupportUser' encontrado."
}
catch {
    Stop-Clean `
        "No fue posible validar usuarios: $($_.Exception.Message)"
}

# ------------------------------------------------------------
# 9. PREFLIGHT - LABORATORIO
# ------------------------------------------------------------

Write-CleanLog ""
Write-CleanLog "-------------------- LABORATORIO --------------------"

$MatchingLabs = @()

try {

    if (-not (Test-Path $LabsDirectory)) {
        Stop-Clean "No existe config\labs."
    }

    $LabFiles =
    Get-ChildItem `
        -Path $LabsDirectory `
        -Filter "*.json" `
        -File `
        -ErrorAction Stop

    foreach ($LabFile in $LabFiles) {

        try {

            $RawContent =
            Get-Content `
                $LabFile.FullName `
                -Raw `
                -ErrorAction Stop

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
            Write-CleanLog `
                "[WARN] Configuracion invalida ignorada: $($LabFile.Name)"
        }
    }
}
catch {
    Stop-Clean `
        "No fue posible cargar configuraciones de laboratorio: $($_.Exception.Message)"
}

if ($MatchingLabs.Count -eq 0) {
    Stop-Clean `
        "El equipo no pertenece a ningun laboratorio configurado."
}

if ($MatchingLabs.Count -gt 1) {
    Stop-Clean `
        "El hostname coincide con multiples laboratorios."
}

$Lab = $MatchingLabs[0]

Write-CleanLog "[OK] Laboratorio identificado."
Write-CleanLog "     ID:      $($Lab.id)"
Write-CleanLog "     Nombre:  $($Lab.name)"
Write-CleanLog "     Prefix:  $($Lab.computerPrefix)"

# ------------------------------------------------------------
# 10. VALIDAR ROL DEL EQUIPO
# ------------------------------------------------------------

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

if ($ExpectedRole -eq "UNKNOWN") {
    Stop-Clean `
        "El hostname pertenece al laboratorio pero esta fuera del rango configurado."
}

Write-CleanLog "[OK] Rol esperado: $ExpectedRole"
Write-CleanLog "     Numero:       $ComputerNumber"

# ------------------------------------------------------------
# 11. INVENTARIO APPLOCKER - POLITICA DECLARADA
# ------------------------------------------------------------

Write-CleanLog ""
Write-CleanLog "-------------------- APPLOCKER LEGACY --------------------"

$AppLockerXmlString = $null
$AppLockerXml = $null
$DeclaredLocalLegacy = $false
$DeclaredUnknown = $false

try {

    $AppLockerXmlString =
    Get-AppLockerPolicy `
        -Local `
        -Xml `
        -ErrorAction Stop

    if ([string]::IsNullOrWhiteSpace($AppLockerXmlString)) {

        Write-CleanLog "[INFO] No existe politica AppLocker local declarada."

    }
    else {

        [xml]$AppLockerXml = $AppLockerXmlString

        $Collections =
        @($AppLockerXml.AppLockerPolicy.RuleCollection)

        $ExeCollection =
        $Collections |
        Where-Object { $_.Type -eq "Exe" }

        $MsiCollection =
        $Collections |
        Where-Object { $_.Type -eq "Msi" }

        $ScriptCollection =
        $Collections |
        Where-Object { $_.Type -eq "Script" }

        $AppxCollection =
        $Collections |
        Where-Object { $_.Type -eq "Appx" }

        $DllCollection =
        $Collections |
        Where-Object { $_.Type -eq "Dll" }

        $ExeRules =
        @(
            $ExeCollection.ChildNodes |
            Where-Object {
                $_.NodeType -eq
                [System.Xml.XmlNodeType]::Element
            }
        )

        $MsiRules =
        @(
            $MsiCollection.ChildNodes |
            Where-Object {
                $_.NodeType -eq
                [System.Xml.XmlNodeType]::Element
            }
        )

        $ScriptRules =
        @(
            $ScriptCollection.ChildNodes |
            Where-Object {
                $_.NodeType -eq
                [System.Xml.XmlNodeType]::Element
            }
        )

        $AppxRules =
        @(
            $AppxCollection.ChildNodes |
            Where-Object {
                $_.NodeType -eq
                [System.Xml.XmlNodeType]::Element
            }
        )

        $DllRules =
        @(
            $DllCollection.ChildNodes |
            Where-Object {
                $_.NodeType -eq
                [System.Xml.XmlNodeType]::Element
            }
        )

        Write-CleanLog "Politica declarada (Local):"
        Write-CleanLog "  EXE:     $($ExeRules.Count) regla(s)"
        Write-CleanLog "  MSI:     $($MsiRules.Count) regla(s)"
        Write-CleanLog "  SCRIPT:  $($ScriptRules.Count) regla(s)"
        Write-CleanLog "  APPX:    $($AppxRules.Count) regla(s)"
        Write-CleanLog "  DLL:     $($DllRules.Count) regla(s)"

        # ----------------------------------------------------
        # Reconocer exactamente el AppLocker legacy conocido.
        #
        # Esperamos:
        #
        # EXE:
        #   Everyone       -> %PROGRAMFILES%\*
        #   Everyone       -> %WINDIR%\*
        #   Administrators -> *
        #
        # APPX:
        #   Everyone -> Publisher wildcard
        #
        # MSI/SCRIPT/DLL:
        #   0 reglas
        # ----------------------------------------------------

        $ExeMatches = $true

        if ($ExeRules.Count -ne 3) {
            $ExeMatches = $false
        }
        else {

            for ($i = 0; $i -lt $ExpectedLegacyExePaths.Count; $i++) {

                $ExpectedPath = $ExpectedLegacyExePaths[$i]
                $ExpectedSid = $ExpectedLegacyExeSids[$i]

                $MatchingRule =
                $ExeRules |
                Where-Object {
                    $_.LocalName -eq "FilePathRule" -and
                    $_.Action -eq "Allow" -and
                    $_.UserOrGroupSid -eq $ExpectedSid -and
                    $_.Conditions.FilePathCondition.Path -eq
                    $ExpectedPath
                }

                if (@($MatchingRule).Count -ne 1) {
                    $ExeMatches = $false
                }
            }
        }

        $AppxMatches = $false

        if ($AppxRules.Count -eq 1) {

            $AppxRule = $AppxRules[0]

            if (
                $AppxRule.LocalName -eq "FilePublisherRule" -and
                $AppxRule.Action -eq "Allow" -and
                $AppxRule.UserOrGroupSid -eq "S-1-1-0"
            ) {
                $AppxMatches = $true
            }
        }

        $EmptyCollectionsMatch =
        ($MsiRules.Count -eq 0) -and
        ($ScriptRules.Count -eq 0) -and
        ($DllRules.Count -eq 0)

        $TotalDeclaredRules =
        $ExeRules.Count +
        $MsiRules.Count +
        $ScriptRules.Count +
        $AppxRules.Count +
        $DllRules.Count

        if ($TotalDeclaredRules -eq 0) {

            $DeclaredLocalLegacy = $false
            $DeclaredUnknown = $false

            Write-CleanLog `
                "[OK] Politica AppLocker declarada vacia (0 reglas)."
        }
        else {

            $DeclaredLocalLegacy =
            $ExeMatches -and
            $AppxMatches -and
            $EmptyCollectionsMatch

            if ($DeclaredLocalLegacy) {

                $DeclaredUnknown = $false

                Write-CleanLog `
                    "[OK] Politica declarada coincide con el patron legacy conocido."
            }
            else {

                $DeclaredUnknown = $true

                Write-CleanLog `
                    "[WARN] Politica AppLocker declarada contiene reglas no reconocidas."
                Write-CleanLog `
                    "       La politica declarada NO sera eliminada automaticamente."
            }
        }
    }
}
catch {
    Stop-Clean `
        "No fue posible inspeccionar AppLocker declarado: $($_.Exception.Message)"
}

# ------------------------------------------------------------
# 11b. INVENTARIO APPLOCKER - RUNTIME
# ------------------------------------------------------------

Write-CleanLog ""
Write-CleanLog "Runtime AppLocker ($AppLockerRuntimeDirectory):"

$RuntimeLegacy = $false
$RuntimeFiles = @()
$RuntimeUnknown = $false

try {

    $RuntimeFiles = @(
        Get-ChildItem `
            -Path "$AppLockerRuntimeDirectory\*.AppLocker" `
            -ErrorAction SilentlyContinue
    )

    if ($RuntimeFiles.Count -eq 0) {

        Write-CleanLog "  [INFO] No existen archivos *.AppLocker runtime."

    }
    else {

        Write-CleanLog "  [INFO] $($RuntimeFiles.Count) archivo(s) *.AppLocker encontrado(s):"

        foreach ($RuntimeFile in $RuntimeFiles) {
            Write-CleanLog "         $($RuntimeFile.Name)  ($($RuntimeFile.Length) bytes)"
        }

        # Buscar GUID legacy conocidos dentro de los archivos
        # binarios usando codificacion ASCII + Unicode.

        $LegacyGuidsFound = @()

        foreach ($RuntimeFile in $RuntimeFiles) {

            try {

                $FileBytes =
                [System.IO.File]::ReadAllBytes(
                    $RuntimeFile.FullName
                )

                $TextContent =
                [System.Text.Encoding]::ASCII.GetString(
                    $FileBytes
                ) +
                [System.Text.Encoding]::Unicode.GetString(
                    $FileBytes
                )

                foreach ($Guid in $ExpectedLegacyAppLockerRuleIds) {

                    if (
                        $TextContent.IndexOf(
                            $Guid,
                            [System.StringComparison]::OrdinalIgnoreCase
                        ) -ge 0
                    ) {
                        if ($LegacyGuidsFound -notcontains $Guid) {
                            $LegacyGuidsFound += $Guid
                        }
                    }
                }
            }
            catch {
                Write-CleanLog `
                    "  [WARN] No fue posible leer $($RuntimeFile.Name): $($_.Exception.Message)"
            }
        }

        if (
            $LegacyGuidsFound.Count -eq
            $ExpectedLegacyAppLockerRuleIds.Count
        ) {

            $RuntimeLegacy = $true

            Write-CleanLog `
                "  [OK] Todos los GUID legacy reconocidos en runtime: $($LegacyGuidsFound.Count)/$($ExpectedLegacyAppLockerRuleIds.Count)"

            foreach ($FoundGuid in $LegacyGuidsFound) {
                Write-CleanLog "       $FoundGuid"
            }
        }
        elseif ($LegacyGuidsFound.Count -gt 0) {

            $RuntimeUnknown = $true

            Write-CleanLog `
                "  [WARN] Coincidencia parcial de GUID legacy: $($LegacyGuidsFound.Count)/$($ExpectedLegacyAppLockerRuleIds.Count)"

            foreach ($FoundGuid in $LegacyGuidsFound) {
                Write-CleanLog "       $FoundGuid"
            }

            Write-CleanLog `
                "         Runtime con coincidencia parcial: NO sera eliminado automaticamente."
        }
        else {

            $RuntimeUnknown = $true

            Write-CleanLog `
                "  [WARN] Existen archivos *.AppLocker pero NO contienen GUID legacy conocidos."
            Write-CleanLog `
                "         Runtime desconocido: NO sera eliminado automaticamente."
        }
    }
}
catch {
    Write-CleanLog `
        "  [WARN] No fue posible inventariar runtime AppLocker: $($_.Exception.Message)"
}

# Determinar estado combinado de AppLocker.
$AppLockerClean =
(-not $DeclaredLocalLegacy) -and
(-not $DeclaredUnknown) -and
(-not $RuntimeLegacy) -and
(-not $RuntimeUnknown)

Write-CleanLog ""
Write-CleanLog "Resumen estado AppLocker:"
Write-CleanLog "  DeclaredLocalLegacy: $DeclaredLocalLegacy"
Write-CleanLog "  DeclaredUnknown:     $DeclaredUnknown"
Write-CleanLog "  RuntimeLegacy:       $RuntimeLegacy"
Write-CleanLog "  RuntimeUnknown:      $RuntimeUnknown"
Write-CleanLog "  AppLockerClean:      $AppLockerClean"

# ------------------------------------------------------------
# 12. INVENTARIO MLGPO NO ADMINISTRADORES
# ------------------------------------------------------------

Write-CleanLog ""
Write-CleanLog "-------------------- MLGPO LEGACY --------------------"

$LegacyMlgpoFound = $false

if (Test-Path $LegacyUserPolicyDirectory) {

    Write-CleanLog "[OK] MLGPO No administradores encontrado."
    Write-CleanLog "     SID:  $NonAdministratorsSid"
    Write-CleanLog "     Ruta: $LegacyUserPolicyDirectory"

    if (Test-Path $LegacyRegistryPol) {

        $LegacyMlgpoFound = $true

        $PolItem = Get-Item $LegacyRegistryPol

        Write-CleanLog "[OK] User\Registry.pol encontrado."
        Write-CleanLog "     Tamano: $($PolItem.Length) bytes"
        Write-CleanLog "     Fecha:  $($PolItem.LastWriteTime)"
    }
    else {
        Write-CleanLog `
            "[WARN] Existe el MLGPO pero no contiene User\Registry.pol."
        Write-CleanLog `
            "       No sera retirado automaticamente."
    }
}
else {
    Write-CleanLog "[INFO] No existe MLGPO No administradores."
}

# ------------------------------------------------------------
# 13. PLAN
# ------------------------------------------------------------

Write-CleanLog ""
Write-CleanLog "-------------------- PLAN --------------------"

$ActionsPlanned = 0
$PlanAppLockerDeclared = $false
$PlanAppLockerRuntime = $false

if ($DeclaredLocalLegacy) {
    Write-CleanLog `
        "[PLAN] Respaldar y retirar politica AppLocker declarada legacy."
    $PlanAppLockerDeclared = $true
    $ActionsPlanned++
}
elseif ($DeclaredUnknown) {
    Write-CleanLog `
        "[SKIP] Politica AppLocker declarada desconocida; no se modificara."
}
else {
    Write-CleanLog `
        "[SKIP] Politica AppLocker declarada vacia; nada que retirar."
}

if ($RuntimeLegacy) {
    Write-CleanLog `
        "[PLAN] Respaldar y eliminar archivos runtime AppLocker legacy."
    Write-CleanLog `
        "       Se requerira reinicio despues de la limpieza."
    $PlanAppLockerRuntime = $true
    $ActionsPlanned++
}
elseif ($RuntimeUnknown) {
    Write-CleanLog `
        "[SKIP] Runtime AppLocker desconocido: no sera eliminado automaticamente."
}
else {
    Write-CleanLog `
        "[SKIP] No existen archivos runtime AppLocker que retirar."
}

if ($LegacyMlgpoFound) {
    Write-CleanLog `
        "[PLAN] Respaldar y retirar MLGPO No administradores."
    $ActionsPlanned++
}
else {
    Write-CleanLog `
        "[SKIP] No existe MLGPO legacy reconocible que retirar."
}

Write-CleanLog ""

if ($ActionsPlanned -eq 0) {

    Write-CleanLog `
        "[INFO] No hay configuracion legacy reconocida para retirar."
    Write-CleanLog ""
    Write-CleanLog "No se realizaron cambios."
    exit 0
}

# ------------------------------------------------------------
# 14. SIMULACION
# ------------------------------------------------------------

if (-not $Apply) {

    Write-CleanLog "============================================================"
    Write-CleanLog " SIMULACION FINALIZADA"
    Write-CleanLog "============================================================"
    Write-CleanLog ""
    Write-CleanLog `
        "No se modifico ninguna configuracion del sistema."
    Write-CleanLog ""
    Write-CleanLog `
        "Revise el plan anterior."
    Write-CleanLog ""
    Write-CleanLog `
        "Para ejecutar los cambios reales:"
    Write-CleanLog ""
    Write-CleanLog `
        "  .\scripts\02-CleanLegacyPolicies.ps1 -Apply"
    Write-CleanLog ""

    exit 0
}

# ------------------------------------------------------------
# 15. CREAR BACKUP
# ------------------------------------------------------------

Write-CleanLog "-------------------- BACKUP --------------------"

try {

    New-Item `
        -ItemType Directory `
        -Path $BackupRoot `
        -Force |
    Out-Null

    Write-CleanLog "[OK] Backup creado:"
    Write-CleanLog "     $BackupRoot"
}
catch {
    Stop-Clean `
        "No fue posible crear el directorio de backup: $($_.Exception.Message)"
}

# ------------------------------------------------------------
# 16. RESPALDAR APPLOCKER DECLARADO
# ------------------------------------------------------------

if ($PlanAppLockerDeclared) {

    try {

        $AppLockerBackupPath =
        Join-Path `
            $BackupRoot `
            "applocker-local.xml"

        $AppLockerXmlString |
        Out-File `
            -FilePath $AppLockerBackupPath `
            -Encoding utf8

        if (-not (Test-Path $AppLockerBackupPath)) {
            Stop-Clean `
                "No se pudo verificar el backup de AppLocker declarado."
        }

        Write-CleanLog `
            "[OK] AppLocker declarado respaldado."
    }
    catch {
        Stop-Clean `
            "Fallo el respaldo de AppLocker declarado: $($_.Exception.Message)"
    }
}

# ------------------------------------------------------------
# 16b. RESPALDAR APPLOCKER RUNTIME
# ------------------------------------------------------------

if ($PlanAppLockerRuntime) {

    try {

        $RuntimeBackupDir =
        Join-Path `
            $BackupRoot `
            "applocker-runtime"

        New-Item `
            -ItemType Directory `
            -Path $RuntimeBackupDir `
            -Force |
        Out-Null

        $RuntimeBackupOk = $true

        foreach ($RuntimeFile in $RuntimeFiles) {

            $DestPath =
            Join-Path `
                $RuntimeBackupDir `
                $RuntimeFile.Name

            Copy-Item `
                -Path $RuntimeFile.FullName `
                -Destination $DestPath `
                -Force `
                -ErrorAction Stop

            if (-not (Test-Path $DestPath)) {
                Write-CleanLog `
                    "[ERROR] No se pudo verificar backup de $($RuntimeFile.Name)."
                $RuntimeBackupOk = $false
                break
            }

            $OrigHash =
            (Get-FileHash `
                -Path $RuntimeFile.FullName `
                -Algorithm SHA256
            ).Hash

            $BackupFileHash =
            (Get-FileHash `
                -Path $DestPath `
                -Algorithm SHA256
            ).Hash

            if ($OrigHash -ne $BackupFileHash) {
                Write-CleanLog `
                    "[ERROR] SHA256 no coincide para $($RuntimeFile.Name)."
                Write-CleanLog `
                    "        Original: $OrigHash"
                Write-CleanLog `
                    "        Backup:   $BackupFileHash"
                $RuntimeBackupOk = $false
                break
            }

            Write-CleanLog `
                "[OK] $($RuntimeFile.Name) respaldado."
            Write-CleanLog `
                "     SHA256: $OrigHash"
        }

        if (-not $RuntimeBackupOk) {
            Stop-Clean `
                "Abortando: no fue posible respaldar todos los archivos runtime AppLocker."
        }

        Write-CleanLog `
            "[OK] Todos los archivos runtime AppLocker respaldados e integridad verificada."
    }
    catch {
        Stop-Clean `
            "Fallo el respaldo del runtime AppLocker: $($_.Exception.Message)"
    }
}

# ------------------------------------------------------------
# 17. RESPALDAR MLGPO
# ------------------------------------------------------------

if ($LegacyMlgpoFound) {

    try {

        $MlgpoBackupPath =
        Join-Path `
            $BackupRoot `
            "GroupPolicyUsers\$NonAdministratorsSid"

        $MlgpoBackupParent =
        Split-Path $MlgpoBackupPath -Parent

        New-Item `
            -ItemType Directory `
            -Path $MlgpoBackupParent `
            -Force |
        Out-Null

        Copy-Item `
            -Path $LegacyUserPolicyDirectory `
            -Destination $MlgpoBackupPath `
            -Recurse `
            -Force `
            -ErrorAction Stop

        $BackupRegistryPol =
        Join-Path `
            $MlgpoBackupPath `
            "User\Registry.pol"

        if (-not (Test-Path $BackupRegistryPol)) {
            Stop-Clean `
                "El backup del MLGPO no contiene Registry.pol."
        }

        $LegacyHash =
        (Get-FileHash -Path $LegacyRegistryPol -Algorithm SHA256).Hash

        $BackupHash =
        (Get-FileHash -Path $BackupRegistryPol -Algorithm SHA256).Hash

        if ($LegacyHash -ne $BackupHash) {
            Stop-Clean `
                "Discrepancia de integridad SHA256 en el respaldo de Registry.pol."
        }

        Write-CleanLog `
            "[OK] MLGPO No administradores respaldado."
        Write-CleanLog `
            "[OK] Integridad SHA256 del backup verificada."
        Write-CleanLog `
            "     SHA256: $BackupHash"
    }
    catch {
        Stop-Clean `
            "Fallo el respaldo del MLGPO: $($_.Exception.Message)"
    }
}

# ------------------------------------------------------------
# 18. RETIRAR APPLOCKER LEGACY - POLITICA DECLARADA
# ------------------------------------------------------------

if ($PlanAppLockerDeclared) {

    Write-CleanLog ""
    Write-CleanLog "-------------------- LIMPIEZA APPLOCKER DECLARADA --------------------"

    try {

        $ClearPolicyPath =
        Join-Path `
            $BackupRoot `
            "applocker-clear.xml"

        '<AppLockerPolicy Version="1" />' |
        Out-File `
            -FilePath $ClearPolicyPath `
            -Encoding ascii

        Set-AppLockerPolicy `
            -XmlPolicy $ClearPolicyPath `
            -ErrorAction Stop

        Write-CleanLog `
            "[OK] Politica AppLocker declarada legacy retirada."
    }
    catch {
        Stop-Clean `
            "Fallo al retirar politica AppLocker declarada: $($_.Exception.Message)"
    }
}

# ------------------------------------------------------------
# 18b. RETIRAR APPLOCKER LEGACY - RUNTIME
# ------------------------------------------------------------

$RuntimeRemoved = $false

if ($PlanAppLockerRuntime) {

    Write-CleanLog ""
    Write-CleanLog "-------------------- LIMPIEZA APPLOCKER RUNTIME --------------------"

    try {

        Remove-Item `
            -Path "$AppLockerRuntimeDirectory\*.AppLocker" `
            -Force `
            -ErrorAction Stop

        # Verificar que se eliminaron.
        $RemainingRuntime = @(
            Get-ChildItem `
                -Path "$AppLockerRuntimeDirectory\*.AppLocker" `
                -ErrorAction SilentlyContinue
        )

        if ($RemainingRuntime.Count -gt 0) {
            Write-CleanLog `
                "[WARN] Todavia existen $($RemainingRuntime.Count) archivo(s) *.AppLocker despues del intento de eliminacion."
            foreach ($Remaining in $RemainingRuntime) {
                Write-CleanLog "       $($Remaining.Name)"
            }
        }
        else {
            $RuntimeRemoved = $true
            Write-CleanLog `
                "[OK] Archivos runtime AppLocker legacy eliminados."
        }
    }
    catch {
        Stop-Clean `
            "Fallo al eliminar runtime AppLocker: $($_.Exception.Message)"
    }
}

# ------------------------------------------------------------
# 19. RETIRAR MLGPO LEGACY
# ------------------------------------------------------------

if ($LegacyMlgpoFound) {

    Write-CleanLog ""
    Write-CleanLog "-------------------- LIMPIEZA MLGPO --------------------"

    try {

        Remove-Item `
            -Path $LegacyUserPolicyDirectory `
            -Recurse `
            -Force `
            -ErrorAction Stop

        if (Test-Path $LegacyUserPolicyDirectory) {
            Stop-Clean `
                "El directorio MLGPO sigue presente despues de eliminarlo."
        }

        Write-CleanLog `
            "[OK] MLGPO No administradores retirado."
    }
    catch {
        Stop-Clean `
            "Fallo al retirar MLGPO: $($_.Exception.Message)"
    }
}

# ------------------------------------------------------------
# 20. REFRESCAR DIRECTIVAS (MLGPO)
# ------------------------------------------------------------

# gpupdate se ejecuta unicamente como mecanismo de refresco para
# cambios de MLGPO. NO corrige estado residual de AppLocker
# runtime; eso requiere eliminacion de *.AppLocker + reinicio.

if ($LegacyMlgpoFound) {

    Write-CleanLog ""
    Write-CleanLog "-------------------- ACTUALIZACION --------------------"

    try {

        Write-CleanLog `
            "[INFO] Ejecutando gpupdate /force (refresco MLGPO)..."

        $GpUpdate =
        Start-Process `
            -FilePath "gpupdate.exe" `
            -ArgumentList "/force" `
            -Wait `
            -PassThru `
            -NoNewWindow

        if ($GpUpdate.ExitCode -eq 0) {
            Write-CleanLog "[OK] gpupdate finalizo correctamente."
        }
        else {
            Write-CleanLog `
                "[WARN] gpupdate termino con codigo $($GpUpdate.ExitCode)."
        }
    }
    catch {
        Write-CleanLog `
            "[WARN] No fue posible ejecutar gpupdate: $($_.Exception.Message)"
    }
}

# ------------------------------------------------------------
# 21. VERIFICACION POST-LIMPIEZA
# ------------------------------------------------------------

Write-CleanLog ""
Write-CleanLog "-------------------- POST-CHECK --------------------"

$PostCheckOk = $true

# -- AppLocker Local --

try {

    $PostAppLocker =
    Get-AppLockerPolicy `
        -Local `
        -Xml `
        -ErrorAction Stop

    [xml]$PostXml = $PostAppLocker

    $PostLocalRules = @()

    if ($PostXml.AppLockerPolicy) {

        foreach (
            $Collection in
            @($PostXml.AppLockerPolicy.RuleCollection)
        ) {

            $PostLocalRules += @(
                $Collection.ChildNodes |
                Where-Object {
                    $_.NodeType -eq
                    [System.Xml.XmlNodeType]::Element
                }
            )
        }
    }

    if ($PostLocalRules.Count -eq 0) {
        Write-CleanLog `
            "[OK] AppLocker Local: 0 reglas."
    }
    else {
        Write-CleanLog `
            "[WARN] AppLocker Local todavia contiene $($PostLocalRules.Count) regla(s)."
        $PostCheckOk = $false
    }
}
catch {
    Write-CleanLog `
        "[WARN] No fue posible verificar AppLocker Local despues de limpiar."
    $PostCheckOk = $false
}

# -- AppLocker Effective --

try {

    $PostEffective =
    Get-AppLockerPolicy `
        -Effective `
        -Xml `
        -ErrorAction Stop

    [xml]$PostEffXml = $PostEffective

    $PostEffRules = @()

    if ($PostEffXml.AppLockerPolicy) {

        foreach (
            $Collection in
            @($PostEffXml.AppLockerPolicy.RuleCollection)
        ) {

            $PostEffRules += @(
                $Collection.ChildNodes |
                Where-Object {
                    $_.NodeType -eq
                    [System.Xml.XmlNodeType]::Element
                }
            )
        }
    }

    if ($PostEffRules.Count -eq 0) {
        Write-CleanLog `
            "[OK] AppLocker Effective: 0 reglas."
    }
    else {
        Write-CleanLog `
            "[WARN] AppLocker Effective todavia contiene $($PostEffRules.Count) regla(s)."
        $PostCheckOk = $false
    }
}
catch {
    Write-CleanLog `
        "[WARN] No fue posible verificar AppLocker Effective despues de limpiar."
    $PostCheckOk = $false
}

# -- AppLocker Runtime --

$PostRuntimeFiles = @(
    Get-ChildItem `
        -Path "$AppLockerRuntimeDirectory\*.AppLocker" `
        -ErrorAction SilentlyContinue
)

if ($PostRuntimeFiles.Count -eq 0) {
    Write-CleanLog `
        "[OK] AppLocker Runtime: 0 archivos *.AppLocker."
}
else {
    Write-CleanLog `
        "[WARN] AppLocker Runtime: todavia existen $($PostRuntimeFiles.Count) archivo(s) *.AppLocker."
    foreach ($PostRf in $PostRuntimeFiles) {
        Write-CleanLog "       $($PostRf.Name)"
    }
    $PostCheckOk = $false
}

# -- MLGPO --

if (-not (Test-Path $LegacyUserPolicyDirectory)) {
    Write-CleanLog `
        "[OK] MLGPO No administradores ya no esta presente."
}
else {
    Write-CleanLog `
        "[WARN] MLGPO No administradores continua presente."
    $PostCheckOk = $false
}

# ------------------------------------------------------------
# 22. RESULTADO
# ------------------------------------------------------------

Write-CleanLog ""

if ($RuntimeRemoved) {

    Write-CleanLog "============================================================"
    Write-CleanLog " [REBOOT REQUIRED]"
    Write-CleanLog "============================================================"
    Write-CleanLog ""
    Write-CleanLog "Se elimino runtime AppLocker legacy."
    Write-CleanLog "Reinicie Windows antes de considerar la limpieza verificada."
    Write-CleanLog ""
    Write-CleanLog "Despues del reinicio, ejecute nuevamente este script en modo"
    Write-CleanLog "simulacion para confirmar que AppLocker quedo limpio:"
    Write-CleanLog ""
    Write-CleanLog "  .\scripts\02-CleanLegacyPolicies.ps1"
    Write-CleanLog ""
}

if ($PostCheckOk -and -not $RuntimeRemoved) {

    Write-CleanLog "============================================================"
    Write-CleanLog " LIMPIEZA LEGACY FINALIZADA"
    Write-CleanLog "============================================================"
}
else {

    if (-not $RuntimeRemoved) {
        Write-CleanLog "============================================================"
        Write-CleanLog " LIMPIEZA LEGACY FINALIZADA CON ADVERTENCIAS"
        Write-CleanLog "============================================================"
    }
}

Write-CleanLog ""
Write-CleanLog "Backup:"
Write-CleanLog "$BackupRoot"
Write-CleanLog ""
Write-CleanLog "Log:"
Write-CleanLog "$LogPath"
Write-CleanLog ""
Write-CleanLog "SIGUIENTE PASO:"
Write-CleanLog "Ejecutar nuevamente:"
Write-CleanLog ""
Write-CleanLog "  .\scripts\01-Audit.ps1"
Write-CleanLog ""
Write-CleanLog "No se ha instalado todavia el nuevo estandar."