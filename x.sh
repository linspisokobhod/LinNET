cat > /root/linaccounts/server.js << 'EOF'
// ================================================================
//  server.js — LinAccounts API
//  Возможности: 2FA, OAuth 2.0, смена пароля, анти-спам регистрации
//  Порт: 9001
// ================================================================

const express = require('express');
const sqlite3 = require('sqlite3').verbose();
const bcrypt = require('bcrypt');
const cors = require('cors');
const cookieParser = require('cookie-parser');
const { randomUUID: uuidv4 } = require('crypto');
const speakeasy = require('speakeasy');
const QRCode = require('qrcode');
const path = require('path');

const app = express();
const PORT = 9001;

// --- Middleware ---
app.use(cors({
  origin: '*',
  methods: ['GET', 'POST', 'OPTIONS'],
  allowedHeaders: ['Content-Type', 'Authorization'],
  credentials: true
}));
app.use(express.json());
app.use(express.urlencoded({ extended: true }));
app.use(cookieParser());
app.use(express.static(path.join(__dirname, 'public')));

// --- База данных SQLite ---
const db = new sqlite3.Database('./linaccounts.db');

db.serialize(() => {
  db.run(`
    CREATE TABLE IF NOT EXISTS users (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      username TEXT UNIQUE NOT NULL,
      password TEXT NOT NULL,
      firstName TEXT,
      lastName TEXT,
      totp_secret TEXT,
      created INTEGER DEFAULT (strftime('%s', 'now'))
    )
  `);
  db.run(`
    CREATE TABLE IF NOT EXISTS sessions (
      token TEXT PRIMARY KEY,
      username TEXT NOT NULL,
      created INTEGER DEFAULT (strftime('%s', 'now')),
      expires INTEGER
    )
  `);
  db.run(`
    CREATE TABLE IF NOT EXISTS oauth_codes (
      code TEXT PRIMARY KEY,
      username TEXT NOT NULL,
      client_id TEXT NOT NULL,
      redirect_uri TEXT NOT NULL,
      created INTEGER DEFAULT (strftime('%s', 'now'))
    )
  `);
  db.run(`
    CREATE TABLE IF NOT EXISTS oauth_tokens (
      token TEXT PRIMARY KEY,
      username TEXT NOT NULL,
      created INTEGER DEFAULT (strftime('%s', 'now')),
      expires INTEGER
    )
  `);
  db.run(`
    CREATE TABLE IF NOT EXISTS refresh_tokens (
      token TEXT PRIMARY KEY,
      username TEXT NOT NULL,
      created INTEGER DEFAULT (strftime('%s', 'now')),
      expires INTEGER
    )
  `);
  db.run(`
    CREATE TABLE IF NOT EXISTS oauth_clients (
      client_id TEXT PRIMARY KEY,
      client_secret TEXT NOT NULL,
      redirect_uri TEXT NOT NULL,
      name TEXT
    )
  `);
  // Анти-спам: лог регистраций по IP
  db.run(`
    CREATE TABLE IF NOT EXISTS registration_log (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      ip TEXT NOT NULL,
      username TEXT NOT NULL,
      created INTEGER DEFAULT (strftime('%s', 'now'))
    )
  `);
  db.run(`CREATE INDEX IF NOT EXISTS idx_reg_ip ON registration_log(ip)`);
  db.run(`CREATE INDEX IF NOT EXISTS idx_reg_created ON registration_log(created)`);

  db.get('SELECT * FROM oauth_clients WHERE client_id = ?', ['demo'], (err, row) => {
    if (!row) {
      db.run(`
        INSERT INTO oauth_clients (client_id, client_secret, redirect_uri, name)
        VALUES (?, ?, ?, ?)
      `, ['demo', 'demo-secret', 'https://example.com/callback', 'Демо-приложение']);
      console.log('✅ Добавлен тестовый OAuth клиент: demo / demo-secret');
    }
  });
});

// --- Вспомогательные функции ---
function generateTOTPSecret() {
  return speakeasy.generateSecret({ length: 20 }).base32;
}

function verifyTOTP(secret, token) {
  return speakeasy.totp.verify({
    secret: secret,
    encoding: 'base32',
    token: token,
    window: 1
  });
}

function getClientIP(req) {
  return (req.headers['cf-connecting-ip'] ||
          req.headers['x-real-ip'] ||
          (req.headers['x-forwarded-for'] || '').split(',')[0].trim() ||
          req.socket.remoteAddress ||
          'unknown');
}

// ================================================================
//  ВНУТРЕННИЙ API
// ================================================================

// ---- Регистрация (с анти-спамом) ----
app.post('/api/signup', async (req, res) => {
  try {
    const { username, password, firstName, lastName, enable2fa } = req.body;
    const ip = getClientIP(req);

    console.log(`📝 Регистрация: username=${username}, ip=${ip}`);

    // --- Проверка лимита регистраций с этого IP ---
    const MAX_REGISTRATIONS_PER_MONTH = 2;
    const MONTH_SECONDS = 30 * 24 * 60 * 60;
    const since = Math.floor(Date.now() / 1000) - MONTH_SECONDS;

    const recentCount = await new Promise((resolve, reject) => {
      db.get(
        'SELECT COUNT(*) as cnt FROM registration_log WHERE ip = ? AND created > ?',
        [ip, since],
        (err, row) => {
          if (err) return reject(err);
          resolve(row ? row.cnt : 0);
        }
      );
    });

    if (recentCount >= MAX_REGISTRATIONS_PER_MONTH) {
      console.log(`⛔ IP ${ip} превысил лимит (${recentCount}/${MAX_REGISTRATIONS_PER_MONTH})`);
      return res.status(429).json({
        error: 'С этого IP уже зарегистрировано максимальное количество аккаунтов за месяц. Попробуйте позже.'
      });
    }

    // --- Валидация ---
    if (!username || !password) {
      return res.status(400).json({ error: 'Missing username or password' });
    }
    if (password.length < 6) {
      return res.status(400).json({ error: 'Password must be at least 6 characters' });
    }
    if (!/^[a-zA-Z0-9_.-]{3,32}$/.test(username)) {
      return res.status(400).json({ error: 'Username: 3-32 символов, a-z, A-Z, 0-9, _, ., -' });
    }

    const hashed = await bcrypt.hash(password, 10);
    let totpSecret = null;
    if (enable2fa) {
      totpSecret = generateTOTPSecret();
    }

    db.run(
      'INSERT INTO users (username, password, firstName, lastName, totp_secret) VALUES (?, ?, ?, ?, ?)',
      [username, hashed, firstName || '', lastName || '', totpSecret],
      function(err) {
        if (err) {
          if (err.message.includes('UNIQUE')) {
            return res.status(409).json({ error: 'User already exists' });
          }
          return res.status(500).json({ error: 'Database error' });
        }

        // Логируем регистрацию по IP
        db.run(
          'INSERT INTO registration_log (ip, username) VALUES (?, ?)',
          [ip, username],
          (logErr) => {
            if (logErr) console.error('⚠️ Ошибка логирования IP:', logErr.message);
          }
        );

        const response = { message: 'User created successfully' };
        if (totpSecret) {
          const otpauth = `otpauth://totp/LinAccounts:${username}?secret=${totpSecret}&issuer=LinAccounts`;
          QRCode.toDataURL(otpauth, (err, qr) => {
            if (err) return res.status(201).json({ ...response, totpSecret, qr: null });
            res.status(201).json({ ...response, totpSecret, qr });
          });
        } else {
          res.status(201).json(response);
        }
      }
    );
  } catch (e) {
    console.error(e);
    res.status(400).json({ error: 'Invalid request' });
  }
});

// ---- Включение 2FA ----
app.post('/api/enable-2fa', async (req, res) => {
  const { username, password } = req.body;
  if (!username || !password) {
    return res.status(400).json({ error: 'Missing username or password' });
  }

  db.get('SELECT * FROM users WHERE username = ?', [username], async (err, user) => {
    if (err || !user) return res.status(404).json({ error: 'User not found' });
    const valid = await bcrypt.compare(password, user.password);
    if (!valid) return res.status(401).json({ error: 'Invalid credentials' });
    if (user.totp_secret) return res.status(400).json({ error: '2FA already enabled' });

    const secret = generateTOTPSecret();
    db.run('UPDATE users SET totp_secret = ? WHERE username = ?', [secret, username], function(err) {
      if (err) return res.status(500).json({ error: 'Database error' });
      const otpauth = `otpauth://totp/LinAccounts:${username}?secret=${secret}&issuer=LinAccounts`;
      QRCode.toDataURL(otpauth, (err, qr) => {
        if (err) return res.json({ message: '2FA enabled', secret });
        res.json({ message: '2FA enabled', secret, qr });
      });
    });
  });
});

// ---- Отключение 2FA ----
app.post('/api/disable-2fa', async (req, res) => {
  const { username, password } = req.body;
  if (!username || !password) return res.status(400).json({ error: 'Missing username or password' });

  const tokenHeader = req.headers.authorization;
  if (!tokenHeader || !tokenHeader.startsWith('Bearer ')) return res.status(401).json({ error: 'Unauthorized' });

  const sessionToken = tokenHeader.slice(7);
  db.get('SELECT username FROM sessions WHERE token = ? AND expires > strftime("%s", "now")', [sessionToken], async (err, row) => {
    if (err || !row || row.username !== username) return res.status(401).json({ error: 'Invalid session' });

    db.get('SELECT * FROM users WHERE username = ?', [username], async (err, user) => {
      if (err || !user) return res.status(404).json({ error: 'User not found' });
      const valid = await bcrypt.compare(password, user.password);
      if (!valid) return res.status(401).json({ error: 'Invalid password' });
      if (!user.totp_secret) return res.status(400).json({ error: '2FA is not enabled' });

      db.run('UPDATE users SET totp_secret = NULL WHERE username = ?', [username], function(err) {
        if (err) return res.status(500).json({ error: 'Database error' });
        res.json({ message: '2FA disabled successfully' });
      });
    });
  });
});

// ---- Смена пароля ----
app.post('/api/change-password', async (req, res) => {
  const { username, oldPassword, newPassword } = req.body;
  if (!username || !oldPassword || !newPassword) return res.status(400).json({ error: 'Missing fields' });
  if (newPassword.length < 6) return res.status(400).json({ error: 'New password must be at least 6 characters' });

  const tokenHeader = req.headers.authorization;
  if (!tokenHeader || !tokenHeader.startsWith('Bearer ')) return res.status(401).json({ error: 'Unauthorized' });

  const sessionToken = tokenHeader.slice(7);
  db.get('SELECT username FROM sessions WHERE token = ? AND expires > strftime("%s", "now")', [sessionToken], async (err, row) => {
    if (err || !row || row.username !== username) return res.status(401).json({ error: 'Invalid session' });

    db.get('SELECT * FROM users WHERE username = ?', [username], async (err, user) => {
      if (err || !user) return res.status(404).json({ error: 'User not found' });
      const valid = await bcrypt.compare(oldPassword, user.password);
      if (!valid) return res.status(401).json({ error: 'Invalid old password' });

      const newHashed = await bcrypt.hash(newPassword, 10);
      db.run('UPDATE users SET password = ? WHERE username = ?', [newHashed, username], function(err) {
        if (err) return res.status(500).json({ error: 'Database error' });
        res.json({ message: 'Password changed successfully' });
      });
    });
  });
});

// ---- Вход ----
app.post('/api/login', async (req, res) => {
  try {
    const { username, password, totpToken } = req.body;
    if (!username || !password) return res.status(400).json({ error: 'Missing username or password' });

    db.get('SELECT * FROM users WHERE username = ?', [username], async (err, user) => {
      if (err || !user) return res.status(401).json({ error: 'Invalid credentials' });

      const valid = await bcrypt.compare(password, user.password);
      if (!valid) return res.status(401).json({ error: 'Invalid credentials' });

      if (user.totp_secret) {
        if (!totpToken) return res.status(403).json({ error: '2FA required', requires2fa: true });
        const verified = verifyTOTP(user.totp_secret, totpToken);
        if (!verified) return res.status(403).json({ error: 'Invalid 2FA code' });
      }

      const token = uuidv4();
      const expires = Math.floor(Date.now() / 1000) + 86400;
      db.run('INSERT INTO sessions (token, username, expires) VALUES (?, ?, ?)',
        [token, username, expires],
        function(err) {
          if (err) return res.status(500).json({ error: 'Database error' });
          res.json({ token });
        }
      );
    });
  } catch (e) {
    console.error(e);
    res.status(400).json({ error: 'Invalid request' });
  }
});

// ---- Получение данных пользователя ----
app.get('/api/me', (req, res) => {
  const token = req.headers.authorization?.split(' ')[1];
  if (!token) return res.status(401).json({ error: 'Unauthorized' });

  db.get('SELECT username FROM sessions WHERE token = ? AND expires > strftime("%s", "now")', [token], (err, row) => {
    if (err || !row) return res.status(401).json({ error: 'Invalid or expired token' });

    db.get('SELECT username, firstName, lastName, totp_secret, created FROM users WHERE username = ?', [row.username], (err, user) => {
      if (err || !user) return res.status(404).json({ error: 'User not found' });
      const has2fa = !!user.totp_secret;
      delete user.totp_secret;
      res.json({ ...user, has2fa });
    });
  });
});

// ================================================================
//  OAuth 2.0
// ================================================================

// ---- GET /oauth/authorize ----
app.get('/oauth/authorize', (req, res) => {
  const { client_id, redirect_uri, response_type, state } = req.query;

  console.log('=== GET /oauth/authorize ===');
  console.log('client_id:', client_id);
  console.log('redirect_uri:', redirect_uri);

  db.get('SELECT * FROM oauth_clients WHERE client_id = ?', [client_id], (err, client) => {
    if (err || !client) {
      console.log('❌ Клиент не найден:', client_id);
      return res.status(400).send('Invalid client_id');
    }
    if (client.redirect_uri !== redirect_uri) {
      console.log('❌ redirect_uri не совпадает');
      console.log('   В БД:  ', client.redirect_uri);
      console.log('   Получен:', redirect_uri);
      return res.status(400).send('Invalid redirect_uri');
    }
    if (response_type !== 'code') return res.status(400).send('Only authorization code flow is supported');

    const sessionToken = req.cookies && req.cookies.lin_session;
    console.log('cookie lin_session:', sessionToken || 'нет');

    if (sessionToken) {
      db.get('SELECT username FROM sessions WHERE token = ? AND expires > strftime("%s", "now")', [sessionToken], (err, row) => {
        if (row) {
          console.log('✅ Пользователь уже залогинен:', row.username);
          const code = uuidv4();
          db.run('INSERT INTO oauth_codes (code, username, client_id, redirect_uri) VALUES (?, ?, ?, ?)',
            [code, row.username, client_id, redirect_uri],
            () => {
              const url = new URL(redirect_uri);
              url.searchParams.set('code', code);
              if (state) url.searchParams.set('state', state);
              console.log('✅ Редирект на:', url.toString());
              res.redirect(url.toString());
            });
        } else {
          res.send(renderLoginPage(client_id, redirect_uri, state));
        }
      });
    } else {
      res.send(renderLoginPage(client_id, redirect_uri, state));
    }
  });
});

// ---- POST /oauth/authorize ----
app.post('/oauth/authorize', (req, res) => {
  const { username, password, client_id, redirect_uri, state } = req.body;

  console.log('=== POST /oauth/authorize ===');
  console.log('username:', username);
  console.log('client_id:', client_id);
  console.log('redirect_uri:', redirect_uri);

  db.get('SELECT * FROM oauth_clients WHERE client_id = ?', [client_id], async (err, client) => {
    if (err || !client) {
      console.log('❌ Клиент не найден');
      return res.status(400).send('Invalid client_id');
    }
    if (client.redirect_uri !== redirect_uri) {
      console.log('❌ redirect_uri не совпадает');
      console.log('   В БД:  ', client.redirect_uri);
      console.log('   Получен:', redirect_uri);
      return res.status(400).send('Invalid redirect_uri');
    }

    db.get('SELECT * FROM users WHERE username = ?', [username], async (err, user) => {
      if (err || !user) {
        console.log('❌ Пользователь не найден:', username);
        return res.status(401).send('Invalid credentials');
      }

      const valid = await bcrypt.compare(password, user.password);
      if (!valid) {
        console.log('❌ Неверный пароль для:', username);
        return res.status(401).send('Invalid credentials');
      }

      console.log('✅ Логин успешен:', username);

      const sessionToken = uuidv4();
      const expires = Math.floor(Date.now() / 1000) + 86400;

      db.run('INSERT INTO sessions (token, username, expires) VALUES (?, ?, ?)',
        [sessionToken, username, expires], () => {
          const code = uuidv4();
          db.run('INSERT INTO oauth_codes (code, username, client_id, redirect_uri) VALUES (?, ?, ?, ?)',
            [code, username, client_id, redirect_uri], () => {
              const url = new URL(redirect_uri);
              url.searchParams.set('code', code);
              if (state) url.searchParams.set('state', state);
              console.log('✅ Редирект на:', url.toString());

              res.cookie('lin_session', sessionToken, {
                httpOnly: true,
                secure: false,
                maxAge: 86400000,
                sameSite: 'lax'
              });
              res.redirect(url.toString());
            });
        });
    });
  });
});

// ---- POST /oauth/token ----
app.post('/oauth/token', (req, res) => {
  const { code, client_id, client_secret } = req.body;
  console.log('=== POST /oauth/token ===');

  if (!code || !client_id || !client_secret) return res.status(400).json({ error: 'Missing parameters' });

  db.get('SELECT * FROM oauth_clients WHERE client_id = ?', [client_id], (err, client) => {
    if (err || !client || client.client_secret !== client_secret) {
      console.log('❌ Неверный клиент');
      return res.status(400).json({ error: 'Invalid client' });
    }

    db.get('SELECT * FROM oauth_codes WHERE code = ?', [code], (err, codeRow) => {
      if (err || !codeRow) return res.status(400).json({ error: 'Invalid or expired code' });
      if (codeRow.client_id !== client_id) return res.status(400).json({ error: 'Code does not match client' });

      db.run('DELETE FROM oauth_codes WHERE code = ?', [code]);

      const accessToken = uuidv4();
      const refreshToken = uuidv4();
      const now = Math.floor(Date.now() / 1000);

      db.run('INSERT INTO oauth_tokens (token, username, expires) VALUES (?, ?, ?)',
        [accessToken, codeRow.username, now + 900], () => {
          db.run('INSERT INTO refresh_tokens (token, username, expires) VALUES (?, ?, ?)',
            [refreshToken, codeRow.username, now + 604800], () => {
              console.log('✅ Токены выданы для:', codeRow.username);
              res.json({
                access_token: accessToken,
                token_type: 'Bearer',
                expires_in: 900,
                refresh_token: refreshToken
              });
            });
        });
    });
  });
});

// ---- POST /oauth/refresh ----
app.post('/oauth/refresh', (req, res) => {
  const { refresh_token } = req.body;
  if (!refresh_token) return res.status(400).json({ error: 'Missing refresh_token' });

  db.get('SELECT * FROM refresh_tokens WHERE token = ? AND expires > strftime("%s", "now")', [refresh_token], (err, row) => {
    if (err || !row) return res.status(401).json({ error: 'Invalid or expired refresh token' });

    db.run('DELETE FROM refresh_tokens WHERE token = ?', [refresh_token]);

    const newAccess = uuidv4();
    const newRefresh = uuidv4();
    const now = Math.floor(Date.now() / 1000);

    db.run('INSERT INTO oauth_tokens (token, username, expires) VALUES (?, ?, ?)',
      [newAccess, row.username, now + 900], () => {
        db.run('INSERT INTO refresh_tokens (token, username, expires) VALUES (?, ?, ?)',
          [newRefresh, row.username, now + 604800], () => {
            res.json({
              access_token: newAccess,
              token_type: 'Bearer',
              expires_in: 900,
              refresh_token: newRefresh
            });
          });
      });
  });
});

// ---- GET /oauth/userinfo ----
app.get('/oauth/userinfo', (req, res) => {
  const token = req.headers.authorization?.split(' ')[1];
  if (!token) return res.status(401).json({ error: 'Unauthorized' });

  db.get('SELECT username FROM oauth_tokens WHERE token = ? AND expires > strftime("%s", "now")', [token], (err, row) => {
    if (err || !row) return res.status(401).json({ error: 'Invalid or expired token' });

    db.get('SELECT username, firstName, lastName, created FROM users WHERE username = ?', [row.username], (err, user) => {
      if (err || !user) return res.status(404).json({ error: 'User not found' });
      res.json(user);
    });
  });
});

// ================================================================
//  HTML-страница входа для OAuth
// ================================================================

function renderLoginPage(clientId, redirectUri, state) {
  return `<!DOCTYPE html>
<html lang="ru"><head><meta charset="UTF-8"><title>Вход в LinAccounts</title>
<link href="https://fonts.googleapis.com/css2?family=Roboto:wght@300;400;500&display=swap" rel="stylesheet">
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:'Roboto',Arial,sans-serif;background:#111;min-height:100vh;display:flex;align-items:center;justify-content:center;padding:20px}
.card{background:#1c1c1c;box-shadow:0 2px 10px rgba(0,0,0,.8);width:100%;max-width:400px;padding:40px 32px;border:1px solid #333}
.logo{text-align:center;margin-bottom:28px}
.logo .lin{font-size:34px;font-weight:700;color:#FF6D00}
.logo .acc{font-size:34px;font-weight:700;color:#00C853}
.logo-sub{color:#aaa;font-size:14px;margin-top:4px}
h1{color:#f0f0f0;font-weight:400;font-size:24px;margin-bottom:4px}
p.sub{color:#aaa;font-size:14px;margin-bottom:24px}
label{display:block;color:#ccc;font-size:13px;text-transform:uppercase;letter-spacing:.5px;margin-bottom:4px}
input{width:100%;padding:10px 12px;font-size:16px;background:#222;border:1px solid #444;color:#f0f0f0;outline:0;margin-bottom:16px}
input:focus{border-color:#FF6D00;box-shadow:0 0 6px rgba(255,109,0,.5)}
button{width:100%;padding:12px;background:#FF6D00;color:#fff;border:0;font-size:16px;font-weight:500;text-transform:uppercase;cursor:pointer;transition:background .2s}
button:hover{background:#e65100}
.error{color:#d93025;font-size:13px;margin-top:-12px;margin-bottom:12px;display:none}
.footer{text-align:center;margin-top:20px;color:#aaa;font-size:14px}
.footer a{color:#FF6D00;text-decoration:none}
</style></head>
<body>
<div class="card">
<div class="logo"><span class="lin">Lin</span><span class="acc">Accounts</span><div class="logo-sub">Вход через аккаунт</div></div>
<h1>Войти</h1>
<p class="sub">Используйте свои учётные данные LinAccounts</p>
<form method="post" action="/oauth/authorize">
<input type="hidden" name="client_id" value="${clientId}">
<input type="hidden" name="redirect_uri" value="${redirectUri}">
<input type="hidden" name="state" value="${state || ''}">
<label for="username">Юзернейм</label>
<input type="text" id="username" name="username" placeholder="Введите юзернейм" required>
<label for="password">Пароль</label>
<input type="password" id="password" name="password" placeholder="Введите пароль" required>
<div id="error" class="error"></div>
<button type="submit">Продолжить</button>
</form>
<div class="footer">Нет аккаунта? <a href="#" onclick="alert('Зарегистрируйтесь на сайте LinAccounts')">Создать</a></div>
</div>
<script>
document.querySelector('form').addEventListener('submit', function(e) {
  const pwd = document.getElementById('password').value;
  if (pwd.length < 6) {
    e.preventDefault();
    document.getElementById('error').textContent = 'Пароль должен быть не менее 6 символов';
    document.getElementById('error').style.display = 'block';
  }
});
</script></body></html>`;
}

// ================================================================
//  ЗАПУСК
// ================================================================

app.listen(PORT, '0.0.0.0', () => {
  console.log(`🚀 LinAccounts API запущен на порту ${PORT}`);
  console.log(`🌐 Веб-интерфейс: http://localhost:${PORT}/`);
  console.log('📋 Эндпоинты:');
  console.log('   POST /api/signup         - регистрация (анти-спам: 2/IP/месяц)');
  console.log('   POST /api/login          - вход');
  console.log('   GET  /api/me             - данные пользователя');
  console.log('   POST /api/change-password - смена пароля');
  console.log('   POST /api/enable-2fa     - включить 2FA');
  console.log('   POST /api/disable-2fa    - отключить 2FA');
  console.log('   GET  /oauth/authorize    - OAuth авторизация');
  console.log('   POST /oauth/token        - обмен кода на токены');
  console.log('   POST /oauth/refresh      - обновление токена');
  console.log('   GET  /oauth/userinfo     - данные (OAuth)');
});
EOF