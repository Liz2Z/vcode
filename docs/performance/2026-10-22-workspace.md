# Workspace loading and diff performance

## Measurement

Measured on Apple M4, macOS 26.3, optimized Swift compilation. The same synthetic Git workspace contains 1,002 visible files and 20,000 ignored cache files, with one modified TypeScript file. Values below are medians of three local warm-cache samples. Original and optimized runs returned identical file/change counts and snapshot sizes. These are core operation timings, not end-to-end application startup or first window paint.

| Operation | Before | After |
| --- | ---: | ---: |
| Full raw disk inventory, including cache files | 525 ms | 102 ms |
| Construct and load workspace | 1,373 ms | 55 ms |
| Reload existing workspace | 1,115 ms | 30 ms |
| Read repeated small diff | 349 ms | 20 ms |
| Style approximately 300 KB of TypeScript | 50 ms | 49 ms |
| Construct its code pane | 56 ms | 57 ms |

The first optimized diff sample was slower than repeat reads; the median includes the benefit of reusing an unchanged comparison. Source snapshots were already under 1 ms. Styling/render preparation showed no material improvement and was left unchanged.

## Changes and constraints

- Files are still enumerated from disk. Git supplies ignored paths and collapses ignored, untracked directories before traversal, using its own ignore engine. Directories containing tracked exceptions remain traversable. No index/status path list is substituted for the disk inventory.
- Resolve the physical root prefix once, rather than resolving symlinks for every file. Account for macOS returning `/private/var` enumerator URLs for `/var` roots. Symbolic links are listed, not traversed.
- Call `skipDescendants()` only for real directories. Calling it on `.DS_Store`, a worktree's regular `.git` marker, or a link could hide the next real directory. The user's actual `zan-cli` scan reproduces the old missing `auth/` directory and now returns all 18 source files under it.
- One porcelain-v2 status query supplies branch, initial-commit state and changes. Paths containing whitespace, Unicode or line breaks retain NUL framing; staged/unstaged, rename and conflict semantics remain separate.
- Batch object-size/missing checks remove a redundant Git query while keeping the content-size limit before reading data. Empty and missing files remain distinguishable from command errors.
- A process termination notification replaces `waitUntilExit()` polling. A separate five-sample probe measured about 66–72 ms of avoidable waiting per Git command, after its output was already read. The 20-second timeout remains in place.
- Reuse at most one diff snapshot with at most 1 MiB of source content. Both versions are read again before reuse; content, path and comparison must match. This avoids stale data from timestamps, index changes, branch changes or staged/unstaged switching.

## Reproduction and correctness

`Tools/Performance/README.md` documents the reusable benchmark and fresh-fixture generator. Raw timing JSON and local probe logs are under `.build/performance/`.

Correctness and real-window results are recorded after the final frozen build. Performance changes must not hide files, mix comparison versions, eagerly materialize collapsed tree nodes or change text rendering. The missing-directory regression fails on the original enumerator and covers regular ignore markers, links and adjacent directories.

## Final checks and limits

104 automated tests passed with no failures, covering missing-directory recovery, ignored tracked exceptions, changed ignore rules, branch/worktree switching, initial and detached Git states, staged/unstaged versions, conflicts, content size limits, Unicode/newline paths and diff cache invalidation. A fresh generated fixture reproduced the expected 1,002 visible files and one change. Release build and signature checks passed.

A separate read-only run against the user's actual `~/Code/zan-cli` reported 537 visible files: workspace construction/load 97 ms, refresh 41 ms and repeated small diff 10 ms. Its repository state can change independently; these values have no measured pre-change counterpart and are not used to claim a speedup. The actual auth directory and all 18 sources appear in the raw inventory, workspace state and tree index.

The isolated application with that workspace open and no source tabs used about 79 MiB RSS; ten one-second ps samples each reported 0.0% CPU. This excludes a running TypeScript language service and is not a before/after memory comparison.

Actual window checks remain **需要用户验证**: macOS was locked and rejected the first UI inspection. No repeated attempts were made; the user was asked once to unlock. Source, test and benchmark hashes remain identical to the frozen build. Local evidence and the pending UI status are recorded in `.build/performance/ui/result.json`.

## Native verification resumed on 2026-10-23

After the user unlocked macOS, the unchanged isolated release build was checked against the actual zan-cli repository. Clicking through packages → idev-cli → src → auth reveals the 15 direct source files and sites folder; sites expands to garden.ts, ops.ts and xiaolv.ts. Clicking auth/request.ts renders its complete source with TypeScript Ready. Manual Refresh preserves both expanded folders and reading content.

Files/Changes switching and filtering respond. The new auth/request.ts diff has empty INDEX content on the left and 56 added lines on the right. Refresh keeps these versions. The deleted qima-login/request.ts remains in Changes with 147 removed lines on the left and an empty working tree on the right; Files filtered results exclude it. Returning through the source tab restores auth/request.ts as a single pane with TypeScript Ready.

One separate operation remains **需要用户验证**: following a user/window control interruption, automation clicks on filtered file rows did not change selection or content. Raising the window and pressing the source tab worked, but that does not prove filtered row clicking works. The user was asked once to test it; no product or test code was changed, and no repeated attempts are planned without new evidence. Automation paste also did not insert filter text; typing did, so clipboard behavior is not claimed as verified.

Screenshot/AX evidence and itemized results are under `.build/performance/ui/2026-10-23/`. Frozen source/test/tool fingerprints still match exactly.

## User-confirmed UI failure, 2026-10-23

The user confirmed filtered file-row clicks fail in the application. Resizing the sidebar and switching to Changes and back to Files restores clicking. This supersedes the earlier “tool versus product unresolved” classification: it is a user-verified product failure. The UI acceptance run is **not passed**. Performance improvements and previously passed cases remain recorded separately. No product or test code was changed during UI acceptance; AGENTS.md requires a separate explicit repair instruction before implementation continues.

## Filtered-row repair verified, 2026-10-23

The user explicitly authorized repair after confirming the application failure. A diagnostic build reproduced correct mouse-down delivery with no native file-row selection after the Changes/Files roundtrip. File and folder rows now use explicit selection on press and guarded activation on release; refresh cancels old presses. The latest fixed release passed all 106 tests. In the real zan-cli workspace, the failing sequence now opens auth/request.ts directly without resizing; other matching files, already-open files, refresh, re-filtering and a narrowed sidebar also passed. This closes the earlier filtered-row acceptance failure; historical failed results above remain unchanged.

No source or test files changed during final native acceptance (81 frozen fingerprints matched). Package signature and release UUID checks passed. Current itemized evidence is `.build/diagnostics/filter-click/result.json`. This was a focused repair verification, not a repeat of every unrelated UI requirement.
