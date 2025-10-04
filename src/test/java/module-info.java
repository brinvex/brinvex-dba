module test.brinvex.persistence {
    requires com.brinvex.dba;
    requires org.junit.jupiter.api;
    requires org.junit.jupiter.engine;
    requires org.slf4j;
    opens test.com.brinvex.dba to org.junit.platform.commons;
}