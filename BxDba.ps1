# Copyright (c) 2026 Brinvex (dev@brinvex.com). Apache License 2.0.
#
# Brinvex Database Admin 1.1.0 - PostgreSQL administration on Windows.
# https://github.com/brinvex/brinvex-dba
#
# Copied into another project? Don't edit the copy: change the script in the
# repository above, tag a new version and copy it again.
#
#   . .\BxDba.ps1
#   $conf = @{
#       Port = 5430; SuperPass = 'S3cr3t!123'
#       EnvName = 'Dev1'; TargetVersion = '18.3'
#       AppUsers = @{ my_app1 = 'app-password' }; AppDatabases = @{ my_app1 = 'my_app1' }
#   }
#   Install-PgServer -Conf $conf
#   Backup-PgDatabase -Conf $conf -Database my_app1 -BackupPath 'C:\bck\my_app1.backup'
#
# Commands
#   Install-PgServer, Uninstall-PgServer [-SkipBackup], Restart-PgService [-OnlyIfRunning]
#   New-PgUser, New-PgDatabase, Test-PgRole, Test-PgDatabase, Remove-PgDatabase [-SkipBackup]
#   Backup-PgDatabase, Restore-PgDatabase, Backup-PgDataFolder
#   Install-PgFdw, Update-PgFdw, Invoke-Psql, Get-VCRedist
#   Import-PgDbaProperties, Invoke-PgDbaCommand   for applications configured by .properties files
#
# $conf is a plain hashtable; Resolve-PgConf lists every key with its default and
# rejects unknown keys, so a typo fails loudly. Windows PowerShell 5.1 or later.
# Install-PgServer and Uninstall-PgServer need administrator rights: start
# PowerShell by right-clicking it and choosing 'Run as administrator'.

# Must match the version in the header above; a test checks that they agree.
function Get-DbaScriptVersion { '1.1.0' }

#region Configuration

function Resolve-PgConf {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Conf)

    $c = [ordered]@{
        DbHost                   = 'localhost'
        Port                     = 5432
        SuperUser                = 'postgres'
        SuperPass                = $null
        DbHomePath               = 'C:\app\my_app1\postgresql'
        DbDataPath               = $null          # default: <DbHomePath>\db_data
        DbToolsPath              = $null          # default: <DbHomePath>\db_system\bin; psql, pg_dump, pg_restore
        BackupFormat             = 'DIRECTORY'    # PLAIN | CUSTOM_ARCHIVE | DIRECTORY
        BackupRestoreParallelism = 1
        EnvName                  = 'Dev1'
        WinServiceName           = $null          # default: <EnvName>_Postgresql
        FirewallRuleName         = $null          # default: <EnvName>_PG - open <Port>
        TargetVersion            = $null          # newest | 18.3 | 18.3-2 | postgresql-18.3-2-windows-x64
        InstallerPath            = $null          # an installer .exe, instead of TargetVersion
        DownloadPath             = $null          # default: the user's Downloads folder
        BackupDir                = $null          # default: db-bck next to DbHomePath; dumps before every drop and uninstall, and of Invoke-PgDbaCommand
        DbLocale                 = 'English_United States.UTF8'
        DbListenAddresses        = '*'
        InstallVCRedist          = $true
        AllowedClientAddresses   = @()
        PgServerSettings         = @()            # e.g. "shared_buffers = '256MB'"
        Extensions               = @()
        AppUsers                 = @{}            # role name -> password
        AppDatabases             = @{}            # database name -> owner role
    }
    foreach ($key in $Conf.Keys) {
        # Not a setting: always <DbHomePath>\db_system, but a resolved conf passed back in carries it.
        if ($key -eq 'DbSystemPath') { continue }
        if (-not $c.Contains($key)) {
            throw "Unknown conf key '$key'. Known keys: $($c.Keys -join ', ')"
        }
        if ($null -ne $Conf[$key] -and "$($Conf[$key])" -ne '') { $c[$key] = $Conf[$key] }
    }

    $c.DbHomePath = Get-FullPath $c.DbHomePath
    $c.DbSystemPath = Join-Path $c.DbHomePath 'db_system'
    # A different value would otherwise be silently ignored.
    if ($Conf['DbSystemPath'] -and (Get-FullPath $Conf['DbSystemPath']) -ne $c.DbSystemPath) {
        throw "DbSystemPath can't be set: it is always <DbHomePath>\db_system, here $($c.DbSystemPath)"
    }
    $c.DbDataPath = if ($c.DbDataPath) { Get-FullPath $c.DbDataPath } else { Join-Path $c.DbHomePath 'db_data' }
    $c.DbToolsPath = if ($c.DbToolsPath) { Get-FullPath $c.DbToolsPath } else { Join-Path $c.DbSystemPath 'bin' }
    if ($c.InstallerPath) { $c.InstallerPath = Get-FullPath $c.InstallerPath }
    $c.DownloadPath = if ($c.DownloadPath) { Get-FullPath $c.DownloadPath } else { Get-DownloadsFolder }
    $homeParent = Split-Path $c.DbHomePath -Parent
    if (-not $homeParent) { $homeParent = $c.DbHomePath }
    $c.BackupDir = if ($c.BackupDir) { Get-FullPath $c.BackupDir } else { Join-Path $homeParent 'db-bck' }

    $c.Port = [int]$c.Port
    if ($c.Port -lt 1 -or $c.Port -gt 65535) { throw "Port must be between 1 and 65535, got $($c.Port)" }
    $c.BackupFormat = "$($c.BackupFormat)".ToUpperInvariant()
    if ('PLAIN', 'CUSTOM_ARCHIVE', 'DIRECTORY' -notcontains $c.BackupFormat) {
        throw "BackupFormat must be PLAIN, CUSTOM_ARCHIVE or DIRECTORY, got '$($c.BackupFormat)'"
    }
    $c.BackupRestoreParallelism = [int]$c.BackupRestoreParallelism
    if ($c.BackupRestoreParallelism -lt 1) { throw 'BackupRestoreParallelism must be at least 1' }
    if (-not $c.WinServiceName) { $c.WinServiceName = "$($c.EnvName)_Postgresql" }
    if (-not $c.FirewallRuleName) { $c.FirewallRuleName = '{0}_PG - open {1}' -f $c.EnvName, $c.Port }
    return $c
}

function Assert-PgFdwConf {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Fdw)
    foreach ($key in 'SourceDb', 'SourceDbUser', 'SourceDbPass', 'FdwSchema', 'ForeignHost',
        'ForeignPort', 'ForeignDb', 'ForeignSchema', 'ForeignUser', 'ForeignPass') {
        if (-not $Fdw[$key]) { throw "FDW conf key '$key' is required" }
    }
    Assert-SqlIdentifier $Fdw.SourceDbUser 'source role name'
    Assert-SqlIdentifier $Fdw.FdwSchema 'FDW schema name'
    Assert-SqlIdentifier $Fdw.ForeignSchema 'foreign schema name'
}

#endregion
#region Small helpers

function Write-DbaLog([string]$Message, [switch]$Detail) {
    $line = '{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Message
    if ($Detail) { Write-Verbose $line } else { Write-Host $line }
}

# Relative paths resolve against the PowerShell location, not the process
# directory that [IO.Path]::GetFullPath would use.
function Get-FullPath([string]$Path) {
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

# UTF-8 without a BOM; PostgreSQL rejects a BOM in its configuration files.
function Write-TextFile([string]$Path, [string]$Content) {
    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

function Assert-SqlIdentifier([string]$Name, [string]$What) {
    if ($Name -notmatch '^[A-Za-z_][A-Za-z0-9_$]{0,62}$') {
        throw "Invalid $What '$Name' - expected a plain SQL identifier"
    }
}

function ConvertTo-SqlLiteral([string]$Value) { $Value.Replace("'", "''") }

function Assert-Elevated([string]$Activity) {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "$Activity needs administrator rights. Close this window, right-click PowerShell, choose 'Run as administrator' and try again."
    }
}

# <BackupDir>\<env>_<db>_<yyyyMMdd_HHmmss>.backup, the names Invoke-PgDbaCommand restore
# picks from. A -Suffix, e.g. before_drop, keeps a dump out of its reach.
function Get-DumpPath($Conf, [string]$Database, [string]$Suffix) {
    $name = '{0}_{1}_{2:yyyyMMdd_HHmmss}' -f $Conf.EnvName, $Database, (Get-Date)
    if ($Suffix) { $name += "_$Suffix" }
    return Join-Path $Conf.BackupDir "$name.backup"
}

function Get-DataBackupFolder($Conf) {
    $folder = Join-Path (Split-Path $Conf.DbDataPath -Parent) ((Split-Path $Conf.DbDataPath -Leaf) + '_backup')
    if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    return $folder
}

#endregion
#region Running native programs

# Quotes arguments per the CommandLineToArgvW rules every native Windows program
# uses to split its command line, so spaces, quotes and backslashes survive.
function ConvertTo-NativeArgLine([string[]]$ArgumentList) {
    $quoted = foreach ($arg in $ArgumentList) {
        if ($arg -and $arg -notmatch '[ \t"]') { $arg; continue }
        $sb = [Text.StringBuilder]::new('"')
        $backslashes = 0
        foreach ($ch in $arg.ToCharArray()) {
            if ($ch -eq '\') { $backslashes++; continue }
            # Backslashes are literal unless they precede a quote.
            if ($ch -eq '"') { [void]$sb.Append('\' * ($backslashes * 2 + 1)) }
            else { [void]$sb.Append('\' * $backslashes) }
            [void]$sb.Append($ch)
            $backslashes = 0
        }
        [void]$sb.Append('\' * ($backslashes * 2)).Append('"')
        $sb.ToString()
    }
    return $quoted -join ' '
}

# Runs a program and returns ExitCode, Out, Err, OutLines, ErrLines and the
# CommandLine with -Secret values masked. Out/Err hold the non-blank lines, trimmed.
function Invoke-NativeExe {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [hashtable]$Environment = @{},
        [string[]]$Secret = @()
    )
    $argLine = ConvertTo-NativeArgLine $ArgumentList
    $shown = "$FilePath $argLine"
    foreach ($s in $Secret) { if ($s) { $shown = $shown.Replace($s, '*****') } }
    Write-DbaLog "exec $shown" -Detail

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = $argLine
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    foreach ($key in $Environment.Keys) { $psi.EnvironmentVariables[$key] = [string]$Environment[$key] }

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    try {
        try { [void]$proc.Start() }
        catch { throw "Cannot start ${FilePath}: $($_.Exception.GetBaseException().Message)" }
        # Closed stdin makes a program that unexpectedly waits for input fail at
        # once instead of hanging. The base stream is closed directly because
        # closing the writer would first send a UTF-8 byte order mark.
        $proc.StandardInput.BaseStream.Close()
        # Both pipes are read at the same time: a child that fills one pipe while
        # the other is being drained would otherwise block forever.
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        $proc.WaitForExit()
        $stdOut = $outTask.Result
        $stdErr = $errTask.Result
        $exitCode = $proc.ExitCode
    }
    finally {
        $proc.Dispose()
    }
    $outLines = @($stdOut -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $errLines = @($stdErr -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    return [pscustomobject]@{
        CommandLine = $shown
        ExitCode    = $exitCode
        Out         = $outLines -join "`n"
        Err         = $errLines -join "`n"
        OutLines    = $outLines
        ErrLines    = $errLines
    }
}

function Assert-NativeSuccess {
    param($Result, [string]$Activity, [int[]]$AllowExitCode = 0)
    if ($AllowExitCode -contains $Result.ExitCode) { return }
    throw "$Activity failed (exit $($Result.ExitCode)): $($Result.CommandLine)`n  stderr: $($Result.Err)`n  stdout: $($Result.Out)"
}

# Passwords travel in PGPASSWORD, never on a command line where any process
# listing could read them.
function Invoke-PgTool($Conf, [string]$Tool, [string[]]$ArgumentList, [string]$Password, [string[]]$Secret = @()) {
    Invoke-NativeExe -FilePath (Join-Path $Conf.DbToolsPath "$Tool.exe") -ArgumentList $ArgumentList `
        -Environment @{ PGPASSWORD = $Password; PGCLIENTENCODING = 'UTF8' } -Secret (@($Password) + $Secret)
}

function Get-PgDumpArgs($Conf, [string]$Database, [string]$BackupPath) {
    $format = $Conf.BackupFormat
    $parallelism = $Conf.BackupRestoreParallelism
    if ($parallelism -ne 1 -and $format -ne 'DIRECTORY') {
        throw "Parallel dumps need the DIRECTORY format (parallelism=$parallelism, format=$format)"
    }
    $a = @()
    if ($format -eq 'CUSTOM_ARCHIVE') { $a += '-F', 'c' }
    if ($format -eq 'DIRECTORY') { $a += '-F', 'd' }
    if ($parallelism -ne 1) { $a += '-j', [string]$parallelism }
    return $a + @('-U', $Conf.SuperUser, '-h', $Conf.DbHost, '-p', [string]$Conf.Port, '-w',
        '--encoding', 'UTF-8', '--file', $BackupPath, '-d', $Database)
}

function Get-PgRestoreArgs($Conf, [string]$Database, [string]$Owner, [string]$BackupPath) {
    $a = @()
    if ($Conf.BackupRestoreParallelism -ne 1) { $a += '-j', [string]$Conf.BackupRestoreParallelism }
    return $a + @('-U', $Conf.SuperUser, '-h', $Conf.DbHost, '-p', [string]$Conf.Port, '-w',
        '-d', $Database, '--no-owner', "--role=$Owner", $BackupPath)
}

# Runs SQL through psql - by default as the superuser on the postgres database.
#   -ExpectTag      asserts the command tag psql prints, e.g. 'CREATE DATABASE'
#   -AssertSuccess  asserts success without checking the output (for queries)
#   -Secret         sends the SQL via a temp file, so a password inside it never
#                   reaches a command line, and masks it in error messages
# NOTICE/INFO/DETAIL/HINT lines on stderr count as success.
function Invoke-Psql {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Conf,
        [Parameter(Mandatory)][string]$Sql,
        [string]$Database = 'postgres',
        [string]$User,
        [string]$Password,
        [switch]$Tuples,
        [string]$ExpectTag,
        [switch]$AssertSuccess,
        [string[]]$Secret = @()
    )
    $Conf = Resolve-PgConf $Conf
    if (-not $User) { $User = $Conf.SuperUser; $Password = $Conf.SuperPass }
    $psqlArgs = @('-U', $User, '-h', $Conf.DbHost, '-p', [string]$Conf.Port, '-d', $Database, '-w')
    if ($Tuples) { $psqlArgs += '-X', '-t', '-A' }

    $scriptFile = $null
    try {
        if ($Secret.Count -gt 0) {
            $scriptFile = Join-Path ([IO.Path]::GetTempPath()) ('bxdba_{0}.sql' -f [guid]::NewGuid().ToString('N'))
            Write-TextFile $scriptFile "\set ON_ERROR_STOP on`r`n$Sql`r`n"
            $psqlArgs += '-f', $scriptFile
        }
        else {
            $psqlArgs += '-c', $Sql
        }
        $result = Invoke-PgTool -Conf $Conf -Tool psql -ArgumentList $psqlArgs -Password $Password -Secret $Secret
    }
    finally {
        if ($scriptFile) { Remove-Item -LiteralPath $scriptFile -Force -ErrorAction SilentlyContinue }
    }

    if ($ExpectTag -or $AssertSuccess) {
        $shownSql = $Sql
        foreach ($s in $Secret) { if ($s) { $shownSql = $shownSql.Replace($s, '*****') } }
        Assert-NativeSuccess $result "psql [$shownSql]"
        $realErrors = @($result.ErrLines | Where-Object { $_ -notmatch '^(psql:.*: )?(NOTICE|INFO|DETAIL|HINT):' })
        if ($realErrors.Count -gt 0 -or ($ExpectTag -and $result.Out -ne $ExpectTag)) {
            throw "psql [$shownSql] failed, expected '$ExpectTag'`n  stdout: $($result.Out)`n  stderr: $($result.Err)"
        }
    }
    return $result
}

# Makes a role SUPERUSER for the duration of -Body, and always takes it back.
function Invoke-AsSuperuser($RoleConf, [string]$Role, [scriptblock]$Body) {
    Assert-SqlIdentifier $Role 'role name'
    Invoke-Psql -Conf $RoleConf -Sql "ALTER USER $Role WITH SUPERUSER;" -ExpectTag 'ALTER ROLE' | Out-Null
    $bodySucceeded = $false
    try {
        & $Body
        $bodySucceeded = $true
    }
    finally {
        try {
            Invoke-Psql -Conf $RoleConf -Sql "ALTER USER $Role WITH NOSUPERUSER;" -ExpectTag 'ALTER ROLE' | Out-Null
        }
        catch {
            if ($bodySucceeded) { throw }
            # Don't hide the body's own error, but make the leftover privilege visible.
            Write-Warning "Could not revoke SUPERUSER from $Role - run: ALTER USER $Role WITH NOSUPERUSER; ($($_.Exception.Message))"
        }
    }
}

#endregion
#region Installer download

# EnterpriseDB publishes the PostgreSQL Windows installers under predictable names.
function Get-PgInstallerUrl([string]$FileName) { "https://get.enterprisedb.com/postgresql/$FileName" }

function Enable-Tls12 {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

# Size of a file on a web server, or $null when the server doesn't have it.
function Get-WebFileSize([string]$Url) {
    Enable-Tls12
    $request = [Net.HttpWebRequest]::Create($Url)
    $request.Method = 'HEAD'
    try {
        $response = $request.GetResponse()
        try { return $response.ContentLength } finally { $response.Close() }
    }
    catch {
        $webError = $_.Exception.GetBaseException()
        if ($webError -is [Net.WebException] -and $webError.Response -and [int]$webError.Response.StatusCode -in 403, 404) {
            return $null
        }
        throw
    }
}

function Save-WebFile([string]$Url, [string]$Path) {
    Enable-Tls12
    $client = New-Object Net.WebClient
    try { $client.DownloadFile($Url, $Path) } finally { $client.Dispose() }
}

# The PostgreSQL release list from postgresql.org: major, latestMinor, supported, ...
function Get-PgReleases {
    Enable-Tls12
    $releases = (Invoke-WebRequest -UseBasicParsing -Uri 'https://www.postgresql.org/versions.json').Content | ConvertFrom-Json
    return $releases
}

function Get-DownloadsFolder {
    $shellFolders = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -ErrorAction SilentlyContinue
    $downloads = if ($shellFolders) { $shellFolders.PSObject.Properties['{374DE290-123F-4565-9164-39C4925E467B}'] }
    if ($downloads -and $downloads.Value) { return [Environment]::ExpandEnvironmentVariables($downloads.Value) }
    return Join-Path $env:USERPROFILE 'Downloads'
}

# The highest installer build published for a version such as 18.3, or $null.
# Builds are numbered from 1 without gaps.
function Find-PgInstallerName([string]$Version) {
    $found = $null
    for ($build = 1; $build -le 50; $build++) {
        $name = "postgresql-$Version-$build-windows-x64.exe"
        if (-not (Get-WebFileSize (Get-PgInstallerUrl $name))) { break }
        $found = $name
    }
    return $found
}

# Turns TargetVersion into an installer file name, e.g. postgresql-18.3-2-windows-x64.exe.
function Resolve-PgInstallerName([string]$TargetVersion) {
    $version = $TargetVersion.Trim()
    if ($version -match '^postgresql-(\d+\.\d+(\.\d+)?-\d+)-windows-x64(\.exe)?$') {
        return "postgresql-$($Matches[1])-windows-x64.exe"
    }
    if ($version -match '^\d+\.\d+(\.\d+)?-\d+$') {
        return "postgresql-$version-windows-x64.exe"
    }
    if ($version -match '^\d+\.\d+(\.\d+)?$') {
        $name = Find-PgInstallerName $version
        if (-not $name) { throw "EnterpriseDB has no Windows x64 installer of PostgreSQL $version" }
        return $name
    }
    if ($version -eq 'newest') {
        # postgresql.org can list a release before EnterpriseDB has published its
        # installer, so step back through the minor versions until one is there.
        $supported = @(Get-PgReleases | Where-Object { $_.supported }) | Sort-Object { [version]"$($_.major).0" } -Descending
        foreach ($release in $supported) {
            for ($minor = [int]$release.latestMinor; $minor -ge 0; $minor--) {
                $name = Find-PgInstallerName "$($release.major).$minor"
                if ($name) { return $name }
            }
        }
        throw 'EnterpriseDB has no Windows x64 installer for any supported PostgreSQL release'
    }
    throw "Invalid TargetVersion '$TargetVersion' - use 'newest', '18.3', '18.3-2' or 'postgresql-18.3-2-windows-x64'"
}

# The installer runs with administrator rights, so it must carry EnterpriseDB's valid signature.
function Assert-EdbSignature([string]$Path) {
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '^CN=EnterpriseDB Corporation,') {
        throw "$Path is not signed by EnterpriseDB (signature status: $($signature.Status))"
    }
}

# Returns @{ Path; Downloaded } for the installer to extract: InstallerPath when set,
# otherwise the TargetVersion installer in DownloadPath, downloaded first if missing.
function Get-PgInstaller($Conf) {
    if ($Conf.InstallerPath -and $Conf.TargetVersion) { throw 'Set either InstallerPath or TargetVersion, not both' }
    if ($Conf.InstallerPath) {
        if (-not (Test-Path -LiteralPath $Conf.InstallerPath -PathType Leaf)) { throw "Installer not found: $($Conf.InstallerPath)" }
        return @{ Path = $Conf.InstallerPath; Downloaded = $false }
    }
    if (-not $Conf.TargetVersion) { throw 'Set InstallerPath or TargetVersion to install PostgreSQL' }

    $name = Resolve-PgInstallerName $Conf.TargetVersion
    $path = Join-Path $Conf.DownloadPath $name
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        Write-DbaLog "Using the installer already in the download folder: $path"
        try { Assert-EdbSignature $path }
        catch { throw "$($_.Exception.Message). Delete it to have a fresh copy downloaded." }
        return @{ Path = $path; Downloaded = $false }
    }

    $url = Get-PgInstallerUrl $name
    $size = Get-WebFileSize $url
    if (-not $size) { throw "Installer not available for download: $url" }
    New-Item -ItemType Directory -Path $Conf.DownloadPath -Force | Out-Null
    # Saved under a temporary name first, so an interrupted download never looks complete.
    $partial = "$path.partial"
    Write-DbaLog ('Downloading {0} ({1:n0} MB) to {2}' -f $url, ($size / 1MB), $Conf.DownloadPath)
    try {
        Save-WebFile $url $partial
        $received = (Get-Item -LiteralPath $partial).Length
        if ($received -ne $size) { throw "Download of $url is incomplete: $received of $size bytes" }
        Assert-EdbSignature $partial
        Move-Item -LiteralPath $partial -Destination $path -Force
    }
    finally {
        Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
    }
    return @{ Path = $path; Downloaded = $true }
}

#endregion
#region Install and service

function Install-PgServer {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Conf)
    $Conf = Resolve-PgConf $Conf
    Assert-Elevated 'Install-PgServer'
    if (-not $Conf.SuperPass) { throw 'SuperPass is required' }
    Write-DbaLog "Brinvex Database Admin $(Get-DbaScriptVersion): installing PostgreSQL $($Conf.DbHost):$($Conf.Port) in $($Conf.DbHomePath), service $($Conf.WinServiceName)"

    if (-not (Test-Path -LiteralPath $Conf.DbHomePath)) {
        New-Item -ItemType Directory -Path $Conf.DbHomePath -Force | Out-Null
    }

    # Binaries: extract-only, so the installer registers no service of its own.
    $installer = $null
    if (Test-Path -LiteralPath $Conf.DbSystemPath) {
        Write-DbaLog "System folder exists, skipping extraction: $($Conf.DbSystemPath)"
    }
    else {
        $installer = Get-PgInstaller $Conf
        Write-DbaLog "Extracting $($installer.Path) -> $($Conf.DbSystemPath)"
        $r = Invoke-NativeExe -FilePath $installer.Path -Secret $Conf.SuperPass -ArgumentList @(
            '--mode', 'unattended', '--enable-components', 'server,commandlinetools',
            '--disable-components', 'pgAdmin,stackbuilder', '--create_shortcuts', '0',
            '--prefix', $Conf.DbSystemPath, '--superaccount', $Conf.SuperUser,
            '--superpassword', $Conf.SuperPass, '--extract-only', '1')
        Assert-NativeSuccess $r 'PostgreSQL installer extraction'
    }

    Install-VCRedist $Conf

    # Cluster. initdb takes the superuser password only from a file.
    if (Test-Path -LiteralPath $Conf.DbDataPath) {
        Write-DbaLog "Data folder exists, skipping initdb: $($Conf.DbDataPath)"
    }
    else {
        $pwDir = Split-Path $Conf.DbDataPath -Parent
        New-Item -ItemType Directory -Path $pwDir -Force | Out-Null
        $pwFile = Join-Path $pwDir ('initdb_{0}.tmp' -f [guid]::NewGuid().ToString('N'))
        try {
            Write-TextFile $pwFile $Conf.SuperPass
            Write-DbaLog "Initializing cluster in $($Conf.DbDataPath)"
            $r = Invoke-NativeExe -FilePath (Join-Path $Conf.DbSystemPath 'bin\initdb.exe') -ArgumentList @(
                '-D', $Conf.DbDataPath, '-U', $Conf.SuperUser, '--pwfile', $pwFile,
                '--auth=scram-sha-256', "--locale=$($Conf.DbLocale)")
            Assert-NativeSuccess $r 'initdb'
        }
        finally {
            Remove-Item -LiteralPath $pwFile -Force -ErrorAction SilentlyContinue
        }
    }

    if (-not (Get-Service -Name $Conf.WinServiceName -ErrorAction SilentlyContinue)) {
        Write-DbaLog "Registering service $($Conf.WinServiceName)"
        $r = Invoke-NativeExe -FilePath (Join-Path $Conf.DbSystemPath 'bin\pg_ctl.exe') `
            -ArgumentList 'register', '-N', $Conf.WinServiceName, '-D', $Conf.DbDataPath
        Assert-NativeSuccess $r 'pg_ctl register'
    }
    Start-Service -Name $Conf.WinServiceName -ErrorAction Stop

    Update-PgConfFiles $Conf
    Restart-Service -Name $Conf.WinServiceName -Force -ErrorAction Stop

    foreach ($setting in $Conf.PgServerSettings) {
        Write-DbaLog "ALTER SYSTEM SET $setting"
        Invoke-Psql -Conf $Conf -Sql "ALTER SYSTEM SET $setting" -ExpectTag 'ALTER SYSTEM' | Out-Null
    }

    New-PgUser -Conf $Conf -Users $Conf.AppUsers
    New-PgDatabase -Conf $Conf -Databases $Conf.AppDatabases

    # Extensions are created by each database's owner, made superuser meanwhile.
    if (@($Conf.Extensions).Count -gt 0) {
        foreach ($db in @($Conf.AppDatabases.Keys)) {
            $owner = $Conf.AppDatabases[$db]
            if (-not $Conf.AppUsers.Contains($owner)) {
                throw "Cannot create extensions in '$db': owner '$owner' has no password in AppUsers"
            }
            $ownerPass = $Conf.AppUsers[$owner]
            Invoke-AsSuperuser -RoleConf $Conf -Role $owner -Body {
                foreach ($ext in $Conf.Extensions) {
                    Assert-SqlIdentifier $ext 'extension name'
                    Write-DbaLog "CREATE EXTENSION IF NOT EXISTS $ext in $db"
                    Invoke-Psql -Conf $Conf -Database $db -User $owner -Password $ownerPass `
                        -Sql "CREATE EXTENSION IF NOT EXISTS $ext;" -ExpectTag 'CREATE EXTENSION' | Out-Null
                }
            }
        }
    }

    if (-not (Get-NetFirewallRule -DisplayName $Conf.FirewallRuleName -ErrorAction SilentlyContinue)) {
        Write-DbaLog "Creating firewall rule '$($Conf.FirewallRuleName)'"
        New-NetFirewallRule -DisplayName $Conf.FirewallRuleName -Direction Inbound -Action Allow `
            -Protocol TCP -LocalPort $Conf.Port -ErrorAction Stop | Out-Null
    }

    Restart-Service -Name $Conf.WinServiceName -Force -ErrorAction Stop

    # Only a successful install removes a download; after a failure the next attempt reuses it.
    if ($installer -and $installer.Downloaded) {
        Write-DbaLog "Deleting the downloaded installer $($installer.Path)"
        Remove-Item -LiteralPath $installer.Path -Force
    }
    Write-DbaLog 'Install successful'
}

# First dumps every database into BackupDir as <env>_<db>_<timestamp>.backup, starting the
# service if it is stopped, and returns database -> dump path; nothing is changed if a dump
# fails. -SkipBackup uninstalls without the dumps. Either way the cluster data is moved
# aside by Backup-PgDataFolder, never deleted.
function Uninstall-PgServer {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Conf, [switch]$SkipBackup)
    $Conf = Resolve-PgConf $Conf
    Assert-Elevated 'Uninstall-PgServer'
    Write-DbaLog "Uninstalling PostgreSQL in $($Conf.DbHomePath), service $($Conf.WinServiceName)"
    # Like pg_ctl below, the dumps use the tools of the server being removed.
    $Conf.DbToolsPath = Join-Path $Conf.DbSystemPath 'bin'

    $service = Get-Service -Name $Conf.WinServiceName -ErrorAction SilentlyContinue
    $dumps = [ordered]@{}
    if ($SkipBackup) {
        Write-DbaLog 'Uninstalling without dumping the databases, as -SkipBackup was given'
    }
    elseif (-not $service) {
        Write-DbaLog "No service $($Conf.WinServiceName), so no databases to dump"
    }
    else {
        if (-not $Conf.SuperPass) { throw 'SuperPass is required to dump the databases before uninstalling; -SkipBackup uninstalls without the dumps' }
        if ($service.Status -ne 'Running') {
            Write-DbaLog "Starting service $($Conf.WinServiceName) to dump the databases"
            try { Start-Service -Name $Conf.WinServiceName -ErrorAction Stop }
            catch { throw "Cannot start $($Conf.WinServiceName) to dump the databases, nothing was changed: $($_.Exception.Message). -SkipBackup uninstalls without the dumps." }
        }
        # Template databases take no connections and hold nothing of the applications.
        $databases = (Invoke-Psql -Conf $Conf -Tuples -AssertSuccess `
                -Sql 'SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate ORDER BY datname').OutLines
        foreach ($db in $databases) {
            $dumps[$db] = Backup-PgDatabase -Conf $Conf -Database $db -BackupPath (Get-DumpPath $Conf $db)
        }
    }

    if ($service) {
        Stop-Service -Name $Conf.WinServiceName -Force -ErrorAction Stop
        Write-DbaLog "Unregistering service $($Conf.WinServiceName)"
        $r = Invoke-NativeExe -FilePath (Join-Path $Conf.DbSystemPath 'bin\pg_ctl.exe') `
            -ArgumentList 'unregister', '-N', $Conf.WinServiceName, '-D', $Conf.DbDataPath
        Assert-NativeSuccess $r 'pg_ctl unregister'
    }
    Backup-PgDataFolder -Conf $Conf | Out-Null
    if (Test-Path -LiteralPath $Conf.DbSystemPath) {
        Write-DbaLog "Deleting $($Conf.DbSystemPath)"
        Remove-Item -LiteralPath $Conf.DbSystemPath -Recurse -Force -ErrorAction Stop
    }
    if (Get-NetFirewallRule -DisplayName $Conf.FirewallRuleName -ErrorAction SilentlyContinue) {
        Write-DbaLog "Removing firewall rule '$($Conf.FirewallRuleName)'"
        Remove-NetFirewallRule -DisplayName $Conf.FirewallRuleName -ErrorAction Stop
    }
    Write-DbaLog 'Uninstall successful'
    return $dumps
}

function Restart-PgService {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Conf, [switch]$OnlyIfRunning)
    $Conf = Resolve-PgConf $Conf
    $service = Get-Service -Name $Conf.WinServiceName -ErrorAction SilentlyContinue
    if ($OnlyIfRunning -and (-not $service -or $service.Status -ne 'Running')) {
        Write-DbaLog "Service $($Conf.WinServiceName) is not running, nothing to restart"
        return
    }
    Write-DbaLog "Restarting service $($Conf.WinServiceName)"
    Restart-Service -Name $Conf.WinServiceName -Force -ErrorAction Stop
}

# Adds port, listen_addresses and the allowed client addresses. Idempotent.
function Update-PgConfFiles($Conf) {
    $path = Join-Path $Conf.DbDataPath 'postgresql.conf'
    $text = [IO.File]::ReadAllText($path)
    $text = Add-LineAfterAnchor $text '# - Connection Settings -' "port = $($Conf.Port)"
    $text = Add-LineAfterAnchor $text '# - Connection Settings -' "listen_addresses = '$($Conf.DbListenAddresses)'"
    Write-TextFile $path $text

    $path = Join-Path $Conf.DbDataPath 'pg_hba.conf'
    $text = [IO.File]::ReadAllText($path)
    foreach ($address in $Conf.AllowedClientAddresses) {
        $text = Add-LineAfterAnchor $text '# IPv4 local connections:' "host    all    all    $address    scram-sha-256"
    }
    Write-TextFile $path $text
}

function Add-LineAfterAnchor([string]$Content, [string]$Anchor, [string]$Line) {
    if ($Content.Contains($Line)) { return $Content }
    $index = $Content.IndexOf($Anchor)
    if ($index -lt 0) { throw "Line '$Anchor' not found in the configuration file" }
    return $Content.Insert($index + $Anchor.Length, "`r`n$Line")
}

# Returns 'Name - Version: x.y' for each installed Visual C++ redistributable.
function Get-VCRedist {
    Get-ItemProperty -ErrorAction SilentlyContinue -Path @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*') |
        Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -like '*Visual C++*' } |
        ForEach-Object {
            $version = if ($_.PSObject.Properties['DisplayVersion']) { $_.DisplayVersion }
            '{0} - Version: {1}' -f $_.DisplayName, $version
        } |
        Sort-Object
}

function Install-VCRedist($Conf) {
    $before = @(Get-VCRedist)
    Write-DbaLog ("VC++ redistributables:`n  " + ($before -join "`n  "))
    if (-not $Conf.InstallVCRedist) { Write-DbaLog 'InstallVCRedist is off, skipping'; return }

    $exe = Join-Path $Conf.DbSystemPath 'installer\vcredist_x64.exe'
    Write-DbaLog "Running $exe, this may take several minutes"
    $r = Invoke-NativeExe -FilePath $exe -ArgumentList '/install', '/quiet', '/norestart'
    # 1638: a newer version is already installed. 3010: installed, reboot required.
    Assert-NativeSuccess $r 'VC++ redistributable installation' -AllowExitCode 0, 1638, 3010
    if ($r.ExitCode -eq 3010) { Write-Warning 'VC++ redistributable installed; Windows asks for a reboot' }

    $after = @(Get-VCRedist)
    $added = @($after | Where-Object { $before -notcontains $_ })
    $removed = @($before | Where-Object { $after -notcontains $_ })
    Write-DbaLog ("Added: " + $(if ($added) { "`n  " + ($added -join "`n  ") } else { 'none' }))
    Write-DbaLog ("No longer present: " + $(if ($removed) { "`n  " + ($removed -join "`n  ") } else { 'none' }))
}

#endregion
#region Roles and databases

function Test-PgRole {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Conf, [Parameter(Mandatory)][string]$Role)
    $sql = "SELECT 1 FROM pg_roles WHERE rolname = '$(ConvertTo-SqlLiteral $Role)'"
    return (Invoke-Psql -Conf $Conf -Sql $sql -Tuples -AssertSuccess).Out -eq '1'
}

function Test-PgDatabase {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Conf, [Parameter(Mandatory)][string]$Database)
    $sql = "SELECT 1 FROM pg_database WHERE datname = '$(ConvertTo-SqlLiteral $Database)'"
    return (Invoke-Psql -Conf $Conf -Sql $sql -Tuples -AssertSuccess).Out -eq '1'
}

# -Users: role name -> password. Existing roles are left untouched.
function New-PgUser {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Conf, [System.Collections.IDictionary]$Users = @{})
    foreach ($name in @($Users.Keys)) {
        Assert-SqlIdentifier $name 'role name'
        if (Test-PgRole -Conf $Conf -Role $name) { Write-DbaLog "User exists: $name"; continue }
        Write-DbaLog "Creating user $name"
        $pass = [string]$Users[$name]
        $passLiteral = ConvertTo-SqlLiteral $pass
        Invoke-Psql -Conf $Conf -Sql "CREATE USER $name WITH PASSWORD '$passLiteral'" `
            -ExpectTag 'CREATE ROLE' -Secret $pass, $passLiteral | Out-Null
    }
}

# -Databases: database name -> owner role. Existing databases are left untouched.
function New-PgDatabase {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Conf, [System.Collections.IDictionary]$Databases = @{})
    foreach ($name in @($Databases.Keys)) {
        $owner = [string]$Databases[$name]
        Assert-SqlIdentifier $name 'database name'
        Assert-SqlIdentifier $owner 'owner role name'
        if (Test-PgDatabase -Conf $Conf -Database $name) { Write-DbaLog "Database exists: $name"; continue }
        Write-DbaLog "Creating database $name owned by $owner"
        Invoke-Psql -Conf $Conf -Sql "CREATE DATABASE $name WITH OWNER = $owner" -ExpectTag 'CREATE DATABASE' | Out-Null
    }
}

# Drops with FORCE, after dumping it into BackupDir as <env>_<db>_<timestamp>_before_drop.backup,
# which Invoke-PgDbaCommand restore never picks, and returns the dump path; nothing is dropped if the dump fails. -SkipBackup drops it
# without a dump and returns nothing.
function Remove-PgDatabase {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Conf,
        [Parameter(Mandatory)][string]$Database,
        [switch]$SkipBackup
    )
    $Conf = Resolve-PgConf $Conf
    Assert-SqlIdentifier $Database 'database name'
    $backupPath = $null
    if ($SkipBackup) {
        Write-DbaLog "Dropping $Database without a backup, as -SkipBackup was given"
    }
    else {
        $backupPath = Get-DumpPath $Conf $Database 'before_drop'
        Backup-PgDatabase -Conf $Conf -Database $Database -BackupPath $backupPath | Out-Null
    }
    Write-DbaLog "Dropping database $Database"
    Invoke-Psql -Conf $Conf -Sql "DROP DATABASE $Database WITH (FORCE);" -ExpectTag 'DROP DATABASE' | Out-Null
    return $backupPath
}

#endregion
#region Backup and restore

# Format and parallelism come from BackupFormat and BackupRestoreParallelism.
function Backup-PgDatabase {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Conf,
        [Parameter(Mandatory)][string]$Database,
        [Parameter(Mandatory)][string]$BackupPath
    )
    $Conf = Resolve-PgConf $Conf
    if (-not $Conf.SuperPass) { throw 'SuperPass is required' }
    $BackupPath = Get-FullPath $BackupPath
    $parent = Split-Path $BackupPath -Parent
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }

    Write-DbaLog "Backing up $Database to $BackupPath ($($Conf.BackupFormat), parallelism $($Conf.BackupRestoreParallelism))"
    $r = Invoke-PgTool -Conf $Conf -Tool pg_dump -Password $Conf.SuperPass `
        -ArgumentList (Get-PgDumpArgs -Conf $Conf -Database $Database -BackupPath $BackupPath)
    Assert-NativeSuccess $r "pg_dump $Database"
    # pg_dump writes to --file, so any output at all means something went wrong.
    if ($r.Out -or $r.Err) { throw "pg_dump $Database reported problems:`n  stdout: $($r.Out)`n  stderr: $($r.Err)" }
    Write-DbaLog "Backup of $Database finished: $BackupPath"
    return $BackupPath
}

# Creates the database and restores into it. Refuses an existing database.
function Restore-PgDatabase {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Conf,
        [Parameter(Mandatory)][string]$BackupPath,
        [Parameter(Mandatory)][string]$Database,
        [Parameter(Mandatory)][string]$Owner
    )
    $Conf = Resolve-PgConf $Conf
    if (-not $Conf.SuperPass) { throw 'SuperPass is required' }
    $BackupPath = Get-FullPath $BackupPath
    if (-not (Test-Path -LiteralPath $BackupPath)) { throw "Backup not found: $BackupPath" }
    if (Test-PgDatabase -Conf $Conf -Database $Database) { throw "Database already exists: $Database" }

    Write-DbaLog "Restoring $BackupPath into $Database owned by $Owner"
    New-PgDatabase -Conf $Conf -Databases @{ $Database = $Owner }
    Invoke-AsSuperuser -RoleConf $Conf -Role $Owner -Body {
        $r = Invoke-PgTool -Conf $Conf -Tool pg_restore -Password $Conf.SuperPass `
            -ArgumentList (Get-PgRestoreArgs -Conf $Conf -Database $Database -Owner $Owner -BackupPath $BackupPath)
        Assert-NativeSuccess $r "pg_restore $Database"
        if ($r.Out -or $r.Err) { throw "pg_restore $Database reported problems:`n  stdout: $($r.Out)`n  stderr: $($r.Err)" }
    }
    Write-DbaLog "Restore of $Database successful"
}

# Moves the whole data folder to <DbDataPath>_backup\<name>_<timestamp> and
# returns that path. The service must be stopped.
function Backup-PgDataFolder {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Conf)
    $Conf = Resolve-PgConf $Conf
    if (-not (Test-Path -LiteralPath $Conf.DbDataPath)) {
        Write-DbaLog "No data folder to back up: $($Conf.DbDataPath)"
        return
    }
    $target = Join-Path (Get-DataBackupFolder $Conf) ('{0}_{1:yyyyMMdd_HHmmss}' -f (Split-Path $Conf.DbDataPath -Leaf), (Get-Date))
    Write-DbaLog "Moving $($Conf.DbDataPath) to $target"
    Move-Item -LiteralPath $Conf.DbDataPath -Destination $target -ErrorAction Stop
    return $target
}

#endregion
#region Foreign data wrapper

# -Fdw keys: SourceDb, SourceDbUser, SourceDbPass, FdwSchema, ForeignHost,
# ForeignPort, ForeignDb, ForeignSchema, ForeignUser, ForeignPass.
# The foreign server is named after FdwSchema.
function Install-PgFdw {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Conf, [Parameter(Mandatory)][System.Collections.IDictionary]$Fdw)
    $Conf = Resolve-PgConf $Conf
    Assert-PgFdwConf $Fdw
    $schema = $Fdw.FdwSchema
    Write-DbaLog "Setting up FDW $($Fdw.SourceDb).$schema -> $($Fdw.ForeignHost):$($Fdw.ForeignPort)/$($Fdw.ForeignDb).$($Fdw.ForeignSchema)"

    Invoke-Psql -Conf $Conf -Database $Fdw.SourceDb -Sql 'CREATE EXTENSION IF NOT EXISTS postgres_fdw;' `
        -ExpectTag 'CREATE EXTENSION' | Out-Null
    Invoke-Psql -Conf $Conf -Database $Fdw.SourceDb -Sql "GRANT USAGE ON FOREIGN DATA WRAPPER postgres_fdw TO $($Fdw.SourceDbUser);" `
        -ExpectTag 'GRANT' | Out-Null

    $asSource = @{ Conf = $Conf; Database = $Fdw.SourceDb; User = $Fdw.SourceDbUser; Password = $Fdw.SourceDbPass }
    Invoke-Psql @asSource -ExpectTag 'CREATE SERVER' -Sql ("CREATE SERVER $schema FOREIGN DATA WRAPPER postgres_fdw " +
        "OPTIONS (host '$(ConvertTo-SqlLiteral $Fdw.ForeignHost)', dbname '$(ConvertTo-SqlLiteral $Fdw.ForeignDb)', port '$([int]$Fdw.ForeignPort)');") | Out-Null
    $passLiteral = ConvertTo-SqlLiteral $Fdw.ForeignPass
    Invoke-Psql @asSource -ExpectTag 'CREATE USER MAPPING' -Secret $Fdw.ForeignPass, $passLiteral -Sql (
        "CREATE USER MAPPING FOR $($Fdw.SourceDbUser) SERVER $schema " +
        "OPTIONS (user '$(ConvertTo-SqlLiteral $Fdw.ForeignUser)', password '$passLiteral');") | Out-Null
    Invoke-Psql @asSource -ExpectTag 'CREATE SCHEMA' -Sql "CREATE SCHEMA IF NOT EXISTS $schema;" | Out-Null
    Invoke-Psql @asSource -ExpectTag 'IMPORT FOREIGN SCHEMA' `
        -Sql "IMPORT FOREIGN SCHEMA $($Fdw.ForeignSchema) FROM SERVER $schema INTO $schema;" | Out-Null
    Write-DbaLog 'FDW setup successful'
}

# Drops and re-imports the foreign tables so they match the foreign schema again.
# Aborts before dropping anything if a view or materialized view depends on them.
function Update-PgFdw {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Conf, [Parameter(Mandatory)][System.Collections.IDictionary]$Fdw)
    $Conf = Resolve-PgConf $Conf
    Assert-PgFdwConf $Fdw
    $schema = $Fdw.FdwSchema
    $asSource = @{ Conf = $Conf; Database = $Fdw.SourceDb; User = $Fdw.SourceDbUser; Password = $Fdw.SourceDbPass }
    Write-DbaLog "Refreshing FDW $($Fdw.SourceDb).$schema"

    $dependents = Invoke-Psql @asSource -Tuples -AssertSuccess -Sql (
        "SELECT DISTINCT dep_ns.nspname || '.' || dep_obj.relname || ' (kind=' || dep_obj.relkind::text || ') depends on ' || src.relname" +
        ' FROM pg_depend d' +
        ' JOIN pg_rewrite rw ON d.objid = rw.oid' +
        ' JOIN pg_class dep_obj ON rw.ev_class = dep_obj.oid' +
        ' JOIN pg_namespace dep_ns ON dep_ns.oid = dep_obj.relnamespace' +
        ' JOIN pg_class src ON d.refobjid = src.oid' +
        ' JOIN pg_namespace src_ns ON src_ns.oid = src.relnamespace' +
        " WHERE src_ns.nspname = '$schema' AND dep_obj.relkind IN ('v', 'm')")
    if ($dependents.Out) { throw "Update-PgFdw aborted, objects depend on FDW schema '$schema':`n$($dependents.Out)" }

    $tables = (Invoke-Psql @asSource -Tuples -AssertSuccess -Sql (
            "SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace" +
            " WHERE n.nspname = '$schema' AND c.relkind = 'f' ORDER BY c.relname")).OutLines
    foreach ($table in $tables) {
        Write-DbaLog "Dropping foreign table $schema.$table"
        Invoke-Psql @asSource -ExpectTag 'DROP FOREIGN TABLE' -Sql ('DROP FOREIGN TABLE {0}."{1}";' -f $schema, $table.Replace('"', '""')) | Out-Null
    }
    Invoke-Psql @asSource -ExpectTag 'IMPORT FOREIGN SCHEMA' `
        -Sql "IMPORT FOREIGN SCHEMA $($Fdw.ForeignSchema) FROM SERVER $schema INTO $schema;" | Out-Null
    Write-DbaLog 'FDW refresh successful'
}

#endregion
#region Applications configured by .properties files

# Java .properties files, later ones overriding earlier ones. An escape stands for the
# escaped character (\\, \: and \=), and ${NAME} expands to the environment variable NAME.
function Read-PropertyFiles([string[]]$Path) {
    $props = @{}
    foreach ($file in $Path) {
        $fullPath = Get-FullPath $file
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw "Property file not found: $fullPath" }
        foreach ($line in [IO.File]::ReadAllLines($fullPath)) {
            if ($line -notmatch '^\s*([^#!\s][^=:]*?)\s*[=:]\s*(.*)$') { continue }
            $key = $Matches[1]
            $value = [regex]::Replace($Matches[2], '\\(.)', '$1')
            $props[$key] = [regex]::Replace($value, '\$\{([^}]+)\}', {
                    param($match)
                    $variable = [Environment]::GetEnvironmentVariable($match.Groups[1].Value)
                    if ($null -eq $variable) { $match.Value } else { $variable }
                })
        }
    }
    return $props
}

function Get-DbaProperty($Props, [string]$Key, [switch]$Required) {
    $value = $Props[$Key]
    if ($Required -and -not $value) { throw "$Key is not set in the property files" }
    return $value
}

# Describes an application's database for Invoke-PgDbaCommand, from the .properties
# files the application itself reads. The README lists the <KeyPrefix>.env and
# <KeyPrefix>.db.* properties used. HomePath holds postgresql\ (the server),
# install\ (installers) and db-bck\ (dumps); DbHomePath, DownloadPath and BackupDir in
# -Settings put them elsewhere. -Settings sets or overrides any $conf key, e.g.
# @{ PgServerSettings = ...; Extensions = ... }.
# Returns @{ Conf; Fdw; CopySource; KeyPrefix }. The environment, database and owner live in Conf only.
function Import-PgDbaProperties {
    param(
        [Parameter(Mandatory)][string[]]$PropertyFile,
        [Parameter(Mandatory)][string]$KeyPrefix,
        [Parameter(Mandatory)][string]$HomePath,
        [System.Collections.IDictionary]$Settings = @{}
    )
    $props = Read-PropertyFiles $PropertyFile
    $dbKey = "$KeyPrefix.db"
    $HomePath = Get-FullPath $HomePath
    $envName = Get-DbaProperty $props "$KeyPrefix.env" -Required
    $appUser = Get-DbaProperty $props "$dbKey.appUser" -Required
    $appPass = Get-DbaProperty $props "$dbKey.appPass" -Required
    $appDb = Get-DbaProperty $props "$dbKey.appDb"
    if (-not $appDb) { $appDb = $appUser }

    $conf = @{
        EnvName                  = $envName
        SuperPass                = (Get-DbaProperty $props "$dbKey.superPass" -Required)
        DbHomePath               = (Join-Path $HomePath 'postgresql')
        DownloadPath             = (Join-Path $HomePath 'install')
        # Set here rather than left to the default, so moving DbHomePath keeps the dumps in place.
        BackupDir                = (Join-Path $HomePath 'db-bck')
        AppUsers                 = @{ $appUser = $appPass }
        AppDatabases             = @{ $appDb = $appUser }
        BackupFormat             = 'DIRECTORY'
        # Measured 2024-07-18 copying a database: 1 -> 189 s, 2 -> 160 s, 4 -> 156 s, 8 -> 150 s.
        BackupRestoreParallelism = 8
    }
    # Unset optional properties leave the BxDba defaults in place.
    $optional = [ordered]@{
        DbHost = 'host'; Port = 'port'; SuperUser = 'superUser'; DbLocale = 'locale'
        WinServiceName = 'service.name'; TargetVersion = 'installer'
    }
    foreach ($confKey in $optional.Keys) {
        $value = Get-DbaProperty $props "$dbKey.$($optional[$confKey])"
        if ($value) { $conf[$confKey] = $value }
    }
    $addresses = Get-DbaProperty $props "$dbKey.allowedClientAddresses"
    if ($addresses) {
        $conf.AllowedClientAddresses = @($addresses -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
    foreach ($settingKey in $Settings.Keys) { $conf[$settingKey] = $Settings[$settingKey] }
    # Also fails now, not halfway through a command, on a misspelt -Settings key.
    $app = Get-DbaAppDatabase $conf

    $fdw = $null
    if (Get-DbaProperty $props "$dbKey.fdw1.schema") {
        # Taken from the settings, so a -Settings override of the database reaches the FDW too.
        $fdw = @{ SourceDb = $app.AppDb; SourceDbUser = $app.AppUser; SourceDbPass = $app.AppPass }
        $fdwKeys = [ordered]@{
            FdwSchema = 'schema'; ForeignHost = 'foreignHost'; ForeignPort = 'foreignPort'; ForeignDb = 'foreignDb'
            ForeignSchema = 'foreignSchema'; ForeignUser = 'foreignUser'; ForeignPass = 'foreignPass'
        }
        foreach ($fdwKey in $fdwKeys.Keys) {
            $fdw[$fdwKey] = Get-DbaProperty $props "$dbKey.fdw1.$($fdwKeys[$fdwKey])" -Required
        }
    }

    $copySource = $null
    if (Get-DbaProperty $props "$dbKey.copy.source.host") {
        $copySource = @{}
        $copyKeys = [ordered]@{ DbHost = 'host'; Port = 'port'; SuperUser = 'superUser'; SuperPass = 'superPass'; Database = 'appDb' }
        foreach ($copyKey in $copyKeys.Keys) {
            $copySource[$copyKey] = Get-DbaProperty $props "$dbKey.copy.source.$($copyKeys[$copyKey])" -Required
        }
    }

    return @{ Conf = $conf; Fdw = $fdw; CopySource = $copySource; KeyPrefix = $KeyPrefix }
}

# The database Invoke-PgDbaCommand works on: the only entry in AppDatabases.
function Get-DbaAppDatabase($Conf) {
    $c = Resolve-PgConf $Conf
    if ($c.AppDatabases.Count -ne 1) {
        throw "Invoke-PgDbaCommand needs exactly one database in AppDatabases, found $($c.AppDatabases.Count)"
    }
    $appDb = @($c.AppDatabases.Keys)[0]
    $appUser = $c.AppDatabases[$appDb]
    return @{ Conf = $c; EnvName = $c.EnvName; AppDb = $appDb; AppUser = $appUser; AppPass = $c.AppUsers[$appUser] }
}

function Backup-DbaAppDatabase($Db) {
    $app = Get-DbaAppDatabase $Db.Conf
    return Backup-PgDatabase -Conf $app.Conf -Database $app.AppDb -BackupPath (Get-DumpPath $app.Conf $app.AppDb)
}

# Restores -DumpPath, by default the newest dump Backup-DbaAppDatabase took.
function Restore-DbaAppDatabase($Db, [switch]$SkipBackup, [string]$DumpPath) {
    $app = Get-DbaAppDatabase $Db.Conf
    if (-not $DumpPath) {
        # The timestamp in the name makes the alphabetically last dump the newest.
        $pattern = '^{0}_{1}_\d{{8}}_\d{{6}}\.backup$' -f [regex]::Escape($app.EnvName), [regex]::Escape($app.AppDb)
        $dump = Get-ChildItem -LiteralPath $app.Conf.BackupDir -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match $pattern } | Sort-Object Name | Select-Object -Last 1
        if (-not $dump) { throw "No dump of $($app.AppDb) in $($app.Conf.BackupDir)" }
        $DumpPath = $dump.FullName
    }
    if (Test-PgDatabase -Conf $app.Conf -Database $app.AppDb) {
        Remove-PgDatabase -Conf $app.Conf -Database $app.AppDb -SkipBackup:$SkipBackup | Out-Null
    }
    Restore-PgDatabase -Conf $app.Conf -BackupPath $DumpPath -Database $app.AppDb -Owner $app.AppUser
}

# Uninstalls, installs and restores the database from the dump the uninstall took of it,
# so it is dumped only once. -SkipBackup skips the uninstall's dumps, but never the one
# restored: the database is then dumped on its own first. The database the install
# creates is dropped without a dump, as it holds nothing yet.
function Update-DbaAppServer($Db, [switch]$SkipBackup) {
    $app = Get-DbaAppDatabase $Db.Conf
    # Checked first, as after the uninstall it would be too late.
    if (-not (Test-PgDatabase -Conf $app.Conf -Database $app.AppDb)) {
        throw "No database $($app.AppDb) to carry over to the new server, nothing was changed"
    }
    if ($SkipBackup) {
        $dump = Backup-DbaAppDatabase $Db
        Uninstall-PgServer -Conf $Db.Conf -SkipBackup | Out-Null
    }
    else {
        $dump = (Uninstall-PgServer -Conf $Db.Conf)[$app.AppDb]
        # Restore-DbaAppDatabase would otherwise fall back to an older dump.
        if (-not $dump) { throw "The uninstall took no dump of $($app.AppDb); the dumps it took are in $($app.Conf.BackupDir)" }
    }
    Install-DbaAppServer $Db
    Restore-DbaAppDatabase $Db -DumpPath $dump -SkipBackup
}

# Replaces the application database with a fresh dump of the CopySource database, usually
# on another server. The dump stays in BackupDir as <env>_<sourceDb>_<yyyyMMdd_HHmmss>.backup.
function Copy-DbaAppDatabase($Db, [switch]$SkipBackup) {
    if (-not $Db.CopySource) { throw "copy needs $($Db.KeyPrefix).db.copy.source.* in the property files" }
    $app = Get-DbaAppDatabase $Db.Conf
    $source = $Db.CopySource
    Assert-SqlIdentifier $source.Database 'copy source database name'
    $sourceConf = [ordered]@{}
    foreach ($key in $app.Conf.Keys) { $sourceConf[$key] = $app.Conf[$key] }
    $sourceConf.DbHost = $source.DbHost
    $sourceConf.Port = $source.Port
    $sourceConf.SuperUser = $source.SuperUser
    $sourceConf.SuperPass = $source.SuperPass

    Write-DbaLog "Copying $($source.Database) from $($source.DbHost):$($source.Port) into $($app.AppDb)"
    $dump = Backup-PgDatabase -Conf $sourceConf -Database $source.Database -BackupPath (Get-DumpPath $app.Conf $source.Database)
    if (Test-PgDatabase -Conf $app.Conf -Database $app.AppDb) {
        Remove-PgDatabase -Conf $app.Conf -Database $app.AppDb -SkipBackup:$SkipBackup | Out-Null
    }
    Restore-PgDatabase -Conf $app.Conf -BackupPath $dump -Database $app.AppDb -Owner $app.AppUser
}

function Install-DbaAppServer($Db) {
    Install-PgServer -Conf $Db.Conf
    if ($Db.Fdw) { Install-PgFdw -Conf $Db.Conf -Fdw $Db.Fdw }
}

# Everyday operations on the database Import-PgDbaProperties describes:
#   backup       dump it into BackupDir as <env>_<appDb>_<yyyyMMdd_HHmmss>.backup
#   restore      replace it with the newest of those dumps
#   copy         replace it with a fresh dump of <prefix>.db.copy.source.appDb from the copy
#                source server, kept in BackupDir as <env>_<sourceDb>_<yyyyMMdd_HHmmss>.backup
#   fdw-refresh  re-import the foreign tables
#   install      install the server and the database, and the FDW when configured
#   uninstall    remove the server, keeping its data folder
#   upgrade      uninstall, install, restore the uninstall's dump of the database; set
#                <prefix>.db.installer to the new version first
# uninstall and upgrade first dump every database into BackupDir as
# <env>_<db>_<yyyyMMdd_HHmmss>.backup, so restore can pick the database up later.
# restore and copy drop the database WITH (FORCE), disconnecting its applications. Before
# that drop they dump it as <env>_<appDb>_<yyyyMMdd_HHmmss>_before_drop.backup, a name
# restore never picks. -SkipBackup skips these dumps; upgrade still dumps the database it
# restores.
function Invoke-PgDbaCommand([string]$Command, [System.Collections.IDictionary]$Db, [switch]$SkipBackup) {
    switch ($Command) {
        'backup' { Backup-DbaAppDatabase $Db | Out-Null }
        'restore' { Restore-DbaAppDatabase $Db -SkipBackup:$SkipBackup }
        'copy' { Copy-DbaAppDatabase $Db -SkipBackup:$SkipBackup }
        'fdw-refresh' {
            if (-not $Db.Fdw) { throw "fdw-refresh needs $($Db.KeyPrefix).db.fdw1.* in the property files" }
            Update-PgFdw -Conf $Db.Conf -Fdw $Db.Fdw
        }
        'install' { Install-DbaAppServer $Db }
        'uninstall' { Uninstall-PgServer -Conf $Db.Conf -SkipBackup:$SkipBackup | Out-Null }
        'upgrade' { Update-DbaAppServer $Db -SkipBackup:$SkipBackup }
        default {
            throw "Give one of these commands: backup, restore, copy, fdw-refresh, install, uninstall, upgrade (got '$Command')"
        }
    }
    # Reached only on success, so the run always ends with either this line or an error.
    Write-DbaLog "$Command finished"
}

#endregion
