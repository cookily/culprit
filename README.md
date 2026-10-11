# Culprit 元凶监控

macOS 菜单栏的"元凶"显示器——风扇狂飙、系统卡顿**之后**，告诉你刚才是谁干的。

> A macOS menu bar monitor that answers, after the fan spins up: *who did it?*

## 为什么又造一个轮子

Stats / eul / iStat Menus 都只显示"现在"：等你打开监控，元凶可能已经跑完了。
Culprit 的差异点在**事后归因**——后台持续采样，把"某时刻谁在吃 CPU/内存/磁盘"记下来，
风扇转完你才想起来看？点开时间轴就有答案。

## 当前状态（P1 · 实时监控 + 历史归因）

- 菜单栏常驻：整机 CPU 百分比，≥50% 橙、≥80% 红；热压力 serious/critical 追加 🔥
- 点开菜单：整机概览（CPU / 内存 / 热状态）+ CPU 占用 Top 10 进程
- **尖峰事件自动记录**：整机 CPU ≥50% 持续 15 秒开事件、回落 30 秒关闭；热压力升到 serious/critical 也记
- **"最近尖峰事件"区**：每条事件带子菜单，回放时段（起止/时长/整机均值/峰值）+ 当时 CPU Top5 进程（均值/峰值）——风扇转完再点开，照样知道是谁
- 采样滚动落 SQLite：`~/Library/Application Support/Culprit/history.sqlite`（WAL；采样保留 2 天、事件 7 天）
- 每 3 秒采样一轮，全部用户态 API：无需 root、无需任何权限，自身开销毫秒级

### 构建与运行

```bash
bash build.sh                     # 产物 ~/Applications/Culprit.app（universal，ad-hoc 签名）
open ~/Applications/Culprit.app
```

只需 Command Line Tools，无需 Xcode 工程；退出：菜单最后一项或 ⌘Q。

## 路线图

- [x] **P1 历史归因（核心差异点，0.2.0 已交付）**：滚动采样落 SQLite；尖峰事件检测（CPU 持续高位 / 热压力升级）；
      菜单"最近尖峰事件"回放"当时谁在跑"；每进程磁盘 IO 已入库（展示待做）
- [ ] **P2**：SMC 风扇转速/温度（参考 exelban/stats 的 SMC 键库）；尖峰系统通知；每进程网络速率；
      历史图表；从菜单安全地结束进程

## 口径与已知限制

- 每进程 CPU%：单核口径（同活动监视器），一个进程吃满 8 核 = 800%
- 整机 CPU%：busy ticks / all ticks，0~100
- 内存：物理足迹（phys_footprint），与活动监视器"内存"列同源
- kernel_task（pid 0）不进进程列表；每进程网络速率需私有 API，放到 P2
- 温度/风扇转速需读 SMC，未实现（先用系统热压力等级顶上）
- 事件口径：整机 CPU ≥50% 连续 5 拍（15 秒）开、<35% 连续 10 拍（30 秒）关；热压力 ≥serious 连续 2 拍开、≤fair 持续 1 分钟关
- 进行中的事件若遇应用退出，下次启动按最后采样时间自动收尾（不丢记录）
- 库文件约 10 MB/天（WAL 每小时收缩一次），按采样保留 2 天滚动，整库稳定在 20~30 MB

## License

MIT
