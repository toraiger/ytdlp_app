#!/usr/bin/env python3
"""Apply the documented mobile plugin settings without duplicating entries."""
from pathlib import Path
import plistlib
import re
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
ANDROID = "http://schemas.android.com/apk/res/android"
ET.register_namespace("android", ANDROID)


def android_settings():
    manifest = ROOT / "android/app/src/main/AndroidManifest.xml"
    tree = ET.parse(manifest)
    root = tree.getroot()
    attr = lambda name: f"{{{ANDROID}}}{name}"
    for permission in (
        "INTERNET", "WAKE_LOCK", "FOREGROUND_SERVICE",
        "FOREGROUND_SERVICE_MEDIA_PLAYBACK",
    ):
        name = f"android.permission.{permission}"
        if not any(p.get(attr("name")) == name for p in root.findall("uses-permission")):
            root.insert(0, ET.Element("uses-permission", {attr("name"): name}))
    app = root.find("application")
    app.set(attr("label"), "Mix Player")
    app.set(attr("usesCleartextTraffic"), "false")
    app.set(attr("allowBackup"), "false")
    for tag, name, action in (
        ("service", "com.ryanheise.audioservice.AudioService",
         "android.media.browse.MediaBrowserService"),
        ("receiver", "com.ryanheise.audioservice.MediaButtonReceiver",
         "android.intent.action.MEDIA_BUTTON"),
    ):
        component = next((e for e in app.findall(tag) if e.get(attr("name")) == name), None)
        if component is None:
            component = ET.SubElement(app, tag, {attr("name"): name, attr("exported"): "true"})
            intent = ET.SubElement(component, "intent-filter")
            ET.SubElement(intent, "action", {attr("name"): action})
        if tag == "service":
            component.set(attr("foregroundServiceType"), "mediaPlayback")
    ET.indent(tree, space="    ")
    tree.write(manifest, encoding="utf-8", xml_declaration=True)
    activity = ROOT / "android/app/src/main/kotlin/jp/toraiger/mix_player_app/MainActivity.kt"
    text = activity.read_text()
    text = text.replace("import io.flutter.embedding.android.FlutterActivity",
                        "import com.ryanheise.audioservice.AudioServiceActivity")
    text = text.replace("class MainActivity : FlutterActivity()", "class MainActivity : AudioServiceActivity()")
    activity.write_text(text)
    gradle = ROOT / "android/app/build.gradle.kts"
    gradle.write_text(gradle.read_text().replace("minSdk = flutter.minSdkVersion", "minSdk = 24"))


def ios_settings():
    info = ROOT / "ios/Runner/Info.plist"
    data = plistlib.loads(info.read_bytes())
    data["CFBundleDisplayName"] = "Mix Player"
    data["CFBundleName"] = "Mix Player"
    data["UIBackgroundModes"] = sorted(set(data.get("UIBackgroundModes", [])) | {"audio"})
    info.write_bytes(plistlib.dumps(data, sort_keys=False))
    entitlements = ROOT / "ios/Runner/Runner.entitlements"
    data = plistlib.loads(entitlements.read_bytes()) if entitlements.exists() else {}
    data.setdefault("keychain-access-groups", [])
    entitlements.write_bytes(plistlib.dumps(data))
    project = ROOT / "ios/Runner.xcodeproj/project.pbxproj"
    text = re.sub(r"IPHONEOS_DEPLOYMENT_TARGET = [0-9.]+;",
                  "IPHONEOS_DEPLOYMENT_TARGET = 13.0;", project.read_text())
    marker = "INFOPLIST_FILE = Runner/Info.plist;"
    if "CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements;" not in text:
        text = text.replace(marker, marker + "\n\t\t\t\tCODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements;")
    project.write_text(text)


if __name__ == "__main__":
    android_settings()
    ios_settings()
    print("iOS background audio / Keychain and Android media service configured.")
