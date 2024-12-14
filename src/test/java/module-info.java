module test.brinvex.persistence {
    requires com.brinvex.dbmanager;
    requires org.junit.jupiter.api;
    requires org.junit.jupiter.engine;
    requires org.slf4j;
    opens test.com.brinvex.dbmanager to org.junit.platform.commons;
}