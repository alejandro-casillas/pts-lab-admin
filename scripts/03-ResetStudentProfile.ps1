#requires -Version 5.1

<#
.SYNOPSIS
    PTS LAB ADMIN - Reset Student Profile

.DESCRIPTION
    Elimina la cuenta/perfil local anterior de "Alumnos" y recrea
    una cuenta limpia para el estandar PTS.

    SIMULACION:
        .\03-ResetStudentProfile.ps1

    CAMBIOS REALES:
        .\03-ResetStudentProfile.ps1 -Apply

.NOTES
    Este script NO configura:
    - AppLocker
    - Politicas de Windows
    - Wallpaper
    - Veyon
    - Limpieza al reiniciar

    Debe ejecutarse desde la cuenta Soporte despues de reiniciar
    el equipo y antes de iniciar sesion como Alumnos.
#>

[CmdletBinding()]
param(
    [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ============================================================
# 1. CONSTANTES
# ============================================================

$StudentUser = "Alumnos"
$SupportUser = "Soporte"

$ComputerName = $env:COMPUTERNAME
$CurrentUser = $env:USERNAME

$Timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"

$ScriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDirectory
$LogsDirectory = Join-Path $ProjectRoot "logs"

$LogPath = Join-Path `
    $LogsDirectory `
    "$ComputerName-ResetStudent-$Timestamp.txt"

$ModeText = if ($Apply) {
    "APPLY - CAMBIOS REALES"
}
else {
    "SIMULACION - SIN CAMBIOS"
}


# ============================================================
# 2. FUNCIONES
# ============================================================

function Write-Log {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message
    )

    Write-Host $Message

    if (Test-Path $LogsDirectory) {
        Add-Content `
            -Path $LogPath `
            -Value $Message `
            -Encoding UTF8
    }
}


function Stop-Script {
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    Write-Log ""
    Write-Log "[ERROR] $Message"
    Write-Log ""
    Write-Log "Proceso abortado. No se continuara con el reset."

    exit 1
}


function Test-IsAdministrator {

    $Identity = [Security.Principal.WindowsIdentity]::GetCurrent()

    $Principal = New-Object `
        Security.Principal.WindowsPrincipal($Identity)

    return $Principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}


function Test-LocalGroupMembershipBySid {
    param(
        [Parameter(Mandatory)]
        [string]$UserName,

        [Parameter(Mandatory)]
        [string]$GroupSid
    )

    $Group = Get-LocalGroup |
    Where-Object {
        $_.SID.Value -eq $GroupSid
    }

    if (-not $Group) {
        throw "No fue posible localizar el grupo local SID $GroupSid."
    }

    $Members = Get-LocalGroupMember `
        -Group $Group.Name `
        -ErrorAction Stop

    return [PSCustomObject]@{
        GroupName = $Group.Name
        IsMember  = (
            $Members.Name -contains "$ComputerName\$UserName"
        )
    }
}


# ============================================================
# 3. INICIO / LOG
# ============================================================

if (-not (Test-Path $LogsDirectory)) {
    New-Item `
        -Path $LogsDirectory `
        -ItemType Directory `
        -Force | Out-Null
}

New-Item `
    -Path $LogPath `
    -ItemType File `
    -Force | Out-Null


Write-Log "============================================================"
Write-Log " PTS LAB ADMIN - RESET STUDENT PROFILE"
Write-Log "============================================================"
Write-Log ""
Write-Log "Equipo:          $ComputerName"
Write-Log "Fecha:           $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Log "Usuario actual:  $CurrentUser"
Write-Log "Modo:            $ModeText"


# ============================================================
# 4. PREFLIGHT
# ============================================================

Write-Log ""
Write-Log "-------------------- PREFLIGHT --------------------"


if (-not (Test-IsAdministrator)) {
    Stop-Script "PowerShell no esta elevado como administrador."
}

Write-Log "[OK] Sesion elevada como administrador."


# ------------------------------------------------------------
# No permitir ejecutar desde Alumnos
# ------------------------------------------------------------

if ($CurrentUser -ieq $StudentUser) {
    Stop-Script "Este script no puede ejecutarse desde la cuenta '$StudentUser'."
}

Write-Log "[OK] El script no se esta ejecutando desde '$StudentUser'."


# ------------------------------------------------------------
# Validar hostname Student
#
# Por ahora:
# LAB-A-PC01 ... LAB-A-PC40 = Student
# LAB-A-PC00                = Teacher
# ------------------------------------------------------------

if ($ComputerName -notmatch '^LAB-A-PC(\d{2})$') {
    Stop-Script "Hostname no reconocido para Laboratorio A: $ComputerName"
}

$PcNumber = [int]$Matches[1]

if ($PcNumber -eq 0) {
    Stop-Script "PC-00 es equipo Teacher. Este script solo aplica a equipos Student."
}

if ($PcNumber -lt 1 -or $PcNumber -gt 40) {
    Stop-Script "Numero de equipo fuera del rango Student esperado: $PcNumber"
}

Write-Log "[OK] Equipo Student reconocido."
Write-Log "     Laboratorio: A"
Write-Log "     Numero:      $PcNumber"


# ============================================================
# 5. VALIDAR SOPORTE
# ============================================================

Write-Log ""
Write-Log "-------------------- SOPORTE --------------------"

$SupportAccount = Get-LocalUser `
    -Name $SupportUser `
    -ErrorAction SilentlyContinue

if (-not $SupportAccount) {
    Stop-Script "La cuenta '$SupportUser' no existe."
}

Write-Log "[OK] Cuenta '$SupportUser' encontrada."


if (-not $SupportAccount.Enabled) {
    Stop-Script "La cuenta '$SupportUser' esta deshabilitada."
}

Write-Log "[OK] Cuenta '$SupportUser' habilitada."


# SID S-1-5-32-544 = Administrators / Administradores
try {

    $SupportAdmin = Test-LocalGroupMembershipBySid `
        -UserName $SupportUser `
        -GroupSid "S-1-5-32-544"

}
catch {

    Stop-Script "No fue posible verificar Administradores: $($_.Exception.Message)"
}


if (-not $SupportAdmin.IsMember) {
    Stop-Script "'$SupportUser' no pertenece al grupo local de Administradores."
}

Write-Log "[OK] '$SupportUser' pertenece a '$($SupportAdmin.GroupName)'."
Write-Log "[INFO] Soporte solo sera verificado. No sera modificado."


# ============================================================
# 6. INVENTARIO ALUMNOS
# ============================================================

Write-Log ""
Write-Log "-------------------- ALUMNOS ACTUAL --------------------"

$StudentAccount = Get-LocalUser `
    -Name $StudentUser `
    -ErrorAction SilentlyContinue

$OldStudentSid = $null
$OldProfile = $null


if ($StudentAccount) {

    $OldStudentSid = $StudentAccount.SID.Value

    Write-Log "[INFO] Cuenta '$StudentUser' encontrada."
    Write-Log "       SID:     $OldStudentSid"
    Write-Log "       Enabled: $($StudentAccount.Enabled)"

    try {

        $OldProfile = Get-CimInstance Win32_UserProfile |
        Where-Object {
            $_.SID -eq $OldStudentSid
        } |
        Select-Object -First 1

    }
    catch {

        Stop-Script "No fue posible consultar Win32_UserProfile."
    }


    if ($OldProfile) {

        Write-Log "[INFO] Perfil asociado encontrado."
        Write-Log "       Ruta:    $($OldProfile.LocalPath)"
        Write-Log "       Loaded:  $($OldProfile.Loaded)"
        Write-Log "       Special: $($OldProfile.Special)"


        if ($OldProfile.Loaded) {
            Stop-Script "El perfil de '$StudentUser' esta cargado. Reinicie e ingrese directamente como Soporte."
        }


        if ($OldProfile.Special) {
            Stop-Script "El perfil de '$StudentUser' esta marcado como Special. No se eliminara."
        }

    }
    else {

        Write-Log "[INFO] La cuenta existe pero no tiene perfil Win32_UserProfile asociado."

    }

}
else {

    Write-Log "[INFO] La cuenta '$StudentUser' no existe."

}


# ============================================================
# 7. PLAN
# ============================================================

Write-Log ""
Write-Log "-------------------- PLAN --------------------"


if ($StudentAccount) {

    if ($OldProfile) {
        Write-Log "[PLAN] Eliminar perfil anterior:"
        Write-Log "       $($OldProfile.LocalPath)"
    }
    else {
        Write-Log "[SKIP] No existe perfil registrado que retirar."
    }

    Write-Log "[PLAN] Eliminar cuenta local '$StudentUser'."

}
else {

    Write-Log "[SKIP] No existe cuenta anterior que retirar."

}


Write-Log "[PLAN] Crear cuenta local '$StudentUser' desde cero."
Write-Log "[PLAN] Crear cuenta sin contrasena."
Write-Log "[PLAN] Configurar PasswordNeverExpires = True."
Write-Log "[PLAN] Garantizar pertenencia al grupo Usuarios."
Write-Log "[PLAN] Garantizar que NO pertenezca a Administradores."
Write-Log "[PLAN] NO crear perfil de usuario manualmente."

Write-Log ""
Write-Log "[ADVERTENCIA]"
Write-Log "En modo -Apply se eliminara permanentemente el perfil anterior"
Write-Log "de '$StudentUser' y todo su contenido local."


# ============================================================
# 8. FIN DE SIMULACION
# ============================================================

if (-not $Apply) {

    Write-Log ""
    Write-Log "============================================================"
    Write-Log " SIMULACION FINALIZADA"
    Write-Log "============================================================"
    Write-Log ""
    Write-Log "No se modifico ninguna configuracion del sistema."
    Write-Log ""
    Write-Log "Para ejecutar los cambios reales:"
    Write-Log ""
    Write-Log "  .\03-ResetStudentProfile.ps1 -Apply"
    Write-Log ""
    Write-Log "Log:"
    Write-Log $LogPath

    exit 0
}


# ============================================================
# 9. RESET - ELIMINAR PERFIL ANTERIOR
# ============================================================

Write-Log ""
Write-Log "-------------------- RESET --------------------"


if ($StudentAccount -and $OldProfile) {

    Write-Log "[INFO] Eliminando perfil anterior de '$StudentUser'..."

    try {

        Remove-CimInstance `
            -InputObject $OldProfile `
            -ErrorAction Stop

    }
    catch {

        Stop-Script "No fue posible eliminar el perfil anterior: $($_.Exception.Message)"
    }


    Start-Sleep -Seconds 1


    $ProfileStillExists = Get-CimInstance Win32_UserProfile |
    Where-Object {
        $_.SID -eq $OldStudentSid
    }

    if ($ProfileStillExists) {
        Stop-Script "El perfil anterior continua registrado despues de Remove-CimInstance."
    }


    Write-Log "[OK] Perfil anterior eliminado."

}
elseif ($StudentAccount) {

    Write-Log "[SKIP] La cuenta anterior no tenia perfil registrado."

}


# ============================================================
# 10. ELIMINAR CUENTA ANTERIOR
# ============================================================

if ($StudentAccount) {

    Write-Log "[INFO] Eliminando cuenta anterior '$StudentUser'..."

    try {

        Remove-LocalUser `
            -Name $StudentUser `
            -ErrorAction Stop

    }
    catch {

        Stop-Script "No fue posible eliminar la cuenta anterior: $($_.Exception.Message)"
    }


    if (
        Get-LocalUser `
            -Name $StudentUser `
            -ErrorAction SilentlyContinue
    ) {

        Stop-Script "La cuenta anterior '$StudentUser' continua existiendo."
    }


    Write-Log "[OK] Cuenta anterior eliminada."

}


# ============================================================
# 11. COMPROBAR RESIDUO C:\Users\Alumnos
# ============================================================

$ExpectedOldPath = "C:\Users\$StudentUser"

if (Test-Path $ExpectedOldPath) {

    Write-Log "[WARN] Permanece un directorio residual:"
    Write-Log "       $ExpectedOldPath"
    Write-Log ""
    Write-Log "[WARN] No se eliminara a ciegas."
    Write-Log "       Reviselo manualmente antes del primer login."

    Stop-Script "Existe un directorio residual de '$StudentUser'. No es seguro continuar con la recreacion."

}

Write-Log "[OK] No existe directorio residual C:\Users\$StudentUser."


# ============================================================
# 12. CREAR ALUMNOS NUEVO
# ============================================================

Write-Log "[INFO] Creando nueva cuenta '$StudentUser'..."


try {

    New-LocalUser `
        -Name $StudentUser `
        -NoPassword `
        -AccountNeverExpires `
        -UserMayNotChangePassword `
        -ErrorAction Stop |
    Out-Null

}
catch {

    Stop-Script "No fue posible crear '$StudentUser': $($_.Exception.Message)"
}


Write-Log "[OK] Cuenta '$StudentUser' creada."


try {

    Set-LocalUser `
        -Name $StudentUser `
        -PasswordNeverExpires $true `
        -ErrorAction Stop

}
catch {

    Stop-Script "No fue posible configurar PasswordNeverExpires."
}


Write-Log "[OK] PasswordNeverExpires = True."


# ============================================================
# 13. GRUPOS
# ============================================================

# SID S-1-5-32-545 = Users / Usuarios
$UsersGroup = Get-LocalGroup |
Where-Object {
    $_.SID.Value -eq "S-1-5-32-545"
}

# SID S-1-5-32-544 = Administrators / Administradores
$AdminsGroup = Get-LocalGroup |
Where-Object {
    $_.SID.Value -eq "S-1-5-32-544"
}


if (-not $UsersGroup) {
    Stop-Script "No fue posible localizar el grupo local Usuarios."
}

if (-not $AdminsGroup) {
    Stop-Script "No fue posible localizar el grupo local Administradores."
}


$CurrentUsersMembers = Get-LocalGroupMember `
    -Group $UsersGroup.Name `
    -ErrorAction Stop


if (
    $CurrentUsersMembers.Name -notcontains "$ComputerName\$StudentUser"
) {

    try {

        Add-LocalGroupMember `
            -Group $UsersGroup.Name `
            -Member $StudentUser `
            -ErrorAction Stop

    }
    catch {

        Stop-Script "No fue posible agregar '$StudentUser' a '$($UsersGroup.Name)'."
    }

}


Write-Log "[OK] '$StudentUser' pertenece a '$($UsersGroup.Name)'."


$CurrentAdminMembers = Get-LocalGroupMember `
    -Group $AdminsGroup.Name `
    -ErrorAction Stop


if (
    $CurrentAdminMembers.Name -contains "$ComputerName\$StudentUser"
) {

    try {

        Remove-LocalGroupMember `
            -Group $AdminsGroup.Name `
            -Member $StudentUser `
            -ErrorAction Stop

    }
    catch {

        Stop-Script "No fue posible retirar '$StudentUser' de Administradores."
    }

}


Write-Log "[OK] '$StudentUser' no pertenece a '$($AdminsGroup.Name)'."


function Test-PasswordNeverExpires {
    param(
        [Parameter(Mandatory)]
        [string]$UserName
    )

    try {
        $User = [ADSI]"WinNT://$env:COMPUTERNAME/$UserName,user"
        $Flags = [int]$User.UserFlags.Value

        # UF_DONT_EXPIRE_PASSWD = 0x10000
        return (($Flags -band 0x10000) -ne 0)
    }
    catch {
        throw "No fue posible consultar UserFlags para '$UserName': $($_.Exception.Message)"
    }
}


# ============================================================
# 14. POST-CHECK
# ============================================================

Write-Log ""
Write-Log "-------------------- POST-CHECK --------------------"


$NewStudent = Get-LocalUser `
    -Name $StudentUser `
    -ErrorAction SilentlyContinue


if (-not $NewStudent) {
    Stop-Script "POST-CHECK: '$StudentUser' no existe."
}


$NewStudentSid = $NewStudent.SID.Value


if (-not $NewStudent.Enabled) {
    Stop-Script "POST-CHECK: '$StudentUser' esta deshabilitado."
}


$PostUsers = Test-LocalGroupMembershipBySid `
    -UserName $StudentUser `
    -GroupSid "S-1-5-32-545"

$PostAdmins = Test-LocalGroupMembershipBySid `
    -UserName $StudentUser `
    -GroupSid "S-1-5-32-544"


if (-not $PostUsers.IsMember) {
    Stop-Script "POST-CHECK: '$StudentUser' no pertenece a Usuarios."
}

if ($PostAdmins.IsMember) {
    Stop-Script "POST-CHECK: '$StudentUser' pertenece a Administradores."
}


try {
    $PasswordNeverExpires = Test-PasswordNeverExpires `
        -UserName $StudentUser
}
catch {
    Stop-Script "POST-CHECK: $($_.Exception.Message)"
}

if (-not $PasswordNeverExpires) {
    Stop-Script "POST-CHECK: la contrasena de '$StudentUser' puede expirar."
}


$NewProfile = Get-CimInstance Win32_UserProfile |
Where-Object {
    $_.SID -eq $NewStudentSid
}


if ($NewProfile) {
    Stop-Script "POST-CHECK: existe inesperadamente un perfil para el nuevo SID."
}


Write-Log "[OK] Cuenta '$StudentUser' recreada correctamente."
Write-Log "[OK] Nuevo SID: $NewStudentSid"
Write-Log "[OK] Cuenta habilitada."
Write-Log "[OK] PasswordNeverExpires: True."
Write-Log "[OK] Miembro de '$($PostUsers.GroupName)'."
Write-Log "[OK] No pertenece a '$($PostAdmins.GroupName)'."
Write-Log "[OK] Perfil nuevo aun no creado (esperado)."


# ============================================================
# 15. RESULTADO
# ============================================================

Write-Log ""
Write-Log "============================================================"
Write-Log " RESET STUDENT PROFILE FINALIZADO"
Write-Log "============================================================"
Write-Log ""
Write-Log "La cuenta '$StudentUser' esta preparada."
Write-Log ""
Write-Log "NO inicie sesion como Alumnos todavia."
Write-Log "Windows creara el perfil limpio durante el primer inicio."
Write-Log ""
Write-Log "SIGUIENTE PASO:"
Write-Log "Ejecutar 04-ConfigureStudentPolicies.ps1 antes del primer"
Write-Log "inicio de sesion de Alumnos."
Write-Log ""
Write-Log "Log:"
Write-Log $LogPath