"""Export xcresult attachments and recover stable store screenshot filenames."""
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys

SHOT_NAME = re.compile(r"^((?:store-(?:en|zh-Hans|zh-Hant)-\d{2}-[a-z-]+|paid-01-paywall))(?=[_.]|$)")


def name_attachments(folder):
    manifest_path = folder / "manifest.json"
    if not manifest_path.is_file():
        return []
    named = []
    for test in json.loads(manifest_path.read_text(encoding="utf-8")):
        for attachment in test["attachments"]:
            match = SHOT_NAME.match(attachment.get("suggestedHumanReadableName", ""))
            name = attachment["exportedFileName"]
            if not match or Path(name).name != name or Path(name).suffix.lower() != ".png":
                continue
            source = folder / name
            if not source.is_file():
                continue
            target = folder / (match[1] + ".png")
            if source != target:
                shutil.copy2(source, target)
            named.append(target)
    return named


def main(result, output):
    folder = Path(output)
    folder.mkdir(parents=True, exist_ok=True)
    subprocess.run(["xcrun", "xcresulttool", "export", "attachments", "--path", result,
                    "--output-path", str(folder)], check=True)
    name_attachments(folder)
    screenshots = list(folder.glob("**/*.png"))
    if not screenshots:
        sys.exit("界面测试没有导出 PNG 截图")
    print(f"已导出 {len(screenshots)} 张界面测试截图到 {folder}")


if __name__ == "__main__":
    main(*sys.argv[1:3])
