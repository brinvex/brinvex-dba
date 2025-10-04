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
package com.brinvex.dba.internal.common;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.util.Collection;
import java.util.Collections;

import static java.util.stream.Collectors.joining;

public class OsCmdUtil {

    private static final Logger LOG = LoggerFactory.getLogger(OsCmdUtil.class);

    public static OsCmdResult exec(String cmds) throws IOException {
        return exec(cmds, Collections.emptyList());
    }

    public static OsCmdResult exec(String cmds, Collection<String> envs) throws IOException {
        String normCmds = cmds.replaceAll("\\s+", " ");
        LOG.debug("exec {} [envs={}]", normCmds, hideSecretEnvs(envs));

        String[] cmdParts = normCmds.split("\\s");
        Runtime runtime = Runtime.getRuntime();
        Process process = envs.isEmpty() ? runtime.exec(cmdParts) : runtime.exec(cmdParts, envs.toArray(String[]::new));

        StringBuilder outSb = new StringBuilder();
        try (BufferedReader outReader = new BufferedReader(new InputStreamReader(process.getInputStream()))) {
            outReader.lines().forEach(s -> {
                LOG.trace("cmdOut: {}", s);
                if (!s.isBlank()) {
                    outSb.append(s);
                }
            });
        }

        StringBuilder errSb = new StringBuilder();
        try (BufferedReader errReader = new BufferedReader(new InputStreamReader(process.getErrorStream()))) {
            errReader.lines().forEach(s -> {
                LOG.trace("cmdErr: {}", s);
                if (!s.isBlank()) {
                    errSb.append(s);
                }
            });
        }

        return new OsCmdResult(outSb.toString(), errSb.toString());
    }

    private static String hideSecretEnvs(Collection<String> envs) {
        return envs == null ? null : envs.stream()
                .map(s -> s.startsWith("PGPASSWORD=") ? "PGPASSWORD=*****" : s)
                .collect(joining(","));
    }
}
