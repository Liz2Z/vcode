#!/usr/bin/env python3
"""Build an optimized benchmark and run against a supplied read-only workspace."""
from pathlib import Path
import subprocess
import sys

repo = Path(__file__).resolve().parents[2]
binary = repo / ".build/performance/benchmark"
binary.parent.mkdir(parents=True, exist_ok=True)
sources = sorted(p for p in (repo / "Sources/VCode").rglob("*.swift") if p.name != "App.swift")
subprocess.run(["swiftc", "-O", "-parse-as-library", *map(str, sources), str(Path(__file__).with_name("Benchmark.swift")), "-o", str(binary)], check=True)
subprocess.run([str(binary), *sys.argv[1:]], check=True)
