#!/usr/bin/env bash
# generate-day-report.sh — черновик ежедневного отчёта (docs/day-open/REPORT-STRUCTURE.md)
# Собирает объективные данные (коммиты, сессии, план дня) в archive/daily-reports/$DATE/.
# Раздельные текстовые секции (§1 Вчера narrative, §3 Внимание, §5 Заметки) остаются
# плейсхолдерами — их пишет пилот/агент по смыслу, не парсингом.

set -uo pipefail

IWE="${IWE_ROOT:-$HOME/IWE}"
STRATEGY="$IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}"

DATE="${1:-$(date +%Y-%m-%d)}"
YDAY=$(date -j -v-1d -f "%Y-%m-%d" "$DATE" "+%Y-%m-%d" 2>/dev/null \
  || date -d "$DATE - 1 day" "+%Y-%m-%d" 2>/dev/null)

REPORT_DIR="$STRATEGY/archive/daily-reports/$DATE"
mkdir -p "$REPORT_DIR"

# --- Guard: don't clobber a manually-finished report ---
if [ -f "$REPORT_DIR/report.md" ] && ! grep -q "ЗАПОЛНИТЬ" "$REPORT_DIR/report.md"; then
  echo "  report.md уже заполнен вручную ($REPORT_DIR) — пропускаю, чтобы не затереть."
  exit 0
fi

# ============================================
# 1. Коммиты по репозиториям (вчера)
# ============================================
COMMITS_TOTAL=0
COMMITS_BLOCK=""
for repo_path in "$IWE"/*/; do
  [ -d "$repo_path/.git" ] || continue
  repo=$(basename "$repo_path")
  log=$(cd "$repo_path" && git log --oneline --since="$YDAY 00:00:00" --until="$DATE 00:00:00" 2>/dev/null)
  [ -z "$log" ] && continue
  n=$(echo "$log" | wc -l | tr -d ' ')
  COMMITS_TOTAL=$((COMMITS_TOTAL + n))
  COMMITS_BLOCK+="=== $repo ($n) ===
$log

"
done

# ============================================
# 2. Сессии вчера
# ============================================
SESSIONS_YDAY=$(find "$STRATEGY/sessions" -maxdepth 1 -name "*$YDAY*" 2>/dev/null | wc -l | tr -d ' ')

# ============================================
# 3. Приоритеты дня из DayPlan (если есть)
# ============================================
DAYPLAN_FILE="$STRATEGY/current/DayPlan $DATE.md"
DAYPLAN_PRIORITIES=""
if [ -f "$DAYPLAN_FILE" ]; then
  DAYPLAN_PRIORITIES=$(sed -n '/Утренние приоритеты/,/^$/p' "$DAYPLAN_FILE" 2>/dev/null)
fi

# ============================================
# 4. checklist-status.yaml (только объективно измеримые поля)
# ============================================
cat > "$REPORT_DIR/checklist-status.yaml" <<YAML
date: $DATE
checklist_file: docs/day-open/CHECKLIST.md
generation: auto ($(date -u +%Y-%m-%dT%H:%M:%SZ))

phase_1_yesterday:
  title: "Сбор вчерашних данных"
  commits_all_repos: $COMMITS_TOTAL
  sessions_yesterday: $SESSIONS_YDAY
  status: "computed"

phase_3_dayplan:
  title: "Планирование дня"
  dayplan_exists: $([ -f "$DAYPLAN_FILE" ] && echo "true" || echo "false")
  status: "$([ -f "$DAYPLAN_FILE" ] && echo "computed" || echo "missing")"

phases_not_auto_checked:
  - phase_0_preconditions
  - phase_2_review_wp
  - phase_4_platform_health
  - phase_5_context
  - phase_6_finalize

notes: >
  Автосгенерировано скриптом generate-day-report.sh. Фазы 0, 2, 4, 5, 6 требуют
  ручной/агентной сверки (Sync Gate, здоровье платформы, контекст) — скрипт их не
  проверяет, только помечает как непроверенные.
YAML

# ============================================
# 5. report.md (шаблон + объективные данные, текст — плейсхолдер)
# ============================================
cat > "$REPORT_DIR/report.md" <<MD
---
date: $DATE
day_of_week: $(date -j -f "%Y-%m-%d" "$DATE" "+%A" 2>/dev/null || date -d "$DATE" "+%A" 2>/dev/null)
type: day-open-report
status: draft
---

## Вчера ($YDAY)

[ЗАПОЛНИТЬ: 2-3 абзаца о вчерашних РП/сессиях. Сырые данные ниже.]

<details>
<summary>Сырые коммиты по репозиториям ($COMMITS_TOTAL всего, $SESSIONS_YDAY сессий)</summary>

\`\`\`
$COMMITS_BLOCK
\`\`\`

</details>

## Сегодня ($DATE)

[ЗАПОЛНИТЬ: план дня. Из DayPlan ниже.]

<details>
<summary>Приоритеты из DayPlan</summary>

\`\`\`
$DAYPLAN_PRIORITIES
\`\`\`

</details>

## ⚠️ Внимание

[ЗАПОЛНИТЬ или удалить, если нет рисков]

## 📝 Заметки

[ЗАПОЛНИТЬ или удалить]
MD

echo "  Отчёт-черновик: $REPORT_DIR/report.md ($COMMITS_TOTAL коммитов, $SESSIONS_YDAY сессий вчера)"
