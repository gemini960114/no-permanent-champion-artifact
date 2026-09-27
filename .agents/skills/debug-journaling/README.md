# Skill：修復記錄紀律 (Debug Journaling)

> **SKILL.md**＝AI 載入的技能指令；本 README＝人類說明。
> 緣起：2026-09-26 使用者觀察到——AI 修完東西會習慣把教訓寫進 docs/，
> 這讓後續修正與未來 AI 除錯都有跡可循。本 skill 將此紀律制度化。
> 核心：**修好 ≠ 完成；修好＋記錄才是完成。**

## 為什麼這件事值得變成 skill

這個 repo 的實證：幾乎每次快速除錯，都是因為**上一次的學費有記錄**——

| 情境 | 靠哪條歷史記錄省下的時間 |
| :--- | :--- |
| GLM cap 調優（64→128 一次到位） | flash 的 48→100 教訓（benchmarks/README） |
| 抓 `stepfun` parser 是錯的 | skill 自己的「教訓實錄」制度（實測優先鐵律） |
| 壓測失敗快速分層定位 | ulimit／隧道上限都寫在 benchmarks 教訓區 |
| 避免 ps args 卡死、跨節點陷阱 | EXTERNAL_VM_TUNNEL（私有部署文件，未收錄於公開版） §4.1 的實錄 |

**沒有記錄的修復會被反覆重新發明**——對人類如此，對 AI 更是（每次對話都是失憶重來）。

## 標準格式（五段式）

```markdown
### 案例 N：<一句話症狀>
- **症狀**：錯誤訊息／行為特徵（秒殺 or 逾時？數字卡在哪？）
- **定罪**：怎麼定位的＋**證據**（實測數據、log 摘錄、旁路對照）
- **修復**：改了什麼（設定位置＋行內註解）
- **驗證**：可複製的指令＋期望輸出
- **注意**：修復的副作用／尾巴（例如 sshd 修後要彈隧道）
```

## 路由表速記

```
操作踩坑      → docs/ENGINE_LIFECYCLE_GUIDE.md §5
基礎設施      → docs/EXTERNAL_VM_TUNNEL.md（私有部署文件，未收錄於公開版）（教訓小節）
引擎配方/參數 → engines/KNOWN_GOOD.md
壓測/容量     → benchmarks/README.md 工程解讀
AI 流程方法論 → 對應 skill 的 README
歷史軌跡      → CHANGELOG.md（私有 repo 維護，未收錄於公開版）（條目寫「怎麼發現的」）
```

## 使用者端範例 prompt

```
（這個 skill 不需要你主動觸發——AI 修完東西就該自動遵守）
```
若想抽查 AI 有没有遵守：
```
你剛剛修的這個問題，教訓記到哪個文件了？帶我看
```

## 相關文件

- 記錄格式實例：[`benchmarks/README.md`](../../../benchmarks/README.md) 工程解讀區
- 疑難排解實例：[`docs/ENGINE_LIFECYCLE_GUIDE.md`](../../../docs/ENGINE_LIFECYCLE_GUIDE.md) §5
- 教訓實錄實例：docs/EXTERNAL_VM_TUNNEL.md（私有部署文件，未收錄於公開版） §4.1
