# 用户体验架构重构方案

> 本文档回答三个问题:**现在的流程断在哪(有代码证据)、目标架构长什么样、怎么迁移过去。**
> 诊断基于 `0f6988b` + `ARC1024A09` 两个提交后的代码库,所有数字都可以用文中给出的命令复现。

---

## 0. 结论摘要

| 指标 | 现在 | 目标 |
|---|---:|---:|
| 声明的产品支柱 | 4 个 Tab | 3 个视图 + 抽屉 |
| 用户真正能到达的支柱 | **1 个**(地图) | 3 个 |
| 不可达 UI | **20,811 行** | 0 行 |
| 到达"看历史记录"的点击次数 | **不可能** | 1 次 |
| 到达剪辑编辑器(NLE)的层级 | 2 层,靠小图标发现 | 1 层,有名字的按钮 |
| 并列的呈现状态 | 48 个 | 0 个(由栈决定) |
| 模态调用点 | 27 处 | ≤ 6 处(只剩全局覆盖层) |
| 返回后是否保留现场 | 否(每次回到地图) | 是(契约保证) |

一句话:**这个 App 有一个很好的"家"(地图),但没有"门"(导航)。**
四根支柱里三根在代码里存在、在运行时不存在。

---

## 1. 诊断方法

不靠体感。三个来源:

1. **可达性追踪** — 从 `WindowGroup` 往下追,看哪些视图真的会被渲染。
2. **状态清点** — 数呈现状态的数量和形态,判断有没有导航模型。
3. **入口清点** — 对每个目的地,数它的入口数量和层级深度。

复现命令见文末附录。

---

## 2. 五个断点

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

这是最大的断点,而且它不是一个"跳转不畅"的问题:**用户根本走不到"看历史"这件事上。**
一个自动记录生活的产品,如果看不到记录,产品的核心承诺就没有交付。

### B2. 没有导航模型,只有 48 个并列的开关

`MapHomeView` 里:

```
@State 总数                     252
  is*Presented                   19
  is*Expanded                    11
  selected*                      18
.sheet(                          25
.fullScreenCover(                2
```

这 48 个状态彼此独立。它们不构成一棵树,不构成一个栈,只是并排躺在同一个视图里。

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
| 1 | — | 底栏点 **기록** |
| 2 | — | 分段控件点 **주**(周) |
| 3 | **不可达** | 看到上周 |

**这是从"不可能"到"两次点击"。**

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

四个阶段,每个阶段独立可发布,独立可回滚。

### 阶段 1 — 装一条栈(不动 UI)

**做什么**
1. 新增 `DayNavigator`(`UX/DayNavigator.swift`)。
2. 把 27 处模态里"目的地型"的收进 `path`;真正的全局覆盖层(权限、购买、分享、录屏)留在外面,并显式标注 `GlobalOverlay`。
3. 先把 `path` 映射到现有的 sheet 调用,视觉不变。

**为什么安全** 界面一个像素都不改。只是把"48 个布尔"换成"1 个数组",并用现有 sheet 渲染。

**怎么验证** 现有的 756 个测试不动;新增导航测试:push/pop 序列、返回后 `selectedDate` 不变。

**完成标志** `MapHomeView` 的 `is*Presented` 从 19 降到 ≤ 6(剩下的都是纯 UI 开关,如 `isMenuOpen`)。

### 阶段 2 — 三视图模式条

**做什么**
1. 底栏第 1 位换成模式分段控件:`지도 · 타임라인 · 기록`。
2. `ScheduleView` 复活,只接 day 刻度;`ReviewView` 复活,只接 week/month 刻度。
3. 两个视图改为读 `navigator.selectedDate`,不各自持有日期。

**为什么安全** 两个视图本身不改,只是重新接到根上。它们各自已有完整的渲染逻辑和测试。

**怎么验证** 截图对比:同一天在三个视图里的活动条带必须一致(同一份 snapshot)。

**完成标志** 不可达 UI 从 20,811 行降到 0。

### 阶段 3 — 权限内嵌

**做什么**
1. 首屏加"采集状态卡":缺哪个权限、缺了会怎样、一键跳系统设置。
2. 删除 `presentPermissionOnboardingIfNeeded()` 的延迟模态调用。
3. 空状态从"等待位置记录"改成"因为你没给位置权限,所以这里空着"。

**为什么安全** 权限申请逻辑不动,只改**呈现位置**。

**怎么验证** 关闭位置权限冷启动:必须能在首屏一句话内读到原因。

**完成标志** 首屏到"理解为什么没数据"= 0 次点击。

### 阶段 4 — 清理

**做什么**
1. 删除 `legacyUIEnabled` 与 `legacyRootContent` 分支。
2. `AppDetail` 的 14 个 case 归档到 `DayRoute`(逐条对照,不遗漏)。
3. `GoalsView` 的内容拆到计划层与抽屉。

**为什么安全** 前三阶段已经把等价能力搬到新路径,这一步只删旧路径。

**完成标志** `rg 'legacyUIEnabled'` 结果为空。

---

## 7. 权衡:我们放弃什么

诚实地写,因为这个方案有真实代价。

| 放弃的东西 | 代价 | 为什么仍然值得 |
|---|---|---|
| 地图作为唯一入口 | 地图失去"App 的家"的唯一性,变成一个平级视图 | 用户能到达另外两根支柱。可达性 > 仪式感 |
| 四 Tab 的命名 | `루틴` 从支柱降为时间轴的一层 | 例程本质是规则,不是地点。放在偏差旁边才用得上 |
| 21 个 sheet 的独立性 | 收进栈后每个必须声明父级和返回目标 | 这正是"返回"能工作的前提。声明不出来的,说明它本就不该是目的地 |
| 一次性重写的诱惑 | 阶段 1 会让 `path` 与旧 sheet 短暂并存 | 每阶段可独立回滚。20,811 行 UI 不能靠一次提交复活 |

**明确不做的**:
- 不重画视觉。配色、字体、圆角全部沿用现有 `Theme`。
- 不引入第三方导航库。`NavigationStack` + 一个 `@Observable` 就够。
- 不做 5 Tab。移动端 5 个以上就拥挤,而且设置不该占一个永久位置。

---

## 8. 验收

可测的,不是"感觉流畅了"。

| 指标 | 现在 | 目标 | 怎么测 |
|---|---:|---:|---|
| 到达"记录"的点击 | 不可达 | 1 | 手动走查 |
| 到达 NLE 的层级 | 2 | 1 | 手动走查 |
| 并列呈现状态 | 48 | 0 | `rg '@State private var (is.*Presented\|selected.*)'` |
| 模态调用点 | 27 | ≤ 6 | `rg -c '\.sheet\(\|\.fullScreenCover\('` |
| 不可达 UI | 20,811 行 | 0 | 可达性追踪 |
| 返回后现场保持 | 无 | 契约测试 | 单测:push → 改 scroll → pop → 断言 |
| 首屏到"理解无数据原因" | 1 模态 + 1 次猜测 | 0 | 权限关闭冷启动 |

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
