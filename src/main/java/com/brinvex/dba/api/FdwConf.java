package com.brinvex.dba.api;

public class FdwConf {

    private String sourceDb;
    private String sourceDbUser;
    private String sourceDbPass;

    private String fdwSchema;

    private String foreignHost;
    private String foreignDb;
    private int foreignPort;
    private String foreignSchema;
    private String foreignUser;
    private String foreignPass;

    public String getSourceDb() {
        return sourceDb;
    }

    public FdwConf setSourceDb(String sourceDb) {
        this.sourceDb = sourceDb;
        return this;
    }

    public String getSourceDbUser() {
        return sourceDbUser;
    }

    public FdwConf setSourceDbUser(String sourceDbUser) {
        this.sourceDbUser = sourceDbUser;
        return this;
    }

    public String getSourceDbPass() {
        return sourceDbPass;
    }

    public FdwConf setSourceDbPass(String sourceDbPass) {
        this.sourceDbPass = sourceDbPass;
        return this;
    }

    public String getFdwSchema() {
        return fdwSchema;
    }

    public FdwConf setFdwSchema(String fdwSchema) {
        this.fdwSchema = fdwSchema;
        return this;
    }

    public String getForeignHost() {
        return foreignHost;
    }

    public FdwConf setForeignHost(String foreignHost) {
        this.foreignHost = foreignHost;
        return this;
    }

    public String getForeignDb() {
        return foreignDb;
    }

    public FdwConf setForeignDb(String foreignDb) {
        this.foreignDb = foreignDb;
        return this;
    }

    public int getForeignPort() {
        return foreignPort;
    }

    public FdwConf setForeignPort(int foreignPort) {
        this.foreignPort = foreignPort;
        return this;
    }

    public String getForeignUser() {
        return foreignUser;
    }

    public FdwConf setForeignUser(String foreignUser) {
        this.foreignUser = foreignUser;
        return this;
    }

    public String getForeignPass() {
        return foreignPass;
    }

    public FdwConf setForeignPass(String foreignPass) {
        this.foreignPass = foreignPass;
        return this;
    }

    public String getForeignSchema() {
        return foreignSchema;
    }

    public FdwConf setForeignSchema(String foreignSchema) {
        this.foreignSchema = foreignSchema;
        return this;
    }

    @Override
    public String toString() {
        return "FdwConf{" +
               "sourceDb='" + sourceDb + '\'' +
               ", sourceDbUser='" + sourceDbUser + '\'' +
               ", sourceDbPass=***" +
               ", fdwSchema='" + fdwSchema + '\'' +
               ", foreignHost='" + foreignHost + '\'' +
               ", foreignDb='" + foreignDb + '\'' +
               ", foreignSchema='" + foreignSchema + '\'' +
               ", foreignPort=" + foreignPort +
               ", foreignUser='" + foreignUser + '\'' +
               ", foreignPass=***" +
               '}';
    }
}
