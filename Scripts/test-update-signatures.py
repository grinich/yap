#!/usr/bin/env python3
"""Offline integration check using RFC 8032 TEST KEYS, never production credentials."""
import base64
import os
from pathlib import Path
import plistlib
import runpy
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parent.parent
sparkle = root / ".build/artifacts/sparkle/Sparkle"
tools = sparkle / "bin"
configure = runpy.run_path(str(root / "Scripts/configure-updates.py"))["configure"]
seed = bytes.fromhex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
public = base64.b64encode(bytes.fromhex("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")).decode()
with tempfile.TemporaryDirectory(prefix="yap-update-test-") as temporary:
    scratch = Path(temporary)
    key = scratch / "test-key.txt"
    key.write_bytes(base64.b64encode(seed))
    key.chmod(0o600)
    app = scratch / "Yap.app"
    (app / "Contents/MacOS").mkdir(parents=True)
    (app / "Contents/Frameworks").mkdir()
    # An inert fixture is never launched. The generator only inspects metadata.
    shutil.copyfile("/usr/bin/true", app / "Contents/MacOS/Yap")
    framework = sparkle / "Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
    subprocess.run(["ditto", str(framework), str(app / "Contents/Frameworks/Sparkle.framework")], check=True)
    info = configure({"CFBundleName": "Yap", "CFBundleIdentifier": "com.grinich.yap.signature-fixture",
            "CFBundleExecutable": "Yap", "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "0.1.1", "CFBundleVersion": "2", "LSMinimumSystemVersion": "26.0",
            "SUDefaultsDomain": "com.grinich.yap.updater-fixture." + scratch.name},
            {"YAP_RELEASE": "1", "YAP_UPDATE_FEED_URL": "https://github.com/example/releases/releases/latest/download/appcast.xml",
             "YAP_UPDATE_PUBLIC_KEY": public})
    plist = app / "Contents/Info.plist"
    validator = scratch / "validate-updater-startup"
    subprocess.run(["xcrun", "clang", "-fobjc-arc", "-framework", "Foundation", "-framework", "Sparkle",
                    "-F", str(framework.parent), "-Wl,-rpath," + str(framework.parent),
                    str(root / "Scripts/validate-updater-startup.m"), "-o", str(validator)], check=True)
    # Crypto verification alone does not call Sparkle's updater startup checks.
    # Reproduce v0.1.1's startup error, then validate the actual release configurator.
    for verification in [None, False]:
        invalid_info = {**info}
        if verification is None:
            invalid_info.pop("SUVerifyUpdateBeforeExtraction")
        else:
            invalid_info["SUVerifyUpdateBeforeExtraction"] = verification
        plist.write_bytes(plistlib.dumps(invalid_info))
        subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True)
        rejected = subprocess.run([str(validator), str(app)], capture_output=True, text=True, timeout=30)
        assert rejected.returncode == 1 and "SUVerifyUpdateBeforeExtraction" in rejected.stderr, rejected.stderr
    plist.write_bytes(plistlib.dumps(info))
    subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True)
    subprocess.run([str(validator), str(app)], check=True, timeout=30)
    feed_dir = scratch / "feed"
    feed_dir.mkdir()
    archive = feed_dir / "Yap-macOS.zip"
    subprocess.run(["ditto", "-c", "-k", "--keepParent", str(app), str(archive)], check=True)
    subprocess.run([str(tools / "generate_appcast"), "--ed-key-file", str(key), "--maximum-deltas", "0",
                    "--download-url-prefix", "https://github.com/example/releases/releases/download/v0.1.1/", str(feed_dir)], check=True)
    feed = feed_dir / "appcast.xml"
    subprocess.run(["python3", str(root / "Scripts/validate-appcast.py"), str(feed), str(archive), str(plist)],
                   env={**os.environ, "YAP_RELEASE_REPOSITORY": "example/releases"}, check=True)
    sign = [str(tools / "sign_update"), "--verify", "--ed-key-file", str(key)]
    subprocess.run(sign + [str(feed)], check=True)
    signature = ET.parse(feed).find("channel/item/enclosure").get("{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature")
    subprocess.run(sign + [str(archive), signature], check=True)
    with archive.open("ab") as stream:
        stream.write(b"tampering")
    assert subprocess.run(sign + [str(archive), signature], capture_output=True).returncode != 0, "Tampered archive was accepted"
    feed.write_bytes(feed.read_bytes().replace(b"0.1.1", b"0.1.9"))
    assert subprocess.run(sign + [str(feed)], capture_output=True).returncode != 0, "Tampered feed was accepted"
print("PASS: updater startup rejects missing/disabled extraction verification and accepts release settings; "
      "signed feed and archive verify; tampered feed and archive are rejected.")
