#!/usr/bin/env node
// =============================================================================
// OpenClaw SQLite Safe Backup
// =============================================================================
// Creates a safe snapshot of SQLite databases using the .backup() API.
// NEVER just copy a SQLite file while it's in use — you'll get corruption.
// This script does it right.
//
// Usage: node backup-db.js
// Config: Set env vars or use .env file
// =============================================================================

const path = require('path');
const fs = require('fs');
const { execSync } = require('child_process');

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------
const OPENCLAW_HOME = process.env.OPENCLAW_HOME || path.join(process.env.HOME, '.openclaw');
const BACKUP_DIR = process.env.BACKUP_DIR || path.join(process.env.HOME, 'backups', 'openclaw');
const LOG_DIR = process.env.LOG_DIR || path.join(process.env.HOME, 'logs', 'openclaw-backup');

// How many timestamped snapshots to keep (0 = don't keep timestamped copies)
const KEEP_SNAPSHOTS = parseInt(process.env.DB_KEEP_SNAPSHOTS || '5', 10);

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
function ensureDir(dir) {
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
  }
}

function log(msg) {
  const ts = new Date().toISOString();
  const line = `[${ts}] ${msg}`;
  console.log(line);
  try {
    ensureDir(LOG_DIR);
    fs.appendFileSync(path.join(LOG_DIR, 'backup-db.log'), line + '\n');
  } catch (_) {
    // Logging failure shouldn't kill the backup
  }
}

function findSqliteDbs(dir) {
  const dbs = [];
  if (!fs.existsSync(dir)) return dbs;

  const entries = fs.readdirSync(dir, { withFileTypes: true });
  for (const entry of entries) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      // Recurse but skip node_modules and .git
      if (entry.name !== 'node_modules' && entry.name !== '.git') {
        dbs.push(...findSqliteDbs(full));
      }
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

function backupSqlite(dbPath, destDir) {
  const dbName = path.basename(dbPath);
  const destPath = path.join(destDir, dbName);

  // Use sqlite3 CLI's .backup command for a safe online backup
  // This uses SQLite's backup API internally — safe even with concurrent writes
  try {
    execSync(`sqlite3 "${dbPath}" ".backup '${destPath}'"`, {
      timeout: 60000,
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    return destPath;
  } catch (err) {
    // Fallback: try using the VACUUM INTO command (SQLite 3.27+)
    try {
      execSync(`sqlite3 "${dbPath}" "VACUUM INTO '${destPath}';"`, {
        timeout: 120000,
        stdio: ['pipe', 'pipe', 'pipe'],
      });
      return destPath;
    } catch (err2) {
      throw new Error(`Failed to backup ${dbPath}: ${err2.message}`);
    }
  }
}

function pruneSnapshots(snapshotDir, keep) {
  if (keep <= 0 || !fs.existsSync(snapshotDir)) return;

  const dirs = fs.readdirSync(snapshotDir, { withFileTypes: true })
    .filter(d => d.isDirectory() && /^\d{4}-\d{2}-\d{2}T/.test(d.name))
    .map(d => d.name)
    .sort()
    .reverse();

  const toRemove = dirs.slice(keep);
  for (const dir of toRemove) {
    const full = path.join(snapshotDir, dir);
    fs.rmSync(full, { recursive: true, force: true });
    log(`Pruned old snapshot: ${dir}`);
  }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
function main() {
  log('Starting SQLite backup...');

  // Find all SQLite databases
  const dbs = findSqliteDbs(OPENCLAW_HOME);
  if (dbs.length === 0) {
    log(`No SQLite databases found in ${OPENCLAW_HOME}`);
    log('Check that OPENCLAW_HOME is set correctly.');
    process.exit(0);
  }

  log(`Found ${dbs.length} database(s): ${dbs.map(d => path.basename(d)).join(', ')}`);

  // Create backup destination
  const dbBackupDir = path.join(BACKUP_DIR, 'db');
  ensureDir(dbBackupDir);

  // Also create a timestamped snapshot
  const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
  const snapshotDir = path.join(BACKUP_DIR, 'db-snapshots', timestamp);
  if (KEEP_SNAPSHOTS > 0) {
    ensureDir(snapshotDir);
  }

  let failures = 0;

  for (const dbPath of dbs) {
    const dbName = path.basename(dbPath);
    try {
      // Latest backup (overwritten each time — for git commits)
      const dest = backupSqlite(dbPath, dbBackupDir);
      const size = fs.statSync(dest).size;
      log(`✓ ${dbName} → ${dest} (${(size / 1024).toFixed(1)} KB)`);

      // Timestamped snapshot
      if (KEEP_SNAPSHOTS > 0) {
        fs.copyFileSync(dest, path.join(snapshotDir, dbName));
      }
    } catch (err) {
      log(`✗ FAILED: ${dbName} — ${err.message}`);
      failures++;
    }
  }

  // Prune old snapshots
  if (KEEP_SNAPSHOTS > 0) {
    pruneSnapshots(path.join(BACKUP_DIR, 'db-snapshots'), KEEP_SNAPSHOTS);
  }

  log(`Backup complete. ${dbs.length - failures}/${dbs.length} succeeded.`);

  if (failures > 0) {
    process.exit(1);
  }
}

main();
