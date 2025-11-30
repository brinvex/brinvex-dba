package com.brinvex.dba.api;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStreamReader;
import java.io.UncheckedIOException;
import java.util.ArrayList;
import java.util.List;

public class VCRedistDetectUtil {

    // 64-bit uninstall key
    private static final String regKey64 = "HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall";
    // 32-bit uninstall key on 64-bit Windows
    private static final String regKey32 = "HKLM\\SOFTWARE\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall";

    public static List<String> detectVCRedists() {
        List<String> results = new ArrayList<>();
        results.addAll(detectVCRedists(regKey64));
        results.addAll(detectVCRedists(regKey32));
        return results;
    }

    private static List<String> detectVCRedists(String key) {
        try {
            List<String> results = new ArrayList<>();

            // Enumerate subkeys under Uninstall
            Process listKeys = Runtime.getRuntime().exec(
                    new String[]{"reg", "query", key}
            );
            BufferedReader reader = new BufferedReader(new InputStreamReader(listKeys.getInputStream()));
            String line;
            while ((line = reader.readLine()) != null) {
                line = line.trim();
                // For each subkey, query DisplayName
                Process displayNameProc = Runtime.getRuntime().exec(
                        new String[]{"reg", "query", line, "/v", "DisplayName"}
                );
                BufferedReader nameReader = new BufferedReader(new InputStreamReader(displayNameProc.getInputStream()));
                String nameLine;
                String displayName = null;
                while ((nameLine = nameReader.readLine()) != null) {
                    nameLine = nameLine.trim();
                    if (nameLine.contains("Visual C++")) {
                        // Extract value from line: usually last token
                        String[] tokens = nameLine.split("\\s{2,}");
                        if (tokens.length >= 3) {
                            displayName = tokens[2];
                        }
                    }
                }
                if (displayName != null) {
                    // Query DisplayVersion
                    Process displayVersionProc = Runtime.getRuntime().exec(
                            new String[]{"reg", "query", line, "/v", "DisplayVersion"}
                    );
                    BufferedReader verReader = new BufferedReader(new InputStreamReader(displayVersionProc.getInputStream()));
                    String version = null;
                    String verLine;
                    while ((verLine = verReader.readLine()) != null) {
                        verLine = verLine.trim();
                        String[] tokens = verLine.split("\\s{2,}");
                        if (tokens.length >= 3) {
                            version = tokens[2];
                        }
                    }
                    String fullName = displayName + " - Version: " + version;
                    results.add(fullName);
                }
            }
            return results;
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
    }
}
