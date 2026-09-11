cat > ~/linplus/server.js << 'ENDOFFILE'
// ============================================================
//  Lin+ — социальная сеть на Node.js
//  Хост: 195.43.142.215:9002
//  Серверный рендер + Holo-дизайн на всех страницах
// ============================================================

const express = require('express');
const session = require('express-session');
const axios = require('axios');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

// ============================================================
//  КОНФИГУРАЦИЯ
// ============================================================
const HOST = '195.43.142.215';
const PORT = process.env.PORT || 9002;
const BASE_URL = `http://${HOST}:${PORT}`;

const CLIENT_ID = 'linplus';
const CLIENT_SECRET = 't5T9rPhVFbZzCtjn3Tsa8yUVbMKydxbt';
const REDIRECT_URI = process.env.REDIRECT_URI || `${BASE_URL}/callback`;
const LINACCOUNTS_URL = 'http://195.43.142.215:9001';

const SITE_DIR = path.join(__dirname, 'site');
const DATA_DIR = path.join(__dirname, 'data');
const USERS_FILE = path.join(DATA_DIR, 'users.json');
const POSTS_FILE = path.join(DATA_DIR, 'posts.json');

// ============================================================
//  АНТИ-ФЛУД
// ============================================================
const RATE_LIMITS = {
  post:      { windowMs: 5 * 1000,       max: 1,   banMs: 15 * 1000 },
  postWin:   { windowMs: 5 * 60 * 1000,  max: 60,  banMs: 60 * 1000 },
  comment:   { windowMs: 3 * 1000,       max: 1,   banMs: 15 * 1000 },
  commentWin:{ windowMs: 5 * 60 * 1000,  max: 100, banMs: 60 * 1000 },
  like:      { windowMs: 60 * 1000,      max: 300, banMs: 30 * 1000 },
  repost:    { windowMs: 5 * 60 * 1000,  max: 30,  banMs: 60 * 1000 },
  search:    { windowMs: 60 * 1000,      max: 120, banMs: 30 * 1000 },
  global:    { windowMs: 10 * 1000,      max: 300, banMs: 30 * 1000 }
};

const rateStore = new Map();
const banStore = new Map();

setInterval(() => {
  const now = Date.now();
  for (const [key, entry] of rateStore) {
    entry.hits = entry.hits.filter(t => now - t < 10 * 60 * 1000);
    if (entry.hits.length === 0) rateStore.delete(key);
  }
  for (const [key, entry] of banStore) {
    if (entry.until < now) banStore.delete(key);
  }
}, 5 * 60 * 1000);

function checkRateLimit(type, identifier) {
  const cfg = RATE_LIMITS[type];
  if (!cfg) return null;
  const key = `${type}:${identifier}`;
  const now = Date.now();

  const ban = banStore.get(key);
  if (ban && ban.until > now) {
    return { retryAfter: Math.ceil((ban.until - now) / 1000) };
  }

  let entry = rateStore.get(key);
  if (!entry) { entry = { hits: [] }; rateStore.set(key, entry); }
  entry.hits = entry.hits.filter(t => now - t < cfg.windowMs);

  if (entry.hits.length >= cfg.max) {
    banStore.set(key, { until: now + cfg.banMs });
    return { retryAfter: Math.ceil(cfg.banMs / 1000) };
  }
  entry.hits.push(now);
  return null;
}

const recentContent = new Map();
function isDuplicate(userId, content, windowMs = 5 * 60 * 1000) {
  const now = Date.now();
  const arr = (recentContent.get(userId) || []).filter(x => now - x.ts < windowMs);
  const hash = crypto.createHash('md5').update(content.trim().toLowerCase()).digest('hex');
  if (arr.some(x => x.hash === hash)) {
    recentContent.set(userId, arr);
    return true;
  }
  arr.push({ hash, ts: now });
  recentContent.set(userId, arr);
  return false;
}

// ============================================================
//  ИНИЦИАЛИЗАЦИЯ
// ============================================================
if (!fs.existsSync(SITE_DIR)) fs.mkdirSync(SITE_DIR, { recursive: true });
if (!fs.existsSync(DATA_DIR)) fs.mkdirSync(DATA_DIR, { recursive: true });
if (!fs.existsSync(USERS_FILE)) fs.writeFileSync(USERS_FILE, JSON.stringify({ users: [] }, null, 2));
if (!fs.existsSync(POSTS_FILE)) fs.writeFileSync(POSTS_FILE, JSON.stringify({ posts: [] }, null, 2));

// ============================================================
//  ХРАНИЛИЩЕ
// ============================================================
const loadUsers = () => { try { return JSON.parse(fs.readFileSync(USERS_FILE, 'utf8')).users || []; } catch { return []; } };
const saveUsers = (u) => fs.writeFileSync(USERS_FILE, JSON.stringify({ users: u }, null, 2));
const loadPosts = () => { try { return JSON.parse(fs.readFileSync(POSTS_FILE, 'utf8')).posts || []; } catch { return []; } };
const savePosts = (p) => fs.writeFileSync(POSTS_FILE, JSON.stringify({ posts: p }, null, 2));

const getUserById = (id) => loadUsers().find(u => u.id === id) || null;
const getUserByUsername = (username) => loadUsers().find(u => u.username === username) || null;

function createUser({ username, email, avatar }) {
  const users = loadUsers();
  const maxId = users.reduce((m, u) => Math.max(m, u.id), 0);
  const newUser = { id: maxId + 1, username, email: email || null, avatar: avatar || '#33B5E5', oauth: true, created_at: Date.now() };
  users.push(newUser);
  saveUsers(users);
  return newUser;
}
function updateUser(user) {
  const users = loadUsers();
  const idx = users.findIndex(u => u.id === user.id);
  if (idx !== -1) { users[idx] = user; saveUsers(users); }
}

function normalizePost(p) {
  if (!Array.isArray(p.likes)) p.likes = [];
  if (!Array.isArray(p.comments)) p.comments = [];
  if (!Array.isArray(p.reposts)) p.reposts = [];
  if (typeof p.repost_of === 'undefined') p.repost_of = null;
  return p;
}

const getPosts = () => loadPosts().map(normalizePost).sort((a, b) => b.timestamp - a.timestamp);
const getPostById = (id) => { const p = loadPosts().find(x => x.id === id); return p ? normalizePost(p) : null; };

function addPost(userId, content, repostOf = null) {
  const posts = loadPosts();
  const maxId = posts.reduce((m, p) => Math.max(m, p.id), 0);
  posts.push({ id: maxId + 1, user_id: userId, content, timestamp: Date.now(), likes: [], comments: [], reposts: [], repost_of: repostOf });
  savePosts(posts);
}

function toggleLike(postId, userId) {
  const posts = loadPosts();
  const idx = posts.findIndex(p => p.id === postId);
  if (idx === -1) return null;
  const p = normalizePost(posts[idx]);
  const likeIdx = p.likes.indexOf(userId);
  if (likeIdx === -1) p.likes.push(userId);
  else p.likes.splice(likeIdx, 1);
  posts[idx] = p;
  savePosts(posts);
}

function addComment(postId, userId, content) {
  const posts = loadPosts();
  const idx = posts.findIndex(p => p.id === postId);
  if (idx === -1) return null;
  const p = normalizePost(posts[idx]);
  const maxCid = p.comments.reduce((m, c) => Math.max(m, c.id || 0), 0);
  p.comments.push({ id: maxCid + 1, user_id: userId, content, timestamp: Date.now() });
  posts[idx] = p;
  savePosts(posts);
}

function addRepost(postId, userId) {
  const original = getPostById(postId);
  if (!original) return null;
  const posts = loadPosts();
  const idx = posts.findIndex(p => p.id === postId);
  if (idx !== -1) {
    const p = normalizePost(posts[idx]);
    if (!p.reposts.includes(userId)) {
      p.reposts.push(userId);
      posts[idx] = p;
      savePosts(posts);
    }
  }
  const content = `Репост от @${getUserById(original.user_id)?.username || 'user'}:\n\n${original.content}`;
  addPost(userId, content, original.id);
}

function deletePost(postId, userId) {
  const posts = loadPosts();
  const idx = posts.findIndex(p => p.id === postId);
  if (idx === -1) return { ok: false, reason: 'not_found' };
  const p = normalizePost(posts[idx]);
  if (p.user_id !== userId) return { ok: false, reason: 'forbidden' };
  savePosts(posts.filter(x => x.id !== postId && x.repost_of !== postId));
  return { ok: true };
}

function searchPosts(query) {
  const q = query.toLowerCase().trim();
  if (!q) return getPosts();
  return getPosts().filter(p => {
    const user = getUserById(p.user_id);
    return p.content.toLowerCase().includes(q) || (user && user.username.toLowerCase().includes(q));
  });
}

// ============================================================
//  EXPRESS
// ============================================================
const app = express();
app.set('trust proxy', 1);
app.use(express.urlencoded({ extended: true }));
app.use(express.json());
app.use(session({
  secret: 'linplus-secret-key-change-me',
  resave: false,
  saveUninitialized: false,
  cookie: { maxAge: 7 * 24 * 60 * 60 * 1000 }
}));

app.use(express.static(SITE_DIR, {
  index: false,
  maxAge: '1h',
  setHeaders: (res, filePath) => {
    if (/\.(woff2?|ttf|otf|eot)$/i.test(filePath)) {
      res.setHeader('Cache-Control', 'public, max-age=31536000, immutable');
    }
  }
}));

app.use((req, res, next) => {
  req.user = req.session.user_id ? getUserById(req.session.user_id) : null;
  next();
});

app.use((req, res, next) => {
  const ip = req.ip || 'unknown';
  const limit = checkRateLimit('global', ip);
  if (limit) return sendFloodPage(res, req, limit.retryAfter, 'Слишком много запросов с вашего IP');
  next();
});

// ============================================================
//  УТИЛИТЫ
// ============================================================
function escapeHtml(str) {
  if (!str) return '';
  return String(str).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}
function formatDate(ts) {
  const now = Date.now();
  const diff = Math.floor((now - ts) / 1000);
  if (diff < 60) return 'только что';
  if (diff < 3600) return Math.floor(diff / 60) + ' мин назад';
  if (diff < 86400) return Math.floor(diff / 3600) + ' ч назад';
  const d = new Date(ts);
  const pad = n => String(n).padStart(2, '0');
  return `${pad(d.getDate())}.${pad(d.getMonth()+1)}.${d.getFullYear()} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}
const initial = (name) => (name && name[0] ? name[0].toUpperCase() : '?');

// ============================================================
//  СТИЛИ
// ============================================================
const COMMON_STYLES = `
@import url(https://fonts.googleapis.com/css?family=Roboto:400,400italic,500,700,700italic);
* { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
html { scroll-behavior: smooth; }
html, body { margin: 0; padding: 0; }
body {
  font-family: Roboto, "Droid Sans", -apple-system, BlinkMacSystemFont, sans-serif;
  background-color: #000; color: #eee;
  padding-top: 56px; padding-bottom: 76px;
  min-height: 100vh; -webkit-font-smoothing: antialiased;
}
body::before { content: ""; position: fixed; inset: 0; z-index: -1; background: linear-gradient(#000000, #272D33); }
a { color: #33B5E5; text-decoration: none; transition: color .2s; }
a:hover { color: #66C9F0; }
::selection { background: rgba(51,181,229,0.5); color: #fff; }
::-webkit-scrollbar { width: 10px; height: 10px; }
::-webkit-scrollbar-track { background: #0a0a0a; }
::-webkit-scrollbar-thumb { background: #333; }
::-webkit-scrollbar-thumb:hover { background: #444; }

.material-symbols-outlined {
  font-variation-settings: 'FILL' 0, 'wght' 400, 'GRAD' 0, 'opsz' 24;
  font-size: 20px; line-height: 1; user-select: none;
  vertical-align: middle; display: inline-block; font-display: block;
}
.material-symbols-outlined.filled { font-variation-settings: 'FILL' 1, 'wght' 400, 'GRAD' 0, 'opsz' 24; }

/* ============================================================
   ВЕРХНЯЯ ПАНЕЛЬ
   ============================================================ */
.topbar {
  position: fixed; top: 0; left: 0; right: 0; height: 52px;
  background: linear-gradient(#0a0a0a, #050505);
  border-bottom: 2px solid #33B5E5;
  padding: 0 16px; display: flex; align-items: center; gap: 12px;
  z-index: 1000; box-shadow: inset 0 1px 0 0 rgba(255,255,255,0.05);
}
.logo { font-size: 22px; font-weight: 700; letter-spacing: -0.5px; flex-shrink: 0; display: flex; align-items: center; user-select: none; }
.logo .lin { color: #FF8800; }
.logo .plus { color: #66FF00; margin-left: 1px; }
.search { flex: 1; position: relative; }
.search input {
  width: 100%; padding: 7px 12px 7px 36px;
  border: 1px solid #2a2a2a; border-top-color: #333; border-bottom-color: #1a1a1a;
  border-radius: 2px; background: #0d0d0d; color: #eee;
  font-size: 14px; font-family: inherit; outline: none;
  transition: border-color .15s, box-shadow .15s;
}
.search input::placeholder { color: #666; }
.search input:focus { border-color: #33B5E5; background: #0f1a20; box-shadow: 0 0 0 1px #33B5E5, 0 0 8px rgba(51,181,229,0.4); }
.search .icon { position: absolute; left: 10px; top: 50%; transform: translateY(-50%); color: #666; pointer-events: none; display: flex; align-items: center; }
.search .icon .material-symbols-outlined { font-size: 18px; }

.topbar .user-btn {
  width: 32px; height: 32px; border-radius: 2px; background: #33B5E5;
  display: flex; align-items: center; justify-content: center;
  font-weight: 700; font-size: 14px; color: #fff;
  cursor: pointer; flex-shrink: 0; border: 1px solid #1F8DB5;
  transition: background .15s;
}
.topbar .user-btn:hover { background: #4DC0E8; }
.topbar .user-btn:active { background: #1F8DB5; }

.btn-holo {
  padding: 7px 16px;
  background: linear-gradient(#3a3a3a, #2a2a2a);
  border: 1px solid #1a1a1a; border-top-color: #4a4a4a;
  border-radius: 2px; color: #eee;
  font-weight: 500; font-size: 13px; font-family: inherit;
  cursor: pointer; display: inline-flex; align-items: center; gap: 6px;
  transition: background .15s; text-decoration: none;
}
.btn-holo:hover { background: linear-gradient(#434343, #333); border-top-color: #555; }
.btn-holo:active { background: linear-gradient(#1F8DB5, #33B5E5); border-color: #33B5E5; color: #fff; box-shadow: 0 0 0 1px #33B5E5, 0 0 8px rgba(51,181,229,0.5); }
.btn-holo.primary { background: linear-gradient(#33B5E5, #1F8DB5); border-color: #1F8DB5; border-top-color: #66C9F0; color: #fff; }
.btn-holo.primary:hover { background: linear-gradient(#4DC0E8, #33B5E5); }

.btn-login-top {
  padding: 7px 16px;
  background: linear-gradient(#3a3a3a, #2a2a2a);
  border: 1px solid #1a1a1a; border-top-color: #4a4a4a;
  border-radius: 2px; color: #eee;
  font-weight: 500; font-size: 13px; font-family: inherit;
  cursor: pointer; flex-shrink: 0;
  display: inline-flex; align-items: center; gap: 6px;
  transition: background .15s; text-decoration: none;
}
.btn-login-top:hover { background: linear-gradient(#434343, #333); border-top-color: #555; }
.btn-login-top:active { background: linear-gradient(#1F8DB5, #33B5E5); border-color: #33B5E5; color: #fff; }
.btn-login-top .material-symbols-outlined { font-size: 16px; }

.container { max-width: 620px; margin: 0 auto; padding: 12px 12px 0; }

.avatar {
  width: 44px; height: 44px; border-radius: 2px;
  display: flex; align-items: center; justify-content: center;
  color: #fff; font-weight: 700; font-size: 18px; flex-shrink: 0;
  background: #33B5E5; border: 1px solid #1F8DB5;
  user-select: none; position: relative; overflow: hidden;
}

.post {
  background: #141414; border: 1px solid #262626;
  border-top-color: #333; border-bottom-color: #1a1a1a;
  border-radius: 2px; padding: 14px; margin-bottom: 10px;
  position: relative; transition: border-color .2s;
}
.post:hover { border-color: #333; border-top-color: #444; }
.post-header { display: flex; align-items: center; gap: 12px; margin-bottom: 10px; }
.post-header .meta { min-width: 0; }
.post-author { font-weight: 600; font-size: 15px; color: #eee; display: flex; align-items: center; gap: 6px; }
.post-author a { color: #eee; }
.post-author a:hover { color: #33B5E5; }
.post-time { font-size: 12px; color: #777; margin-top: 2px; }
.post-content { font-size: 15px; line-height: 1.5; color: #ddd; margin: 4px 0 12px; white-space: pre-wrap; word-wrap: break-word; }

.repost-box { background: #0d0d0d; border-left: 3px solid #66FF00; padding: 10px 12px; margin: 6px 0 12px; font-size: 14px; color: #bbb; line-height: 1.4; }
.repost-box .repost-label { display: inline-flex; align-items: center; gap: 5px; color: #66FF00; font-weight: 600; }
.repost-box .repost-label .material-symbols-outlined { font-size: 16px; }

.post-actions { display: flex; padding-top: 10px; margin-top: 6px; border-top: 1px solid #262626; }
.post-actions form { margin: 0; padding: 0; flex: 1; display: flex; }
.post-actions button {
  flex: 1; background: transparent; border: none;
  border-right: 1px solid #262626; color: #999;
  font-size: 12px; font-weight: 500; font-family: inherit;
  padding: 10px 4px; margin: 0; border-radius: 0; cursor: pointer;
  display: inline-flex; align-items: center; justify-content: center;
  gap: 6px; text-transform: uppercase; letter-spacing: .5px;
  transition: background .15s, color .15s;
}
.post-actions button:last-child,
.post-actions form:last-child button { border-right: none; }
.post-actions button .material-symbols-outlined { font-size: 18px; }
.post-actions button:hover { color: #33B5E5; background: rgba(51,181,229,0.08); }
.post-actions button.liked { color: #33B5E5; }
.post-actions button.reposted { color: #66FF00; }
.post-actions button.danger:hover { color: #ff5252; background: rgba(255,82,82,0.10); }

.delete-top {
  position: absolute; top: 8px; right: 8px;
  width: 28px; height: 28px; border-radius: 2px;
  background: transparent; border: none; color: #555;
  cursor: pointer; display: flex; align-items: center; justify-content: center;
  transition: background .15s, color .15s;
}
.delete-top .material-symbols-outlined { font-size: 18px; }
.delete-top:hover { background: rgba(255,82,82,0.15); color: #ff5252; }

.comments { margin-top: 12px; padding-top: 12px; border-top: 1px solid #262626; }
.comments-title { font-size: 12px; font-weight: 600; color: #33B5E5; text-transform: uppercase; letter-spacing: .5px; margin-bottom: 10px; display: flex; align-items: center; gap: 6px; }
.comments-title .material-symbols-outlined { font-size: 16px; }
.comment { display: flex; gap: 10px; padding: 10px; background: #0d0d0d; border: 1px solid #1a1a1a; border-radius: 2px; margin-bottom: 6px; }
.comment .avatar { width: 30px; height: 30px; font-size: 12px; }
.comment-body { flex: 1; min-width: 0; }
.comment-head { display: flex; align-items: baseline; gap: 6px; flex-wrap: wrap; }
.comment-author { font-size: 13px; font-weight: 600; color: #33B5E5; }
.comment-time { font-size: 11px; color: #666; }
.comment-text { font-size: 14px; color: #ccc; margin-top: 3px; line-height: 1.4; word-wrap: break-word; }
.comment-form { display: flex; gap: 6px; margin-top: 10px; }
.comment-form input { flex: 1; padding: 9px 12px; border: 1px solid #2a2a2a; border-top-color: #333; border-radius: 2px; background: #0d0d0d; color: #eee; font-size: 14px; font-family: inherit; outline: none; transition: border-color .15s, box-shadow .15s; min-width: 0; }
.comment-form input:focus { border-color: #33B5E5; box-shadow: 0 0 0 1px #33B5E5, 0 0 8px rgba(51,181,229,0.3); }
.comment-form button { padding: 9px 16px; background: linear-gradient(#3a3a3a, #2a2a2a); border: 1px solid #1a1a1a; border-top-color: #4a4a4a; border-radius: 2px; color: #eee; font-weight: 500; font-size: 12px; font-family: inherit; text-transform: uppercase; letter-spacing: .5px; cursor: pointer; flex-shrink: 0; display: inline-flex; align-items: center; gap: 6px; transition: background .15s; }
.comment-form button:hover { background: linear-gradient(#434343, #333); }
.comment-form button:active { background: linear-gradient(#1F8DB5, #33B5E5); border-color: #33B5E5; color: #fff; }
.comment-form button .material-symbols-outlined { font-size: 16px; }
.comment-login { text-align: center; padding: 12px; background: #0d0d0d; border: 1px solid #1a1a1a; border-radius: 2px; color: #888; font-size: 13px; margin-top: 8px; display: flex; align-items: center; justify-content: center; gap: 6px; flex-wrap: wrap; }
.comment-login .material-symbols-outlined { font-size: 16px; color: #FF8800; }

.empty { text-align: center; padding: 60px 20px; color: #666; }
.empty .material-symbols-outlined { font-size: 72px; color: #2a2a2a; margin-bottom: 12px; display: block; font-variation-settings: 'FILL' 0, 'wght' 300, 'GRAD' 0, 'opsz' 48; }
.empty p { margin: 6px 0; font-size: 15px; }

.profile-card { background: #141414; border: 1px solid #262626; border-top-color: #333; border-bottom-color: #1a1a1a; border-radius: 2px; padding: 24px 20px 20px; margin-bottom: 14px; text-align: center; }
.profile-avatar { width: 84px; height: 84px; border-radius: 2px; margin: 0 auto 14px; display: flex; align-items: center; justify-content: center; font-size: 34px; font-weight: 700; color: #fff; border: 2px solid #000; box-shadow: 0 2px 8px rgba(0,0,0,0.6); background: #33B5E5; }
.profile-name { font-size: 22px; font-weight: 700; letter-spacing: -0.3px; }
.profile-email { color: #888; font-size: 13px; margin-top: 6px; display: flex; align-items: center; justify-content: center; gap: 6px; }
.profile-email .material-symbols-outlined { font-size: 16px; }
.profile-badge { display: inline-flex; align-items: center; gap: 5px; background: linear-gradient(#FF8800, #E67800); border: 1px solid #CC6A00; color: #fff; padding: 4px 12px; border-radius: 2px; font-size: 11px; font-weight: 600; margin-top: 12px; }
.profile-badge .material-symbols-outlined { font-size: 14px; }
.profile-logout { display: inline-flex; align-items: center; gap: 7px; margin-top: 14px; padding: 8px 18px; background: linear-gradient(#3a3a3a, #2a2a2a); color: #ff6b6b; border: 1px solid #1a1a1a; border-top-color: #4a4a4a; border-radius: 2px; font-weight: 500; font-size: 12px; text-transform: uppercase; letter-spacing: .5px; cursor: pointer; transition: background .15s, color .15s; text-decoration: none; }
.profile-logout .material-symbols-outlined { font-size: 16px; }
.profile-logout:hover { background: linear-gradient(#4a2a2a, #3a2020); color: #ff8888; border-top-color: #ff6b6b; }
.profile-logout:active { background: linear-gradient(#ff5252, #cc4040); color: #fff; border-color: #ff5252; }

.profile-stats { display: flex; justify-content: center; margin-top: 20px; padding-top: 16px; border-top: 1px solid #262626; }
.stat { text-align: center; flex: 1; padding: 0 12px; border-right: 1px solid #262626; }
.stat:last-child { border-right: none; }
.stat .num { font-size: 20px; font-weight: 700; color: #33B5E5; }
.stat .lbl { font-size: 11px; color: #888; margin-top: 2px; text-transform: uppercase; letter-spacing: .5px; }

.section-title { font-weight: 500; margin: 20px 0 12px; color: #33B5E5; font-size: 13px; text-transform: uppercase; letter-spacing: .8px; padding-bottom: 6px; border-bottom: 2px solid #33B5E5; }

.nav {
  position: fixed; bottom: 0; left: 0; right: 0; height: 60px;
  background: linear-gradient(#0a0a0a, #050505);
  border-top: 1px solid #262626;
  box-shadow: inset 0 1px 0 0 rgba(255,255,255,0.05);
  display: flex; z-index: 1000;
}
.nav-btn {
  flex: 1; background: transparent; border: none;
  border-right: 1px solid #1a1a1a; color: #777;
  font-family: inherit; font-size: 11px; font-weight: 500;
  text-transform: uppercase; letter-spacing: .5px;
  display: flex; flex-direction: column; align-items: center; justify-content: center;
  gap: 3px; cursor: pointer; padding: 8px 0;
  position: relative; outline: none;
  transition: color .15s, background .15s; text-decoration: none;
}
.nav-btn:last-child { border-right: none; }
.nav-btn .material-symbols-outlined { font-size: 24px; transition: transform .2s; }
.nav-btn:hover { color: #33B5E5; background: rgba(51,181,229,0.05); }
.nav-btn.active { color: #33B5E5; background: rgba(51,181,229,0.08); }
.nav-btn.active::after { content: ""; position: absolute; bottom: 0; left: 0; right: 0; height: 3px; background: #33B5E5; box-shadow: 0 0 8px rgba(51,181,229,0.8); }

.nav-fab {
  position: absolute; top: -26px; left: 50%; transform: translateX(-50%);
  width: 56px; height: 56px; border-radius: 2px;
  background: linear-gradient(#33B5E5, #1F8DB5);
  border: 2px solid #000; border-top-color: #66C9F0;
  color: #fff; cursor: pointer;
  display: flex; align-items: center; justify-content: center;
  box-shadow: 0 4px 16px rgba(51,181,229,0.5);
  transition: background .15s, transform .15s, box-shadow .15s;
  z-index: 1001; padding: 0; text-decoration: none;
}
.nav-fab .material-symbols-outlined { font-size: 30px; font-variation-settings: 'FILL' 0, 'wght' 500, 'GRAD' 0, 'opsz' 24; }
.nav-fab:hover { background: linear-gradient(#4DC0E8, #33B5E5); transform: translateX(-50%) translateY(-2px); box-shadow: 0 6px 20px rgba(51,181,229,0.7); }
.nav-fab:active { transform: translateX(-50%) scale(0.94); background: linear-gradient(#1F8DB5, #186F90); }
.nav > .nav-btn:first-child { margin-right: 28px; }
.nav > .nav-btn:last-child { margin-left: 28px; }

/* ============================================================
   СЛУЖЕБНЫЕ СТРАНИЦЫ — единый Holo-стиль
   ============================================================ */
.holo-page {
  min-height: calc(100vh - 130px);
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 20px 12px;
}
.holo-card {
  background: #141414;
  border: 1px solid #262626;
  border-top-color: #333;
  border-bottom-color: #1a1a1a;
  border-radius: 2px;
  padding: 0;
  max-width: 460px;
  width: 100%;
  box-shadow: 0 4px 20px rgba(0,0,0,0.6);
  overflow: hidden;
}
.holo-card-header {
  padding: 14px 20px;
  background: linear-gradient(#0a0a0a, #050505);
  border-bottom: 2px solid #33B5E5;
  display: flex;
  align-items: center;
  gap: 10px;
  box-shadow: inset 0 1px 0 0 rgba(255,255,255,0.05);
}
.holo-card-header .material-symbols-outlined {
  color: #33B5E5;
  font-size: 22px;
}
.holo-card-title {
  font-size: 14px;
  font-weight: 600;
  color: #33B5E5;
  text-transform: uppercase;
  letter-spacing: .8px;
}
.holo-card-body { padding: 24px 20px; text-align: center; }
.holo-card-icon {
  font-size: 64px !important;
  color: #33B5E5;
  display: block;
  margin: 0 auto 12px;
  font-variation-settings: 'FILL' 0, 'wght' 300, 'GRAD' 0, 'opsz' 48;
}
.holo-card-icon.error { color: #ff5252; }
.holo-card-icon.warning { color: #FF8800; }
.holo-card-icon.success { color: #66FF00; }
.holo-card h1 {
  font-size: 22px;
  font-weight: 500;
  margin: 0 0 8px;
  color: #eee;
  letter-spacing: -0.3px;
}
.holo-card h1.error { color: #ff5252; }
.holo-card p {
  color: #999;
  font-size: 14px;
  line-height: 1.5;
  margin: 6px 0;
}
.holo-card p.muted { color: #666; font-size: 12px; }
.holo-card-actions {
  display: flex;
  gap: 8px;
  justify-content: center;
  margin-top: 20px;
  flex-wrap: wrap;
}

/* Логотип внутри карточки */
.holo-logo {
  font-size: 42px;
  font-weight: 700;
  letter-spacing: -1px;
  margin-bottom: 6px;
  user-select: none;
  text-align: center;
}
.holo-logo .lin { color: #FF8800; }
.holo-logo .plus { color: #66FF00; }

/* Счётчик на странице анти-флуда */
.holo-timer {
  color: #FF8800;
  font-size: 26px;
  font-weight: 700;
  margin: 18px 0 4px;
  letter-spacing: 0.5px;
}
.holo-timer-label {
  color: #666;
  font-size: 12px;
  text-transform: uppercase;
  letter-spacing: .5px;
  margin-bottom: 8px;
}

/* OAuth-кнопка (login) */
.oauth-btn {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  gap: 8px;
  width: 100%;
  padding: 14px 20px;
  background: linear-gradient(#33B5E5, #1F8DB5);
  border: 1px solid #1F8DB5;
  border-top-color: #66C9F0;
  border-radius: 2px;
  color: #fff;
  font-size: 15px;
  font-weight: 500;
  font-family: inherit;
  text-decoration: none;
  cursor: pointer;
  transition: background .15s;
}
.oauth-btn:hover { background: linear-gradient(#4DC0E8, #33B5E5); color: #fff; }
.oauth-btn:active { background: linear-gradient(#1F8DB5, #186F90); }
.oauth-btn .material-symbols-outlined { font-size: 20px; }

/* Форма создания поста */
.create-form textarea {
  width: 100%; min-height: 160px;
  background: #0d0d0d;
  border: 1px solid #2a2a2a;
  border-top-color: #333;
  border-radius: 2px;
  color: #eee; font-family: inherit; font-size: 15px;
  line-height: 1.5; padding: 12px; outline: none;
  resize: vertical;
  transition: border-color .15s, box-shadow .15s;
}
.create-form textarea:focus { border-color: #33B5E5; box-shadow: 0 0 0 1px #33B5E5, 0 0 8px rgba(51,181,229,0.3); }

/* ============================================================
   АДАПТИВ
   ============================================================ */
@media (max-width: 480px) {
  .container { padding: 8px 8px 0; }
  .post { padding: 12px; }
  .post-actions button { font-size: 10px; padding: 10px 2px; letter-spacing: 0; }
  .stat { padding: 0 6px; }
  .logo { font-size: 20px; }
  .search input { font-size: 13px; padding: 7px 10px 7px 32px; }
  .nav-fab { width: 52px; height: 52px; top: -22px; }
  .nav-fab .material-symbols-outlined { font-size: 26px; }
  .holo-page { padding: 12px 8px; min-height: calc(100vh - 120px); }
  .holo-card-body { padding: 20px 16px; }
  .holo-logo { font-size: 36px; }
}
@media (min-width: 640px) {
  .container { max-width: 680px; padding: 16px 20px 0; }
  .post { padding: 16px; }
  .post-content { font-size: 16px; line-height: 1.55; }
  .avatar { width: 48px; height: 48px; font-size: 20px; }
  .post-actions button { font-size: 13px; padding: 10px 8px; }
  .comment-text { font-size: 15px; }
  .profile-card { padding: 30px 26px 24px; }
  .profile-avatar { width: 96px; height: 96px; font-size: 38px; }
  .profile-name { font-size: 24px; }
}
@media (min-width: 900px) {
  body { padding-bottom: 20px; }
  .nav {
    position: fixed; top: 52px; left: 0; right: auto; bottom: 0;
    width: 220px; height: auto; flex-direction: column;
    align-items: stretch; justify-content: flex-start;
    padding: 12px 8px; border-top: none; border-right: 1px solid #262626;
    background: #0a0a0a; box-shadow: none; gap: 2px;
  }
  .nav-btn { flex: 0 0 auto; flex-direction: row; justify-content: flex-start; padding: 11px 14px; border-right: none; border-radius: 2px; font-size: 14px; font-weight: 500; text-transform: none; letter-spacing: 0; gap: 12px; color: #ccc; width: 100%; margin: 0 !important; }
  .nav-btn .material-symbols-outlined { font-size: 22px; }
  .nav-btn.active { background: rgba(51,181,229,0.12); border-left: 3px solid #33B5E5; padding-left: 11px; }
  .nav-btn.active::after { display: none; }
  .nav-fab { position: static; transform: none; width: 100%; height: auto; padding: 11px 14px; border-radius: 2px; border: 1px solid #1F8DB5; border-top-color: #66C9F0; flex-direction: row; justify-content: flex-start; gap: 12px; box-shadow: none; margin-top: 4px; }
  .nav-fab .material-symbols-outlined { font-size: 22px; }
  .nav-fab:hover { transform: none; }
  .nav-fab:active { transform: none; }
  .container { max-width: none; margin: 0 0 0 220px; padding: 20px 32px 0; display: flex; flex-direction: column; align-items: center; }
  .container > * { width: 100%; max-width: 680px; }
  .holo-page { margin-left: 220px; }
}
@media (min-width: 1200px) {
  .nav { width: 260px; padding: 16px 12px; }
  .nav-btn, .nav-fab { padding: 13px 18px; font-size: 15px; gap: 14px; }
  .container { margin-left: 260px; padding: 24px 40px 0; }
  .container > * { max-width: 720px; }
  .post { padding: 18px; }
  .holo-page { margin-left: 260px; }
}
@media (prefers-reduced-motion: reduce) {
  *, *::before, *::after { animation-duration: 0.01ms !important; transition-duration: 0.01ms !important; }
}
`;

// ============================================================
//  ШАБЛОН HTML-СТРАНИЦЫ
// ============================================================
function layout({ title, body, activeNav = '', user = null, searchQuery = '' }) {
  const authButtons = user
    ? `<a href="/logout" class="btn-login-top" title="Выйти"><span class="material-symbols-outlined">logout</span>Выйти</a>`
    : `<a href="/login" class="btn-login-top"><span class="material-symbols-outlined">login</span>Войти</a>`;

  const userBtn = user
    ? `<a href="/profile" class="user-btn" title="Профиль">${initial(user.username)}</a>`
    : '';

  const bottomNav = `
    <footer class="nav">
      <a href="/" class="nav-btn ${activeNav === 'home' ? 'active' : ''}">
        <span class="material-symbols-outlined">home</span>
        <span>Главная</span>
      </a>
      ${user ? `<a href="/create" class="nav-fab" title="Создать пост"><span class="material-symbols-outlined">add</span></a>` : `<a href="/login" class="nav-fab" title="Войти чтобы создать"><span class="material-symbols-outlined">add</span></a>`}
      <a href="${user ? '/profile' : '/login'}" class="nav-btn ${activeNav === 'profile' ? 'active' : ''}">
        <span class="material-symbols-outlined">person</span>
        <span>Профиль</span>
      </a>
    </footer>`;

  return `<!DOCTYPE html>
<html lang="ru">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, minimum-scale=1, maximum-scale=1, user-scalable=no">
  <title>${escapeHtml(title)} · Lin+</title>
  <link rel="stylesheet" href="/Material Symbols Outlined.css">
  <style>${COMMON_STYLES}</style>
</head>
<body>
  <header class="topbar">
    <a href="/" class="logo" style="text-decoration:none;"><span class="lin">Lin</span><span class="plus">+</span></a>
    <div class="search">
      <span class="icon"><span class="material-symbols-outlined">search</span></span>
      <form method="GET" action="/" style="display:contents;">
        <input type="search" name="search" placeholder="Поиск по Lin+..." value="${escapeHtml(searchQuery)}">
      </form>
    </div>
    ${userBtn}
    ${authButtons}
  </header>
  ${body}
  ${bottomNav}
</body>
</html>`;
}

// ============================================================
//  СЛУЖЕБНЫЕ СТРАНИЦЫ — общие хелперы
// ============================================================

/** Универсальная карточка для служебной страницы */
function holoPage({ icon, iconClass = '', title, titleClass = '', message, actions = '', timer = '', extra = '' }) {
  return `
    <div class="holo-page">
      <div class="holo-card">
        <div class="holo-card-header">
          <span class="material-symbols-outlined">info</span>
          <span class="holo-card-title">Lin+</span>
        </div>
        <div class="holo-card-body">
          ${icon ? `<span class="material-symbols-outlined holo-card-icon ${iconClass}">${icon}</span>` : ''}
          ${title ? `<h1 class="${titleClass}">${escapeHtml(title)}</h1>` : ''}
          ${message ? `<p>${message}</p>` : ''}
          ${timer}
          ${extra}
          ${actions ? `<div class="holo-card-actions">${actions}</div>` : ''}
        </div>
      </div>
    </div>`;
}

// ============================================================
//  АНТИ-ФЛУД
// ============================================================
function sendFloodPage(res, req, retryAfter, reason) {
  const minutes = Math.floor(retryAfter / 60);
  const seconds = retryAfter % 60;
  const timeStr = minutes > 0 ? `${minutes} мин ${seconds} сек` : `${seconds} сек`;

  const body = holoPage({
    icon: 'block',
    iconClass: 'warning',
    title: 'Слишком быстро!',
    titleClass: '',
    message: escapeHtml(reason || 'Вы превысили лимит действий.'),
    timer: `
      <div class="holo-timer-label">Подождите</div>
      <div class="holo-timer" id="timer">${timeStr}</div>
    `,
    actions: `
      <a href="/" class="btn-holo">
        <span class="material-symbols-outlined">arrow_back</span>
        На главную
      </a>
    `,
    extra: `<p class="muted">Это защита от флуда. Пожалуйста, не спамьте.</p>
      <script>
        let left = ${retryAfter};
        const el = document.getElementById('timer');
        const t = setInterval(() => {
          left--;
          if (left <= 0) { clearInterval(t); location.reload(); return; }
          const m = Math.floor(left / 60), s = left % 60;
          el.textContent = m > 0 ? (m + ' мин ' + s + ' сек') : (s + ' сек');
        }, 1000);
      <\/script>`
  });

  res.status(429).send(layout({ title: 'Слишком быстро', body, user: req.user }));
}

// ============================================================
//  СТРАНИЦЫ ОШИБОК
// ============================================================

function sendNotFound(res, req, message = 'Страница не найдена') {
  const body = holoPage({
    icon: 'search_off',
    iconClass: 'error',
    title: '404',
    titleClass: 'error',
    message: escapeHtml(message),
    actions: `
      <a href="/" class="btn-holo primary">
        <span class="material-symbols-outlined">home</span>
        На главную
      </a>
    `
  });
  res.status(404).send(layout({ title: '404', body, activeNav: 'home', user: req.user }));
}

function sendForbidden(res, req, message = 'Доступ запрещён') {
  const body = holoPage({
    icon: 'lock',
    iconClass: 'error',
    title: '403',
    titleClass: 'error',
    message: escapeHtml(message),
    actions: `
      <a href="/" class="btn-holo primary">
        <span class="material-symbols-outlined">home</span>
        На главную
      </a>
    `
  });
  res.status(403).send(layout({ title: '403', body, user: req.user }));
}

function sendServerError(res, req, message = 'Ошибка сервера') {
  const body = holoPage({
    icon: 'error',
    iconClass: 'error',
    title: '500',
    titleClass: 'error',
    message: escapeHtml(message),
    actions: `
      <a href="/" class="btn-holo primary">
        <span class="material-symbols-outlined">refresh</span>
        Попробовать снова
      </a>
    `
  });
  res.status(500).send(layout({ title: 'Ошибка', body, user: req.user }));
}

function sendOAuthError(res, req, errorCode, errorMessage) {
  const messages = {
    access_denied: 'Вы отменили вход',
    invalid_request: 'Некорректный запрос авторизации',
    invalid_client: 'Ошибка клиента приложения',
    invalid_grant: 'Недействительный код авторизации',
    unauthorized_client: 'Клиент не авторизован',
    unsupported_response_type: 'Неподдерживаемый тип ответа',
    invalid_scope: 'Некорректные права доступа',
    server_error: 'Ошибка на сервере LinAccounts',
    temporarily_unavailable: 'Сервер авторизации временно недоступен',
    csrf: 'Ошибка безопасности (CSRF)',
    missing_params: 'Недостаточно параметров авторизации',
    no_token: 'Сервер не выдал токен доступа',
    no_userinfo: 'Не удалось получить данные профиля'
  };

  const humanMessage = messages[errorCode] || 'Произошла ошибка авторизации';

  const body = holoPage({
    icon: 'error',
    iconClass: 'error',
    title: 'Ошибка входа',
    titleClass: 'error',
    message: escapeHtml(humanMessage),
    extra: errorMessage
      ? `<p class="muted">${escapeHtml(errorMessage)}</p>`
      : '',
    actions: `
      <a href="/login" class="btn-holo primary">
        <span class="material-symbols-outlined">refresh</span>
        Попробовать снова
      </a>
      <a href="/" class="btn-holo">
        <span class="material-symbols-outlined">home</span>
        На главную
      </a>
    `
  });

  res.status(400).send(layout({ title: 'Ошибка входа', body, user: req.user }));
}

// ============================================================
//  РЕНДЕР ПОСТА
// ============================================================
function renderPost(post, user, showComments = false) {
  const author = getUserById(post.user_id);
  if (!author) return '';
  const likes = post.likes || [];
  const comments = post.comments || [];
  const reposts = post.reposts || [];
  const liked = user && likes.includes(user.id);
  const reposted = user && reposts.includes(user.id);
  const isOwner = user && user.id === post.user_id;

  let repostBox = '';
  if (post.repost_of) {
    const orig = getPostById(post.repost_of);
    if (orig) {
      const origAuthor = getUserById(orig.user_id);
      repostBox = `<div class="repost-box">
        <div class="repost-label"><span class="material-symbols-outlined">repeat</span> Репост от @${escapeHtml(origAuthor?.username || 'user')}</div>
        <div style="margin-top:6px;">${escapeHtml(orig.content).slice(0, 160)}</div>
      </div>`;
    }
  }

  const likeForm = user
    ? `<form method="POST" action="/post/${post.id}/like"><button class="${liked ? 'liked' : ''}" type="submit"><span class="material-symbols-outlined ${liked ? 'filled' : ''}">favorite</span> ${likes.length}</button></form>`
    : `<form method="GET" action="/login"><button type="submit"><span class="material-symbols-outlined">favorite</span> ${likes.length}</button></form>`;

  const commentBtn = `<form method="GET" action="/post/${post.id}"><button type="submit"><span class="material-symbols-outlined">chat_bubble</span> ${comments.length}</button></form>`;

  const repostForm = user
    ? `<form method="POST" action="/post/${post.id}/repost"><button class="${reposted ? 'reposted' : ''}" type="submit"><span class="material-symbols-outlined">repeat</span> ${reposts.length}</button></form>`
    : `<form method="GET" action="/login"><button type="submit"><span class="material-symbols-outlined">repeat</span> ${reposts.length}</button></form>`;

  const deleteBtn = isOwner
    ? `<form method="POST" action="/post/${post.id}/delete" style="display:contents;" onsubmit="return confirm('Удалить этот пост?');">
        <button type="submit" class="danger" title="Удалить"><span class="material-symbols-outlined">delete</span></button>
      </form>`
    : '';

  const deleteTopBtn = isOwner
    ? `<form method="POST" action="/post/${post.id}/delete" style="display:contents;" onsubmit="return confirm('Удалить этот пост?');">
        <button type="submit" class="delete-top" title="Удалить"><span class="material-symbols-outlined">delete</span></button>
      </form>`
    : '';

  let commentsSection = '';
  if (showComments) {
    const commentsHtml = comments.length === 0
      ? `<div style="color:#666;font-size:13px;padding:6px 0;">Комментариев пока нет. Будьте первым!</div>`
      : comments.map(c => {
          const cAuthor = getUserById(c.user_id);
          if (!cAuthor) return '';
          return `<div class="comment">
            <div class="avatar">${initial(cAuthor.username)}</div>
            <div class="comment-body">
              <div class="comment-head">
                <span class="comment-author">${escapeHtml(cAuthor.username)}</span>
                <span class="comment-time">${formatDate(c.timestamp)}</span>
              </div>
              <div class="comment-text">${escapeHtml(c.content)}</div>
            </div>
          </div>`;
        }).join('');

    const commentForm = user
      ? `<form class="comment-form" method="POST" action="/post/${post.id}/comment">
          <input type="text" name="content" placeholder="Написать комментарий..." required maxlength="2000">
          <button type="submit"><span class="material-symbols-outlined">send</span>Отправить</button>
        </form>`
      : `<div class="comment-login"><span class="material-symbols-outlined">lock</span> <a href="/login">Войдите</a>, чтобы оставить комментарий</div>`;

    commentsSection = `<div class="comments">
      <div class="comments-title"><span class="material-symbols-outlined">chat_bubble</span> Комментарии (${comments.length})</div>
      ${commentsHtml}
      ${commentForm}
    </div>`;
  }

  return `
    <div class="post">
      ${deleteTopBtn}
      <div class="post-header">
        <div class="avatar">${initial(author.username)}</div>
        <div class="meta">
          <div class="post-author">
            <a href="/user/${author.id}">${escapeHtml(author.username)}</a>
            ${author.id === 1 ? '<span class="material-symbols-outlined" style="color:#33B5E5;font-size:16px;">verified</span>' : ''}
          </div>
          <div class="post-time">${formatDate(post.timestamp)}</div>
        </div>
      </div>
      ${repostBox}
      <div class="post-content">${escapeHtml(post.content)}</div>
      <div class="post-actions">
        ${likeForm}
        ${commentBtn}
        ${repostForm}
        ${deleteBtn}
      </div>
      ${commentsSection}
    </div>`;
}

// ============================================================
//  МАРШРУТЫ
// ============================================================

// --- Главная ---
app.get('/', (req, res) => {
  const user = req.user;
  const searchQuery = (req.query.search || '').toString();

  if (searchQuery) {
    const ip = req.ip || 'unknown';
    const limit = checkRateLimit('search', ip);
    if (limit) return sendFloodPage(res, req, limit.retryAfter, 'Слишком частый поиск.');
  }

  const posts = searchQuery ? searchPosts(searchQuery) : getPosts();

  const postsHtml = posts.length === 0
    ? `<div class="empty">
        <span class="material-symbols-outlined">${searchQuery ? 'search_off' : 'inbox'}</span>
        <p>${searchQuery ? 'Ничего не найдено.' : 'Здесь пока нет постов.'}</p>
        ${!searchQuery ? '<p>Нажмите <strong>+</strong> внизу, чтобы создать первый пост.</p>' : ''}
      </div>`
    : posts.map(p => renderPost(p, user)).join('');

  const searchInfo = searchQuery
    ? `<div style="color:#888;margin:8px 0;font-size:14px;"><span class="material-symbols-outlined" style="font-size:16px;vertical-align:middle;">search</span> Результаты: <strong style="color:#eee;">${escapeHtml(searchQuery)}</strong> <a href="/" style="margin-left:12px;">✕ Сбросить</a></div>`
    : '';

  const body = `
    <div class="container">
      ${searchInfo}
      ${postsHtml}
    </div>`;

  res.send(layout({ title: 'Главная', body, activeNav: 'home', user, searchQuery }));
});

// --- Создание поста (форма) ---
app.get('/create', (req, res) => {
  if (!req.user) return res.redirect('/login');

  const body = `
    <div class="holo-page">
      <div class="holo-card">
        <div class="holo-card-header">
          <span class="material-symbols-outlined">edit_note</span>
          <span class="holo-card-title">Новый пост</span>
        </div>
        <div class="holo-card-body" style="text-align:left;">
          <form method="POST" action="/post" class="create-form">
            <textarea name="content" placeholder="Что у вас нового?" maxlength="10000" required autofocus></textarea>
            <div style="display:flex;justify-content:flex-end;gap:8px;margin-top:14px;">
              <a href="/" class="btn-holo">
                <span class="material-symbols-outlined">close</span>
                Отмена
              </a>
              <button type="submit" class="btn-holo primary">
                <span class="material-symbols-outlined">send</span>
                Опубликовать
              </button>
            </div>
          </form>
        </div>
      </div>
    </div>`;

  res.send(layout({ title: 'Новый пост', body, user: req.user }));
});

app.post('/post', (req, res) => {
  if (!req.user) return res.redirect('/login');
  const content = (req.body.content || '').trim();
  if (!content) return res.redirect('/');

  if (content.length > 10000) return sendFloodPage(res, req, 5, 'Пост слишком длинный');
  let limit = checkRateLimit('post', req.user.id);
  if (limit) return sendFloodPage(res, req, limit.retryAfter, 'Слишком частые посты.');
  limit = checkRateLimit('postWin', req.user.id);
  if (limit) return sendFloodPage(res, req, limit.retryAfter, 'Слишком много постов.');
  if (isDuplicate(req.user.id, content)) return sendFloodPage(res, req, 60, 'Такой пост вы уже публиковали.');

  addPost(req.user.id, content);
  res.redirect('/');
});

// --- Лайк ---
app.post('/post/:id/like', (req, res) => {
  if (!req.user) return res.redirect('/login');
  const id = parseInt(req.params.id, 10);
  const limit = checkRateLimit('like', req.user.id);
  if (limit) return sendFloodPage(res, req, limit.retryAfter, 'Слишком много лайков.');
  toggleLike(id, req.user.id);
  res.redirect(req.get('referer') || '/');
});

// --- Репост ---
app.post('/post/:id/repost', (req, res) => {
  if (!req.user) return res.redirect('/login');
  const id = parseInt(req.params.id, 10);
  const limit = checkRateLimit('repost', req.user.id);
  if (limit) return sendFloodPage(res, req, limit.retryAfter, 'Слишком много репостов.');
  addRepost(id, req.user.id);
  res.redirect('/');
});

// --- Комментарий ---
app.post('/post/:id/comment', (req, res) => {
  if (!req.user) return res.redirect('/login');
  const id = parseInt(req.params.id, 10);
  const content = (req.body.content || '').trim();
  if (!content) return res.redirect(`/post/${id}`);
  if (content.length > 2000) return sendFloodPage(res, req, 5, 'Комментарий слишком длинный');
  let limit = checkRateLimit('comment', req.user.id);
  if (limit) return sendFloodPage(res, req, limit.retryAfter, 'Слишком частые комментарии.');
  limit = checkRateLimit('commentWin', req.user.id);
  if (limit) return sendFloodPage(res, req, limit.retryAfter, 'Слишком много комментариев.');
  if (isDuplicate('c' + req.user.id, content)) return sendFloodPage(res, req, 60, 'Такой комментарий вы уже писали.');
  addComment(id, req.user.id, content);
  res.redirect(`/post/${id}`);
});

// --- Удаление ---
app.post('/post/:id/delete', (req, res) => {
  if (!req.user) return res.redirect('/login');
  const id = parseInt(req.params.id, 10);
  const result = deletePost(id, req.user.id);
  if (!result.ok) {
    if (result.reason === 'forbidden') return sendForbidden(res, req, 'Вы можете удалять только свои посты.');
    return sendNotFound(res, req, 'Пост не найден');
  }
  const referer = req.get('referer') || '/';
  if (referer.includes(`/post/${id}`)) return res.redirect('/');
  res.redirect(referer);
});

// --- Страница поста ---
app.get('/post/:id', (req, res) => {
  const id = parseInt(req.params.id, 10);
  const post = getPostById(id);
  if (!post) return sendNotFound(res, req, 'Пост не найден или был удалён');

  const body = `
    <div class="container">
      <a href="/" class="btn-holo" style="text-decoration:none;margin-bottom:12px;display:inline-flex;">
        <span class="material-symbols-outlined">arrow_back</span>Назад
      </a>
      ${renderPost(post, req.user, true)}
    </div>`;
  res.send(layout({ title: 'Пост', body, activeNav: 'home', user: req.user }));
});

// --- Профиль ---
app.get('/profile', (req, res) => {
  if (!req.user) return res.redirect('/login');
  res.redirect(`/user/${req.user.id}`);
});

app.get('/user/:id', (req, res) => {
  const id = parseInt(req.params.id, 10);
  const profileUser = getUserById(id);
  if (!profileUser) return sendNotFound(res, req, 'Пользователь не найден');

  const myPosts = getPosts().filter(p => p.user_id === profileUser.id);
  const isMe = req.user && req.user.id === profileUser.id;

  const postsHtml = myPosts.length === 0
    ? `<div class="empty"><span class="material-symbols-outlined">inbox</span><p>${isMe ? 'Вы ещё не написали ни одного поста.' : 'У пользователя пока нет постов.'}</p>${isMe ? '<p>Нажмите <strong>+</strong> внизу.</p>' : ''}</div>`
    : myPosts.map(p => renderPost(p, req.user)).join('');

  const emailHtml = profileUser.email && isMe
    ? `<div class="profile-email"><span class="material-symbols-outlined">mail</span> ${escapeHtml(profileUser.email)}</div>`
    : '';

  const logoutBtn = isMe
    ? `<a href="/logout" class="profile-logout"><span class="material-symbols-outlined">logout</span>Выйти из аккаунта</a>`
    : '';

  const body = `
    <div class="container">
      <div class="profile-card">
        <div class="profile-avatar">${initial(profileUser.username)}</div>
        <div class="profile-name">${escapeHtml(profileUser.username)}</div>
        ${emailHtml}
        <div class="profile-badge"><span class="material-symbols-outlined">key</span> Вход через LinAccounts</div>
        ${logoutBtn}
        <div class="profile-stats">
          <div class="stat"><div class="num">${myPosts.length}</div><div class="lbl">Постов</div></div>
          <div class="stat"><div class="num">${myPosts.reduce((s,p)=>s+p.likes.length,0)}</div><div class="lbl">Лайков</div></div>
          <div class="stat"><div class="num">0</div><div class="lbl">Подписчиков</div></div>
        </div>
      </div>
      <h3 class="section-title">${isMe ? 'Мои посты' : 'Посты'}</h3>
      ${postsHtml}
    </div>`;

  res.send(layout({ title: profileUser.username, body, activeNav: isMe ? 'profile' : '', user: req.user }));
});

// ============================================================
//  ВХОД / OAUTH
// ============================================================

// --- Страница входа (новый Holo-дизайн) ---
app.get('/login', (req, res) => {
  if (req.user) return res.redirect('/');

  const body = `
    <div class="holo-page">
      <div class="holo-card">
        <div class="holo-card-header">
          <span class="material-symbols-outlined">login</span>
          <span class="holo-card-title">Вход</span>
        </div>
        <div class="holo-card-body">
          <div class="holo-logo">
            <span class="lin">Lin</span><span class="plus">+</span>
          </div>
          <p style="margin:12px 0 24px;color:#888;font-size:14px;">
            Войдите в свою социальную сеть
          </p>
          <a href="/auth" class="oauth-btn">
            <span class="material-symbols-outlined">passkey</span>
            Войти через LinAccounts
          </a>
          <p class="muted" style="margin-top:20px;line-height:1.7;">
            <span class="material-symbols-outlined" style="font-size:14px;vertical-align:middle;color:#FF8800;">shield</span>
            Безопасный вход через <strong style="color:#bbb;">LinAccounts</strong><br>
            Чтение постов доступно без входа.
          </p>
          <div class="holo-card-actions">
            <a href="/" class="btn-holo">
              <span class="material-symbols-outlined">arrow_back</span>
              К чтению
            </a>
          </div>
        </div>
      </div>
    </div>`;
  res.send(layout({ title: 'Вход', body, user: null }));
});

// --- OAuth: начало ---
app.get('/auth', (req, res) => {
  const state = crypto.randomBytes(16).toString('hex');
  req.session.oauth_state = state;

  const params = new URLSearchParams({
    client_id: CLIENT_ID,
    redirect_uri: REDIRECT_URI,
    response_type: 'code',
    state
  });
  res.redirect(`${LINACCOUNTS_URL}/oauth/authorize?${params.toString()}`);
});

// --- OAuth: callback ---
app.get('/callback', async (req, res) => {
  const { code, state, error, error_description } = req.query;

  if (error) {
    return sendOAuthError(res, req, error, error_description || '');
  }
  if (!code || !state) {
    return sendOAuthError(res, req, 'missing_params', '');
  }
  if (state !== req.session.oauth_state) {
    return sendOAuthError(res, req, 'csrf', '');
  }

  try {
    const tokenResp = await axios.post(
      `${LINACCOUNTS_URL}/oauth/token`,
      { code, client_id: CLIENT_ID, client_secret: CLIENT_SECRET },
      { headers: { 'Content-Type': 'application/json' }, timeout: 30000 }
    );

    const accessToken = tokenResp.data.access_token;
    const refreshToken = tokenResp.data.refresh_token;
    if (!accessToken) return sendOAuthError(res, req, 'no_token', 'Сервер LinAccounts не вернул access_token');

    const userResp = await axios.get(`${LINACCOUNTS_URL}/oauth/userinfo`, {
      headers: { Authorization: `Bearer ${accessToken}` },
      timeout: 30000
    });

    const userData = userResp.data;
    if (!userData || !userData.username) {
      return sendOAuthError(res, req, 'no_userinfo', 'В ответе нет поля username');
    }

    let user = getUserByUsername(userData.username);
    if (!user) {
      user = createUser({
        username: userData.username,
        email: userData.email || null,
        avatar: userData.avatar || '#33B5E5'
      });
    } else {
      let updated = false;
      if (userData.email && user.email !== userData.email) { user.email = userData.email; updated = true; }
      if (userData.avatar && user.avatar !== userData.avatar) { user.avatar = userData.avatar; updated = true; }
      if (!user.oauth) { user.oauth = true; updated = true; }
      if (updated) updateUser(user);
    }

    req.session.user_id = user.id;
    req.session.access_token = accessToken;
    req.session.refresh_token = refreshToken;
    req.session.login_time = Date.now();
    delete req.session.oauth_state;

    res.redirect('/');
  } catch (err) {
    const httpStatus = err.response ? err.response.status : 0;
    const data = err.response ? err.response.data : null;

    let errorCode = 'server_error';
    let errorMessage = err.message;

    if (httpStatus === 401) errorCode = 'invalid_client';
    else if (httpStatus === 400) errorCode = 'invalid_grant';
    else if (httpStatus === 403) errorCode = 'unauthorized_client';
    else if (httpStatus === 404) {
      errorCode = 'server_error';
      errorMessage = 'Эндпоинт не найден (404). Проверьте URL LinAccounts.';
    }

    if (data) {
      if (typeof data === 'string') errorMessage = data;
      else if (data.error) {
        errorCode = data.error;
        errorMessage = data.error_description || data.message || JSON.stringify(data);
      } else if (data.message) errorMessage = data.message;
    }

    console.error('OAuth ошибка:', data || err.message);
    sendOAuthError(res, req, errorCode, errorMessage);
  }
});

// --- Выход ---
app.get('/logout', (req, res) => {
  req.session.destroy(() => res.redirect('/'));
});

// ============================================================
//  404 ДЛЯ ВСЕХ ОСТАЛЬНЫХ МАРШРУТОВ
// ============================================================
app.use((req, res) => {
  sendNotFound(res, req, 'Страница не найдена');
});

// ============================================================
//  ГЛОБАЛЬНЫЙ ОБРАБОТЧИК ОШИБОК
// ============================================================
app.use((err, req, res, next) => {
  console.error('Необработанная ошибка:', err);
  if (res.headersSent) return next(err);
  sendServerError(res, req, err.message || 'Что-то пошло не так');
});

// ============================================================
//  ЗАПУСК
// ============================================================
app.listen(PORT, () => {
  console.log(`🚀 Lin+ запущен на ${BASE_URL}`);
  console.log(`📁 Сайт:   ${SITE_DIR}`);
  console.log(`📁 Данные: ${DATA_DIR}`);
  console.log(`🔐 OAuth:  ${LINACCOUNTS_URL}`);
  console.log(`🔗 Redirect URI: ${REDIRECT_URI}`);
});
ENDOFFILE
echo "✅ server.js создан — все служебные страницы в Holo-дизайне"