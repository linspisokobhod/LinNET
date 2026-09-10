cat > ~/linplus/server.js << 'ENDOFFILE'
// ============================================================
//  Lin+ — социальная сеть на Node.js
//  Хост: 195.43.142.215:9002
//  Лайки, комментарии, репосты — работают
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

const DATA_DIR = path.join(__dirname, 'data');
const USERS_FILE = path.join(DATA_DIR, 'users.json');
const POSTS_FILE = path.join(DATA_DIR, 'posts.json');

// ============================================================
//  ХРАНИЛИЩЕ
// ============================================================
if (!fs.existsSync(DATA_DIR)) fs.mkdirSync(DATA_DIR, { recursive: true });
if (!fs.existsSync(USERS_FILE)) fs.writeFileSync(USERS_FILE, JSON.stringify({ users: [] }, null, 2));
if (!fs.existsSync(POSTS_FILE)) fs.writeFileSync(POSTS_FILE, JSON.stringify({ posts: [] }, null, 2));

const loadUsers = () => { try { return JSON.parse(fs.readFileSync(USERS_FILE, 'utf8')).users || []; } catch { return []; } };
const saveUsers = (u) => fs.writeFileSync(USERS_FILE, JSON.stringify({ users: u }, null, 2));
const loadPosts = () => { try { return JSON.parse(fs.readFileSync(POSTS_FILE, 'utf8')).posts || []; } catch { return []; } };
const savePosts = (p) => fs.writeFileSync(POSTS_FILE, JSON.stringify({ posts: p }, null, 2));

const getUserById = (id) => loadUsers().find(u => u.id === id) || null;
const getUserByUsername = (username) => loadUsers().find(u => u.username === username) || null;

function createUser({ username, email, avatar }) {
  const users = loadUsers();
  const maxId = users.reduce((m, u) => Math.max(m, u.id), 0);
  const newUser = {
    id: maxId + 1, username,
    email: email || null,
    avatar: avatar || '#33B5E5',
    oauth: true,
    created_at: Date.now()
  };
  users.push(newUser);
  saveUsers(users);
  return newUser;
}
function updateUser(user) {
  const users = loadUsers();
  const idx = users.findIndex(u => u.id === user.id);
  if (idx !== -1) { users[idx] = user; saveUsers(users); }
}

// --- Нормализация поста (на случай старых данных) ---
function normalizePost(p) {
  if (!Array.isArray(p.likes)) p.likes = [];
  if (!Array.isArray(p.comments)) p.comments = [];
  if (!Array.isArray(p.reposts)) p.reposts = [];
  if (typeof p.repost_of === 'undefined') p.repost_of = null;
  return p;
}

const getPosts = () => loadPosts().map(normalizePost).sort((a, b) => b.timestamp - a.timestamp);
const getPostById = (id) => {
  const p = loadPosts().find(x => x.id === id);
  return p ? normalizePost(p) : null;
};

function addPost(userId, content, repostOf = null) {
  const posts = loadPosts();
  const maxId = posts.reduce((m, p) => Math.max(m, p.id), 0);
  posts.push({
    id: maxId + 1,
    user_id: userId,
    content,
    timestamp: Date.now(),
    likes: [],
    comments: [],
    reposts: [],
    repost_of: repostOf
  });
  savePosts(posts);
}

function toggleLike(postId, userId) {
  const posts = loadPosts();
  const idx = posts.findIndex(p => p.id === postId);
  if (idx === -1) return null;
  const p = normalizePost(posts[idx]);
  const likeIdx = p.likes.indexOf(userId);
  if (likeIdx === -1) {
    p.likes.push(userId);
  } else {
    p.likes.splice(likeIdx, 1);
  }
  posts[idx] = p;
  savePosts(posts);
  return { liked: likeIdx === -1, count: p.likes.length };
}

function addComment(postId, userId, content) {
  const posts = loadPosts();
  const idx = posts.findIndex(p => p.id === postId);
  if (idx === -1) return null;
  const p = normalizePost(posts[idx]);
  const maxCid = p.comments.reduce((m, c) => Math.max(m, c.id || 0), 0);
  const newComment = {
    id: maxCid + 1,
    user_id: userId,
    content,
    timestamp: Date.now()
  };
  p.comments.push(newComment);
  posts[idx] = p;
  savePosts(posts);
  return newComment;
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

  // Создаём новый пост-репост
  const content = `↗️ Репост от @${getUserById(original.user_id)?.username || 'user'}:\n\n${original.content}`;
  addPost(userId, content, original.id);
  return true;
}

function searchPosts(query) {
  const q = query.toLowerCase().trim();
  if (!q) return getPosts();
  return getPosts().filter(p => {
    const user = getUserById(p.user_id);
    return p.content.toLowerCase().includes(q) ||
           (user && user.username.toLowerCase().includes(q));
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

app.use((req, res, next) => {
  req.user = req.session.user_id ? getUserById(req.session.user_id) : null;
  next();
});

// ============================================================
//  УТИЛИТЫ
// ============================================================
function escapeHtml(str) {
  if (!str) return '';
  return String(str)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}
function formatDate(ts) {
  const d = new Date(ts);
  const pad = n => String(n).padStart(2, '0');
  return `${pad(d.getDate())}.${pad(d.getMonth() + 1)}.${d.getFullYear()} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}
const initial = (name) => (name && name[0] ? name[0].toUpperCase() : '?');

// ============================================================
//  СТИЛИ
// ============================================================
const COMMON_STYLES = `
  @import url(https://fonts.googleapis.com/css?family=Roboto:400,400italic,700,700italic);
  * { box-sizing: border-box; }
  body { font-family: Roboto, "Droid Sans", sans-serif; margin: 0; padding: 16px; background: #000; color: #eee; padding-top: 56px; padding-bottom: 56px; }
  body:before { z-index: -1000; content: ""; position: fixed; left: 0; right: 0; top: 0; bottom: 0; background: linear-gradient(#000000, #272D33); }
  a { color: #33B5E5; text-decoration: none; }
  .lin-topbar { position: fixed; top: 0; left: 0; right: 0; height: 48px; background: #111; border-bottom: 1px solid #333; padding: 0 16px; display: flex; align-items: center; justify-content: space-between; box-sizing: border-box; color: #eee; gap: 12px; z-index: 1000; }
  .lin-topbar .logo { font-size: 20px; font-weight: 700; display: flex; align-items: center; flex-shrink: 0; }
  .lin-topbar .logo .lin { color: #FF8800; }
  .lin-topbar .logo .plus { color: #66FF00; margin-left: 2px; }
  .lin-topbar .search-box { flex: 1; position: relative; }
  .lin-topbar .search-box input[type="search"] { width: 100%; padding: 6px 12px 6px 32px; border: 1px solid #333; border-radius: 2px; background: #1a1a1a; color: #eee; font-size: 14px; font-family: inherit; outline: none; transition: border-color 0.2s, box-shadow 0.2s; box-sizing: border-box; -webkit-appearance: none; appearance: none; }
  .lin-topbar .search-box input[type="search"]::placeholder { color: #888; }
  .lin-topbar .search-box input[type="search"]:focus { border-color: #33B5E5; box-shadow: 0 0 0 2px rgba(51, 181, 229, 0.4); }
  .lin-topbar .search-box .search-icon { position: absolute; left: 8px; top: 50%; transform: translateY(-50%); color: #888; font-size: 16px; pointer-events: none; }
  .lin-topbar .auth-buttons { display: flex; gap: 8px; flex-shrink: 0; }
  .lin-topbar .auth-buttons a { padding: 6px 14px; border-radius: 2px; font-size: 13px; font-weight: 500; text-transform: uppercase; letter-spacing: 0.5px; }
  .lin-topbar .auth-buttons .btn-login { background: #FF8800; color: #fff; }
  .lin-topbar .auth-buttons .btn-login:hover { background: #CC6A00; }

  .post-card { background: #1e1e1e; color: #e0e0e0; margin: 12px 0; padding: 16px; border-radius: 2px; box-shadow: 0 2px 6px rgba(0,0,0,0.7); }
  .post-header { display: flex; align-items: center; margin-bottom: 12px; }
  .avatar { width: 48px; height: 48px; border-radius: 50%; background: #33B5E5; margin-right: 12px; flex-shrink: 0; display: flex; align-items: center; justify-content: center; color: #fff; font-weight: bold; font-size: 20px; }
  .post-author { font-weight: 700; font-size: 16px; color: #eee; }
  .post-author a { color: #eee; }
  .post-author a:hover { color: #33B5E5; }
  .post-time { font-size: 13px; color: #999; margin-left: 8px; }
  .post-content { margin: 8px 0 12px; font-size: 15px; line-height: 1.4; color: #ddd; white-space: pre-wrap; }
  .post-actions { display: flex; justify-content: space-around; border-top: 1px solid #333; padding-top: 10px; margin-top: 4px; gap: 4px; }
  .post-actions form { margin: 0; padding: 0; flex: 1; display: flex; }
  .post-actions button { flex: 1; background: transparent; border: none; color: #aaa; font-size: 13px; font-weight: 500; padding: 6px 4px; margin: 0; box-shadow: none; text-transform: uppercase; letter-spacing: 0.3px; cursor: pointer; border-radius: 2px; transition: background 0.2s, color 0.2s; }
  .post-actions button:hover { color: #33B5E5; background: rgba(51,181,229,0.1); }
  .post-actions button.liked { color: #33B5E5; }
  .post-actions button.reposted { color: #66FF00; }

  .new-post-area { background: #1e1e1e; margin: 8px 0 16px; padding: 12px 16px; border-radius: 2px; box-shadow: 0 2px 6px rgba(0,0,0,0.7); display: flex; align-items: center; gap: 12px; }
  .new-post-area input[type="text"] { flex: 1; border: none; padding: 10px 0; font-size: 15px; background: transparent; color: #eee; outline: none; min-width: 0; }
  .new-post-area input[type="text"]::placeholder { color: #777; }
  .new-post-area button { background: #33B5E5; color: #fff; border: none; padding: 6px 16px; border-radius: 2px; font-weight: 500; text-transform: uppercase; font-size: 14px; box-shadow: 0 1px 2px rgba(0,0,0,0.3); margin: 0; flex-shrink: 0; cursor: pointer; }
  .new-post-area button:hover { background: #1F8DB5; }

  .guest-prompt { background: #1e1e1e; margin: 8px 0 16px; padding: 20px; border-radius: 2px; box-shadow: 0 2px 6px rgba(0,0,0,0.7); text-align: center; }
  .guest-prompt p { margin: 0 0 16px; color: #aaa; font-size: 15px; }
  .guest-prompt a { display: inline-block; padding: 10px 24px; background: #FF8800; color: #fff; border-radius: 2px; font-size: 15px; font-weight: 500; margin: 0 6px; }
  .guest-prompt a:hover { background: #CC6A00; }

  .empty-feed { text-align: center; padding: 40px 20px; color: #888; font-size: 16px; border-top: 1px solid #333; margin-top: 20px; }
  .empty-feed span { display: block; font-size: 48px; margin-bottom: 12px; }

  .lin-bottom-nav { position: fixed; bottom: 0; left: 0; right: 0; height: 56px; background: #111; border-top: 1px solid #333; display: flex; align-items: stretch; justify-content: space-around; z-index: 1000; box-shadow: 0 -2px 8px rgba(0,0,0,0.4); }
  .lin-bottom-nav button { flex: 1; background: transparent; border: none; color: #aaa; font-size: 13px; font-weight: 500; padding: 6px 0; margin: 0; box-shadow: none; text-transform: uppercase; letter-spacing: 0.3px; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 2px; position: relative; transition: color 0.2s, background 0.2s; cursor: pointer; outline: none !important; }
  .lin-bottom-nav button:focus { outline: none !important; }
  .lin-bottom-nav button .nav-icon { font-size: 22px; line-height: 1.2; transition: transform 0.2s; }
  .lin-bottom-nav button.active .nav-icon { transform: scale(1.05); color: #33B5E5; }
  .lin-bottom-nav button .nav-label { font-size: 11px; font-weight: 500; letter-spacing: 0.4px; text-transform: uppercase; color: #888; transition: color 0.2s; }
  .lin-bottom-nav button.active .nav-label { color: #33B5E5; }
  .lin-bottom-nav button:active { background: rgba(51, 181, 229, 0.15); }

  .profile-card { background: #1e1e1e; padding: 20px; border-radius: 4px; margin: 20px auto; max-width: 600px; box-shadow: 0 2px 6px rgba(0,0,0,0.7); text-align: center; }
  .profile-avatar { width: 80px; height: 80px; border-radius: 50%; margin: 0 auto 16px; display: flex; align-items: center; justify-content: center; font-size: 32px; color: #fff; }
  .profile-name { font-size: 24px; font-weight: 500; }
  .profile-email { color: #888; font-size: 14px; margin-top: 4px; }
  .profile-stats { display: flex; justify-content: center; gap: 40px; margin: 20px 0; }
  .stat-item { text-align: center; }
  .stat-number { font-size: 22px; font-weight: 500; }
  .stat-label { font-size: 13px; color: #888; }
  .profile-oauth-badge { display: inline-block; background: #FF8800; color: #fff; padding: 2px 12px; border-radius: 12px; font-size: 12px; margin-top: 8px; }

  /* Комментарии */
  .comments-section { margin-top: 14px; padding-top: 12px; border-top: 1px solid #333; }
  .comment { display: flex; gap: 10px; margin: 10px 0; padding: 8px; background: #161616; border-radius: 4px; }
  .comment .avatar { width: 32px; height: 32px; font-size: 13px; margin: 0; }
  .comment-body { flex: 1; min-width: 0; }
  .comment-author { font-weight: 600; font-size: 13px; color: #eee; }
  .comment-time { font-size: 11px; color: #888; margin-left: 6px; }
  .comment-text { font-size: 14px; color: #ddd; margin-top: 3px; white-space: pre-wrap; word-wrap: break-word; }
  .comment-form { display: flex; gap: 8px; margin-top: 10px; }
  .comment-form input { flex: 1; padding: 8px 12px; border: 1px solid #333; border-radius: 2px; background: #111; color: #eee; font-size: 14px; outline: none; min-width: 0; }
  .comment-form input:focus { border-color: #33B5E5; box-shadow: 0 0 0 2px rgba(51,181,229,0.3); }
  .comment-form button { background: #33B5E5; color: #fff; border: none; padding: 8px 16px; border-radius: 2px; font-weight: 500; font-size: 13px; cursor: pointer; text-transform: uppercase; flex-shrink: 0; }
  .comment-form button:hover { background: #1F8DB5; }
  .comment-login { color: #888; font-size: 13px; text-align: center; padding: 10px; background: #161616; border-radius: 4px; margin-top: 10px; }

  /* Страница поста */
  .post-full { max-width: 600px; margin: 0 auto; }
  .back-link { display: inline-block; color: #33B5E5; margin-bottom: 12px; font-size: 14px; }
  .repost-of-box { background: #161616; border-left: 3px solid #66FF00; padding: 10px 12px; border-radius: 2px; margin: 8px 0; font-size: 14px; color: #bbb; }

  @media (max-width: 600px) {
    .lin-topbar .logo { font-size: 18px; }
    .avatar { width: 40px; height: 40px; font-size: 16px; }
    .lin-topbar .auth-buttons a { padding: 5px 8px; font-size: 11px; }
  }
  @media (max-width: 480px) {
    .new-post-area { flex-wrap: wrap; gap: 8px; padding: 10px 12px; }
    .new-post-area input[type="text"] { flex: 1 1 100%; padding: 8px 0; font-size: 14px; }
    .new-post-area button { flex: 1 1 auto; width: 100%; text-align: center; padding: 8px; font-size: 13px; }
    .new-post-area .avatar { width: 32px; height: 32px; font-size: 12px; margin-right: 0; }
    .lin-bottom-nav button .nav-icon { font-size: 20px; }
    .lin-bottom-nav button .nav-label { font-size: 10px; }
    .post-actions button { font-size: 11px; letter-spacing: 0; }
  }
`;

// ============================================================
//  ШАБЛОН
// ============================================================
function layout({ title, body, activeNav = '', user = null }) {
  const authButtons = user
    ? `<div class="auth-buttons"><a href="/logout" class="btn-login">Выйти</a></div>`
    : `<div class="auth-buttons"><a href="/login" class="btn-login">Войти</a></div>`;

  const bottomNav = user
    ? `<footer class="lin-bottom-nav">
        <button ${activeNav === 'home' ? 'class="active"' : ''} onclick="location.href='/'"><span class="nav-icon">🏠</span><span class="nav-label">Главная</span></button>
        <button ${activeNav === 'profile' ? 'class="active"' : ''} onclick="location.href='/profile'"><span class="nav-icon">👤</span><span class="nav-label">Профиль</span></button>
        <button onclick="location.href='/logout'"><span class="nav-icon">🚪</span><span class="nav-label">Выйти</span></button>
      </footer>`
    : `<footer class="lin-bottom-nav">
        <button ${activeNav === 'home' ? 'class="active"' : ''} onclick="location.href='/'"><span class="nav-icon">🏠</span><span class="nav-label">Главная</span></button>
        <button onclick="location.href='/login'"><span class="nav-icon">🔑</span><span class="nav-label">Войти</span></button>
      </footer>`;

  return `<!DOCTYPE html>
<html lang="ru">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, minimum-scale=1, maximum-scale=1, user-scalable=no">
  <title>${escapeHtml(title)} · Lin+</title>
  <style>${COMMON_STYLES}</style>
</head>
<body>
  <div class="lin-topbar">
    <div class="logo"><span class="lin">Lin</span><span class="plus">+</span></div>
    <div class="search-box">
      <span class="search-icon">🔍</span>
      <form method="GET" action="/" style="display:contents;">
        <input type="search" name="search" placeholder="Поиск..." aria-label="Поиск">
      </form>
    </div>
    ${authButtons}
  </div>
  ${body}
  ${bottomNav}
</body>
</html>`;
}

// ============================================================
//  РЕНДЕР ПОСТА
// ============================================================
function renderPost(post, user, opts = {}) {
  const author = getUserById(post.user_id);
  if (!author) return '';
  const likes = post.likes || [];
  const comments = post.comments || [];
  const reposts = post.reposts || [];
  const liked = user && likes.includes(user.id);
  const reposted = user && reposts.includes(user.id);

  // Оригинал при репосте
  let repostBox = '';
  if (post.repost_of) {
    const orig = getPostById(post.repost_of);
    if (orig) {
      const origAuthor = getUserById(orig.user_id);
      repostBox = `<div class="repost-of-box">↗️ Репост от <strong>@${escapeHtml(origAuthor?.username || 'user')}</strong><br>${escapeHtml(orig.content).slice(0, 200)}</div>`;
    }
  }

  // Кнопки действий
  const likeForm = user
    ? `<form method="POST" action="/post/${post.id}/like"><button class="${liked ? 'liked' : ''}" type="submit">${liked ? '💙' : '❤️'} Нравится (${likes.length})</button></form>`
    : `<form method="GET" action="/login"><button type="submit">❤️ Нравится (${likes.length})</button></form>`;

  const commentLink = `/post/${post.id}`;
  const commentBtn = `<form method="GET" action="${commentLink}"><button type="submit">💬 Комментировать (${comments.length})</button></form>`;

  const repostForm = user
    ? `<form method="POST" action="/post/${post.id}/repost"><button class="${reposted ? 'reposted' : ''}" type="submit">↗️ Репост (${reposts.length})</button></form>`
    : `<form method="GET" action="/login"><button type="submit">↗️ Репост (${reposts.length})</button></form>`;

  // Комментарии (только на странице поста)
  let commentsSection = '';
  if (opts.showComments) {
    const commentsHtml = comments.length === 0
      ? `<div style="color:#666;font-size:13px;padding:8px 0;">Комментариев пока нет. Будьте первым!</div>`
      : comments.map(c => {
          const cAuthor = getUserById(c.user_id);
          if (!cAuthor) return '';
          return `<div class="comment">
            <div class="avatar" style="background:${escapeHtml(cAuthor.avatar || '#33B5E5')};">${initial(cAuthor.username)}</div>
            <div class="comment-body">
              <div><span class="comment-author">${escapeHtml(cAuthor.username)}</span><span class="comment-time">${formatDate(c.timestamp)}</span></div>
              <div class="comment-text">${escapeHtml(c.content)}</div>
            </div>
          </div>`;
        }).join('');

    const commentForm = user
      ? `<form class="comment-form" method="POST" action="/post/${post.id}/comment">
          <input type="text" name="content" placeholder="Написать комментарий..." required maxlength="500">
          <button type="submit">Отправить</button>
        </form>`
      : `<div class="comment-login">🔐 <a href="/login">Войдите</a>, чтобы оставить комментарий</div>`;

    commentsSection = `<div class="comments-section">
      <div style="font-weight:600;font-size:14px;margin-bottom:6px;">💬 Комментарии (${comments.length})</div>
      ${commentsHtml}
      ${commentForm}
    </div>`;
  }

  return `
    <div class="post-card">
      <div class="post-header">
        <div class="avatar" style="background:${escapeHtml(author.avatar || '#33B5E5')};">${initial(author.username)}</div>
        <div>
          <div class="post-author"><a href="/user/${author.id}">${escapeHtml(author.username)}</a></div>
          <div class="post-time">${formatDate(post.timestamp)}</div>
        </div>
      </div>
      ${repostBox}
      <div class="post-content">${escapeHtml(post.content)}</div>
      <div class="post-actions">
        ${likeForm}
        ${commentBtn}
        ${repostForm}
      </div>
      ${commentsSection}
    </div>`;
}

// ============================================================
//  МАРШРУТЫ
// ============================================================

app.get('/', (req, res) => {
  const user = req.user;
  const searchQuery = (req.query.search || '').toString();
  const posts = searchQuery ? searchPosts(searchQuery) : getPosts();

  const postsHtml = posts.length === 0
    ? `<div class="empty-feed"><span>${searchQuery ? '🔍' : '📭'}</span>${searchQuery ? 'Ничего не найдено.' : 'Здесь пока нет постов.' + (user ? '<br>Напишите что-нибудь!' : '')}</div>`
    : posts.map(p => renderPost(p, user)).join('');

  let newPostHtml;
  if (user) {
    newPostHtml = `
      <div class="new-post-area">
        <div class="avatar" style="width:36px;height:36px;font-size:14px;background:${escapeHtml(user.avatar || '#33B5E5')};">${initial(user.username)}</div>
        <form method="POST" action="/post" style="flex:1;display:flex;gap:12px;align-items:center;margin:0;padding:0;">
          <input type="text" name="content" placeholder="Что у вас нового?" required>
          <button type="submit">Опубликовать</button>
        </form>
      </div>`;
  } else {
    newPostHtml = `
      <div class="guest-prompt">
        <p>🔐 Чтобы публиковать, лайкать и комментировать — войдите через LinAccounts</p>
        <a href="/login" class="btn-login">Войти</a>
      </div>`;
  }

  const searchInfo = searchQuery
    ? `<div style="color:#888;margin:8px 0;font-size:14px;">🔍 Результаты поиска: <strong style="color:#eee;">${escapeHtml(searchQuery)}</strong> <a href="/" style="margin-left:12px;">✕ Сбросить</a></div>`
    : '';

  const body = `
    <div style="max-width:600px;margin:0 auto;padding:8px 0;">
      ${newPostHtml}
      ${searchInfo}
      ${postsHtml}
    </div>`;

  res.send(layout({ title: 'Главная', body, activeNav: 'home', user }));
});

// --- Создание поста ---
app.post('/post', (req, res) => {
  if (!req.user) return res.redirect('/login');
  const content = (req.body.content || '').trim();
  if (content) addPost(req.user.id, content);
  res.redirect('/');
});

// --- Лайк ---
app.post('/post/:id/like', (req, res) => {
  if (!req.user) return res.redirect('/login');
  const id = parseInt(req.params.id, 10);
  toggleLike(id, req.user.id);
  const back = req.get('referer') || '/';
  res.redirect(back);
});

// --- Репост ---
app.post('/post/:id/repost', (req, res) => {
  if (!req.user) return res.redirect('/login');
  const id = parseInt(req.params.id, 10);
  addRepost(id, req.user.id);
  res.redirect('/');
});

// --- Комментарий ---
app.post('/post/:id/comment', (req, res) => {
  if (!req.user) return res.redirect('/login');
  const id = parseInt(req.params.id, 10);
  const content = (req.body.content || '').trim();
  if (content) addComment(id, req.user.id, content);
  res.redirect(`/post/${id}`);
});

// --- Страница поста ---
app.get('/post/:id', (req, res) => {
  const id = parseInt(req.params.id, 10);
  const post = getPostById(id);
  if (!post) return res.status(404).send(layout({
    title: 'Не найдено',
    body: '<div style="text-align:center;padding:60px 20px;"><h1>📄 Пост не найден</h1><p><a href="/">← На главную</a></p></div>',
    user: req.user
  }));

  const body = `
    <div class="post-full">
      <a class="back-link" href="/">← Назад к ленте</a>
      ${renderPost(post, req.user, { showComments: true })}
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
  if (!profileUser) return res.status(404).send(layout({
    title: 'Не найдено',
    body: '<div style="text-align:center;padding:60px 20px;"><h1>👤 Пользователь не найден</h1><p><a href="/">← На главную</a></p></div>',
    user: req.user
  }));

  const myPosts = getPosts().filter(p => p.user_id === profileUser.id);
  const isMe = req.user && req.user.id === profileUser.id;

  const postsHtml = myPosts.length === 0
    ? `<div class="empty-feed">У пользователя пока нет постов.</div>`
    : myPosts.map(p => renderPost(p, req.user)).join('');

  const emailHtml = profileUser.email && isMe
    ? `<div class="profile-email">📧 ${escapeHtml(profileUser.email)}</div>`
    : '';

  const body = `
    <div style="max-width:600px;margin:0 auto;padding:8px 16px;">
      <div class="profile-card">
        <div class="profile-avatar" style="background:${escapeHtml(profileUser.avatar || '#33B5E5')};">${initial(profileUser.username)}</div>
        <div class="profile-name">${escapeHtml(profileUser.username)}</div>
        ${emailHtml}
        <div class="profile-oauth-badge">🔑 Вход через LinAccounts</div>
        <div class="profile-stats">
          <div class="stat-item"><div class="stat-number">${myPosts.length}</div><div class="stat-label">Постов</div></div>
          <div class="stat-item"><div class="stat-number">0</div><div class="stat-label">Подписчиков</div></div>
        </div>
      </div>
      <h3 style="font-weight:300;margin:20px 0 10px;">Посты</h3>
      ${postsHtml}
    </div>`;

  res.send(layout({ title: profileUser.username, body, activeNav: isMe ? 'profile' : '', user: req.user }));
});

// --- Вход / OAuth ---
app.get('/login', (req, res) => {
  if (req.user) return res.redirect('/');

  const body = `
    <div style="display:flex;justify-content:center;align-items:center;min-height:80vh;">
      <div style="background:#1e1e1e;padding:40px 30px;border-radius:4px;box-shadow:0 4px 12px rgba(0,0,0,0.6);width:100%;max-width:380px;text-align:center;">
        <h1 style="margin-top:0;font-weight:300;font-size:32px;">
          <span style="color:#FF8800;">Lin</span><span style="color:#66FF00;">+</span>
        </h1>
        <div style="color:#aaa;font-size:14px;margin:8px 0 30px;">Войдите в свою социальную сеть</div>
        <a href="/auth" style="text-decoration:none;">
          <button style="display:block;width:100%;padding:14px;background:#FF8800;color:#fff;border:none;border-radius:2px;font-size:18px;font-weight:500;cursor:pointer;box-shadow:0 2px 8px rgba(255,136,0,0.3);">
            <span style="margin-right:10px;">🚀</span> Войти через LinAccounts
          </button>
        </a>
        <div style="color:#666;font-size:13px;margin-top:24px;line-height:1.6;">
          🔐 Безопасный вход через <strong>LinAccounts</strong><br>
          Чтение постов доступно без входа.
        </div>
        <div style="margin-top:20px;">
          <a href="/" style="color:#33B5E5;font-size:14px;">← Вернуться к чтению</a>
        </div>
      </div>
    </div>`;
  res.send(layout({ title: 'Вход', body, activeNav: '', user: null }));
});

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

app.get('/callback', async (req, res) => {
  const { code, state, error } = req.query;

  if (error) return res.status(400).send(`❌ Ошибка авторизации: ${escapeHtml(error)}`);
  if (!code || !state) return res.status(400).send('❌ Недостаточно параметров');
  if (state !== req.session.oauth_state) return res.status(400).send('❌ CSRF-атака: неверный state');

  try {
    const tokenResp = await axios.post(
      `${LINACCOUNTS_URL}/oauth/token`,
      { code, client_id: CLIENT_ID, client_secret: CLIENT_SECRET },
      { headers: { 'Content-Type': 'application/json' }, timeout: 30000 }
    );

    const accessToken = tokenResp.data.access_token;
    const refreshToken = tokenResp.data.refresh_token;
    if (!accessToken) return res.status(500).send('❌ Не получен access_token');

    const userResp = await axios.get(`${LINACCOUNTS_URL}/oauth/userinfo`, {
      headers: { Authorization: `Bearer ${accessToken}` },
      timeout: 30000
    });

    const userData = userResp.data;
    if (!userData || !userData.username) return res.status(500).send('❌ Не получены данные пользователя');

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
    console.error('OAuth ошибка:', err.response ? err.response.data : err.message);
    res.status(500).send(`❌ Ошибка авторизации: ${escapeHtml(err.message)}`);
  }
});

app.get('/logout', (req, res) => {
  req.session.destroy(() => res.redirect('/'));
});

// ============================================================
//  ЗАПУСК
// ============================================================
app.listen(PORT, () => {
  console.log(`🚀 Lin+ запущен на ${BASE_URL}`);
  console.log(`🔐 OAuth: ${LINACCOUNTS_URL}`);
  console.log(`📁 Данные: ${DATA_DIR}`);
  console.log(`🔗 Redirect URI: ${REDIRECT_URI}`);
  console.log(`❤️  Лайки, 💬 комментарии, ↗️ репосты — активны.`);
});
ENDOFFILE
echo "✅ server.js обновлён"