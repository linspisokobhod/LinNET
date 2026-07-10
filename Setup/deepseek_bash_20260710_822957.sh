#!/bin/bash

# ============================================================
#  Установка и запуск прокси-сервера Node.js
#  - устанавливает Node.js 20 LTS (через NodeSource)
#  - создаёт proxy.js с корректной подстановкой Host
#  - запускает прокси в фоне
#  - показывает, как открыть порт 8080 вручную
# ============================================================

set -e

# ---------- Цвета ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ---------- Переменные ----------
PROXY_FILE="proxy.js"
PROXY_PORT=8080
NODE_VERSION="20"

print_status() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warn()   { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error()  { echo -e "${RED}[ERROR]${NC} $1"; }

# Проверка занятости порта
check_port() {
    if ss -lptn | grep -q ":${PROXY_PORT} "; then
        print_error "Порт ${PROXY_PORT} уже занят."
        read -p "Остановить существующий процесс и перезапустить? (y/N) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            PID=$(ss -lptn | grep ":${PROXY_PORT} " | awk '{print $6}' | sed 's/.*pid=\([0-9]*\).*/\1/')
            if [ -n "$PID" ]; then
                kill -9 "$PID"
                print_status "Процесс с PID $PID остановлен."
                sleep 1
            else
                print_error "Не удалось определить PID, попробуйте: sudo fuser -k ${PROXY_PORT}/tcp"
                exit 1
            fi
        else
            exit 1
        fi
    fi
}

# Установка Node.js
install_node() {
    print_status "Проверка установки Node.js..."
    if command -v node &> /dev/null; then
        INSTALLED_VERSION=$(node -v | cut -d'v' -f2 | cut -d'.' -f1)
        if [ "$INSTALLED_VERSION" -ge 18 ]; then
            print_status "Node.js версии $INSTALLED_VERSION уже установлен."
            return 0
        else
            print_warn "Установлена старая версия ($INSTALLED_VERSION). Будет обновлена до ${NODE_VERSION} LTS."
        fi
    else
        print_status "Node.js не найден. Устанавливаю..."
    fi

    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VER=$VERSION_ID
    else
        print_error "Не удалось определить ОС."
        exit 1
    fi

    print_status "Установка Node.js ${NODE_VERSION} LTS через NodeSource..."
    case $OS in
        ubuntu|debian)
            curl -fsSL "https://deb.nodesource.com/setup_${NODE_VERSION}.x" | sudo bash -
            sudo apt install -y nodejs
            ;;
        rhel|centos|fedora|rocky|almalinux)
            curl -fsSL "https://rpm.nodesource.com/setup_${NODE_VERSION}.x" | sudo bash -
            sudo yum install -y nodejs
            ;;
        *)
            print_error "Дистрибутив $OS не поддерживается автоматической установкой."
            print_error "Установите Node.js вручную (версия >= 18) и запустите скрипт заново."
            exit 1
            ;;
    esac

    if command -v node &> /dev/null; then
        print_status "Node.js успешно установлен: $(node -v)"
    else
        print_error "Не удалось установить Node.js."
        exit 1
    fi
}

# Создание proxy.js (с исправленным Host)
create_proxy_file() {
    print_status "Создание файла $PROXY_FILE с исправленным заголовком Host..."
    cat > "$PROXY_FILE" << 'EOF'
const http = require('http');
const https = require('https');
const net = require('net');
const url = require('url');
const fs = require('fs');

// =====================  КОНФИГУРАЦИЯ  =====================
const PROXY_PORT = 8080;
const RULES_URL = 'https://raw.githubusercontent.com/linspisokobhod/LinNET/refs/heads/main/dns.lin';
const RULES_FILE = './dns_rules_cache.txt';
const UPDATE_INTERVAL = 5 * 60 * 1000; // 5 минут

// =====================  ЗАГРУЗКА ПРАВИЛ  =====================
let rewriteRules = {};

function parseRules(text) {
    const rules = {};
    const parts = text.trim().split(/\s+/);
    for (let i = 0; i < parts.length - 1; i += 2) {
        const src = parts[i];
        const dst = parts[i + 1];
        if (src && dst) {
            rules[src] = dst;
        }
    }
    return rules;
}

async function fetchRules() {
    try {
        const response = await fetch(RULES_URL);
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        const text = await response.text();
        const newRules = parseRules(text);
        fs.writeFileSync(RULES_FILE, text, 'utf8');
        rewriteRules = newRules;
        console.log(`[${new Date().toISOString()}] Rules updated: ${Object.keys(newRules).length} entries`);
    } catch (err) {
        console.error(`[${new Date().toISOString()}] Failed to fetch rules:`, err.message);
        if (fs.existsSync(RULES_FILE)) {
            try {
                const cached = fs.readFileSync(RULES_FILE, 'utf8');
                rewriteRules = parseRules(cached);
                console.log(`[${new Date().toISOString()}] Loaded ${Object.keys(rewriteRules).length} rules from cache`);
            } catch (e) {
                console.error('Failed to load cache:', e.message);
            }
        }
    }
}

function applyRewrite(hostname) {
    if (rewriteRules[hostname]) {
        const newHost = rewriteRules[hostname];
        console.log(`Rewrite: ${hostname} -> ${newHost}`);
        return { host: newHost, rewritten: true };
    }
    return { host: hostname, rewritten: false };
}

// =====================  HTTP-СЕРВЕР  =====================
const server = http.createServer((req, res) => {
    let targetUrl;
    try {
        targetUrl = new URL(req.url);
    } catch (e) {
        res.statusCode = 400;
        res.end('Invalid URL');
        return;
    }

    const originalHost = targetUrl.hostname;
    const result = applyRewrite(originalHost);

    if (result.rewritten) {
        const newUrl = new URL(req.url);
        newUrl.hostname = result.host;
        proxyRequest(newUrl.toString(), req, res);
    } else {
        proxyRequest(req.url, req, res);
    }
});

// =====================  ФУНКЦИЯ ПРОКСИРОВАНИЯ (С ИСПРАВЛЕННЫМ HOST)  =====================
function proxyRequest(targetUrl, req, res) {
    const parsed = new URL(targetUrl);
    const options = {
        hostname: parsed.hostname,
        port: parsed.port || (parsed.protocol === 'https:' ? 443 : 80),
        path: parsed.pathname + parsed.search,
        method: req.method,
        headers: req.headers,
    };
    delete options.headers['proxy-connection'];
    delete options.headers['proxy-authorization'];
    // ✅ ИСПРАВЛЕНИЕ: устанавливаем правильный Host
    options.headers.host = parsed.hostname;

    const protocol = parsed.protocol === 'https:' ? https : http;

    const proxyReq = protocol.request(options, (proxyRes) => {
        res.writeHead(proxyRes.statusCode, proxyRes.headers);
        proxyRes.pipe(res);
    });

    proxyReq.on('error', (err) => {
        console.error('Proxy error:', err.message);
        res.statusCode = 502;
        res.end('Bad Gateway');
    });

    req.pipe(proxyReq);
}

// =====================  ОБРАБОТКА CONNECT (HTTPS)  =====================
server.on('connect', (req, clientSocket, head) => {
    const { hostname, port } = new URL(`http://${req.url}`);
    const result = applyRewrite(hostname);

    const targetHost = result.rewritten ? result.host : hostname;
    const targetPort = port || 443;

    const serverSocket = net.connect(targetPort, targetHost, () => {
        clientSocket.write('HTTP/1.1 200 Connection Established\r\n\r\n');
        serverSocket.write(head);
        serverSocket.pipe(clientSocket);
        clientSocket.pipe(serverSocket);
    });

    serverSocket.on('error', (err) => {
        console.error('CONNECT error:', err.message);
        clientSocket.end('HTTP/1.1 502 Bad Gateway\r\n\r\n');
    });
});

// =====================  ЗАПУСК  =====================
async function start() {
    await fetchRules();
    setInterval(fetchRules, UPDATE_INTERVAL);

    server.listen(PROXY_PORT, '0.0.0.0', () => {
        console.log(`Forward proxy running on port ${PROXY_PORT}`);
        console.log(`Loaded ${Object.keys(rewriteRules).length} rewrite rules`);
    });
}

start().catch(console.error);
EOF

    if [ -f "$PROXY_FILE" ]; then
        print_status "Файл $PROXY_FILE создан."
    else
        print_error "Не удалось создать $PROXY_FILE."
        exit 1
    fi
}

# Запуск прокси
run_proxy() {
    print_status "Запуск прокси-сервера..."
    check_port

    LOG_FILE="proxy.log"
    nohup node "$PROXY_FILE" > "$LOG_FILE" 2>&1 &
    PID=$!
    sleep 2
    if kill -0 $PID 2>/dev/null; then
        print_status "Прокси запущен с PID $PID"
        print_status "Логи пишутся в $LOG_FILE"
        echo "Для остановки: kill $PID"
    else
        print_error "Не удалось запустить прокси. Проверьте лог: $LOG_FILE"
        exit 1
    fi
}

# Настройка systemd
setup_systemd() {
    read -p "Настроить автозапуск через systemd? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        SERVICE_NAME="proxy-lin"
        SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
        WORK_DIR=$(pwd)
        sudo bash -c "cat > $SERVICE_FILE" <<EOF
[Unit]
Description=LinNET Proxy
After=network.target

[Service]
ExecStart=$(which node) $WORK_DIR/$PROXY_FILE
WorkingDirectory=$WORK_DIR
Restart=always
User=$(whoami)
Group=$(id -gn)

[Install]
WantedBy=multi-user.target
EOF
        sudo systemctl daemon-reload
        sudo systemctl enable "$SERVICE_NAME"
        sudo systemctl start "$SERVICE_NAME"
        print_status "Systemd-сервис $SERVICE_NAME настроен и запущен."
        echo "Команды управления:"
        echo "  sudo systemctl start $SERVICE_NAME"
        echo "  sudo systemctl stop $SERVICE_NAME"
        echo "  sudo systemctl status $SERVICE_NAME"
    fi
}

# ---------- Основной процесс ----------
main() {
    print_status "Начинаем установку прокси-сервера LinNET..."
    install_node
    create_proxy_file
    run_proxy
    setup_systemd

    print_status "Готово! Прокси работает на порту $PROXY_PORT."
    echo ""
    echo "============================================================"
    echo "  ВАЖНО: Откройте порт $PROXY_PORT в файерволе,"
    echo "  чтобы прокси был доступен извне (если нужно)."
    echo ""
    echo "  Для UFW (Ubuntu/Debian):"
    echo "    sudo ufw allow $PROXY_PORT/tcp"
    echo ""
    echo "  Для firewalld (CentOS/RHEL/Fedora):"
    echo "    sudo firewall-cmd --permanent --add-port=$PROXY_PORT/tcp"
    echo "    sudo firewall-cmd --reload"
    echo ""
    echo "  Для iptables (старые системы):"
    echo "    sudo iptables -A INPUT -p tcp --dport $PROXY_PORT -j ACCEPT"
    echo "    (и сохраните правила)"
    echo "============================================================"
    echo ""
    echo "Настройте браузер на использование прокси:"
    echo "  IP: $(hostname -I | awk '{print $1}')"
    echo "  Порт: $PROXY_PORT"
}

main