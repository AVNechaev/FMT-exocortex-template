#!/usr/bin/env bash
# routing: utility  deterministic=true
# napkin-illustrate.sh — текст → napkin.ai API → SVG-иллюстрация
#
# Статус: экспериментальный (WP-511-adjacent, 06.08.2026). IntegrationGate
# (DP.SC/DP.ROLE) ещё не формализован — промотирован по прямому поручению
# пилота до обкатки. Интерфейс может измениться.
#
# Требует: ~/.secrets/napkin_api_key (см. ~/.secrets/add-secret.sh)
#
# Использование:
#   bash napkin-illustrate.sh "<текст для визуализации>" <путь-к-выходному.svg>
#
# Пример:
#   bash napkin-illustrate.sh "Объект и роль — разные срезы одного и того же" ./assets/D-077.svg

set -euo pipefail

if [ $# -ne 2 ]; then
  echo "Использование: $0 \"<текст>\" <выходной-файл.svg>" >&2
  exit 1
fi

TEXT="$1"
OUT="$2"

KEY_FILE="$HOME/.secrets/napkin_api_key"
if [ ! -f "$KEY_FILE" ]; then
  echo "Нет файла ключа: $KEY_FILE (см. bash ~/.secrets/add-secret.sh napkin_api_key)" >&2
  exit 1
fi
KEY=$(cat "$KEY_FILE")

create_resp=$(curl -s -X POST https://api.napkin.ai/v1/visual \
  -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  -d "$(python3 -c "import json,sys; print(json.dumps({'format':'svg','language':'ru-RU','content':sys.argv[1]}))" "$TEXT")")

req_id=$(echo "$create_resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))")
if [ -z "$req_id" ]; then
  echo "Ошибка создания запроса: $create_resp" >&2
  exit 1
fi
echo "Request ID: $req_id"

status=""
for i in $(seq 1 20); do
  status_resp=$(curl -s "https://api.napkin.ai/v1/visual/$req_id/status" -H "Authorization: Bearer $KEY")
  status=$(echo "$status_resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))")
  if [ "$status" = "completed" ]; then
    file_url=$(echo "$status_resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['generated_files'][0]['url'])")
    curl -s -o "$OUT" -H "Authorization: Bearer $KEY" "$file_url"
    credits=$(echo "$status_resp" | python3 -c "import sys,json; print(json.load(sys.stdin).get('credits',{}).get('consumed','?'))")
    echo "Сохранено: $OUT (кредитов потрачено: $credits)"
    exit 0
  elif [ "$status" = "failed" ]; then
    echo "Генерация не удалась: $status_resp" >&2
    exit 1
  fi
  sleep 3
done

echo "Таймаут ожидания (последний статус: $status)" >&2
exit 1
