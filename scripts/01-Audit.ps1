#Requires -Version 5.1

<#
.SYNOPSIS
    Audita el estado actual de una computadora de laboratorio.

.DESCRIPTION
    Recopila informacion relevante para determinar posteriormente si el
    equipo cumple con el estandar de pts-lab-admin.

    IMPORTANTE:
    Este script es de SOLO LECTURA.
    No modifica usuarios, politicas, servicios ni configuracion del sistema.

.NOTES
    Proyecto: pts-lab-admin
    Preparatoria Tonala Sur
    Version: 2.0.0
#>

$ErrorActionPreference = "Continue"

# ------------------------------------------------------------
# 1. RUTAS DEL PROYECTO
# ------------------------------------------------------------

$ScriptDirectory = $PSScriptRoot
$ProjectRoot = Split-Path $ScriptDirectory -Parent

$StandardPath = Join-Path $ProjectRoot "config\standard.json"
$LabsDirectory = Join-Path $ProjectRoot "config\labs"
$LogsDirectory = Join-Path $ProjectRoot "logs"

# ------------------------------------------------------------
# 2. COMPROBAR ARCHIVOS NECESARIOS
# ------------------------------------------------------------

if (-not (Test-Path $StandardPath)) {
    Write-Error "No se encontro config\standard.json."
    exit 1
}

if (-not (Test-Path $LogsDirectory)) {
    Write-Error "No se encontro el directorio logs."
    exit 1
}

# ------------------------------------------------------------
# 3. CARGAR ESTANDAR
# ------------------------------------------------------------

try {
    $Standard = Get-Content $StandardPath -Raw |
        ConvertFrom-Json
}
catch {
    Write-Error "No se pudo leer standard.json: $($_.Exception.Message)"
    exit 1
}

$StudentUser = $Standard.accounts.student.username
$SupportUser = $Standard.accounts.support.username

# ------------------------------------------------------------
# 4. PREPARAR LOG Y UTILIDADES ASCII
# ------------------------------------------------------------

$ComputerName = $env:COMPUTERNAME
$Timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"

$LogPath = Join-Path `
    $LogsDirectory `
    "$ComputerName-Audit-$Timestamp.txt"

function ConvertTo-AsciiText {
    param (
        [string]$Text
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return $Text
    }

    $normalized = $Text.Normalize([System.Text.NormalizationForm]::FormD)
    $sb = New-Object System.Text.StringBuilder
    foreach ($c in $normalized.ToCharArray()) {
        $category = [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($c)
        if ($category -ne [System.Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$sb.Append($c)
        }
    }
    return $sb.ToString()
}

function Write-Audit {
    param (
        [string]$Message = ""
    )

    $cleanMessage = ConvertTo-AsciiText $Message
    Write-Host $cleanMessage
    $cleanMessage | Out-File -FilePath $LogPath -Append -Encoding ascii
}

# ------------------------------------------------------------
# 5. FUNCION DE AUDITORIA APPLOCKER (XML)
# ------------------------------------------------------------

function Audit-AppLockerPolicy {
    param (
        [Parameter(Mandatory = $true)]
        [ValidateSet("Local", "Effective")]
        [string]$PolicyType
    )

    Write-Audit "-------------------- APPLOCKER - $($PolicyType.ToUpper()) --------------------"

    try {
        $xmlString = $null
        if ($PolicyType -eq "Local") {
            $xmlString = Get-AppLockerPolicy -Local -Xml -ErrorAction Stop
        }
        else {
            $xmlString = Get-AppLockerPolicy -Effective -Xml -ErrorAction Stop
        }

        if ([string]::IsNullOrWhiteSpace($xmlString)) {
            Write-Audit "[INFO] No se encontro politica AppLocker $PolicyType definida."
            Write-Audit ""
            return
        }

        [xml]$xml = $xmlString
        if (-not $xml -or -not $xml.AppLockerPolicy) {
            Write-Audit "[WARN] No fue posible analizar el XML de AppLocker $PolicyType."
            Write-Audit ""
            return
        }

        $knownCollections = @('Exe', 'Msi', 'Script', 'Appx', 'Dll')
        $allRuleCollections = @($xml.AppLockerPolicy.RuleCollection)

        foreach ($cType in $knownCollections) {
            $rc = $allRuleCollections | Where-Object { $_.Type -eq $cType }

            if ($rc) {
                $enforcement = if ($rc.EnforcementMode) { $rc.EnforcementMode } else { "UNKNOWN" }
                $rules = @($rc.ChildNodes | Where-Object { $_.NodeType -eq [System.Xml.XmlNodeType]::Element })

                Write-Audit "Coleccion:   $cType"
                Write-Audit "Enforcement: $enforcement"
                Write-Audit "Reglas:      $($rules.Count)"

                if ($rules.Count -gt 0) {
                    foreach ($r in $rules) {
                        $ruleName = if ($r.Name) { $r.Name } else { "UNKNOWN" }
                        $action = if ($r.Action) { $r.Action } else { "UNKNOWN" }
                        $sid = if ($r.UserOrGroupSid) { $r.UserOrGroupSid } else { "UNKNOWN" }

                        $ruleType = switch ($r.LocalName) {
                            "FilePathRule"      { "Path" }
                            "FilePublisherRule" { "Publisher" }
                            "FileHashRule"      { "Hash" }
                            default             { if ($r.LocalName) { $r.LocalName } else { "UNKNOWN" } }
                        }

                        $condition = "UNKNOWN"
                        if ($r.Conditions) {
                            if ($r.Conditions.FilePathCondition -and $r.Conditions.FilePathCondition.Path) {
                                $condition = "Path: " + $r.Conditions.FilePathCondition.Path
                            }
                            elseif ($r.Conditions.FilePublisherCondition) {
                                $pub = $r.Conditions.FilePublisherCondition
                                $pubName = if ($pub.PublisherName) { $pub.PublisherName } else { "*" }
                                $prodName = if ($pub.ProductName) { $pub.ProductName } else { "*" }
                                $binName = if ($pub.BinaryName) { $pub.BinaryName } else { "*" }
                                $condition = "Publisher: $pubName | Product: $prodName | Binary: $binName"
                            }
                            elseif ($r.Conditions.FileHashCondition) {
                                $hashes = @($r.Conditions.FileHashCondition.FileHash)
                                $condition = "Hash: $($hashes.Count) hash(es)"
                            }
                        }

                        Write-Audit " - Regla:     $ruleName"
                        Write-Audit "   Accion:    $action"
                        Write-Audit "   SID:       $sid"
                        Write-Audit "   Tipo:      $ruleType"
                        Write-Audit "   Condicion: $condition"
                    }
                }
            }
            else {
                Write-Audit "Coleccion:   $cType"
                Write-Audit "Enforcement: NotConfigured"
                Write-Audit "Reglas:      0"
            }
            Write-Audit ""
        }

        # Inspeccionar colecciones adicionales no contempladas en las 5 estandar
        $extraCollections = $allRuleCollections | Where-Object { $knownCollections -notcontains $_.Type }
        foreach ($extra in $extraCollections) {
            $eType = if ($extra.Type) { $extra.Type } else { "UNKNOWN" }
            $eEnforce = if ($extra.EnforcementMode) { $extra.EnforcementMode } else { "UNKNOWN" }
            $eRules = @($extra.ChildNodes | Where-Object { $_.NodeType -eq [System.Xml.XmlNodeType]::Element })
            Write-Audit "Coleccion (Adicional): $eType"
            Write-Audit "Enforcement:           $eEnforce"
            Write-Audit "Reglas:                $($eRules.Count)"
            Write-Audit ""
        }
    }
    catch {
        Write-Audit "[WARN] No fue posible obtener la politica AppLocker $($PolicyType): $($_.Exception.Message)"
        Write-Audit ""
    }
}

# ------------------------------------------------------------
# 6. ENCABEZADO
# ------------------------------------------------------------

Write-Audit "============================================================"
Write-Audit " PTS LAB ADMIN - AUDITORIA"
Write-Audit "============================================================"
Write-Audit ""

# ------------------------------------------------------------
# 7. IDENTIDAD
# ------------------------------------------------------------

Write-Audit "-------------------- IDENTIDAD --------------------"
Write-Audit "Equipo:          $ComputerName"
Write-Audit "Fecha:           $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Audit "Usuario actual:  $env:USERNAME"
Write-Audit "Estandar:        $($Standard.standardVersion)"
Write-Audit ""

# ------------------------------------------------------------
# 8. LABORATORIO
# ------------------------------------------------------------

Write-Audit "-------------------- LABORATORIO --------------------"

try {
    $matchingLabs = @()

    if (Test-Path $LabsDirectory) {
        $labFiles = Get-ChildItem -Path $LabsDirectory -Filter "*.json" -File -ErrorAction SilentlyContinue
        foreach ($labFile in $labFiles) {
            try {
                $rawContent = Get-Content $labFile.FullName -Raw -ErrorAction Stop
                if ([string]::IsNullOrWhiteSpace($rawContent)) {
                    continue
                }
                $labConfig = $rawContent | ConvertFrom-Json
                if (-not $labConfig -or -not $labConfig.lab -or -not $labConfig.lab.computerPrefix) {
                    continue
                }
                $prefix = $labConfig.lab.computerPrefix
                if ($ComputerName.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $matchingLabs += $labConfig.lab
                }
            }
            catch {
                # Ignorar archivos no validos o con errores de parseo
            }
        }
    }

    if ($matchingLabs.Count -eq 0) {
        Write-Audit "[WARN] Equipo no asociado a una configuracion de laboratorio."
    }
    elseif ($matchingLabs.Count -gt 1) {
        Write-Audit "[WARN] Hostname coincide con multiples configuraciones."
    }
    else {
        $lab = $matchingLabs[0]
        Write-Audit "ID de laboratorio:      $($lab.id)"
        Write-Audit "Nombre:                 $($lab.name)"
        Write-Audit "Hostname actual:        $ComputerName"

        $expectedRole = "UNKNOWN"
        $computerNumber = "UNKNOWN"

        $isTeacher = $false
        if ($lab.teacherComputer) {
            if ($lab.teacherComputer.hostname -and ($ComputerName -eq $lab.teacherComputer.hostname)) {
                $isTeacher = $true
            }
            elseif ($lab.teacherComputer.number -ne $null) {
                $prefix = $lab.computerPrefix
                $suffix = $ComputerName.Substring($prefix.Length)
                $parsed = 0
                if ([int]::TryParse($suffix, [ref]$parsed) -and ($parsed -eq $lab.teacherComputer.number)) {
                    $isTeacher = $true
                }
            }
        }

        if ($isTeacher) {
            $expectedRole = "Teacher"
            if ($lab.teacherComputer.number -ne $null) {
                $computerNumber = $lab.teacherComputer.number
            }
        }
        else {
            $prefix = $lab.computerPrefix
            $suffix = $ComputerName.Substring($prefix.Length)
            $parsed = 0
            if ([int]::TryParse($suffix, [ref]$parsed)) {
                $computerNumber = $parsed
                if ($lab.studentComputers -and
                    $parsed -ge $lab.studentComputers.first -and
                    $parsed -le $lab.studentComputers.last) {
                    $expectedRole = "Student"
                }
                else {
                    $expectedRole = "UNKNOWN (Fuera de rango)"
                }
            }
        }

        Write-Audit "Rol esperado:           $expectedRole"
        Write-Audit "Numero de equipo:       $computerNumber"
    }
}
catch {
    Write-Audit "[ERROR] No fue posible determinar configuracion de laboratorio: $($_.Exception.Message)"
}

Write-Audit ""

# ------------------------------------------------------------
# 9. WINDOWS
# ------------------------------------------------------------

Write-Audit "-------------------- WINDOWS --------------------"

try {
    $Windows = Get-ItemProperty `
        "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" `
        -ErrorAction Stop

    Write-Audit "Producto:        $($Windows.ProductName)"
    Write-Audit "DisplayVersion:  $($Windows.DisplayVersion)"
    Write-Audit "CurrentBuild:    $($Windows.CurrentBuild)"
    Write-Audit "UBR:             $($Windows.UBR)"
    Write-Audit "Build Completo:  $($Windows.CurrentBuild).$($Windows.UBR)"
}
catch {
    Write-Audit "[ERROR] No fue posible obtener informacion de Windows: $($_.Exception.Message)"
}

Write-Audit ""

# ------------------------------------------------------------
# 10. USUARIOS LOCALES
# ------------------------------------------------------------

Write-Audit "-------------------- USUARIOS --------------------"

try {
    $Student = Get-LocalUser `
        -Name $StudentUser `
        -ErrorAction SilentlyContinue

    if ($null -eq $Student) {
        Write-Audit "[WARN] Usuario '$StudentUser' no existe."
    }
    else {
        Write-Audit "[OK] Usuario '$StudentUser' existe."
        Write-Audit "     Habilitado: $($Student.Enabled)"
    }

    $Support = Get-LocalUser `
        -Name $SupportUser `
        -ErrorAction SilentlyContinue

    if ($null -eq $Support) {
        Write-Audit "[WARN] Usuario '$SupportUser' no existe."
    }
    else {
        Write-Audit "[OK] Usuario '$SupportUser' existe."
        Write-Audit "     Habilitado: $($Support.Enabled)"
    }
}
catch {
    Write-Audit "[ERROR] No fue posible consultar usuarios locales: $($_.Exception.Message)"
}

Write-Audit ""

# ------------------------------------------------------------
# 11. ADMINISTRADORES
# ------------------------------------------------------------

Write-Audit "-------------------- ADMINISTRADORES --------------------"

try {
    $Administrators = Get-LocalGroupMember `
        -Group "Administradores" `
        -ErrorAction Stop

    Write-Audit "Miembros del grupo Administradores:"
    foreach ($Member in $Administrators) {
        Write-Audit " - $($Member.Name)"
    }

    $StudentIsAdmin = $false
    $SupportIsAdmin = $false

    foreach ($Member in $Administrators) {
        if ($Member.Name -eq "$ComputerName\$StudentUser" -or $Member.Name -eq $StudentUser) {
            $StudentIsAdmin = $true
        }
        if ($Member.Name -eq "$ComputerName\$SupportUser" -or $Member.Name -eq $SupportUser) {
            $SupportIsAdmin = $true
        }
    }

    if ($StudentIsAdmin) {
        Write-Audit "[FAIL] '$StudentUser' pertenece a Administradores."
    }
    else {
        Write-Audit "[OK] '$StudentUser' no pertenece a Administradores."
    }

    if ($SupportIsAdmin) {
        Write-Audit "[OK] '$SupportUser' pertenece a Administradores."
    }
    else {
        Write-Audit "[WARN] '$SupportUser' NO pertenece a Administradores."
    }
}
catch {
    Write-Audit "[ERROR] No fue posible consultar Administradores: $($_.Exception.Message)"
}

Write-Audit ""

# ------------------------------------------------------------
# 12. APPLOCKER - SERVICIO
# ------------------------------------------------------------

Write-Audit "-------------------- APPLOCKER - SERVICIO --------------------"

try {
    $AppIdService = Get-Service `
        -Name "AppIDSvc" `
        -ErrorAction SilentlyContinue

    if ($AppIdService) {
        Write-Audit "[OK] Servicio Application Identity encontrado."
        Write-Audit "     Nombre:       $($AppIdService.Name)"
        Write-Audit "     DisplayName:  $($AppIdService.DisplayName)"
        Write-Audit "     Estado:       $($AppIdService.Status)"
        Write-Audit "     Inicio:       $($AppIdService.StartType)"
    }
    else {
        Write-Audit "[WARN] No se encontro el servicio Application Identity (AppIDSvc)."
    }
}
catch {
    Write-Audit "[ERROR] No fue posible consultar Application Identity: $($_.Exception.Message)"
}

Write-Audit ""

# ------------------------------------------------------------
# 13. APPLOCKER - POLITICAS (LOCAL Y EFECTIVA)
# ------------------------------------------------------------

Audit-AppLockerPolicy -PolicyType "Local"
Audit-AppLockerPolicy -PolicyType "Effective"

# ------------------------------------------------------------
# 14. VEYON
# ------------------------------------------------------------

Write-Audit "-------------------- VEYON --------------------"

try {
    $VeyonServices = Get-Service |
        Where-Object {
            $_.Name -like "*veyon*" -or
            $_.DisplayName -like "*Veyon*"
        }

    if ($VeyonServices) {
        foreach ($Service in $VeyonServices) {
            Write-Audit "[OK] Servicio Veyon encontrado."
            Write-Audit "     Nombre:       $($Service.Name)"
            Write-Audit "     DisplayName:  $($Service.DisplayName)"
            Write-Audit "     Estado:       $($Service.Status)"
            Write-Audit "     Inicio:       $($Service.StartType)"
        }
    }
    else {
        Write-Audit "[WARN] No se encontro un servicio de Veyon."
    }
}
catch {
    Write-Audit "[ERROR] No fue posible consultar Veyon: $($_.Exception.Message)"
}

Write-Audit ""

# ------------------------------------------------------------
# 15. POLITICAS LOCALES
# ------------------------------------------------------------

Write-Audit "-------------------- POLITICAS LOCALES --------------------"

$MachinePolicyPath = "C:\Windows\System32\GroupPolicy"
$UserPolicyPath = "C:\Windows\System32\GroupPolicyUsers"

if (Test-Path $MachinePolicyPath) {
    Write-Audit "[OK] Directorio GroupPolicy encontrado."
    $machinePol = Join-Path $MachinePolicyPath "Machine\Registry.pol"
    $userPol = Join-Path $MachinePolicyPath "User\Registry.pol"
    Write-Audit "     Machine\Registry.pol: $(if (Test-Path $machinePol) { 'Presente' } else { 'No encontrado' })"
    Write-Audit "     User\Registry.pol:    $(if (Test-Path $userPol) { 'Presente' } else { 'No encontrado' })"
}
else {
    Write-Audit "[INFO] No se encontro GroupPolicy."
}

if (Test-Path $UserPolicyPath) {
    Write-Audit "[OK] Directorio GroupPolicyUsers encontrado."

    try {
        $PolicyFolders = Get-ChildItem `
            $UserPolicyPath `
            -Directory `
            -Force `
            -ErrorAction Stop

        if ($PolicyFolders.Count -eq 0) {
            Write-Audit "     [INFO] No hay carpetas de directivas por usuario."
        }
        else {
            foreach ($Folder in $PolicyFolders) {
                $sid = $Folder.Name
                $accountName = "UNKNOWN"

                try {
                    $secId = New-Object System.Security.Principal.SecurityIdentifier($sid)
                    $accountName = $secId.Translate([System.Security.Principal.NTAccount]).Value
                }
                catch {
                    $accountName = "UNKNOWN"
                }

                $userRegPol = Join-Path $Folder.FullName "User\Registry.pol"
                $hasRegPol = if (Test-Path $userRegPol) { "Presente" } else { "No encontrado" }

                Write-Audit " - SID:                 $sid"
                Write-Audit "   Cuenta traducida:    $accountName"
                Write-Audit "   User\Registry.pol:   $hasRegPol"
            }
        }
    }
    catch {
        Write-Audit "[WARN] No fue posible enumerar GroupPolicyUsers: $($_.Exception.Message)"
    }
}
else {
    Write-Audit "[INFO] No se encontro GroupPolicyUsers."
}

Write-Audit ""

# ------------------------------------------------------------
# 16. RESULTADO
# ------------------------------------------------------------

Write-Audit "============================================================"
Write-Audit " AUDITORIA FINALIZADA"
Write-Audit "============================================================"
Write-Audit ""
Write-Audit "Archivo generado:"
Write-Audit "$LogPath"