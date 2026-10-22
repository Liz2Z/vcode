# Local performance measurements

`python3 Tools/Performance/create_fixture.py` creates a fresh workspace containing 1,000 source files, a small changed file and 20,000 ignored cache files. It prints the absolute path. Generated fixtures stay under `.build/performance/`.

Run `python3 Tools/Performance/run.py <workspace> [source-path]` to compile an optimized benchmark and print JSON. The default source path is `src/sample.ts`. Existing workspaces can also be measured; the benchmark only reads their files and Git state. Git diff writes temporary comparison files outside the workspace.

The benchmark measures disk inventory, workspace construction/loading, repeated refresh, source and diff snapshots, and TypeScript styling/pane construction for approximately 300 KB. Each measurement reports three samples and their median. It does not measure cold disk I/O, application startup, first window paint, LSP startup or scroll frame rates. Run correctness tests separately; timing alone does not prove that the file list is complete.
