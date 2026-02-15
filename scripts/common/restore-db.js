#!/usr/bin/env node
// =============================================================================
// OpenClaw SQLite Restore
// =============================================================================
// Restores SQLite databases from backup. Stops OpenClaw first, replaces the
// database files, then optionally restarts.
//
// Usage:
//   node restore-db.js                    # Restore latest backup
//   node restore-db.js --list             # List available snapshots
//   node restore-db.js --snapshot <name>  # Restore specific snapshot
//   node restore-db.js --dry-run          # Show what would happen
// =============================================================================

const path = require('path');
const fs = require('fs');
const { execSync } = require('child_process');

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------
const OPENCLAW_HOME = process.env.OPENCLAW_HOME || path.join(process.env.HOME, '.openclaw');
const BACKUP_DIR = process.env.BACKUP_DIR || path.join(process.env.HOME, 'backups', 'openclaw');

// ---------------------------------------------------------------------------
// Argument parsing
// ---------------------------------------------------------------------------
const args = process.argv.slice(2);
const DRY_RUN = args.includes('--dry-run');
const LIST = args.includes('--list');
const snapshotIdx = args.indexOf('--snapshot');
const SNAPSHOT = snapshotIdx >= 0 ? args[snapshotIdx + 1] : null;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
function log(msg) {
  console.log(`[${new Date().toISOString()}] ${msg}`);
}

function findSqliteDbs(dir) {
  const dbs = [];
  if (!fs.existsSync(dir)) return dbs;
  const entries = fs.readdirSync(dir, { withFileTypes: true });
  for (const entry of entries) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory() && entry.name !== 'node_modules' && entry.name !== '.git') {
      dbs.push(...findSqliteDbs(full));
    } else if (
      entry.name.endsWith('.db') ||
      entry.name.endsWith('.sqlite') ||
      entry.name.endsWith('.sqlite3')
    ) {
      dbs.push(full);
    }
  }
  return dbs;
}

function listSnapshots() {
  const snapshotBase = path.join(BACKUP_DIR, 'db-snapshots');
  if (!fs.existsSync(snapshotBase)) {
    console.log('No snapshots found.');
    return [];
  }
  const dirs = fs.readdirSync(snapshotBase, { withFileTypes: true })
    .filter(d => d.isDirectory())
    .map(d => d.name)
    .sort()
    .reverse();

  if (dirs.length === 0) {
    console.log('No snapshots found.');
    return [];
  }

  console.log('Available snapshots:');
  for (const dir of dirs) {
    const files = fs.readdirSync(path.join(snapshotBase, dir));
    console.log(`  ${dir}  (${files.length} file(s): ${files.join(', ')})`);
  }
  return dirs;
}

function stopOpenclaw() {
  log('Stopping OpenClaw...');
  try {
    execSync('openclaw gateway stop', { timeout: 30000, stdio: 'pipe' });
    log('OpenClaw stopped.');
  } catch (_) {
    log('Could not stop OpenClaw (may not be running). Continuing...');
  }
}

function startOpenclaw() {
  log('Starting OpenClaw...');
  try {
    execSync('openclaw gateway start', { timeout: 30000, stdio: 'pipe' });
    log('OpenClaw started.');
  } catch (_) {
    log('Could not start OpenClaw. You may need to start it manually.');
  }
}

function verifyDb(dbPath) {
  try {
    const result = execSync(`sqlite3 "${dbPath}" "PRAGMA integrity_check;"`, {
      timeout: 60000,
      encoding: 'utf-8',
    }).trim();
    return result === 'ok';
  } catch (_) {
    return false;
  }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
function main() {
  if (LIST) {
    listSnapshots();
    process.exit(0);
  }

  // Determine source directory
  let sourceDir;
  if (SNAPSHOT) {
    sourceDir = path.join(BACKUP_DIR, 'db-snapshots', SNAPSHOT);
    if (!fs.existsSync(sourceDir)) {
      log(`Snapshot not found: ${SNAPSHOT}`);
      log('Use --list to see available snapshots.');
      process.exit(1);
    }
  } else {
    sourceDir = path.join(BACKUP_DIR, 'db');
    if (!fs.existsSync(sourceDir)) {
      log(`No backup directory found at ${sourceDir}`);
      process.exit(1);
    }
  }

  // Find backup files
  const backupFiles = fs.readdirSync(sourceDir).filter(f =>
    f.endsWith('.db') || f.endsWith('.sqlite') || f.endsWith('.sqlite3')
  );

  if (backupFiles.length === 0) {
    log(`No database files found in ${sourceDir}`);
    process.exit(1);
  }

  // Find target databases
  const targetDbs = findSqliteDbs(OPENCLAW_HOME);
  const targetMap = {};
  for (const t of targetDbs) {
    targetMap[path.basename(t)] = t;
  }

  log(`Source: ${sourceDir}`);
  log(`Target: ${OPENCLAW_HOME}`);
  log(`Files to restore: ${backupFiles.join(', ')}`);
  log('');

  // Verify backup integrity before restoring
  log('Verifying backup integrity...');
  for (const file of backupFiles) {
    const srcPath = path.join(sourceDir, file);
    const ok = verifyDb(srcPath);
    if (!ok) {
      log(`✗ INTEGRITY CHECK FAILED: ${file} — aborting restore!`);
      process.exit(1);
    }
    log(`✓ ${file} — integrity OK`);
  }

  if (DRY_RUN) {
    log('');
    log('DRY RUN — would perform these actions:');
    for (const file of backupFiles) {
      const target = targetMap[file];
      if (target) {
        log(`  RESTORE: ${path.join(sourceDir, file)} → ${target}`);
      } else {
        log(`  COPY: ${path.join(sourceDir, file)} → ${path.join(OPENCLAW_HOME, file)} (new)`);
      }
    }
    log('  STOP OpenClaw before restore');
    log('  START OpenClaw after restore');
    process.exit(0);
  }

  // Stop OpenClaw
  stopOpenclaw();

  // Restore each database
  let failures = 0;
  for (const file of backupFiles) {
    const srcPath = path.join(sourceDir, file);
    const targetPath = targetMap[file] || path.join(OPENCLAW_HOME, file);

    try {
      // Create a backup of the current (possibly corrupted) file
      if (fs.existsSync(targetPath)) {
        const preRestorePath = targetPath + '.pre-restore';
        fs.copyFileSync(targetPath, preRestorePath);
        log(`Saved current ${file} as ${path.basename(preRestorePath)}`);
      }

      // Restore
      fs.copyFileSync(srcPath, targetPath);
      const size = fs.statSync(targetPath).size;
      log(`✓ Restored ${file} (${(size / 1024).toFixed(1)} KB)`);

      // Remove WAL and SHM files (stale journal files cause issues)
      for (const suffix of ['-wal', '-shm', '-journal']) {
        const journalPath = targetPath + suffix;
        if (fs.existsSync(journalPath)) {
          fs.unlinkSync(journalPath);
          log(`  Removed stale ${file}${suffix}`);
        }
      }
    } catch (err) {
      log(`✗ FAILED to restore ${file}: ${err.message}`);
      failures++;
    }
  }

  // Restart OpenClaw
  startOpenclaw();

  log('');
  log(`Restore complete. ${backupFiles.length - failures}/${backupFiles.length} succeeded.`);

  if (failures > 0) {
    process.exit(1);
  }
}

main();
