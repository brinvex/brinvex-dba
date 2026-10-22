# Brinvex Database Admin

One PowerShell script for managing PostgreSQL on Windows: unattended install,
application roles and databases, backup and restore, and foreign-data-wrappers
 setup and refresh.

## Requirements

- Windows PowerShell 5.1 (built into Windows) or PowerShell 7
- Administrator rights for `Install-PgServer` and `Uninstall-PgServer`: in the
  Start menu, right-click **Windows PowerShell** and choose **Run as administrator**
- For `Install-PgServer`: internet access to download the PostgreSQL installer, or
  the installer `.exe` itself
- PowerShell allowed to run scripts. A fresh Windows installation blocks them, with the
  error "running scripts is disabled on this system". Allow them once for your Windows
  user, without administrator rights: `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`.
  It lasts until changed; `Set-ExecutionPolicy -Scope CurrentUser Undefined` undoes it.

## Usage

```powershell
. .\BxDba.ps1

$conf = @{
    Port                   = 5430
    SuperPass              = 'S3cr3t!123'
    EnvName                = 'Dev1'
    TargetVersion          = '18.3'
    AllowedClientAddresses = '192.168.0.0/16'
    Extensions             = 'btree_gist', 'postgres_fdw'
    AppUsers               = @{ my_app1 = 'app-password' }
    AppDatabases           = @{ my_app1 = 'my_app1' }
    PgServerSettings       = "shared_buffers = '256MB'", "work_mem = '8MB'"
}

Install-PgServer -Conf $conf
Backup-PgDatabase -Conf $conf -Database my_app1 -BackupPath 'C:\bck\my_app1.backup'
```

Add `-Verbose` to any command to see each program it runs.

## Commands

| Command | What it does |
| --- | --- |
| `Install-PgServer -Conf` | Gets the installer (see [Choosing the PostgreSQL version](#choosing-the-postgresql-version)), extracts the binaries, installs the VC++ runtime, runs `initdb`, registers and starts the Windows service, opens network access in `postgresql.conf` and `pg_hba.conf`, applies `PgServerSettings`, creates `AppUsers`, `AppDatabases` and `Extensions`, and adds the firewall rule. Safe to run again. |
| `Uninstall-PgServer -Conf [-SkipBackup]` | Dumps every database into `BackupDir`, starting the service if it is stopped, then stops and unregisters the service, moves the data folder aside, deletes the binaries, removes the firewall rule, and returns database → dump path. Changes nothing if a dump fails. `-SkipBackup` uninstalls without the dumps. |
| `Restart-PgService -Conf [-OnlyIfRunning]` | Restarts the Windows service. |
| `New-PgUser -Conf -Users` | Creates the roles that don't exist yet (role → password). |
| `New-PgDatabase -Conf -Databases` | Creates the databases that don't exist yet (database → owner). |
| `Test-PgRole -Conf -Role`, `Test-PgDatabase -Conf -Database` | Whether it exists. |
| `Remove-PgDatabase -Conf -Database [-SkipBackup]` | Dumps the database into `BackupDir` as `<env>_<db>_<yyyyMMdd_HHmmss>_before_drop.backup`, drops it `WITH (FORCE)` only if that worked, and returns the dump path. `-SkipBackup` drops it without a dump. |
| `Backup-PgDatabase -Conf -Database -BackupPath` | `pg_dump` in the configured format and parallelism. |
| `Restore-PgDatabase -Conf -BackupPath -Database -Owner` | Creates the database and restores into it. Refuses an existing database. |
| `Backup-PgDataFolder -Conf` | Moves the whole data folder to `<DbDataPath>_backup\`. The service must be stopped. |
| `Install-PgFdw -Conf -Fdw` | Creates the extension, foreign server, user mapping and schema, and imports the foreign schema. |
| `Update-PgFdw -Conf -Fdw` | Drops and re-imports the foreign tables. Stops without changing anything if a view depends on them. |
| `Invoke-Psql -Conf -Sql` | Runs any SQL. Options: `-Database`, `-User`/`-Password`, `-Tuples`, `-ExpectTag`, `-AssertSuccess`. |
| `Get-VCRedist` | Lists the installed Visual C++ redistributables. |

## Configuration

`$conf` is a plain hashtable. Unknown keys are rejected, so a typo fails straight
away.

| Key | Default |
| --- | --- |
| `DbHost` | `localhost` |
| `Port` | `5432` |
| `SuperUser` | `postgres` |
| `SuperPass` | none; required by install, uninstall, backup and restore |
| `DbHomePath` | `C:\app\my_app1\postgresql` |
| `DbDataPath` | `<DbHomePath>\db_data` |
| `DbToolsPath` | `<DbHomePath>\db_system\bin`; where `psql`, `pg_dump` and `pg_restore` come from, e.g. a client installation when the server is on another machine. Install and uninstall always use the tools of the server they install. |
| `BackupFormat` | `DIRECTORY`; or `PLAIN`, `CUSTOM_ARCHIVE` |
| `BackupRestoreParallelism` | `1`; above 1 needs `DIRECTORY` |
| `EnvName` | `Dev1` |
| `WinServiceName` | `<EnvName>_Postgresql` |
| `FirewallRuleName` | `<EnvName>_PG - open <Port>` |
| `TargetVersion` | none; `newest`, `18.3`, `18.3-2` or `postgresql-18.3-2-windows-x64` |
| `InstallerPath` | none; an installer `.exe` to use instead of `TargetVersion` |
| `DownloadPath` | the user's Downloads folder |
| `BackupDir` | `db-bck` next to `DbHomePath`; dumps taken before every drop and uninstall, and those of `Invoke-PgDbaCommand` |
| `DbLocale` | `English_United States.UTF8` |
| `DbListenAddresses` | `*` |
| `InstallVCRedist` | `$true` |
| `AllowedClientAddresses` | none |
| `PgServerSettings` | none; e.g. `"shared_buffers = '256MB'"` |
| `Extensions` | none |
| `AppUsers` | none; role → password |
| `AppDatabases` | none; database → owner |

The FDW commands take a second hashtable, `-Fdw`, with these keys, all required:
`SourceDb`, `SourceDbUser`, `SourceDbPass`, `FdwSchema`, `ForeignHost`,
`ForeignPort`, `ForeignDb`, `ForeignSchema`, `ForeignUser`, `ForeignPass`.
The foreign server is named after `FdwSchema`.

## Choosing the PostgreSQL version

`Install-PgServer` needs either `TargetVersion` or `InstallerPath`, not both. With
`TargetVersion` it uses the matching Windows x64 installer from EnterpriseDB, the
official distributor of the PostgreSQL Windows installers:

| `TargetVersion` | Installs |
| --- | --- |
| `postgresql-18.3-2-windows-x64` or `18.3-2` | exactly that installer build |
| `18.3` | the highest published build of 18.3 |
| `newest` | the latest PostgreSQL release, according to postgresql.org, that EnterpriseDB has published an installer for |

- If the installer is already in `DownloadPath`, it is used and nothing is
  downloaded. With an exact version such as `18.3-2`, that means no internet access
  is needed. `18.3` and `newest` always check online which builds exist.
- Otherwise it is downloaded to `DownloadPath` from
  `https://get.enterprisedb.com/postgresql/`. The download is saved as a `.partial`
  file first and only renamed once its size and signature have been checked, so an
  interrupted download is never mistaken for a complete one.
- The installer runs with administrator rights, so it must carry a valid
  EnterpriseDB code signature. This applies to both downloaded installers and those
  found in `DownloadPath`.
- After a successful install, a downloaded installer is deleted. After a failed
  install it is kept, so the next attempt doesn't download it again. An installer
  that was already in `DownloadPath`, or given as `InstallerPath`, is never deleted.

The version only matters for the first install. Once the binaries are in place,
running `Install-PgServer` again doesn't look for an installer at all.

## Worth knowing

- Database passwords stay off command lines, where other processes could read
  them. They go through `PGPASSWORD`, a temporary SQL file, or `initdb --pwfile`.
  The one exception is the installer's `--superpassword`, which has no other way
  to receive it.
- Uninstall never deletes data: it dumps every database into `BackupDir` as
  `<env>_<db>_<yyyyMMdd_HHmmss>.backup`, and moves the data folder to `<DbDataPath>_backup\`.
  The dumps use the `pg_dump` of the server being removed. Roles are not dumped;
  `Install-PgServer` creates `AppUsers` again.
- A role that is made superuser for a restore or for creating extensions is always
  demoted again, even when the step fails.
- Service and firewall handling uses PowerShell cmdlets rather than reading
  console text, so it works on a non-English Windows.

## Using it in another project

Copy `BxDba.ps1` into the project at a tagged version, straight from GitHub:

```powershell
Invoke-WebRequest -UseBasicParsing -OutFile BxDba.ps1 -Uri 'https://raw.githubusercontent.com/brinvex/brinvex-dba/v1.1.0/BxDba.ps1'
```

- This gives an exact copy of the tagged file. A copy saved from a browser is
  marked as coming from the internet, and PowerShell refuses to load it until you
  run `Unblock-File BxDba.ps1`.
- Don't edit the copy. Keep the project's settings in a script of its own that
  dot-sources `BxDba.ps1`. To change `BxDba.ps1` itself, change it in this
  repository, tag a new version and copy it again.
- The version is in the script's header, and `Install-PgServer` logs it first, so
  you can tell which version a project or a server uses.

To release a version, change it in both places at the top of `BxDba.ps1`, the
header and `Get-DbaScriptVersion` (a test fails if they differ), then tag the
commit, e.g. `v1.1.0`. Keep the script plain ASCII: Windows PowerShell 5.1 misreads
other characters in a file saved without a byte order mark.

## Applications configured by .properties files

For an application that keeps its database settings in Java `.properties` files,
the project's script only has to say where those files are:

```powershell
# ops\db\dba\BxFinTracker-db.ps1
param([string]$Command, [switch]$SkipBackup)
. "$PSScriptRoot\BxDba.ps1"

$appHome = $env:BRINVEX_FINTRACKER_HOME
$db = Import-PgDbaProperties -KeyPrefix 'bx.fintracker' -HomePath $appHome -PropertyFile @(
    "$appHome\brinvex-fintracker\brinvex-fintracker-core-impl\src\main\resources\brinvex-fintracker-default.properties"
    "$appHome\brinvex-fintracker.properties"
) -Settings @{ PgServerSettings = "shared_buffers = '256MB'", "work_mem = '8MB'" }

if ($MyInvocation.InvocationName -ne '.') { Invoke-PgDbaCommand $Command $db -SkipBackup:$SkipBackup }
```

Then run `.\ops\db\dba\BxFinTracker-db.ps1 backup`, or any other command below.
Dot-sourced, the script only loads `$db`, for ad hoc use such as
`Invoke-Psql -Conf $db.Conf -Sql 'SELECT version()' -Tuples`.

The commands work on the one database in `AppDatabases`, and read the environment
name, that database and its owner from `$db.Conf`, so a `-Settings` override
applies to them as well.

| Command | What it does |
| --- | --- |
| `backup` | Dumps the database into `BackupDir` as `<env>_<appDb>_<yyyyMMdd_HHmmss>.backup`. |
| `restore` | Replaces the database with the newest of those dumps. It first dumps the current one into `BackupDir` as `<env>_<appDb>_<yyyyMMdd_HHmmss>_before_drop.backup`, a name `restore` never picks, so running `restore` again still restores the same dump. |
| `copy` | Replaces the database with a fresh dump of `<prefix>.db.copy.source.appDb` from the copy source server, first dumping the current one, like `restore`. The copy stays in `BackupDir` as `<env>_<sourceDb>_<yyyyMMdd_HHmmss>.backup`. The local `pg_dump` must be at least as new as that server. |
| `fdw-refresh` | Re-imports the foreign tables. |
| `install` | Installs the server and the database, and the FDW when one is configured. Needs administrator rights. |
| `uninstall` | Dumps every database into `BackupDir` as `<env>_<db>_<yyyyMMdd_HHmmss>.backup`, the name `restore` picks, then removes the server, keeping its data folder. Needs administrator rights. |
| `upgrade` | Uninstalls, installs, then restores the dump the uninstall took of the database. If it stops halfway, `install` then `restore` bring the database back from that dump. Set `<prefix>.db.installer` to the new version first. Needs administrator rights. |

`restore` and `copy` drop the database `WITH (FORCE)`, disconnecting the application.
Like every drop and every uninstall, that drop is preceded by a dump into `BackupDir`,
unless the command is given `-SkipBackup`, e.g.
`.\ops\db\dba\BxFinTracker-db.ps1 restore -SkipBackup`. `upgrade` always dumps the
database it restores, once: with `-SkipBackup` it dumps only that database and skips the
dumps of the others. It drops the database the install just created without a dump, as
it holds nothing yet.

| Property | Used as |
| --- | --- |
| `<prefix>.env` | `EnvName`; required |
| `<prefix>.db.appUser`, `<prefix>.db.appPass` | the database owner and its password; required |
| `<prefix>.db.appDb` | the database; defaults to the `appUser` value |
| `<prefix>.db.superPass` | `SuperPass`; required |
| `<prefix>.db.superUser`, `.host`, `.port`, `.locale`, `.service.name` | `SuperUser`, `DbHost`, `Port`, `DbLocale`, `WinServiceName` |
| `<prefix>.db.allowedClientAddresses` | `AllowedClientAddresses`, separated by `,` or `;` |
| `<prefix>.db.installer` | `TargetVersion` |
| `<prefix>.db.fdw1.schema`, `.foreignHost`, `.foreignPort`, `.foreignDb`, `.foreignSchema`, `.foreignUser`, `.foreignPass` | the FDW, when `fdw1.schema` is set |
| `<prefix>.db.copy.source.host`, `.port`, `.superUser`, `.superPass`, `.appDb` | the server and database `copy` copies from, when `copy.source.host` is set |

Unset optional properties keep the defaults from [Configuration](#configuration).
The home folder holds `postgresql\` (the server), `install\` (installers, so
they are not downloaded again) and `db-bck\` (dumps). To put them elsewhere, set
`DbHomePath`, `DownloadPath` or `BackupDir` in `-Settings`; moving one doesn't move
the others. Relative paths are resolved against the current PowerShell folder, not
the home folder, so build them from it, e.g. `"$appHome\dumps"`. Dumps use the
`DIRECTORY` format with a parallelism of 8. `-Settings` sets or overrides any `$conf` key,
e.g. `PgServerSettings` or `Extensions`.

As in Java, `\\`, `\:` and `\=` in a property value stand for the escaped
character. `${NAME}` expands to the environment variable `NAME`.

### Typical flows

The examples use the script above with `bx.fintracker.env=Dev1` and the database
`fintracker`, and show what each step leaves in `db-bck\`. The commands marked *admin*
need PowerShell started with **Run as administrator**.

**Set up a new machine** (*admin*). Set `bx.fintracker.db.installer`, e.g. to `18.3`, then:

```powershell
.\ops\db\dba\BxFinTracker-db.ps1 install
```

**Take a backup and go back to it.** `restore` always takes the newest
`Dev1_fintracker_<timestamp>.backup`:

```powershell
.\ops\db\dba\BxFinTracker-db.ps1 backup     # Friday
.\ops\db\dba\BxFinTracker-db.ps1 restore    # Monday
```

```
db-bck\Dev1_fintracker_20261016_170000.backup              <- backup, restored on Monday
db-bck\Dev1_fintracker_20261019_090000_before_drop.backup  <- Monday's data, before restore dropped it
```

Running `restore` again restores Friday's backup again: a `_before_drop` dump is never
picked. To get Monday's data back, remove the `_before_drop` suffix from that dump's
name, making it the newest, and run `restore`. Delete it once you no longer need it.

**Refresh the database from another server.** With `bx.fintracker.db.copy.source.*`
pointing at, say, the production server and its database `fintracker`:

```powershell
.\ops\db\dba\BxFinTracker-db.ps1 copy
```

```
db-bck\Dev1_fintracker_20261020_080000.backup              <- the copy from production
db-bck\Dev1_fintracker_20261020_080200_before_drop.backup  <- the local data it replaced
```

As the source database has the same name, the copy is also what a later `restore` picks.

**Upgrade PostgreSQL** (*admin*). Set `bx.fintracker.db.installer` to the new version,
e.g. `18.4`, then:

```powershell
.\ops\db\dba\BxFinTracker-db.ps1 upgrade
```

```
db-bck\Dev1_fintracker_20261022_100000.backup  <- restored into the new server
db-bck\Dev1_postgres_20261022_100000.backup
```

The old data folder is also kept, in `postgresql\db_data_backup\db_data_<timestamp>\`.

**Recover from an upgrade that stopped halfway** (*admin*), e.g. because the new
installer could not be downloaded. The old server is gone by then, but its dumps are in
`db-bck\`. Fix the cause, then:

```powershell
.\ops\db\dba\BxFinTracker-db.ps1 install
.\ops\db\dba\BxFinTracker-db.ps1 restore -SkipBackup
```

`restore` picks `Dev1_fintracker_20261022_100000.backup`, the dump the upgrade took.
`-SkipBackup` only skips dumping the empty database `install` just created.

**Remove the server** (*admin*):

```powershell
.\ops\db\dba\BxFinTracker-db.ps1 uninstall
```

Every database is dumped first, as `Dev1_<db>_<timestamp>.backup`, so a later `install`
and `restore` bring `fintracker` back. The data folder is moved aside, not deleted.

## Tests

```powershell
.\BxDba.Tests.ps1                # unit tests, no PostgreSQL needed
.\BxDba.Tests.ps1 -Integration   # also installs, uses and removes a real server
.\BxDba.Tests.ps1 -Newest        # also downloads, installs and removes the newest release
```

The switches can be combined. The first run downloads Pester 5 into `.pester\`
next to the script. Nothing is installed machine-wide.

The integration tests need PowerShell started with **Run as administrator** and a
PostgreSQL installer in `..\test-data\install`. They use that folder as the
download folder, so nothing is downloaded. Override the defaults with
`BXDBA_TEST_DATA`, `BXDBA_TEST_INSTALLER` and `BXDBA_TEST_PORT`.

The `-Newest` test downloads the newest installer (~355 MB) on every run, so it
is left out unless asked for. It installs that release on port 5431 under
`..\test-data\newest`, checks the running version and that the download was
deleted, then removes everything again. It needs PowerShell started with
**Run as administrator** and internet access. Set `BXDBA_TEST_NEWEST_PORT` to use
another port.

## License

Apache License 2.0.
