# Tidy 2.0 MVP (SwiftUI macOS)

## Run in Xcode
1. Generate Xcode project (P5): `xcodegen generate`.
2. Open `/Users/yihengli/Desktop/TA/访达/Tidy2.xcodeproj` in Xcode.
3. Select scheme `Tidy2` and run.
3. On first launch, click `授权 Downloads` in Digest page.
4. Click `运行 Autopilot` to execute duplicate scan + quarantine copy.

## Current MVP Scope
- Autopilot only handles duplicate files (SHA256 exact match) with `quarantineCopy`.
- Installer/temp cleanup is **not** automated and remains in Decision Bundles.
- Decision Bundle accept supports:
  - `rename` batch apply
  - `quarantine` batch copy apply (low-risk policy only)
  - `move` batch apply (requires archive root bookmark)
  - `skip` snooze to next week
- Decision evidence is structured (`EvidenceItem`) and supports source reveal from Bundle Detail.
- High-risk bundle move requires one-time override (`overrideRisk` journal row).
- Rules learning:
  - User override in Bundle Detail (`action/template/target`) will upsert a visible rule.
  - BundleBuilder applies enabled user rules before system defaults.
  - Rules can be enabled/disabled, deleted, and target folder can be re-selected.
- Digest metrics:
  - `Auto-isolated`: weekly **user** `quarantineCopy` count/bytes from bundle apply (not undone)
  - `Auto-organized`: weekly **user** `rename + move` count from bundle apply (not undone)
  - `Needs your decision`: pending bundles, capped at 5
- `Last applied` summary is generated from latest user txn journal rows.
- `Health` is driven by silent repair checks (`archive_root_health` + quarantine integrity).
- Low-noise nudge: Digest shows reminder only when pending bundles > 0 and last nudge >= 24h (`last_nudge_at`).
- FSEvents watcher listens to authorized `Downloads` + `Desktop` (if available), debounces 4s, and triggers incremental reindex.
- Quarantine restore copies one file back to original path (rename on conflict).
- Quarantine expiry/purge:
  - `active` + `expires_at <= now` -> `expired`
  - optional weekly auto purge (`auto_purge_expired_quarantine`, default OFF)
  - manual purge from Quarantine `Expired` tab
  - purge journal uses `action_type='purgeExpired'` and is marked not undoable
- Undo supports latest transaction for both autopilot and bundle apply.
- Indexing is startup incremental with watermark (`downloads_last_indexed_at`).

## P6 Release Engineering (Archive / Export / Verify / Package)
### Project / target
- Project config: `/Users/yihengli/Desktop/TA/访达/project.yml`
- Generated project: `/Users/yihengli/Desktop/TA/访达/Tidy2.xcodeproj`
- Entitlements: `/Users/yihengli/Desktop/TA/访达/Config/Tidy2.entitlements`

### Sandbox entitlements (minimum)
- `com.apple.security.app-sandbox = true`
- `com.apple.security.files.user-selected.read-write = true`
- No Full Disk Access entitlement is used.

### Before build (Xcode.app active developer dir)
1. Switch active developer dir:
   - `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`
2. Verify SDK list:
   - `xcodebuild -showsdks`

### Export options files
- Development export: `/Users/yihengli/Desktop/TA/访达/Config/ExportOptions_Development.plist`
- Developer ID export: `/Users/yihengli/Desktop/TA/访达/Config/ExportOptions_DeveloperID.plist`

### One-step command chain (Archive -> Export -> Verify -> Package)
```bash
cd /Users/yihengli/Desktop/TA/访达
./scripts/archive_beta.sh
EXPORT_METHOD=development ./scripts/export_beta.sh
./scripts/verify_app.sh
./scripts/package_beta.sh
```

### Script parameters (defaults)
- `SCHEME=Tidy2`
- `CONFIG=Release`
- `ARCHIVE_PATH=build/Tidy2.xcarchive`
- `EXPORT_PATH=build/export`

### Script responsibilities
- `scripts/archive_beta.sh`: run `xcodebuild archive`.
- `scripts/export_beta.sh`: run `xcodebuild -exportArchive` to produce `build/export/Tidy2.app`.
- `scripts/verify_app.sh`: run codesign/info/entitlements/spctl checks.
- `scripts/package_beta.sh`: package from `build/export/Tidy2.app` to zip/dmg.
- `scripts/notarize.sh` (optional): submit dmg to notarytool and staple.

### Output naming convention
- `dist/Tidy2_Beta_<version>_<build>_<yyyyMMdd>.zip`
- `dist/Tidy2_Beta_<version>_<build>_<yyyyMMdd>.dmg`
- DMG includes `Tidy2.app` + `Applications` shortcut.

### Manual Archive from Xcode
1. Open `Tidy2.xcodeproj`.
2. Select `Any Mac (Apple Silicon, Intel)`.
3. Product -> Archive.
4. Export `Developer ID` (or Development) app.

Note: This machine currently has Command Line Tools as active developer dir, so `xcodebuild archive/export` was not executed locally in this run.

### Verify checks
`./scripts/verify_app.sh` will print:
- `codesign -dv --verbose=4 <app>`
- `codesign --verify --deep --strict <app>`
- `plutil -p <app>/Contents/Info.plist`
- `codesign -d --entitlements :- <app>`
- `spctl --assess --type execute --verbose <app>`
- If `spctl` fails pre-notarization, script explains expected reason.

### Runtime self-check log
- On app launch, console prints runtime log file path:
  - `[Tidy2] runtime log: ...`
- Default log location:
  - `~/Library/Application Support/Tidy2/Logs/runtime.log`
- This helps beta users quickly send basic startup diagnostics.

## P5 Local Metrics
- New weekly metrics table: `metrics_weekly`.
- Digest has `Metrics` entry to view last 4 weeks.
- Metrics fields:
  - `weekly_confirm_count`: number of accepted bundle transactions (per week).
  - `files_per_confirm`: `confirmed_files_total / weekly_confirm_count`.
  - `undo_rate`: `undo_count / weekly_confirm_count`.
  - `autopilot_isolated_bytes`: weekly bytes from autopilot `quarantineCopy`.
  - `pending_bundles`: weekly pending snapshot.
  - `time_to_zero_inbox_proxy`: days from first run to first pending=0 snapshot.

## P5 Feedback Loop (Local-only)
- `Export Debug Bundle` in Digest:
  - outputs `Tidy2_Debug_<timestamp>.zip` to Desktop.
  - contains: anonymized journal, anonymized rules, settings health, recent 200 app events, version info.
  - no file content is exported.
- Path anonymization strategy:
  - `hash = SHA256(salt + "|" + standardized_lowercased_path)`
  - export `path_<first_16_hex>`.
  - salt is local-only setting key `debug_export_salt`.
- `Report an issue` in Digest:
  - copies a prefilled issue template to clipboard with app version, macOS, access health, latest txn id.

## 20-minute Beta Script
1. Install app (`.app` from `dist/`), launch.
2. Onboarding Step 1: authorize `Downloads`.
3. Onboarding Step 2: choose Archive Root (or skip).
4. Wait first-run autopilot + bundle generation.
5. Open one pending bundle, click `Accept` once.
6. Go back to Digest, verify Auto-organized/Auto-isolated changed.
7. Click `撤销上一次操作`.
8. Open `View change log`, confirm latest txn + undo state.
9. Open `Metrics`, confirm current-week row appears.
10. Click `Export Debug Bundle`, send zip to developer.

## Optional Notarization (Developer ID account required)
1. Build dmg first (`./scripts/package_beta.sh`).
2. Configure notarytool keychain profile in Xcode / CLI.
3. Run:
   - `NOTARY_PROFILE=<your_profile> ./scripts/notarize.sh`
4. Script will:
   - submit with `xcrun notarytool submit --wait`
   - staple with `xcrun stapler staple`
   - save JSON log to `build/notarytool_result.json`

## Known Limitations
- No OCR.
- No semantic/embedding retrieval.
- No cloud model integration (local-only processing).
- No full-disk scan (default scopes: Downloads + optional Desktop).
- `move` still requires explicit archive root authorization.
- Desktop monitoring requires explicit Desktop authorization.

## P2 Manual Test Scripts
1. FSEvents new-download refresh (no restart)
   - Keep app open on Digest.
   - Copy/create a new `pdf` file under `~/Downloads`.
   - Wait 4-6 seconds; open Bundles.
   - Expect: related weekly bundle count updates without relaunch.

2. Debounce under burst downloads
   - In Terminal run: `for i in {1..20}; do cp /etc/hosts ~/Downloads/test_$i.txt; done`
   - Keep app visible during writes.
   - Expect: UI stays responsive; one debounced refresh instead of 20 immediate scans.

3. Archive root bookmark invalidation + recovery
   - Set archive root in Bundle Detail.
   - Rename/move that folder in Finder so bookmark becomes invalid.
   - Wait weekly repair trigger (or relaunch, bootstrap runs checks).
   - Expect: Digest `Health` shows `Needs re-auth`.
   - Re-select archive root in Bundle Detail; expect `Health` returns to `Archive root access OK`.

4. Undo partial failure logging
   - Apply a bundle with move/quarantine producing multiple journal rows.
   - Before Undo, manually delete one destination file from Finder.
   - Click `撤销上一次操作`.
   - Expect: status message reports partial fail count; journal row accumulates `UNDO_FAILED` message.

5. High-risk override move + undo
   - Create a bundle containing filename with token like `passport` or `ssn`.
   - In Bundle Detail switch to `move`, enable `本次仍允许 move`.
   - Apply and then run Undo.
   - Expect: move succeeds, journal contains `overrideRisk` + move rows; Undo returns files and marks txn undone.

6. Restart consistency
   - Run autopilot and one bundle apply.
   - Quit and reopen app.
   - Expect: Digest counts, pending bundles (<=5), quarantine list, and change log remain consistent with journal state.

## P3 Manual Test Scripts
1. Rule generation on user override
   - Open a pending bundle in Bundle Detail.
   - Change action/template/target and click `Edit once then accept`.
   - Open `Settings/Rules`.
   - Expect: a new/updated rule appears with matching condition + action.

2. Rule hit and disable behavior
   - Keep one matching bundle type in current week.
   - Ensure rule is enabled; trigger bundle rebuild (run autopilot or add file).
   - Expect: bundle action is prefilled by rule and evidence contains `Matched your rule`.
   - Disable the same rule and rebuild again; expect default system suggestion returns.

3. Edit rule target folder
   - In `Settings/Rules`, click `Edit target folder` for a move rule.
   - Rebuild bundles and apply matching bundle with move.
   - Expect: files move to newly selected target path.

4. Auto purge switch
   - Open Quarantine page and enable `每周自动清理过期项`.
   - Confirm setting persists after app restart.
   - Expect: toggle remains ON and weekly repair path can execute purge (when expired items exist).

5. Expired visibility and manual purge
   - Create/prepare expired quarantine items (set `expires_at` in DB or wait policy).
   - Open Quarantine `Expired` tab.
   - Expect: expired items listed; click `清理所有过期项` removes files and updates state.

6. Purge event logging
   - After manual or weekly purge, open `View change log`.
   - Expect: row `Purged N expired items` appears and displays `Not undoable`.

## P4 Manual Test Scripts
1. Downloads access loss and one-click recovery
   - Remove/clear `authorized_roots` record for `downloads` (or run with invalid bookmark).
   - Open app; Digest Health should show Downloads needs auth.
   - Click `Re-authorize Downloads` and select `~/Downloads`.
   - Expect: health returns to OK and autopilot can run.

2. Archive root re-auth flow
   - Set archive root, then move/rename that folder in Finder.
   - Trigger any move bundle apply; expect actionable error with re-auth hint.
   - In Digest Health click `Re-authorize Archive Root`.
   - Expect: move apply works again, health status no longer denied/missing.

3. Enable Desktop optional scope
   - Start with only Downloads authorized.
   - Click `Enable Desktop` in Digest Health and select `~/Desktop`.
   - Create files on Desktop and wait debounce window.
   - Expect: Desktop bundles appear without app restart.

4. New rule learned nudge + disable
   - Apply a bundle with override action/template/target to learn rule.
   - Return to Digest.
   - Expect: banner `New rule learned: ... (Disable)` appears once.
   - Click `Disable`; rule becomes disabled in Rules list.

5. Rule dry-run preview (SQL match)
   - Open `Settings/Rules`.
   - Click `Dry-run preview` on a rule.
   - Expect: list shows up to 5 currently pending bundles that would match.

6. Emergency brake
   - In RulesView turn ON `Emergency brake: disable all rules`.
   - Trigger reindex (new file or autopilot).
   - Expect: bundle actions fallback to system defaults, not learned rules.
   - Turn OFF and verify learned actions return.

7. Storm mode entry
   - In Terminal, create many nested directories quickly under Downloads (target >200 dir changes in 10s).
   - Expect Digest Health shows `High activity detected; will resync soon.` and immediate rebuild is paused.

8. Storm mode recovery resync
   - After storm mode trigger, wait ~30 seconds.
   - Expect one consolidated incremental resync runs, bundles/digest refresh once, storm hint disappears.

9. Consistency checker + repair
   - Manually delete several indexed originals and several quarantine files in Finder.
   - Click `Run repair now` in Digest Health.
   - Expect Digest updates: `Missing originals` and `Missing quarantine files` counts reflect real state.

10. Purge safety and audit trail
   - Ensure expired quarantine items exist.
   - Trigger `清理所有过期项`.
   - Validate only files under app quarantine root are removed.
   - Open change log; expect `Purged ... expired items` entry with `Not undoable` and audit details in journal rows.

## Sandbox and permission details
- App uses security-scoped bookmark for `Downloads`.
- Current Swift Package build can run without explicit Xcode entitlements file.
- For full sandboxed app distribution, use an `.xcodeproj` target and add:
  - `com.apple.security.app-sandbox = true`
  - `com.apple.security.files.user-selected.read-write = true`
