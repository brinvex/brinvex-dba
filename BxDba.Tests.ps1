# Copyright (c) 2026 Brinvex (dev@brinvex.com). Apache License 2.0.
#
# Tests for BxDba.ps1.
#
#   .\BxDba.Tests.ps1                unit tests, no PostgreSQL needed
#   .\BxDba.Tests.ps1 -Integration   also installs, exercises and removes a real
#                                    server: needs PowerShell run as administrator and a
#                                    PostgreSQL installer in ..\test-data\install
#   .\BxDba.Tests.ps1 -Newest        also downloads the newest PostgreSQL (~355 MB),
#                                    installs and removes it: needs PowerShell run as
#                                    administrator and internet access
#
# The switches can be combined. The first run downloads Pester 5 into .pester\ next
# to this file; nothing is installed machine-wide.

param([switch]$Integration, [switch]$Newest)

# Started directly rather than by Invoke-Pester: get Pester, then run this file.
if ((Get-PSCallStack).Command -notcontains 'Invoke-Pester') {
    $pesterVersion = '5.9.1'
    $pesterDir = Join-Path $PSScriptRoot ".pester\Pester\$pesterVersion"
    $pesterManifest = Join-Path $pesterDir 'Pester.psd1'
    if (-not (Test-Path -LiteralPath $pesterManifest)) {
        Write-Host "Downloading Pester $pesterVersion into $pesterDir"
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $package = Join-Path ([IO.Path]::GetTempPath()) "Pester.$pesterVersion.$PID.zip"
        try {
            Invoke-WebRequest -UseBasicParsing -OutFile $package `
                -Uri "https://www.powershellgallery.com/api/v2/package/Pester/$pesterVersion"
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [IO.Compression.ZipFile]::ExtractToDirectory($package, $pesterDir)
        }
        finally {
            Remove-Item -LiteralPath $package -Force -ErrorAction SilentlyContinue
        }
    }
    Remove-Module Pester -ErrorAction SilentlyContinue
    Import-Module $pesterManifest -Force
    $config = New-PesterConfiguration
    $config.Run.Path = $PSCommandPath
    $config.Run.PassThru = $true
    $config.Output.Verbosity = 'Detailed'
    $excludedTags = @()
    if (-not $Integration) { $excludedTags += 'Integration' }
    if (-not $Newest) { $excludedTags += 'Newest' }
    if ($excludedTags.Count -gt 0) { $config.Filter.ExcludeTag = $excludedTags }
    $result = Invoke-Pester -Configuration $config
    if ($result.Result -ne 'Passed') { exit 1 }
    return
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'BxDba.ps1')

    function New-FakeResult([string]$Out = '', [string]$Err = '', [int]$ExitCode = 0) {
        [pscustomobject]@{
            CommandLine = 'fake'
            ExitCode    = $ExitCode
            Out         = $Out
            Err         = $Err
            OutLines    = @($Out -split "`n" | Where-Object { $_ })
            ErrLines    = @($Err -split "`n" | Where-Object { $_ })
        }
    }

    $fdw = @{
        SourceDb = 'db1'; SourceDbUser = 'u1'; SourceDbPass = 'p1'; FdwSchema = 'fdw1'
        ForeignHost = 'h'; ForeignPort = 5432; ForeignDb = 'db2'; ForeignSchema = 'public'
        ForeignUser = 'u2'; ForeignPass = 'p2'
    }
}

Describe 'Get-DbaScriptVersion' {
    It 'matches the version in the script header' {
        $header = (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'BxDba.ps1') -TotalCount 5) -join "`n"
        $header -match 'Brinvex Database Admin (\d+\.\d+\.\d+) ' | Should -BeTrue
        $headerVersion = $Matches[1]
        Get-DbaScriptVersion | Should -Be $headerVersion
    }
}

Describe 'ConvertTo-NativeArgLine' {
    BeforeAll {
        # CommandLineToArgvW is how psql.exe, pg_dump.exe and every other native
        # program splits its command line, so it is the authoritative check.
        if (-not ('BxDbaArgv' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class BxDbaArgv {
    [DllImport("shell32.dll", SetLastError = true)]
    static extern IntPtr CommandLineToArgvW([MarshalAs(UnmanagedType.LPWStr)] string cmdLine, out int count);
    [DllImport("kernel32.dll")]
    static extern IntPtr LocalFree(IntPtr mem);
    public static string[] Parse(string cmdLine) {
        int count;
        IntPtr argv = CommandLineToArgvW(cmdLine, out count);
        try {
            var result = new string[count];
            for (int i = 0; i < count; i++) result[i] = Marshal.PtrToStringUni(Marshal.ReadIntPtr(argv, i * IntPtr.Size));
            return result;
        } finally { LocalFree(argv); }
    }
}
'@
        }
    }

    It 'leaves plain arguments unquoted' {
        ConvertTo-NativeArgLine @('-U', 'postgres', '--auth=scram-sha-256') | Should -BeExactly '-U postgres --auth=scram-sha-256'
    }

    It 'delivers awkward arguments to a native program intact' {
        $cases = @(
            'C:\Program Files\PostgreSQL\bin'
            'English_United States.UTF8'
            ''
            'say "hi"'
            'C:\dir with space\'
            'back\\"slash'
            "CREATE USER x WITH PASSWORD 'p ""q"" \'"
            'trailing\\'
            "tab`there"
        )
        $parsed = [BxDbaArgv]::Parse('prog.exe ' + (ConvertTo-NativeArgLine $cases))
        $parsed.Count - 1 | Should -Be $cases.Count
        for ($i = 0; $i -lt $cases.Count; $i++) {
            $parsed[$i + 1] | Should -BeExactly $cases[$i]
        }
    }
}

Describe 'Invoke-NativeExe' {
    It 'captures the exit code and keeps stdout and stderr apart' {
        $r = Invoke-NativeExe -FilePath cmd.exe -ArgumentList '/c', 'echo out& echo err 1>&2& exit /b 3'
        $r.ExitCode | Should -Be 3
        $r.Out | Should -Be 'out'
        $r.Err | Should -Be 'err'
    }

    It 'does not hang when the child floods stderr' {
        $r = Invoke-NativeExe -FilePath powershell.exe -ArgumentList '-NoProfile', '-NonInteractive', '-Command',
            "[Console]::Error.Write('x' * 1MB); [Console]::Out.Write('done')"
        $r.Out | Should -Be 'done'
        $r.Err.Length | Should -Be 1MB
    }

    It 'passes environment variables to the child only' {
        $r = Invoke-NativeExe -FilePath cmd.exe -ArgumentList '/c', 'echo %BXDBA_TEST_VALUE%' `
            -Environment @{ BXDBA_TEST_VALUE = 'hello world' }
        $r.Out | Should -Be 'hello world'
        $env:BXDBA_TEST_VALUE | Should -BeNullOrEmpty
    }

    It 'closes stdin, so a program reading it finishes instead of waiting' {
        (Invoke-NativeExe -FilePath "$env:SystemRoot\System32\sort.exe").ExitCode | Should -Be 0
    }

    It 'masks secrets in the reported command line' {
        $r = Invoke-NativeExe -FilePath cmd.exe -ArgumentList '/c', 'rem', 'topsecret' -Secret 'topsecret'
        $r.CommandLine | Should -Not -Match 'topsecret'
    }

    It 'names the program it could not start' {
        { Invoke-NativeExe -FilePath 'C:\nope\missing.exe' } | Should -Throw -ExpectedMessage '*missing.exe*'
    }
}

Describe 'Resolve-PgConf' {
    It 'fills in the defaults' {
        $c = Resolve-PgConf @{}
        $c.DbHost | Should -Be 'localhost'
        $c.Port | Should -Be 5432
        $c.SuperUser | Should -Be 'postgres'
        $c.BackupFormat | Should -Be 'DIRECTORY'
        $c.BackupRestoreParallelism | Should -Be 1
        $c.EnvName | Should -Be 'Dev1'
        $c.DbLocale | Should -Be 'English_United States.UTF8'
        $c.DbListenAddresses | Should -Be '*'
        $c.InstallVCRedist | Should -BeTrue
        $c.DbHomePath | Should -Be 'C:\app\my_app1\postgresql'
        $c.TargetVersion | Should -BeNullOrEmpty
        $c.DownloadPath | Should -Be (Get-DownloadsFolder)
        $c.BackupDir | Should -Be 'C:\app\my_app1\db-bck'
    }

    It 'derives the folders from DbHomePath' {
        $c = Resolve-PgConf @{ DbHomePath = 'C:\app\pg' }
        $c.DbSystemPath | Should -Be 'C:\app\pg\db_system'
        $c.DbDataPath | Should -Be 'C:\app\pg\db_data'
        $c.DbToolsPath | Should -Be 'C:\app\pg\db_system\bin'
        $c.BackupDir | Should -Be 'C:\app\db-bck'
    }

    It 'keeps an explicit data, tools and backup folder' {
        $c = Resolve-PgConf @{ DbHomePath = 'C:\app\pg'; DbDataPath = 'D:\pgdata'; DbToolsPath = 'D:\pgbin'; BackupDir = 'D:\dumps' }
        $c.DbDataPath | Should -Be 'D:\pgdata'
        $c.DbToolsPath | Should -Be 'D:\pgbin'
        $c.BackupDir | Should -Be 'D:\dumps'
    }

    It 'derives the service and firewall rule names from EnvName and Port' {
        $c = Resolve-PgConf @{ EnvName = 'Prod1'; Port = 5430 }
        $c.WinServiceName | Should -Be 'Prod1_Postgresql'
        $c.FirewallRuleName | Should -Be 'Prod1_PG - open 5430'
    }

    It 'resolves relative paths against the current PowerShell location' {
        Push-Location $TestDrive
        try { (Resolve-PgConf @{ DbHomePath = 'pg' }).DbHomePath | Should -Be (Join-Path $TestDrive 'pg') }
        finally { Pop-Location }
    }

    It 'gives the same result when resolved twice' {
        $once = Resolve-PgConf @{ DbHomePath = 'C:\app\pg'; EnvName = 'Prod1'; Port = 5430; AppUsers = @{ a = 'b' } }
        $twice = Resolve-PgConf $once
        ($twice.Keys | ForEach-Object { "$_=$($twice[$_])" }) -join ';' |
            Should -Be (($once.Keys | ForEach-Object { "$_=$($once[$_])" }) -join ';')
    }

    It 'rejects a misspelt key' {
        { Resolve-PgConf @{ SuperPassword = 'x' } } | Should -Throw -ExpectedMessage "*Unknown conf key 'SuperPassword'*"
    }

    It 'does not offer DbSystemPath as a setting' {
        $message = $null
        try { Resolve-PgConf @{ SuperPassword = 'x' } } catch { $message = $_.Exception.Message }
        $message | Should -Match 'Known keys: '
        $message | Should -Not -Match 'DbSystemPath'
    }

    It 'rejects a DbSystemPath other than the one derived from DbHomePath' {
        { Resolve-PgConf @{ DbHomePath = 'C:\app\pg'; DbSystemPath = 'D:\sys' } } |
            Should -Throw -ExpectedMessage '*DbSystemPath can''t be set*'
        (Resolve-PgConf @{ DbHomePath = 'C:\app\pg'; DbSystemPath = 'C:\app\pg\db_system' }).DbSystemPath |
            Should -Be 'C:\app\pg\db_system'
    }

    It 'rejects an invalid <Key>' -ForEach @(
        @{ Key = 'Port'; Value = 70000 }
        @{ Key = 'BackupFormat'; Value = 'ZIP' }
        @{ Key = 'BackupRestoreParallelism'; Value = 0 }
    ) {
        { Resolve-PgConf @{ $Key = $Value } } | Should -Throw
    }
}

Describe 'Update-PgConfFiles' {
    BeforeEach {
        $conf = Resolve-PgConf @{
            DbDataPath = (Join-Path $TestDrive 'data'); Port = 5430
            AllowedClientAddresses = '192.168.0.0/16', '172.17.0.0/16'
        }
        New-Item -ItemType Directory -Path $conf.DbDataPath -Force | Out-Null
        $pgConfPath = Join-Path $conf.DbDataPath 'postgresql.conf'
        $hbaPath = Join-Path $conf.DbDataPath 'pg_hba.conf'
        # Excerpts of the files initdb writes, saved with a BOM to prove it gets removed.
        [IO.File]::WriteAllText($pgConfPath,
            "# - Connection Settings -`r`n`r`n#listen_addresses = 'localhost'`r`n#port = 5432`r`n", [Text.Encoding]::UTF8)
        [IO.File]::WriteAllText($hbaPath,
            "# IPv4 local connections:`r`nhost    all    all    127.0.0.1/32    scram-sha-256`r`n", [Text.Encoding]::UTF8)
    }

    It 'adds the port, listen address and client lines right after their anchors' {
        Update-PgConfFiles $conf
        [IO.File]::ReadAllText($pgConfPath) | Should -Match "# - Connection Settings -\r\nlisten_addresses = '\*'\r\nport = 5430\r\n"
        $hba = [IO.File]::ReadAllText($hbaPath)
        $hba | Should -Match 'host    all    all    192\.168\.0\.0/16    scram-sha-256'
        $hba | Should -Match 'host    all    all    172\.17\.0\.0/16    scram-sha-256'
        $hba | Should -Match '127\.0\.0\.1/32'
    }

    It 'changes nothing when run again' {
        Update-PgConfFiles $conf
        $first = [Convert]::ToBase64String([IO.File]::ReadAllBytes($pgConfPath) + [IO.File]::ReadAllBytes($hbaPath))
        Update-PgConfFiles $conf
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($pgConfPath) + [IO.File]::ReadAllBytes($hbaPath)) | Should -Be $first
    }

    It 'writes the files without a byte order mark' {
        Update-PgConfFiles $conf
        [IO.File]::ReadAllBytes($pgConfPath)[0] | Should -Not -Be 0xEF
        [IO.File]::ReadAllBytes($hbaPath)[0] | Should -Not -Be 0xEF
    }

    It 'fails when an anchor line is missing' {
        Write-TextFile $pgConfPath "port = 5432`r`n"
        { Update-PgConfFiles $conf } | Should -Throw -ExpectedMessage '*Connection Settings*'
    }
}

Describe 'Get-PgDumpArgs and Get-PgRestoreArgs' {
    It 'maps BackupFormat <Format> to "<Flag>"' -ForEach @(
        @{ Format = 'PLAIN'; Flag = '' }
        @{ Format = 'CUSTOM_ARCHIVE'; Flag = '-F c' }
        @{ Format = 'DIRECTORY'; Flag = '-F d' }
    ) {
        $line = (Get-PgDumpArgs -Conf (Resolve-PgConf @{ BackupFormat = $Format }) -Database db1 -BackupPath 'C:\bck\db1') -join ' '
        if ($Flag) { $line | Should -Match "^$Flag " } else { $line | Should -Not -Match '-F ' }
    }

    It 'adds -j only when parallelism is above 1' {
        (Get-PgDumpArgs -Conf (Resolve-PgConf @{}) -Database db1 -BackupPath x) -contains '-j' | Should -BeFalse
        $a = Get-PgDumpArgs -Conf (Resolve-PgConf @{ BackupRestoreParallelism = 8 }) -Database db1 -BackupPath x
        $a[[array]::IndexOf($a, '-j') + 1] | Should -Be '8'
    }

    It 'refuses a parallel dump in the <Format> format' -ForEach @(@{ Format = 'PLAIN' }, @{ Format = 'CUSTOM_ARCHIVE' }) {
        { Get-PgDumpArgs -Conf (Resolve-PgConf @{ BackupFormat = $Format; BackupRestoreParallelism = 4 }) -Database db1 -BackupPath x } |
            Should -Throw -ExpectedMessage '*DIRECTORY*'
    }

    It 'keeps the password off the command line and a path with spaces in one argument' {
        $conf = Resolve-PgConf @{ SuperPass = 'sup3r' }
        $all = @(Get-PgDumpArgs -Conf $conf -Database db1 -BackupPath 'C:\my backups\db1') +
            @(Get-PgRestoreArgs -Conf $conf -Database db1 -Owner app1 -BackupPath 'C:\my backups\db1')
        $all -join ' ' | Should -Not -Match 'sup3r'
        @($all | Where-Object { $_ -eq 'C:\my backups\db1' }).Count | Should -Be 2
    }

    It 'restores without the original ownership, as the owner role, in parallel when configured' {
        $a = Get-PgRestoreArgs -Conf (Resolve-PgConf @{ BackupRestoreParallelism = 4 }) -Database db1 -Owner app1 -BackupPath 'C:\bck\db1'
        $a | Should -Contain '--no-owner'
        $a | Should -Contain '--role=app1'
        $a[[array]::IndexOf($a, '-j') + 1] | Should -Be '4'
        $a[-1] | Should -Be 'C:\bck\db1'
    }
}

Describe 'Assert-SqlIdentifier' {
    It 'accepts <Name>' -ForEach @(@{ Name = 'my_app1' }, @{ Name = '_x' }, @{ Name = 'Tbl$1' }) {
        { Assert-SqlIdentifier $Name 'name' } | Should -Not -Throw
    }

    It 'rejects "<Name>"' -ForEach @(
        @{ Name = 'bad name' }, @{ Name = '1abc' }, @{ Name = 'x; DROP DATABASE postgres' },
        @{ Name = "x'y" }, @{ Name = '' }, @{ Name = 'a' * 64 }
    ) {
        { Assert-SqlIdentifier $Name 'name' } | Should -Throw -ExpectedMessage '*Invalid name*'
    }
}

Describe 'Invoke-Psql' {
    BeforeEach {
        $conf = @{ SuperPass = 'sup3r'; Port = 5499; DbHomePath = 'C:\pgtest' }
        Mock Invoke-NativeExe { New-FakeResult -Out 'CREATE DATABASE' }
    }

    It 'runs psql.exe as the superuser, with the password in PGPASSWORD only' {
        Invoke-Psql -Conf $conf -Sql 'SELECT 1' | Out-Null
        Should -Invoke Invoke-NativeExe -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq 'C:\pgtest\db_system\bin\psql.exe' -and
            $Environment.PGPASSWORD -eq 'sup3r' -and
            ($ArgumentList -join ' ') -eq '-U postgres -h localhost -p 5499 -d postgres -w -c SELECT 1'
        }
    }

    It 'accepts the expected tag' {
        { Invoke-Psql -Conf $conf -Sql 'CREATE DATABASE x' -ExpectTag 'CREATE DATABASE' } | Should -Not -Throw
    }

    It 'accepts a NOTICE alongside the tag, so re-runs succeed' {
        Mock Invoke-NativeExe { New-FakeResult -Out 'CREATE EXTENSION' -Err 'NOTICE:  extension "btree_gist" already exists, skipping' }
        { Invoke-Psql -Conf $conf -Sql 'CREATE EXTENSION IF NOT EXISTS btree_gist;' -ExpectTag 'CREATE EXTENSION' } | Should -Not -Throw
    }

    It 'fails on <Case>' -ForEach @(
        @{ Case = 'a different tag'; FakeOut = 'ROLLBACK'; FakeErr = ''; FakeExit = 0 }
        @{ Case = 'an ERROR on stderr'; FakeOut = 'CREATE DATABASE'; FakeErr = 'ERROR:  permission denied'; FakeExit = 0 }
        @{ Case = 'a non-zero exit code'; FakeOut = ''; FakeErr = ''; FakeExit = 1 }
    ) {
        Mock Invoke-NativeExe { New-FakeResult -Out $FakeOut -Err $FakeErr -ExitCode $FakeExit }
        { Invoke-Psql -Conf $conf -Sql 'CREATE DATABASE x' -ExpectTag 'CREATE DATABASE' } | Should -Throw
    }

    It 'sends SQL holding a secret through a temp file that is deleted afterwards' {
        Mock Invoke-NativeExe {
            $global:BxDbaSqlFile = $ArgumentList[[array]::IndexOf($ArgumentList, '-f') + 1]
            $global:BxDbaSqlText = [IO.File]::ReadAllText($global:BxDbaSqlFile)
            New-FakeResult -Out 'CREATE ROLE'
        }
        try {
            Invoke-Psql -Conf $conf -Sql "CREATE USER app1 WITH PASSWORD 'pa55'" -ExpectTag 'CREATE ROLE' -Secret 'pa55' | Out-Null
            Should -Invoke Invoke-NativeExe -Times 1 -Exactly -ParameterFilter { ($ArgumentList -join ' ') -notmatch 'pa55' }
            $global:BxDbaSqlText | Should -Match "ON_ERROR_STOP on\r\nCREATE USER app1 WITH PASSWORD 'pa55'"
            $global:BxDbaSqlFile | Should -Not -Exist
        }
        finally {
            Remove-Variable BxDbaSqlFile, BxDbaSqlText -Scope Global -ErrorAction SilentlyContinue
        }
    }

    It 'masks the secret in its error message' {
        Mock Invoke-NativeExe { New-FakeResult -Err 'ERROR:  boom' -ExitCode 1 }
        $message = $null
        try { Invoke-Psql -Conf $conf -Sql "CREATE USER app1 WITH PASSWORD 'pa55'" -ExpectTag 'CREATE ROLE' -Secret 'pa55' }
        catch { $message = $_.Exception.Message }
        $message | Should -Match 'boom'
        $message | Should -Not -Match 'pa55'
    }
}

Describe 'Invoke-AsSuperuser' {
    BeforeEach {
        $global:BxDbaSteps = [Collections.Generic.List[string]]::new()
        Mock Invoke-Psql { $global:BxDbaSteps.Add($Sql); New-FakeResult -Out 'ALTER ROLE' }
    }
    AfterEach { Remove-Variable BxDbaSteps -Scope Global -ErrorAction SilentlyContinue }

    It 'grants, runs the body, then revokes' {
        Invoke-AsSuperuser -RoleConf @{} -Role app1 -Body { $global:BxDbaSteps.Add('body') }
        $global:BxDbaSteps -join '|' | Should -Be 'ALTER USER app1 WITH SUPERUSER;|body|ALTER USER app1 WITH NOSUPERUSER;'
    }

    It 'revokes even when the body fails, and passes the failure on' {
        { Invoke-AsSuperuser -RoleConf @{} -Role app1 -Body { throw 'restore broke' } } |
            Should -Throw -ExpectedMessage '*restore broke*'
        $global:BxDbaSteps[-1] | Should -Be 'ALTER USER app1 WITH NOSUPERUSER;'
    }

    It 'fails when revoking fails after a successful body' {
        Mock Invoke-Psql { if ($Sql -match 'NOSUPERUSER') { throw 'connection lost' }; New-FakeResult -Out 'ALTER ROLE' }
        { Invoke-AsSuperuser -RoleConf @{} -Role app1 -Body { } } | Should -Throw -ExpectedMessage '*connection lost*'
    }
}

Describe 'New-PgUser and New-PgDatabase' {
    BeforeEach {
        Mock Write-DbaLog { }
        Mock Invoke-Psql { New-FakeResult }
    }

    It 'creates only missing users, passing the password as a secret' {
        Mock Test-PgRole { $Role -eq 'old_user' }
        New-PgUser -Conf @{} -Users ([ordered]@{ old_user = 'x'; new_user = "it's" })
        Should -Invoke Invoke-Psql -Times 1 -Exactly
        Should -Invoke Invoke-Psql -Times 1 -Exactly -ParameterFilter {
            $Sql -eq "CREATE USER new_user WITH PASSWORD 'it''s'" -and $Secret -contains "it's" -and $ExpectTag -eq 'CREATE ROLE'
        }
    }

    It 'creates only missing databases, each with its owner' {
        Mock Test-PgDatabase { $Database -eq 'old_db' }
        New-PgDatabase -Conf @{} -Databases ([ordered]@{ old_db = 'u1'; new_db = 'u2' })
        Should -Invoke Invoke-Psql -Times 1 -Exactly
        Should -Invoke Invoke-Psql -Times 1 -Exactly -ParameterFilter { $Sql -eq 'CREATE DATABASE new_db WITH OWNER = u2' }
    }

    It 'rejects a role name that is not a plain identifier' {
        { New-PgUser -Conf @{} -Users @{ 'bad name' = 'x' } } | Should -Throw -ExpectedMessage '*Invalid role name*'
    }
}

Describe 'Remove-PgDatabase' {
    BeforeEach {
        Mock Write-DbaLog { }
        Mock Invoke-Psql { New-FakeResult -Out 'DROP DATABASE' }
        $conf = @{ BackupDir = (Join-Path $TestDrive 'dumps') }
    }

    It 'drops nothing when the backup taken first fails' {
        Mock Backup-PgDatabase { throw 'pg_dump failed' }
        { Remove-PgDatabase -Conf $conf -Database db1 } | Should -Throw -ExpectedMessage '*pg_dump failed*'
        Should -Invoke Invoke-Psql -Times 0
    }

    It 'backs up into BackupDir by default, then drops' {
        Mock Backup-PgDatabase { $BackupPath }
        $path = Remove-PgDatabase -Conf $conf -Database db1
        $path | Should -BeLike (Join-Path $TestDrive 'dumps\db1_*.backup')
        Should -Invoke Invoke-Psql -Times 1 -Exactly -ParameterFilter { $Sql -eq 'DROP DATABASE db1 WITH (FORCE);' }
    }

    It 'drops without a dump with -SkipBackup' {
        Mock Backup-PgDatabase { $BackupPath }
        Remove-PgDatabase -Conf $conf -Database db1 -SkipBackup | Should -BeNullOrEmpty
        Should -Invoke Backup-PgDatabase -Times 0
        Should -Invoke Invoke-Psql -Times 1 -Exactly -ParameterFilter { $Sql -eq 'DROP DATABASE db1 WITH (FORCE);' }
    }
}

Describe 'Restore-PgDatabase' {
    BeforeAll {
        $backup = Join-Path $TestDrive 'db1.backup'
        New-Item -ItemType Directory -Path $backup -Force | Out-Null
    }
    BeforeEach { Mock Write-DbaLog { } }

    It 'refuses to restore over an existing database' {
        Mock Test-PgDatabase { $true }
        Mock New-PgDatabase { }
        { Restore-PgDatabase -Conf @{ SuperPass = 'x' } -BackupPath $backup -Database db1 -Owner u1 } |
            Should -Throw -ExpectedMessage '*already exists*'
        Should -Invoke New-PgDatabase -Times 0
    }

    It 'creates the database, then restores while the owner is temporarily superuser' {
        $global:BxDbaSteps = [Collections.Generic.List[string]]::new()
        Mock Test-PgDatabase { $false }
        Mock New-PgDatabase { $global:BxDbaSteps.Add('create') }
        Mock Invoke-Psql { $global:BxDbaSteps.Add($Sql); New-FakeResult -Out 'ALTER ROLE' }
        Mock Invoke-PgTool { $global:BxDbaSteps.Add($Tool); New-FakeResult }
        try {
            Restore-PgDatabase -Conf @{ SuperPass = 'x' } -BackupPath $backup -Database db1 -Owner u1
            $global:BxDbaSteps -join '|' | Should -Be 'create|ALTER USER u1 WITH SUPERUSER;|pg_restore|ALTER USER u1 WITH NOSUPERUSER;'
        }
        finally {
            Remove-Variable BxDbaSteps -Scope Global -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Install-PgFdw and Update-PgFdw' {
    BeforeEach { Mock Write-DbaLog { } }

    It 'sets up in six steps, the first two as superuser, with the foreign password as a secret' {
        Mock Invoke-Psql { New-FakeResult }
        Install-PgFdw -Conf @{} -Fdw $fdw
        Should -Invoke Invoke-Psql -Times 6 -Exactly
        Should -Invoke Invoke-Psql -Times 2 -Exactly -ParameterFilter { -not $User }
        Should -Invoke Invoke-Psql -Times 1 -Exactly -ParameterFilter {
            $Sql -like 'CREATE USER MAPPING FOR u1 SERVER fdw1 *' -and $Secret -contains 'p2' -and $User -eq 'u1'
        }
    }

    It 'aborts a refresh before dropping anything when a view depends on the FDW schema' {
        Mock Invoke-Psql { if ($Sql -match 'pg_depend') { New-FakeResult -Out 'public.v1 (kind=v) depends on t1' } else { New-FakeResult } }
        { Update-PgFdw -Conf @{} -Fdw $fdw } | Should -Throw -ExpectedMessage '*public.v1*'
        Should -Invoke Invoke-Psql -Times 0 -ParameterFilter { $Sql -match 'DROP|IMPORT' }
    }

    It 'refreshes by dropping every foreign table, then re-importing, as the source role' {
        Mock Invoke-Psql { if ($Sql -match "relkind = 'f'") { return New-FakeResult -Out "t1`nt2" }; New-FakeResult }
        Update-PgFdw -Conf @{} -Fdw $fdw
        Should -Invoke Invoke-Psql -Times 1 -Exactly -ParameterFilter { $Sql -eq 'DROP FOREIGN TABLE fdw1."t1";' }
        Should -Invoke Invoke-Psql -Times 1 -Exactly -ParameterFilter { $Sql -eq 'DROP FOREIGN TABLE fdw1."t2";' }
        Should -Invoke Invoke-Psql -Times 1 -Exactly -ParameterFilter { $Sql -eq 'IMPORT FOREIGN SCHEMA public FROM SERVER fdw1 INTO fdw1;' }
        Should -Invoke Invoke-Psql -Times 0 -ParameterFilter { $User -ne 'u1' }
    }
}

Describe 'Get-VCRedist' {
    It 'lists only Visual C++ entries, as "name - Version: x"' {
        Mock Get-ItemProperty {
            [pscustomobject]@{ DisplayName = 'Microsoft Visual C++ 2015-2022 Redistributable (x64)'; DisplayVersion = '14.40.33810.0' }
            [pscustomobject]@{ DisplayName = 'Some Other App'; DisplayVersion = '1.0' }
            [pscustomobject]@{ PSChildName = 'KeyWithoutDisplayName' }
        }
        Get-VCRedist | Should -Be 'Microsoft Visual C++ 2015-2022 Redistributable (x64) - Version: 14.40.33810.0'
    }
}

Describe 'Get-DownloadsFolder' {
    It 'uses the Downloads folder Windows has on record, expanding variables' {
        Mock Get-ItemProperty { [pscustomobject]@{ '{374DE290-123F-4565-9164-39C4925E467B}' = '%SystemDrive%\Dl' } }
        Get-DownloadsFolder | Should -Be "$env:SystemDrive\Dl"
    }

    It 'falls back to Downloads in the user profile' {
        Mock Get-ItemProperty { }
        Get-DownloadsFolder | Should -Be (Join-Path $env:USERPROFILE 'Downloads')
    }
}

Describe 'Resolve-PgInstallerName' {
    BeforeEach {
        Mock Get-WebFileSize { }
        Mock Get-PgReleases { }
    }

    It 'maps "<Version>" straight to the file name, without going online' -ForEach @(
        @{ Version = 'postgresql-18.3-2-windows-x64' }
        @{ Version = 'postgresql-18.3-2-windows-x64.exe' }
        @{ Version = '18.3-2' }
    ) {
        Resolve-PgInstallerName $Version | Should -Be 'postgresql-18.3-2-windows-x64.exe'
        Should -Invoke Get-WebFileSize -Times 0
    }

    It 'resolves 18.3 to its highest published build' {
        Mock Get-WebFileSize { if ($Url -match '-18\.3-[123]-windows') { 370MB } }
        Resolve-PgInstallerName '18.3' | Should -Be 'postgresql-18.3-3-windows-x64.exe'
    }

    It 'fails when no build of the version is published' {
        { Resolve-PgInstallerName '18.99' } | Should -Throw -ExpectedMessage '*18.99*'
    }

    It 'resolves newest to the latest release EnterpriseDB has an installer for' {
        Mock Get-PgReleases {
            [pscustomobject]@{ major = '17'; latestMinor = 11; supported = $true }
            [pscustomobject]@{ major = '18'; latestMinor = 6; supported = $true }
            [pscustomobject]@{ major = '9.6'; latestMinor = 24; supported = $false }
        }
        # In this scenario postgresql.org lists 18.6, but EnterpriseDB has only published up to 18.4.
        Mock Get-WebFileSize { if ($Url -match '-(18\.4-[12]|17\.11-1)-windows') { 370MB } }
        Resolve-PgInstallerName 'Newest' | Should -Be 'postgresql-18.4-2-windows-x64.exe'
    }

    It 'rejects "<Version>"' -ForEach @(
        @{ Version = '18' }, @{ Version = 'latest' }, @{ Version = '18.3-x' }, @{ Version = 'postgresql-18.3' }
    ) {
        { Resolve-PgInstallerName $Version } | Should -Throw -ExpectedMessage '*Invalid TargetVersion*'
    }
}

Describe 'Get-PgInstaller' {
    BeforeEach {
        Mock Write-DbaLog { }
        Mock Assert-EdbSignature { }
        Mock Get-WebFileSize { 5 }
        Mock Save-WebFile { [IO.File]::WriteAllBytes($Path, [byte[]](1..5)) }
        $downloads = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $conf = Resolve-PgConf @{ TargetVersion = '18.3-2'; DownloadPath = $downloads }
        $target = Join-Path $downloads 'postgresql-18.3-2-windows-x64.exe'
    }

    It 'requires InstallerPath or TargetVersion, but not both' {
        { Get-PgInstaller (Resolve-PgConf @{}) } | Should -Throw -ExpectedMessage '*InstallerPath or TargetVersion*'
        { Get-PgInstaller (Resolve-PgConf @{ InstallerPath = 'C:\x.exe'; TargetVersion = '18.3' }) } |
            Should -Throw -ExpectedMessage '*not both*'
    }

    It 'uses InstallerPath as given' {
        $exe = Join-Path $TestDrive 'my-installer.exe'
        Set-Content -LiteralPath $exe -Value 'x'
        $installer = Get-PgInstaller (Resolve-PgConf @{ InstallerPath = $exe })
        $installer.Path | Should -Be $exe
        $installer.Downloaded | Should -BeFalse
        Should -Invoke Save-WebFile -Times 0
    }

    It 'uses an installer already in the download folder, without downloading' {
        New-Item -ItemType Directory -Path $downloads -Force | Out-Null
        Set-Content -LiteralPath $target -Value 'x'
        $installer = Get-PgInstaller $conf
        $installer.Path | Should -Be $target
        $installer.Downloaded | Should -BeFalse
        Should -Invoke Save-WebFile -Times 0
        Should -Invoke Assert-EdbSignature -Times 1 -Exactly -ParameterFilter { $Path -eq $target }
    }

    It 'says how to recover when the installer in the download folder is not genuine' {
        New-Item -ItemType Directory -Path $downloads -Force | Out-Null
        Set-Content -LiteralPath $target -Value 'x'
        Mock Assert-EdbSignature { throw "$Path is not signed by EnterpriseDB" }
        { Get-PgInstaller $conf } | Should -Throw -ExpectedMessage '*Delete it*'
    }

    It 'downloads a missing installer, checking its size and signature before keeping it' {
        $installer = Get-PgInstaller $conf
        $installer.Path | Should -Be $target
        $installer.Downloaded | Should -BeTrue
        $target | Should -Exist
        "$target.partial" | Should -Not -Exist
        Should -Invoke Save-WebFile -Times 1 -Exactly -ParameterFilter {
            $Url -eq 'https://get.enterprisedb.com/postgresql/postgresql-18.3-2-windows-x64.exe' -and $Path -eq "$target.partial"
        }
        Should -Invoke Assert-EdbSignature -Times 1 -Exactly -ParameterFilter { $Path -eq "$target.partial" }
    }

    It 'keeps nothing when <Case>' -ForEach @(
        @{ Case = 'the download is incomplete'; FakeSize = 999; FakeSignatureError = ''; Message = '*incomplete*' }
        @{ Case = 'the download is not signed by EnterpriseDB'; FakeSize = 5; FakeSignatureError = 'not signed by EnterpriseDB'; Message = '*not signed by EnterpriseDB*' }
    ) {
        Mock Get-WebFileSize { $FakeSize }
        if ($FakeSignatureError) { Mock Assert-EdbSignature { throw $FakeSignatureError } }
        { Get-PgInstaller $conf } | Should -Throw -ExpectedMessage $Message
        @(Get-ChildItem -LiteralPath $downloads -Force).Count | Should -Be 0
    }

    It 'fails when EnterpriseDB does not publish that installer' {
        Mock Get-WebFileSize { }
        { Get-PgInstaller $conf } | Should -Throw -ExpectedMessage '*not available*'
    }
}

Describe 'Assert-EdbSignature' {
    It 'rejects a file without a signature' {
        $file = Join-Path $TestDrive 'unsigned.exe'
        Set-Content -LiteralPath $file -Value 'not a program'
        { Assert-EdbSignature $file } | Should -Throw -ExpectedMessage '*not signed by EnterpriseDB*'
    }

    It 'rejects a validly signed program from another publisher' {
        { Assert-EdbSignature "$env:SystemRoot\System32\cmd.exe" } | Should -Throw -ExpectedMessage '*not signed by EnterpriseDB*'
    }

    It 'accepts a genuine EnterpriseDB installer' {
        $exe = Get-ChildItem -Path (Join-Path $PSScriptRoot '..\test-data\install') -Filter 'postgresql-*.exe' -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if (-not $exe) { Set-ItResult -Skipped -Because 'there is no PostgreSQL installer in ..\test-data\install' }
        { Assert-EdbSignature $exe.FullName } | Should -Not -Throw
    }
}

Describe 'Install-PgServer and Uninstall-PgServer' {
    BeforeEach {
        Mock Write-DbaLog { }
        Mock Assert-Elevated { }
        Mock Install-VCRedist { }
        Mock Invoke-NativeExe { New-FakeResult }
        Mock Get-Service { [pscustomobject]@{ Status = 'Running' } }
        Mock Start-Service { }
        Mock Restart-Service { }
        Mock Update-PgConfFiles { }
        Mock New-PgUser { }
        Mock New-PgDatabase { }
        Mock Get-NetFirewallRule { 'rule exists' }
        # Not called $installer: Install-PgServer has a variable of that name, and the
        # Get-PgInstaller mocks below would read that one instead of this.
        $fakeInstaller = Join-Path $TestDrive 'postgresql-18.3-2-windows-x64.exe'
        Set-Content -LiteralPath $fakeInstaller -Value 'x'
        $conf = @{ SuperPass = 'x'; DbHomePath = (Join-Path $TestDrive 'pg'); TargetVersion = '18.3-2'; DownloadPath = $TestDrive }
    }

    It 'deletes it after a successful install' {
        Mock Get-PgInstaller { @{ Path = $fakeInstaller; Downloaded = $true } }
        Install-PgServer -Conf $conf
        $fakeInstaller | Should -Not -Exist
    }

    It 'keeps it when the install fails, so the next attempt needs no download' {
        Mock Get-PgInstaller { @{ Path = $fakeInstaller; Downloaded = $true } }
        Mock Update-PgConfFiles { throw 'boom' }
        { Install-PgServer -Conf $conf } | Should -Throw -ExpectedMessage '*boom*'
        $fakeInstaller | Should -Exist
    }

    It 'never deletes an installer it did not download' {
        Mock Get-PgInstaller { @{ Path = $fakeInstaller; Downloaded = $false } }
        Install-PgServer -Conf $conf
        $fakeInstaller | Should -Exist
    }

    It 'runs initdb and pg_ctl from the server it installs, not from DbToolsPath' {
        Mock Get-PgInstaller { @{ Path = $fakeInstaller; Downloaded = $false } }
        Mock Get-Service { }
        $conf.DbToolsPath = 'D:\client\bin'
        Install-PgServer -Conf $conf
        Should -Invoke Invoke-NativeExe -Times 1 -Exactly -ParameterFilter { $FilePath -eq (Join-Path $TestDrive 'pg\db_system\bin\initdb.exe') }
        Should -Invoke Invoke-NativeExe -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq (Join-Path $TestDrive 'pg\db_system\bin\pg_ctl.exe') -and $ArgumentList[0] -eq 'register'
        }
        Should -Invoke Invoke-NativeExe -Times 0 -ParameterFilter { $FilePath -like 'D:\client\bin\*' }
    }

    It 'unregisters the service with pg_ctl from the installed server, not from DbToolsPath' {
        Mock Stop-Service { }
        Mock Backup-PgDataFolder { }
        Mock Remove-NetFirewallRule { }
        $conf.DbToolsPath = 'D:\client\bin'
        Uninstall-PgServer -Conf $conf
        Should -Invoke Invoke-NativeExe -Times 1 -Exactly -ParameterFilter {
            $FilePath -eq (Join-Path $TestDrive 'pg\db_system\bin\pg_ctl.exe') -and $ArgumentList[0] -eq 'unregister'
        }
    }
}

Describe 'Read-PropertyFiles' {
    BeforeAll {
        $defaults = Join-Path $TestDrive 'app-default.properties'
        $overrides = Join-Path $TestDrive 'app.properties'
        Set-Content -LiteralPath $defaults -Value @(
            '# comment'
            '! also a comment'
            ''
            'bx.app.db.port=5432'
            'bx.app.db.host = localhost'
            'bx.app.db.locale:English_United States.UTF8'
            'bx.app.db.installer=postgresql-18.3-2-windows-x64.exe'
        )
        Set-Content -LiteralPath $overrides -Value @(
            'bx.app.db.port=5452'
            'bx.app.db.superPass=a\=b\:c\\d'
            'bx.app.dir=${BXDBA_TEST_HOME}/data'
            'bx.app.other=${BXDBA_NO_SUCH_VARIABLE}'
        )
    }

    It 'lets later files override earlier ones' {
        $props = Read-PropertyFiles $defaults, $overrides
        $props['bx.app.db.port'] | Should -Be '5452'
        $props['bx.app.db.installer'] | Should -Be 'postgresql-18.3-2-windows-x64.exe'
    }

    It 'accepts = and : with spaces around them, and skips comments and blank lines' {
        $props = Read-PropertyFiles $defaults
        $props['bx.app.db.host'] | Should -Be 'localhost'
        $props['bx.app.db.locale'] | Should -Be 'English_United States.UTF8'
        $props.Count | Should -Be 4
    }

    It 'turns an escape into the escaped character' {
        (Read-PropertyFiles $overrides)['bx.app.db.superPass'] | Should -BeExactly 'a=b:c\d'
    }

    It 'expands ${NAME} from the environment, leaving unknown names as they are' {
        $env:BXDBA_TEST_HOME = 'C:\app1'
        try {
            $props = Read-PropertyFiles $overrides
            $props['bx.app.dir'] | Should -Be 'C:\app1/data'
            $props['bx.app.other'] | Should -Be '${BXDBA_NO_SUCH_VARIABLE}'
        }
        finally {
            Remove-Item Env:\BXDBA_TEST_HOME
        }
    }

    It 'names a missing file' {
        { Read-PropertyFiles (Join-Path $TestDrive 'missing.properties') } | Should -Throw -ExpectedMessage '*missing.properties*'
    }
}

Describe 'Import-PgDbaProperties' {
    BeforeAll {
        function Import-TestProperties([string[]]$Lines, $Settings = @{}) {
            Set-Content -LiteralPath $propsFile -Value $Lines
            Import-PgDbaProperties -PropertyFile $propsFile -KeyPrefix 'bx.app' -HomePath $appHome -Settings $Settings
        }
    }

    BeforeEach {
        $appHome = Join-Path $TestDrive 'app-home'
        $propsFile = Join-Path $TestDrive ('app-{0}.properties' -f [guid]::NewGuid().ToString('N'))
        $baseLines = @(
            'bx.app.env=App1_dev'
            'bx.app.db.host=127.0.0.1'
            'bx.app.db.port=5452'
            'bx.app.db.appDb=app1_dev'
            'bx.app.db.appUser=app1_user'
            'bx.app.db.appPass=app-pw'
            'bx.app.db.superUser=postgres'
            'bx.app.db.superPass=super-pw'
            'bx.app.db.locale=English_United States.UTF8'
            'bx.app.db.allowedClientAddresses=192.168.0.0/16; 172.17.0.0/16'
            'bx.app.db.service.name=App1_Postgres'
            'bx.app.db.installer=postgresql-18.6-3-windows-x64.exe'
        )
    }

    It 'maps the properties to the database settings, with the home folder layout' {
        $db = Import-TestProperties $baseLines
        $c = Resolve-PgConf $db.Conf
        $c.EnvName | Should -Be 'App1_dev'
        $c.WinServiceName | Should -Be 'App1_Postgres'
        $c.FirewallRuleName | Should -Be 'App1_dev_PG - open 5452'
        $c.DbHost | Should -Be '127.0.0.1'
        $c.Port | Should -Be 5452
        $c.SuperUser | Should -Be 'postgres'
        $c.SuperPass | Should -Be 'super-pw'
        $c.DbLocale | Should -Be 'English_United States.UTF8'
        $c.TargetVersion | Should -Be 'postgresql-18.6-3-windows-x64.exe'
        $c.AllowedClientAddresses -join ',' | Should -Be '192.168.0.0/16,172.17.0.0/16'
        $c.DbHomePath | Should -Be (Join-Path $appHome 'postgresql')
        $c.DownloadPath | Should -Be (Join-Path $appHome 'install')
        $c.AppUsers['app1_user'] | Should -Be 'app-pw'
        $c.AppDatabases['app1_dev'] | Should -Be 'app1_user'
        $c.BackupFormat | Should -Be 'DIRECTORY'
        $c.BackupRestoreParallelism | Should -Be 8
        $c.BackupDir | Should -Be (Join-Path $appHome 'db-bck')
        ($db.Keys | Sort-Object) -join ',' | Should -Be 'Conf,CopySource,Fdw,KeyPrefix'
        $db.Fdw | Should -BeNullOrEmpty
        $db.CopySource | Should -BeNullOrEmpty
    }

    It 'leaves unset optional properties to the BxDba defaults' {
        $db = Import-TestProperties ($baseLines | Where-Object { $_ -notmatch '\.(host|port|superUser|locale|service\.name|allowedClientAddresses|installer)=' })
        $c = Resolve-PgConf $db.Conf
        $c.DbHost | Should -Be 'localhost'
        $c.Port | Should -Be 5432
        $c.SuperUser | Should -Be 'postgres'
        $c.WinServiceName | Should -Be 'App1_dev_Postgresql'
        $c.TargetVersion | Should -BeNullOrEmpty
        @($c.AllowedClientAddresses).Count | Should -Be 0
    }

    It 'uses the user name as the database name when appDb is not set' {
        $db = Import-TestProperties ($baseLines | Where-Object { $_ -notmatch '\.appDb=' })
        $db.Conf.AppDatabases.Keys | Should -Be 'app1_user'
    }

    It 'names the required property that is missing: <Key>' -ForEach @(
        @{ Key = 'bx.app.env' }, @{ Key = 'bx.app.db.appUser' }, @{ Key = 'bx.app.db.appPass' }, @{ Key = 'bx.app.db.superPass' }
    ) {
        $keyToDrop = $Key
        { Import-TestProperties ($baseLines | Where-Object { -not $_.StartsWith("$keyToDrop=") }) } |
            Should -Throw -ExpectedMessage "*$Key is not set*"
    }

    It 'describes the FDW when fdw1 is configured' {
        $db = Import-TestProperties ($baseLines + @(
                'bx.app.db.fdw1.schema=md_fdw'
                'bx.app.db.fdw1.foreignHost=10.0.0.5'
                'bx.app.db.fdw1.foreignPort=5432'
                'bx.app.db.fdw1.foreignDb=md_dev'
                'bx.app.db.fdw1.foreignSchema=public'
                'bx.app.db.fdw1.foreignUser=md_user'
                'bx.app.db.fdw1.foreignPass=md-pw'))
        $db.Fdw.SourceDb | Should -Be 'app1_dev'
        $db.Fdw.SourceDbUser | Should -Be 'app1_user'
        $db.Fdw.SourceDbPass | Should -Be 'app-pw'
        $db.Fdw.FdwSchema | Should -Be 'md_fdw'
        $db.Fdw.ForeignHost | Should -Be '10.0.0.5'
        $db.Fdw.ForeignDb | Should -Be 'md_dev'
        $db.Fdw.ForeignPass | Should -Be 'md-pw'
        { Assert-PgFdwConf $db.Fdw } | Should -Not -Throw
    }

    It 'requires the whole FDW once fdw1.schema is set' {
        { Import-TestProperties ($baseLines + 'bx.app.db.fdw1.schema=md_fdw') } |
            Should -Throw -ExpectedMessage '*bx.app.db.fdw1.foreignHost is not set*'
    }

    It 'describes the copy source when copy.source.host is set' {
        $db = Import-TestProperties ($baseLines + @(
                'bx.app.db.copy.source.host=192.168.10.12'
                'bx.app.db.copy.source.port=5433'
                'bx.app.db.copy.source.superUser=postgres'
                'bx.app.db.copy.source.superPass=src-pw'
                'bx.app.db.copy.source.appDb=app1_prod'))
        $db.CopySource.DbHost | Should -Be '192.168.10.12'
        $db.CopySource.Port | Should -Be '5433'
        $db.CopySource.SuperUser | Should -Be 'postgres'
        $db.CopySource.SuperPass | Should -Be 'src-pw'
        $db.CopySource.Database | Should -Be 'app1_prod'
    }

    It 'requires the whole copy source once copy.source.host is set' {
        { Import-TestProperties ($baseLines + 'bx.app.db.copy.source.host=192.168.10.12') } |
            Should -Throw -ExpectedMessage '*bx.app.db.copy.source.port is not set*'
    }

    It 'takes the FDW source from the settings, after -Settings is applied' {
        $db = Import-TestProperties ($baseLines + @(
                'bx.app.db.fdw1.schema=md_fdw'
                'bx.app.db.fdw1.foreignHost=10.0.0.5'
                'bx.app.db.fdw1.foreignPort=5432'
                'bx.app.db.fdw1.foreignDb=md_dev'
                'bx.app.db.fdw1.foreignSchema=public'
                'bx.app.db.fdw1.foreignUser=md_user'
                'bx.app.db.fdw1.foreignPass=md-pw')) @{ AppDatabases = @{ app1_copy = 'app1_user' } }
        $db.Fdw.SourceDb | Should -Be 'app1_copy'
        $db.Fdw.SourceDbUser | Should -Be 'app1_user'
        $db.Fdw.SourceDbPass | Should -Be 'app-pw'
    }

    It 'needs exactly one application database' {
        { Import-TestProperties $baseLines @{ AppDatabases = @{ a = 'app1_user'; b = 'app1_user' } } } |
            Should -Throw -ExpectedMessage '*exactly one database in AppDatabases, found 2*'
    }

    It 'applies -Settings over the properties' {
        $db = Import-TestProperties $baseLines @{ PgServerSettings = @("work_mem = '8MB'"); Extensions = @('btree_gist'); Port = 6000 }
        $c = Resolve-PgConf $db.Conf
        $c.PgServerSettings | Should -Be "work_mem = '8MB'"
        $c.Extensions | Should -Be 'btree_gist'
        $c.Port | Should -Be 6000
    }

    It 'rejects a misspelt -Settings key straight away' {
        { Import-TestProperties $baseLines @{ PgServerSetting = @() } } | Should -Throw -ExpectedMessage "*Unknown conf key 'PgServerSetting'*"
    }

    It 'moves each home folder independently through -Settings' {
        $db = Import-TestProperties $baseLines @{ BackupDir = 'D:\dumps' }
        $c = Resolve-PgConf $db.Conf
        $c.BackupDir | Should -Be 'D:\dumps'
        $c.DownloadPath | Should -Be (Join-Path $appHome 'install')

        $db = Import-TestProperties $baseLines @{ DbHomePath = (Join-Path $appHome 'servers\pg18') }
        $c = Resolve-PgConf $db.Conf
        $c.DbDataPath | Should -Be (Join-Path $appHome 'servers\pg18\db_data')
        $c.BackupDir | Should -Be (Join-Path $appHome 'db-bck')
    }

    It 'resolves a relative BackupDir against the current folder' {
        Push-Location $TestDrive
        try {
            $db = Import-TestProperties $baseLines @{ BackupDir = 'dumps' }
            (Resolve-PgConf $db.Conf).BackupDir | Should -Be (Join-Path $TestDrive 'dumps')
        }
        finally {
            Pop-Location
        }
    }
}

Describe 'Invoke-PgDbaCommand' {
    BeforeEach {
        Mock Write-DbaLog { }
        $global:BxDbaSteps = [Collections.Generic.List[string]]::new()
        Mock Backup-PgDatabase {
            $global:BxDbaSteps.Add("backup $Database")
            New-Item -ItemType Directory -Path $BackupPath -Force | Out-Null
            $BackupPath
        }
        Mock Test-PgDatabase { $true }
        Mock Remove-PgDatabase { $global:BxDbaSteps.Add("drop $Database skipBackup=$([bool]$SkipBackup)") }
        Mock Restore-PgDatabase { $global:BxDbaSteps.Add("restore $Database from $(Split-Path $BackupPath -Leaf) as $Owner") }
        Mock Install-PgServer { $global:BxDbaSteps.Add('install server') }
        Mock Install-PgFdw { $global:BxDbaSteps.Add('install fdw') }
        Mock Uninstall-PgServer { $global:BxDbaSteps.Add('uninstall server') }
        Mock Update-PgFdw { $global:BxDbaSteps.Add('refresh fdw') }
        $backupDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $backupDir | Out-Null
        $appDbSetup = @{
            Conf      = @{
                SuperPass = 'x'; BackupDir = $backupDir; EnvName = 'App1_dev'
                AppUsers = @{ app1_user = 'app-pw' }; AppDatabases = @{ app1_dev = 'app1_user' }
            }
            Fdw       = $null
            KeyPrefix = 'bx.app'
        }
    }

    AfterEach {
        Remove-Variable BxDbaSteps -Scope Global -ErrorAction SilentlyContinue
    }

    It 'backup dumps the database into the backup folder under a timestamped name' {
        Invoke-PgDbaCommand backup $appDbSetup
        Should -Invoke Backup-PgDatabase -Times 1 -Exactly -ParameterFilter {
            $Database -eq 'app1_dev' -and
            (Split-Path $BackupPath -Parent) -eq $backupDir -and
            (Split-Path $BackupPath -Leaf) -match '^App1_dev_app1_dev_\d{8}_\d{6}\.backup$'
        }
    }

    It 'takes the environment, database and owner from the settings, so overrides reach dumps and restores' {
        $appDbSetup.Conf.EnvName = 'App1_test'
        $appDbSetup.Conf.AppDatabases = @{ app1_copy = 'app1_owner' }
        Invoke-PgDbaCommand backup $appDbSetup
        Should -Invoke Backup-PgDatabase -Times 1 -Exactly -ParameterFilter {
            $Database -eq 'app1_copy' -and (Split-Path $BackupPath -Leaf) -match '^App1_test_app1_copy_\d{8}_\d{6}\.backup$'
        }
        $global:BxDbaSteps.Clear()
        Invoke-PgDbaCommand restore $appDbSetup
        $global:BxDbaSteps -join ' | ' |
            Should -Match '^drop app1_copy skipBackup=False \| restore app1_copy from App1_test_app1_copy_\d{8}_\d{6}\.backup as app1_owner$'
    }

    It 'refuses to guess between several application databases' {
        $appDbSetup.Conf.AppDatabases = @{ a = 'app1_user'; b = 'app1_user' }
        { Invoke-PgDbaCommand backup $appDbSetup } | Should -Throw -ExpectedMessage '*exactly one database in AppDatabases*'
        Should -Invoke Backup-PgDatabase -Times 0
    }

    It 'restore replaces the database with its newest dump, dumping the current database first' {
        foreach ($name in 'App1_dev_app1_dev_20260101_120000.backup', 'App1_dev_app1_dev_20260301_080000.backup',
            'App1_dev_app1_dev_old_20261231_000000.backup', 'Other_dev_app1_dev_20261231_000000.backup') {
            New-Item -ItemType Directory -Path (Join-Path $backupDir $name) | Out-Null
        }
        Invoke-PgDbaCommand restore $appDbSetup
        $global:BxDbaSteps -join ' | ' |
            Should -Be 'drop app1_dev skipBackup=False | restore app1_dev from App1_dev_app1_dev_20260301_080000.backup as app1_user'
    }

    It 'restore skips the drop when the database does not exist' {
        New-Item -ItemType Directory -Path (Join-Path $backupDir 'App1_dev_app1_dev_20260101_120000.backup') | Out-Null
        Mock Test-PgDatabase { $false }
        Invoke-PgDbaCommand restore $appDbSetup
        Should -Invoke Remove-PgDatabase -Times 0
        Should -Invoke Restore-PgDatabase -Times 1 -Exactly
    }

    It 'restore fails, dropping nothing, when there is no dump' {
        { Invoke-PgDbaCommand restore $appDbSetup } | Should -Throw -ExpectedMessage '*No dump of app1_dev*'
        Should -Invoke Remove-PgDatabase -Times 0
    }

    It 'copy dumps the database from the copy source server, then replaces the local database with it' {
        $appDbSetup.CopySource = @{ DbHost = '10.0.0.9'; Port = '5433'; SuperUser = 'src_su'; SuperPass = 'src-pw'; Database = 'app1_prod' }
        Invoke-PgDbaCommand copy $appDbSetup
        Should -Invoke Backup-PgDatabase -Times 1 -Exactly -ParameterFilter {
            $Database -eq 'app1_prod' -and $Conf.DbHost -eq '10.0.0.9' -and "$($Conf.Port)" -eq '5433' -and
            $Conf.SuperUser -eq 'src_su' -and $Conf.SuperPass -eq 'src-pw' -and
            (Split-Path $BackupPath -Parent) -eq $backupDir -and
            (Split-Path $BackupPath -Leaf) -match '^App1_dev_app1_prod_\d{8}_\d{6}\.backup$'
        }
        $global:BxDbaSteps -join ' | ' |
            Should -Match '^backup app1_prod \| drop app1_dev skipBackup=False \| restore app1_dev from App1_dev_app1_prod_\d{8}_\d{6}\.backup as app1_user$'
        Should -Invoke Remove-PgDatabase -Times 1 -Exactly -ParameterFilter { $Conf.DbHost -eq 'localhost' -and $Conf.SuperPass -eq 'x' }
        Should -Invoke Restore-PgDatabase -Times 1 -Exactly -ParameterFilter { $Conf.DbHost -eq 'localhost' -and $Conf.SuperPass -eq 'x' }
    }

    It 'copy passes -SkipBackup to the drop, and says what is missing without a copy source' {
        { Invoke-PgDbaCommand copy $appDbSetup } | Should -Throw -ExpectedMessage '*bx.app.db.copy.source.*'
        Should -Invoke Backup-PgDatabase -Times 0
        $appDbSetup.CopySource = @{ DbHost = '10.0.0.9'; Port = '5433'; SuperUser = 'src_su'; SuperPass = 'src-pw'; Database = 'app1_prod' }
        Invoke-PgDbaCommand copy $appDbSetup -SkipBackup
        $global:BxDbaSteps[1] | Should -Be 'drop app1_dev skipBackup=True'
    }

    It 'install sets up the FDW only when one is configured' {
        Invoke-PgDbaCommand install $appDbSetup
        $appDbSetup.Fdw = $fdw
        Invoke-PgDbaCommand install $appDbSetup
        $global:BxDbaSteps -join ' | ' | Should -Be 'install server | install server | install fdw'
    }

    It 'upgrade backs up, reinstalls and restores the dump it just took, dumping before the drop as well' {
        New-Item -ItemType Directory -Path (Join-Path $backupDir 'App1_dev_app1_dev_20200101_000000.backup') | Out-Null
        $appDbSetup.Fdw = $fdw
        Invoke-PgDbaCommand upgrade $appDbSetup
        $steps = @($global:BxDbaSteps)
        $steps.Count | Should -Be 6
        $steps[0..4] -join ' | ' | Should -Be 'backup app1_dev | uninstall server | install server | install fdw | drop app1_dev skipBackup=False'
        $steps[5] | Should -Match '^restore app1_dev from App1_dev_app1_dev_\d{8}_\d{6}\.backup as app1_user$'
        $steps[5] | Should -Not -Match '20200101'
    }

    It 'fdw-refresh re-imports the foreign tables, and says what is missing without an FDW' {
        { Invoke-PgDbaCommand fdw-refresh $appDbSetup } | Should -Throw -ExpectedMessage '*bx.app.db.fdw1.*'
        $appDbSetup.Fdw = $fdw
        Invoke-PgDbaCommand fdw-refresh $appDbSetup
        Should -Invoke Update-PgFdw -Times 1 -Exactly
    }

    It 'uninstall removes the server' {
        Invoke-PgDbaCommand uninstall $appDbSetup
        Should -Invoke Uninstall-PgServer -Times 1 -Exactly
    }

    It 'passes -SkipBackup to the drop in restore and upgrade, while upgrade still takes the dump it restores' {
        New-Item -ItemType Directory -Path (Join-Path $backupDir 'App1_dev_app1_dev_20200101_000000.backup') | Out-Null
        Invoke-PgDbaCommand restore $appDbSetup -SkipBackup
        Invoke-PgDbaCommand upgrade $appDbSetup -SkipBackup
        $steps = @($global:BxDbaSteps)
        $steps[2] | Should -Be 'backup app1_dev'
        @($steps | Where-Object { $_ -like 'drop *' }) -join ' | ' | Should -Be 'drop app1_dev skipBackup=True | drop app1_dev skipBackup=True'
    }

    It 'says when a command has finished, but not when it failed' {
        Invoke-PgDbaCommand backup $appDbSetup
        Should -Invoke Write-DbaLog -Times 1 -Exactly -ParameterFilter { $Message -eq 'backup finished' }

        Mock Uninstall-PgServer { throw 'boom' }
        { Invoke-PgDbaCommand uninstall $appDbSetup } | Should -Throw -ExpectedMessage '*boom*'
        Should -Invoke Write-DbaLog -Times 0 -ParameterFilter { $Message -eq 'uninstall finished' }
    }

    It 'lists the commands when given "<Given>"' -ForEach @(@{ Given = '' }, @{ Given = 'drop-everything' }) {
        { Invoke-PgDbaCommand $Given $appDbSetup } |
            Should -Throw -ExpectedMessage '*backup, restore, copy, fdw-refresh, install, uninstall, upgrade*'
    }
}

BeforeDiscovery {
    $dataPath = if ($env:BXDBA_TEST_DATA) { $env:BXDBA_TEST_DATA } else { [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\test-data')) }
    $installer = $env:BXDBA_TEST_INSTALLER
    if (-not $installer) {
        $installer = Get-ChildItem -Path (Join-Path $dataPath 'install') -Filter 'postgresql-*.exe' -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending | Select-Object -First 1 -ExpandProperty FullName
    }
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    $script:ItgSkip = -not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) -or -not $installer
    $script:Itg = @{ DataPath = $dataPath; Installer = $installer; Port = $(if ($env:BXDBA_TEST_PORT) { [int]$env:BXDBA_TEST_PORT } else { 5430 }) }
}

Describe 'A real PostgreSQL server' -Tag Integration -Skip:$script:ItgSkip -ForEach @($script:Itg) {
    BeforeAll {
        $conf = @{
            DbHost = '127.0.0.1'; Port = $Port; SuperPass = 'S3cr3t!123'
            DbHomePath = (Join-Path $DataPath 'postgresql'); BackupRestoreParallelism = 4
            EnvName = 'BxDbaTest1'
            # The folder holding the test installer doubles as the download folder, so nothing is downloaded.
            TargetVersion = [IO.Path]::GetFileNameWithoutExtension($Installer); DownloadPath = (Split-Path $Installer)
            AllowedClientAddresses = '192.168.0.0/16', '172.17.0.0/16'
            Extensions = 'btree_gist', 'postgres_fdw'
            AppUsers = @{ my_app1 = 'my_app1_pass123' }
            AppDatabases = @{ my_app1 = 'my_app1' }
            PgServerSettings = "max_connections = '100'", "shared_buffers = '256MB'", "work_mem = '8MB'"
        }
        $app = @{ Conf = $conf; Database = 'my_app1'; User = 'my_app1'; Password = 'my_app1_pass123' }
        $fdwConf = @{
            SourceDb = 'my_app1'; SourceDbUser = 'my_app1'; SourceDbPass = 'my_app1_pass123'; FdwSchema = 'my_app1_fdw1'
            ForeignHost = '127.0.0.1'; ForeignPort = $Port; ForeignDb = 'my_app1'; ForeignSchema = 'public'
            ForeignUser = 'my_app1'; ForeignPass = 'my_app1_pass123'
        }
        $backupDir = Join-Path $DataPath 'db-bck'
        function Get-Value([string]$Sql, [hashtable]$As = @{ Conf = $conf }) {
            (Invoke-Psql @As -Sql $Sql -Tuples -AssertSuccess).Out
        }

        Uninstall-PgServer -Conf $conf   # whatever an earlier run left behind
        Install-PgServer -Conf $conf
    }
    AfterAll {
        Uninstall-PgServer -Conf $conf
    }

    It 'installed from the installer already in the download folder, and kept it' {
        $Installer | Should -Exist
    }

    It 'runs the service with the configured roles, databases, extensions and settings' {
        (Get-Service -Name 'BxDbaTest1_Postgresql').Status | Should -Be 'Running'
        Test-PgRole -Conf $conf -Role my_app1 | Should -BeTrue
        Test-PgDatabase -Conf $conf -Database my_app1 | Should -BeTrue
        Test-PgDatabase -Conf $conf -Database no_such_db | Should -BeFalse
        Get-Value "SELECT string_agg(extname, ',' ORDER BY extname) FROM pg_extension WHERE extname IN ('btree_gist', 'postgres_fdw')" @{ Conf = $conf; Database = 'my_app1' } |
            Should -Be 'btree_gist,postgres_fdw'
        Get-Value 'SHOW max_connections' | Should -Be '100'
        Get-Value "SELECT rolsuper FROM pg_roles WHERE rolname = 'my_app1'" | Should -Be 'f'
        Get-NetFirewallRule -DisplayName "BxDbaTest1_PG - open $Port" | Should -Not -BeNullOrEmpty
    }

    It 'installs again without failing' {
        { Install-PgServer -Conf $conf } | Should -Not -Throw
        Get-Value 'SELECT 1' | Should -Be '1'
    }

    It 'backs up, drops and restores a database with its data intact' {
        $label = "it's ""quoted"" and  spaced"
        Invoke-Psql @app -AssertSuccess -Sql ("CREATE TABLE IF NOT EXISTS probe (id int PRIMARY KEY, label text); " +
            "INSERT INTO probe VALUES (1, '$(ConvertTo-SqlLiteral $label)') ON CONFLICT (id) DO UPDATE SET label = excluded.label") | Out-Null
        $backup = Backup-PgDatabase -Conf $conf -Database my_app1 `
            -BackupPath (Join-Path $backupDir ('my_app1-itg-{0:yyyyMMdd_HHmmss}.backup' -f (Get-Date)))
        $backup | Should -Exist

        Remove-PgDatabase -Conf $conf -Database my_app1 -SkipBackup | Out-Null
        Test-PgDatabase -Conf $conf -Database my_app1 | Should -BeFalse

        Restore-PgDatabase -Conf $conf -BackupPath $backup -Database my_app1 -Owner my_app1
        Get-Value 'SELECT label FROM probe WHERE id = 1' $app | Should -BeExactly $label
        Get-Value "SELECT rolsuper FROM pg_roles WHERE rolname = 'my_app1'" | Should -Be 'f'
        { Restore-PgDatabase -Conf $conf -BackupPath $backup -Database my_app1 -Owner my_app1 } |
            Should -Throw -ExpectedMessage '*already exists*'
    }

    It 'backs up before dropping, by default' {
        $backup = Remove-PgDatabase -Conf $conf -Database my_app1
        $backup | Should -Exist
        Restore-PgDatabase -Conf $conf -BackupPath $backup -Database my_app1 -Owner my_app1
        Get-Value 'SELECT count(*) FROM probe' $app | Should -Be '1'
    }

    It 'sets up and refreshes a foreign data wrapper, refusing while a view depends on it' {
        Install-PgFdw -Conf $conf -Fdw $fdwConf
        $countSql = "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'my_app1_fdw1' AND c.relkind = 'f'"
        $imported = Get-Value $countSql $app
        [int]$imported | Should -BeGreaterThan 0

        Update-PgFdw -Conf $conf -Fdw $fdwConf
        Get-Value $countSql $app | Should -Be $imported

        Invoke-Psql @app -AssertSuccess -Sql 'CREATE VIEW probe_v AS SELECT * FROM my_app1_fdw1.probe' | Out-Null
        try { { Update-PgFdw -Conf $conf -Fdw $fdwConf } | Should -Throw -ExpectedMessage '*probe_v*' }
        finally { Invoke-Psql @app -Sql 'DROP VIEW IF EXISTS probe_v' | Out-Null }
    }

    It 'restarts the running service' {
        Restart-PgService -Conf $conf -OnlyIfRunning
        Get-Value 'SELECT 1' | Should -Be '1'
    }

    It 'lists the VC++ redistributables' {
        @(Get-VCRedist).Count | Should -BeGreaterThan 0
    }
}

BeforeDiscovery {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    $script:NewestSkip = -not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    # Not $script:Newest: that is the runner's -Newest switch, which can't hold a hashtable.
    $script:NewestTest = @{
        DataPath = $script:Itg.DataPath
        Port     = $(if ($env:BXDBA_TEST_NEWEST_PORT) { [int]$env:BXDBA_TEST_NEWEST_PORT } else { 5431 })
    }
}

# Opt-in with -Newest: it downloads the newest installer, ~355 MB, on every run.
Describe 'The newest PostgreSQL release, downloaded and installed' -Tag Newest -Skip:$script:NewestSkip -ForEach @($script:NewestTest) {
    BeforeAll {
        $root = Join-Path $DataPath 'newest'
        $downloads = Join-Path $root 'download'
        $conf = @{
            DbHost = '127.0.0.1'; Port = $Port; SuperPass = 'S3cr3t!123'; EnvName = 'BxDbaTest2'
            DbHomePath = (Join-Path $root 'postgresql'); TargetVersion = 'newest'; DownloadPath = $downloads
        }
        $resolvedInstaller = Resolve-PgInstallerName 'newest'

        # Start from nothing, so the installer really has to be downloaded.
        Uninstall-PgServer -Conf $conf
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
        Install-PgServer -Conf $conf
    }
    AfterAll {
        Uninstall-PgServer -Conf $conf
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'runs the release that newest resolves to' {
        $resolvedInstaller -match '^postgresql-(\d+\.\d+)-\d+-windows-x64\.exe$' | Should -BeTrue
        $expectedVersion = $Matches[1]
        (Invoke-Psql -Conf $conf -Sql 'SHOW server_version' -Tuples -AssertSuccess).Out | Should -Be $expectedVersion
    }

    It 'deleted the installer it downloaded' {
        $downloads | Should -Exist
        @(Get-ChildItem -LiteralPath $downloads -Force).Count | Should -Be 0
    }
}
