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

import java.nio.file.Path;
import java.util.Collection;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.Map;
import java.util.Set;
import java.util.StringJoiner;

public class DbInstallConf {

    private final DbConf baseConf;
    private String envName;
    private String firewallRuleName;
    private String winServiceName;
    private Path installerPath;
    private String dbLocale = "English_United States.UTF8";
    private String dbListenAddresses = "*";
    private final Set<String> allowedClientAddresses = new LinkedHashSet<>();
    private final Set<String> systemSettings = new LinkedHashSet<>();
    private final Set<String> extensions = new LinkedHashSet<>();
    private final Map<String, String> appUsers = new LinkedHashMap<>();
    private final Map<String, String> appDatabases = new LinkedHashMap<>();

    public DbInstallConf(DbConf baseConf) {
        this.baseConf = baseConf;
    }

    public DbConf getBaseConf() {
        return baseConf;
    }

    public String getEnvName() {
        return envName == null ? "BrinvexDBA" : envName;
    }

    public DbInstallConf setEnvName(String envName) {
        this.envName = envName;
        return this;
    }

    public String getFirewallRuleName() {
        if (firewallRuleName != null) {
            return firewallRuleName;
        }
        return String.format("%s_PG - open %s", envName, baseConf.getPort());
    }

    public DbInstallConf setFirewallRuleName(String firewallRuleName) {
        this.firewallRuleName = firewallRuleName;
        return this;
    }

    public String getWinServiceName() {
        return winServiceName == null ? (getEnvName() + "_Postgresql") : winServiceName;
    }

    public DbInstallConf setWinServiceName(String winServiceName) {
        this.winServiceName = winServiceName;
        return this;
    }

    public Path getInstallerPath() {
        return installerPath;
    }

    public DbInstallConf setInstallerPath(Path installerPath) {
        this.installerPath = installerPath;
        return this;
    }

    public String getDbLocale() {
        return dbLocale;
    }

    public DbInstallConf setDbLocale(String dbLocale) {
        this.dbLocale = dbLocale;
        return this;
    }

    public Set<String> getAllowedClientAddresses() {
        return allowedClientAddresses;
    }

    public DbInstallConf addAllowedClientAddresses(Collection<String> allowedClientAddresses) {
        this.allowedClientAddresses.addAll(allowedClientAddresses);
        return this;
    }

    public String getDbListenAddresses() {
        return dbListenAddresses;
    }

    public DbInstallConf setDbListenAddresses(String dbListenAddresses) {
        this.dbListenAddresses = dbListenAddresses;
        return this;
    }

    public Set<String> getSystemSettings() {
        return systemSettings;
    }

    public DbInstallConf addSystemSettings(Collection<String> systemSettings) {
        this.systemSettings.addAll(systemSettings);
        return this;
    }

    public Set<String> getExtensions() {
        return extensions;
    }

    /**
     * Carefully consider whether you really need this method.
     * It is often better to create an extension the same way we create tables or other DB objects.
     * E.g:
     * create extension if not exists postgres_fdw;
     * grant usage on foreign data wrapper postgres_fdw to bx_finlab_dev;
     *
     */
    public DbInstallConf addExtensions(Collection<String> extensions) {
        this.extensions.addAll(extensions);
        return this;
    }

    public Map<String, String> getAppUsers() {
        return appUsers;
    }

    public DbInstallConf addAppUsers(Map<String, String> appUsers) {
        this.appUsers.putAll(appUsers);
        return this;
    }

    public Map<String, String> getAppDatabases() {
        return appDatabases;
    }

    public DbInstallConf addAppDatabases(Map<String, String> appDatabases) {
        this.appDatabases.putAll(appDatabases);
        return this;
    }

    @Override
    public String toString() {
        return new StringJoiner(", ", DbInstallConf.class.getSimpleName() + "[", "]")
                .add("baseConf=" + baseConf)
                .add("envName='" + envName + "'")
                .add("firewallRuleName='" + firewallRuleName + "'")
                .add("winServiceName='" + winServiceName + "'")
                .add("installerPath=" + installerPath)
                .add("pgLocale='" + dbLocale + "'")
                .add("pgListenAddresses='" + dbListenAddresses + "'")
                .add("allowedClientAddresses=" + allowedClientAddresses)
                .add("systemSettings=" + systemSettings)
                .add("extensions=" + extensions)
                .add("appUsers=" + appUsers)
                .add("appDatabases=" + appDatabases)
                .toString();
    }
}
