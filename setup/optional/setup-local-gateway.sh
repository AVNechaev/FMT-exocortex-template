#!/bin/bash
# Локальный шлюз координации агентов (iwe-local-gateway) — установка
#
# ПРАВИЛО ДОСТАВКИ MCP-МОДУЛЕЙ:
#   модуль работает с ЛОКАЛЬНЫМ диском пилота  -> локальная доставка (этот скрипт)
#   модуль работает с облачными данными        -> mcp.aisystant.com, не клонируем
# iwe-local-gateway координирует file-locks на диске -> облачным быть не может.
#
# FMT-ONLY АРТЕФАКТ: этот файл не идёт через авторский конвейер синхронизации
# platform-space (template-sync.sh) — тот конвейер переписал бы GATEWAY_REPO_URL
# на GitHub-логин случайного пользователя и вырезал бы строки с DS-MCP. Правки —
# прямо в этом репозитории.
#
# Usage:
#   bash setup/optional/setup-local-gateway.sh
#
set -euo pipefail

# Upstream-константы. URL умышленно указывает на репозиторий автора платформы,
# а не на форк пользователя — это общая зависимость всех инсталляций.
GATEWAY_REPO_URL="https://github.com/TserenTserenov/iwe-local-gateway.git"
GATEWAY_REF="v0.1.0"   # бамп только вместе со строкой в CHANGELOG шаблона

WORKSPACE_DIR="${IWE_WORKSPACE:-$HOME/IWE}"
GATEWAY_DIR="$WORKSPACE_DIR/DS-MCP/local-gateway"
MCP_JSON="$WORKSPACE_DIR/.mcp.json"
AGENT_ID="${IWE_AGENT_ID:-claude-code}"
SOCK="${IWE_GATEWAY_SOCKET:-$HOME/.iwe/gateway.sock}"

echo "========================================"
echo "  Локальный шлюз координации агентов"
echo "========================================"
echo ""
echo "Workspace: $WORKSPACE_DIR"
echo "Версия: $GATEWAY_REF"
echo ""

command -v node >/dev/null 2>&1 || { echo "ОШИБКА: нужен Node.js >= 18."; exit 1; }
command -v git  >/dev/null 2>&1 || { echo "ОШИБКА: нужен git."; exit 1; }

# --- 1. Клон / обновление до пина ---
NEEDS_BUILD=false
if [ ! -d "$GATEWAY_DIR/.git" ]; then
    mkdir -p "$(dirname "$GATEWAY_DIR")"
    # git может напечатать "refs/tags/... is not a commit!" для annotated-тегов —
    # безвредный шум git, клон при этом разрешается на правильный коммит.
    git clone --branch "$GATEWAY_REF" "$GATEWAY_REPO_URL" "$GATEWAY_DIR"
    echo "  ✓ Закреплено на $(git -C "$GATEWAY_DIR" rev-parse --short HEAD) ($GATEWAY_REF)"
    NEEDS_BUILD=true
else
    # Guard вместо rollback-гейта template-sync.sh: там источник и приёмник не
    # связаны через VCS, здесь связаны через origin — git сам защищает чужую
    # работу. Наша обязанность — не делать checkout поверх правок молча.
    if [ -n "$(git -C "$GATEWAY_DIR" status --porcelain)" ]; then
        echo "СТОП: в $GATEWAY_DIR есть незакоммиченные правки."
        echo "Закоммитьте или отмените их, затем перезапустите скрипт."
        exit 1
    fi

    git -C "$GATEWAY_DIR" fetch --tags origin
    LOCAL_HEAD=$(git -C "$GATEWAY_DIR" rev-parse HEAD)
    PIN_HEAD=$(git -C "$GATEWAY_DIR" rev-parse "$GATEWAY_REF^{commit}")

    if [ "$LOCAL_HEAD" != "$PIN_HEAD" ]; then
        if ! git -C "$GATEWAY_DIR" merge-base --is-ancestor "$LOCAL_HEAD" "$PIN_HEAD"; then
            echo "СТОП: в $GATEWAY_DIR есть свои коммиты, расходящиеся с $GATEWAY_REF."
            echo "Перенесите их в отдельную ветку (git branch my-changes) и перезапустите."
            exit 1
        fi
        git -C "$GATEWAY_DIR" checkout --detach "$GATEWAY_REF"
        NEEDS_BUILD=true
    elif [ ! -f "$GATEWAY_DIR/dist/proxy.js" ]; then
        NEEDS_BUILD=true
    fi
fi

# --- 2. Воспроизводимая сборка ---
if $NEEDS_BUILD; then
    echo "Собираю шлюз ($GATEWAY_REF)..."
    ( cd "$GATEWAY_DIR" && npm ci && npm run build )
    echo "  ✓ Собран."
fi

# --- 3. .mcp.json: не патчить программно, только показать блок для вставки ---
# Прецедент этого репозитория (setup-calendar.sh) — существующий .mcp.json
# не переписывается автоматически, чтобы не сломать формат чужих правок.
# env.IWE_AGENT_ID обязателен: без него proxy.ts подставляет случайный
# unknown-agent-<uuid> при каждом перезапуске — координация между агентами
# молча ломается (см. AGENT-VENDOR-SETUP.md).
if [ -f "$MCP_JSON" ] && grep -q '"iwe-local-gateway"' "$MCP_JSON" 2>/dev/null; then
    echo "  ✓ iwe-local-gateway уже в .mcp.json"
else
    echo ""
    echo "  ⚠ Добавьте iwe-local-gateway в $MCP_JSON вручную:"
    echo '    "iwe-local-gateway": {'
    echo '      "command": "node",'
    echo "      \"args\": [\"$GATEWAY_DIR/dist/proxy.js\"],"
    echo '      "env": {'
    echo "        \"IWE_AGENT_ID\": \"$AGENT_ID\""
    echo '      }'
    echo '    }'
    echo ""
fi

# --- 4. Демон: без него proxy падает ("Start daemon first") ---
SOCK_DIR="$(dirname "$SOCK")"
DAEMON_LOG="$SOCK_DIR/gateway-daemon.log"
mkdir -p "$SOCK_DIR"
if [ ! -S "$SOCK" ]; then
    echo "Запускаю демон..."
    IWE_GATEWAY_SOCKET="$SOCK" nohup node "$GATEWAY_DIR/dist/daemon.js" >"$DAEMON_LOG" 2>&1 &
    for _ in $(seq 1 50); do
        [ -S "$SOCK" ] && break
        sleep 0.1
    done
    if [ -S "$SOCK" ]; then
        echo "  ✓ Демон запущен (сокет: $SOCK)."
    else
        echo "  ✗ Демон не поднял сокет за 5 секунд. Проверьте: $DAEMON_LOG"
        exit 1
    fi
elif $NEEDS_BUILD; then
    echo ""
    echo "  ⚠ Шлюз обновлён до $GATEWAY_REF, но демон ещё старой версии."
    echo "    Перезапустите его, когда gateway_status покажет пустой список блокировок:"
    echo "    pkill -f 'node.*local-gateway.*daemon.js' && bash $0"
else
    echo "  ✓ Демон уже работает (сокет: $SOCK)."
fi

echo ""
echo "========================================"
echo "  Готово: iwe-local-gateway $GATEWAY_REF"
echo "========================================"
echo ""
echo "Проверка:"
echo "  1. Убедитесь, что запись iwe-local-gateway есть в .mcp.json (шаг 3 выше)"
echo "  2. Перезапустите агента (чтобы MCP подхватился)"
echo "  3. Вызовите gateway_status — должен вернуть пустой список locks"
