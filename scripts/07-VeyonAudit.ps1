# ============================================================
# Audit-VeyonClient.ps1
# Auditoría de una PC cliente del laboratorio
# NO modifica ninguna configuración.
# ============================================================

$ExpectedKeyName = "PreparatoriaTonalaSur"
$ExpectedPrefix = "LAB-A-PC"
$VeyonPath = "C:\Program Files\Veyon"
$PublicKeyPath = "C:\ProgramData\Veyon\keys\public\$ExpectedKeyName\key"

Write-Host ""
Write-Host "============================================"
Write-Host "       AUDITORIA VEYON - PC ALUMNO"
Write-Host "============================================"
Write-Host ""

# ---------- NOMBRE ----------
$ComputerName = $env:COMPUTERNAME
$NameOK = $ComputerName -like "$ExpectedPrefix*"

Write-Host "Nombre:          $ComputerName"

if ($NameOK) {
    Write-Host "Nombre correcto: SI"
}
else {
    Write-Host "Nombre correcto: NO  <-- REVISAR"
}

# ---------- VEYON INSTALADO ----------
$VeyonInstalled = Test-Path $VeyonPath

if ($VeyonInstalled) {
    Write-Host "Veyon:           INSTALADO"
}
else {
    Write-Host "Veyon:           NO INSTALADO  <-- REVISAR"
}

# ---------- SERVICIO ----------
$Service = Get-Service -Name "VeyonService" -ErrorAction SilentlyContinue

if ($null -eq $Service) {
    Write-Host "Servicio Veyon:  NO EXISTE  <-- REVISAR"
    $ServiceOK = $false
}
elseif ($Service.Status -eq "Running") {
    Write-Host "Servicio Veyon:  ENCENDIDO"
    $ServiceOK = $true
}
else {
    Write-Host "Servicio Veyon:  APAGADO  <-- REVISAR"
    $ServiceOK = $false
}

# ---------- CLAVE PUBLICA ----------
$PublicKeyExists = Test-Path $PublicKeyPath

if ($PublicKeyExists) {
    $KeyFile = Get-Item $PublicKeyPath
    Write-Host "Clave publica:   INSTALADA"
    Write-Host "Nombre clave:    $ExpectedKeyName"
    Write-Host "Tamano clave:    $($KeyFile.Length) bytes"
}
else {
    Write-Host "Clave publica:   NO ENCONTRADA  <-- REVISAR"
}

# ---------- PUERTO LOCAL ----------
$Port1110 = Get-NetTCPConnection `
    -LocalPort 1110 `
    -State Listen `
    -ErrorAction SilentlyContinue

if ($Port1110) {
    Write-Host "Puerto 1110:     ESCUCHANDO"
    $PortOK = $true
}
else {
    Write-Host "Puerto 1110:     NO ESCUCHA  <-- REVISAR"
    $PortOK = $false
}

# ---------- IP ----------
$IPv4 = Get-NetIPAddress `
    -AddressFamily IPv4 `
    -ErrorAction SilentlyContinue |
Where-Object {
    $_.IPAddress -notlike "127.*" -and
    $_.IPAddress -notlike "169.254.*"
} |
Select-Object -ExpandProperty IPAddress

if ($IPv4) {
    Write-Host "IP:              $($IPv4 -join ', ')"
}
else {
    Write-Host "IP:              NO DETECTADA  <-- REVISAR"
}

# ---------- RESULTADO ----------
Write-Host ""
Write-Host "--------------------------------------------"

$Problems = @()

if (-not $NameOK) {
    $Problems += "Nombre de PC incorrecto"
}

if (-not $VeyonInstalled) {
    $Problems += "Veyon no esta instalado"
}

if (-not $ServiceOK) {
    $Problems += "Servicio Veyon no esta funcionando"
}

if (-not $PublicKeyExists) {
    $Problems += "Falta la clave publica PreparatoriaTonalaSur"
}

if (-not $PortOK) {
    $Problems += "Veyon no esta escuchando en el puerto 1110"
}

if ($Problems.Count -eq 0) {
    Write-Host "RESULTADO:       TODO CORRECTO"
    Write-Host "Esta PC deberia ser visible desde Veyon Master."
}
else {
    Write-Host "RESULTADO:       HAY PROBLEMAS"
    Write-Host ""
    Write-Host "Revisar:"

    foreach ($Problem in $Problems) {
        Write-Host " - $Problem"
    }
}

Write-Host "--------------------------------------------"
Write-Host ""