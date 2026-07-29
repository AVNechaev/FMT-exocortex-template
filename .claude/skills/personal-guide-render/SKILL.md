---
name: personal-guide-render
description: Тонкий клиент — собирает персональное руководство пилота через облачный сервер (mcp__aisystant__render_personal_guide). Используй когда пилот просит «пересобери руководство», «обнови мой план», «собери руководство на сегодня».
argument-hint: "[необязательно: дата в формате YYYY-MM-DD, по умолчанию сегодня]"
experimental: false
related: [WP-149, personal-guide-start, DP.SC.187]
version: 2.0.0
layer: L1
status: active
supersedes: "v1.0.0 (personal-guide-render-v1-archive.md в inbox/WP-149/)"
triggers:
  slash: [/personal-guide-render]
  phrases: []
routing:
  executor: sonnet
  deterministic: true
agents: single
interaction: single-step
gates_required: []
gates_enforced: []
gates_rationale: "операционный скилл; WP Gate применим только при создании нового РП, не для операционных вызовов"
---

# Render персонального руководства (v2 — тонкий клиент)

> ⚡ **Три шага, без диалога.** Выполни 0→1→2→3 последовательно. Вся логика сборки — на сервере (render-pilot-guides.py, вызывается через облачный MCP-сервер aisystant).

## When to use

Тонкий клиент — собирает персональное руководство пилота через облачный сервер (`mcp__aisystant__render_personal_guide`). Используй когда пилот просит «пересобери руководство», «обнови мой план», «собери руководство на сегодня».

## Контракт скилла

- **Вход:** дата (аргумент или сегодня). Репо `personal-guide` под аккаунтом пилота должно существовать (создаётся через `/personal-guide-start`).
- **Выход:** файлы `guide/<date>.md` и `panel/<date>.md` обновлены в репо `personal-guide`.
- **Время:** ≤3 мин (включая LLM-генерацию на сервере).
- **Не делает:** не читает Память.Derived, не выбирает заготовки, не пишет profile.md/worldview.md/methods.md — всё это делает render-pilot-guides.py на сервере.

## Algorithm

## Шаг 0. Проверить предусловие (setup завершён)

Вызови `personal_search(source: "personal-guide", path: ".claude/skills/personal-guide-start/SKILL.md")`.

Если файл **не найден** → сообщить пилоту:
```
Скиллы не установлены или установка не завершена.
Запусти /personal-guide-start для первичной настройки.
```
Стоп (не переходить к Шагу 1).

## Шаг 1. Определить дату

`date` = аргумент скилла если передан (формат YYYY-MM-DD), иначе сегодня.

## Шаг 2. Запустить сборку

Вызови `mcp__aisystant__render_personal_guide(date=<date>)`.

## Шаг 3. Отчёт пилоту

**Если OK:**
```
Руководство готово.
guide/<date>.md — учебный текст (содержание)
panel/<date>.md — табло (форма, статистика, повестка)
```

**Если ошибка:**
```
Сборщик вернул ошибку: <текст ошибки>
Повтори попытку. Если ошибка повторяется — обратись в поддержку платформы.
```

## Failure modes

| Симптом | Причина | Решение |
|---------|---------|---------|
| Шаг 0: файл не найден | /personal-guide-start не запускался | Запустить /personal-guide-start |
| render_not_configured | PILOT_GITHUB_OWNER не задан на сервере | Проверить настройку через /personal-guide-start |
| Таймаут >3 мин | LLM не отвечает на сервере | Повторить попытку позже |
| guide/<date>.md не появился | Ошибка git push на сервере | Повторить попытку; при повторении — в поддержку платформы |

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
