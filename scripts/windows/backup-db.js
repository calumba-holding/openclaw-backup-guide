#!/usr/bin/env node
// Windows wrapper — runs the common backup-db.js
const path = require('path');
require(path.join(__dirname, '..', 'common', 'backup-db.js'));
