#!/usr/bin/env node
// Linux wrapper — just runs the common backup-db.js
// This exists so the directory structure is intuitive.
// All the logic lives in scripts/common/backup-db.js

const path = require('path');
require(path.join(__dirname, '..', 'common', 'backup-db.js'));
