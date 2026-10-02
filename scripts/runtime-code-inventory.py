#!/usr/bin/env python3
"""Small, read-only map of product Swift sources; no generated/cache traversal."""
import json
from pathlib import Path
import re
import subprocess


def inventory():
    root = Path(__file__).resolve().parent.parent
    paths = subprocess.check_output([
        "rg", "--files", "TaptionPlan", "TaptionPlanWidget", "TaptionPlanWatch",
        "TaptionPlanWatchWidget", "Packages", "-g", "*.swift",
        "-g", "!**/Tests/**", "-g", "!**/.build/**",
    ], cwd=root, text=True).splitlines()
    patterns = {
        "sort_sites": r"\.sorted\s*\(|\.sorted\s*\{",
        "filter_sites": r"\.filter\s*\(|\.filter\s*\{",
        "detached_tasks": r"Task\.detached\s*\(",
        "gesture_callbacks": r"\.onChanged\s*\{",
        "sqlite_prepares": r"sqlite3_prepare_v[23]\s*\(",
    }
    files = []
    for name in sorted(paths):
        source = (root / name).read_text()
        files.append({
            "path": name,
            "lines": len(source.splitlines()),
            "imports": sorted(set(re.findall(r"^\s*(?:@\w+\s+)?import\s+(\w+)", source, re.M))),
            **{key: len(re.findall(pattern, source)) for key, pattern in patterns.items()},
        })
    return {"source_files": len(files), "lines": sum(x["lines"] for x in files),
            "note": "Counts locate review work; they are not measured bottlenecks.", "files": files}


if __name__ == "__main__":
    print(json.dumps(inventory(), ensure_ascii=False, indent=2))
