#!/usr/bin/env python3
"""Create a fresh deterministic workspace; print its absolute path."""
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[2]
base = repo / ".build/performance"
base.mkdir(parents=True, exist_ok=True)
root = Path(tempfile.mkdtemp(prefix="fixture-", dir=base))
for directory, count in [("src", 1000), (".cache-generated", 20000)]:
    for index in range(count):
        file = root / directory / str(index // 100) / f"file-{index}.ts"
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(f"export const value = {index};\n")
(root / "src/sample.ts").write_text("export const sample = 1;\n")
(root / ".gitignore").write_text(".cache-generated/\n")
for arguments in [
    ["init", "-q", "-b", "main"],
    ["config", "user.name", "VCode Performance"],
    ["config", "user.email", "perf@localhost"],
    ["config", "commit.gpgsign", "false"],
    ["add", "."],
    ["commit", "-qm", "baseline"],
]:
    subprocess.run(["git", "-C", str(root), *arguments], check=True, stdout=subprocess.DEVNULL)
(root / "src/sample.ts").write_text("export const sample = 2;\n")
print(root)
