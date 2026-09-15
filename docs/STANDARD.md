# Estándar de Computadoras de Alumno — PTS

## 1. Propósito

Este documento define el estado esperado de una computadora destinada a alumnos en los laboratorios de cómputo de la Preparatoria Tonalá Sur.

Los scripts del proyecto `pts-lab-admin` deben implementar y verificar este estándar.

---

## 2. Modelo de usuarios

### Soporte

- Cuenta local.
- Miembro del grupo Administradores.
- Protegida mediante contraseña.
- Utilizada exclusivamente para administración, instalación de software y mantenimiento.
- No debe estar sujeta a las restricciones destinadas a alumnos.

### Alumnos

- Cuenta local.
- Usuario estándar.
- Sin privilegios administrativos.
- No debe pertenecer al grupo Administradores.
- Puede utilizar el software previamente autorizado e instalado por Soporte.

---

## 3. Instalación y ejecución de software

El principio general es:

> El software es instalado y administrado por Soporte. Los alumnos utilizan el software autorizado, pero no instalan ni ejecutan software arbitrario.

Se debe permitir la ejecución normal del software instalado administrativamente en ubicaciones protegidas del sistema.

Se debe impedir la ejecución no autorizada desde ubicaciones controladas por el usuario, incluyendo:

- Descargas.
- Escritorio personal.
- AppData.
- Unidades USB.
- Otras ubicaciones escribibles por el usuario cuando representen un riesgo equivalente.

El almacenamiento USB permanece permitido.

Los alumnos pueden abrir documentos, imágenes, presentaciones y otros archivos de trabajo desde dispositivos USB, pero esto no implica autorización para ejecutar programas desde ellos.

---

## 4. Aplicaciones y herramientas administrativas

Los alumnos no requieren acceso interactivo a herramientas administrativas o shells de línea de comandos.

El estándar debe restringir, cuando sea técnicamente apropiado:

- Command Prompt (CMD).
- Windows PowerShell.
- PowerShell ISE.
- Registry Editor.
- Microsoft Management Console (MMC).

Las restricciones no deben impedir que la cuenta Soporte utilice estas herramientas.

---

## 5. Windows

Para la cuenta Alumnos:

- Microsoft Store debe permanecer bloqueada.
- El acceso general a Configuración y Panel de control debe permanecer restringido.
- La personalización institucional debe permanecer protegida.
- El fondo de pantalla institucional no debe poder modificarse.
- No debe poder modificarse libremente la apariencia institucional del equipo.
- No debe poder modificar los accesos directos institucionales protegidos.

Deben mantenerse disponibles las funciones necesarias para el trabajo normal del alumno, incluyendo:

- Explorador de archivos.
- Administrador de tareas.
- Uso normal de teclado y mouse.
- Funciones necesarias de accesibilidad.
- Reproducción y control normal de audio.
- Navegadores autorizados.
- Microsoft Office y demás software académico autorizado.

---

## 6. Internet

El proyecto no implementará filtrado general de contenido web.

Los alumnos pueden utilizar los navegadores autorizados y acceder a los sitios necesarios para sus actividades académicas.

La seguridad del equipo debe centrarse en impedir modificaciones persistentes o ejecución de software no autorizado, no en restringir arbitrariamente el contenido consultado.

---

## 7. Escritorio

El equipo debe utilizar un fondo institucional administrado.

Los accesos directos institucionales deben ser administrados por Soporte y no deben poder ser eliminados o modificados por Alumnos.

Los alumnos pueden crear archivos personales y temporales durante su sesión de trabajo.

---

## 8. Datos temporales

Las computadoras son equipos compartidos.

Los alumnos no deben depender del almacenamiento local como almacenamiento permanente.

Los trabajos que deban conservarse deben guardarse en medios externos o servicios autorizados, como almacenamiento en la nube.

Se contempla implementar limpieza automática de datos temporales de alumnos.

Hasta que dicha funcionalidad haya sido diseñada, probada y aprobada, no debe asumirse que el equipo elimina automáticamente todos los datos al reiniciar.

---

## 9. Veyon

Las computadoras de alumno deben:

- Tener Veyon correctamente instalado.
- Mantener el servicio requerido en funcionamiento.
- Utilizar la configuración institucional definida.
- Poder ser administradas desde la computadora docente correspondiente.

Las credenciales y claves privadas de Veyon no deben almacenarse directamente en el repositorio.

---

## 10. AppLocker

AppLocker será utilizado como mecanismo principal de control de ejecución.

Las políticas deben contemplar:

- Ejecutables.
- Windows Installer.
- Scripts.
- Aplicaciones empaquetadas.

Las reglas DLL permanecerán inicialmente sin configurar salvo que una necesidad futura justifique su uso.

Las nuevas políticas deben probarse inicialmente en modo de auditoría antes de utilizarse en modo obligatorio.

El estándar debe priorizar reglas de autorización controladas sobre listas manuales de programas prohibidos.

---

## 11. Auditoría

La auditoría debe ser una operación de solo lectura.

Debe permitir conocer, como mínimo:

- Nombre del equipo.
- Versión de Windows.
- Usuarios locales relevantes.
- Miembros del grupo Administradores.
- Estado de AppLocker.
- Estado del servicio Application Identity.
- Políticas relevantes existentes.
- Estado de Veyon.
- Configuración relevante para el estándar.

La auditoría no debe corregir automáticamente los problemas encontrados.

---

## 12. Verificación

Después de configurar un equipo debe existir una verificación independiente.

El resultado debe indicar claramente:

- PASS: requisito cumplido.
- FAIL: requisito incumplido.
- WARN: estado que requiere revisión.

La verificación no debe modificar la configuración del equipo.

---

## 13. Seguridad del proyecto

Nunca deben almacenarse en el repositorio:

- Contraseñas.
- Claves privadas.
- Tokens.
- Credenciales administrativas.
- Información equivalente que permita obtener acceso privilegiado.

---

## 14. Compatibilidad futura

Las configuraciones específicas de un laboratorio deben mantenerse separadas de la lógica general.

Agregar un nuevo laboratorio no debería requerir modificar los scripts principales.

El estándar institucional debe poder evolucionar mediante versiones documentadas.