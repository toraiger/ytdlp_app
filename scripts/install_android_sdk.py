#!/usr/bin/env python3
"""Install the cloud Android build tools using Google's verified archive."""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import urllib.parse
import urllib.request
import zipfile

SDK = Path("/workspace/.tooling/android-sdk")
TOOLS_URL = "https://dl.google.com/android/repository/commandlinetools-linux-16111833_latest.zip"
# SHA-1 published in Google's repository2-3.xml metadata.
TOOLS_SHA1 = "e025545c62a8e64c7559119566a569fb1dec5f60"


def main():
    manager = SDK / "cmdline-tools/latest/bin/sdkmanager"
    if not manager.exists():
        archive = Path("/tmp/mix-player-android-tools.zip")
        with urllib.request.urlopen(TOOLS_URL, timeout=60) as source, archive.open("wb") as target:
            shutil.copyfileobj(source, target)
        if hashlib.sha1(archive.read_bytes()).hexdigest() != TOOLS_SHA1:
            raise RuntimeError("Google Android tool archive checksum mismatch")
        tool_root = SDK / "cmdline-tools"
        tool_root.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(archive) as bundle:
            bundle.extractall(tool_root)
        (tool_root / "cmdline-tools").rename(tool_root / "latest")
        for file in (tool_root / "latest/bin").iterdir():
            file.chmod(0o755)
    args = [str(manager), "--sdk_root=" + str(SDK)]
    proxy = urllib.parse.urlsplit(os.environ.get("HTTPS_PROXY", ""))
    if proxy.hostname:
        args += ["--proxy=http", "--proxy_host=" + proxy.hostname,
                 "--proxy_port=" + str(proxy.port or 80)]
    environment = dict(os.environ, ANDROID_USER_HOME="/workspace/.cache/android-user")
    with Path("/tmp/mix-android-install.log").open("w") as log:
        subprocess.run(args + ["--licenses"], input="y\n" * 120, text=True,
                       env=environment, stdout=log, stderr=subprocess.STDOUT, check=True)
        subprocess.run(args + [
            "platform-tools", "platforms;android-34", "platforms;android-35", "platforms;android-36", "build-tools;35.0.0", "build-tools;36.0.0", "ndk;27.0.12077973", "cmake;3.22.1",
        ], env=environment, stdout=log, stderr=subprocess.STDOUT, check=True)
    print("Android SDK 36 and NDK 27 installed.")


if __name__ == "__main__":
    main()
