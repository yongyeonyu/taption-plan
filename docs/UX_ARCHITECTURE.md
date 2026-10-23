# 用户体验架构重构方案

> 本文档回答三个问题:**现在的流程断在哪(有代码证据)、目标架构长什么样、怎么迁移过去。**
> 诊断基于 `0f6988b` + `ARC1024A09` 两个提交后的代码库,所有数字都可以用文中给出的命令复现。

---

## 修订记录

**v2 — 2026-10-24,产品评审后修订。** 评审推翻了 v1 的三个判断,本版已改:

| v1 的说法 | 评审结论 | 本版处理 |
|---|---|---|
| 诊断漏掉了 widget 深链 | `handleOpenURL` 第一行 `guard legacyUIEnabled else { return }`,而 widget 全部用 `.widgetURL(taptionplan://…)` | 新增 **B0**,列为最高优先级 |
| "地图优先" 是事故,应恢复四支柱 | git 证据显示是有意转向(`e4ef98c`, 2026-08-16),后续 2 个月 35,470 行全投在 MapHome 家族 | B1 改写:不是"丢了两根支柱",是"两个能力没在新基础上重建" |
| Phase 2 复活 `ScheduleView` + `ReviewView`(16,639 行) | 这两者是死代码;而 `MapHomeTimeSidebar`(3,093 行)、`MapHomeCalendarSheet`(2,920 行)已经是活的、持续维护的同类能力 | Phase 2 改为**提升活的东西**,6,013 行 |
| "看历史记录" 完全没有入口 | 夸大。`MapHomeCalendarSheet` 已有月网格 + 每日时长/次数/距离与均值 | 改为"缺的是深度,不是存在" |
| 验收用 "48 个状态 → 0" | 会把 27 处模态全部重写,而目的地还没定 | 放宽为 ≤ 10 |

**新增:** Phase 0(埋 6 个计数器)与 kill criteria(§8)。评审指出的前提是:**这个 App 目前没有任何产品分析**(Firebase / Amplitude / Mixpanel / Sentry / PostHog 全部 0 命中,只有本地 diagnostics 日志)。没有基线,任何"验收指标"都只是仪式。

---

## 0. 结论摘要

| 指标 | 现在 | 目标 |
|---|---:|---:|
| **widget 点击是否有效** | **否(全部失效)** | 是 |
| 声明的产品支柱 | 4 个 Tab | 3 个视图 + 抽屉 |
| 用户真正能到达的支柱 | **1 个**(地图) | 3 个 |
| 不可达 UI | **20,811 行** | 决定删或重建,不假装"复活" |
| 到达"看历史记录"的深度 | 浅(月网格有,趋势无) | 有趋势与叙事 |
| 到达剪辑编辑器(NLE)的层级 | 2 层,靠小图标发现 | 1 层,有名字的按钮 |
| 并列的呈现状态 | 48 个 | ≤ 10 个 |
| 模态调用点 | 27 处 | ≤ 6 处(只剩全局覆盖层) |
| 返回后是否保留现场 | 否(每次回到地图) | 是(契约保证) |

一句话:**这个 App 有一个很好的"家"(地图),但没有"门"(导航)——而 widget 这扇门现在是被焊死的。**

---

## 1. 诊断方法

不靠体感。三个来源:

1. **可达性追踪** — 从 `WindowGroup` 往下追,看哪些视图真的会被渲染。
2. **状态清点** — 数呈现状态的数量和形态,判断有没有导航模型。
3. **入口清点** — 对每个目的地,数它的入口数量和层级深度。

复现命令见文末附录。

---

## 2. 六个断点

### B0. widget 深链在已发布版本里全部失效 —— 最高优先级

`AppShellView.swift:77` 是**全 App 唯一的** `onOpenURL`:

```swift
.onOpenURL { url in handleOpenURL(url) }        // :77

private func handleOpenURL(_ url: URL) {
    guard Self.legacyUIEnabled else { return }  // :574 ← 直接返回
    ...
}
```

与此同时,widget 在用 `.widgetURL(taptionplan://…)`(`TaptionPlanWidget.swift:2425`、`:3791`)、
`Link(destination:)`(`:390`)、以及 `deepLinkURL(payload:at:)`(`:324`),URL scheme 正常注册在
`Info.plist:34`。`AppModel.openDeepLink`(`:2861`)也已经写好了。

**所以:用户点 widget,落到地图,什么都不会发生。**

对一个靠被动记录留存的 App 来说,这比"某个页面不可达"更严重——widget 本身就是留存机制。
而 `handlePlanNotification`(`:582`)同样被这个 guard 挡住,通知点击也是死的。

**修复成本极低**:把 `handleOpenURL` 改成把 URL 映射到 `MapHomeView` 已有的状态
(`isCalendarPresented` / `isDaySummaryPresented` / section 编辑选择),大约 20 行。

**为什么它排在第一**:它是唯一一个"现在就在损失用户、且一天能修好"的问题。
它同时也是后面所有度量工作的验证器——见 §8。

### B1. 声明的信息架构 ≠ 交付的信息架构

`RootTab` 声明了四根支柱:

```swift
// TaptionPlan/UX/NavigationModels.swift:92
enum RootTab: String, CaseIterable, Identifiable {
    case schedule = "시간표"   // 时间表
    case goals    = "루틴"     // 例程
    case review   = "기록"     // 记录
    case settings = "설정"     // 设置
}
```

但这四个视图只在 `AppShellView` 的一个分支里被实例化,而那个分支被一个常量关掉了:

```swift
// TaptionPlan/UI/AppShellView.swift:7
private static let legacyUIEnabled = false

// :648
private var rootContent: some View {
    if Self.legacyUIEnabled && !showsMapHome {
        legacyRootContent          // ← 永远进不来
    } else {
        MapHomeView(...)           // ← 唯一的根视图
    }
}
```

`legacyUIEnabled` 在文件里被引用 10 次,全部是 `Self.legacyUIEnabled && ...` 或 `guard Self.legacyUIEnabled else { return }`。所以:

| 视图 | 行数 | 运行时可达 |
|---|---:|:---:|
| `MapHomeView` | 21,998 | ✅ |
| `ScheduleView`(时间轴) | 11,822 | ❌ |
| `ReviewView`(记录) | 4,817 | ❌ |
| `SettingsView`(设置) | 2,324 | ❌ |
| `GoalsView`(例程) | 1,848 | ❌ |

**合计 20,811 行 UI 用户永远看不到。** `AppDetail` 的 14 个目的地同样全部失效。

**但这不是事故,是有意转向没做完。** git 说得很清楚:`e4ef98c`(2026-08-16,
"refresh map home experience")在一次提交里引入了这个 flag、`showsMapHome = true`、
给 `MapHomeView` 加了 904 行、并新增了 `MapHomeCalendarSheet` / `MapHomeTimeSidebar` /
`MapHomeBannerAdView` 与房屋素材。此后两个月的产品工作**全部**投在 MapHome 家族
(35,470 行),而 `ScheduleView` / `ReviewView` / `GoalsView` 只拿到机械性修补。

这个区别决定了处方。不是"用户失去了支柱,把它还回去",而是**"两个能力没有在新地基上重建"**。
所以"不可达行数 20,811 → 0"是个坏指标:它奖励复活一具尸体。

正确的问法是:**这两个能力里,哪些已经被活的表面覆盖了?**(见 §6 Phase 2)


### B2. 没有导航模型,只有一片并列的开关

`MapHomeView` 里:

```
@State 总数                     252
  is*Presented                   19   ← 控制"哪个模态在显示"
  is*Expanded                    11   ← 控制"哪块内容展开"
  selected*                      18   ← 控制"选中了哪个对象"
.sheet(                          25
.fullScreenCover(                2
```

**说明:上面三类是不同性质的,不能相加。** 48 只是把它们加起来的读数,不是"48 个模态开关"。真正的导航状态是 19 个 `is*Presented` + 2 个 `fullScreenCover` + 25 个 `.sheet`,而其中又有多处是同一个 sheet 在不同分支上重复挂载。

无论怎么数,结论一样:**这些状态彼此独立。它们不构成一棵树,不构成一个栈,只是并排躺在同一个视图里。**

后果有三条,每一条都是可观察的体验问题:

1. **没有"返回"语义。** 每个 sheet 关闭后都回到地图。用户在"设置 → 数据保护 → 关掉 → 想看刚才那页"时,没有"上一页"。
2. **可以进入不可能的状态。** 两个 `is*Presented` 同时为 `true` 时,SwiftUI 只显示后设置的那个,前一个静默丢失,没有任何断言保护。
3. **模态会套模态。** `MapHomeCalendarSheet` 内部又有 2 个 `.sheet`。日历 → 详情 → 再一层,用户按三次"关闭"才能回到地图,而三次的视觉反馈是一样的。

### B3. 底栏是工具箱,不是导航器

底栏 7 个按钮:

```
메뉴(菜单) · 달력(日历) · 현재 위치(当前位置) · 집(家) · 재생(播放) · 녹화(录屏) · 메모(备忘)
```

**其中 0 个改变"你在哪"。** 全部是对当前视图的操作。所以用户在任何一个时刻,都没有办法表达"我想换个角度看看"。

抽屉里的 4 个分组同样如此:

```
기록(记录):  位置 · 分类        ← 配置,不是浏览
화면(画面):  显示 · 语言        ← 配置
연결(连接):  Apple Watch       ← 配置
앱(应用):    设置 · 通知 · 每日卡片 · 地图来源
```

抽屉是一个**设置面板**,不是导航器。把它当作导航器,是当前架构的根本误解。

### B4. 核心循环埋在第 2 层,靠一个图标发现

这个产品的核心循环是:**自动采集 → 看见 → 修正 → 回顾**。

"修正"这一步的入口是这样的:

```
MapHomeView
  └─ 地图上的一个区块(小图标)
       └─ MapHomeSectionEditSheet        ← 第 1 层
            └─ MapHomeNLEClipEditor      ← 第 2 层,真正干活的界面
```

而"回顾"这一步:**没有入口**(见 B1)。

所以循环在"修正"处需要用户先猜到一个没有文字的图标,在"回顾"处直接断掉。
一个循环断在两处,它就不是循环,而是一条走不回去的直线。

### B5. 权限是事后弹窗,不是首屏状态

产品需要 10 类权限:

```swift
enum PermissionFeature {
    case photos, calendar, health, location, motion,
         weather, microphone, notifications, cloud, appUsage
}
```

启动顺序是:启动遮罩 → 地图 → (延迟) `presentPermissionOnboardingIfNeeded()` 弹出模态。

问题不在于弹窗本身,而在于**顺序**:

1. 用户先看到一张完整的地图,以为自己已经"开始记录"了。
2. 然后一个模态告诉他还缺权限,但没有说明"缺了这个,地图上这块空白就永远不会亮"。
3. 用户关掉模态,回到地图。地图上显示"위치 기록을 기다리는 중"(等待位置记录)——一个**沉默的空状态**。

采集没跑起来时,产品最该做的事是**解释为什么**。现在它选择安静地等。

---

## 3. 设计原则

四条,后面每个决定都回到这四条:

**P1. 一天是唯一实体。**
这个产品的时间单位是一天。所有视图都是"同一天"的不同投影,不是不同的地方。
`AppModel.selectedDate` 已经是这样工作的,架构要承认它。

**P2. 换视角不是导航。**
在"地图 / 时间轴 / 记录"之间切换,不应该清空任何东西。它是重新投影,不是页面跳转。
所以它是分段控件,不是 Tab。

**P3. 只有一条栈。**
所有"目的地"必须声明父级和返回目标。不能声明父级的,就不是目的地,而是全局覆盖层(权限、购买、分享)。

**P4. 每个目的地恰好一个主入口,入口必须有名字。**
可以额外有一个上下文入口(比如长按地图),但主入口必须是有文字的控件,不能只有图标。

---

## 4. 目标架构:一天,三个视图,一条栈

### 4.1 形状

```
                        ┌──────────────────────────────┐
                        │   Day  (selectedDate)        │
                        │   唯一的实体,唯一的真相源      │
                        └──────────────┬───────────────┘
                                       │ 三个投影
              ┌────────────────────────┼────────────────────────┐
              ▼                        ▼                        ▼
        ┌───────────┐            ┌───────────┐            ┌───────────┐
        │  지도      │            │  타임라인   │            │  기록      │
        │  空间视角   │            │  时间视角   │            │  回顾视角   │
        └─────┬─────┘            └─────┬─────┘            └─────┬─────┘
              │                        │                        │
              └────────────────────────┴────────────────────────┘
                                       │ 共用一条栈
                        ┌──────────────▼───────────────┐
                        │  DayNavigator                │
                        │  mode + path: [DayRoute]     │
                        └──────────────┬───────────────┘
                                       │
                        ┌──────────────▼───────────────┐
                        │  全局覆盖层(不进栈)            │
                        │  权限 · 购买 · 分享 · 录屏     │
                        └──────────────────────────────┘
```

### 4.2 三个视图,不是四个 Tab

| 视图 | 回答的问题 | 内容来源 |
|---|---|---|
| **지도**(地图) | 我今天**在哪**、发生了什么 | `MapHomeView`(保留) |
| **타임라인**(时间轴) | 我今天**怎么过的**、哪里错了 | `ScheduleView` 的 day 刻度(复活) |
| **기록**(记录) | 我**过去**是怎么过的 | `ReviewView` 的 week/month 刻度(复活) |

**例程(루틴)为什么不是第四个视图?**
例程不是"一个地方",而是时间轴上的一条**参考层**(计划 vs 实际)。把它做成视图,用户每次要"去一个地方管理规则";把它做成层,用户在看到偏差的当下就能改规则。

所以:`GoalsView` 的内容并入时间轴的计划层 + 抽屉里的"루틴"入口。这是**降级**,不是删除。

**设置为什么不占视图?**
设置是低频、非浏览性内容。它属于抽屉(已经是抽屉了)。恢复 `SettingsView` 全量 2,324 行到抽屉的"설정"入口即可。

### 4.3 状态模型

```swift
enum DayMode: Hashable, CaseIterable {
    case map        // 지도
    case timeline   // 타임라인
    case record     // 기록
}

enum DayRoute: Hashable {
    case daySummary(Date)
    case clipEditor(clipID: UUID?, focus: TimeSpan?)
    case sectionEditor(TimeSpan)
    case place(UUID)
    case memo(Date)
    case photos(Date)
    case calendar
    case growth
    case routineEditor
    case settings(SettingsPane)
}

@Observable
final class DayNavigator {
    var mode: DayMode = .map
    var path: [DayRoute] = []
    var selectedDate: Date

    func push(_ route: DayRoute)
    func pop()
    func switchMode(_ mode: DayMode)
}
```

### 4.4 现场保持契约

这是整个方案里最容易被做坏的一条,所以写成契约:

**切换视图时保留:**
- (a) 选中的日期 `selectedDate`
- (b) 每个视图各自的滚动 / 缩放位置(每个 mode 记住自己的,互不覆盖)
- (c) 当前选中的 clip / 地点

**切换视图时清空:**
- (d) 该视图的 push 栈(回到该视图的根)

**从任何地方返回时保留:**
- (e) 进入前的滚动位置与选中项 —— 这就是"返回"的意义

没有 (e),用户每次修正一个 clip 都要重新找到它。这是当前架构最伤人的地方。

---

## 5. 关键流程:前后对比

### 流程 A — 修正今天的一个活动

| | 现在 | 目标 |
|---|---|---|
| 1 | 地图上找到一个没有文字的小图标 | 底栏点 **타임라인** |
| 2 | 点开 SectionEdit sheet | 在时间轴上看到这一天的条带 |
| 3 | 在 sheet 里再点编辑 | 点那个 clip |
| 4 | NLE 编辑器打开 | NLE 编辑器打开 |
| 5 | 关闭 → 回地图,**位置丢失** | 返回 → **回到同一位置,同一 clip 仍选中** |

层级 2 → 1,且每一步都有名字。

### 流程 B — 看上周的记录

| | 现在 | 目标 |
|---|---|---|
| 1 | 달력 按钮 → `MapHomeCalendarSheet`(月网格) | 底栏点 **기록** |
| 2 | 逐日翻,看单日时长/次数/距离与均值 | 分段控件点 **주**(周) |
| 3 | 没有趋势、没有叙事、没有跨日对比 | 看到一周的形状 |

**v1 在这里写"不可达",是错的。** 回顾的入口存在,缺的是**深度**:现在能回答"那天多少小时",
不能回答"这周和上周比怎么样"。这个区别很重要——它把 Phase 2 从"造一个新视图"变成
"给已有表面加一层",成本差一个数量级。

### 流程 C — 第一次打开

| | 现在 | 目标 |
|---|---|---|
| 1 | 启动遮罩 | 启动遮罩 |
| 2 | 地图(看起来一切正常) | 地图 + **采集状态卡**(缺什么、为什么、一键开启) |
| 3 | 延迟弹权限模态 | —(已内嵌,无模态) |
| 4 | 关掉模态,回到沉默的空地图 | 卡片消失,地图开始点亮 |
| 5 | 不明白为什么没有数据 | 每一步都知道自己在等什么 |

### 流程 D — 从通知 / 深链进入某一天

| | 现在 | 目标 |
|---|---|---|
| 1 | `handleOpenURL` 第一行 `guard Self.legacyUIEnabled else { return }` | 解析成 `DayRoute`,直接 push |
| 2 | **静默失败** | 定位到那一天的对应视图 |

---

## 6. 迁移计划

六个阶段,每个独立可发布、独立可回滚。**前两个不叫 Phase 0 是因为它们不是准备工作,
是现在就在损失用户的问题。**

> **命名与顺序提醒** 本文的"阶段"是 **UX 阶段**;`docs/ARCHITECTURE_ROADMAP.md` 的
> "Phase 0–5" 是 **代码结构阶段**,两套编号互不相干。顺序上只有一条约束:
> **代码侧 Phase 2(把 6 个域模型提升到 `TaptionPlanCore`)已推迟到本文六个阶段之后** ——
> 它要改的调用部和本方案的 `Day` 单一实体化是同一批文件,同时动会分不清谁弄坏的。
> 代码侧 Phase 1(纯文件移动)可以先做,它让 `MapHomeView.swift` 从 21,998 行降到约 9,000 行,
> 反而减轻这里的负担。

### 阶段 0a — 修 widget 深链(1 天,立刻发)

**做什么** 把 `AppShellView.handleOpenURL`(`:573`)的 `guard Self.legacyUIEnabled`
换成真正的路由:解析 `taptionplan://today|sensor|cats|plan/<id>`,映射到 `MapHomeView`
已有的状态(`isCalendarPresented` / `isDaySummaryPresented` / section 编辑选择 /
`model.selectedDate`)。`AppModel.openDeepLink`(`:2861`)已经写好,复用它。
`handlePlanNotification`(`:582`)同一个 guard,一并修。

**为什么排第一** 约 20 行,零架构依赖,修的是**正在发生的**用户损失。
在它之前做任何架构工作,都是让用户多等一周。

**怎么验证** `xcrun simctl openurl booted "taptionplan://today"` 必须落到今天;
四种 scheme 各一次;通知点击一次。

**完成标志** 四种深链全部生效,`rg 'guard Self.legacyUIEnabled'` 不再出现在 URL 路径上。

### 阶段 0b — 埋 6 个计数器(2 天,然后等 2 周基线)

**做什么** 这个 App **目前没有任何产品分析**——Firebase / Amplitude / Mixpanel /
Sentry / PostHog 全部 0 命中,只有 `TaptionPlanDiagnosticsLogger`
(`DiagnosticsLogSupport.swift:331`)这个 1 MB 上限的本地滚动日志,靠用户手动导出。
所以先在既有 diagnostics 通道里加 6 个计数:

`mode_switch` · `timeline_opened` · `record_opened` · `correction_saved` ·
`widget_tapped` · `session_start`

本地聚合,在 diagnostics 导出里呈现。**不引入 SDK。**

**为什么必须先做** 没有基线,§8 的 kill criteria 全是仪式。而"要不要继续投这个架构"
是个几十万成本的决策,不能靠感觉。

**顺带的红利** `widget_tapped` 让阶段 0a 变成一次免费的自然实验:修好那天,这个计数
从 0 跳到 N,同时验证了整条计数管线可信——在你把它用于大决策之前。

**完成标志** 6 个计数在导出文件里可见,且连续采集 14 天。

### 阶段 1 — 装一条栈(不动 UI)

**做什么**
1. 新增 `DayNavigator`(`UX/DayNavigator.swift`)。
2. 把 27 处模态里"目的地型"的收进 `path`;真正的全局覆盖层(权限、购买、分享、录屏)留在外面,并显式标注 `GlobalOverlay`。
3. 先把 `path` 映射到现有的 sheet 调用,视觉不变。

**为什么安全** 界面一个像素都不改。只是把并列布尔换成"1 个数组",并用现有 sheet 渲染。

**怎么验证** 现有 756 个测试不动;新增导航测试:push/pop 序列、返回后 `selectedDate` 不变。

**完成标志** `is*Presented` 从 19 降到 **≤ 10**(不要求到 0——见 §7 的取舍)。

### 阶段 2 — 三视图模式条(**提升活的,不复活死的**)

**做什么**
1. 底栏第 1 位换成模式分段控件:`지도 · 타임라인 · 기록`。
2. **타임라인 ← 把 `MapHomeTimeSidebar`(3,093 行,已在用、持续维护到 10-22)提升为全宽。**
3. **기록 ← 把 `MapHomeCalendarSheet`(2,920 行,10-24 还在改)提升为模式,并加"周/月趋势"这一层。**
4. 两者改读 `navigator.selectedDate`,不各自持有日期。

**为什么安全** 这两个表面**已经在处理真实用户数据**,只是嵌在地图里。提升是布局改动,
不是重写。

**为什么不复活 `ScheduleView` / `ReviewView`** 它们是死代码,且会造出同一份数据的
第二、第三个表示。"它有测试"不是安全——那些测试从没跑过真实用户行为。
16,639 行 vs 6,013 行,而且后者在维护中。

**怎么验证** 同一天在三个视图里的活动条带必须一致(同一份 snapshot)。

**完成标志** 三个模式都从活代码渲染;`mode_switch` 中位数 > 0.5(否则触发 §8 kill)。

### 阶段 3 — 权限内嵌

**做什么**
1. 首屏加"采集状态卡":缺哪个权限、缺了会怎样、一键跳系统设置。
2. 删除 `presentPermissionOnboardingIfNeeded()` 的延迟模态调用。
3. 空状态从"等待位置记录"改成"因为你没给位置权限,所以这里空着"。

**为什么安全** 权限申请逻辑不动,只改**呈现位置**。

**怎么验证** 关闭位置权限冷启动:必须能在首屏一句话内读到原因。

**完成标志** 首屏到"理解为什么没数据"= 0 次点击。

### 阶段 4 — 决定:删还是重建(先决定,再动手)

**做什么**
1. **先做决定**:`ScheduleView` / `ReviewView` / `SettingsView` / `GoalsView` 里,
   哪些能力已经被阶段 2 完全覆盖?被覆盖的**删除**;没覆盖的列出缺口,单独立项。
   最便宜的"0 不可达行数"是删除,不是复活——v1 的计划没评估这条。
2. `AppDetail` 的 14 个 case 逐条对照:进 `DayRoute`,或确认已废弃。
3. `GoalsView` 的内容拆到计划层与抽屉。
4. 删除 `legacyUIEnabled` 与 `legacyRootContent`。

**为什么这个顺序** v1 是"先复活再删除",逻辑反了。先决定去留,再动手,否则
复活的东西又要删一遍。

**完成标志** `rg 'legacyUIEnabled'` 为空,且每个被删的能力都有"由谁覆盖"的记录。


---

## 7. 权衡:我们放弃什么

诚实地写,因为这个方案有真实代价。

| 放弃的东西 | 代价 | 为什么仍然值得 |
|---|---|---|
| 地图作为唯一入口 | 地图失去"App 的家"的唯一性,变成一个平级视图 | 用户能到达另外两个视角。可达性 > 仪式感 |
| 四 Tab 的命名 | `루틴` 从支柱降为时间轴的一层 | 例程本质是规则,不是地点(`GoalRepeatRule` 就是 start/end + weekdays)。放在偏差旁边才用得上 |
| **旧的四 Tab 视图(20,811 行)** | 这些代码不再复活,成为待删除候选 | 它们的能力已由 `MapHomeTimeSidebar` + `MapHomeCalendarSheet` 覆盖。复活 = 同一份数据造第二、第三个表示 |
| 21 个 sheet 的独立性 | 收进栈后每个必须声明父级和返回目标 | 这正是"返回"能工作的前提。声明不出来的,说明它本就不该是目的地 |
| 一次性重写的诱惑 | 阶段 1 会让 `path` 与旧 sheet 短暂并存 | 每阶段可独立回滚 |

**明确不做的**:
- 不重画视觉。配色、字体、圆角全部沿用现有 `Theme`。
- 不引入第三方导航库。`NavigationStack` + 一个 `@Observable` 就够。
- 不做 5 Tab。移动端 5 个以上就拥挤,而且设置不该占一个永久位置。

---

## 8. 验收与 kill criteria

### 8.1 代码指标(可立刻测)

| 指标 | 现在 | 目标 | 怎么测 |
|---|---:|---:|---|
| widget 深链 | 全部失效 | 4 种全部生效 | `simctl openurl` |
| 到达 NLE 的层级 | 2 | 1 | 手动走查 |
| 并列呈现状态 | 48 | **≤ 10** | `rg '@State private var (is.*Presented\|selected.*)'` |
| 模态调用点 | 27 | ≤ 6 | `rg -c '\.sheet\(\|\.fullScreenCover\('` |
| 返回后现场保持 | 无 | 契约测试 | 单测:push → 改 scroll → pop → 断言 |
| 首屏到"理解无数据原因" | 1 模态 + 1 次猜测 | 0 | 权限关闭冷启动 |

> "48 → 0" 被放宽为 ≤ 10。理由:强求 0 会在目的地还没定的时候就重写 27 处模态调用。
> 剩下的 ≤ 10 应该是纯 UI 开关(如 `isMenuOpen`),不是目的地。

### 8.2 kill criteria(唯一能推翻方案的三条)

**前提**:这个 App 没有产品分析。所以这三条只有在阶段 0b 装好计数器、跑满 2 周基线之后
才成立。**做不到就删掉本节**——留一份没人能检验的验收表,比没有更糟。

| # | 指标 | 判定 | 如果触发 |
|---|---|---|---|
| K1 | 每个"有记录日"的修正次数(NLE 保存 + 区块编辑 + 重分类),分母限 ≥5 记录日的用户 | 4 周内中位数**未**比基线涨 ≥50% | 摩擦不是障碍,用户就是不想改。整个三视图的前提错了,回滚 |
| K2 | 每会话的模式切换中位数 | 4 周内 **< 0.5** | 用户把 TaptionPlan 当地图 App。**不需要 `DayNavigator`**——把时间轴做成地图上的 sheet(它本来就在地图里),跳过整条栈的迁移 |
| K3 | 7 天内打开过 기록 的 WAU 占比 | 4 周内 **< 15%** | 记录并进日历 sheet,不单独维护一个模式 |

**先跑 K2。** 它最便宜,且能取消最贵的工作(整条栈 + 27 处模态迁移)。

**同时预登记成功线**,不要只写失败线。建议:기록 达到 25% 即视为"该保留"。
不预先写成功线,拿到什么数据都会合理化。

### 8.3 一周内可做的零埋点测试

招 8–12 个用户,一个任务:

> "어제 점심이 업무로 잘못 분류됐어요. 고쳐 주세요."(昨天的午饭被误分类成工作,请改正。)

- **现在**:预期多数失败(2 层,无文字图标)。
- **阶段 2 之后的门槛**:10 人里少于 8 人无提示成功,说明时间轴不可发现,模式条没完成它唯一的任务。

这条不需要 SDK,一周出结果,而且测的正是方案的核心假设。

---

## 附录:复现命令

```bash
# 1. 四根支柱的声明
rg -n -A8 'enum RootTab' TaptionPlan/UX/NavigationModels.swift

# 2. 交付的只有地图
rg -n 'legacyUIEnabled' --glob '*.swift' TaptionPlan
rg -n 'ScheduleView\(|ReviewView\(|GoalsView\(|SettingsView\(' --glob '*.swift' TaptionPlan

# 3. 不可达行数
wc -l TaptionPlan/UI/{ScheduleView,ReviewView,SettingsView,GoalsView}.swift

# 4. 并列状态与模态数量
f=TaptionPlan/UI/MapHomeView.swift
rg -c '@State private var is[A-Za-z]*Presented' $f
rg -c '@State private var is[A-Za-z]*Expanded'  $f
rg -c '@State private var selected[A-Za-z]*'    $f
rg -c '\.sheet\(' $f
rg -c '\.fullScreenCover\(' $f

# 5. NLE 编辑器的层级
rg -n 'MapHomeNLEClipEditor\(|MapHomeSectionEditSheet\(' --glob '*.swift' TaptionPlan

# 6. 底栏与抽屉的入口
rg -n 'private var bottomActionBar' TaptionPlan/UI/MapHomeView.swift
rg -n 'private var sidebarContent'  TaptionPlan/UI/MapHomeView.swift

# 7. 权限类别
rg -n -A12 'enum PermissionFeature' TaptionPlan/Core/FeatureModels.swift
```
