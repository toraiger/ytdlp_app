#!/usr/bin/env python3
"""Install a complete JDK 21 into the writable cloud tooling directory."""
from pathlib import Path
import hashlib
import shutil
import subprocess
import tarfile
import urllib.request

JDK = Path("/workspace/.tooling/jdk-21")
URL = "https://download.oracle.com/java/21/latest/jdk-21_linux-x64_bin.tar.gz"


def main():
    if (JDK / "bin/javac").exists():
        subprocess.run([str(JDK / "bin/javac"), "-version"], check=True)
        return
    with urllib.request.urlopen(URL + ".sha256", timeout=30) as response:
        checksum = response.read().decode().split()[0]
    archive = Path("/tmp/mix-player-jdk21.tar.gz")
    with urllib.request.urlopen(URL, timeout=60) as source, archive.open("wb") as target:
        shutil.copyfileobj(source, target)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != checksum:
        raise RuntimeError("Oracle JDK SHA-256 verification failed")
    temp = Path("/workspace/.tooling/jdk-extract")
    temp.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive) as bundle:
        bundle.extractall(temp, filter="data")
    next(p for p in temp.iterdir() if p.is_dir()).rename(JDK)
    subprocess.run([str(JDK / "bin/javac"), "-version"], check=True)
    print("JDK 21 installed and SHA-256 verified.")


if __name__ == "__main__":
    main()
