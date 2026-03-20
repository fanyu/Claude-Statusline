#!/usr/bin/env node

const { execSync } = require('child_process')
const path = require('path')
const os = require('os')

if (os.platform() === 'win32') {
  console.error('Error: claude-statusline is not supported on Windows.')
  process.exit(1)
}

const installScript = path.join(__dirname, '..', 'install.sh')

try {
  execSync(`bash "${installScript}"`, { stdio: 'inherit' })
} catch (e) {
  process.exit(e.status || 1)
}
