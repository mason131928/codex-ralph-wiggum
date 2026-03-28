# 發版前 Checklist

這份 checklist 是給維護者用的。目標不是把 Ralph 包裝成「看起來能用」，而是確認它真的能在 Codex 上被安裝、啟動、觀測、取消、續跑。

## 1. 先跑靜態 smoke test

```bash
bash ./scripts/smoke-test.sh
```

通過標準：

- shell script 語法正確
- dashboard Node script 語法正確
- plugin metadata 與 `SCRIPT_VERSION` 同步
- 主要 command wrapper 與核心文件都存在

## 2. 驗證 repo-local plugin 可被 Codex 看見

在 source repo 直接開 Codex，確認 slash commands 存在：

```text
/ralph:start
/ralph:watch
/ralph:dashboard
```

通過標準：

- `start`、`watch`、`dashboard` 至少都能被補全或正確辨識

## 3. 驗證家目錄安裝流程

```bash
./scripts/install-home-plugin.sh
```

重新開啟 Codex，於任意 workspace 驗證：

```text
/ralph:start --foreground --completion-promise DONE --max-iterations 2 read README.md and output <promise>DONE</promise> when finished
```

通過標準：

- `~/plugins/ralph` 已更新
- `~/.agents/plugins/marketplace.json` 內存在 `ralph` entry
- 前景 loop 可啟動

## 4. 驗證 loop 基本生命週期

在測試 workspace 內依序驗證：

```text
/ralph:start --foreground --completion-promise DONE --max-iterations 3 read README.md and output <promise>DONE</promise> when finished
/ralph:status
/ralph:cancel
/ralph:resume --additional-iterations 2
```

通過標準：

- `.ralph/` 會被建立
- `status` 能看到 loop 狀態
- `cancel` 能把狀態切到 `cancelled` 或 `cancel-requested`
- `resume` 能重新啟動既有 loop

## 5. 驗證 observability

至少測一次 terminal watch 與 dashboard：

```text
/ralph:watch --tail 16
/ralph:dashboard --open-browser
/ralph:dashboard-status
/ralph:dashboard-stop
```

通過標準：

- `watch` 能持續刷新，不是一次性輸出
- dashboard 能回報本地 URL
- dashboard status / stop 都能正確工作

## 6. 驗證 campaign

只在目標 repo 有合適的 boundary doc 時執行，例如：

```text
/ralph:campaign --foreground --verify-cmd "npm run verify" --boundary-doc docs/public-release.md --boundary-section "Current Boundaries" finish the remaining roadmap honestly
```

通過標準：

- campaign 能建立 `.ralph/campaigns/<id>/`
- 能讀到 boundary snapshot
- 完成一輪後會執行 verify command
- 若 boundary 仍存在，會繼續下一 round

## 7. 最後做 release hygiene 檢查

發版前再確認：

- `README.md` 已清楚說明這不是 stop-hook 的 1:1 移植，而是 external stateful runner
- `plugins/ralph/README.md` 的命令列表與實作一致
- `docs/TEAM_INSTALL.md` 安裝與驗證步驟仍正確
- `plugin.json` 的 `version` 與 `plugins/ralph/scripts/ralph-loop.sh` 的 `SCRIPT_VERSION` 一致

如果以上任一項沒過，不要把這版當成可 rollout 的 release。
