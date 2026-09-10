cat > ~/linplus/setup-pm2.sh << 'EOF'
#!/bin/bash
# ============================================================
#  Настройка автозапуска Lin+ через PM2
#  Хост: 195.43.142.215:9002
# ============================================================

set -e

INSTALL_DIR="$HOME/linplus"
APP_NAME="linplus"
PORT=9002
HOST="195.43.142.215"

echo "🚀 Настройка Lin+ для работы 24/7 через PM2"
echo "🌐 Адрес: http://$HOST:$PORT"
echo ""

if [ ! -d "$INSTALL_DIR" ]; then
    echo "❌ Директория $INSTALL_DIR не найдена."
    echo "   Сначала запустите установку: bash ~/install-linplus.sh"
    exit 1
fi

cd "$INSTALL_DIR"

if [ ! -f "server.js" ]; then
    echo "❌ Файл server.js не найден в $INSTALL_DIR"
    exit 1
fi

echo "✅ Проект найден: $INSTALL_DIR"
echo ""

if ! command -v node >/dev/null 2>&1; then
    echo "❌ Node.js не установлен."
    exit 1
fi

if ! command -v npm >/dev/null 2>&1; then
    echo "❌ npm не установлен."
    exit 1
fi

echo "✅ Node.js: $(node -v)"
echo "✅ npm:     $(npm -v)"
echo ""

if [ ! -d "node_modules" ]; then
    echo "📦 Зависимости не найдены. Устанавливаем..."
    npm install express express-session axios
    echo ""
fi

echo "✅ Зависимости на месте"
echo ""

if ! command -v pm2 >/dev/null 2>&1; then
    echo "📦 Установка PM2..."
    npm install -g pm2
    echo ""
fi

echo "✅ PM2: $(pm2 -v)"
echo ""

if pm2 describe "$APP_NAME" > /dev/null 2>&1; then
    echo "♻️  Удаляем старый процесс $APP_NAME..."
    pm2 delete "$APP_NAME"
fi

pkill -f "node server.js" 2>/dev/null || true

echo ""

echo "🚀 Запуск Lin+ через PM2..."
pm2 start server.js \
    --name "$APP_NAME" \
    --watch \
    --ignore-watch "node_modules data" \
    --max-memory-restart 300M \
    --restart-delay 3000 \
    --exp-backoff-restart-delay 100

echo ""

echo "💾 Сохранение списка процессов..."
pm2 save
echo ""

echo "⚙️  Настройка автозапуска при загрузке системы..."
echo ""
echo "⚠️  ВАЖНО: Сейчас будет выведена команда для копирования."
echo "   Скопируйте её и выполните с sudo."
echo ""
pm2 startup || true

echo ""
echo "============================================================"
echo "🎉 Lin+ настроен для работы 24/7 через PM2!"
echo "============================================================"
echo ""
echo "📁 Проект:  $INSTALL_DIR"
echo "🌐 Адрес:   http://$HOST:$PORT"
echo "🔗 Callback: http://$HOST:$PORT/callback"
echo "🏷️  Имя:     $APP_NAME"
echo ""
echo "📋 Полезные команды:"
echo ""
echo "   pm2 status              — статус всех процессов"
echo "   pm2 logs $APP_NAME      — логи в реальном времени"
echo "   pm2 restart $APP_NAME   — перезапустить"
echo "   pm2 stop $APP_NAME      — остановить"
echo "   pm2 delete $APP_NAME    — удалить из PM2"
echo "   pm2 monit               — мониторинг в реальном времени"
echo ""
EOF

chmod +x ~/linplus/setup-pm2.sh