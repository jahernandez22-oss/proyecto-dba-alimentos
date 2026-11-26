# Kit del Proyecto Final DBA · Alimentos del Valle

Scripts y configuraciones del equipo (Isaac, Yuleny y Jesús) para el proyecto
"Aseguramiento, optimización y continuidad de bases de datos en entornos híbridos (SQL y NoSQL) bajo Windows".

Cada archivo se explica y se ejecuta desde las guías del equipo (doc **Proyecto Final DBA — Guías de trabajo del equipo**)
y se marca como hecho en el **Tablero de tareas** (hoja). Este README solo dice qué hay aquí y en qué orden se corre.

## Estructura

```
proyecto-dba-alimentos\
├── README.md
├── .gitignore
├── config\
│   ├── postgresql_bloque_hardening.conf   bloque que se pega al final de postgresql.conf
│   ├── pg_hba.conf                        reemplaza al de la carpeta de datos
│   └── mongod.cfg                         reemplaza al de MongoDB
├── scripts\
│   ├── 00_parametros.ps1                  el contrato del equipo: IPs, puertos, rutas y cuentas
│   ├── windows\       00 a 10   Jesús     hardening de Windows, auditoría, evidencias y CPU
│   ├── postgresql\    00 a 11   Isaac     TLS, roles, auditoría, cifrado, inyección, carga y optimización
│   ├── mongodb\       00 a 09   Yuleny    keyFile, réplica, RBAC, auditoría, enmascaramiento, inyección, carga e índices
│   └── continuidad\             Jesús     respaldos, restauraciones, PITR, integridad, tareas y simulacros
├── evidencias\        capturas y CSV con el nombre acordado (sin contraseñas)
└── reporte\           borradores del reporte PDF
```

## Antes de correr nada

1. Windows Server 2022 (o Windows 10/11 Pro) con PostgreSQL 18, MongoDB Enterprise 8.0, mongosh 2.x,
   MongoDB Database Tools 100.x y Git para Windows.
2. Clonar en `C:\DBA\repo` y, en PowerShell como Administrador:

   ```powershell
   Set-ExecutionPolicy RemoteSigned -Scope LocalMachine
   Get-ChildItem C:\DBA\repo -Recurse | Unblock-File
   ```

3. Revisar `scripts\00_parametros.ps1`. Es el contrato: si alguien cambia una IP, un puerto o una ruta, la cambia ahí
   y avisa al equipo. Valores acordados: VM `192.168.56.10`, anfitrión autorizado `192.168.56.1`, red no autorizada
   de prueba `192.168.57.0/24`, PostgreSQL en `15432`, MongoDB en `37017`, respaldos en `E:\Respaldos`.
4. Los `.ps1` corren en Windows PowerShell 5.1 como Administrador, desde su propia carpeta
   (`cd C:\DBA\repo\scripts\windows`, etc.). Están guardados en UTF-8 con BOM para que PowerShell 5.1 lea bien
   los acentos; si los editan, conserven esa codificación (en VS Code: "Save with Encoding" → "UTF-8 with BOM").
5. Los `.sql` se corren con `psql` y los `.js` con `mongosh`; la línea exacta está en el encabezado de cada archivo.

## Orden de ejecución

**Fase 0 · Línea base (18 a 22 nov).** Jesús: `windows\00_linea_base_insegura.ps1` y las capturas del "antes".

**Fase 1 · Hardening (23 a 29 nov).** El orden importa:

1. Jesús: `windows\01_cuentas_servicio.ps1`.
2. Yuleny: `mongodb\00_generar_keyfile.ps1`. Isaac: `postgresql\00_certificado_tls.ps1`.
3. Isaac: bloque de hardening al final de `postgresql.conf` y `config\pg_hba.conf`. Yuleny: `config\mongod.cfg`.
4. Jesús: `windows\02_permisos_ntfs.ps1` y `windows\03_asignar_cuentas_servicios.ps1`.
5. Isaac: `postgresql\01` a `04`. Yuleny: `mongodb\01` a `04`.
6. Jesús: `windows\04_firewall.ps1`.
7. Isaac y Yuleny: pruebas desde el anfitrión. Jesús: `windows\05_verificar_hardening.ps1`.

**Fase 2 · Auditoría y protección de datos (30 nov a 3 dic).**

- Jesús primero: `windows\06_auditoria_windows.ps1` (registra el origen PostgreSQL del Visor de eventos); después
  `07_mantenimiento_logs.ps1`, y al final, con las tres bitácoras activas, `08_prueba_fuerza_bruta.ps1` y
  `09_recolectar_evidencias.ps1`.
- Isaac: descomentar la sección FASE 2 del bloque, reiniciar y correr `postgresql\05` a `07`.
  `06_proteccion_datos.sql` pide la llave de cifrado; léanla sin escribirla en la línea de comandos:

  ```powershell
  $llave = (New-Object System.Management.Automation.PSCredential('x', (Read-Host 'Llave' -AsSecureString))).GetNetworkCredential().Password
  psql -h 127.0.0.1 -p 15432 -U postgres -d alimentos_erp -v llave=$llave -f 06_proteccion_datos.sql
  Remove-Variable llave
  ```

- Yuleny: descomentar `auditLog` y `operationProfiling` en `mongod.cfg`, reiniciar y correr `mongodb\05` a `07`.

**Fase 3 · Rendimiento (4 a 7 dic).**

- Isaac: `postgresql\08_datos_masivos.sql` → Jesús: `windows\10_medir_cpu.ps1 -Escenario antes` →
  Isaac: `09` y `10` → Jesús: `10_medir_cpu.ps1 -Escenario despues` → Isaac: `11`.
- Yuleny: `mongodb\08` y `09`.

**Fase 4 · Continuidad (3 a 10 dic).**

- Jesús: `respaldo_completo.ps1` (corre `respaldo_postgres`, `respaldo_mongodb` y `respaldo_config`),
  `verificar_integridad.ps1 -Sellar`, `registrar_tareas.ps1`, y las restauraciones `restaurar_postgres.ps1`,
  `restaurar_mongodb.ps1` y `restaurar_config.ps1`.
- Isaac: sección FASE 4 del bloque (archivado WAL), `pitr_base_postgres.ps1` y
  `pitr_restaurar_postgres.ps1 -Hasta '2026-12-10 10:32:00'`. Después, Jesús vuelve a sellar las configuraciones.
- Los tres, el 10 de diciembre: `simulacro.ps1 -Escenario` con `pg-borrado`, `pg-pitr`, `mongo-coleccion`,
  `config-pg` y `config-mongo`. Cada corrida agrega una fila a `C:\DBA\logs\simulacros.csv`.

**Tareas programadas** (carpeta `\AlimentosDelValle\` del Programador de tareas):

| Tarea | Cuándo | Qué corre | Cuenta |
| --- | --- | --- | --- |
| ADV-Respaldo-Logico | 13:30 y 23:30 | `respaldo_completo.ps1` | svc_respaldo |
| ADV-Respaldo-Base-WAL | 03:00 | `pitr_base_postgres.ps1` | svc_respaldo |
| ADV-Refresco-Reportes | 02:00 | `SELECT reportes.refrescar_ventas()` | svc_respaldo |
| ADV-Integridad-Config | cada hora | `verificar_integridad.ps1` | SYSTEM |

## Secretos: dónde viven y qué nunca se sube

- Contraseñas de personas, la llave de cifrado de PostgreSQL y la llave del token de MongoDB: solo en el gestor de
  contraseñas del equipo.
- Lo que leen las tareas: `C:\DBA\secretos\` (`pgpass.conf`, `mongo_respaldo.yaml`, `mongo_mantenimiento.txt`,
  `pgpass_pruebas.conf`). Solo `svc_respaldo` puede leerla, además de SYSTEM y Administradores.
- Lo que se usa para restaurar: `C:\DBA\secretos\admin\` (`pgpass_admin.conf`, `mongo_restaurador.yaml`).
  Solo Administradores.
- Nunca en Git ni en el ZIP: secretos, `mongo.key`, `server.key`, llaves, respaldos ni datos. `.gitignore` ya los
  excluye. Antes de cada commit y antes de armar el ZIP, revisen cada coincidencia de:

  ```powershell
  Get-ChildItem .\scripts, .\config -Recurse -File | Select-String -Pattern 'password|clave|pwd'
  ```

## Entrega

`Proyecto_GrupoXX_BD.zip` lleva el reporte PDF, `scripts\` y `config\` con las copias **finales sacadas de la VM**:
`postgresql.conf` completo (no solo el bloque), `pg_hba.conf` y `mongod.cfg` con `auditLog` y perfilador activos.
El detalle y la checklist final están en la Guía 5.
