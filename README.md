# Ralph for Codex

Ralph 是一個給 Codex 用的本地 plugin，目的是把「同一個任務反覆執行，直到真的完成」這件事做成可控制、可恢復、可觀察的工作流。

它參考了 Claude Code 的 Ralph Wiggum 概念，但不是 stop-hook 的 1:1 移植。更準確的說法是：同樣的 loop 哲學，不同的 runtime model。Ralph for Codex 不依賴未公開的 stop hook，而是把每一輪都當成新的 `codex exec`，把狀態落盤，並提供明確的 `status`、`cancel`、`resume`、`watch`、`dashboard` 與 `campaign` 操作。

## 與 Claude upstream 的關係

如果你熟悉 Claude Code 的 Ralph Wiggum，這裡最重要的差異只有一個：

- Claude upstream：在同一個 session 裡用 stop hook 阻止結束，讓 agent 原地繼續 loop
- Ralph for Codex：在外部用可恢復的狀態機管理多次 fresh `codex exec`

這樣做的代價是每輪都會重新啟動一個新 session；好處是狀態透明、故障可追、可以 `status` / `resume` / `cancel`，也更容易做 `campaign` 和本地 dashboard。

## 這個專案解決什麼問題

單純跑一次 `codex exec`，很適合一次性任務；但遇到下面這類工作時，你通常需要一個「有狀態的 loop」：

- 把 failing test suite 修到全綠
- 做有邊界的重構，直到驗證條件滿足
- 反覆執行修復與驗證
- 等待一個明確完成條件被觸發

Ralph 在 `codex exec` 之上補了幾件關鍵能力：

- 穩定的任務 prompt，不會每輪漂移
- 用 `<promise>...</promise>` 做精準完成判定
- 把每個 loop 的狀態持久化到 `.ralph/`
- 支援暫停後追蹤、取消與續跑
- 保留 handoff 與 iteration 記錄，方便除錯與恢復
- 提供 terminal watch 與本地 dashboard，讓你知道它現在在做什麼

## 它怎麼運作

Ralph 不會攔截你當前的 Codex session。它的模型比較直接：

1. 把任務、loop 設定與目前狀態寫進目標 workspace。
2. 每一輪啟動一個新的 `codex exec`。
3. 把輸出、handoff、iteration 歷史寫到 `.ralph/loops/<loop-id>/`。
4. 只有在以下情況才停止：
   - assistant 輸出符合指定的 completion promise
   - 達到最大 iteration 數
   - loop 被取消
   - 連續失敗次數超過限制

這種做法的好處是狀態透明、故障可追、行為容易推理，不必賭未公開 runtime 的穩定性。

## 安裝

### 在這個 repo 內直接使用

如果你是直接在這個 repository 裡開 Codex，repo-local plugin 會直接可用。

### 安裝成家目錄 plugin

建議做法：

```bash
./scripts/install-home-plugin.sh
```

安裝腳本會寫入：

- `~/plugins/ralph`
- `~/.agents/plugins/marketplace.json`

完成後重新開啟 Codex。

團隊安裝與 rollout 指南請看 [docs/TEAM_INSTALL.md](docs/TEAM_INSTALL.md)。

## 發版前檢查

靜態 smoke test：

```bash
bash ./scripts/smoke-test.sh
```

完整發版流程請看 [docs/RELEASE_CHECKLIST.md](docs/RELEASE_CHECKLIST.md)。

## 快速開始

第一次驗證建議先跑前景模式：

```text
/ralph:start --foreground --completion-promise DONE --max-iterations 5 fix the failing tests and output <promise>DONE</promise> only when everything is actually green
```

查看狀態：

```text
/ralph:status
```

取消目前 loop：

```text
/ralph:cancel
```

續跑最近一次 loop：

```text
/ralph:resume --additional-iterations 5
```

## 也可以直接跑 shell

除了 slash command，也可以直接執行 runner：

```bash
./plugins/ralph/scripts/ralph-loop.sh start \
  --foreground \
  --completion-promise DONE \
  --max-iterations 5 \
  "fix the failing tests and output <promise>DONE</promise> only when everything is actually green"
```

常用子命令：

```bash
./plugins/ralph/scripts/ralph-loop.sh status
./plugins/ralph/scripts/ralph-loop.sh cancel
./plugins/ralph/scripts/ralph-loop.sh resume --additional-iterations 5
```

## 支援的 slash commands

- `/ralph:start <task> [--completion-promise TEXT] [--max-iterations N] [--model MODEL]`
- `/ralph:status [--loop-id ID] [--tail N] [--all]`
- `/ralph:watch [--loop-id ID] [--campaign-id ID] [--interval SEC] [--tail N]`
- `/ralph:cancel [--loop-id ID]`
- `/ralph:resume [--loop-id ID] [--additional-iterations N] [--max-iterations N]`
- `/ralph:campaign <goal> [--watch-active-loop] [--verify-cmd CMD] [--boundary-doc PATH] [--boundary-section TITLE]`
- `/ralph:campaign-status [--campaign-id ID] [--tail N]`
- `/ralph:campaign-cancel [--campaign-id ID]`
- `/ralph:dashboard [--host HOST] [--port PORT] [--open-browser]`
- `/ralph:dashboard-status`
- `/ralph:dashboard-stop`

## 觀測層

如果你不想再一直盯 `.ralph/` 裡的檔案，現在有三個正式入口：

即時 terminal 視圖：

```text
/ralph:watch --tail 16
```

或直接跑 shell：

```bash
./plugins/ralph/scripts/ralph-loop.sh watch --tail 16
```

本地 dashboard：

```text
/ralph:dashboard --open-browser
```

或直接跑 shell：

```bash
./plugins/ralph/scripts/ralph-loop.sh dashboard --open-browser
```

dashboard 會起一個本地 HTTP server，顯示：

- active loop / campaign
- 最近 iterations
- 最後一輪訊息摘要
- campaign boundary snapshot
- verify log tail

另外還有：

```text
/ralph:dashboard-status
/ralph:dashboard-stop
```

以及對應的 shell 指令：

```bash
./plugins/ralph/scripts/ralph-loop.sh dashboard-status
./plugins/ralph/scripts/ralph-loop.sh dashboard-stop
```

## 狀態會寫到哪裡

Ralph 會把 loop 狀態寫進目前 workspace：

```text
.ralph/
  active-loop
  loops/
    <loop-id>/
      state.env
      task.md
      prompt.md
      handoff.md
      last-output.txt
      iterations/
        0001/
        0002/
        ...
```

最常用的幾個檔案：

- `state.env`：目前 loop 的中繼資料
- `handoff.md`：上一輪留下的交接內容
- `iterations/<n>/final-message.txt`：assistant 該輪的原始最終輸出
- `runner.log`：背景模式下的執行記錄

## 預設值

- `--max-iterations` = `20`
- `--approval-policy` = `never`
- `--sandbox` = `workspace-write`
- `--consecutive-error-limit` = `3`

`approval-policy=never` 是刻意設計的，因為 unattended loop 不可能替你回答 approval prompt。

## 背景模式

要先驗證一台機器是否穩定，建議先用前景模式：

```text
/ralph:start --foreground ...
```

背景模式是支援的，但是否能長時間常駐，仍取決於主機環境：

- macOS 會優先嘗試 `launchctl submit`
- 如果不可用，會退回 detached child process
- 某些受管控的 shell 或 supervisor 仍可能回收背景程序

如果 loop 意外停掉，先檢查：

```text
/ralph:status
/ralph:resume
```

## 什麼情況適合用 Ralph

適合：

- 任務有客觀完成條件
- 任務可以靠測試、檔案或命令驗證
- 你想要有限度的自動執行，但保留可追蹤性

不適合：

- 任務本質上模糊或偏探索
- 任務需要人持續做主觀判斷
- 任務本身高風險或具破壞性

## 專案結構

- `plugins/ralph/`：Codex plugin 本體
- `plugins/ralph/scripts/ralph-loop.sh`：loop runner
- `.agents/plugins/marketplace.json`：repo-local plugin 清單
- `scripts/install-home-plugin.sh`：安裝到家目錄的 helper
- `docs/TEAM_INSTALL.md`：團隊安裝說明

## 已知限制

- 目前是本地 plugin 工作流，不是已發布的 marketplace package
- 背景模式是否穩定，取決於機器與 shell supervision 模型
- 實作刻意避開未公開的 Codex stop-hook 行為，因此不是 Claude upstream 的同-session loop 語義

## 授權

MIT，詳見 [LICENSE](LICENSE)。
