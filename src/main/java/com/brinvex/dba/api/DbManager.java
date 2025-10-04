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
package com.brinvex.dba.api;

import com.brinvex.dba.internal.postgresql.PostgresqlDbManager;

import java.io.IOException;
import java.nio.file.Path;
import java.util.Map;

public interface DbManager {

    DbManager POSTGRESQL = new PostgresqlDbManager();

    void install(DbInstallConf conf) throws IOException;

    void uninstall(DbInstallConf conf) throws IOException;

    boolean databaseExists(DbConf conf, String db) throws IOException;

    void createAppDbUsers(DbConf conf, Map<String, String> appUsers) throws IOException;

    void createAppDatabases(DbConf conf, Map<String, String> appDbs) throws IOException;

    void backupDatabase(DbConf conf, String dbToBackup, Path backupPath) throws IOException;

    void backupAndDropDatabase(DbConf conf, String db) throws IOException;

    void backupAllDbData(DbConf baseConf) throws IOException;

    void restoreDatabase(DbConf conf, Path backupPath, String db, String owner) throws IOException;

    void restartDbSystem(DbInstallConf conf) throws IOException;

    void restartDbSystemIfRunning(DbInstallConf conf) throws IOException;

    void riskyDropDatabase(DbConf conf, String db) throws IOException;
}
