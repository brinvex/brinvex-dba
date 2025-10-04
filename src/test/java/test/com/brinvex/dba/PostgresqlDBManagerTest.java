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
package test.com.brinvex.dba;

import com.brinvex.dba.api.DbConf;
import com.brinvex.dba.api.DbInstallConf;
import com.brinvex.dba.api.DbManager;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfSystemProperty;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.IOException;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.time.LocalDateTime;
import java.time.format.DateTimeFormatter;
import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.assertTrue;

class PostgresqlDBManagerTest {

    private static final Logger LOG = LoggerFactory.getLogger(PostgresqlDBManagerTest.class);

    @EnabledIfSystemProperty(named = "enableLongRunningTests", matches = "true")
    @Test
    void install_uninstall() throws IOException {
        Path testBasePath = Paths.get("v:/prj/bx/bx-dba/test-data");

        String appUser = "bx_app1";
        String appDb = "bx_app1";

        DbConf baseConf = new DbConf()
                .setPort(5430)
                .setSuperPass("S3cr3t!123")
                .setDbHomePath(testBasePath.resolve("postgresql"));

        DbInstallConf installConf = new DbInstallConf(baseConf)
                .setEnvName("BrinvexDbaTest")
                .setInstallerPath(testBasePath.resolve("install/postgresql-18.0-1-windows-x64.exe"))
                .addAllowedClientAddresses(List.of("192.168.0.0/16", "172.17.0.0/16"))
                .addExtensions(List.of("btree_gist", "postgres_fdw"))
                .addAppUsers(Map.of(appUser, "bx_app_user1_123"))
                .addAppDatabases(Map.of(appDb, appUser))
                .addSystemSettings(List.of(
                        "max_connections = '100'",
                        "max_prepared_transactions = '100'",
                        "shared_buffers = '8GB'",
                        "effective_cache_size = '24GB'",
                        "maintenance_work_mem = '2097151kB'",
                        "checkpoint_completion_target = '0.9'",
                        "wal_buffers = '16MB'",
                        "default_statistics_target = '100'",
                        "random_page_cost = '1.1'",
                        "work_mem = '20971kB'",
                        "min_wal_size = '1GB'",
                        "max_wal_size = '4GB'",
                        "max_worker_processes = '8'",
                        "max_parallel_workers_per_gather = '4'",
                        "max_parallel_workers = '8'",
                        "max_parallel_maintenance_workers = '4'"
                ));

        DbManager dbManager = DbManager.POSTGRESQL;

        LOG.debug("uninstall - cleaning mess from previous runs - {}", installConf);
        dbManager.uninstall(installConf);

        LOG.debug("install - {}", installConf);
        dbManager.install(installConf);

        Path backupToRestore = testBasePath.resolve("db-bck/bx_app1-test-in.backup");
        try {
            dbManager.restoreDatabase(baseConf, backupToRestore, appDb, appUser);
        } catch (IllegalArgumentException e) {
            assertTrue(e.getMessage().startsWith("Database already exists"));
        }
        dbManager.backupAndDropDatabase(baseConf, appDb);
        dbManager.restoreDatabase(baseConf, backupToRestore, appDb, appUser);

        String ts = LocalDateTime.now().format(DateTimeFormatter.ofPattern("yyyyMMdd_HHmmss"));
        Path backupPath = testBasePath.resolve(String.format("db-bck/%s-test-out-%s.backup", appDb, ts));
        dbManager.backupDatabase(baseConf, appDb, backupPath);
        dbManager.riskyDropDatabase(baseConf, appDb);
        dbManager.restoreDatabase(baseConf, backupPath, appDb, appUser);

        LOG.debug("uninstall - {}", installConf);
        dbManager.uninstall(installConf);
    }

}
