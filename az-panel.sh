#!/usr/bin/env bash
# ============================================================================
#  KINGCLOUD INSTALLER  -  AZ PANEL INSTALLER
#  Installs AZ PANEL, a Minecraft server management panel.
#  Single self-contained file. Safe to re-run (install/update/uninstall).
# ============================================================================
set -u
set -o pipefail

# ---------------------------------------------------------------------------
# Configuration (override via environment before running if you want)
# ---------------------------------------------------------------------------
APP_DIR="${AZ_PANEL_DIR:-/opt/az-panel}"
DATA_DIR="$APP_DIR/data"
CONFIG_DIR="$APP_DIR/config"
CONF_D="$CONFIG_DIR/conf.d"
LOG_DIR="$DATA_DIR/logs"
ENV_FILE="$APP_DIR/.env"
CLI_LINK="/usr/local/bin/azpanel"
PANEL_PORT_DEFAULT=8080
SUPERVISOR_SOCK="$CONFIG_DIR/supervisor.sock"
SUPERVISOR_CONF="$CONFIG_DIR/supervisord.conf"
NODE_MIN_MAJOR=18

# ---------------------------------------------------------------------------
# Colors / logging
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
  C_RESET='\033[0m'; C_BOLD='\033[1m'
  C_BLUE='\033[38;5;69m'; C_CYAN='\033[38;5;51m'; C_GREEN='\033[38;5;83m'
  C_YELLOW='\033[38;5;220m'; C_RED='\033[38;5;203m'; C_GREY='\033[38;5;245m'
  C_MAGENTA='\033[38;5;171m'
else
  C_RESET=''; C_BOLD=''; C_BLUE=''; C_CYAN=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_GREY=''; C_MAGENTA=''
fi

log_info()  { printf "${C_BLUE}[INFO]${C_RESET}  %s\n" "$*"; }
log_ok()    { printf "${C_GREEN}[OK]${C_RESET}    %s\n" "$*"; }
log_warn()  { printf "${C_YELLOW}[WARN]${C_RESET}  %s\n" "$*"; }
log_error() { printf "${C_RED}[ERROR]${C_RESET} %s\n" "$*" >&2; }
log_step()  { printf "\n${C_MAGENTA}${C_BOLD}==>${C_RESET} ${C_BOLD}%s${C_RESET}\n" "$*"; }

print_banner() {
  printf "${C_CYAN}"
  cat <<'BANNER'
  ██╗  ██╗██╗███╗   ██╗ ██████╗  ██████╗██╗      ██████╗ ██╗   ██╗██████╗
  ██║ ██╔╝██║████╗  ██║██╔════╝ ██╔════╝██║     ██╔═══██╗██║   ██║██╔══██╗
  █████╔╝ ██║██╔██╗ ██║██║  ███╗██║     ██║     ██║   ██║██║   ██║██║  ██║
  ██╔═██╗ ██║██║╚██╗██║██║   ██║██║     ██║     ██║   ██║██║   ██║██║  ██║
  ██║  ██╗██║██║ ╚████║╚██████╔╝╚██████╗███████╗╚██████╔╝╚██████╔╝██████╔╝
  ╚═╝  ╚═╝╚═╝╚═╝  ╚═══╝ ╚═════╝  ╚═════╝╚══════╝ ╚═════╝  ╚═════╝ ╚═════╝
BANNER
  printf "${C_RESET}"
  printf "                        ${C_BOLD}KINGCLOUD${C_RESET}\n"
  printf "                     ${C_GREY}AZ PANEL INSTALLER${C_RESET}\n\n"
}

die() { log_error "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Environment detection
# ---------------------------------------------------------------------------
require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    die "This installer must be run as root (try: sudo ./az-panel.sh)"
  fi
}

detect_os() {
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VERSION="${VERSION_ID:-unknown}"
  else
    OS_ID="unknown"
    OS_VERSION="unknown"
  fi
  case "$OS_ID" in
    debian|ubuntu) ;;
    *)
      log_error "Unsupported OS detected: $OS_ID $OS_VERSION"
      log_error "AZ PANEL currently supports Debian and Ubuntu only."
      exit 1
      ;;
  esac
  log_ok "Detected OS: $OS_ID $OS_VERSION"
}

detect_arch() {
  ARCH_RAW="$(uname -m)"
  case "$ARCH_RAW" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) die "Unsupported CPU architecture: $ARCH_RAW" ;;
  esac
  log_ok "Detected architecture: $ARCH_RAW ($ARCH)"
}

detect_init() {
  local pid1
  pid1="$(ps -p 1 -o comm= 2>/dev/null || echo unknown)"
  if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    HAS_SYSTEMD=1
    log_info "systemd appears to be present on this host (PID 1: $pid1)."
    log_info "AZ PANEL does not use systemd regardless - it manages its own"
    log_info "processes with PM2 (panel) and supervisord (Minecraft servers)."
  else
    HAS_SYSTEMD=0
    log_info "Non-systemd PID 1 detected (PID 1: $pid1)."
    log_info "AZ PANEL will use userspace process supervision."
    log_ok "systemd is not required."
  fi
}

detect_pkg_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_MANAGER="apt"
  else
    die "No supported package manager found (expected apt-get)."
  fi
}

apt_install() {
  # Installs only the packages that are actually missing.
  local to_install=()
  local pkg
  for pkg in "$@"; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
      to_install+=("$pkg")
    fi
  done
  if [ "${#to_install[@]}" -eq 0 ]; then
    log_ok "All requested packages already installed: $*"
    return 0
  fi
  log_info "Installing packages: ${to_install[*]}"
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${to_install[@]}" \
    || die "apt-get install failed for: ${to_install[*]}"
  log_ok "Installed: ${to_install[*]}"
}

apt_update_once() {
  if [ "${AZPANEL_APT_UPDATED:-0}" != "1" ]; then
    log_info "Refreshing package index (apt-get update)..."
    apt-get update -y || die "apt-get update failed"
    AZPANEL_APT_UPDATED=1
    log_ok "Package index refreshed."
  fi
}

install_base_dependencies() {
  log_step "Checking base dependencies"
  apt_update_once
  apt_install curl wget git ca-certificates unzip tar jq openssl gnupg
}

install_nodejs() {
  log_step "Checking Node.js"
  if command -v node >/dev/null 2>&1; then
    local major
    major="$(node -v | sed 's/^v//' | cut -d. -f1)"
    if [ "$major" -ge "$NODE_MIN_MAJOR" ] 2>/dev/null; then
      log_ok "Node.js already installed: $(node -v)"
      return 0
    fi
    log_warn "Installed Node.js ($(node -v)) is older than required (v${NODE_MIN_MAJOR}+). Upgrading."
  else
    log_info "Node.js not found. Installing..."
  fi
  apt_update_once
  curl -fsSL https://deb.nodesource.com/setup_20.x -o /tmp/nodesource_setup.sh \
    || die "Failed to download the Node.js setup script (no network?)"
  bash /tmp/nodesource_setup.sh || die "NodeSource setup script failed"
  apt_install nodejs
  command -v node >/dev/null 2>&1 || die "Node.js installation appears to have failed"
  log_ok "Node.js installed: $(node -v)"
  log_ok "npm installed: $(npm -v)"
}

install_java() {
  log_step "Checking Java"
  if command -v java >/dev/null 2>&1; then
    # `java -version` writes to stderr, not stdout - capture both.
    local ver
    ver="$(java -version 2>&1 | head -n1)"
    log_ok "Java already installed: $ver"
    return 0
  fi
  log_info "Java not found. Installing OpenJDK..."
  apt_update_once
  apt_install openjdk-21-jre-headless || apt_install default-jre-headless \
    || die "Failed to install a Java runtime"
  command -v java >/dev/null 2>&1 || die "Java installation appears to have failed"
  log_ok "Java installed: $(java -version 2>&1 | head -n1)"
}

install_supervisor() {
  log_step "Checking supervisord (userspace process supervisor)"
  if command -v supervisord >/dev/null 2>&1; then
    log_ok "supervisord already installed: $(supervisord -v 2>/dev/null || echo present)"
    return 0
  fi
  apt_update_once
  apt_install supervisor
  command -v supervisord >/dev/null 2>&1 || die "supervisord installation appears to have failed"
  log_ok "supervisord installed."
  log_info "Note: AZ PANEL runs supervisord directly with its own config;"
  log_info "it does not use any systemd/init.d unit that the package may ship."
}

install_pm2() {
  log_step "Checking PM2 (panel process manager - no systemd)"
  if command -v pm2 >/dev/null 2>&1; then
    log_ok "PM2 already installed: $(pm2 -v)"
    return 0
  fi
  log_info "Installing PM2 globally via npm..."
  npm install -g pm2 || die "Failed to install PM2"
  command -v pm2 >/dev/null 2>&1 || die "PM2 installation appears to have failed"
  log_ok "PM2 installed: $(pm2 -v)"
}
# ---------------------------------------------------------------------------
# Application file generation (embedded from the AZ PANEL source tree)
# ---------------------------------------------------------------------------
generate_app_files() {
  log_step "Generating AZ PANEL application files in $APP_DIR"
  mkdir -p "$APP_DIR/lib" "$APP_DIR/bin" "$APP_DIR/public" "$DATA_DIR/logs" "$DATA_DIR/servers" "$DATA_DIR/db" "$DATA_DIR/backups" "$CONFIG_DIR/conf.d"

  cat > "$APP_DIR/package.json" <<'AZPANEL_FILE_EOF_PACKAGE_JSON'
{
  "name": "az-panel",
  "version": "1.0.0",
  "description": "AZ PANEL - Minecraft server management panel",
  "private": true,
  "main": "server.js",
  "scripts": {
    "start": "node server.js"
  },
  "engines": {
    "node": ">=18.0.0"
  },
  "dependencies": {
    "express": "^4.19.2",
    "helmet": "^7.1.0",
    "express-rate-limit": "^7.4.0",
    "cookie-parser": "^1.4.6",
    "bcryptjs": "^2.4.3",
    "jsonwebtoken": "^9.0.2",
    "dotenv": "^16.4.5",
    "ws": "^8.18.0"
  }
}
AZPANEL_FILE_EOF_PACKAGE_JSON

  cat > "$APP_DIR/ecosystem.config.js" <<'AZPANEL_FILE_EOF_ECOSYSTEM_CONFIG_JS'
module.exports = {
  apps: [
    {
      name: 'az-panel',
      script: 'server.js',
      cwd: __dirname,
      instances: 1,
      exec_mode: 'fork',
      autorestart: true,
      max_restarts: 10,
      restart_delay: 3000,
      watch: false,
      env: {
        NODE_ENV: 'production',
      },
      out_file: './data/logs/panel-out.log',
      error_file: './data/logs/panel-error.log',
      merge_logs: true,
      time: true,
    },
  ],
};
AZPANEL_FILE_EOF_ECOSYSTEM_CONFIG_JS

  cat > "$APP_DIR/server.js" <<'AZPANEL_FILE_EOF_SERVER_JS'
'use strict';
/**
 * AZ PANEL - server.js
 * Main entrypoint. Run via PM2 (see ecosystem.config.js) - no systemd.
 */

require('dotenv').config({ path: require('path').join(__dirname, '.env') });

const path = require('path');
const http = require('http');
const express = require('express');
const helmet = require('helmet');
const rateLimit = require('express-rate-limit');
const cookieParser = require('cookie-parser');
const { WebSocketServer } = require('ws');

const auth = require('./lib/auth');
const mc = require('./lib/mc');
const system = require('./lib/system');
const { DATA_DIR } = require('./lib/db');

const PORT = Number(process.env.PORT || 8080);
const HOST = process.env.HOST || '0.0.0.0';
const APP_NAME = 'AZ PANEL';

const app = express();
app.disable('x-powered-by');
app.set('trust proxy', 1);

app.use(
  helmet({
    contentSecurityPolicy: {
      directives: {
        defaultSrc: ["'self'"],
        scriptSrc: ["'self'"],
        styleSrc: ["'self'", "'unsafe-inline'"],
        imgSrc: ["'self'", 'data:'],
        connectSrc: ["'self'"],
      },
    },
  }),
);
app.use(express.json({ limit: '256kb' }));
app.use(cookieParser());
app.use(express.static(path.join(__dirname, 'public')));

// ---------------- rate limiting ----------------
const apiLimiter = rateLimit({ windowMs: 60 * 1000, max: 120, standardHeaders: true, legacyHeaders: false });
const loginLimiter = rateLimit({ windowMs: 10 * 60 * 1000, max: 30, standardHeaders: true, legacyHeaders: false });
app.use('/api/', apiLimiter);

function clientIp(req) {
  return req.ip || (req.connection && req.connection.remoteAddress) || 'unknown';
}

// ---------------- health ----------------
app.get('/api/health', (req, res) => {
  res.json({ ok: true, product: APP_NAME, time: new Date().toISOString() });
});

// ---------------- bootstrap: is there an admin account yet? ----------------
app.get('/api/auth/bootstrap', (req, res) => {
  res.json({ needsSetup: !auth.anyUserExists(), googleEnabled: auth.googleEnabled() });
});

app.post('/api/auth/setup', loginLimiter, async (req, res) => {
  try {
    if (auth.anyUserExists()) return res.status(409).json({ error: 'Admin already configured' });
    const { username, password } = req.body || {};
    if (!auth.validateUsername(username)) return res.status(400).json({ error: 'Invalid username' });
    if (!auth.validatePassword(password)) return res.status(400).json({ error: 'Password must be at least 8 characters' });
    const user = await auth.createUser({ username, password, role: 'admin' });
    const token = auth.issueToken(user);
    auth.setAuthCookie(req, res, token);
    res.json({ ok: true, user });
  } catch (err) {
    res.status(400).json({ error: err.message });
  }
});

// ---------------- local login ----------------
app.post('/api/auth/login', loginLimiter, async (req, res) => {
  const { username, password } = req.body || {};
  const ip = clientIp(req);
  if (!auth.validateUsername(username) || typeof password !== 'string') {
    return res.status(400).json({ error: 'Invalid credentials format' });
  }
  if (auth.isLockedOut(ip, username)) {
    return res.status(429).json({ error: 'Too many failed attempts. Try again later.' });
  }
  const user = auth.findByUsername(username);
  const ok = user && (await auth.verifyPassword(user, password));
  if (!ok) {
    auth.recordFailure(ip, username);
    return res.status(401).json({ error: 'Invalid username or password' });
  }
  auth.recordSuccess(ip, username);
  const token = auth.issueToken(user);
  auth.setAuthCookie(req, res, token);
  res.json({ ok: true, user: auth.sanitizeUser(user) });
});

app.post('/api/auth/logout', (req, res) => {
  auth.clearAuthCookie(res);
  res.json({ ok: true });
});

app.get('/api/auth/me', auth.requireAuth, (req, res) => {
  res.json({ user: req.user, googleEnabled: auth.googleEnabled() });
});

// ---------------- Google OAuth ----------------
app.get('/auth/google', (req, res) => {
  if (!auth.googleEnabled()) return res.status(404).send('Google login is not configured');
  const { url, state } = auth.buildGoogleAuthUrl();
  res.cookie('azpanel_oauth_state', state, { httpOnly: true, sameSite: 'lax', maxAge: 10 * 60 * 1000 });
  res.redirect(url);
});

app.get('/auth/google/callback', async (req, res) => {
  try {
    if (!auth.googleEnabled()) return res.status(404).send('Google login is not configured');
    const { code, state } = req.query;
    const cookieState = req.cookies && req.cookies.azpanel_oauth_state;
    if (!code || !state || state !== cookieState || !auth.consumeState(state)) {
      return res.status(400).send('Invalid or expired OAuth state');
    }
    const tokenResp = await auth.exchangeGoogleCode(code);
    const profile = await auth.fetchGoogleProfile(tokenResp.access_token);
    if (!profile.email_verified) return res.status(403).send('Google email is not verified');

    let user = auth.findByGoogleId(profile.sub);
    if (!user) {
      // Only ever LINK to an existing local account with a matching email,
      // and only if that email is on the explicit allowlist (when configured).
      // We never silently mint a brand-new admin from an arbitrary Google account.
      const allowlist = auth.googleAllowlist();
      const emailOk = allowlist.length === 0 || allowlist.includes(String(profile.email).toLowerCase());
      const existing = auth.findByUsername(profile.email);
      if (!emailOk || !existing) {
        return res.status(403).send('This Google account is not authorized for AZ PANEL. Ask an administrator to grant access.');
      }
      await auth.linkGoogleAccount(existing.id, profile.sub);
      user = auth.findByUsername(profile.email);
    }
    const token = auth.issueToken(user);
    auth.setAuthCookie(req, res, token);
    res.clearCookie('azpanel_oauth_state');
    res.redirect('/#/dashboard');
  } catch (err) {
    console.error('[google-oauth]', err.message);
    res.status(500).send('Google login failed');
  }
});

// ---------------- servers API ----------------
const router = express.Router();
router.use(auth.requireAuth);

// ---------------- user management API ----------------
router.get('/users', auth.requireAdmin, (req, res) => {
  res.json({ users: auth.listUsers() });
});

router.post('/users', auth.requireAdmin, async (req, res) => {
  try {
    const { username, password, email, role = 'user' } = req.body || {};
    if (!auth.validateUsername(username)) return res.status(400).json({ error: 'Invalid username' });
    if (!auth.validatePassword(password)) return res.status(400).json({ error: 'Password must be at least 8 characters' });
    if (!['admin', 'user'].includes(role)) return res.status(400).json({ error: 'Invalid role' });
    const user = await auth.createUser({ username, password, email, role });
    res.status(201).json({ user });
  } catch (err) { res.status(400).json({ error: err.message }); }
});

router.patch('/users/:id', auth.requireAdmin, async (req, res) => {
  try {
    const target = auth.findById(req.params.id);
    if (!target) return res.status(404).json({ error: 'User not found' });
    if (target.id === req.user.id && req.body.disabled) return res.status(400).json({ error: 'You cannot disable your own account' });
    if (target.role === 'admin' && req.body.role === 'user' && auth.listUsers().filter((u) => u.role === 'admin' && !u.disabled).length <= 1) return res.status(400).json({ error: 'Cannot remove the last active administrator' });
    const patch = {};
    if (typeof req.body.disabled === 'boolean') patch.disabled = req.body.disabled;
    if (req.body.role) { if (!['admin', 'user'].includes(req.body.role)) return res.status(400).json({ error: 'Invalid role' }); patch.role = req.body.role; }
    if (req.body.email !== undefined) patch.email = req.body.email || null;
    const user = await auth.updateUser(target.id, patch);
    res.json({ user });
  } catch (err) { res.status(400).json({ error: err.message }); }
});

router.post('/users/:id/password', auth.requireAdmin, async (req, res) => {
  try { const user = await auth.setPassword(req.params.id, req.body && req.body.password); res.json({ user }); }
  catch (err) { res.status(400).json({ error: err.message }); }
});

router.delete('/users/:id', auth.requireAdmin, async (req, res) => {
  try {
    if (req.params.id === req.user.id) return res.status(400).json({ error: 'You cannot delete your own account' });
    await auth.deleteUser(req.params.id);
    for (const srv of mc.listServers()) {
      if (srv.ownerId === req.params.id) await mc.updateServerMeta(srv.id, { ownerId: null });
    }
    res.json({ ok: true });
  } catch (err) { res.status(400).json({ error: err.message }); }
});

router.post('/servers/:id/assign', auth.requireAdmin, requireServer, async (req, res) => {
  try {
    const ownerId = req.body && req.body.ownerId ? req.body.ownerId : null;
    if (ownerId && !auth.findById(ownerId)) return res.status(404).json({ error: 'User not found' });
    const server = await mc.updateServerMeta(req.params.id, { ownerId });
    res.json({ server });
  } catch (err) { res.status(400).json({ error: err.message }); }
});

router.get('/versions', async (req, res) => {
  try {
    res.json(await mc.listMinecraftVersions());
  } catch (err) {
    res.status(502).json({ error: `Could not reach Mojang: ${err.message}` });
  }
});

router.get('/servers', async (req, res) => {
  const list = mc.listServersForUser(req.user);
  for (const s of list) await mc.refreshStatus(s.id);
  res.json({ servers: mc.listServersForUser(req.user) });
});

router.post('/servers', auth.requireAdmin, async (req, res) => {
  try {
    const { name, version, ram, port, eulaAccepted } = req.body || {};
    const hasOwnerField = Object.prototype.hasOwnProperty.call(req.body || {}, 'ownerId');
    const requestedOwner = hasOwnerField ? (req.body.ownerId || null) : req.user.id;
    if (requestedOwner && !auth.findById(requestedOwner)) return res.status(404).json({ error: 'Owner user not found' });
    const server = await mc.createServer({ name, version, ram, port, eulaAccepted, ownerId: requestedOwner });
    res.status(201).json({ server });
  } catch (err) {
    res.status(400).json({ error: err.message });
  }
});

function requireServer(req, res, next) {
  if (!mc.isValidId(req.params.id)) return res.status(400).json({ error: 'Invalid server id' });
  const server = mc.getServer(req.params.id);
  if (!server) return res.status(404).json({ error: 'Server not found' });
  if (req.user.role !== 'admin' && server.ownerId !== req.user.id) return res.status(403).json({ error: 'You do not have access to this server' });
  req.server = server;
  next();
}

router.get('/servers/:id', requireServer, async (req, res) => {
  res.json({ server: await mc.refreshStatus(req.params.id) });
});

router.post('/servers/:id/start', requireServer, async (req, res) => {
  try { res.json({ server: await mc.startServer(req.params.id) }); }
  catch (err) { res.status(400).json({ error: err.message }); }
});

router.post('/servers/:id/stop', requireServer, async (req, res) => {
  try { res.json({ server: await mc.stopServer(req.params.id) }); }
  catch (err) { res.status(400).json({ error: err.message }); }
});

router.post('/servers/:id/restart', requireServer, async (req, res) => {
  try { res.json({ server: await mc.restartServer(req.params.id) }); }
  catch (err) { res.status(400).json({ error: err.message }); }
});

router.post('/servers/:id/kill', requireServer, async (req, res) => {
  try { res.json({ server: await mc.killServer(req.params.id) }); }
  catch (err) { res.status(400).json({ error: err.message }); }
});

router.delete('/servers/:id', auth.requireAdmin, requireServer, async (req, res) => {
  try {
    await mc.deleteServer(req.params.id, { deleteData: req.query.deleteData === 'true' });
    res.json({ ok: true });
  } catch (err) { res.status(400).json({ error: err.message }); }
});

router.get('/servers/:id/logs', requireServer, (req, res) => {
  const lines = Math.min(2000, Number(req.query.lines) || 200);
  res.json({ logs: mc.readLogs(req.params.id, lines) });
});

router.post('/servers/:id/console', requireServer, async (req, res) => {
  try {
    const { command } = req.body || {};
    await mc.sendConsoleCommand(req.params.id, command);
    res.json({ ok: true });
  } catch (err) { res.status(400).json({ error: err.message }); }
});

router.get('/system', async (req, res) => {
  res.json({ system: await system.snapshot(DATA_DIR), servers: mc.listServers().length });
});

app.use('/api', router);

// SPA fallback (only for non-API GET requests)
app.get(/^(?!\/api|\/auth).*/, (req, res) => {
  res.sendFile(path.join(__dirname, 'public', 'index.html'));
});

// ---------------- error handler ----------------
app.use((err, req, res, next) => { // eslint-disable-line no-unused-vars
  console.error('[unhandled]', err);
  res.status(500).json({ error: 'Internal server error' });
});

// ---------------- HTTP + WebSocket (live console/log streaming) ----------------
const server = http.createServer(app);
const wss = new WebSocketServer({ server, path: '/ws/console' });

wss.on('connection', (ws, req) => {
  try {
    const url = new URL(req.url, 'http://localhost');
    const id = url.searchParams.get('server');
    const token = (req.headers.cookie || '').match(new RegExp(`${auth.COOKIE_NAME}=([^;]+)`));
    const payload = token && auth.verifyToken(decodeURIComponent(token[1]));
    const wsUser = payload && auth.findById(payload.sub);
    const wsServer = id && mc.isValidId(id) ? mc.getServer(id) : null;
    if (!wsUser || wsUser.disabled || !id || !wsServer || (wsUser.role !== 'admin' && wsServer.ownerId !== wsUser.id)) {
      ws.close(4401, 'unauthorized');
      return;
    }
    let lastSize = 0;
    const interval = setInterval(() => {
      try {
        const logs = mc.readLogs(id, 500);
        if (logs.length !== lastSize) {
          lastSize = logs.length;
          ws.send(JSON.stringify({ type: 'log', data: logs }));
        }
      } catch (_) { /* server may not have logs yet */ }
    }, 1000);
    ws.on('close', () => clearInterval(interval));
    ws.on('message', async (raw) => {
      try {
        const msg = JSON.parse(raw.toString());
        if (msg.type === 'command' && typeof msg.command === 'string') {
          await mc.sendConsoleCommand(id, msg.command);
        }
      } catch (err) {
        ws.send(JSON.stringify({ type: 'error', message: err.message }));
      }
    });
  } catch (err) {
    ws.close(1011, 'internal error');
  }
});

server.listen(PORT, HOST, () => {
  console.log(`[AZ PANEL] listening on http://${HOST}:${PORT}`);
});

process.on('SIGTERM', () => { server.close(() => process.exit(0)); });
process.on('SIGINT', () => { server.close(() => process.exit(0)); });
AZPANEL_FILE_EOF_SERVER_JS

  cat > "$APP_DIR/lib/db.js" <<'AZPANEL_FILE_EOF_LIB_DB_JS'
'use strict';
/**
 * AZ PANEL - lib/db.js
 *
 * Minimal, dependency-free JSON file datastore.
 * - Atomic writes (write to temp file, then rename)
 * - Per-file write queue so concurrent writes never interleave/corrupt data
 * - Not a "real" database, but safe and adequate for a single-node panel
 */

const fs = require('fs');
const path = require('path');

const DATA_DIR = process.env.PANEL_DATA_DIR || path.join(__dirname, '..', 'data');
const DB_DIR = path.join(DATA_DIR, 'db');

function ensureDir(dir) {
  fs.mkdirSync(dir, { recursive: true, mode: 0o750 });
}

ensureDir(DATA_DIR);
ensureDir(DB_DIR);

// One write queue (Promise chain) per file path so writes are serialized.
const writeQueues = new Map();

function filePath(name) {
  // name must be a simple identifier - never derived from raw user input.
  if (!/^[a-zA-Z0-9_-]+$/.test(name)) {
    throw new Error('Invalid db collection name');
  }
  return path.join(DB_DIR, `${name}.json`);
}

function readJSONSync(file, fallback) {
  try {
    const raw = fs.readFileSync(file, 'utf8');
    if (!raw.trim()) return fallback;
    return JSON.parse(raw);
  } catch (err) {
    if (err.code === 'ENOENT') return fallback;
    // Corrupt file - back it up rather than silently losing data or crashing forever.
    try {
      fs.copyFileSync(file, `${file}.corrupt-${Date.now()}`);
    } catch (_) { /* best effort */ }
    return fallback;
  }
}

function writeJSONAtomic(file, data) {
  const dir = path.dirname(file);
  const tmp = path.join(dir, `.${path.basename(file)}.${process.pid}.${Date.now()}.tmp`);
  const json = JSON.stringify(data, null, 2);
  fs.writeFileSync(tmp, json, { mode: 0o640 });
  fs.renameSync(tmp, file); // atomic on same filesystem
}

/**
 * A simple collection API: load(), save(mutatorFn), get()
 * `mutatorFn(currentArrayOrObject) => newArrayOrObject`
 */
class Collection {
  constructor(name, defaultValue) {
    this.name = name;
    this.file = filePath(name);
    this.defaultValue = defaultValue;
    if (!writeQueues.has(this.file)) writeQueues.set(this.file, Promise.resolve());
  }

  all() {
    return readJSONSync(this.file, JSON.parse(JSON.stringify(this.defaultValue)));
  }

  // Queue a read-modify-write so concurrent calls never race.
  update(mutatorFn) {
    const prev = writeQueues.get(this.file);
    const next = prev.then(() => {
      const current = this.all();
      const updated = mutatorFn(current);
      writeJSONAtomic(this.file, updated);
      return updated;
    }).catch((err) => {
      // Ensure queue continues even if one write fails
      console.error(`[db] write error on ${this.name}:`, err.message);
      throw err;
    });
    writeQueues.set(this.file, next.catch(() => {}));
    return next;
  }
}

module.exports = {
  DATA_DIR,
  DB_DIR,
  Collection,
  ensureDir,
};
AZPANEL_FILE_EOF_LIB_DB_JS

  cat > "$APP_DIR/lib/auth.js" <<'AZPANEL_FILE_EOF_LIB_AUTH_JS'
'use strict';
/**
 * AZ PANEL - lib/auth.js
 * Authentication: local password login + optional Google OAuth2.
 */

const crypto = require('crypto');
const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const { Collection } = require('./db');

const users = new Collection('users', []);
const oauthStates = new Map(); // state -> { expires }

const JWT_SECRET = process.env.JWT_SECRET;
const JWT_EXPIRES_IN = '12h';
const COOKIE_NAME = 'azpanel_token';

if (!JWT_SECRET || JWT_SECRET.length < 32) {
  throw new Error('JWT_SECRET is missing or too short. Refusing to start.');
}

// ---------- Login rate limiting (per username + per IP) ----------
const failedAttempts = new Map(); // key -> { count, firstAt }
const MAX_ATTEMPTS = 8;
const WINDOW_MS = 10 * 60 * 1000; // 10 minutes
const LOCKOUT_MS = 15 * 60 * 1000; // 15 minutes

function rateLimitKey(ip, username) {
  return `${ip}::${(username || '').toLowerCase()}`;
}

function isLockedOut(ip, username) {
  const rec = failedAttempts.get(rateLimitKey(ip, username));
  if (!rec) return false;
  if (Date.now() - rec.firstAt > WINDOW_MS + LOCKOUT_MS) {
    failedAttempts.delete(rateLimitKey(ip, username));
    return false;
  }
  return rec.count >= MAX_ATTEMPTS && (Date.now() - rec.lockedAt < LOCKOUT_MS);
}

function recordFailure(ip, username) {
  const key = rateLimitKey(ip, username);
  const rec = failedAttempts.get(key) || { count: 0, firstAt: Date.now() };
  rec.count += 1;
  if (rec.count >= MAX_ATTEMPTS) rec.lockedAt = Date.now();
  failedAttempts.set(key, rec);
}

function recordSuccess(ip, username) {
  failedAttempts.delete(rateLimitKey(ip, username));
}

// ---------- Validation ----------
function validateUsername(u) {
  return typeof u === 'string' && /^[a-zA-Z0-9_.@-]{3,64}$/.test(u);
}

function validatePassword(p) {
  return typeof p === 'string' && p.length >= 8 && p.length <= 256;
}

// ---------- Users ----------
async function createUser({ username, password, email, role = 'admin', googleId = null }) {
  const all = users.all();
  if (all.some((u) => u.username.toLowerCase() === username.toLowerCase())) {
    throw new Error('Username already exists');
  }
  const passwordHash = password ? await bcrypt.hash(password, 12) : null;
  const user = {
    id: crypto.randomUUID(),
    username,
    email: email || null,
    passwordHash,
    googleId,
    role,
    disabled: false,
    createdAt: new Date().toISOString(),
  };
  await users.update((list) => [...list, user]);
  return sanitizeUser(user);
}

function findByUsername(username) {
  return users.all().find((u) => u.username.toLowerCase() === String(username).toLowerCase());
}

function findByGoogleId(googleId) {
  return users.all().find((u) => u.googleId === googleId);
}

function findById(id) {
  return users.all().find((u) => u.id === id);
}

function listUsers() {
  return users.all().map(sanitizeUser);
}

async function updateUser(id, patch) {
  const current = findById(id);
  if (!current) throw new Error('User not found');
  await users.update((list) => list.map((u) => (u.id === id ? { ...u, ...patch } : u)));
  return sanitizeUser(findById(id));
}

async function deleteUser(id) {
  const current = findById(id);
  if (!current) throw new Error('User not found');
  if (current.role === 'admin' && users.all().filter((u) => u.role === 'admin').length <= 1) {
    throw new Error('Cannot delete the last administrator');
  }
  await users.update((list) => list.filter((u) => u.id !== id));
}

async function setPassword(id, password) {
  if (!validatePassword(password)) throw new Error('Password must be at least 8 characters');
  const passwordHash = await bcrypt.hash(password, 12);
  return updateUser(id, { passwordHash, googleId: null });
}

function anyUserExists() {
  return users.all().length > 0;
}

function sanitizeUser(u) {
  if (!u) return null;
  const { passwordHash, googleId, ...safe } = u;
  return safe;
}

async function verifyPassword(user, password) {
  if (!user || !user.passwordHash) return false;
  return bcrypt.compare(password, user.passwordHash);
}

async function linkGoogleAccount(userId, googleId) {
  await users.update((list) => list.map((u) => (u.id === userId ? { ...u, googleId } : u)));
}

// ---------- JWT / session cookie ----------
function issueToken(user) {
  return jwt.sign({ sub: user.id, username: user.username, role: user.role }, JWT_SECRET, {
    expiresIn: JWT_EXPIRES_IN,
  });
}

function verifyToken(token) {
  try {
    return jwt.verify(token, JWT_SECRET);
  } catch (_) {
    return null;
  }
}

function cookieOptions(req) {
  const isHttps = req.secure || req.headers['x-forwarded-proto'] === 'https';
  return {
    httpOnly: true,
    sameSite: 'lax',
    secure: !!isHttps,
    maxAge: 12 * 60 * 60 * 1000,
    path: '/',
  };
}

function setAuthCookie(req, res, token) {
  res.cookie(COOKIE_NAME, token, cookieOptions(req));
}

function clearAuthCookie(res) {
  res.clearCookie(COOKIE_NAME, { path: '/' });
}

// Express middleware: requires a valid session, attaches req.user
function requireAuth(req, res, next) {
  const token = req.cookies && req.cookies[COOKIE_NAME];
  const payload = token ? verifyToken(token) : null;
  if (!payload) {
    return res.status(401).json({ error: 'Not authenticated' });
  }
  const user = findById(payload.sub);
  if (!user || user.disabled) {
    return res.status(401).json({ error: 'Not authenticated' });
  }
  req.user = sanitizeUser(user);
  next();
}

function requireAdmin(req, res, next) {
  if (!req.user || req.user.role !== 'admin') {
    return res.status(403).json({ error: 'Admin access required' });
  }
  next();
}

// ---------- Google OAuth (manual, no passport dependency) ----------
const GOOGLE_AUTH_URL = 'https://accounts.google.com/o/oauth2/v2/auth';
const GOOGLE_TOKEN_URL = 'https://oauth2.googleapis.com/token';
const GOOGLE_USERINFO_URL = 'https://www.googleapis.com/oauth2/v3/userinfo';

function googleEnabled() {
  return !!(process.env.GOOGLE_CLIENT_ID && process.env.GOOGLE_CLIENT_SECRET && process.env.GOOGLE_CALLBACK_URL);
}

// Optional allowlist: comma-separated emails permitted to use Google login.
// If unset, Google login can still only ever attach to an *existing* local
// account with a matching email - it never silently creates a new admin.
function googleAllowlist() {
  return (process.env.GOOGLE_ALLOWED_EMAILS || '')
    .split(',')
    .map((s) => s.trim().toLowerCase())
    .filter(Boolean);
}

function buildGoogleAuthUrl() {
  const state = crypto.randomBytes(24).toString('hex');
  oauthStates.set(state, { expires: Date.now() + 10 * 60 * 1000 });
  // Prune old states opportunistically.
  for (const [k, v] of oauthStates) if (v.expires < Date.now()) oauthStates.delete(k);

  const params = new URLSearchParams({
    client_id: process.env.GOOGLE_CLIENT_ID,
    redirect_uri: process.env.GOOGLE_CALLBACK_URL,
    response_type: 'code',
    scope: 'openid email profile',
    state,
    access_type: 'online',
    prompt: 'select_account',
  });
  return { url: `${GOOGLE_AUTH_URL}?${params.toString()}`, state };
}

function consumeState(state) {
  const rec = oauthStates.get(state);
  oauthStates.delete(state);
  if (!rec) return false;
  return rec.expires >= Date.now();
}

async function exchangeGoogleCode(code) {
  const body = new URLSearchParams({
    code,
    client_id: process.env.GOOGLE_CLIENT_ID,
    client_secret: process.env.GOOGLE_CLIENT_SECRET,
    redirect_uri: process.env.GOOGLE_CALLBACK_URL,
    grant_type: 'authorization_code',
  });
  const resp = await fetch(GOOGLE_TOKEN_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: body.toString(),
  });
  if (!resp.ok) throw new Error(`Google token exchange failed: ${resp.status}`);
  return resp.json();
}

async function fetchGoogleProfile(accessToken) {
  const resp = await fetch(GOOGLE_USERINFO_URL, {
    headers: { Authorization: `Bearer ${accessToken}` },
  });
  if (!resp.ok) throw new Error(`Google userinfo failed: ${resp.status}`);
  return resp.json();
}

module.exports = {
  COOKIE_NAME,
  validateUsername,
  validatePassword,
  createUser,
  findByUsername,
  findByGoogleId,
  findById,
  anyUserExists,
  sanitizeUser,
  verifyPassword,
  linkGoogleAccount,
  issueToken,
  verifyToken,
  setAuthCookie,
  clearAuthCookie,
  requireAuth,
  requireAdmin,
  listUsers,
  updateUser,
  deleteUser,
  setPassword,
  isLockedOut,
  recordFailure,
  recordSuccess,
  googleEnabled,
  googleAllowlist,
  buildGoogleAuthUrl,
  consumeState,
  exchangeGoogleCode,
  fetchGoogleProfile,
};
AZPANEL_FILE_EOF_LIB_AUTH_JS

  cat > "$APP_DIR/lib/mc.js" <<'AZPANEL_FILE_EOF_LIB_MC_JS'
'use strict';
/**
 * AZ PANEL - lib/mc.js
 *
 * Minecraft server lifecycle, backed by supervisord (a real userspace
 * process supervisor - no systemd anywhere in this file).
 *
 * Architecture per server <id>:
 *   data/servers/<id>/
 *     server.jar, eula.txt, server.properties
 *     start.sh          -- wrapper that opens console.fifo rw on fd 3,
 *                           dup's it onto stdin, then execs java.
 *     console.fifo       -- named pipe; writing to it sends console input
 *     logs/latest.log    -- supervisord stdout/stderr capture (also=stdout)
 *     metadata.json       -- name, version, ram, port, status bookkeeping
 *
 *   config/conf.d/<id>.conf  -- supervisord program definition for the server
 *
 * We control the servers exclusively through `supervisorctl`, invoked with
 * execFile() and argument arrays (never through a shell), so nothing here
 * is vulnerable to shell injection regardless of user-supplied names.
 */

const fs = require('fs');
const path = require('path');
const net = require('net');
const crypto = require('crypto');
const { execFile } = require('child_process');
const { Collection, DATA_DIR, ensureDir } = require('./db');

const SERVERS_DIR = path.join(DATA_DIR, 'servers');
const CONFIG_DIR = process.env.PANEL_CONFIG_DIR || path.join(__dirname, '..', 'config');
const CONF_D = path.join(CONFIG_DIR, 'conf.d');
const SUPERVISORCTL = process.env.SUPERVISORCTL_BIN || 'supervisorctl';
const SUPERVISOR_CONF = path.join(CONFIG_DIR, 'supervisord.conf');

ensureDir(SERVERS_DIR);
ensureDir(CONF_D);

const servers = new Collection('servers', []);

const VALID_ID = /^[a-z0-9-]{1,40}$/;
const MC_VERSION_MANIFEST = 'https://launchermeta.mojang.com/mc/game/version_manifest_v2.json';

// ---------------- validation / sanitization ----------------

function sanitizeName(name) {
  if (typeof name !== 'string') return null;
  const trimmed = name.trim();
  if (trimmed.length < 1 || trimmed.length > 48) return null;
  if (!/^[a-zA-Z0-9 _.-]+$/.test(trimmed)) return null;
  return trimmed;
}

function slugify(name) {
  const base = name
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 24) || 'server';
  const suffix = crypto.randomBytes(3).toString('hex');
  return `${base}-${suffix}`;
}

function isValidId(id) {
  return typeof id === 'string' && VALID_ID.test(id);
}

// The ONLY place a server id becomes a filesystem path. Always re-validates
// and always resolves *inside* SERVERS_DIR, refusing any traversal attempt.
function serverDir(id) {
  if (!isValidId(id)) throw new Error('Invalid server id');
  const dir = path.resolve(SERVERS_DIR, id);
  if (dir !== path.join(SERVERS_DIR, id) || !dir.startsWith(SERVERS_DIR + path.sep)) {
    throw new Error('Path traversal rejected');
  }
  return dir;
}

function isValidRamMb(ram) {
  const n = Number(ram);
  return Number.isInteger(n) && n >= 512 && n <= 65536;
}

function isValidPort(port) {
  const n = Number(port);
  return Number.isInteger(n) && n >= 1024 && n <= 65535;
}

// ---------------- port availability ----------------

function checkPortFree(port, host = '0.0.0.0') {
  return new Promise((resolve) => {
    const tester = net.createServer();
    tester.once('error', () => resolve(false));
    tester.once('listening', () => tester.close(() => resolve(true)));
    tester.listen(port, host);
  });
}

async function assertPortAvailable(port, excludeServerId = null) {
  if (!isValidPort(port)) throw new Error('Invalid port (1024-65535 required)');
  const all = servers.all();
  const collision = all.find((s) => s.port === Number(port) && s.id !== excludeServerId);
  if (collision) throw new Error(`Port ${port} is already assigned to server "${collision.name}"`);
  const free = await checkPortFree(port);
  if (!free) throw new Error(`Port ${port} is already in use on this host`);
}

// ---------------- supervisorctl helpers ----------------

function runSupervisorCtl(args) {
  return new Promise((resolve, reject) => {
    execFile(SUPERVISORCTL, ['-c', SUPERVISOR_CONF, ...args], { timeout: 20000 }, (err, stdout, stderr) => {
      if (err && !/^\S+:\s*(ERROR|already|not running|not started|stopped)/i.test(stdout || '')) {
        return reject(new Error(stderr || err.message));
      }
      resolve((stdout || '').trim());
    });
  });
}

async function supervisorProgramStatus(program) {
  try {
    const out = await runSupervisorCtl(['status', program]);
    // Example: "mc-abc123   RUNNING   pid 1234, uptime 0:01:02"
    const line = out.split('\n')[0] || '';
    if (/RUNNING/.test(line)) return 'RUNNING';
    if (/STARTING/.test(line)) return 'STARTING';
    if (/STOPPING/.test(line)) return 'STOPPING';
    if (/BACKOFF|FATAL/.test(line)) return 'CRASHED';
    if (/EXITED/.test(line)) return 'EXITED';
    if (/STOPPED/.test(line)) return 'STOPPED';
    return 'UNKNOWN';
  } catch (_) {
    return 'UNKNOWN';
  }
}

function panelStatusFromSupervisor(s) {
  switch (s) {
    case 'RUNNING': return 'ONLINE';
    case 'STARTING': return 'STARTING';
    case 'STOPPING': return 'STOPPING';
    case 'CRASHED': return 'CRASHED';
    case 'EXITED':
    case 'STOPPED': return 'OFFLINE';
    default: return 'UNKNOWN';
  }
}

// ---------------- supervisord program config generation ----------------

function programName(id) {
  return `mc-${id}`;
}

function writeSupervisorProgram(meta) {
  const dir = serverDir(meta.id);
  const logFile = path.join(dir, 'logs', 'latest.log');
  const startScript = path.join(dir, 'start.sh');
  const conf = `[program:${programName(meta.id)}]
command=/bin/bash ${startScript}
directory=${dir}
autostart=false
autorestart=false
startsecs=5
stopsignal=TERM
stopwaitsecs=30
stdout_logfile=${logFile}
stdout_logfile_maxbytes=10MB
stdout_logfile_backups=5
redirect_stderr=true
user=${process.env.MC_RUN_USER || process.env.SUDO_USER || 'root'}
environment=HOME="${dir}"
`;
  fs.writeFileSync(path.join(CONF_D, `${meta.id}.conf`), conf, { mode: 0o640 });
}

function removeSupervisorProgram(id) {
  const f = path.join(CONF_D, `${id}.conf`);
  if (fs.existsSync(f)) fs.unlinkSync(f);
}

async function reloadSupervisor() {
  // reread + update loads/unloads program definitions without restarting
  // supervisord itself and without ever touching systemd/service.
  await runSupervisorCtl(['reread']);
  await runSupervisorCtl(['update']);
}

// ---------------- start.sh wrapper (console FIFO) ----------------

function writeStartScript(meta) {
  const dir = serverDir(meta.id);
  const jar = path.join(dir, 'server.jar');
  const fifo = path.join(dir, 'console.fifo');
  const script = `#!/bin/bash
# AZ PANEL - generated launcher for server ${meta.id}. Do not edit by hand.
set -u
cd "${dir}" || exit 1
if [ ! -p "${fifo}" ]; then
  rm -f "${fifo}"
  mkfifo -m 600 "${fifo}"
fi
# Open the FIFO read-write on fd 3. This gives us a persistent reader so
# writers (console commands) never block on an absent reader, and lets us
# dup it onto Minecraft's real stdin.
exec 3<>"${fifo}"
exec java -Xms${meta.ram}M -Xmx${meta.ram}M -jar "${jar}" nogui <&3
`;
  const scriptPath = path.join(dir, 'start.sh');
  fs.writeFileSync(scriptPath, script, { mode: 0o750 });
}

// ---------------- Mojang download ----------------

async function fetchVersionManifest() {
  const resp = await fetch(MC_VERSION_MANIFEST);
  if (!resp.ok) throw new Error(`Failed to fetch Minecraft version manifest: ${resp.status}`);
  return resp.json();
}

async function listMinecraftVersions() {
  const manifest = await fetchVersionManifest();
  return {
    latest: manifest.latest,
    versions: manifest.versions
      .filter((v) => v.type === 'release')
      .slice(0, 60)
      .map((v) => ({ id: v.id, releaseTime: v.releaseTime })),
  };
}

async function resolveServerDownload(versionId) {
  const manifest = await fetchVersionManifest();
  const entry = manifest.versions.find((v) => v.id === versionId);
  if (!entry) throw new Error(`Unknown Minecraft version "${versionId}"`);
  const detailResp = await fetch(entry.url);
  if (!detailResp.ok) throw new Error(`Failed to fetch version metadata: ${detailResp.status}`);
  const detail = await detailResp.json();
  const server = detail.downloads && detail.downloads.server;
  if (!server || !server.url) throw new Error(`Version "${versionId}" has no server download`);
  return { url: server.url, sha1: server.sha1, size: server.size };
}

async function downloadServerJar(meta, versionId) {
  const dir = serverDir(meta.id);
  const { url, sha1, size } = await resolveServerDownload(versionId);
  const resp = await fetch(url);
  if (!resp.ok) throw new Error(`Download failed: HTTP ${resp.status}`);
  const buf = Buffer.from(await resp.arrayBuffer());
  if (size && buf.length !== size) {
    throw new Error(`Downloaded jar size mismatch (expected ${size}, got ${buf.length})`);
  }
  const hash = crypto.createHash('sha1').update(buf).digest('hex');
  if (sha1 && hash !== sha1) {
    throw new Error('Downloaded jar failed SHA-1 verification - refusing to install');
  }
  fs.writeFileSync(path.join(dir, 'server.jar'), buf, { mode: 0o640 });
  return { sha1: hash, size: buf.length };
}

// ---------------- CRUD ----------------

function listServers() {
  return servers.all().map(publicMeta);
}

function listServersForUser(user) {
  return servers.all().filter((s) => user.role === 'admin' || s.ownerId === user.id).map(publicMeta);
}

function getServer(id) {
  const s = servers.all().find((x) => x.id === id);
  return s || null;
}

function publicMeta(s) {
  const { ...m } = s;
  return m;
}

async function createServer({ name, version, ram, port, eulaAccepted, ownerId = null }) {
  const cleanName = sanitizeName(name);
  if (!cleanName) throw new Error('Invalid server name');
  if (typeof version !== 'string' || !/^[0-9a-zA-Z_.-]{1,20}$/.test(version)) {
    throw new Error('Invalid Minecraft version');
  }
  if (!isValidRamMb(ram)) throw new Error('RAM must be between 512 and 65536 MB');
  if (!eulaAccepted) throw new Error('You must accept the Minecraft EULA to create a server');
  await assertPortAvailable(port);

  let id = slugify(cleanName);
  while (getServer(id)) id = slugify(cleanName); // extremely unlikely collision

  const dir = serverDir(id);
  fs.mkdirSync(dir, { recursive: true, mode: 0o750 });
  fs.mkdirSync(path.join(dir, 'logs'), { recursive: true, mode: 0o750 });

  const meta = {
    id,
    name: cleanName,
    ownerId: ownerId || null,
    version,
    ram: Number(ram),
    port: Number(port),
    status: 'INSTALLING',
    createdAt: new Date().toISOString(),
    lastStartedAt: null,
    crashCount: 0,
    lastCrashAt: null,
  };
  await servers.update((list) => [...list, meta]);

  try {
    await downloadServerJar(meta, version);
    fs.writeFileSync(path.join(dir, 'eula.txt'), `eula=true\n#Accepted via AZ PANEL on ${new Date().toISOString()}\n`, { mode: 0o640 });
    fs.writeFileSync(
      path.join(dir, 'server.properties'),
      `server-port=${meta.port}\nmotd=A Minecraft Server managed by AZ PANEL\nenable-status=true\n`,
      { mode: 0o640 },
    );
    writeStartScript(meta);
    writeSupervisorProgram(meta);
    await reloadSupervisor();
    await updateServerMeta(id, { status: 'OFFLINE' });
  } catch (err) {
    await updateServerMeta(id, { status: 'ERROR', lastError: err.message });
    throw err;
  }

  return getServer(id);
}

async function updateServerMeta(id, patch) {
  await servers.update((list) => list.map((s) => (s.id === id ? { ...s, ...patch } : s)));
  return getServer(id);
}

async function refreshStatus(id) {
  const meta = getServer(id);
  if (!meta) return null;
  const supStatus = await supervisorProgramStatus(programName(id));
  const newStatus = panelStatusFromSupervisor(supStatus);
  if (newStatus === 'CRASHED' && meta.status !== 'CRASHED') {
    await updateServerMeta(id, { status: 'CRASHED', crashCount: (meta.crashCount || 0) + 1, lastCrashAt: new Date().toISOString() });
  } else if (newStatus !== 'UNKNOWN' && newStatus !== meta.status) {
    await updateServerMeta(id, { status: newStatus });
  }
  return getServer(id);
}

async function startServer(id) {
  const meta = getServer(id);
  if (!meta) throw new Error('Server not found');
  if (!fs.existsSync(path.join(serverDir(id), 'server.jar'))) throw new Error('server.jar missing - reinstall required');
  await assertPortAvailable(meta.port, id);
  await updateServerMeta(id, { status: 'STARTING' });
  await runSupervisorCtl(['start', programName(id)]);
  await updateServerMeta(id, { lastStartedAt: new Date().toISOString() });
  return refreshStatus(id);
}

async function stopServer(id, { graceMs = 25000 } = {}) {
  const meta = getServer(id);
  if (!meta) throw new Error('Server not found');
  await updateServerMeta(id, { status: 'STOPPING' });
  try {
    // Graceful: tell Minecraft to stop itself via console, then let
    // supervisord's stopwaitsecs / SIGTERM handling take over as backup.
    await sendConsoleCommand(id, 'stop');
  } catch (_) { /* fall through to supervisor stop below */ }
  await runSupervisorCtl(['stop', programName(id)]);
  return refreshStatus(id);
}

async function killServer(id) {
  const meta = getServer(id);
  if (!meta) throw new Error('Server not found');
  await runSupervisorCtl(['signal', 'KILL', programName(id)]);
  await runSupervisorCtl(['stop', programName(id)]);
  return refreshStatus(id);
}

async function restartServer(id) {
  await stopServer(id);
  await new Promise((r) => setTimeout(r, 1500));
  return startServer(id);
}

async function deleteServer(id, { deleteData = false } = {}) {
  const meta = getServer(id);
  if (!meta) throw new Error('Server not found');
  await runSupervisorCtl(['stop', programName(id)]).catch(() => {});
  removeSupervisorProgram(id);
  await reloadSupervisor();
  await servers.update((list) => list.filter((s) => s.id !== id));
  if (deleteData) {
    fs.rmSync(serverDir(id), { recursive: true, force: true });
  }
}

function sendConsoleCommand(id, command) {
  const meta = getServer(id);
  if (!meta) throw new Error('Server not found');
  if (typeof command !== 'string' || command.length === 0 || command.length > 512) {
    throw new Error('Invalid command');
  }
  // Commands go ONLY into this server's own FIFO -> Minecraft stdin.
  // There is no shell involved, so this can never execute an OS command.
  const fifo = path.join(serverDir(id), 'console.fifo');
  if (!fs.existsSync(fifo)) throw new Error('Server console is not available (server not started yet)');

  const payload = command.replace(/[\r\n]+$/, '') + '\n';
  return new Promise((resolve, reject) => {
    // Open O_NONBLOCK: if nothing is reading the FIFO (server not actually
    // running), this fails fast with ENXIO instead of hanging the event
    // loop forever waiting for a reader that will never show up.
    fs.open(fifo, fs.constants.O_WRONLY | fs.constants.O_NONBLOCK, (openErr, fd) => {
      if (openErr) {
        if (openErr.code === 'ENXIO') {
          return reject(new Error('Server is not running - no console reader is attached'));
        }
        return reject(openErr);
      }
      fs.write(fd, payload, (writeErr) => {
        fs.close(fd, () => {
          if (writeErr) return reject(writeErr);
          resolve();
        });
      });
    });
  });
}

function readLogs(id, lines = 200) {
  const logFile = path.join(serverDir(id), 'logs', 'latest.log');
  if (!fs.existsSync(logFile)) return '';
  const content = fs.readFileSync(logFile, 'utf8');
  const all = content.split('\n');
  return all.slice(Math.max(0, all.length - lines)).join('\n');
}

module.exports = {
  SERVERS_DIR,
  CONFIG_DIR,
  SUPERVISOR_CONF,
  listMinecraftVersions,
  createServer,
  listServers,
  listServersForUser,
  getServer,
  updateServerMeta,
  refreshStatus,
  startServer,
  stopServer,
  killServer,
  restartServer,
  deleteServer,
  sendConsoleCommand,
  readLogs,
  isValidId,
};
AZPANEL_FILE_EOF_LIB_MC_JS

  cat > "$APP_DIR/lib/system.js" <<'AZPANEL_FILE_EOF_LIB_SYSTEM_JS'
'use strict';
/**
 * AZ PANEL - lib/system.js
 * Real system information (no fabricated values).
 */

const os = require('os');
const fs = require('fs');
const { execFile } = require('child_process');

function cpuUsageSnapshotOnce() {
  const cpus = os.cpus();
  let idle = 0;
  let total = 0;
  for (const c of cpus) {
    for (const t of Object.values(c.times)) total += t;
    idle += c.times.idle;
  }
  return { idle, total };
}

function cpuUsagePercent() {
  return new Promise((resolve) => {
    const start = cpuUsageSnapshotOnce();
    setTimeout(() => {
      const end = cpuUsageSnapshotOnce();
      const idleDelta = end.idle - start.idle;
      const totalDelta = end.total - start.total;
      const usage = totalDelta > 0 ? 1 - idleDelta / totalDelta : 0;
      resolve(Math.round(usage * 1000) / 10); // percent, 1 decimal
    }, 200);
  });
}

function diskUsage(targetPath) {
  return new Promise((resolve) => {
    execFile('df', ['-kP', targetPath], (err, stdout) => {
      if (err) return resolve(null);
      const lines = stdout.trim().split('\n');
      if (lines.length < 2) return resolve(null);
      const parts = lines[1].split(/\s+/);
      const [, blocks1k, used1k, avail1k] = parts;
      resolve({
        totalBytes: Number(blocks1k) * 1024,
        usedBytes: Number(used1k) * 1024,
        freeBytes: Number(avail1k) * 1024,
      });
    });
  });
}

function javaVersion() {
  return new Promise((resolve) => {
    execFile('java', ['-version'], (err, stdout, stderr) => {
      if (err) return resolve(null);
      // `java -version` writes to stderr, not stdout.
      const text = (stderr || stdout || '').split('\n')[0];
      resolve(text || null);
    });
  });
}

async function snapshot(dataDir) {
  const [cpuPct, disk, javaV] = await Promise.all([
    cpuUsagePercent(),
    diskUsage(dataDir || '/'),
    javaVersion(),
  ]);
  return {
    hostname: os.hostname(),
    platform: os.platform(),
    arch: os.arch(),
    uptimeSeconds: os.uptime(),
    cpuCount: os.cpus().length,
    cpuModel: (os.cpus()[0] && os.cpus()[0].model) || 'unknown',
    cpuUsagePercent: cpuPct,
    memory: {
      totalBytes: os.totalmem(),
      freeBytes: os.freemem(),
      usedBytes: os.totalmem() - os.freemem(),
    },
    disk,
    loadAverage: os.loadavg(),
    nodeVersion: process.version,
    javaVersion: javaV,
    panelUptimeSeconds: process.uptime(),
  };
}

module.exports = { snapshot };
AZPANEL_FILE_EOF_LIB_SYSTEM_JS

  cat > "$APP_DIR/bin/azpanel" <<'AZPANEL_FILE_EOF_BIN_AZPANEL'
#!/usr/bin/env node
'use strict';
/**
 * AZ PANEL CLI
 * Installed as /usr/local/bin/azpanel by the installer.
 * Talks to PM2 for panel process control, and directly to lib/mc.js
 * for Minecraft server management (this CLI only runs locally as root,
 * so it does not need to re-authenticate through the HTTP API).
 */

const path = require('path');
const { execFileSync } = require('child_process');

const APP_DIR = process.env.AZPANEL_APP_DIR || path.resolve(__dirname, '..');
process.chdir(APP_DIR);
require('dotenv').config({ path: path.join(APP_DIR, '.env') });

const args = process.argv.slice(2);
const cmd = args[0];

function pm2(cmdArgs) {
  try {
    const out = execFileSync('pm2', cmdArgs, { encoding: 'utf8' });
    process.stdout.write(out);
  } catch (err) {
    process.stderr.write((err.stdout || '') + (err.stderr || err.message) + '\n');
    process.exit(1);
  }
}

function usage() {
  console.log(`AZ PANEL CLI

Usage:
  azpanel start | stop | restart | status | logs | update | uninstall
  azpanel server list
  azpanel server create --name <name> --version <mc-version> --ram <mb> --port <port>
  azpanel server start <id>
  azpanel server stop <id>
  azpanel server restart <id>
  azpanel server console <id> "<command>"
  azpanel server delete <id> [--data]
`);
}

async function serverCmd() {
  const mc = require(path.join(APP_DIR, 'lib', 'mc.js'));
  const sub = args[1];
  if (sub === 'list') {
    const list = mc.listServers();
    for (const s of list) console.log(`${s.id}\t${s.name}\t${s.status}\tport=${s.port}\tram=${s.ram}MB\tversion=${s.version}`);
    return;
  }
  if (sub === 'create') {
    const opts = {};
    for (let i = 2; i < args.length; i += 2) opts[args[i].replace(/^--/, '')] = args[i + 1];
    const server = await mc.createServer({
      name: opts.name,
      version: opts.version,
      ram: Number(opts.ram),
      port: Number(opts.port),
      eulaAccepted: true,
    });
    console.log(`Created server ${server.id} (${server.name})`);
    return;
  }
  if (sub === 'start') return void console.log(await mc.startServer(args[2]));
  if (sub === 'stop') return void console.log(await mc.stopServer(args[2]));
  if (sub === 'restart') return void console.log(await mc.restartServer(args[2]));
  if (sub === 'console') return void (await mc.sendConsoleCommand(args[2], args.slice(3).join(' ')));
  if (sub === 'delete') return void (await mc.deleteServer(args[2], { deleteData: args.includes('--data') }));
  usage();
}

async function main() {
  switch (cmd) {
    case 'start': return pm2(['start', 'ecosystem.config.js']);
    case 'stop': return pm2(['stop', 'az-panel']);
    case 'restart': return pm2(['restart', 'az-panel']);
    case 'status': return pm2(['status']);
    case 'logs': return pm2(['logs', 'az-panel', '--lines', args[1] || '100']);
    case 'server': return serverCmd();
    default: usage();
  }
}

main().catch((err) => {
  console.error('Error:', err.message);
  process.exit(1);
});
AZPANEL_FILE_EOF_BIN_AZPANEL
  chmod 750 "$APP_DIR/bin/azpanel"

  cat > "$APP_DIR/public/index.html" <<'AZPANEL_FILE_EOF_PUBLIC_INDEX_HTML'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>AZ PANEL</title>
<link rel="stylesheet" href="/style.css" />
</head>
<body>
  <div id="topbar" class="topbar hidden">
    <div class="brand">AZ<span>PANEL</span></div>
    <nav id="nav">
      <a href="#/dashboard" data-route="dashboard">Overview</a>
      <a href="#/servers" data-route="servers">Servers</a>
      <a href="#/servers/new" data-route="servers/new" id="createServerNav">Create Server</a>
      <a href="#/system" data-route="system">System</a>
      <a href="#/users" data-route="users" id="usersNav" class="hidden">Users</a>
    </nav>
    <div class="topbar-right">
      <span id="whoami"></span>
      <button id="logoutBtn" class="btn btn-ghost">Logout</button>
    </div>
  </div>

  <main id="app" class="app"></main>

  <template id="tpl-setup">
    <div class="center-card">
      <div class="brand-lg">AZ<span>PANEL</span></div>
      <p class="muted">First-time setup &mdash; create the administrator account.</p>
      <form id="setupForm" class="form">
        <label>Admin username</label>
        <input name="username" required minlength="3" maxlength="64" autocomplete="username" />
        <label>Admin password</label>
        <input name="password" type="password" required minlength="8" autocomplete="new-password" />
        <button class="btn btn-primary" type="submit">Create Admin Account</button>
        <p class="error" id="setupError"></p>
      </form>
    </div>
  </template>

  <template id="tpl-login">
    <div class="center-card">
      <div class="brand-lg">AZ<span>PANEL</span></div>
      <form id="loginForm" class="form">
        <label>Username</label>
        <input name="username" required autocomplete="username" />
        <label>Password</label>
        <input name="password" type="password" required autocomplete="current-password" />
        <button class="btn btn-primary" type="submit">Sign In</button>
        <p class="error" id="loginError"></p>
      </form>
      <a id="googleLoginLink" class="btn btn-google hidden" href="/auth/google">Continue with Google</a>
    </div>
  </template>

  <template id="tpl-dashboard">
    <h1>Overview</h1>
    <div class="grid" id="sysGrid"></div>
    <h2>Servers</h2>
    <div class="grid" id="serverCards"></div>
  </template>

  <template id="tpl-servers">
    <div class="row-between">
      <h1>Servers</h1>
      <a class="btn btn-primary" href="#/servers/new">+ Create Server</a>
    </div>
    <div class="grid" id="serverCards2"></div>
  </template>

  <template id="tpl-server-detail">
    <div class="row-between">
      <h1 id="srvName">Server</h1>
      <span class="status-pill" id="srvStatus">-</span>
    </div>
    <div class="btn-row">
      <button class="btn" data-action="start">Start</button>
      <button class="btn" data-action="stop">Stop</button>
      <button class="btn" data-action="restart">Restart</button>
      <button class="btn btn-danger" data-action="kill">Kill</button>
      <button class="btn btn-danger" data-action="delete">Delete</button>
    </div>
    <div class="meta-row" id="srvMeta"></div>
    <h2>Console</h2>
    <pre id="console" class="console"></pre>
    <form id="consoleForm" class="console-form">
      <input id="consoleInput" placeholder="Type a Minecraft command and press Enter" autocomplete="off" />
      <button class="btn btn-primary" type="submit">Send</button>
    </form>
  </template>

  <template id="tpl-create-server">
    <h1>Create Server</h1>
    <form id="createForm" class="form">
      <label>Server name</label>
      <input name="name" required maxlength="48" />
      <label>Minecraft version</label>
      <select name="version" id="versionSelect" required></select>
      <label>RAM (MB)</label>
      <input name="ram" type="number" min="512" max="65536" value="2048" required />
      <label>Owner</label>
      <select name="ownerId" id="ownerSelect"><option value="">Me</option></select>
      <label>Port</label>
      <input name="port" type="number" min="1024" max="65535" value="25565" required />
      <label class="checkbox-row">
        <input type="checkbox" name="eulaAccepted" required />
        I accept the <a href="https://www.minecraft.net/en-us/eula" target="_blank" rel="noopener">Minecraft EULA</a>
      </label>
      <button class="btn btn-primary" type="submit">Create Server</button>
      <p class="error" id="createError"></p>
    </form>
  </template>


  <template id="tpl-users">
    <div class="row-between"><h1>Users</h1><button class="btn btn-primary" id="newUserBtn">+ Create User</button></div>
    <div id="usersList" class="stack"></div>
    <div id="userFormWrap" class="card hidden" style="margin-top:1rem">
      <h2 id="userFormTitle">Create User</h2>
      <form id="userForm" class="form">
        <label>Username</label><input name="username" required minlength="3" maxlength="64" autocomplete="off" />
        <label>Email (optional)</label><input name="email" type="email" />
        <label>Password</label><input name="password" type="password" required minlength="8" autocomplete="new-password" />
        <label>Role</label><select name="role"><option value="user">User</option><option value="admin">Admin</option></select>
        <div class="btn-row"><button class="btn btn-primary" type="submit">Create</button><button class="btn" type="button" id="cancelUserBtn">Cancel</button></div>
        <p class="error" id="userFormError"></p>
      </form>
    </div>
  </template>

  <template id="tpl-system">
    <h1>System</h1>
    <div class="grid" id="sysGrid2"></div>
  </template>

  <script src="/app.js"></script>
</body>
</html>
AZPANEL_FILE_EOF_PUBLIC_INDEX_HTML

  cat > "$APP_DIR/public/style.css" <<'AZPANEL_FILE_EOF_PUBLIC_STYLE_CSS'
:root {
  --bg: #0e1116;
  --panel: #161b22;
  --panel-2: #1c232d;
  --border: #262d38;
  --text: #e6edf3;
  --muted: #8b96a5;
  --accent: #5b8cff;
  --accent-2: #2ecc8f;
  --danger: #ff5b6a;
  --warn: #ffb454;
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif;
}
* { box-sizing: border-box; }
body {
  margin: 0;
  background: var(--bg);
  color: var(--text);
}
.hidden { display: none !important; }

.brand, .brand-lg {
  font-weight: 800;
  letter-spacing: 0.5px;
}
.brand span, .brand-lg span { color: var(--accent); }
.brand-lg { font-size: 2rem; margin-bottom: 0.5rem; }

.topbar {
  display: flex;
  align-items: center;
  gap: 1.5rem;
  padding: 0.75rem 1.25rem;
  background: var(--panel);
  border-bottom: 1px solid var(--border);
  position: sticky;
  top: 0;
  z-index: 10;
  flex-wrap: wrap;
}
.topbar nav { display: flex; gap: 1rem; flex-wrap: wrap; }
.topbar nav a { color: var(--muted); text-decoration: none; font-size: 0.9rem; }
.topbar nav a.active, .topbar nav a:hover { color: var(--text); }
.topbar-right { margin-left: auto; display: flex; align-items: center; gap: 0.75rem; }
#whoami { color: var(--muted); font-size: 0.85rem; }

.app { max-width: 1100px; margin: 0 auto; padding: 1.5rem; }

h1 { font-size: 1.4rem; margin: 0.5rem 0 1rem; }
h2 { font-size: 1.1rem; margin: 1.5rem 0 0.75rem; color: var(--muted); }
.muted { color: var(--muted); }

.center-card {
  max-width: 380px;
  margin: 10vh auto;
  background: var(--panel);
  border: 1px solid var(--border);
  border-radius: 12px;
  padding: 2rem;
  text-align: center;
}

.form { display: flex; flex-direction: column; gap: 0.5rem; text-align: left; }
.form label { font-size: 0.8rem; color: var(--muted); margin-top: 0.5rem; }
.form input, .form select {
  background: var(--panel-2);
  border: 1px solid var(--border);
  color: var(--text);
  border-radius: 8px;
  padding: 0.6rem 0.7rem;
  font-size: 0.95rem;
}
.checkbox-row { display: flex; align-items: center; gap: 0.5rem; flex-direction: row; }
.checkbox-row input { width: auto; }

.btn {
  background: var(--panel-2);
  color: var(--text);
  border: 1px solid var(--border);
  border-radius: 8px;
  padding: 0.55rem 1rem;
  cursor: pointer;
  font-size: 0.9rem;
  text-decoration: none;
  display: inline-block;
}
.btn:hover { border-color: var(--accent); }
.btn-primary { background: var(--accent); border-color: var(--accent); color: #fff; }
.btn-danger { background: transparent; border-color: var(--danger); color: var(--danger); }
.btn-ghost { background: transparent; }
.btn-google { margin-top: 1rem; background: #fff; color: #222; }
.btn-row { display: flex; gap: 0.5rem; margin: 1rem 0; flex-wrap: wrap; }

.error { color: var(--danger); font-size: 0.85rem; min-height: 1.2rem; }

.grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); gap: 1rem; }
.card {
  background: var(--panel);
  border: 1px solid var(--border);
  border-radius: 10px;
  padding: 1rem;
}
.card h3 { margin: 0 0 0.25rem; font-size: 1rem; }
.card .muted { font-size: 0.8rem; }
.card a { text-decoration: none; color: inherit; }

.status-pill {
  padding: 0.2rem 0.6rem;
  border-radius: 999px;
  font-size: 0.75rem;
  border: 1px solid var(--border);
}
.status-ONLINE { color: var(--accent-2); border-color: var(--accent-2); }
.status-OFFLINE { color: var(--muted); }
.status-STARTING, .status-STOPPING, .status-INSTALLING { color: var(--warn); border-color: var(--warn); }
.status-CRASHED, .status-ERROR { color: var(--danger); border-color: var(--danger); }

.row-between { display: flex; align-items: center; justify-content: space-between; }
.meta-row { display: flex; gap: 1.5rem; color: var(--muted); font-size: 0.85rem; margin: 0.5rem 0 1rem; flex-wrap: wrap; }

.console {
  background: #05070a;
  border: 1px solid var(--border);
  border-radius: 8px;
  padding: 1rem;
  height: 360px;
  overflow-y: auto;
  font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  font-size: 0.8rem;
  white-space: pre-wrap;
}
.stack { display: grid; gap: 0.75rem; }
.console-form { display: flex; gap: 0.5rem; margin-top: 0.75rem; }
.console-form input {
  flex: 1;
  background: var(--panel-2);
  border: 1px solid var(--border);
  color: var(--text);
  border-radius: 8px;
  padding: 0.55rem 0.7rem;
}

@media (max-width: 640px) {
  .topbar { gap: 0.75rem; }
  .app { padding: 1rem; }
}
AZPANEL_FILE_EOF_PUBLIC_STYLE_CSS

  cat > "$APP_DIR/public/app.js" <<'AZPANEL_FILE_EOF_PUBLIC_APP_JS'
'use strict';
/* AZ PANEL - public/app.js (vanilla JS, no build step required) */

const appEl = document.getElementById('app');
const topbar = document.getElementById('topbar');

async function api(path, options = {}) {
  const resp = await fetch(path, {
    headers: { 'Content-Type': 'application/json' },
    credentials: 'same-origin',
    ...options,
  });
  const isJson = (resp.headers.get('content-type') || '').includes('application/json');
  const data = isJson ? await resp.json() : null;
  if (!resp.ok) throw new Error((data && data.error) || `Request failed (${resp.status})`);
  return data;
}

function tpl(id) {
  return document.getElementById(id).content.cloneNode(true);
}

function fmtBytes(n) {
  if (n == null) return '-';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let i = 0;
  let v = n;
  while (v >= 1024 && i < units.length - 1) { v /= 1024; i++; }
  return `${v.toFixed(1)} ${units[i]}`;
}

function fmtUptime(sec) {
  if (sec == null) return '-';
  const d = Math.floor(sec / 86400);
  const h = Math.floor((sec % 86400) / 3600);
  const m = Math.floor((sec % 3600) / 60);
  return `${d}d ${h}h ${m}m`;
}

// ---------------- routing ----------------
async function route() {
  const hash = location.hash.replace(/^#\/?/, '');
  const [section, sub] = hash.split('/');

  let me = null;
  try {
    const bootstrap = await api('/api/auth/bootstrap');
    if (bootstrap.needsSetup) return renderSetup();
    me = await api('/api/auth/me').catch(() => null);
    if (!me) return renderLogin(bootstrap.googleEnabled);
  } catch (err) {
    return renderLogin(false);
  }

  topbar.classList.remove('hidden');
  document.getElementById('whoami').textContent = `${me.user.username} (${me.user.role})`;
  document.getElementById('usersNav').classList.toggle('hidden', me.user.role !== 'admin');
  document.getElementById('createServerNav').classList.toggle('hidden', me.user.role !== 'admin');
  highlightNav(section || 'dashboard');

  if (!section || section === 'dashboard') return renderDashboard();
  if (section === 'servers' && sub === 'new') return renderCreateServer();
  if (section === 'servers' && sub) return renderServerDetail(sub);
  if (section === 'servers') return renderServers();
  if (section === 'system') return renderSystem();
  if (section === 'users' && me.user.role === 'admin') return renderUsers();
  return renderDashboard();
}

function highlightNav(section) {
  document.querySelectorAll('#nav a').forEach((a) => {
    a.classList.toggle('active', a.dataset.route === section || (section === 'dashboard' && a.dataset.route === 'dashboard'));
  });
}

window.addEventListener('hashchange', route);
window.addEventListener('DOMContentLoaded', () => {
  route();
  document.getElementById('logoutBtn').addEventListener('click', async () => {
    await api('/api/auth/logout', { method: 'POST' });
    location.hash = '';
    topbar.classList.add('hidden');
    route();
  });
});

// ---------------- setup / login ----------------
function renderSetup() {
  topbar.classList.add('hidden');
  appEl.innerHTML = '';
  appEl.appendChild(tpl('tpl-setup'));
  document.getElementById('setupForm').addEventListener('submit', async (e) => {
    e.preventDefault();
    const fd = new FormData(e.target);
    try {
      await api('/api/auth/setup', { method: 'POST', body: JSON.stringify(Object.fromEntries(fd)) });
      location.hash = '#/dashboard';
      route();
    } catch (err) {
      document.getElementById('setupError').textContent = err.message;
    }
  });
}

function renderLogin(googleEnabled) {
  topbar.classList.add('hidden');
  appEl.innerHTML = '';
  appEl.appendChild(tpl('tpl-login'));
  if (googleEnabled) document.getElementById('googleLoginLink').classList.remove('hidden');
  document.getElementById('loginForm').addEventListener('submit', async (e) => {
    e.preventDefault();
    const fd = new FormData(e.target);
    try {
      await api('/api/auth/login', { method: 'POST', body: JSON.stringify(Object.fromEntries(fd)) });
      location.hash = '#/dashboard';
      route();
    } catch (err) {
      document.getElementById('loginError').textContent = err.message;
    }
  });
}

// ---------------- dashboard ----------------
function serverCardHtml(s) {
  return `<a class="card" href="#/servers/${s.id}">
    <h3>${escapeHtml(s.name)}</h3>
    <span class="status-pill status-${s.status}">${s.status}</span>
    <p class="muted">MC ${escapeHtml(s.version)} &middot; ${s.ram}MB &middot; port ${s.port}</p>
  </a>`;
}

function escapeHtml(str) {
  return String(str).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

function sysCardsHtml(sys) {
  return `
    <div class="card"><h3>CPU</h3><p class="muted">${sys.cpuUsagePercent}% of ${sys.cpuCount} cores</p></div>
    <div class="card"><h3>Memory</h3><p class="muted">${fmtBytes(sys.memory.usedBytes)} / ${fmtBytes(sys.memory.totalBytes)}</p></div>
    <div class="card"><h3>Disk</h3><p class="muted">${sys.disk ? `${fmtBytes(sys.disk.usedBytes)} / ${fmtBytes(sys.disk.totalBytes)}` : 'unavailable'}</p></div>
    <div class="card"><h3>Uptime</h3><p class="muted">${fmtUptime(sys.uptimeSeconds)}</p></div>
    <div class="card"><h3>Node.js</h3><p class="muted">${escapeHtml(sys.nodeVersion)}</p></div>
    <div class="card"><h3>Java</h3><p class="muted">${escapeHtml(sys.javaVersion || 'not detected')}</p></div>
  `;
}

async function renderDashboard() {
  appEl.innerHTML = '';
  appEl.appendChild(tpl('tpl-dashboard'));
  const [{ system: sys }, { servers }] = await Promise.all([api('/api/system'), api('/api/servers')]);
  document.getElementById('sysGrid').innerHTML = sysCardsHtml(sys);
  document.getElementById('serverCards').innerHTML = servers.length
    ? servers.map(serverCardHtml).join('')
    : '<p class="muted">No servers yet. <a href="#/servers/new">Create one</a>.</p>';
}

async function renderServers() {
  appEl.innerHTML = '';
  appEl.appendChild(tpl('tpl-servers'));
  const { servers } = await api('/api/servers');
  document.getElementById('serverCards2').innerHTML = servers.length
    ? servers.map(serverCardHtml).join('')
    : '<p class="muted">No servers yet.</p>';
}

async function renderSystem() {
  appEl.innerHTML = '';
  appEl.appendChild(tpl('tpl-system'));
  const { system: sys } = await api('/api/system');
  document.getElementById('sysGrid2').innerHTML = sysCardsHtml(sys);
}

// ---------------- create server ----------------
async function renderCreateServer() {
  appEl.innerHTML = '';
  appEl.appendChild(tpl('tpl-create-server'));
  const select = document.getElementById('versionSelect');
  try {
    const { versions } = await api('/api/versions');
    select.innerHTML = versions.map((v) => `<option value="${v.id}">${v.id}</option>`).join('');
  } catch (err) {
    select.innerHTML = '<option value="">(could not load versions)</option>';
  }
  try {
    const { user } = await api('/api/auth/me');
    if (user.role === 'admin') {
      const { users } = await api('/api/users');
      document.getElementById('ownerSelect').innerHTML = '<option value="">Unassigned</option>' + users.filter(u => !u.disabled).map(u => `<option value="${escapeHtml(u.id)}">${escapeHtml(u.username)} (${escapeHtml(u.role)})</option>`).join('');
    }
  } catch (_) {}
  document.getElementById('createForm').addEventListener('submit', async (e) => {
    e.preventDefault();
    const fd = new FormData(e.target);
    const payload = {
      name: fd.get('name'),
      version: fd.get('version'),
      ram: Number(fd.get('ram')),
      port: Number(fd.get('port')),
      eulaAccepted: fd.get('eulaAccepted') === 'on',
      ownerId: fd.get('ownerId') || null,
    };
    try {
      const { server } = await api('/api/servers', { method: 'POST', body: JSON.stringify(payload) });
      location.hash = `#/servers/${server.id}`;
    } catch (err) {
      document.getElementById('createError').textContent = err.message;
    }
  });
}


// ---------------- user management ----------------
async function renderUsers() {
  appEl.innerHTML = '';
  appEl.appendChild(tpl('tpl-users'));
  await loadUsers();
  document.getElementById('newUserBtn').onclick = () => {
    document.getElementById('userFormWrap').classList.remove('hidden');
    document.getElementById('userForm').reset();
    document.getElementById('userFormError').textContent = '';
  };
  document.getElementById('cancelUserBtn').onclick = () => document.getElementById('userFormWrap').classList.add('hidden');
  document.getElementById('userForm').onsubmit = async (e) => {
    e.preventDefault();
    const fd = new FormData(e.target);
    try {
      await api('/api/users', { method: 'POST', body: JSON.stringify(Object.fromEntries(fd)) });
      document.getElementById('userFormWrap').classList.add('hidden');
      await loadUsers();
    } catch (err) { document.getElementById('userFormError').textContent = err.message; }
  };
}

async function loadUsers() {
  const { users } = await api('/api/users');
  document.getElementById('usersList').innerHTML = users.map(u => `
    <div class="card row-between">
      <div><h3>${escapeHtml(u.username)} <span class="status-pill ${u.disabled ? 'status-ERROR' : 'status-ONLINE'}">${u.disabled ? 'DISABLED' : u.role.toUpperCase()}</span></h3>
      <p class="muted">${escapeHtml(u.email || 'No email')} · created ${new Date(u.createdAt).toLocaleString()}</p></div>
      <div class="btn-row">
        <button class="btn" onclick="toggleUser('${u.id}', ${!u.disabled})">${u.disabled ? 'Enable' : 'Disable'}</button>
        <button class="btn" onclick="resetUserPassword('${u.id}')">Reset Password</button>
        ${u.role !== 'admin' ? `<button class="btn btn-danger" onclick="deleteUser('${u.id}')">Delete</button>` : ''}
      </div>
    </div>`).join('');
}

async function toggleUser(id, disabled) {
  try { await api(`/api/users/${id}`, { method: 'PATCH', body: JSON.stringify({ disabled }) }); await loadUsers(); }
  catch (err) { alert(err.message); }
}
async function resetUserPassword(id) {
  const password = prompt('New password (minimum 8 characters):');
  if (!password) return;
  try { await api(`/api/users/${id}/password`, { method: 'POST', body: JSON.stringify({ password }) }); alert('Password updated.'); }
  catch (err) { alert(err.message); }
}
async function deleteUser(id) {
  if (!confirm('Delete this user?')) return;
  try { await api(`/api/users/${id}`, { method: 'DELETE' }); await loadUsers(); }
  catch (err) { alert(err.message); }
}

// ---------------- server detail / console ----------------
let consoleSocket = null;

async function renderServerDetail(id) {
  appEl.innerHTML = '';
  appEl.appendChild(tpl('tpl-server-detail'));
  await refreshServerDetail(id);

  document.querySelectorAll('[data-action]').forEach((btn) => {
    btn.addEventListener('click', async () => {
      const action = btn.dataset.action;
      if (action === 'delete') {
        if (!confirm('Delete this server? This cannot be undone.')) return;
        const deleteData = confirm('Also permanently delete world/save data?');
        await api(`/api/servers/${id}?deleteData=${deleteData}`, { method: 'DELETE' });
        location.hash = '#/servers';
        return;
      }
      btn.disabled = true;
      try {
        await api(`/api/servers/${id}/${action}`, { method: 'POST' });
        await refreshServerDetail(id);
      } catch (err) {
        alert(err.message);
      } finally {
        btn.disabled = false;
      }
    });
  });

  document.getElementById('consoleForm').addEventListener('submit', async (e) => {
    e.preventDefault();
    const input = document.getElementById('consoleInput');
    const command = input.value.trim();
    if (!command) return;
    input.value = '';
    try {
      if (consoleSocket && consoleSocket.readyState === WebSocket.OPEN) {
        consoleSocket.send(JSON.stringify({ type: 'command', command }));
      } else {
        await api(`/api/servers/${id}/console`, { method: 'POST', body: JSON.stringify({ command }) });
      }
    } catch (err) {
      alert(err.message);
    }
  });

  connectConsole(id);
}

async function refreshServerDetail(id) {
  const { server: s } = await api(`/api/servers/${id}`);
  document.getElementById('srvName').textContent = s.name;
  const pill = document.getElementById('srvStatus');
  pill.textContent = s.status;
  pill.className = `status-pill status-${s.status}`;
  document.getElementById('srvMeta').innerHTML = `
    <span>Version: ${escapeHtml(s.version)}</span>
    <span>RAM: ${s.ram}MB</span>
    <span>Port: ${s.port}</span>
    <span>ID: ${escapeHtml(s.id)}</span>
  `;
}

function connectConsole(id) {
  if (consoleSocket) { try { consoleSocket.close(); } catch (_) {} }
  const proto = location.protocol === 'https:' ? 'wss' : 'ws';
  consoleSocket = new WebSocket(`${proto}://${location.host}/ws/console?server=${encodeURIComponent(id)}`);
  const pre = document.getElementById('console');
  consoleSocket.addEventListener('message', (evt) => {
    try {
      const msg = JSON.parse(evt.data);
      if (msg.type === 'log') {
        pre.textContent = msg.data;
        pre.scrollTop = pre.scrollHeight;
      }
    } catch (_) { /* ignore malformed frame */ }
  });
}
AZPANEL_FILE_EOF_PUBLIC_APP_JS

  log_ok "Application files written."
}

# ---------------------------------------------------------------------------
# .env generation (preserves secrets + settings across updates)
# ---------------------------------------------------------------------------
read_existing_env_var() {
  # $1 = KEY
  [ -f "$ENV_FILE" ] || return 1
  grep -E "^${1}=" "$ENV_FILE" 2>/dev/null | head -n1 | cut -d= -f2-
}

prompt_port() {
  local existing="${1:-}"
  local port="$existing"
  if [ -z "$port" ]; then
    if [ -t 0 ]; then
      read -r -p "Panel HTTP port [${PANEL_PORT_DEFAULT}]: " port
    fi
    port="${port:-$PANEL_PORT_DEFAULT}"
  fi
  if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
    log_warn "Invalid port '$port', falling back to ${PANEL_PORT_DEFAULT}."
    port="$PANEL_PORT_DEFAULT"
  fi
  echo "$port"
}

check_port_in_use() {
  ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1\$"
}

configure_env() {
  log_step "Configuring environment (.env)"
  mkdir -p "$APP_DIR"

  local existing_jwt existing_port existing_gcid existing_gcs existing_gcb
  existing_jwt="$(read_existing_env_var JWT_SECRET || true)"
  existing_port="$(read_existing_env_var PORT || true)"
  existing_gcid="$(read_existing_env_var GOOGLE_CLIENT_ID || true)"
  existing_gcs="$(read_existing_env_var GOOGLE_CLIENT_SECRET || true)"
  existing_gcb="$(read_existing_env_var GOOGLE_CALLBACK_URL || true)"

  local jwt_secret="$existing_jwt"
  if [ -z "$jwt_secret" ]; then
    jwt_secret="$(openssl rand -hex 32)"
    log_ok "Generated a new JWT_SECRET."
  else
    log_ok "Preserving existing JWT_SECRET from previous install."
  fi

  local port
  port="$(prompt_port "${AZ_PANEL_PORT:-$existing_port}")"

  local google_cid="$existing_gcid" google_cs="$existing_gcs" google_cb="$existing_gcb"
  if [ -z "$google_cid" ] && [ -t 0 ] && [ "${AZ_PANEL_NONINTERACTIVE:-0}" != "1" ]; then
    echo
    log_info "Optional: configure Google OAuth login now, or leave blank to skip"
    log_info "(local admin login always works either way; you can configure this"
    log_info "later by editing $ENV_FILE and restarting the panel)."
    read -r -p "Google OAuth Client ID (blank to skip): " google_cid || true
    if [ -n "$google_cid" ]; then
      read -r -p "Google OAuth Client Secret: " google_cs || true
      read -r -p "Panel public URL (e.g. http://1.2.3.4:${port}): " public_url || true
      public_url="${public_url:-http://localhost:${port}}"
      google_cb="${public_url%/}/auth/google/callback"
      log_info "Google callback URL set to: $google_cb"
      log_info "Add this exact URL to your Google Cloud OAuth client's authorized redirect URIs."
    fi
  fi

  cat > "$ENV_FILE" <<ENVEOF
HOST=0.0.0.0
PORT=${port}
JWT_SECRET=${jwt_secret}
PANEL_DIR=${APP_DIR}
PANEL_DATA_DIR=${DATA_DIR}
PANEL_CONFIG_DIR=${CONFIG_DIR}
SUPERVISORCTL_BIN=supervisorctl
GOOGLE_CLIENT_ID=${google_cid}
GOOGLE_CLIENT_SECRET=${google_cs}
GOOGLE_CALLBACK_URL=${google_cb}
ENVEOF
  chmod 600 "$ENV_FILE"
  PANEL_PORT="$port"
  log_ok ".env written (permissions 600)."
}

# ---------------------------------------------------------------------------
# Admin account (created once; never overwritten on update)
# ---------------------------------------------------------------------------
create_admin_account() {
  log_step "Administrator account"

  local has_user
  has_user="$(cd "$APP_DIR" && node -e '
    require("dotenv").config({ path: ".env" });
    try {
      const auth = require("./lib/auth.js");
      process.stdout.write(auth.anyUserExists() ? "yes" : "no");
    } catch (e) { process.stdout.write("no"); }
  ' 2>/dev/null)"

  if [ "$has_user" = "yes" ]; then
    log_ok "An administrator account already exists - leaving it untouched."
    return 0
  fi

  if [ "${AZ_PANEL_NONINTERACTIVE:-0}" = "1" ] || [ ! -t 0 ]; then
    log_warn "Non-interactive install: skipping admin creation."
    log_warn "Visit the panel in a browser to complete first-time setup, or run:"
    log_warn "  azpanel server list   (after creating an account via the web UI)"
    return 0
  fi

  local username password password2
  while true; do
    read -r -p "Admin username: " username
    if [[ "$username" =~ ^[a-zA-Z0-9_.@-]{3,64}$ ]]; then break; fi
    log_warn "Username must be 3-64 characters: letters, numbers, . _ - @"
  done
  while true; do
    read -r -s -p "Admin password (min 8 characters): " password; echo
    read -r -s -p "Confirm password: " password2; echo
    if [ "$password" != "$password2" ]; then
      log_warn "Passwords did not match. Try again."
      continue
    fi
    if [ "${#password}" -lt 8 ]; then
      log_warn "Password must be at least 8 characters."
      continue
    fi
    break
  done

  ADMIN_USERNAME="$username"
  export AZPANEL_TMP_USER="$username" AZPANEL_TMP_PASS="$password"
  (
    cd "$APP_DIR" && node -e '
    require("dotenv").config({ path: ".env" });
    const auth = require("./lib/auth.js");
    auth.createUser({
      username: process.env.AZPANEL_TMP_USER,
      password: process.env.AZPANEL_TMP_PASS,
      role: "admin",
    }).then(() => { console.log("created"); process.exit(0); })
      .catch((e) => { console.error(e.message); process.exit(1); });
    '
  )
  local create_rc=$?
  unset AZPANEL_TMP_USER AZPANEL_TMP_PASS password password2
  [ "$create_rc" -eq 0 ] || die "Failed to create the administrator account"
  log_ok "Administrator account created: $username"
}

# ---------------------------------------------------------------------------
# supervisord (Minecraft process supervision - no systemd)
# ---------------------------------------------------------------------------
write_supervisord_conf() {
  mkdir -p "$CONF_D"
  cat > "$SUPERVISOR_CONF" <<SUPEOF
[unix_http_server]
file=${SUPERVISOR_SOCK}
chmod=0700

[supervisord]
logfile=${LOG_DIR}/supervisord.log
pidfile=${CONFIG_DIR}/supervisord.pid
childlogdir=${LOG_DIR}
nodaemon=false

[rpcinterface:supervisor]
supervisor.rpcinterface_factory = supervisor.rpcinterface:make_main_rpcinterface

[supervisorctl]
serverurl=unix://${SUPERVISOR_SOCK}

[include]
files = ${CONF_D}/*.conf
SUPEOF
}

supervisord_running() {
  supervisorctl -c "$SUPERVISOR_CONF" ping >/dev/null 2>&1
}

ensure_supervisord_running() {
  write_supervisord_conf
  if supervisord_running; then
    log_ok "supervisord already running."
    return 0
  fi
  log_info "Starting supervisord..."
  supervisord -c "$SUPERVISOR_CONF" || die "Failed to start supervisord"
  local tries=0
  until supervisord_running || [ "$tries" -ge 10 ]; do
    sleep 0.5
    tries=$((tries + 1))
  done
  supervisord_running || die "supervisord did not come up"
  log_ok "supervisord is running (socket: $SUPERVISOR_SOCK)"
}

# ---------------------------------------------------------------------------
# CLI install
# ---------------------------------------------------------------------------
install_cli_link() {
  ln -sf "$APP_DIR/bin/azpanel" "$CLI_LINK"
  chmod 755 "$APP_DIR/bin/azpanel"
  chmod 755 "$CLI_LINK" 2>/dev/null || true
  log_ok "CLI installed: azpanel (symlinked to $CLI_LINK)"
}

# ---------------------------------------------------------------------------
# npm install
# ---------------------------------------------------------------------------
npm_install_app() {
  log_step "Installing Node.js dependencies (npm install)"
  (cd "$APP_DIR" && npm install --omit=dev --no-audit --no-fund) \
    || die "npm install failed - check network connectivity and try again"
  log_ok "Node.js dependencies installed."
}

# ---------------------------------------------------------------------------
# Panel process (PM2 - no systemd, ever)
# ---------------------------------------------------------------------------
start_panel_pm2() {
  log_step "Starting AZ PANEL with PM2"
  (cd "$APP_DIR" && pm2 start ecosystem.config.js) || die "PM2 failed to start AZ PANEL"
  (cd "$APP_DIR" && pm2 save) || log_warn "pm2 save failed (process list will not persist across reboots)"
  log_ok "AZ PANEL process started under PM2."
}

verify_panel_listening() {
  log_step "Verifying AZ PANEL is listening"
  local port="${PANEL_PORT:-$(read_existing_env_var PORT || echo "$PANEL_PORT_DEFAULT")}"
  local tries=0
  until curl -fsS "http://127.0.0.1:${port}/api/health" >/dev/null 2>&1 || [ "$tries" -ge 20 ]; do
    sleep 0.5
    tries=$((tries + 1))
  done
  if curl -fsS "http://127.0.0.1:${port}/api/health" >/dev/null 2>&1; then
    log_ok "AZ PANEL responded on http://127.0.0.1:${port}/api/health"
    return 0
  fi
  log_error "AZ PANEL did not respond on port ${port} after installation."
  log_error "Check logs with: azpanel logs   (or) pm2 logs az-panel"
  return 1
}

print_success_banner() {
  local port="${PANEL_PORT:-$(read_existing_env_var PORT || echo "$PANEL_PORT_DEFAULT")}"
  local ip
  ip="$(curl -fsS -4 https://ifconfig.me 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}' || echo "SERVER_IP")"
  echo
  printf "${C_GREEN}${C_BOLD}========================================${C_RESET}\n"
  printf "${C_GREEN}${C_BOLD} KINGCLOUD / AZ PANEL INSTALLED${C_RESET}\n"
  printf "${C_GREEN}${C_BOLD}========================================${C_RESET}\n"
  echo
  echo "Panel:"
  echo "  http://${ip}:${port}"
  echo
  if [ -n "${ADMIN_USERNAME:-}" ]; then
    echo "Admin:"
    echo "  ${ADMIN_USERNAME}"
    echo
  fi
  echo "Panel directory:"
  echo "  ${APP_DIR}"
  echo
  echo "Manage the panel with:"
  echo "  azpanel start | stop | restart | status | logs | update | uninstall"
  echo "  azpanel server list"
  echo
  printf "${C_GREEN}${C_BOLD}========================================${C_RESET}\n"
}

# ---------------------------------------------------------------------------
# High-level commands
# ---------------------------------------------------------------------------
preflight() {
  require_root
  print_banner
  detect_os
  detect_arch
  detect_init
  detect_pkg_manager
}

cmd_install() {
  preflight
  if [ -d "$APP_DIR" ] && [ -f "$ENV_FILE" ]; then
    log_warn "AZ PANEL already appears to be installed at $APP_DIR."
    log_warn "Running the update flow instead (existing data is preserved)."
    cmd_update
    return $?
  fi
  install_base_dependencies
  install_nodejs
  install_java
  install_supervisor
  install_pm2
  generate_app_files
  configure_env
  npm_install_app
  create_admin_account
  install_cli_link
  ensure_supervisord_running
  start_panel_pm2
  verify_panel_listening
  print_success_banner
}

cmd_update() {
  preflight
  [ -d "$APP_DIR" ] || die "AZ PANEL is not installed yet. Run: sudo ./az-panel.sh install"
  install_base_dependencies
  install_nodejs
  install_java
  install_supervisor
  install_pm2
  log_step "Updating AZ PANEL (preserving .env, users, and Minecraft servers)"
  generate_app_files
  configure_env
  npm_install_app
  create_admin_account
  install_cli_link
  ensure_supervisord_running
  (cd "$APP_DIR" && pm2 restart ecosystem.config.js) || start_panel_pm2
  (cd "$APP_DIR" && pm2 save) || true
  verify_panel_listening
  log_ok "AZ PANEL updated successfully. All server data was preserved."
}

cmd_status() {
  print_banner
  echo "KINGCLOUD / AZ PANEL status"
  echo "----------------------------------------"
  if [ -f "$ENV_FILE" ]; then
    echo "Installed at: $APP_DIR"
  else
    echo "AZ PANEL does not appear to be installed."
    return 1
  fi
  local port
  port="$(read_existing_env_var PORT || echo "$PANEL_PORT_DEFAULT")"
  echo "HTTP port:    $port"
  echo "Node:         $(command -v node >/dev/null 2>&1 && node -v || echo 'not found')"
  echo "Java:         $(command -v java >/dev/null 2>&1 && java -version 2>&1 | head -n1 || echo 'not found')"
  echo
  echo "PM2 status:"
  pm2 status az-panel 2>/dev/null || echo "  (pm2 not running / az-panel process not found)"
  echo
  echo "supervisord:"
  if supervisord_running; then
    supervisorctl -c "$SUPERVISOR_CONF" status || true
  else
    echo "  not running"
  fi
  echo
  if curl -fsS "http://127.0.0.1:${port}/api/health" >/dev/null 2>&1; then
    echo "HTTP health check: OK"
  else
    echo "HTTP health check: FAILED"
  fi
}

cmd_start() {
  print_banner
  [ -d "$APP_DIR" ] || die "AZ PANEL is not installed. Run: sudo ./az-panel.sh install"
  ensure_supervisord_running
  (cd "$APP_DIR" && pm2 start ecosystem.config.js 2>/dev/null) || (cd "$APP_DIR" && pm2 restart az-panel)
  (cd "$APP_DIR" && pm2 save) || true
  verify_panel_listening
}

cmd_stop() {
  print_banner
  (cd "$APP_DIR" && pm2 stop az-panel) || log_warn "pm2 stop reported an issue (already stopped?)"
  log_ok "AZ PANEL (web process) stopped. Minecraft servers under supervisord keep running."
}

cmd_restart() {
  print_banner
  (cd "$APP_DIR" && pm2 restart az-panel) || die "Failed to restart AZ PANEL"
  verify_panel_listening
}

cmd_logs() {
  (cd "$APP_DIR" && pm2 logs az-panel --lines "${1:-100}")
}

cmd_uninstall() {
  print_banner
  [ -d "$APP_DIR" ] || die "AZ PANEL is not installed."
  log_warn "This will stop AZ PANEL and remove the application files."
  log_warn "Minecraft server data lives in: $DATA_DIR/servers"
  read -r -p "Type 'yes' to continue uninstalling AZ PANEL: " confirm
  [ "$confirm" = "yes" ] || { log_info "Uninstall cancelled."; return 0; }

  (cd "$APP_DIR" && pm2 delete az-panel 2>/dev/null) || true
  (cd "$APP_DIR" && pm2 save 2>/dev/null) || true

  if supervisord_running; then
    for conf in "$CONF_D"/*.conf; do
      [ -e "$conf" ] || continue
      local prog
      prog="$(basename "$conf" .conf)"
      supervisorctl -c "$SUPERVISOR_CONF" stop "mc-${prog}" >/dev/null 2>&1 || true
    done
    supervisorctl -c "$SUPERVISOR_CONF" shutdown >/dev/null 2>&1 || true
  fi

  rm -f "$CLI_LINK"

  echo
  read -r -p "Also permanently DELETE all AZ PANEL data, including Minecraft worlds, in $APP_DIR? Type 'DELETE' to confirm: " wipe
  if [ "$wipe" = "DELETE" ]; then
    rm -rf -- "${APP_DIR:?}"
    log_ok "Removed $APP_DIR and all Minecraft server data."
  else
    log_info "Application files removed from process managers, but $APP_DIR was left on disk."
    log_info "(Re-run the installer to reuse this data, or delete $APP_DIR manually.)"
  fi
  log_ok "Uninstall complete."
}

show_menu() {
  preflight
  while true; do
    echo
    echo "  [1] Install AZ PANEL"
    echo "  [2] Update AZ PANEL"
    echo "  [3] Status"
    echo "  [4] Start"
    echo "  [5] Stop"
    echo "  [6] Restart"
    echo "  [7] Logs"
    echo "  [8] Uninstall"
    echo "  [9] Exit"
    read -r -p "Select an option [1-9]: " choice
    case "$choice" in
      1) cmd_install ;;
      2) cmd_update ;;
      3) cmd_status ;;
      4) cmd_start ;;
      5) cmd_stop ;;
      6) cmd_restart ;;
      7) cmd_logs ;;
      8) cmd_uninstall ;;
      9) exit 0 ;;
      *) log_warn "Invalid option." ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
main() {
  local action="${1:-}"
  case "$action" in
    install) cmd_install ;;
    update) cmd_update ;;
    status) cmd_status ;;
    start) preflight; cmd_start ;;
    stop) preflight; cmd_stop ;;
    restart) preflight; cmd_restart ;;
    logs) shift || true; cmd_logs "${1:-100}" ;;
    uninstall) cmd_uninstall ;;
    "") show_menu ;;
    *)
      echo "Usage: $0 {install|update|status|start|stop|restart|logs|uninstall}"
      exit 1
      ;;
  esac
}

main "$@"
