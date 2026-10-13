#!/usr/bin/env python3
"""Configure Gradle to use the cloud's existing HTTP(S) proxy."""
import os
from pathlib import Path
import hashlib
import re
import shutil
import subprocess
import urllib.parse


def main():
    proxy = urllib.parse.urlsplit(os.environ.get("HTTPS_PROXY", ""))
    if not proxy.hostname:
        return
    root = Path("/workspace/.cache/gradle")
    root.mkdir(parents=True, exist_ok=True)
    config = root / "gradle.properties"
    existing = config.read_text().splitlines() if config.exists() else []
    updates = {
        "systemProp.http.proxyHost": proxy.hostname,
        "systemProp.http.proxyPort": str(proxy.port or 80),
        "systemProp.https.proxyHost": proxy.hostname,
        "systemProp.https.proxyPort": str(proxy.port or 80),
        "systemProp.http.nonProxyHosts": "localhost|127.*",
        "org.gradle.workers.max": "4",
    }
    # Oracle's JDK lacks the cloud's CA. Keep its public roots and add the
    # platform-provided proxy CA instead of disabling TLS verification.
    jdk = Path("/workspace/.tooling/jdk-21")
    certificate = os.environ.get("CODEX_PROXY_CERT")
    if (jdk / "bin/keytool").exists() and certificate and Path(certificate).is_file():
        trust_root = Path("/workspace/.cache/java")
        trust_root.mkdir(parents=True, exist_ok=True)
        store = trust_root / "cacerts"
        if not store.exists():
            shutil.copyfile(jdk / "lib/security/cacerts", store)
        certificates = re.findall(
            r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----",
            Path(certificate).read_text(), re.S,
        )
        for pem in certificates:
            digest = hashlib.sha256(pem.encode()).hexdigest()
            alias = "cloud-proxy-" + digest
            command = [str(jdk / "bin/keytool"), "-keystore", str(store),
                       "-storepass", "changeit", "-alias", alias]
            found = subprocess.run(command + ["-list"], capture_output=True)
            if found.returncode != 0:
                public_ca = trust_root / (alias + ".pem")
                public_ca.write_text(pem)
                subprocess.run(command + ["-importcert", "-file", str(public_ca), "-noprompt"],
                               capture_output=True, check=True)
        updates["systemProp.javax.net.ssl.trustStore"] = str(store)
        updates["systemProp.javax.net.ssl.trustStorePassword"] = "changeit"
    kept = [line for line in existing if line.split("=", 1)[0] not in updates]
    config.write_text("\n".join(kept + [key + "=" + value for key, value in updates.items()]) + "\n")


if __name__ == "__main__":
    main()
