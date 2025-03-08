/*
 * Copyright © 2023 Brinvex (dev@brinvex.com)
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
package com.brinvex.dbmanager.api;

import java.nio.file.Path;
import java.util.Collection;
import java.util.LinkedHashSet;
import java.util.Set;
import java.util.StringJoiner;

public class DbConf {

    /**
     * https://www.postgresql.org/docs/17/app-pgdump.html
     */
    public enum BackupFormat {
        PLAIN,
        CUSTOM_ARCHIVE,
        DIRECTORY
    }

    private String host = "localhost";
    private int port = 5432;
    private String superUser = "postgres";
    private String superPass;
    private Path dbHomePath;
    private Path dbDataPath;
    private Path dbToolsPath;
    private BackupFormat backupFormat = BackupFormat.DIRECTORY;
    private int backupRestoreParallelism = 1;
    private final Set<String> superExtensions = new LinkedHashSet<>();

    public String getHost() {
        return host;
    }

    public DbConf setHost(String host) {
        this.host = host;
        return this;
    }

    public int getPort() {
        return port;
    }

    public DbConf setPort(int port) {
        this.port = port;
        return this;
    }

    public String getSuperUser() {
        return superUser;
    }

    public DbConf setSuperUser(String superUser) {
        this.superUser = superUser;
        return this;
    }

    public String getSuperPass() {
        return superPass;
    }

    public DbConf setSuperPass(String superPass) {
        this.superPass = superPass;
        return this;
    }

    public Path getDbHomePath() {
        return dbHomePath != null ? dbHomePath : Path.of("c:/postgresql");
    }

    public DbConf setDbHomePath(Path dbHomePath) {
        this.dbHomePath = dbHomePath;
        return this;
    }

    public Path getDbDataPath() {
        return dbDataPath != null ? dbDataPath : getDbHomePath().resolve("db_data");
    }

    public DbConf setDbDataPath(Path dbDataPath) {
        this.dbDataPath = dbDataPath;
        return this;
    }

    public Path getDbSystemPath() {
        return getDbHomePath().resolve("db_system");
    }

    public Path getDbToolsPath() {
        return dbToolsPath != null ? dbToolsPath : getDbSystemPath().resolve("bin");
    }

    public DbConf setDbToolsPath(Path dbToolsPath) {
        this.dbToolsPath = dbToolsPath;
        return this;
    }

    public BackupFormat getBackupFormat() {
        return backupFormat;
    }

    public DbConf setBackupFormat(BackupFormat backupFormat) {
        this.backupFormat = backupFormat;
        return this;
    }

    public int getBackupRestoreParallelism() {
        return backupRestoreParallelism;
    }

    public DbConf setBackupRestoreParallelism(int backupRestoreParallelism) {
        this.backupRestoreParallelism = backupRestoreParallelism;
        return this;
    }

    public Set<String> getSuperExtensions() {
        return superExtensions;
    }

    public DbConf addSuperExtensions(Collection<String> extensions) {
        this.superExtensions.addAll(extensions);
        return this;
    }

    @Override
    public String toString() {
        return new StringJoiner(", ", DbConf.class.getSimpleName() + "[", "]")
                .add("host='" + host + "'")
                .add("port=" + port)
                .add("superUser='" + superUser + "'")
                .add("dbHomePath=" + dbHomePath)
                .add("dbDataPath=" + dbDataPath)
                .add("toolsPath=" + dbToolsPath)
                .add("dbSystemPath=" + getDbSystemPath())
                .add("backupFormat=" + backupFormat)
                .add("backupRestoreParallelism=" + backupRestoreParallelism)
                .add("dbExtensions=" + superExtensions)
                .toString();
    }
}
