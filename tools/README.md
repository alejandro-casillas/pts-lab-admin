# PTS Lab Admin

Herramienta de administración, estandarización y seguridad para los laboratorios de cómputo de la Preparatoria Tonalá Sur.

El proyecto busca proporcionar una configuración reproducible para las computadoras de los laboratorios actuales y futuros de la escuela, evitando configuraciones manuales diferentes entre equipos.

## Objetivos

- Estandarizar las computadoras destinadas a alumnos.
- Mantener una cuenta administrativa de soporte separada.
- Evitar la instalación y ejecución de software no autorizado.
- Proteger la configuración institucional de Windows.
- Mantener una configuración uniforme de escritorio.
- Integrar y verificar Veyon.
- Facilitar auditoría y diagnóstico.
- Permitir que futuros responsables de soporte puedan mantener y ampliar la solución.
- Evitar configuraciones específicas de un solo laboratorio siempre que sea posible.

## Alcance inicial

El primer despliegue y las primeras pruebas se realizarán en el Laboratorio A.

Actualmente se contemplan:

- Laboratorio A: PC-00 de docente + PC-01 a PC-40 de alumnos.
- Laboratorio B: PC-00 de docente + PC-01 a PC-32 de alumnos.

La arquitectura debe permitir agregar futuros laboratorios mediante archivos de configuración, sin modificar la lógica principal de los scripts.

## Principios del proyecto

1. Seguridad antes que comodidad de despliegue.
2. Probar los cambios antes de aplicarlos de forma general.
3. No asumir que todas las computadoras tienen el mismo estado previo.
4. Separar configuración, lógica, recursos y registros.
5. No almacenar contraseñas, claves privadas ni credenciales en el repositorio.
6. Los scripts de auditoría y verificación no deben modificar el sistema.
7. Las operaciones destructivas deben validar sus precondiciones antes de ejecutarse.
8. Una computadora debe poder verificarse objetivamente contra el estándar.
9. Las configuraciones específicas de cada laboratorio deben permanecer fuera de la lógica general.
10. El proyecto debe poder ser mantenido por futuros responsables de soporte.

## Estado del proyecto

En desarrollo.

El Laboratorio A será utilizado como entorno piloto antes de extender el estándar al resto de los equipos.

## Plataforma inicial

- Windows 11 Pro
- PowerShell
- AppLocker
- Directivas locales de Windows
- Veyon

## Advertencia

Este proyecto modifica configuraciones de seguridad y políticas locales de Windows.

Los cambios deben probarse primero en equipos piloto antes de aplicarse a un laboratorio completo.