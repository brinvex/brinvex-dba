package test.com.brinvex.dba;

import com.brinvex.dba.api.VCRedistDetectUtil;
import org.junit.jupiter.api.Test;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.List;

public class VCRedistDetectUtilTest {

    private static final Logger LOG = LoggerFactory.getLogger(PostgresDBManagerTest.class);

    @Test
    public void detectVCRedistsVersions() {
        List<String> vcRedists = VCRedistDetectUtil.detectVCRedists();
        LOG.info("VC Redist Versions: \n  {}", String.join("\n  ", vcRedists));
    }


}
