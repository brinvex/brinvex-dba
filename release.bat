set JAVA_HOME="V:\tools\java\jdk-21.0.1"

set new_version=1.2.0

set jsh_content=^
    Files.writeString(Path.of("README.md"), ^
        Files.readString(Path.of("README.md")).replaceAll(^
            "<brinvex-dba.version>(.*)</brinvex-dba.version>", ^
            "<brinvex-dba.version>%%s</brinvex-dba.version>".formatted(System.getenv("new_version"))), ^
    StandardOpenOption.TRUNCATE_EXISTING);

echo %jsh_content% | %JAVA_HOME%\bin\jshell -

call mvnw clean package
call mvnw versions:set -DnewVersion=%new_version%
call mvnw versions:commit
call mvnw clean deploy -DskipTests