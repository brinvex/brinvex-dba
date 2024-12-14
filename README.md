# Brinvex Database Server Manager

### Introduction

_Brinvex Database Server Manager_ is a Java utility to programmatically manage Postgresql database server.

### Maven dependency declaration
````
<properties>
    <brinvex-db-manager.version>1.0.0</brinvex-db-manager.version>
</properties>    

<repository>
    <id>brinvex-repo</id>
    <name>Brinvex Repository</name>
    <url>https://github.com/brinvex/brinvex-repo/raw/main/</url>
    <snapshots>
        <enabled>false</enabled>
    </snapshots>
</repository>
        
<dependency>
    <groupId>com.brinvex</groupId>
    <artifactId>brinvex-db-manager</artifactId>
    <version>${brinvex-db-manager.version}</version>
</dependency>
````

### Requirements
- Java 17 or above

### License

- The _Brinvex Database Server Manager_ is released under version 2.0 of the Apache License.
