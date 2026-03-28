# 團隊安裝指南

這份文件是給團隊成員用的，目的是讓大家可以在自己的機器上安裝 Ralph，並在任意 Codex workspace 中使用。

## 安裝前提

- macOS 或其他 Unix-like 環境
- 系統上已有可正常運作的 `bash`
- 系統上已有可正常運作的 `node`
- 系統上已有可正常運作的 `perl`
- Codex CLI 已安裝完成且可執行
- 可存取這個 repository

建議先確認：

```bash
codex --version
command -v bash
command -v node
command -v perl
```

## 標準安裝流程

1. clone 這個 repository

```bash
git clone <repo-url>
cd codex-ralph-wiggum
```

2. 執行安裝腳本

```bash
./scripts/install-home-plugin.sh
```

3. 建議先跑靜態 smoke test

```bash
bash ./scripts/smoke-test.sh
```

4. 如果 Codex 已開著，請重新啟動

## 安裝腳本會改哪些地方

安裝腳本不會碰你的專案檔案，只會寫到家目錄：

- `~/plugins/ralph`
- `~/.agents/plugins/marketplace.json`

它會安裝一個指向以下路徑的 plugin entry：

```text
./plugins/ralph
```

實際解析後會對應到：

```text
~/plugins/ralph
```

## 安裝後驗證

Ralph for Codex 不是同-session stop hook loop，而是 external stateful runner。所以安裝後建議先驗證前景模式，再依賴背景模式。

在任意 workspace 打開 Codex，執行：

```text
/ralph:start --foreground --completion-promise DONE --max-iterations 2 read README.md and output <promise>DONE</promise> when finished
```

接著檢查：

```text
/ralph:status
```

預期結果：

- `/ralph:start` 指令存在
- Ralph 成功啟動 loop
- 目前 workspace 出現 `.ralph/`
- `status` 能看到 loop 狀態資料

## 第一次建議怎麼跑

第一次驗證某台機器時，請先用前景模式：

```text
/ralph:start --foreground --completion-promise DONE --max-iterations 5 get the local tests green and output <promise>DONE</promise> only when truly complete
```

原因：

- 比較容易即時觀察
- 可以先確認背景程序模型是否可靠
- 能先驗證本機 Codex 環境是否能正確跑完整 loop

## 日常使用

啟動 loop：

```text
/ralph:start --completion-promise DONE --max-iterations 12 fix the failing test suite and output <promise>DONE</promise> only when everything passes
```

查看狀態：

```text
/ralph:status
```

也可以直接開 watch：

```text
/ralph:watch --tail 16
```

取消：

```text
/ralph:cancel
```

續跑：

```text
/ralph:resume --additional-iterations 5
```

開 dashboard：

```text
/ralph:dashboard --open-browser
```

## Ralph 會把資料寫到哪裡

Ralph 會把狀態寫進目前 workspace：

```text
.ralph/
```

重要檔案：

- `.ralph/active-loop`
- `.ralph/loops/<loop-id>/state.env`
- `.ralph/loops/<loop-id>/handoff.md`
- `.ralph/loops/<loop-id>/iterations/`

如果團隊成員回報「Ralph 卡住了」，第一個先看：

```text
.ralph/loops/<loop-id>/handoff.md
```

## 如何更新到新版

1. 拉最新程式碼

```bash
git pull
```

2. 重新執行安裝腳本

```bash
./scripts/install-home-plugin.sh
```

3. 重新跑 smoke test

```bash
bash ./scripts/smoke-test.sh
```

4. 重啟 Codex

## 如何移除

先刪掉 plugin 目錄：

```bash
rm -rf ~/plugins/ralph
```

再編輯：

```text
~/.agents/plugins/marketplace.json
```

把 `plugins` 陣列裡的 `ralph` entry 移除。

## 常見問題

### `/ralph:start` 不存在

請先檢查：

- 安裝後是否有重新啟動 Codex
- `~/plugins/ralph` 是否存在
- `~/.agents/plugins/marketplace.json` 是否包含 `ralph` entry

### 背景 loop 會自己停掉

先改用：

```text
/ralph:start --foreground ...
```

確認這台機器的背景程序行為沒問題之後，再依賴 unattended 背景模式。這是因為 Ralph for Codex 採用 external runner，而不是 Claude upstream 的同-session stop hook 模式。

### `status` 顯示 `stopped`

通常代表 runner process 已經結束，但 loop 狀態檔還在。

先試：

```text
/ralph:resume
```

或直接檢查：

```text
.ralph/loops/<loop-id>/runner.log
.ralph/loops/<loop-id>/handoff.md
```

### Loop 一直無法完成

先檢查 prompt 品質：

- completion promise 是否明確
- success criteria 是否客觀
- iteration 上限是否太低

不好的例子：

```text
/ralph:start make this better
```

比較好的例子：

```text
/ralph:start --completion-promise DONE --max-iterations 10 make the local test suite pass and update README examples if tests reveal contract changes; output <promise>DONE</promise> only when tests are green
```

## 團隊使用建議

如果你要做正式 rollout，請另外走一次 [RELEASE_CHECKLIST.md](./RELEASE_CHECKLIST.md)。

把 Ralph 當成 execution primitive，不要把它當成魔法代理。

適合用在：

- 任務是客觀的
- 任務可以被驗證
- prompt 對完成條件定義清楚

不適合用在：

- 任務需要大量人類主觀判斷
- 任務本身偏模糊或探索
- 任務高風險或具有操作性破壞
