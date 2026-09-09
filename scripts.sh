#!/bin/bash

set -e  # Остановка при любой ошибке

echo "🚀 Начинаем установку LinAccounts..."

# 1. Создаём папки
mkdir -p ~/linaccounts/public

# 2. Создаём server.js
cat > ~/linaccounts/server.js << 'EOF'
// ================================================================
//  server.js — LinAccounts API с 2FA + смена пароля + отключение 2FA
//  Порт: 9001
// ================================================================

const express = require('express');
const sqlite3 = require('sqlite3').verbose();
const bcrypt = require('bcrypt');
const cors = require('cors');
const { randomUUID: uuidv4 } = require('crypto');
const speakeasy = require('speakeasy');
const QRCode = require('qrcode');
const path = require('path');

const app = express();
const PORT = 9001;

app.use(cors({ origin: '*', methods: ['GET', 'POST', 'OPTIONS'], allowedHeaders: ['Content-Type', 'Authorization'] }));
app.use(express.json());
app.use(express.urlencoded({ extended: true }));
app.use(express.static(path.join(__dirname, 'public')));

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

// ---- Регистрация ----
app.post('/api/signup', async (req, res) => {
  try {
    const { username, password, firstName, lastName, enable2fa } = req.body;
    if (!username || !password) {
      return res.status(400).json({ error: 'Missing username or password' });
    }
    if (password.length < 6) {
      return res.status(400).json({ error: 'Password must be at least 6 characters' });
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
        const response = { message: 'User created successfully' };
        if (totpSecret) {
          const otpauth = `otpauth://totp/LinAccounts:${username}?secret=${totpSecret}&issuer=LinAccounts`;
          QRCode.toDataURL(otpauth, (err, qr) => {
            if (err) {
              return res.status(201).json({ ...response, totpSecret, qr: null });
            }
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
    if (err || !user) {
      return res.status(404).json({ error: 'User not found' });
    }
    const valid = await bcrypt.compare(password, user.password);
    if (!valid) {
      return res.status(401).json({ error: 'Invalid credentials' });
    }
    if (user.totp_secret) {
      return res.status(400).json({ error: '2FA already enabled' });
    }

    const secret = generateTOTPSecret();
    db.run('UPDATE users SET totp_secret = ? WHERE username = ?', [secret, username], function(err) {
      if (err) {
        return res.status(500).json({ error: 'Database error' });
      }
      const otpauth = `otpauth://totp/LinAccounts:${username}?secret=${secret}&issuer=LinAccounts`;
      QRCode.toDataURL(otpauth, (err, qr) => {
        if (err) {
          return res.json({ message: '2FA enabled', secret });
        }
        res.json({ message: '2FA enabled', secret, qr });
      });
    });
  });
});

// ---- Отключение 2FA ----
app.post('/api/disable-2fa', async (req, res) => {
  const { username, password } = req.body;
  if (!username || !password) {
    return res.status(400).json({ error: 'Missing username or password' });
  }

  const tokenHeader = req.headers.authorization;
  if (!tokenHeader || !tokenHeader.startsWith('Bearer ')) {
    return res.status(401).json({ error: 'Unauthorized' });
  }
  const sessionToken = tokenHeader.slice(7);
  db.get('SELECT username FROM sessions WHERE token = ? AND expires > strftime("%s", "now")', [sessionToken], async (err, row) => {
    if (err || !row || row.username !== username) {
      return res.status(401).json({ error: 'Invalid session' });
    }
    db.get('SELECT * FROM users WHERE username = ?', [username], async (err, user) => {
      if (err || !user) {
        return res.status(404).json({ error: 'User not found' });
      }
      const valid = await bcrypt.compare(password, user.password);
      if (!valid) {
        return res.status(401).json({ error: 'Invalid password' });
      }
      if (!user.totp_secret) {
        return res.status(400).json({ error: '2FA is not enabled' });
      }
      db.run('UPDATE users SET totp_secret = NULL WHERE username = ?', [username], function(err) {
        if (err) {
          return res.status(500).json({ error: 'Database error' });
        }
        res.json({ message: '2FA disabled successfully' });
      });
    });
  });
});

// ---- Смена пароля ----
app.post('/api/change-password', async (req, res) => {
  const { username, oldPassword, newPassword } = req.body;
  if (!username || !oldPassword || !newPassword) {
    return res.status(400).json({ error: 'Missing fields' });
  }
  if (newPassword.length < 6) {
    return res.status(400).json({ error: 'New password must be at least 6 characters' });
  }

  const tokenHeader = req.headers.authorization;
  if (!tokenHeader || !tokenHeader.startsWith('Bearer ')) {
    return res.status(401).json({ error: 'Unauthorized' });
  }
  const sessionToken = tokenHeader.slice(7);
  db.get('SELECT username FROM sessions WHERE token = ? AND expires > strftime("%s", "now")', [sessionToken], async (err, row) => {
    if (err || !row || row.username !== username) {
      return res.status(401).json({ error: 'Invalid session' });
    }
    db.get('SELECT * FROM users WHERE username = ?', [username], async (err, user) => {
      if (err || !user) {
        return res.status(404).json({ error: 'User not found' });
      }
      const valid = await bcrypt.compare(oldPassword, user.password);
      if (!valid) {
        return res.status(401).json({ error: 'Invalid old password' });
      }
      const newHashed = await bcrypt.hash(newPassword, 10);
      db.run('UPDATE users SET password = ? WHERE username = ?', [newHashed, username], function(err) {
        if (err) {
          return res.status(500).json({ error: 'Database error' });
        }
        res.json({ message: 'Password changed successfully' });
      });
    });
  });
});

// ---- Вход ----
app.post('/api/login', async (req, res) => {
  try {
    const { username, password, totpToken } = req.body;
    if (!username || !password) {
      return res.status(400).json({ error: 'Missing username or password' });
    }

    db.get('SELECT * FROM users WHERE username = ?', [username], async (err, user) => {
      if (err || !user) {
        return res.status(401).json({ error: 'Invalid credentials' });
      }
      const valid = await bcrypt.compare(password, user.password);
      if (!valid) {
        return res.status(401).json({ error: 'Invalid credentials' });
      }

      if (user.totp_secret) {
        if (!totpToken) {
          return res.status(403).json({ error: '2FA required', requires2fa: true });
        }
        const verified = verifyTOTP(user.totp_secret, totpToken);
        if (!verified) {
          return res.status(403).json({ error: 'Invalid 2FA code' });
        }
      }

      const token = uuidv4();
      const expires = Math.floor(Date.now() / 1000) + 86400;
      db.run(
        'INSERT INTO sessions (token, username, expires) VALUES (?, ?, ?)',
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
  if (!token) {
    return res.status(401).json({ error: 'Unauthorized' });
  }

  db.get('SELECT username FROM sessions WHERE token = ? AND expires > strftime("%s", "now")', [token], (err, row) => {
    if (err || !row) {
      return res.status(401).json({ error: 'Invalid or expired token' });
    }
    db.get('SELECT username, firstName, lastName, totp_secret, created FROM users WHERE username = ?', [row.username], (err, user) => {
      if (err || !user) {
        return res.status(404).json({ error: 'User not found' });
      }
      const has2fa = !!user.totp_secret;
      delete user.totp_secret;
      res.json({ ...user, has2fa });
    });
  });
});

// ---- OAuth (сокращённо) ----
app.get('/oauth/authorize', (req, res) => {
  const { client_id, redirect_uri, response_type, state } = req.query;
  db.get('SELECT * FROM oauth_clients WHERE client_id = ?', [client_id], (err, client) => {
    if (err || !client || client.redirect_uri !== redirect_uri || response_type !== 'code') {
      return res.status(400).send('Invalid request');
    }
    const sessionToken = req.cookies?.lin_session;
    if (sessionToken) {
      db.get('SELECT username FROM sessions WHERE token = ? AND expires > strftime("%s", "now")', [sessionToken], (err, row) => {
        if (row) {
          const code = uuidv4();
          db.run('INSERT INTO oauth_codes (code, username, client_id, redirect_uri) VALUES (?, ?, ?, ?)',
            [code, row.username, client_id, redirect_uri], () => {
              const url = new URL(redirect_uri);
              url.searchParams.set('code', code);
              if (state) url.searchParams.set('state', state);
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

app.post('/oauth/authorize', (req, res) => {
  const { username, password, client_id, redirect_uri, state } = req.body;
  db.get('SELECT * FROM oauth_clients WHERE client_id = ?', [client_id], async (err, client) => {
    if (err || !client || client.redirect_uri !== redirect_uri) {
      return res.status(400).send('Invalid request');
    }
    db.get('SELECT * FROM users WHERE username = ?', [username], async (err, user) => {
      if (err || !user) return res.status(401).send('Invalid credentials');
      const valid = await bcrypt.compare(password, user.password);
      if (!valid) return res.status(401).send('Invalid credentials');

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
              res.cookie('lin_session', sessionToken, { httpOnly: true, secure: false, maxAge: 86400000, sameSite: 'lax' });
              res.redirect(url.toString());
            });
        });
    });
  });
});

app.post('/oauth/token', (req, res) => {
  const { code, client_id, client_secret } = req.body;
  if (!code || !client_id || !client_secret) {
    return res.status(400).json({ error: 'Missing parameters' });
  }
  db.get('SELECT * FROM oauth_clients WHERE client_id = ?', [client_id], (err, client) => {
    if (err || !client || client.client_secret !== client_secret) {
      return res.status(400).json({ error: 'Invalid client' });
    }
    db.get('SELECT * FROM oauth_codes WHERE code = ?', [code], (err, codeRow) => {
      if (err || !codeRow || codeRow.client_id !== client_id) {
        return res.status(400).json({ error: 'Invalid or expired code' });
      }
      db.run('DELETE FROM oauth_codes WHERE code = ?', [code]);
      const accessToken = uuidv4();
      const refreshToken = uuidv4();
      const now = Math.floor(Date.now() / 1000);
      db.run('INSERT INTO oauth_tokens (token, username, expires) VALUES (?, ?, ?)',
        [accessToken, codeRow.username, now + 900], () => {
          db.run('INSERT INTO refresh_tokens (token, username, expires) VALUES (?, ?, ?)',
            [refreshToken, codeRow.username, now + 604800], () => {
              res.json({ access_token: accessToken, token_type: 'Bearer', expires_in: 900, refresh_token: refreshToken });
            });
        });
    });
  });
});

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
            res.json({ access_token: newAccess, token_type: 'Bearer', expires_in: 900, refresh_token: newRefresh });
          });
      });
  });
});

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

app.listen(PORT, '0.0.0.0', () => {
  console.log(`🚀 LinAccounts API с 2FA запущен на порту ${PORT}`);
  console.log(`🌐 Веб-интерфейс: http://localhost:${PORT}/`);
  console.log('📋 Новые возможности:');
  console.log('   POST /api/change-password  - смена пароля');
  console.log('   POST /api/disable-2fa      - отключение 2FA');
});
EOF

# 3. Создаём index.html
cat > ~/linaccounts/public/index.html << 'EOF'
<!DOCTYPE html>
<html lang="ru">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>LinAccounts — веб-интерфейс</title>
  <link href="https://fonts.googleapis.com/css2?family=Roboto:wght@300;400;500;700&display=swap" rel="stylesheet">
  <style>
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      font-family: 'Roboto', Arial, sans-serif;
      background: #111;
      min-height: 100vh;
      display: flex;
      align-items: center;
      justify-content: center;
      padding: 20px;
    }
    .container {
      background: #1c1c1c;
      box-shadow: 0 2px 10px rgba(0,0,0,.8);
      width: 100%;
      max-width: 420px;
      padding: 40px 32px;
      border: 1px solid #333;
      border-radius: 4px;
    }
    .logo { text-align: center; margin-bottom: 24px; }
    .logo .lin { font-size: 34px; font-weight: 700; color: #FF6D00; }
    .logo .acc { font-size: 34px; font-weight: 700; color: #00C853; }
    .logo-sub { color: #aaa; font-size: 14px; margin-top: 4px; }
    h1 { color: #f0f0f0; font-weight: 400; font-size: 24px; margin-bottom: 4px; }
    .sub { color: #aaa; font-size: 14px; margin-bottom: 20px; }
    .form-group { margin-bottom: 16px; }
    label { display: block; color: #ccc; font-size: 13px; text-transform: uppercase; letter-spacing: .5px; margin-bottom: 4px; }
    input, select {
      width: 100%;
      padding: 10px 12px;
      font-size: 16px;
      background: #222;
      border: 1px solid #444;
      color: #f0f0f0;
      outline: none;
      border-radius: 2px;
    }
    input:focus { border-color: #FF6D00; box-shadow: 0 0 6px rgba(255,109,0,.5); }
    .checkbox-group {
      display: flex;
      align-items: center;
      gap: 10px;
      color: #ccc;
      font-size: 14px;
    }
    .checkbox-group input[type="checkbox"] {
      width: 18px;
      height: 18px;
      accent-color: #00C853;
    }
    .btn {
      width: 100%;
      padding: 12px;
      background: #FF6D00;
      color: #fff;
      border: none;
      font-size: 16px;
      font-weight: 500;
      text-transform: uppercase;
      cursor: pointer;
      transition: background .2s;
      border-radius: 2px;
      margin-top: 8px;
    }
    .btn:hover { background: #e65100; }
    .btn-secondary {
      background: #333;
      color: #ccc;
    }
    .btn-secondary:hover { background: #444; }
    .btn-danger {
      background: #d32f2f;
      color: #fff;
    }
    .btn-danger:hover { background: #b71c1c; }
    .error { color: #d93025; font-size: 13px; margin-top: 4px; display: none; }
    .success { color: #00C853; font-size: 13px; margin-top: 4px; display: none; }
    .info { color: #aaa; font-size: 13px; margin-top: 4px; }
    .switch {
      text-align: center;
      margin-top: 16px;
      color: #aaa;
      font-size: 14px;
    }
    .switch a { color: #FF6D00; text-decoration: none; cursor: pointer; }
    .switch a:hover { text-decoration: underline; }
    .hidden { display: none; }
    .profile-data { color: #ccc; font-size: 14px; margin-bottom: 8px; }
    .profile-data strong { color: #f0f0f0; }
    .qr-container { text-align: center; margin: 12px 0; }
    .qr-container img { max-width: 200px; border: 1px solid #444; border-radius: 4px; background: #fff; padding: 4px; }
    .totp-secret { color: #aaa; font-size: 13px; word-break: break-all; background: #222; padding: 8px; border-radius: 2px; border: 1px solid #333; }
    .twofa-section { margin-top: 12px; border-top: 1px solid #333; padding-top: 12px; }
    .actions { display: flex; gap: 8px; flex-wrap: wrap; margin-top: 12px; }
    .actions .btn { flex: 1; min-width: 120px; }
    .modal-overlay {
      display: none;
      position: fixed;
      top: 0; left: 0; width: 100%; height: 100%;
      background: rgba(0,0,0,0.7);
      align-items: center;
      justify-content: center;
      z-index: 1000;
    }
    .modal-overlay.active { display: flex; }
    .modal {
      background: #1c1c1c;
      padding: 30px;
      border-radius: 4px;
      max-width: 400px;
      width: 90%;
      border: 1px solid #333;
    }
    .modal h2 { color: #f0f0f0; margin-bottom: 16px; font-weight: 400; }
    .modal .form-group { margin-bottom: 12px; }
    .modal .btn { margin-top: 4px; }
    .modal .btn-secondary { background: #555; }
  </style>
</head>
<body>
<div class="container" id="app">
  <div class="logo">
    <span class="lin">Lin</span><span class="acc">Accounts</span>
    <div class="logo-sub">Управляйте своим аккаунтом</div>
  </div>

  <div id="auth-section">
    <h1 id="form-title">Войти</h1>
    <p class="sub" id="form-sub">Используйте свои учётные данные</p>

    <div id="login-form">
      <div class="form-group">
        <label for="username">Юзернейм</label>
        <input type="text" id="username" placeholder="Введите юзернейм">
      </div>
      <div class="form-group">
        <label for="password">Пароль</label>
        <input type="password" id="password" placeholder="Введите пароль">
      </div>
      <div class="form-group hidden" id="totp-group">
        <label for="totpToken">Код 2FA</label>
        <input type="text" id="totpToken" placeholder="6-значный код из приложения">
      </div>
      <div class="error" id="login-error"></div>
      <button class="btn" id="login-btn">Войти</button>
      <div class="switch">Нет аккаунта? <a id="switch-to-signup">Зарегистрироваться</a></div>
    </div>

    <div id="signup-form" class="hidden">
      <div class="form-group">
        <label for="signup-username">Юзернейм</label>
        <input type="text" id="signup-username" placeholder="Введите юзернейм">
      </div>
      <div class="form-group">
        <label for="signup-password">Пароль</label>
        <input type="password" id="signup-password" placeholder="Минимум 6 символов">
      </div>
      <div class="form-group">
        <label for="signup-first">Имя</label>
        <input type="text" id="signup-first" placeholder="Имя">
      </div>
      <div class="form-group">
        <label for="signup-last">Фамилия</label>
        <input type="text" id="signup-last" placeholder="Фамилия">
      </div>
      <div class="form-group checkbox-group">
        <input type="checkbox" id="signup-2fa">
        <label for="signup-2fa" style="text-transform:none; letter-spacing:0;">Включить двухфакторную аутентификацию</label>
      </div>
      <div class="error" id="signup-error"></div>
      <div class="success" id="signup-success"></div>
      <button class="btn" id="signup-btn">Создать аккаунт</button>
      <div class="switch">Уже есть аккаунт? <a id="switch-to-login">Войти</a></div>
    </div>
  </div>

  <div id="profile-section" class="hidden">
    <h1>Профиль</h1>
    <div class="profile-data"><strong>Юзернейм:</strong> <span id="profile-username"></span></div>
    <div class="profile-data"><strong>Имя:</strong> <span id="profile-first"></span></div>
    <div class="profile-data"><strong>Фамилия:</strong> <span id="profile-last"></span></div>
    <div class="profile-data"><strong>Дата регистрации:</strong> <span id="profile-created"></span></div>
    <div class="profile-data"><strong>2FA:</strong> <span id="profile-2fa-status"></span></div>

    <div class="actions">
      <button class="btn btn-secondary" id="change-password-btn">Сменить пароль</button>
      <button class="btn btn-danger" id="disable-2fa-btn">Отключить 2FA</button>
    </div>

    <div class="twofa-section" id="twofa-section">
      <h3 style="color:#f0f0f0; font-weight:400; margin-bottom:8px;">Управление 2FA</h3>
      <div id="twofa-info">
        <p style="color:#aaa; font-size:14px;">Двухфакторная аутентификация отключена.</p>
        <button class="btn btn-secondary" id="enable-2fa-btn" style="margin-top:8px;">Включить 2FA</button>
      </div>
      <div id="twofa-enable" class="hidden">
        <p style="color:#aaa; font-size:14px;">Отсканируйте QR-код в Google Authenticator или аналогичном приложении.</p>
        <div class="qr-container" id="qr-container"></div>
        <div class="totp-secret" id="totp-secret-display"></div>
        <button class="btn btn-secondary" id="twofa-done-btn" style="margin-top:8px;">Готово (2FA включена)</button>
      </div>
    </div>

    <button class="btn btn-secondary" id="logout-btn" style="margin-top:16px;">Выйти</button>
  </div>
</div>

<!-- Модалка для смены пароля -->
<div class="modal-overlay" id="change-password-modal">
  <div class="modal">
    <h2>Смена пароля</h2>
    <div class="form-group">
      <label>Старый пароль</label>
      <input type="password" id="old-password" placeholder="Введите старый пароль">
    </div>
    <div class="form-group">
      <label>Новый пароль</label>
      <input type="password" id="new-password" placeholder="Минимум 6 символов">
    </div>
    <div class="error" id="change-password-error"></div>
    <div class="success" id="change-password-success"></div>
    <div style="display:flex; gap:8px; margin-top:8px;">
      <button class="btn" id="change-password-confirm">Сменить</button>
      <button class="btn btn-secondary" id="change-password-cancel">Отмена</button>
    </div>
  </div>
</div>

<script>
  const API_BASE = window.location.origin;
  const authSection = document.getElementById('auth-section');
  const profileSection = document.getElementById('profile-section');
  const loginForm = document.getElementById('login-form');
  const signupForm = document.getElementById('signup-form');
  const formTitle = document.getElementById('form-title');
  const formSub = document.getElementById('form-sub');
  const loginUsername = document.getElementById('username');
  const loginPassword = document.getElementById('password');
  const totpToken = document.getElementById('totpToken');
  const totpGroup = document.getElementById('totp-group');
  const loginError = document.getElementById('login-error');
  const loginBtn = document.getElementById('login-btn');
  const signupUsername = document.getElementById('signup-username');
  const signupPassword = document.getElementById('signup-password');
  const signupFirst = document.getElementById('signup-first');
  const signupLast = document.getElementById('signup-last');
  const signup2fa = document.getElementById('signup-2fa');
  const signupError = document.getElementById('signup-error');
  const signupSuccess = document.getElementById('signup-success');
  const signupBtn = document.getElementById('signup-btn');
  const switchToSignup = document.getElementById('switch-to-signup');
  const switchToLogin = document.getElementById('switch-to-login');
  const profileUsername = document.getElementById('profile-username');
  const profileFirst = document.getElementById('profile-first');
  const profileLast = document.getElementById('profile-last');
  const profileCreated = document.getElementById('profile-created');
  const profile2faStatus = document.getElementById('profile-2fa-status');
  const logoutBtn = document.getElementById('logout-btn');
  const enable2faBtn = document.getElementById('enable-2fa-btn');
  const twofaInfo = document.getElementById('twofa-info');
  const twofaEnable = document.getElementById('twofa-enable');
  const qrContainer = document.getElementById('qr-container');
  const totpSecretDisplay = document.getElementById('totp-secret-display');
  const twofaDoneBtn = document.getElementById('twofa-done-btn');
  const disable2faBtn = document.getElementById('disable-2fa-btn');
  const changePasswordBtn = document.getElementById('change-password-btn');
  const changePwdModal = document.getElementById('change-password-modal');
  const oldPwdInput = document.getElementById('old-password');
  const newPwdInput = document.getElementById('new-password');
  const changePwdError = document.getElementById('change-password-error');
  const changePwdSuccess = document.getElementById('change-password-success');
  const changePwdConfirm = document.getElementById('change-password-confirm');
  const changePwdCancel = document.getElementById('change-password-cancel');
  let token = null;

  function showLogin() {
    loginForm.classList.remove('hidden');
    signupForm.classList.add('hidden');
    formTitle.textContent = 'Войти';
    formSub.textContent = 'Используйте свои учётные данные';
    totpGroup.classList.add('hidden');
    loginError.style.display = 'none';
    loginError.textContent = '';
    totpToken.value = '';
  }

  function showSignup() {
    loginForm.classList.add('hidden');
    signupForm.classList.remove('hidden');
    formTitle.textContent = 'Регистрация';
    formSub.textContent = 'Создайте аккаунт LinAccounts';
    signupError.style.display = 'none';
    signupSuccess.style.display = 'none';
  }

  switchToSignup.addEventListener('click', showSignup);
  switchToLogin.addEventListener('click', showLogin);

  signupBtn.addEventListener('click', async () => {
    const username = signupUsername.value.trim();
    const password = signupPassword.value.trim();
    const firstName = signupFirst.value.trim();
    const lastName = signupLast.value.trim();
    const enable2fa = signup2fa.checked;
    signupError.style.display = 'none';
    signupSuccess.style.display = 'none';
    if (!username || !password) {
      signupError.textContent = 'Юзернейм и пароль обязательны.';
      signupError.style.display = 'block';
      return;
    }
    if (password.length < 6) {
      signupError.textContent = 'Пароль должен быть не менее 6 символов.';
      signupError.style.display = 'block';
      return;
    }
    try {
      const resp = await fetch(`${API_BASE}/api/signup`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ username, password, firstName, lastName, enable2fa })
      });
      const data = await resp.json();
      if (resp.status === 201) {
        signupSuccess.textContent = '✅ Аккаунт создан! Теперь войдите.';
        signupSuccess.style.display = 'block';
        setTimeout(() => {
          loginUsername.value = username;
          showLogin();
        }, 2000);
      } else {
        signupError.textContent = data.error || 'Ошибка регистрации.';
        signupError.style.display = 'block';
      }
    } catch (e) {
      signupError.textContent = 'Ошибка сети.';
      signupError.style.display = 'block';
    }
  });

  loginBtn.addEventListener('click', async () => {
    const username = loginUsername.value.trim();
    const password = loginPassword.value.trim();
    const totp = totpToken.value.trim();
    loginError.style.display = 'none';
    loginError.textContent = '';
    if (!username || !password) {
      loginError.textContent = 'Введите юзернейм и пароль.';
      loginError.style.display = 'block';
      return;
    }
    try {
      const payload = { username, password };
      if (totp) payload.totpToken = totp;
      const resp = await fetch(`${API_BASE}/api/login`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload)
      });
      const data = await resp.json();
      if (resp.status === 200) {
        token = data.token;
        localStorage.setItem('lin_token', token);
        await loadProfile();
      } else if (resp.status === 403 && data.requires2fa) {
        totpGroup.classList.remove('hidden');
        loginError.textContent = 'Требуется код 2FA. Введите его.';
        loginError.style.display = 'block';
        totpToken.focus();
      } else {
        loginError.textContent = data.error || 'Ошибка входа.';
        loginError.style.display = 'block';
      }
    } catch (e) {
      loginError.textContent = 'Ошибка сети.';
      loginError.style.display = 'block';
    }
  });

  async function loadProfile() {
    const stored = localStorage.getItem('lin_token');
    if (stored) token = stored;
    if (!token) return;
    try {
      const resp = await fetch(`${API_BASE}/api/me`, {
        headers: { 'Authorization': `Bearer ${token}` }
      });
      if (resp.status === 200) {
        const user = await resp.json();
        profileUsername.textContent = user.username;
        profileFirst.textContent = user.firstName || '—';
        profileLast.textContent = user.lastName || '—';
        profileCreated.textContent = new Date(user.created * 1000).toLocaleString();
        profile2faStatus.textContent = user.has2fa ? '✅ Включена' : '❌ Выключена';
        authSection.classList.add('hidden');
        profileSection.classList.remove('hidden');
        updateTwofaSection(user.has2fa);
        disable2faBtn.style.display = user.has2fa ? 'block' : 'none';
      } else {
        localStorage.removeItem('lin_token');
        token = null;
        authSection.classList.remove('hidden');
        profileSection.classList.add('hidden');
      }
    } catch (e) {
      console.error('Error loading profile:', e);
    }
  }

  function updateTwofaSection(has2fa) {
    if (has2fa) {
      twofaInfo.classList.add('hidden');
      twofaEnable.classList.add('hidden');
      const statusEl = document.querySelector('#twofa-section p');
      if (statusEl) statusEl.textContent = '2FA уже активирована.';
      enable2faBtn.style.display = 'none';
    } else {
      twofaInfo.classList.remove('hidden');
      twofaEnable.classList.add('hidden');
      enable2faBtn.style.display = 'block';
    }
  }

  enable2faBtn.addEventListener('click', async () => {
    const username = profileUsername.textContent;
    const password = prompt('Введите пароль для подтверждения включения 2FA:');
    if (!password) return;
    try {
      const resp = await fetch(`${API_BASE}/api/enable-2fa`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${token}` },
        body: JSON.stringify({ username, password })
      });
      const data = await resp.json();
      if (resp.status === 200) {
        qrContainer.innerHTML = data.qr ? `<img src="${data.qr}" alt="QR-код для 2FA">` : '';
        totpSecretDisplay.textContent = `Секрет: ${data.secret}`;
        twofaInfo.classList.add('hidden');
        twofaEnable.classList.remove('hidden');
      } else {
        alert(data.error || 'Ошибка включения 2FA');
      }
    } catch (e) {
      alert('Ошибка сети');
    }
  });

  twofaDoneBtn.addEventListener('click', async () => {
    await loadProfile();
    alert('2FA включена! Теперь при входе потребуется код.');
  });

  disable2faBtn.addEventListener('click', async () => {
    const username = profileUsername.textContent;
    const password = prompt('Введите пароль для отключения 2FA:');
    if (!password) return;
    try {
      const resp = await fetch(`${API_BASE}/api/disable-2fa`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${token}` },
        body: JSON.stringify({ username, password })
      });
      const data = await resp.json();
      if (resp.status === 200) {
        alert('2FA отключена.');
        await loadProfile();
      } else {
        alert(data.error || 'Ошибка отключения 2FA');
      }
    } catch (e) {
      alert('Ошибка сети');
    }
  });

  changePasswordBtn.addEventListener('click', () => {
    changePwdModal.classList.add('active');
    oldPwdInput.value = '';
    newPwdInput.value = '';
    changePwdError.style.display = 'none';
    changePwdSuccess.style.display = 'none';
  });

  changePwdCancel.addEventListener('click', () => {
    changePwdModal.classList.remove('active');
  });

  changePwdConfirm.addEventListener('click', async () => {
    const oldPwd = oldPwdInput.value.trim();
    const newPwd = newPwdInput.value.trim();
    const username = profileUsername.textContent;
    changePwdError.style.display = 'none';
    changePwdSuccess.style.display = 'none';
    if (!oldPwd || !newPwd) {
      changePwdError.textContent = 'Заполните оба поля.';
      changePwdError.style.display = 'block';
      return;
    }
    if (newPwd.length < 6) {
      changePwdError.textContent = 'Новый пароль должен быть минимум 6 символов.';
      changePwdError.style.display = 'block';
      return;
    }
    try {
      const resp = await fetch(`${API_BASE}/api/change-password`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${token}` },
        body: JSON.stringify({ username, oldPassword: oldPwd, newPassword: newPwd })
      });
      const data = await resp.json();
      if (resp.status === 200) {
        changePwdSuccess.textContent = '✅ Пароль изменён.';
        changePwdSuccess.style.display = 'block';
        setTimeout(() => changePwdModal.classList.remove('active'), 1500);
      } else {
        changePwdError.textContent = data.error || 'Ошибка смены пароля.';
        changePwdError.style.display = 'block';
      }
    } catch (e) {
      changePwdError.textContent = 'Ошибка сети.';
      changePwdError.style.display = 'block';
    }
  });

  logoutBtn.addEventListener('click', () => {
    localStorage.removeItem('lin_token');
    token = null;
    authSection.classList.remove('hidden');
    profileSection.classList.add('hidden');
    showLogin();
    loginPassword.value = '';
    loginUsername.value = '';
    totpToken.value = '';
    totpGroup.classList.add('hidden');
    loginError.style.display = 'none';
  });

  document.querySelectorAll('input').forEach(input => {
    input.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') {
        const form = input.closest('form') || input.closest('#login-form') || input.closest('#signup-form');
        if (form) {
          const btn = form.querySelector('.btn');
          if (btn) btn.click();
        }
      }
    });
  });

  (function init() {
    showLogin();
    const storedToken = localStorage.getItem('lin_token');
    if (storedToken) {
      token = storedToken;
      loadProfile();
    }
  })();
</script>
</body>
</html>
EOF

echo "✅ Файлы созданы."

# 4. Устанавливаем зависимости
cd ~/linaccounts
echo "📦 Устанавливаем зависимости..."
npm install express sqlite3 bcrypt cors speakeasy qrcode

# 5. Проверяем и устанавливаем PM2
if ! command -v pm2 &> /dev/null; then
  echo "⚠️ PM2 не установлен. Устанавливаем..."
  sudo npm install -g pm2
fi

# 6. Запускаем через PM2
echo "🚀 Запускаем сервер через PM2..."
pm2 start server.js --name linaccounts
pm2 save
pm2 startup | tail -n 1

echo "✅ Сервер запущен!"
echo "🌐 Откройте в браузере: http://$(hostname -I | awk '{print $1}'):9001/"
echo "📋 Для управления используйте: pm2 [start|stop|restart|logs] linaccounts"
EOF