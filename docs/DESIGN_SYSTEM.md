# TaptionPlan 디자인 시스템

> 一天是唯一实体。地圖、時間軸、記錄是同一天的三个投影。
> 这套系统只为这三件事服务：**看见今天、修正今天、确认今天。**

版本 `1.0` · 适用范围 `TaptionPlan/UI` 全量 · 目标 iOS 18+，强制 `.preferredColorScheme(.light)`

---

## 0. 怎么用这份文档

三层，从下往上：

| 层 | 内容 | 谁来改 |
|---|---|---|
| **Token** | `Color.tp*` / `Font.tp*` / `Space.x*` / `Radius.x*` / `Elev.tp*` / `Motion.tp*` | 只在 `Theme.swift` 里改 |
| **Component** | §3 的 22 个组件，每个声明它用哪些 token | 复用，不新造 |
| **Pattern** | §4 的非正常状态 | 只在 §4 里选一个，不自创 |

**一条硬规则：** 任何在 `TaptionPlan/UI` 里新出现的 `.system(size:)`、`cornerRadius: <数字>`、`Color(hex:)`、`padding(<数字>)` 都是回归。加 lint 拦它（§7.4）。

---

## 1. 测量基线

以下数字由脚本在 `0f6988b + ARC1024A09` 之后的树上跑出来，可复现（§7.5）。

| 指标 | 实测 | 说明 |
|---|---:|---|
| `Theme.swift` 语义 token | 71 | 调色板本身是好的 |
| `.system(size:)` 调用 | 506 | 其中字面量 488 · 计算值 18 |
| `.taption(size:)` 调用 | **621** | 全部 +2pt 渲染（见 §2.2.1）· 字面量 589 · 计算值 32 |
| **字体调用合计** | **1,127** | 506 + 621 |
| **其中以字面量传字号** | **1,077** | 下面的分布按这个 1,077 的总体算 |
| **实际渲染字号** | **41 个** | 不是 27 个 |
| 计算出来的字号（无法静态统计） | 50 | `rulerFontSize` · `size * 0.42` · `bold ? 15 : 13` · `SettingsTypography.footnote` |
| 低于 11pt 的调用 | **300（27.9%）** | 低于可读下限 |
| 11–16pt 的调用 | 670（62.2%） | 主体在这里 |
| `cornerRadius` 字面量 | 18 个值 / 281 处 | 2–28 |
| `TaptionRadius` token | 8 个名字，值域 7–14 | 名字是值的同义词 |
| `TaptionSpacing` token | 5 个名字，值域 4–8 | 同上 |
| spacing/padding 字面量 | 467 处 / 20 个值 | 4pt 网格命中率 **40.5%** |
| 2pt 网格命中率 | 330/467 = **70.7%** | 所以网格要用 2pt |
| `Theme.swift` 外的 `Color(hex:)` | 38 个不同值 | — |
| Dynamic Type 支持 | **0 处** | 无 `@ScaledMetric` / `relativeTo:` |
| 动画调用点 | ~20 处 | 时长 0.1–0.25，一个 spring |

**结论：问题不在调色板，在两件事——(a) 存在两个字体 API，其中一个会静默 +2；(b) 所有"scale"其实都是把连续整数起了名字。**

`TaptionSpacing` 的五个名字是 `4,5,6,7,8`。`TaptionRadius` 的八个名字是 `7,8,9,10,11,12,13,14`。这不是 scale，是把每个整数翻译了一遍。所以它们没能减少 sprawl——165 处 `TaptionRadius.*` 和 212 处 `TaptionSpacing.*` 分散在全部八个/五个值上，一个都没淘汰。

**新的命名法：token 名里带值。** `Space.x12` 就是 12pt。`Radius.x16` 就是 16pt。开发者不用查表，也就没有动机再加同义词。

---

## 2. Foundations

### 2.1 Color

#### 2.1.1 语义角色

现有调色板保留，一个色值不改。只补三个**角色**并标注实测对比度。

| Token | HEX | on `tpBackground` | on `tpSurface` | 允许的用途 | 禁止的用途 |
|---|---|---:|---:|---|---|
| `tpInk` | `#3E3320` | 10.33 | 11.46 | 正文、标题、图标 | — |
| `tpSecondary` | `#6B5D43` **↓改** | 5.36 | 5.95 | 次级文字 | 不要当主文字 |
| `tpSecondaryWeak` | `#7A6C50` 现值 | 4.29 | 4.76 | 仅 on `tpSurface`、仅 ≥13pt | **on `tpBackground` 做正文（4.29 < 4.5）** |
| `tpAccent` | `#C65D4D` | 3.46 | 3.84 | **填充、描边、指示器、选中框** | **正文文字（不达标）** |
| `tpAccentText` | `#A8473A` **新增** | 4.84 | 5.40 | 强调文字、链接、可点文字 | — |
| `tpAccentFill` | `#B25445` **新增** | — | 4.59 | **白字的实心按钮**（설정 열기 / 적용 / 저장） | 大面积装饰块 |
| `tpLine` | `#E3D6B8` | 1.20 | 1.34 | 装饰性分隔 | 不要当唯一的控件边界 |
| `tpLineStrong` | `#C6B389` **新增** | 1.72 | — | 需要被"看见"的输入框边界 | 仍不够 3:1，见下行 |
| `tpLineControl` | `#8F8571` **新增** | 3.05 | 3.35 | 输入框/未选中控件的可操作边界（≥3:1） | — |
| `tpHoliday` | `#DB454D` | 3.53 | 3.92 | 日期数字（≥15pt） | 小字正文 |
| `tpSaturday` | `#3D78C4` | 3.75 | 4.16 | 日期数字（≥15pt） | 小字正文 |
| `tpNow` | `#FF3B30` | 2.96 | — | 仅作为 1.5pt 线/2pt 点 | **任何文字** |
| `tpReferenceBlue` | `#2D9BF0` | 2.49 | 2.76 | 仅填充/图标（≥18pt） | **文字（当前 NLE 头部在用它写字）** |
| `tpReferenceRose` | `#F15C80` | 2.67 | 2.96 | 仅填充/图标 | **文字（同上）** |
| `tpReferenceMint` | `#48B38C` | 2.17 | 2.40 | 仅填充 | 文字 |
| `tpReferenceGold` | `#E1C453` | 1.44 | 1.59 | 仅填充 | 文字 |
| `tpReferenceGray` | `#777777` | 3.74 | 4.15 | 仅 ≥15pt | 小字正文 |

**三条由此推出的规则：**

1. **`tpAccent` 是填充色，不是文字色。** 实测 3.46:1，永远达不到 AA 正文。要强调文字用 `tpAccentText`。
2. **`tpReference*` 十色是"标记"色，不是"文字"色。** 全部 <3:1。它们的存在理由是给图标和大色块提供可辨识的色相，不是承载可读性。
3. **`tpLine` 不是控件边界。** 1.20:1 在物理上不可见。它只做视觉节奏。真正需要被识别为"这里有个输入框"的边界用 `tpLineControl`。
4. **`tpAccent` 上不能写白字。** 白 on `tpAccent` = **4.14**，不到 4.5。而全 App 的实心主按钮（`설정 열기` / `적용` / `저장`）都是"`tpAccent` 填充 + 白字"。所以补一个 `tpAccentFill #B25445`（白字 4.95、on `tpSurface` 4.59）——它只比 `tpAccent` 深 8%，色相不变，但白字达标。**主按钮用 `tpAccentFill`，指示器/描边/选中框用 `tpAccent`。**

#### 2.1.2 分类色：三个角色，为什么必须分开

分类色现在有**四套**并存的表：`CanonicalCategoryPalette`（饱和）、`MapHomePastelPalette`（饱和二套）、`RecordTimelinePalette`（29+ 项）、`PlanCategory.color`（pastel）。同一个「업무」在不同视图是 `#2563EB` / `#2E6FDB` / `#0F766E` / `#BEDAE3`。这不是调色板问题，是**没有角色定义**。

定三个角色。全部从 `MapHomePastelPalette` 的色相推导（这是运行时真正用的那套），一个色相三个值：

| 角色 | 用途 | 对比度保证 |
|---|---|---|
| `tpCat(_ id)` | 色条、圆点、图表柱、轨道段、图例键、≤4pt 的指示块 | 无（非文字承载） |
| `tpCatStrong(_ id)` | **分类名文字**、chip 实底、`gap` 的边条 | 白字 ≥4.5 **且** on `tpSurface` ≥4.5 |
| `tpCatWash(_ id)` | **clip block 底**、chip/pill 的淡底（叠在 `tpSurface` 上 30%） | 其上的 `tpInk` ≥6.8 |

实测（`tpCatStrong` 由 `tpCat` 按色相压暗推导，逐色验证过两个方向）：

| id | 한글 | `tpCat` | `tpCatStrong` | 白字 on Strong | Strong on Surface |
|---|---|---|---:|---:|
| `activity` | 활동 | `#43A047` | `#368039` | 4.86 | 4.51 |
| `work` | 업무 | `#2E6FDB` | `#2D6ED8` | 4.86 | 4.50 |
| `study` | 공부 | `#00ACC1` | `#007D8D` | 4.85 | 4.50 |
| `hobby` | 취미 | `#9C4DCC` | `#9B4DCB` | 4.86 | 4.51 |
| `sleep` | 수면 | `#3F3D99` | `#3F3D99` | 8.98 | 8.33 |
| `movement` | 이동 | `#F57C00` | `#B15A00` | 4.87 | 4.51 |
| `eating` | 식사 | `#E5B800` | `#896E00` | 4.86 | 4.51 |
| `exercise` | 운동 | `#D32F2F` | `#D32F2F` | 4.98 | 4.62 |
| `health` | 건강 | `#EC407A` | `#CC3769` | 4.86 | 4.50 |
| `unconfirmed` | 미확인 | `#8D8D8D` | `#717171` | 4.86 | 4.50 |

> **这是本次最严重的一处实测缺陷。** 当前 `MapHomeNLEClipEditor.clipBlock` 用 `MapHomePastelPalette` 原值做底、`.foregroundStyle(.white)` 写字。**10 个分类里 7 个白字不达标**：`activity` 3.30、`study` 2.74、`movement` 2.70、`eating` 1.88、`health` 3.76、`unconfirmed` 3.32，`hobby` 4.83 勉强。其中 `activity`(ink 3.74)、`health`(ink 3.76)、`unconfirmed`(ink 3.72) 连黑字也不达标——这三个色**在任何情况下都不能承载文字**，必须换 `tpCatStrong`。
>
> **修法（已修订，见下）：不要用 `tpCatStrong` 做整块填充。**

**为什么不用"饱和块 + 白字"这个一行修法**

它是达标的，但它是错的。理由有三条：

1. **它把十个色相永久移出无障碍审查范围。** `tpInk` on `tpCatWash` 是 6.85–9.67，**与分类色相无关**——因为底色只有 30% 的色相，亮度由 `tpSurface` 主导。这意味着**以后新增任何分类，都不可能掉进对比度不达标的坑里**。反过来，`tpCatStrong` + 白字把每个未来分类都放进对比度关键路径：加一个色，就要重新验证一遍。这不是审美问题，是**维护成本**问题——一条规则能不能活下去，取决于加新东西时它是否还成立。
2. **同一个 `Day`，两个视图不能有两种颜色。** P1 说하루是唯一实体。기록 视图的分类格是淡底，타임라인 如果是饱和块，用户会以为它们不是同一件事。
3. **色彩体积。** 타임라인 的 137pt lane 里同时站着 11 个 clip。11 个饱和块叠成一根竖柱，读起来是甘特图，不是"我今天做了什么"。这是三条里最弱的一条——它是审美判断，前两条是工程判断。

**所以 clip block 用 wash + 识别边：**

```
fill   = tpCatWash(id)      // tpCat 30% over tpSurface
leading = 4pt tpCat(id)     // 饱和色只出现在这 4pt 上
text   = tpInk
border = 0.8pt tpCat(id) @ 35%
```

饱和色不消失，它退到 4pt 的左边条里——那 4pt 足够识别分类（这正是日历 App 的通行解法），但不构成色彩体积。

实测（`tpCatWash` = `tpCat` **30%** over `tpSurface #FBF6EA`）：

| id | `tpCatWash` | `tpInk` on Wash | wash vs `tpSurface` |
|---|---|---:|---:|
| `activity` | `#C4DCB9` | 8.42 | 1.36 |
| `work` | `#BECEE6` | 7.71 | 1.49 |
| `study` | `#B0E0DE` | 8.55 | 1.34 |
| `hobby` | `#DEC3E1` | 7.68 | 1.49 |
| `sleep` | `#C3BED2` | 6.85 | 1.67 |
| `movement` | `#F9D1A4` | 8.67 | 1.32 |
| `eating` | `#F4E3A4` | 9.67 | 1.19 |
| `exercise` | `#EFBAB2` | 7.27 | 1.58 |
| `health` | `#F6BFC8` | 7.80 | 1.47 |
| `unconfirmed` | `#DAD6CE` | 8.56 | 1.34 |

**为什么是 30%。** 我实测了四档（20 / 26 / 30 / 34）：

| α | 最差 `tpInk` | 最差 wash-vs-surface | 判断 |
|---:|---:|---:|---|
| 20% | 8.22 | 1.12 | 太淡，块读不出"被填充" |
| **30%** | **6.85** | **1.19** | **取这一档** |
| 34% | 6.35 | 1.21 | 已经偏灰，`eating` 开始发脏 |

30% 是唯一同时满足"看起来是实心块"和"`tpInk` 仍 ≥6.8"的一档。20% 时 `eating`/`movement` 的块与背景只有 1.12 的分离，肉眼读成"描边"而不是"填充"。

**wash 到底能不能区分 10 个分类？能，但只在 30%。** 我算了 45 个分类对的 CIELAB ΔE：

| α | 最小 ΔE | 最小的一对 | ΔE<5 的对数 |
|---:|---:|---|---:|
| 14% | **4.0** | `work`/`sleep` | **3 / 45** |
| 30% | **8.3** | `work`/`sleep` | **0 / 45** |

ΔE<5 肉眼不可分。所以 14% 的 wash 不能用来表达分类身份，30% 可以。**注意这里真正的变量是 alpha，不是面积。** 我早先写过"分界线是面积"，那是错的：面积影响的是色彩体积（审美），alpha 影响的是可分辨性（测量）。两者都要满足，但只有 alpha 有阈值可测。

#### 规则 C7：什么时候用 wash，什么时候用中性底 + 4pt 条

这一条必须能在 code review 里**不问我**就判完。所以它不问"多大面积"，只问两件事 —— 都是打开组件就能看见的：

> **① 这个色块的尺寸是不是由数据算出来的？（clip 高度 = 时长 · 比例条宽度 = 占比）**
> **② 色块里面有没有 `Text`？**

| ① 尺寸有意义 | ② 里面有字 | 用什么 | 例 |
|---|---|---|---|
| 是 | 是 | **`tpCatWash` + `tpInk`** | clip block、chip 实底 |
| 是 | 否 | **`tpCat` 实底**（满饱和，**不是** `tpCatStrong`） | 공유 카드 12pt 比例条 |
| 否 | 否（字在中性底上） | **中性底 + 4pt `tpCat` 条** | list row、表格行、图例行 |

**每一条怎么机械判定**（review 时照做，不需要理解意图）：

| 分支 | 判定动作 | 判错的后果 |
|---|---|---|
| 1 | 取 frame 的表达式里有模型值（`duration` / `ratio`）**且**填充形状内部有 `Text` | 误用 strong + 白字 → 10 个分类里 7 个白字不达标（§2.1.2 的实测） |
| 2 | 同上第一个测试，内部**无** `Text` | 误判成 1 → wash 掉数据标记，比例条失去"长度即占比"的语义 |
| 3 | frame 是**常数**（44pt），与数据无关 | 误判成 2 → 整行铺饱和色，一行里四个量级的数字全看起来"和分类有关" |

**state 不是第四种填充 —— 这一点必须写下来，否则两份文档会打架。**

`readOnly`（센서 원본，§3.9）是"无填充"的块，它同时满足 ①（高度=时长）和 ②（里面有字），但没有任何填充。它是**分支 1 的状态修饰**，不是一个新的填充配置：

```
先走 C7 选填充（branch 1 → tpCatWash + tpInk）
再叠 state（readOnly → 去掉填充、留 0.8pt tpCat 描边、文字升到 tpCatStrong）
```

顺序不能反。反过来问会得到"一个没有填充的块该用什么填充"这种无解问题。**C7 只管"底怎么选"，state 只管"底之上怎么变"，两者不重叠。**

**非法配置只有一个：饱和底 + 白字。** 它在 4.86 勉强通过，但每加一个分类就要重测一次白字对比度 —— 这是永久性的维护成本。

为什么这条能替代"面积"：它给出**三个合法配置和一个非法配置**，而不是一个需要裁量的连续量。任何人打开一个组件，看尺寸怎么来、看里面有没有字，就能判。

再补一个选择依据（不是阈值，是意图）：

- 元素的**外延本身有意义**（clip 的高度 = 时长）→ 用填充，因为填充的面积在传达信息。
- 元素是**一组无关值的容器**（一行里并排放着名字、时长、百分比）→ 用中性底 + 条，因为填充的面积不传达任何东西，只是噪音。

list row 之所以是中性底：它一行里有四个不同量级的数字，整条上 wash 会让每个数字都看起来"和分类有关"。不是因为 358pt 太大。

**为什么 wash 优于 strong + 白字（这是首要理由，不是审美）：** `tpInk` 压 `tpCatWash` 是 6.85–9.67，**与分类色相无关**。换成 strong + 白字，每个新分类都要重新测白字是否达标 —— 十个色相永久留在无障碍审查路径上。wash 把色相从这个路径上彻底移走。视觉上"11 块饱和色叠在 137pt 车道里像甘特图"是第三个理由，也是最弱的一个。

**注意最后一列仍然只有 1.19–1.67。** wash 天生低分离度，**所以 wash 块必须带 0.8pt 描边 + 4pt 边条**——这不是装饰，是边界。`eating`(1.19) 尤其依赖描边。

**`tpCatStrong` 仍然只用在两处**：分类名文字（`업무` 标签）和 chip 实底。**无字的比例条用 `tpCat`，不用 `tpCatStrong`。**

为什么这一格必须是 `tpCat` 而不是 `tpCatStrong` —— 三条，第三条是决定性的：

1. **`tpCatStrong` 的定义就是"白字能过 4.5"。** 比例条里没有字，这个定义对它不成立。把它用上去，token 的含义就从"能承载白字的深色"漂移成"重要的填充"，而角色系统就是这样烂掉的。
2. **角色表里 `tpCat` 已经写了"图表柱"。** 比例条就是图表柱，它本来就该在 `tpCat` 这一格。
3. **具体后果：`eating` 会变成两个颜色。** `tpCat(eating)` = `#E5B800`（亮黄），`tpCatStrong(eating)` = `#896E00`（暗橄榄）。分享卡上若用 strong，`식사` 的比例条是暗橄榄，而同一个分类在日历、时间轴、图例里都是亮黄 —— **同一个分类两种颜色，正是 §2.1.2 存在的理由。** 这一条不需要审美判断，看色值就能否掉。

（上一版这一格写成"`tpCat` 实底（`tpCatStrong`）"，把两个不同的 token 并列，读者无法知道该用哪个。这两个值差很远，不能并列。）

**什么时候是 category，什么时候是 state？**

| 是 category | 是 state |
|---|---|
| 表示"这是什么活动" | 表示"这条数据现在怎么样" |
| 업무 / 공부 / 식사 / 이동 / 수면 / 활동 / 취미 / 운동 / 건강 | 미확인 / 확정 / 편집됨 / 센서와 다름 / 읽기전용 |
| 用 `tpCat*` | **不用色相区分**，用 `tpAccent` / `tpInk` 的明度层级 + 形状 |

原因：state 和 category 抢同一个通道（色相）时，用户读不出"这块红色是'运动'还是'出错了'"。所以 **state 永远用明度、描边、角标表达，永不用新色相。**

五个 state 的固定表达：

| state | 表达 | 不依赖颜色也能读 |
|---|---|---|
| `default` | `tpCatWash` 底 + 4pt `tpCat` 左边条 + `tpInk` 字 | ✅ 边条 |
| `selected` | 2.5pt `tpInk` 内描边 + 外扩 1pt 阴影 | ✅ 形状 |
| `dirty`（改过，与传感器不同） | 右上角 4pt `tpAccent` 实心点 + lane header 计数角标 | ✅ 角标 |
| `readOnly`（센서 원본） | 无填充、0.8pt `tpCat` 描边、文字用 `tpCatStrong` | ✅ 空心 |
| `unconfirmed` | 50% 透明底 + 斜纹 checker + `questionmark` 26pt 圆标 | ✅ 纹理 |

**`unconfirmed` 是这套系统里最重要的状态**，因为 `MapHomeGrowthPolicy.qualifies` 要求 `unconfirmedCount == 0` —— 有任何一个未确认区间，当天花园**不长**。所以：

> **规则 C1：** `미확인` 永远是全场对比度最高的元素，且清除它的操作 ≤1 次点击。它不能是"一个安静的小问号"。

#### 2.1.3 禁用组合

| 组合 | 原因 |
|---|---|
| 白字 on `tpCat`（原值） | 7/10 不达标 → 用 `tpCatWash` + `tpInk`（§2.1.2） |
| `tpAccent` 做正文 | 3.46 |
| `tpReference*` 做正文 | 全部 <3.2 |
| `tpSecondary` on `tpBackground` 做 <13pt 正文 | 4.29 |
| `tpLine` 做唯一控件边界 | 1.20 |
| `tpNow` 做任何文字 | 2.96 |
| 在奶油色背景上用 `mapHomeGlass` | 材质只在活地图上成立（§2.5） |

---

### 2.2 Typography

#### 2.2.1 先修一件事：`Font.taption` 会静默 +2

```swift
static func taption(size: CGFloat, weight: Font.Weight = .regular) -> Font {
    .system(size: size + 2, weight: weight)   // ← 写 9 得 11
}
```

621 处调用。`.taption(size: 9)` 渲染成 11pt，`.taption(size: 11)` 渲染成 13pt。**读代码的人无法知道真实字号**，这就是 41 个实际字号被统计成 27 个的原因。

处理：`Font.taption` **标 `@available(*, deprecated, message: "用 Font.tpLabel / tpCaption …；这个 API 会 +2pt")`**，在同一个 PR 里按 §2.2.4 的映射表批量替换，然后删掉。不要保留兼容层——保留它就等于保留两套真相。

#### 2.2.2 阶梯：12 个 token

9 个文字级 + 3 个纯数字级。41 → 12（−71%）。

| Token | size | weight | 行高 | 字距 | 用途 |
|---|---:|---|---:|---:|---|
| `tpDisplay` | 34 | `.bold` | 1.06 | −0.4 | 온보딩 히어로, 하루 카드 제목 |
| `tpTitle` | 22 | `.bold` | 1.14 | −0.3 | 뷰 제목, 시트 제목 |
| `tpHeadline` | 19 | `.bold` | 1.21 | −0.2 | 지표 값, 섹션 제목 |
| `tpSubhead` | 17 | `.semibold` | 1.24 | −0.1 | 날짜 숫자, 카드 값 |
| `tpBody` | 15 | `.regular` | 1.47 | 0 | 본문, 설명 |
| `tpBodyStrong` | 15 | `.semibold` | 1.47 | 0 | 강조 본문, 패널 제목 |
| `tpCallout` | 14 | `.semibold` | 1.36 | 0 | 버튼, 행 제목, 클립 라벨 |
| `tpCaption` | 13 | `.medium` | 1.31 | +0.1 | 목록 보조, 클립 보조 |
| `tpLabel` | 12 | `.semibold` | 1.33 | +0.1 | **最小韩文文字（下限）** |
| `tpMetric` | 26 | `.bold` | 1.00 | −0.5 | 하루 요약 큰 숫자 · **숫자 전용** |
| `tpMeter` | 10 | `.semibold` | 1.20 | +0.2 | 달력 셀 값, 지표 보조 · **숫자 전용** |
| `tpRuler` | 9 | `.semibold` | 1.00 | +0.3 | 시간 눈금, 틱 · **숫자 전용** |

**为什么是这几个数**

- `tpLabel 12` 是韩文下限。11pt 是 Apple 的绝对下限，但韩文音节平均 18 笔，11pt 下 `분류`/`센서` 的横向笔画开始糊。12pt 是实测能稳的最近一档（音节 advance 10.38pt，笔画间隙 ≥1.4pt）。
- `tpBody 15` 而不是 16/17：韩文 15pt 的视觉重量≈拉丁 17pt（音节 0.865em vs 拉丁小写均值 0.5em）。用 17 会让整屏读起来"太大声"，和猫/花园的调性打架。
- `tpMetric 26`：`6시간 12분` 在 26pt 是 90.5pt 宽，能进 2 列指标卡（每列 ~160pt）。34pt 时是 118pt，只能单列。
- 三个数字级低于 11pt 是**故意的**，并且被规则限制死（§2.2.3）。

#### 2.2.3 SwiftUI 表达（含 Dynamic Type）

现在全 App 零 Dynamic Type 支持。`.system(size:)` 是绝对值，不跟随系统字号。修法不能靠 `@ScaledMetric`（要改 1,077 个调用点的结构），用一个静态工厂：

```swift
// Theme.swift

enum TaptionType {
    struct Spec {
        let size: CGFloat
        let weight: Font.Weight
        let relativeTo: UIFont.TextStyle
        /// 固定高度容器里的字号必须封顶，否则撑破轨道。
        let maxScale: CGFloat
    }

    static let display    = Spec(size: 34, weight: .bold,     relativeTo: .largeTitle, maxScale: 2.0)
    static let title      = Spec(size: 22, weight: .bold,     relativeTo: .title2,     maxScale: 2.0)
    static let headline   = Spec(size: 19, weight: .bold,     relativeTo: .title3,     maxScale: 2.0)
    static let subhead    = Spec(size: 17, weight: .semibold, relativeTo: .headline,   maxScale: 2.0)
    static let body       = Spec(size: 15, weight: .regular,  relativeTo: .body,       maxScale: 3.0)
    static let bodyStrong = Spec(size: 15, weight: .semibold, relativeTo: .body,       maxScale: 3.0)
    static let callout    = Spec(size: 14, weight: .semibold, relativeTo: .callout,    maxScale: 2.4)
    static let caption    = Spec(size: 13, weight: .medium,   relativeTo: .footnote,   maxScale: 2.0)
    static let label      = Spec(size: 12, weight: .semibold, relativeTo: .caption1,   maxScale: 1.8)

    // 숫자 전용. 시간축·달력 셀처럼 높이가 고정된 곳에만 쓴다.
    static let metric     = Spec(size: 26, weight: .bold,     relativeTo: .title1,     maxScale: 1.6)
    static let meter      = Spec(size: 10, weight: .semibold, relativeTo: .caption2,   maxScale: 1.35)
    static let ruler      = Spec(size: 9,  weight: .semibold, relativeTo: .caption2,   maxScale: 1.35)
}

extension Font {
    static func tp(_ spec: TaptionType.Spec) -> Font {
        let metrics = UIFontMetrics(forTextStyle: spec.relativeTo)
        let scaled = min(metrics.scaledValue(for: spec.size), spec.size * spec.maxScale)
        return .system(size: scaled, weight: spec.weight, design: .rounded)
    }

    static var tpDisplay: Font    { tp(TaptionType.display) }
    static var tpTitle: Font      { tp(TaptionType.title) }
    static var tpHeadline: Font   { tp(TaptionType.headline) }
    static var tpSubhead: Font    { tp(TaptionType.subhead) }
    static var tpBody: Font       { tp(TaptionType.body) }
    static var tpBodyStrong: Font { tp(TaptionType.bodyStrong) }
    static var tpCallout: Font    { tp(TaptionType.callout) }
    static var tpCaption: Font    { tp(TaptionType.caption) }
    static var tpLabel: Font      { tp(TaptionType.label) }
    static var tpMetric: Font     { tp(TaptionType.metric) }
    static var tpMeter: Font      { tp(TaptionType.meter) }
    static var tpRuler: Font      { tp(TaptionType.ruler) }
}
```

**`.rounded` 是强制的。** 它是这个产品"暖"的主要来源之一——287/506 处已经在用，剩下 219 处是漏网。不要为了"现代"换成默认 SF Pro，那会立刻变成企业面板。

**为什么 `maxScale` 不是无限：** 时间轴的轨道高度由 `GeometryReader` 算出，`MapHomeTimeSidebarMath.verticalInset = 28` 是常量。字号涨 3 倍而轨道不变，标签会互相压。所以：

> **规则 T1：** `tpRuler` / `tpMeter` 的 `maxScale` 锁 1.35。超过 AX1 后，时间轴不靠放大字号解决可读性，而是**在 AX 尺寸下把 3 条 lane 折成 1 条**（见 §5.2）。数字永远是辅助，名字才是信息。

#### 2.2.4 迁移映射（41 个实际字号 → 12 个 token）

按调用量排序。`.` 后面的数字是 `.taption` 的值（实际 +2）。

| 现在（实际 pt） | 调用数 | → token | 变化 |
|---|---:|---|---|
| 11 | 162 | `tpLabel` | 12 → **+1** |
| 12 | 135 | `tpLabel` | 0 |
| 13 | 113 | `tpCaption` | 0 |
| 10 | 96 | `tpMeter`（数字）/ `tpLabel`（韩文） | 韩文 **+2** |
| 14 | 84 | `tpCallout` | 0 |
| 9.5 | 69 | `tpRuler`（数字）/ `tpLabel`（韩文） | 韩文 **+2.5** |
| 10.5 | 64 | `tpMeter`（数字）/ `tpLabel`（韩文） | 韩文 **+1.5** |
| 15 | 53 | `tpBody` | 0 |
| 16 | 41 | `tpSubhead` | +1 |
| 12.5 | 38 | `tpCaption` | +0.5 |
| 11.5 | 37 | `tpLabel` | +0.5 |
| 9 | 35 | `tpRuler`（数字）/ `tpLabel`（韩文） | 韩文 **+3** |
| 17 | 23 | `tpSubhead` | 0 |
| 20 | 18 | `tpHeadline` | −1 |
| 18 | 15 | `tpHeadline` | +1 |
| 22 | 13 | `tpTitle` | 0 |
| 8 | 12 | `tpRuler`（数字）/ `tpLabel`（韩文） | 韩文 **+4** |
| 8.5 | 7 | `tpRuler` | +0.5 |
| 19 | 6 | `tpHeadline` | 0 |
| 26 | 5 | `tpMetric` | 0 |
| 14.5 | 5 | `tpCallout` | −0.5 |
| 9.2 / 9.8 / 10.2 / 10.8 / 8.8 | 15 | `tpRuler` / `tpMeter` | ≤1 |
| 21 | 10 | `tpTitle` | +1 |
| 23 / 24 / 25 / 27 | 6 | `tpMetric` | ±2 |
| 30 / 34 / 36 / 38 | 9 | `tpDisplay` | −4 ~ +4 |
| 5 / 9.3 / 13.5 / 15.5 / 16.5 / 29 | 6 | 逐个人工判断 | — |

**需要人工过一遍的 4 个聚集点**（韩文从小字变大，会撞容器）：

1. `MapHomeTimeSidebar` 的 `reviewMarker` 计数角标（9pt → `tpRuler` 保持数字）
2. `MapHomeCalendarSheet.dayCell` 的 `cellValueText`（10pt → `tpMeter`，内容是 `6:12` 这种拉丁数字，安全）
3. `MapHomeNLEClipEditor.laneTitle`（9pt 韩文 → `tpLabel` 12pt）。实测 `센서 원본` 12pt = 44.7pt，lane 宽 75pt，**放得下**，不用 `minimumScaleFactor`
4. `MapHomeView.bottomBarButton` 的 10pt 标签（`현재 위치` 4 音节）→ `tpLabel` 12pt = 45.6pt，6 格底栏每格 ~60pt，**放得下**

#### 2.2.5 韩文度量（实测，SF Pro Rounded / Apple SD Gothic Neo）

音节 advance = **0.865em**，拉丁小写均值 ≈0.5em。**同字号下韩文宽 1.7 倍。**

| 문자열 | 9pt | 11pt | 12pt | 13pt | 15pt | 17pt |
|---|---:|---:|---:|---:|---:|---:|
| `지도` | 15.6 | 19.0 | 20.8 | 22.5 | 25.9 | 29.4 |
| `타임라인` | 31.1 | 38.1 | 41.5 | 45.0 | 51.9 | 58.8 |
| `대분류` | 23.4 | 28.5 | 31.1 | 33.7 | 38.9 | 44.1 |
| `센서 원본` | 33.7 | 41.1 | 44.7 | 48.4 | 55.7 | 62.9 |
| `상세활동` | 31.1 | 38.1 | 41.5 | 45.0 | 51.9 | 58.8 |
| `하루 요약` | 33.7 | 41.1 | 44.7 | 48.4 | 55.7 | 62.9 |
| `클립 편집` | 33.7 | 41.1 | 44.7 | 48.4 | 55.7 | 62.9 |
| `전체 보기` | 33.7 | 41.1 | 44.7 | 48.4 | 55.7 | 62.9 |
| `위치 기록을 기다리는 중` | 85.5 | 104.1 | 113.4 | 122.6 | 141.0 | 159.3 |
| `09:00–12:40` | 59.2 | 70.9 | 76.5 | 82.1 | 93.1 | 103.7 |
| `6시간 12분` | 42.5 | 51.4 | 55.8 | 60.2 | 68.8 | 77.3 |

> **规则 T2：** 排版前先量。韩文标签宽度 ≈ `字数 × 0.87 × 字号`。一个 12pt 的 4 字标签要预留 **42pt**，不是 24pt。
>
> **规则 T3：** 不要在韩文上依赖 `minimumScaleFactor` 来"救"布局。`0.7` 会把 12pt 压到 8.4pt，正好落回不可读区。要么改文案，要么改布局。

---

### 2.3 Spacing

2pt 网格。20 个实测值 → 12 个 token，**命中 433/467 = 92.7%**。

```swift
enum Space {
    static let hair: CGFloat = 1    // 헤어라인 구분선 (1/displayScale 와 함께)
    static let x2:  CGFloat = 2
    static let x3:  CGFloat = 3     // 아이콘-텍스트 간격
    static let x4:  CGFloat = 4
    static let x6:  CGFloat = 6
    static let x8:  CGFloat = 8
    static let x10: CGFloat = 10
    static let x12: CGFloat = 12
    static let x16: CGFloat = 16
    static let x20: CGFloat = 20
    static let x24: CGFloat = 24
    static let x32: CGFloat = 32
}
```

| 现值 | 处数 | → | 变化 |
|---|---:|---|---|
| 0 | 75 | `0` | — |
| 2 | 59 | `x2` | 0 |
| 8 | 54 | `x8` | 0 |
| 3 | 48 | `x3` | 0 |
| 10 | 45 | `x10` | 0 |
| 1 | 30 | `hair` | 0 |
| 12 | 24 | `x12` | 0 |
| 9 | 23 | `x10` | +1 |
| 4 | 22 | `x4` | 0 |
| 6 | 19 | `x6` | 0 |
| 5 | 15 | `x4` 或 `x6` | ±1 |
| 14 | 13 | `x16` | +2 |
| 16 | 12 | `x16` | 0 |
| 13 | 9 | `x12` | −1 |
| 11 | 7 | `x12` | +1 |
| 7 | 4 | `x8` | +1 |
| 18 | 4 | `x16` 或 `x20` | ±2 |
| 20 / 22 / 1.5 | 4 | `x20` / `x24` / `x2` | ≤2 |

**为什么不是 4pt 网格：** 4pt 只能命中 40.5%，意味着 278 处要挪 1–2pt。这个 App 的信息密度是靠 2/3/6pt 撑起来的（clip block 间距、lane gap、ruler tick），挪到 4pt 会把时间轴撑松、把菜单行撑高。**2pt 网格是这套 UI 的真实基准，承认它比纠正它有用。**

**四条规则：**

- **S1** 组件内间距 ≤ `x8`；组件之间 `x12`–`x20`；区块之间 `x24`+。
- **S2** 横向页面边距固定 `x16`（现在是 14/16/18/20 混用）。
- **S3** 44pt 是**命中区**，不是视觉尺寸。视觉 26pt 的按钮用 `taptionTouchTarget` 扩到 44（已存在，保留）。
- **S4** 不要用 `Spacer(minLength: 0)` 当间距用。它会让 VStack 的语义高度不可预测。

---

### 2.4 Radius

18 个值 → **5 个 + `Capsule`**。

```swift
enum Radius {
    static let x4:  CGFloat = 4    // 틱, 레일 세그먼트, 서브클립, 마이크로 칩
    static let x8:  CGFloat = 8    // 칩, 태그, 소형 컨트롤
    static let x12: CGFloat = 12   // 컨트롤, 필드, 셀, 리스트 카드
    static let x16: CGFloat = 16   // 카드, 클립 블록, 글래스 패널
    static let x22: CGFloat = 22   // 레일 패널, 드로어, 히어로
    // 알약·원형은 RoundedRectangle 이 아니라 Capsule()/Circle()
}
```

| 现值 | 处数 | → | 变化 |
|---|---:|---|---|
| 14 | 37 | `x16` | +2 |
| 10 | 26 | `x12` | +2 |
| 12 | 17 | `x12` | 0 |
| 13 | 12 | `x12` | −1 |
| 18 | 11 | `x22` | +4 |
| 9 | 9 | `x8` | −1 |
| 22 | 8 | `x22` | 0 |
| 15 | 8 | `x16` | +1 |
| 4 | 7 | `x4` | 0 |
| 20 | 6 | `x22` | +2 |
| 11 | 6 | `x12` | +1 |
| 16 | 5 | `x16` | 0 |
| 6 | 4 | `x8` | +2 |
| 5 | 4 | `x4` | −1 |
| 3 | 4 | `x4` | +1 |
| 28 | 3 | `x22` | −6 |
| 2 | 3 | `x4` | +2 |
| 8 | 2 | `x8` | 0 |

**一条替代查表的规则：**

> **规则 R1：圆角跟元素的短边成比例，不跟它的语义成比例。**
> 短边 ≤20pt → `x4`/`x8`（或 `Capsule`）
> 短边 20–40pt → `x8`/`x12`
> 短边 >40pt → `x12`/`x16`
> 满宽面板/抽屉 → `x22`

这条规则的存在意义：让开发者**不需要记住"card 是 14 还是 12"**。旧的 `TaptionRadius` 用 8 个名字（`tight/small/control/field/compact/panel/tile/card`）去命名 7–14 这 8 个相邻值，人眼分辨不出 `panel`(12) 和 `tile`(13)，所以命名没有产生任何约束力——165 处调用均匀铺在全部 8 个值上，一个都没被淘汰。

**保留例外：** `MapHomeNLEClipEditor.clipBlock` 的 `cornerRadius: 9` → `x8`。9 和 8 在 24pt 高的块上没有区别，但 9 不在网格上。

---

### 2.5 Elevation & Glass

现在阴影是 4 组随手写的值（`black@0.05 r7 y2`、`black@0.08 r3 y1`、`black@0.16 r3 y1`、`tpSky@0.16 r4 y2`）。定 4 级：

```swift
enum Elev {
    /// 흐름 안에 있는 것. 그림자 없음.
    static let e0 = ShadowSet(color: .clear, radius: 0, y: 0)
    /// 칩, 작은 카드, 떠 있는 pill.
    static let e1 = ShadowSet(color: .black.opacity(0.05), radius: 4, y: 1)
    /// 레일, 액션 바, 지도 위 컨트롤.
    static let e2 = ShadowSet(color: .black.opacity(0.06), radius: 10, y: 3)
    /// 드로어, 모달, 토스트.
    static let e3 = ShadowSet(color: .black.opacity(0.12), radius: 20, y: 8)
}
```

| 层 | 用于 |
|---|---|
| `e0` | 列表行、日历格、时间轴内的 clip、菜单行 |
| `e1` | chip、pill、달력 셀 선택 원, 작은 카드 |
| `e2` | 시간 레일 패널、지도 컨트롤 버튼、모드 바 |
| `e3` | 드로어、시트、토스트、권한 카드 |

**Glass 规则（只有一条）：**

> **规则 E1：`mapHomeGlass` 只允许出现在活地图上方。**

理由：`mapHomeGlass` 是 `.glassEffect(.regular)` / `.ultraThinMaterial` —— 它取的是**背后内容的颜色**。背后是奶油色 `tpBackground` 时，材质返回一层灰蓝，在暖色系里立刻显脏。

现状违例：`MapHomeView.sidebarContent` 的状态胶囊（约 8432 行）在抽屉内部、背景是 `tpSurface`，用了 `mapHomeGlass(in: Capsule())`。改成 `Color.tpSurface` + `e1` + `tpLine` 描边。

| 允许 | 禁止 |
|---|---|
| `dateBadge`（地图上方）✅ | 抽屉内的胶囊 ❌ |
| `mapControls` 按钮（地图上方）✅ | 日历 sheet 内的卡片 ❌ |
| `MapHomeTimeSidebar` 轨道面板（地图上方）✅ | NLE 编辑器内的任何东西 ❌ |
| 权限卡（地图上方）✅ | 设置/菜单行 ❌ |

---

### 2.6 Motion

实测只有 ~20 处，时长 0.1–0.25，一个 spring。定 5 个：

```swift
enum Motion {
    static let instant  = Animation.linear(duration: 0.10)                                    // 상태 플립, 틴트
    static let fast     = Animation.easeOut(duration: 0.18)                                   // 칩, 선택 테두리
    static let standard = Animation.easeInOut(duration: 0.22)                                 // 모드 전환, 시트 detent
    static let emphasis = Animation.spring(response: 0.30, dampingFraction: 0.85)             // 드로어, 날짜 배지 펼침
    static let tracking = Animation.linear(duration: 0.12)                                    // 연속 제스처 추종
}
```

**两条规则：**

> **规则 M1：离散点击用 spring/ease；连续手势用 `tracking` 或无动画。**
> 指南针旋转（`compassRotationDegrees`）已经在用 `.linear(0.12)`，正确。拖 clip、拖 handle、捏合缩放**不要**加 easeOut——缓动会让手指和内容脱节。

> **规则 M2：尊重 `accessibilityReduceMotion`。** 所有 `emphasis` 在 reduce-motion 下退化成 `standard`，`standard` 退化成无动画。`MapHomeView` 现在有 3 处 `withAnimation` 没有检查这个 flag。

---

## 3. Components

22 个（原 22 个；`weekBars` 삭제, `unconfirmedChoice`·`share.card` 추가 — §3.14·§3.15·§3.23）。每个给：**职责 / 解剖 / 状态 / token / 출처**。

命名格式见 §6：`tp.<group>.<name>`（文档用），Swift 侧用 `TP<Group><Name>`。

### 3.0 准入规则：没有출처的组件不进系统

**每一条组件必须写明它在 `TaptionPlan/UI` 里的真实调用点**（文件 + 行号）。写不出来的，不进这套系统。

理由不是洁癖。这套系统唯一的目的是**统一已经在跑的界面**。如果允许"以后可能会用到"的组件混进来，那么 `legacyUIEnabled = false` 后面的 20,811 行就会通过组件库重新进入产品 —— 而没有任何人会在看组件库的时候想起那 20,811 行。`weekBars`（§3.14）就是这么混进来的：它是 `ReviewView` 的周尺度图表，被写成了通用组件。

三条执行规则：

1. **출처 写不出来 → 删。** 不是"标注为待定"，是删。需要的时候再加，加的时候自然有출처。
2. **출처 只算 `TaptionPlan/UI` 里 `legacyUIEnabled == true` 路径上的视图。** `ScheduleView` / `ReviewView` / `GoalsView` / `SettingsView` 里的实现**不算출처** —— 它们编译得到，但跑不到。
3. **출처가 죽으면 컴포넌트도 죽는다.** Phase 4에서 화면을 지우면, 그 화면만 쓰던 컴포넌트를 같이 지운다.

---

### 3.1 `tp.map.dateBadge` — 날짜 배지

**출처** `MapHomeView.swift` → `dateBadge` (살아있음)

**职责** 显示选中日期，是"哪一天"的唯一常驻锚点。点一下展开本周，双击回今天。

**解剖**
```
HStack(spacing: Space.x6)
 ├ [weekStrip]        조건부, 7 × 34pt
 └ ZStack             width = 44, height = 40, Radius.x22, mapHomeGlass
    ├ Text(weekday)   tpRuler(9) .semibold, 색 = 요일 규칙
    └ Text(day)       tpSubhead(17) .bold, .monospacedDigit, tpInk
```

**状态** `collapsed` / `expanded`(weekStrip 표시) / `selected`(오늘 아님) / `today`(액센트 링)

**Token** `Space.x6`, `Radius.x22`, `mapHomeGlass`, `tpSubhead`, `tpRuler`, `tpInk`, `tpHoliday`, `tpSaturday`, `Motion.emphasis`

**요일 색 규칙（한국）：** 토 `tpSaturday` / 일·공휴일 `tpHoliday` / 평일 `tpInk`。当前实现把 토요일写成 `tpReferenceBlue`(#2D9BF0)，和 `tpSaturday`(#3D78C4) 两个值并存——统一到 `tpSaturday`。

---

### 3.2 `tp.map.weekStrip` — 주간 날짜 줄

**출처** `MapHomeView.swift` → `weekStrip` (살아있음)

**解剖** 7 × `VStack(spacing:0){ 요일 tpRuler / 날짜 tpSubhead }`，每格 34×`weekStripHeight-8`，`Radius.x12`。

**状态** `idle` / `selected`（`tpSaturday.opacity(0.22)` 底 + `Radius.x12`）/ `today` / `holiday`

**Token** `tpSubhead`, `tpRuler`, `Radius.x12`, `tpSaturday`, `tpHoliday`

**注意** 当前选中底用的是 `tpReferenceBlue.opacity(0.22)`（2.49:1 的蓝），在奶油底上偏冷。换 `tpSaturday.opacity(0.22)` 或 `tpAccent.opacity(0.14)`。

---

### 3.3 `tp.map.marker` — 집 · 고양이 · 정원

**출처** `MapHomeView.swift` → `MapHomeStickmanMarker` + `MapHomeGrowthPolicy.artworkName(level:)` (살아있음)

**职责** 情绪钩子。它是这个产品区别于"数据面板"的全部。

**解剖** 三种，共享一个 44pt 命中区：
| 마커 | 视觉 | 状态 |
|---|---|---|
| `house` | 屋顶 `tpAccent` / 몸통 `tpSurface` / 창 `tpSky` / 문 `tpSecondary`，104×104 | `closed` / `open`(하루 요약 시트 열림) / `noHome`(점 미설정, 흐림 0.45) |
| `cat` | 26×24, 몸통 `#F0C987`, 1pt `tpSecondary` 윤곽 | `idle`(정지) / `walking`(재생 중) / `sleeping`(야간) |
| `garden` | 366 단계 아트워크 `HomeEvolution001…366` | `seed`(L1–30) / `sprout`(31–120) / `grown`(121–300) / `full`(301–366) |

**Token** `tpAccent`, `tpSurface`, `tpSky`, `tpSecondary`, `Space.x4`, `Elev.e2`

> **规则 M3（花园）：** 花园只在 `qualifies` 为真时生长 —— 即当天 `actualCount > 0` **且** `unconfirmedCount == 0`。所以"未确认"不是一个中性的技术状态，它**阻断情绪回报**。UI 必须在当天存在未确认区间时，让花园处于可见的"等待"态（半透明 + 一个 `tpAccent` 的 1pt 虚线圈），而不是完全不动。

---

### 3.4 `tp.map.sideRail` — 지도 좌측 컨트롤 레일

**출처** `MapHomeView.swift` → `mapSideRails` / `mapControls` (살아있음)

**职责** 地图自身的操作：검색 / 현재 위치 / 나침반 / 확대 / 축소。

**解剖** `VStack(spacing: Space.x10)`，每个按钮 44×44（`Elev.e2` + `mapHomeGlass` + `Circle`），图标 15pt `tpInk`。

**状态** `default` / `pressed`(scale 0.94, `Motion.fast`) / `active`(따라가기 중, `tpAccent` 채움) / `disabled`(opacity 0.35) / `locating`(`ProgressView` 15pt)

**Token** `Space.x10`, `mapHomeGlass`, `Elev.e2`, `tpInk`, `tpAccent`, `Motion.fast`

---

### 3.5 `tp.map.contextActionRow` — 맥락 액션 줄

**출처** `MapHomeView.swift` → `bottomActionBar` (살아있음)

**职责** 当前视图相关的动作，**不改变"你在哪"**。这是 `bottomActionBar` 的替代物：原来的 7 个按钮全部是对当前视图的操作，一个都不导航。

**解剖** `HStack(spacing:0)`，每格 `maxWidth: .infinity`，`minHeight: 44`，图标 20pt + 标签 `tpLabel`，容器 `Color.tpSurface` + `Elev.e2`，高 56。

**状态** `default` / `active`(재생 중 → `pause.fill` + `tpAccent`) / `unavailable`(opacity 0.35, `accessibilityValue` 说明原因)

**Token** `tpLabel`, `tpInk`, `tpSecondary`, `tpAccent`, `Elev.e2`, `Space.x4`

> **规则 C2：** 底栏第一格固定是 `tp.modeSwitch`（§3.6）。其余格是 context action。**任何 context action 都不得改变 `mode`**。

---

### 3.6 `tp.modeSwitch` — 지도 · 타임라인 · 기록

**출처** **신규.** 살아있는 구현 없음 — `docs/UX_ARCHITECTURE.md` §4의 3-시점 전환이 아직 안 만들어졌다. 기존 코드에 3분할 전환 컨트롤이 없다(확인함). **이건 감사 결과가 아니라 신규 설계다.**

**职责** 三个投影的切换器。**它不是 Tab**（P2：换视角不是导航）。切换时 `selectedDate` 不变、每个 mode 各自记住滚动/缩放位置、push 栈回到该 mode 的根（`UX_ARCHITECTURE.md` §4.4）。

**解剖**
```
HStack(spacing: Space.x4)  ← 3 段等宽
 └ VStack(spacing: Space.x3)
    ├ Image 17pt
    └ Text   tpLabel(12)
  选中态: 底 tpAccent.opacity(0.07), Radius.x12, 前景 tpAccent
  未选中: 前景 tpSecondary
```

**状态** `map` / `timeline` / `record` × (`selected` | `idle`)

**Token** `tpLabel`, `tpAccent`, `tpSecondary`, `Radius.x12`, `Space.x3/x4`, `Motion.standard`

**必须做的两件事：**
1. 三段都要有文字（P4：主入口必须有名字，不能只有图标）。
2. `accessibilityValue` 报告当前 mode，`accessibilityAddTraits(.isSelected)` 给选中段。

---

### 3.7 `tp.timeRail` — 타임라인 축 (압축형, 지도 안)

**출처** `MapHomeTimeSidebar.swift` → 사이드바 레일 (`MapHomeTimeSidebarMath`, `trackCenterX`) (살아있음)

**职责** 地图右侧那条 44pt 的时间轴。它是 **3 lane 模型的 1 lane 压缩**——不是另一个东西。`MapHomeTimeSidebar` 里已经是这样（`activeRailWidth: 7` 的彩色轨道 + `rulerNumericColumnWidth: 32` 的数字列 + `handleLaneWidth: 69` 的把手列）。

**解剖**（实测尺寸，全部保留）
```
총 폭 113pt = handleLane 69 + railWidth 44
  handleLane 69 : 선택 시각 카드 + 트림 핸들 (44×44, Radius.x22)
  railWidth 44  : activeRail 7pt (Radius.x4) + numericColumn 32 + trailing 5
  verticalInset 28 (상하)
  trackHeight = railHeight - 56
```

**상태**
| 상태 | 표현 |
|---|---|
| `default` | `tpCat(id).opacity(0.94)` 轨道段 |
| `now` | 1.5pt `tpNow` 横线 + 右侧时间胶囊 |
| `selected` | 44×44 把手，`tpSurfaceCream` 底 + `#D94772` 字（现 `deepPinkHex`，保留） |
| `unconfirmed` | `tpCat.opacity(0.50)` + `MapHomeUnconfirmedChecker` 斜纹 + 26pt 问号圆标 |
| `empty` | `tpBackground.opacity(0.62)` 轨道 + §4.3 空态 |
| `zoomed` | `zoomDurations = [1440, 720, 360, 180, 60]` 五档，`tpRuler` 刻度密度随之变 |

**Token** `tpCat`, `tpNow`, `tpSurfaceCream`, `Radius.x4/x22`, `tpRuler`, `Space.hair`, `mapHomeGlass`, `Elev.e2`

> **规则 C3：** `unconfirmed` 的问号标必须 ≥26pt 命中 44pt，且 `accessibilityLabel` 写明区间和"몇 개 중 몇 개"。现在的实现是 `"미확인 구간 \(count)개 선택"`，正确，保留。

---

### 3.8 `tp.timeline.lanes` — 3 lane 타임라인 (타임라인 모드)

**출처** `MapHomeTimeSidebar.swift` → 3-lane 타임라인 + `MapHomeNLEClipEditor.swift` → `lanes` (살아있음)

**职责** 把 3.7 的 1 lane 展开成 3 lane。**这是 타임라인 mode 的主体**，从 `MapHomeTimeSidebar` 长出来，不是从 `ScheduleView`。

**解剖**（复用 NLE 的比例，因为两者是同一个信息模型）
```
gutter 36 (시각 눈금)
main   44%  ← 대분류 (편집 가능)
sensor 24%  ← 센서 원본 (읽기 전용)
detail 32%  ← 상세활동
gap 5, 카드 Radius.x16, 테두리 tpLine
```
폭 390 화면 / 여백 `Space.x16`×2 → 358 → gutter 36, gap 10 → usable 312 → main 137 / sensor 75 / detail 100。
`센서 원본` 12pt = 44.7pt < 75 ✅ —— **lane 제목을 9pt에서 12pt로 올릴 수 있다.**

**상태** 3.7 与 3.9 的并集，加 lane 级状态：
| lane | 상태 |
|---|---|
| 대분류 | `default` / `selected` / `dirty` / `editing` |
| 센서 | **永远 `readOnly`**。不可点，不可拖。`accessibilityHint("센서 원본은 수정할 수 없습니다")` |
| 상세 | `default` / `selected` |

**Token** `Space.x16/x5`, `Radius.x16`, `tpLine`, `tpLabel`, `tpCat*`

---

### 3.9 `tp.clip` — 클립 블록

**출처** `MapHomeNLEClipEditor.swift` → `clipBlock` (살아있음, 단일 출처)

**职责** 一个时间段。整个产品的原子。

**解剖**
```
ZStack(alignment: .topLeading)
 ├ RoundedRectangle(Radius.x8).fill(tpCatWash(id))        ← 옅은 바탕
 ├ RoundedRectangle(Radius.x8).stroke(tpCat(id).opacity(0.34), 0.8)   ← 경계
 ├ Rectangle().fill(tpCat(id)).frame(width: 4)            ← 정체성 띠 (좌측)
 ├ VStack(alignment: .leading, spacing: Space.x2)
 │   ├ Text(title)  tpCallout(13~14) .bold .foregroundStyle(tpInk)
 │   └ Text(range)  tpMeter(10) .opacity(0.70)            ← blockHeight ≥ 27 일 때만
 └ [selected] VStack{ trimHandle(top); Spacer; trimHandle(bottom) }
```

**상태**
| 상태 | 채움 | 좌측 띠 | 경계 | 각도 |
|---|---|---|---|---|
| `default` | `tpCatWash` | 4pt `tpCat` | `tpCat@0.34` 0.8pt | — |
| `selected` | `tpCatWash` | 4pt `tpCat` | **2.5pt `tpInk`** | — |
| `dirty` | `tpCatWash` | 4pt `tpCat` | 동상 | 우상단 5pt `tpAccent` 점 |
| `readOnly`(센서) | **없음** | 없음 | `tpCat@0.58` 0.8pt | — |
| `gap`(미확인) | `tpCatWash(unconfirmed)` + 135° 사선 | 4pt `tpCatStrong(unconfirmed)` | 동상 | `?` 24pt (테두리 1.5pt `tpInk`) |
| `disabled` | 上 + opacity 0.45 | — | — | — |

> **`readOnly`는 채움 선택이 아니라 상태 변형이다.** C7(§2.1.2)로 채움을 먼저 고른 뒤(branch 1 → `tpCatWash` + `tpInk`), `readOnly`가 그 채움을 제거하고 0.8pt `tpCat` 외곽선 + `tpCatStrong` 글자로 바꾼다. 순서를 뒤집으면 "채움이 없는 블록은 무슨 채움을 쓰나"라는 답 없는 질문이 된다.

**Token** `tpCatWash`, `tpCat`, `tpCatStrong`, `tpInk`, `Radius.x8`, `tpCallout`, `tpMeter`, `Space.x8/x5/x2`, `Elev.e1`

**내용 접기 임계값（실측）**

| blockHeight | 보이는 것 | 근거 |
|---|---|---|
| `< 18` | **띠 + 바탕만. 글자 없음** | 13pt 행높이가 안 들어간다. 억지로 넣으면 글자가 세로로 잘린다 |
| `18–27` | 카테고리명만 (13pt) | 한 줄은 들어간다 |
| `≥ 27` | 카테고리명 + 시간 범위 (10pt) | 두 줄 |
| `width ≤ 34` | 글자 없음 | 한글 두 자가 안 들어간다 |

> **`< 18`에서 글자를 자르지 마라.** 지금 `MapHomeNLEClipEditor`는 9.7pt 블록에 라벨을 넣어 `이동`의 절반이 잘려 나온다. 차라리 안 보여주는 게 낫다 — 4pt 띠가 이미 "여기 15분짜리 이동이 있다"를 말하고 있다.

> **규칙 C4（개정）:** 블록에 글자를 얹을 때 채움은 `tpCatStrong`이 아니라 **`tpCatWash` + `tpInk`** 다. `tpCatStrong` 위 백색은 4.86으로 겨우 통과하지만, 137pt 레인에 11개가 쌓이면 채도 부피가 시스템을 차갑게 만든다. `tpCatWash` 위 `tpInk`는 6.85–9.67로 두 배 여유가 있다. §2.1.2 참조.

### 3.10 `tp.clip.trimHandle` — 자르기 손잡이

**출처** `MapHomeNLEClipEditor.swift` → `trimHandle` (살아있음)

**解剖** `RoundedRectangle(Radius.x4)`，高 5，**`tpSurface` 底（不是纯白）**，`tpInk.opacity(0.25)` 0.8pt 描边，内嵌 `Capsule` 16×2 `tpInk.opacity(0.60)`，水平 padding `Space.x8`，垂直 `Space.x2`。

> 原来是纯白 `#FFFFFF`。在 `tpCatStrong` 的饱和底上白是可见的；换成 `tpCatWash` 之后白与底的对比只有 1.1–1.3，**手柄会消失**。所以必须改成 `tpSurface` + 深色描边 + 深色内条。

**状态** `idle` / `dragging`（`Motion.tracking`）/ `disabled`（块高 <22 时不显示）

**Token** `Radius.x4`, `tpInk`, `Space.x5/x2`, `Motion.tracking`
**A11y** `accessibilityLabel` = `"시작 자르기"` / `"끝 자르기"`（已实现，保留）；加 `accessibilityValue` 报当前分钟。

---

### 3.11 `tp.hourRuler` — 시간 눈금

**출처** `MapHomeTimeSidebar.swift:1173-1504` → `rulerTickWidth` / `rulerFontSize(_:)` (살아있음)

**解剖** `Canvas` 绘制：整点 1pt `tpInk.opacity(0.14)`，半点 0.6pt `tpInk.opacity(0.06)`；标签 `tpRuler(9)` `.monospacedDigit`，右对齐，`tpSecondary`。

**状态** `hourOnly`（zoom ≥360분）/ `tenMinute`（zoom <360）/ `minuteTicks`（zoom =60）

**Token** `tpRuler`, `tpInk`, `tpSecondary`, `Space.hair`
**A11y** 刻度是纯装饰 → `.accessibilityHidden(true)`。时间信息由 clip 的 `accessibilityValue` 承载。

---

### 3.12 `tp.calendar.grid` — 월간 그리드 (기록 모드)

**출처** `MapHomeCalendarSheet.swift` → `monthGrid` / `dayCell` (살아있음)

**职责** 기록 mode 的主体。从 `MapHomeCalendarSheet` 长出来（它已经是月格 + 每日时间/次数/距离合计 + 平均值）。

**解剖**
```
LazyVGrid(7 columns, spacing: Space.x7)      ← 실측 7
  셀 = (358 - 42) / 7 = 45.1 × 38
    Text(day)        tpSubhead(17) .monospacedDigit, 32×28 원
    [selectedKind]  Text(cellValue) tpMeter(10)   ← "6:12" 같은 라틴 숫자
    [!selectedKind] 4pt 점 (log status)
```

**상태（셀）**
| 상태 | 표현 |
|---|---|
| `idle` | 날짜 `tpInk`，로그 점 `tpInk.opacity(0.3)` |
| `selected` | 32pt `Circle` `tpAccent` 实心 + 白字 |
| `today` | 1.5pt `tpAccent.opacity(0.65)` 圆环 |
| `holiday` / `sunday` | 날짜 `tpHoliday` |
| `saturday` | 날짜 `tpSaturday` |
| `hasLog.complete` | 4pt 点 `tpAccent` |
| `hasLog.incomplete` | 4pt 点 `tpAccent.opacity(0.35)` + 见 §4.2 |
| `noLog` | 点 `tpInk.opacity(0.18)` |
| `future` | 日期 `tpSecondary`，无点 |
| `outsideMonth` | `Color.clear`（现在是空 `Color.clear`，保留） |

**Token** `Space.x7`, `tpSubhead`, `tpMeter`, `tpAccent`, `tpHoliday`, `tpSaturday`, `Radius` 不需要（Circle）

> **规则 C5：** 日格里的数字是拉丁数字（`cellText` 返回 `"6:12"` / `"45m"`），所以 `tpMeter` 10pt 合法。**但如果哪天改成 `"6시간 12분"`，10pt 下是 47pt 宽 > 45.1pt 格宽，会触发 `minimumScaleFactor(0.7)` 压到 7pt。** 保持拉丁格式。

---

### 3.13 `tp.calendar.dayTotals` — 일 합계 지표

**출처** `MapHomeCalendarSheet.swift` → `timePanel` (살아있음)

**解剖** `VStack(alignment:.leading, spacing: Space.x10)`，`Radius.x12`，`tpSurface`，`tpLine.opacity(0.9)` 0.8pt 描边。
```
Text(kind.title)   tpBodyStrong(15)
Text(panelText)    tpMetric(26) .bold, tint
HStack(2pt){ 일별 막대 30개, 높이 44 }
  + 평균선: 1/displayScale, tint.opacity(0.5)
HStack{ 이번 달 합계 / 하루 평균 }
```

**상태** `hasData` / `noData`(값 `—`，막대 2pt 最小) / `loading`(§4.1)

**Token** `tpBodyStrong`, `tpMetric`, `tpCaption`, `tpSurface`, `Radius.x12`, `tpLine`, `Space.x10`

---

### 3.14 ~~`tp.record.weekBars` — 주간 막대~~ **삭제됨**

**이 컴포넌트는 삭제했다.** 초안에 7 列 주간 막대가 있었는데, 출처를 확인한 결과 **살아있는 화면에 구현이 없다.**

- 7 列·주 단위 선택·`partial`(그 주가 아직 안 끝남) 상태는 `ReviewView`의 `model.reviewScale == .week` + `chartBuckets: [RecordChartBucket]`(`ReviewView.swift:31`, `:391-495`, `:2781`)와 정확히 일치한다. `ReviewView`는 `legacyUIEnabled = false` 뒤의 죽은 화면이다.
- 살아있는 표면에서 여러 날을 보는 곳은 **§3.12 월간 그리드 + §3.13 일 합계**다. 7 列 막대는 그 자리에 들어갈 자리가 없고, `일요일` 열 라벨은 하루짜리 표면에서 의미가 없다.

이 항목을 지운 이유를 남겨 두는 게 지우는 것보다 중요하다. **죽은 화면의 컴포넌트가 살아있는 시스템으로 들어오는 경로가 바로 이것이다** — 아무도 컴포넌트 목록에서는 옛 계획을 찾지 않는다. §3.0 참고.

> 만약 나중에 "주 단위로 본다"는 요구가 실제로 생기면, 그때는 §3.12를 확장할지 새로 만들지를 **먼저 결정**한다. 지금은 만들지 않는다.

---

### 3.15 `tp.unconfirmedChoice` — 미확인 분류 선택 칩

> **이 자리에는 초안에 `tp.record.listRow`(4pt 색조각 + 이름 + 메타)가 있었다. 출처가 없어 삭제했다** — 살아있는 코드에 그런 행이 없다. §3.0의 규칙("출처를 못 쓰면 삭제")을 내 초안에도 적용한 결과다.
>
> **같은 역할을 하는 살아있는 표면은 여기 있다:** `MapHomeTimeSidebar.swift:2288-2318`, "미확인 활동" 목록의 분류 칩. 이건 그냥 목록 행이 아니라 **규칙 C1이 말하는 "1회 탭으로 미확인을 해소하는" 그 버튼**이다. 시스템에서 가장 중요한 인터랙션이므로 컴포넌트로 승격한다.

**출처** `MapHomeTimeSidebar.swift:2288-2318` (미확인 활동 → 분류 선택)

**解剖**
```swift
Label(category.localizedTitle(language), systemImage: category.systemImage)
    .font(.system(size: 11, weight: .semibold))
    .lineLimit(1)
    .minimumScaleFactor(0.72)          // ← 7.9pt까지 줄어든다
    .frame(maxWidth: .infinity, minHeight: 36)
    .background(category.tint.opacity(0.18), in: Capsule())
```
`List` + `.listRowBackground(Color.tpSurface)`

**상태** `default` / `saving`(`savingSegmentID != nil` → 전체 비활성) / `saved`(`confirmedSegmentIDs` 삽입) / `failed`(`saveFailedSegmentID` → 하단에 `저장하지 못했습니다` 12pt red)

**현재 구현에서 고칠 것 3가지 (전부 실측)**

| 문제 | 현재 | 고칠 값 | 근거 |
|---|---|---|---|
| **글자가 7.9pt까지 줄어든다** | 11pt + `minimumScaleFactor(0.72)` | `tpLabel` 12pt, `minimumScaleFactor` **삭제** | 12pt가 한글 하한(§2.2.5). 0.72를 걸면 `반려동물`·`봉사·커뮤니티`가 7.9pt가 되는데, 이건 Apple 최소(11pt)보다 작다 |
| **히트 영역 36pt, `contentShape` 없음** | `minHeight: 36`, `.buttonStyle(.plain)`, 배경 `Capsule` | `frame(minHeight: 44)` + **`.contentShape(Rectangle())`** | §5.3.1. 표적은 **정확히 36pt** (행 inset은 히트 영역을 늘리지도 줄이지도 않는다). 8pt 모자란 것보다 중요한 건 **`contentShape`가 없다는 것** — 같은 파일이 6곳에서 쓰고 있다(`:1261, :1353, :1574, :1605, :1783, :1809`). 6개 반례가 있는 누락이다 |
| **wash가 경계선** | `tint.opacity(0.18)` | `0.30` | 18%는 최소 ΔE 5.1(`work`/`sleep`)로 겨우 갈린다. 30%는 8.3. §2.1.2 |

**Token** `tpCatWash(0.30)`, `tpInk`, `tpLabel(12)`, `Capsule`, `Space.x12`, `taptionTouchTarget`

**后果链（这是它为什么比其他缺陷更重要）**

```
7.92pt 라벨  →  36pt 표적  →  오탭
             →  unconfirmedCount가 0이 되지 않는다
             →  MapHomeGrowthPolicy.qualifies == false
             →  그날 정원이 자라지 않는다
             →  감정적 보상이 아무 피드백 없이 사라진다
```

하나의 접근성 결함이 **제품 결함**이 되는 지점이 여기다. 다른 44pt 미달은 "불편"이지만, 이 컨트롤의 미달은 **게임 루프가 조용히 멈추는 것**이다.

> **규칙 C1의 집행 지점.** `MapHomeGrowthPolicy.qualifies`는 `unconfirmedCount == 0`을 요구한다 — 미확인이 하나라도 있으면 그날 정원이 자라지 않는다. 이 칩이 그 상태를 지우는 유일한 수단이므로, **이 칩은 44pt이고 글자가 절대 줄어들지 않아야 한다.** 다른 어떤 컴포넌트보다 우선한다.

---

### 3.16 `tp.nle.header` — 클립 편집 헤더

**출처** `MapHomeNLEClipEditor.swift:98` → `header` (살아있음)

**解剖** `HStack`，`minHeight: 44`。
```
Button(닫기)   tpCallout(14) .semibold, 前景 tpAccentText(← 지금 tpReferenceRose 2.67)
               padding H Space.x16, minHeight 38, Capsule, 底 tpAccent.opacity(0.10)
VStack(spacing: Space.hair)
  Text(클립 편집)      tpHeadline(19) .bold
  Text(대분류 · 센서 원본 · 상세활동)  tpLabel(12) .semibold, tpSecondary
Button(적용)   tpCallout(14) .bold, .white on tpAccentText, Capsule
```

**상태** `clean`(적용 비활성 opacity 0.45) / `dirty`(적용 활성) / `saving`(`ProgressView` `.tint(.white)`)

**Token** `tpCallout`, `tpHeadline`, `tpLabel`, `tpAccentText`, `tpSecondary`, `Space.x16`, `Radius` → Capsule

> **必须改：** `닫기` 现在用 `tpReferenceRose`(2.67:1) 写字，`적용` 用 `tpReferenceBlue`(2.49:1) 做底配白字(4.14)。两个都不达标。`닫기` → `tpAccentText`，`적용` 底 → `tpAccentText`。

---

### 3.17 `tp.nle.laneHeader` — 레인 제목

**출처** `MapHomeNLEClipEditor.swift:198` → `laneTitle(_:width:)` (살아있음)

**解剖** `HStack(spacing: Space.x5)`，gutter 36 空位 + 3 个 `Text`，`tpLabel(12)` `.bold` `tpSecondary`。
`대분류` 右侧可挂 dirty 计数角标：`tpRuler(9)` `.bold` `tpAccent`，`tpAccent.opacity(0.14)` 底，`Capsule`。

**상태** `idle` / `hasDiff`(角标 `\(differingSegmentCount)`)

**Token** `tpLabel`, `tpRuler`, `tpSecondary`, `tpAccent`, `Space.x5`, `Capsule`
**改动** 9pt → 12pt（实测放得下，§3.8），移除 `minimumScaleFactor(0.7)`。

---

### 3.18 `tp.nle.selectionSummary` — 선택 요약

**출처** `MapHomeNLEClipEditor.swift` → `selectionSummary` (살아있음)

**解剖** `HStack(spacing: Space.x8)`, `height: 26`。
```
色点 10pt Circle
Text(title)   tpCallout(14) .bold
Text(range)   tpCaption(13) .semibold, tpSecondary
[dirty] Button(센서 \(title))  ← 되돌리기 pill, tpAccentText on tpAccent.opacity(0.12)
Text(playhead) tpCaption(13) .bold .monospacedDigit, tpAccent
```

**상태** `none`(`클립을 고르세요`) / `clip` / `clip.dirty` / `pick`(센서 또는 상세에서 집어 든 상태) / `gap`(`미확인` pill)

**Token** `tpCallout`, `tpCaption`, `tpAccentText`, `tpAccent`, `tpSecondary`, `Space.x8`, `Capsule`

---

### 3.19 `tp.nle.applyBar` — 툴바 + 적용

**출처** `MapHomeNLEClipEditor.swift:626` → `toolbar` (살아있음)

**解剖** `HStack(spacing: Space.x8)`, `height: 44`。
`categoryMenu`（Capsule, `tpCallout`）· `가르기` · `지우기` · `되돌리기` · `다시` · `Spacer` · `전체 보기`
图标按钮 = 44×44 命中，图标 17pt。

**상태** `enabled`(`tpInk`) / `disabled`(opacity 0.35) / `active`(`tpAccent`)

**Token** `tpCallout`, `tpInk`, `tpAccent`, `Space.x8`, `Capsule`, `Motion.fast`

---

### 3.20 `tp.nle.zoom` — 확대/축소

**출처** `MapHomeTimeSidebar.swift` → `MapHomeTimeSidebarMath.zoomDurations` (살아있음)

**解剖** 捏合（`MagnifyGesture`）+ 双击轨道（重置）+ `전체 보기` 按钮。
`minuteHeight` 从 `2.4`（全天下）到 `24`（10 分钟窗）。

**상태** `fit`(全天下) / `zoomed` / `zooming`（`Motion.tracking`，无缓动）

**Token** `Motion.tracking`
**A11y** 捏合不可用于 VoiceOver → `accessibilityAdjustableAction` 在轨道上提供 `increment/decrement` 切换 `zoomDurations` 五档。

---

### 3.21 `tp.drawer` — 드로어

**职责** 配置与例行。**不是导航器。**

**解剖**
```
폭 min(max(viewport × 0.72, 260), 300)
배경 tpSurface, 우측 1pt tpLine, Elev.e3
헤더: Text(오늘의 기록) tpTitle + 닫기 44pt
그룹: Text(제목) tpRuler(9)→tpLabel(12) .tpSecondary .letterSpacing(0.04)
      카드 Radius.x12, tpBackground, 행 구분 Space.hair tpLine
행:   HStack(spacing: Space.x10), padding Space.x12, minHeight 44
      아이콘 22pt tpAccentText + Text(tpCaption 13)
```

**상태** `closed` / `opening`(`Motion.emphasis`) / `open` / `scrim`(`tpInk.opacity(0.22)`)

**그룹（4 个，实测自 `MapHomeView.swift:8375-8400`）** 기록 / 화면 / 연결 / 앱 —— **不要新增"浏览"类分组**。

| 그룹 | 행 | 코드 |
|---|---|---|
| 기록 `Record` | 위치 · 분류 | `:8377`, `:8379` |
| 화면 `View` | 표시 · 언어 | `:8383`, `:8385` |
| 연결 `Connections` | Apple Watch | `:8389` |
| 앱 `App` | 설정 · 알림 · 하루 카드 · 지도 출처 | `:8393-8399` |

> **초안 정정:** 초안은 `기록 / 루틴 / 화면 / 앱`이라고 적었다. **`루틴`은 드로어에 없다.** `루틴`은 죽은 `GoalsView`의 개념이고, 살아있는 드로어의 세 번째 그룹은 `연결`(`appleWatchMenuItem`)이다. 이건 작은 오타가 아니라 §3.0이 말한 누수의 또 다른 사례다 — 옛 정보 구조가 컴포넌트 명세로 들어온 것.
>
> 드로어 하단에는 그룹 밖 요소가 셋 더 있다: `PRO` 항목(`:8404`, `TaptionCommercePolicy.supportsPaidPurchase`일 때만), **현재 위치 상태 캡슐**(`:8417-8432`), 앱 버전 푸터(`:8437`). 상태 캡슐이 `mapHomeGlass(in: Capsule())`를 쓰고 있는데, 이게 크림색 바탕 위 유리라 §2.1 규칙 위반이다 — Phase 2에서 `tpSurface` + 1pt `tpLine`으로 바꾼다.

**Token** `tpSurface`, `tpBackground`, `Radius.x12`, `Elev.e3`, `tpTitle`, `tpLabel`, `tpCaption`, `tpAccentText`, `Space.x10/x12`, `Motion.emphasis`

---

### 3.22 `tp.sheet` — 시트

**출처** `MapHomeCalendarSheet.swift` → `presentationDetents` (살아있음)

**解剖** `presentationDetents`（现有 `.height(contentHeight + 16)` + `.large`），`presentationDragIndicator(.visible)`，`presentationBackground(tpBackground)`，`Radius.x22` 顶角。

**状态** `detent.small` / `detent.large` / `dismissing`

**Token** `tpBackground`, `Radius.x22`, `Motion.standard`
**规则** 一个 sheet 内**不得再开 sheet**（现状 `MapHomeCalendarSheet` 内还有 2 个 `.sheet`）。要下钻就 push `DayRoute`。

---

### 3.23 `tp.share.card` — 공유 카드

**출처** `MapHomeCalendarSheet.swift:2509-2600` (`side = 540`, `BOKKI Plan`)

**为什么必须单独成组件：** 这是全 App 唯一一张**会被公开发布**的图。用户在 앱 里看到的偏差可以容忍，发到 SNS 上的偏差会一直存在，而且脱离了 App 的上下文——没有工具提示、没有后续交互、没有重试。**它是产品视觉的最高风险面，而不是最不重要的一面。**

**解剖**（固定 540×540，`padding 36`）
```
배경  지도 모드: 경로 지도 스냅샷 scaledToFill + tpBackground.opacity(0.72) 스크림
      기본 모드: LinearGradient(tpBackground → tpSurface, topLeading → bottomTrailing)
헤더  dateText    34pt .bold  .rounded        = tpDisplay
      weekdayText 18pt .semibold .rounded    = tpSubhead
      stickman    96×96
지표  최대 4개 stat()  (제목 12pt / 값 14pt)
분류  최대 5행: 아이콘 22 · 이름 16pt semibold (w90) · 캡슐 바 h12 · 시간 14pt · % 15pt bold
푸터  "BOKKI Plan" 14pt .bold  tpAccent   +   부제 12pt .medium  tpSecondary
```

> **출처 정정: 배경은 사용자 사진이 아니라 경로 지도다.** `MapHomeDailyCardSheet`의 `mapImage`는 `Self.routeMap(points: baseData?.routePoints ?? [])`(`MapHomeCalendarSheet.swift:2782`)가 그린 **경로 지도 스냅샷**이다. 사용자가 고른 사진을 배경으로 쓰는 경로는 코드에 없다. 이 구분이 중요하다: 지도는 대체로 밝지만 **위성/야간 스타일에서는 어두워질 수 있고**, 그때 아래 문제가 그대로 발생한다. 위험은 실재하지만, "아무 사진이나"는 과장이다.

**`entry.tint` 实底 캡슐 바는 여기서 옳다.** 바 위에 글자가 없다 — §2.1.2의 `tpCat` 역할(정체성만, 글자 없음)에 정확히 해당한다. 단 **반드시 정규 램프(`tpCat`)에서 와야 한다.** 지금은 `entry.tint`가 어느 팔레트인지에 따라 달라져서, 사용자가 앱에서 본 색과 게시된 카드의 색이 다를 수 있다.

**두 가지 고칠 것 (실측)**

**1. 어두운 지도 위에서 `tpSecondary`가 무너진다.**

스크림은 `tpBackground` 72%다. 지도가 어두울수록 결과 바탕이 어두워진다:

| 지도 바탕 | 스크림 결과 | `tpInk` | `tpSecondary` `#7A6C50` (현행) | `#6B5D43` (개정안) |
|---|---|---:|---:|---:|
| 순수 검정 | `#AFA89A` | 5.23 | **2.17** | **2.72** |
| 진회색 `#333` | `#BDB7A8` | 6.18 | **2.57** | **3.21** |
| 중간 회색 `#666` | `#CCC5B7` | 7.20 | **2.99** | **3.74** |
| 흰색 | `#F6F0E1` | 10.87 | 4.52 | 5.64 |

즉 **야간 지도 스타일에서 부제(`자동 기록으로 만든 하루`)와 요일이 안 읽힌다.** 스크림을 올려도 안 된다 — `tpSecondary #7A6C50`은 **alpha 1.00, 즉 지도를 완전히 덮어도 4.29**다. 스크림으로는 해결할 수 없는 문제다.

> **규칙 C8: 배경을 안다고 가정하는 글자색을, 배경을 모르는 면 위에 쓰지 않는다.**
>
> 공유 카드에는 **`tpSecondary`를 쓰지 않는다.** 보조 톤은 **크기와 굵기로만** 표현한다(`tpInk` 유지). `tpInk`는 순수 검정 지도에서도 5.23으로 통과한다. 이건 스타일 선택이 아니라, 게시된 이미지는 고칠 수 없기 때문에 생기는 제약이다.

**1-b. 그리고 이건 공유 카드만의 문제가 아니다.** 위 표의 마지막 줄이 핵심이다: `tpSecondary #7A6C50`은 **`tpBackground` 위에서 4.29**다 — 이미지도, 스크림도, 지도도 없는 **앱의 기본 바탕에서 이미 4.5 미만**이다. `tpSurface` 위에서는 4.76으로 겨우 넘는다. 즉 현행 `tpSecondary`는 본문 보조 텍스트 기준을 앱 전역에서 못 맞춘다.
>
> 그래서 `#6B5D43`으로의 개정은 취향이 아니라 **적합성 수정**이다(`tpBackground` 위 5.36 / `tpSurface` 위 5.95). §2.1 표의 그 행에 이 근거를 적어 둔다.

**2. `"BOKKI Plan"` 14pt bold가 `tpAccent`(3.46)다.** 14pt bold는 large text라 3:1은 넘지만, 공개 이미지에는 여유를 두고 `tpAccentText`(4.84)를 쓴다.

**Dynamic Type: 여기서는 적용하지 않는다.** `side = 540` 고정 캔버스에 절대 pt로 그린다. `tpDisplay`/`tpSubhead`를 스케일하면 레이아웃이 깨지고, 어차피 결과물은 이미지라서 사용자의 글자 크기 설정이 의미가 없다. **이 컴포넌트는 타입 스케일에서 스케일링만 opting out 한다 — 크기 값은 그대로 쓴다.** (이건 §2.2.3의 `Font.tp()`에 `scales: false` 인자가 필요한 유일한 곳이다.)

**Token** `tpCat`(바), `tpInk`(모든 글자), `tpAccentText`(푸터), `tpBackground`/`tpSurface`(배경·스크림), `tpDisplay`, `tpSubhead`, `Radius.x12`

---

## 4. 非正常状态

这是现在最弱的地方，也是这套系统最该硬的地方。五种，各有固定形态。**不允许自创第六种。**

### 4.1 `loading` — 읽는 중

**原则** 只在**首次**读取时出现。刷新不出现骨架屏（会闪）。

```
骨架: RoundedRectangle(Radius.x8).fill(tpInk.opacity(0.06))
      .overlay(shine: tpSurface.opacity(0.5) 从 -1 到 +1, Motion.linear(1.2) 반복)
```
- 时间轴：3 条 lane 各 4 个占位块，高度按上一帧的真实分布（不留白）。
- 日历：42 个 45×38 圆角块。
- 超过 **400ms** 才显示；短于 400ms 直接出内容（避免闪）。

**禁止**：`ProgressView()` 居中占满屏幕。它不告诉用户在等什么、等多久。

**Token** `tpInk.opacity(0.06)`, `Radius.x8`, `Motion.linear`

### 4.2 `empty` — 기록이 없음

**原则** 说清楚"这里本来该有什么"和"它怎么才会出现"。

```
VStack(spacing: Space.x12)
  Image(systemName:)  44pt, tpInk.opacity(0.18)
  Text(제목)          tpBodyStrong(15), tpInk
  Text(설명)          tpCaption(13), tpSecondary, 最多 2 行, 居中, 宽 ≤ 260
  [Button(행동)]      tpCallout, tpAccentText on tpAccent.opacity(0.10), Capsule
```

| 场景 | 제목 | 설명 | 행동 |
|---|---|---|---|
| 오늘 아직 아무것도 없음 | `아직 오늘의 기록이 없어요` | `센서가 하루를 읽기 시작하면 여기에 시간이 쌓입니다.` | 없음 |
| 그 날 기록 없음 | `이 날은 기록이 없어요` | `기록이 있는 날은 달력에 점이 표시됩니다.` | `오늘로 이동` |
| 검색 결과 없음 | `조건에 맞는 기록이 없어요` | — | `조건 지우기` |

### 4.3 `blocked` — 권한이 없어서 비어 있음

**这是最重要的一条。** 现在它显示 `위치 기록을 기다리는 중` —— 一个沉默的灰点，让用户以为"再等等就有了"。实际上**永远不会来**。

**必须区分：**

| | `empty`（4.2） | `blocked`（本节） |
|---|---|---|
| 原因 | 还没有数据 | 不可能有数据 |
| 语气 | 中性、未来时 | 明确、现在时、可操作 |
| 图形 | 灰图标 | 灰图标 + `tpAccent` 的 `exclamationmark` 角标 |
| 必有 | 一句描述 | **一句原因 + 一个按钮** |

```
VStack(alignment: .leading, spacing: Space.x8)
  Label(위치 권한이 꺼져 있어요, systemImage: "location.slash.fill")
    tpBodyStrong(15), tpAccentText
  Text(이 권한이 없으면 지도에 오늘의 이동이 그려지지 않습니다.)
    tpCaption(13), tpSecondary, 最多 2 行
  Button(설정 열기)  tpCallout, .white on tpAccentText, Capsule, minHeight 36
  배경: tpAccent.opacity(0.06), Radius.x12, 1pt tpAccent.opacity(0.18)
```

**10 类权限的中文/韩文原因句（必须写死，不能拼接）：**

| 권한 | 이유 문장 |
|---|---|
| 위치 | `이 권한이 없으면 지도에 오늘의 이동이 그려지지 않습니다.` |
| 정확한 위치 | `대략 위치만으로는 장소를 구분할 수 없어 방문 기록이 뭉칩니다.` |
| 동작 및 피트니스 | `걷기·뛰기·이동 수단을 구분하려면 필요합니다.` |
| 건강 | `수면과 운동은 건강 앱에서만 읽을 수 있습니다.` |
| 캘린더 | `일정과 약속이 하루에 나타나지 않습니다.` |
| 사진 | `사진이 찍힌 장소와 시각이 기록에 붙지 않습니다.` |
| 알림 | `기록이 끊겼을 때 알려드릴 수 없습니다.` |
| 스크린타임 | `앱 사용 시간이 공부·업무 구간에 반영되지 않습니다.` |
| 마이크 | `소리로 장소를 추정하는 기능을 쓸 수 없습니다.` |
| 클라우드 | `기기를 바꾸면 기록이 이어지지 않습니다.` |

**规则：** `blocked` 卡出现在**首屏**，不是模态。关掉它 = 承认地图是空的但知道为什么。

### 4.4 `error` — 읽지 못했음

**原则** 区分"暂时失败"和"需要人处理"。

| 类型 | 形态 | 例子 |
|---|---|---|
| `transient` | 顶部 1 行 inline banner，`tpWarningTint` 底，`tpInk` 字，右侧 `다시 시도` | 날씨 갱신 실패 |
| `persistent` | 区块内 4.2 的形态，图标换 `exclamationmark.triangle`，`tpAccentText` | 동기화 실패 |
| `fatal` | 整页，`tpDisplay` 标题 + 原因 + `다시 시작` | 스냅샷 손상 |

**禁止**：`print` 到控制台然后静默留白。现在有 3 处 `try?` 吞掉错误后返回空数组，UI 显示成"今天没数据"——这和 4.2 的 `empty` 撞了，用户无法区分。

### 4.5 `locked` — 결제가 필요함

**原则** 先展示价值，再要求付费。锁定态必须**看得见内容形状**。

```
ZStack
 ├ 실제 콘텐츠 (blur 6pt, opacity 0.55, .allowsHitTesting(false))
 └ VStack(spacing: Space.x8)  ← 居中
    Image("lock.fill") 20pt tpAccentText
    Text(제목)        tpBodyStrong(15)
    Text(설명)        tpCaption(13) tpSecondary
    Button(구매)      tpCallout, .white on tpAccentText, Capsule
  底: tpSurface.opacity(0.92), Radius.x12
```

**状态** `preview`（可看不可用）/ `exhausted`（试用结束）/ `restoring`（`ProgressView`）

**规则：** `TaptionCommercePolicy.supportsPaidPurchase == false` 时**不渲染任何锁定 UI**，不要显示一个点了没反应的锁。

---

## 5. Accessibility

### 5.1 Dynamic Type

现在 0 支持。`Font.tp*` 全部走 `UIFontMetrics`（§2.2.3）。三档行为：

| 尺寸 | 行为 |
|---|---|
| `xSmall`–`large`（默认） | 完全按阶梯 |
| `xLarge`–`xxxLarge` | 文字级放大，数字级封顶 1.35。时间轴 3 lane 比例不变 |
| `AX1`–`AX5` | **时间轴从 3 lane 折成 1 lane**（只留 대분류），其他 lane 变成 clip 上的 1 行 subtitle。日历格从"日期+值"折成"日期"，值移到选中后的 `dayTotals` 面板 |

理由：3 lane 在 AX3 下每 lane 只剩 30pt 宽，`센서 원본` 要 44.7×2.4 = 107pt。折成 1 lane 不是妥协，是唯一正确的答案。

### 5.2 对比度

全部实测（§2.1.1 / §2.1.2）。三条硬门槛：

1. **文字 ≥4.5:1**（≥19pt bold 可放宽到 3:1）
2. **控件边界 ≥3:1** —— 输入框、未选中开关、可点击的圆角框
3. **纯装饰 ≥1.2:1** —— 只有 `tpLine` 属于这一类

### 5.3 44pt 命中区

`TaptionMenuMetrics.minimumHitSize = 44` 已存在，`taptionTouchTarget` 已存在。**保留，并扩展使用范围：**

| 元素 | 视觉 | 命中 |
|---|---|---|
| `bottomBarButton` | 26pt 图标 + 12pt 标签 | 44 ✅ |
| `dateBadge` | 44×40 | 44 ✅ |
| `reviewMarker` | 26pt 圆 | 44 ✅ |
| `trimHandle` | 5pt 高 | **44 ❌ 现在是 5** |
| `dayCell` | 45×38 | 38 ❌ → 用 `contentShape` 扩到 44 |
| `mapControl` | 44 | 44 ✅ |

`trimHandle` 是最严重的：5pt 高、22pt 宽的可拖控件。必须用 `taptionHitOutset(horizontal: 11, vertical: 19.5)` 扩到 44×44，否则几乎不可拖。

> **删掉了一行：`weekBar` 柱。** 上一版这里写着「`weekBar` 柱 · 整列 `contentShape`」。**这个组件不存在** —— 它是 `weekBars`（§3.14，已删）的一部分。曾经想把它改名成 `dayTotals` 的日柱，但那些柱子**不是可交互的**：`MapHomeCalendarSheet.swift:609-611` 是 `RoundedRectangle` + `.frame(height:)`，没有 `onTapGesture`、没有 `Button`、没有 `contentShape`。把一个纯展示元素塞进命中区表格，就是再造一次 `weekBars`。
>
> **但这里有一个真的前向风险，值得记下来：** 那 30 根柱子是在约 330pt 里排开的，**每根约 2pt 宽**。今天它们只负责显示，所以不是命中区问题；一旦有人给它们加上点选（"点某天跳到那天"是极可能的下一步），2pt 宽就是全 App 最糟的命中目标，而且会比 `trimHandle` 更糟，因为 30 个目标互相重叠。真要加，必须做**列级** `contentShape`（整条 44pt 高、按 index 均分宽度），不是给每根柱子加 padding。

#### 5.3.1 `List` 안에서는 "행"이 표적이 아니다

44pt 规则说的是**控件自己的 frame**，不是它所在的行。在 `List` 里这两件事会分开，所以规则要写清楚，否则没法执行：

- `listRowInsets`（系统默认值）**不会缩小控件**，它只是让控件的可点区域**无法伸进 inset 区**。所以"整行可点"是做不到的，"控件自己有 44pt"是能做到的。
- `.listRowBackground` **不增加命中区**，它只画背景。
- `tpListStyle()`（`Theme.swift:502-507`）只设 `scrollContentBackground` / `background` / `tint`，**从不碰 `listRowInsets`**。所以**不要假设任何 `List` 是通栏的**。

因此在 `List` 里做 44pt，必须同时满足两条：

```swift
Label(...)
    .frame(maxWidth: .infinity, minHeight: 44)   // ① 控件自己 ≥44
    .contentShape(Rectangle())                    // ② 整个 frame 可点
```

缺 ② 时，命中区会退回到字形边界（`.buttonStyle(.plain)` + 背景色尤其如此），44pt 的 frame 只是画得大，点不到。

> **为什么这条必须写下来：** `MapHomeTimeSidebar.swift` 自己在 **6 处**用了 `.contentShape(Rectangle())`（`:1261, :1353, :1574, :1605, :1783, :1809`）。也就是说这个文件已经知道该怎么做，而 `unconfirmedChoice`（§3.15）是它内部唯一的例外。**这不是风格分歧，是遗漏，而且有 6 个反例。** 反例存在与否，是"发现"和"意见"的分界线。

### 5.4 VoiceOver（韩文标签，图标型控件必须有）

| 控件 | `accessibilityLabel` | `accessibilityValue` | `hint` |
|---|---|---|---|
| 메뉴 버튼 | `메뉴` | — | `기록 설정과 앱 설정을 엽니다` |
| 날짜 배지 | `날짜 10월 24일 토요일` | — | `한 번 누르면 이번 주, 두 번 누르면 오늘로 이동` |
| 모드 전환 (3 段) | `지도` / `타임라인` / `기록` | `선택됨` | `같은 날을 다른 각도로 봅니다` |
| 타임라인 클립 | `업무, 09:00부터 12:40까지, 3시간 40분` | `센서와 다름` 또는 `센서와 같음` | `두 번 탭하여 편집` |
| 미확인 마커 | `미확인 구간 3개` | — | `두 번 탭하여 분류를 고릅니다` |
| 자르기 손잡이 | `시작 자르기` | `09시 00분` | `위아래로 밀어 조절` |
| 시간 레일 | `하루 시간 축` | `06시부터 24시까지` | `조절 가능` |
| 지도 컨트롤 | `현재 위치` | `위치 사용 가능` / `위치 없음` / `위치 찾는 중` | — |
| 드로어 행 | `루틴 편집` | — | — |
| 적용 | `적용` | `변경 사항 3개` | `센서 원본에 반영합니다` |

**规则：** 图标型控件的 label 必须是**动作或对象**，不是图标名。`house.fill` → `집`，不是 `하우스 필`. 现在 `bottomBarButton` 已经传 `title` 做 label，正确。

### 5.5 Reduce Motion

`emphasis` → `standard`，`standard` → 无动画。3 处 `withAnimation` 需加检查：
`MapHomeView.dateBadge` 的 `spring(response: 0.3)`、`mapControls` 的 `easeInOut(0.2)`、`compassRotationDegrees` 的 `linear(0.12)`。

---

## 6. Naming convention

**三列必须同步。** 任何一列单独改就是 bug。

| 韩文标签（UI） | 稳定英文 key（代码/路由/测试） | Swift token |
|---|---|---|
| 지도 | `map` | `DayMode.map` |
| 타임라인 | `timeline` | `DayMode.timeline` |
| 기록 | `record` | `DayMode.record` |
| 하루 요약 | `daySummary` | `DayRoute.daySummary` |
| 클립 편집 | `clipEditor` | `DayRoute.clipEditor` |
| 구간 편집 | `sectionEditor` | `DayRoute.sectionEditor` |
| 장소 | `place` | `DayRoute.place` |
| 메모 | `memo` | `DayRoute.memo` |
| 사진 | `photos` | `DayRoute.photos` |
| 달력 | `calendar` | `DayRoute.calendar` |
| 성장 | `growth` | `DayRoute.growth` |
| 루틴 편집 | `routineEditor` | `DayRoute.routineEditor` |
| 설정 | `settings` | `DayRoute.settings` |
| 대분류 | `mainCategory` | `Lane.main` |
| 센서 원본 | `sensorSource` | `Lane.sensor` |
| 상세활동 | `detailActivity` | `Lane.detail` |
| 미확인 | `unconfirmed` | `CategoryID.unconfirmed` |
| 확정 | `confirmed` | `ClipState.confirmed` |
| 수정됨 | `edited` | `ClipState.dirty` |
| 읽기 전용 | `readOnly` | `ClipState.readOnly` |

**四条规则：**

1. **韩文标签不改，只加。** 已有 `language.text("한국어", "English")` 双写在 ~400 处，保留这个机制；新增字符串必须同时给两个。
2. **key 用 lowerCamelCase，不带韩文、不带空格。** `DayRoute.clipEditor`，不是 `DayRoute.클립편집`.
3. **token 名带值或带角色，不带同义词。** `Space.x12` ✅ / `Space.cozy` ❌。`Radius.x16` ✅ / `Radius.card` ❌。
4. **一个概念一个词。** 「분류」在 UI 里出现了三种写法：`분류`（NLE 按钮）、`대분류`（lane 名）、`카테고리`（设置）。统一为 `분류`（UI）/ `category`（代码）。`대분류` 只用于 3 lane 语境，指"用户可编辑的那一 lane"。

---

## 7. 迁移与阻力

### 7.1 分四步，每步可独立发布/回滚

| 步 | 做什么 | 验证 | 完成标志 |
|---|---|---|---|
| **1. Token 补齐** | `Theme.swift` 加 `Font.tp*`、`Space`、`Radius`、`Elev`、`Motion`、`Color.tpCat` / `tpCatStrong` / `tpCatWash`、`tpAccentText`、`tpLineControl`。**不改任何调用点。** | `xcodebuild` 通过；71+30 token 可编译 | 新 token 存在，旧 token 仍在 |
| **2. 高危修复** | 只改 5 处，全部是达标问题：`clipBlock` 填充 → `tpCatWash` + 4pt `tpCat` 边条 + `tpInk` 字；`trimHandle` 白底 → `tpSurface` + 描边；NLE 头部 `닫기`/`적용` → `tpAccentText`；抽屉状态胶囊去 `mapHomeGlass`；`trimHandle` 扩命中区 | 截图对比 + 对比度脚本 | §2.1.2 的 7 项失败归零 |
| **3. 字体迁移** | `Font.taption` 标 deprecated；按 §2.2.4 批量替换 1,077 处字面量；**再人工处理 §7.3 的 49 处计算值（活代码 20 处）**；删除 `taption` | 逐屏截图对比；`grep -c '\.taption('` = 0 | 41 → 12 |
| **4. 间距/圆角** | 按 §2.3 / §2.4 映射批量替换 | 截图对比；`grep -c 'cornerRadius: [0-9]'` = 0 | 20 → 12, 18 → 5 |

### 7.2 会跟这套系统打架的东西

| 阻力 | 为什么难 | 怎么办 |
|---|---|---|
| **`Font.taption` 的 621 处调用** | 每个都 +2，替换时字号会变小，视觉上"整个 App 缩小了" | 接受它。现在的实际字号就是 +2 后的值，映射表按**实际值**写，所以替换后视觉不变。这是关键：`taption(size:9)` → `tpLabel(12)`，不是 → `tpRuler(9)` |
| **`MapHomeView.swift` 943KB / 22k 行** | 单文件内 506 处字体里有 ~380 处在这里；一次 PR 改不动 | 按 §3 的组件边界切：先抽 `dateBadge`/`mapSideRails`/`sidebarContent`/`bottomActionBar` 到独立文件，再迁移 |
| **4 套分类色表并存** | `CanonicalCategoryPalette` / `MapHomePastelPalette` / `RecordTimelinePalette` / `PlanCategory.color` 同一个「업무」4 个色 | **不要一次统一。** 先给 `tpCat/Strong/Wash` 三个函数收口，内部暂时仍读 `MapHomePastelPalette`（运行时用的那套）。色相统一是独立项目 |
| **`TaptionRadius` / `TaptionSpacing` 已有 377 处调用** | 删除会让 diff 巨大 | 保留为 `@available(deprecated)` 的转发：`TaptionSpacing.cozy` → `Space.x8`。一个 PR 内替换，然后删 |
| **25 个 `.sheet(` + 2 个 `.fullScreenCover(`** | 每个都自带 padding/detent 假设，改 token 会挪位置 | 阶段 1（`DayNavigator`）先把它们收进 `path`，再做视觉迁移。**顺序不能反** |
| **`.preferredColorScheme(.light)` × 3** | 深色模式永不会来，但也意味着任何 `Color(.systemBackground)` 都是错的 | 禁止 `.systemBackground` / `.label` / `.secondary`。全用 `tp*`。现在有 12 处 `.foregroundStyle(.secondary)` 在用系统色 |
| **`legacyUIEnabled = false` 的 20,811 行** | 编译期还在，`ScheduleView` 里也有 100+ 处字体调用 | **不在迁移范围。** 删掉这些视图是另一个项目。但迁移脚本要 `--exclude ScheduleView.swift ReviewView.swift GoalsView.swift SettingsView.swift`，否则统计会虚高 3 倍 |
| **49 处字号是算出来的，不是字面量** | 批量替换只能匹配字面量。这 49 处会被静默漏掉，而且其中一部分恰恰是**相对缩放**的地方，漏掉后不会报错，只会让层级在某个缩放下悄悄塌掉 | **先人工看一遍，再跑脚本。** 见 §7.3 |

### 7.3 算出来的字号：50 个匹配 = 1 个定义 + **49 处调用**

§1 的表里，1,077 是**字面量**调用数，总调用是 1,127。差的 50 个匹配把字号当变量传，脚本匹配不到。**但其中 1 个是 `Font.taption` 自己的定义**（`Theme.swift:21` 的 `.system(size: size + 2, …)`，那个 `size` 当然是变量）。所以**真实调用点是 49 处**，不是 50。

**而且其中 29 处在死视图里**，不在迁移范围：

| 文件 | 计算值调用 | 死活 |
|---|---:|---|
| `SettingsView.swift` | 22 | **死** |
| `ReviewView.swift` | 4 | **死** |
| `ScheduleView.swift` | 3 | **死** |
| **活代码合计** | **20** | ← 真正要处理的 |

活代码的 20 处，按风险排序：

| 位置 | 处数 | 写法 | 为什么要小心 |
|---|---:|---|---|
| `MapHomeLocationPresentation.swift` | **7** | `size * 0.42` · `0.43` · `0.38` · `0.43` · `0.30` · `0.21` · `0.25`（6 种乘数） | **这里已经有一套相对缩放。** 地图标注按基准字号的比例排层级。替换成固定 token 会把比例关系压平，不同缩放/机型下标注层级就没了 |
| `MapHomeView.swift` | 7 | `Layout.mapControlIcon` ×5 · `min(20, …)` · `playbackIconSize` | 地图控件图标尺寸来自布局常量，不是排版决策 |
| `MapHomeTimeSidebar.swift:1486,1524` | 2 | `rulerFontSize` | 时间尺字号由刻度密度算出（`MapHomeTimeSidebarMath.rulerFontSize(durationMinutes:)`，`:2720`） |
| `DetailViews.swift:2003,2921` | 2 | `compact ? 9 : 10.5` · `size` | 三元表达式，替换时容易只改一支 |
| `DraftComponents.swift:408` | 1 | `fontSize` | 外部传入 |
| `MapHomeCalendarSheet.swift:1878` | 1 | `bold ? 15 : 13` | 三元表达式 |

**处理规则：** 这 20 处不套用 §2.2.4 的映射表。相对缩放的地方**保留缩放结构**，只把基准值换成 token（`size * 0.42` → `tpMapLabelBase * 0.42`）；三元表达式按两支分别映射到最接近的 token。改完逐处截图，因为这批没有脚本可依赖。

**死视图的 29 处不处理**，但脚本要用 `--exclude` 明确排除，否则要么被误改，要么统计虚高。

### 7.4 Lint（防回归）

分两类。**硬失败**是"出现即错"；**棘轮**是"现在有 N 处，只准减少不准增加"——迁移期的代码库里，一条一上来就报 79 次的规则没人会看，所以它不该当门禁。

```bash
#!/usr/bin/env bash
# scripts/lint-design-tokens.sh
set -uo pipefail
ROOT="TaptionPlan/UI"
LEGACY='ScheduleView.swift|ReviewView.swift|GoalsView.swift|SettingsView.swift'
fail=0

# ── 硬失败：出现即错 ──
check () { # pattern, message
  local hits
  hits=$(grep -rEn "$1" "$ROOT" --include='*.swift' | grep -Ev "$LEGACY" || true)
  if [ -n "$hits" ]; then
    echo "✗ $2"; echo "$hits" | head -10; fail=1
  fi
}
check '\.system\(size: *[0-9]'     'Font: use Font.tp* (Theme.swift only)'
check 'cornerRadius: *[0-9]'        'Radius: use Radius.x* (Theme.swift only)'
check 'Color\(hex: *"'             'Color: use Color.tp* (Theme.swift only)'
check '\.taption\(size:'           'Font.taption is deprecated (+2pt)'
check 'mapHomeGlass'                'Glass: only over the live map — verify manually'
check '\.minimumScaleFactor'        'Type: never shrink text — fix the copy or give it more width'

# ── 棘轮：只准减少（基线在 .lint-baseline）──
ratchet () { # label, pattern
  local n base
  n=$(grep -rEn "$2" "$ROOT" --include='*.swift' | grep -Ev "$LEGACY" | wc -l | tr -d ' ')
  base=$(grep "^$1 " .lint-baseline 2>/dev/null | awk '{print $2}'); base=${base:-999999}
  if [ "$n" -gt "$base" ]; then echo "✗ $1: $n > baseline $base"; fail=1
  else echo "· $1: $n (baseline $base)"; fi
}
ratchet 'size-under-12' '\.system\(size: *(9|10|10\.5|11)\b'
ratchet 'tap-offset'    'taptionHitOutset'

exit $fail
```

初始基线（实测，live 路径）：`size-under-12 136` · `tap-offset 2`。

`minimumScaleFactor` 是**硬失败**，因为它的唯一作用就是把字缩小，而缩到 12pt 以下没有合法用法（§2.2.5）。当前 23 处，全部要逐个处理。

**为什么 `contentShape` 不进 lint。** §5.3.1 的"有背景但无 `contentShape`"**不能用 grep 判**：我试过，会命中 **47 处**，因为它分不清 200pt 的卡片和 36pt 的胶囊 —— 两者都"有 background、无 contentShape"，但只有后者错。判它必须知道 frame 尺寸，那是 SwiftSyntax 的活，不是正则的活。

所以这条留给 review checklist，判据写死：

> 控件的 `minHeight` 或 `frame(height:)` **小于 44**，带 `.background(...)`，且无 `.contentShape(Rectangle())` → 驳回。

`unconfirmedChoice`（§3.15）三条全中。

### 7.5 复现测量

```bash
cd "taption plan"

# 有效字号分布（含 .taption +2）
python3 - <<'PY'
import re,os,collections
c=collections.Counter()
for dp,_,fs in os.walk("TaptionPlan"):
    for f in fs:
        if not f.endswith(".swift"): continue
        s=open(os.path.join(dp,f),encoding="utf-8",errors="ignore").read()
        for m in re.finditer(r"\.system\(size:\s*([0-9.]+)",s): c[float(m.group(1))]+=1
        for m in re.finditer(r"\.taption\(size:\s*([0-9.]+)",s): c[float(m.group(1))+2]+=1
print("calls",sum(c.values()),"distinct",len(c))
print("below11",sum(n for v,n in c.items() if v<11))
PY

# 圆角 / 十六进制
grep -rho 'cornerRadius: [0-9.]*' TaptionPlan/UI --include='*.swift' | sort -u | wc -l
grep -rho 'Color(hex: *"[^"]*"' TaptionPlan/UI --include='*.swift' | sort -u | wc -l
```

---

## 8. 明确不做

| 不做 | 为什么 |
|---|---|
| **新配色** | 现有调色板是产品身份。只补角色，不换色相 |
| **深色模式** | 见 §8.1。不是"产品决定"这么简单 —— 有实测代价 |
| **`ScheduleView` / `ReviewView` / `SettingsView` / `GoalsView` 的组件** | 运行时不可达。不为死代码设计。见 §3.0 |
| **从零重画地图 / 猫 / 花园** | 是美术资源（366 张 `HomeEvolution`，实测 `HomeEvolution001`–`366`，每张一个 SVG），不是 token 问题 |
| **iPad / 横屏布局** | 时间轴和 3 lane 的几何是竖屏单列假设。要另做一个项目 |
| **统一 4 套分类色表** | 见 §7.2。先收口函数，色相统一独立做 |
| **把 `TaptionRadius` / `TaptionSpacing` 保留为长期 API** | 它们是"重命名 sprawl"，不是 scale。过渡期转发，然后删 |
| **图标系统** | 全用 SF Symbols。现有 `CategoryIcon.systemImage` 映射表够用，不引入自定义图标集 |
| **插画 / 空态插图** | 用 SF Symbols + 排版表达。插画会和猫/花园抢视觉，而且 366 张成长图已经是这个 App 的插画预算 |

### 8.1 深色模式：不做，但理由要写对

初稿写的是"`.preferredColorScheme(.light)` 是产品决定，不是遗漏"。这句话**把一个没算过的账说成了决定**。实测之后，代价是这样的：

| 事实 | 实测 |
|---|---|
| 强制浅色的位置 | 3 处：`AppShellView.swift:73`、`:906`、`MapHomeView.swift:3002` |
| 图片资源总数 | **442 个 imageset** |
| 其中成长图 `HomeEvolution001`–`366` | **366 个**，每张一个 SVG，`preserves-vector-representation: true` |
| 声明 `template` 渲染的 | **0 个** |

所以深色模式不是改 71 个 token 的事。**442 个资源里 366 个是为米白背景画的矢量成长图**，它们没有深色变体、也没有声明模板渲染 —— 换句话说，深色模式下它们会以原色贴在深色底上。要真做深色模式，得重画或重新调色这 366 张，那是美术项目，不是设计系统项目。

**这个"不做"是可撤回的，条件是下面任一条成立：**

1. 有用户明确要求深色模式（应用商店评论、客服、问卷，任一渠道出现 ≥3 次独立提出）。
2. 系统级无障碍需求（例如用户开了"智能反转"后界面不可读）。
3. 366 张成长图有了统一的调色管线（一次能出两套）。

**在条件成立之前，任何 `Color(.systemBackground)` / `.label` / `.secondary` 都是 bug**，因为它们会在强制浅色下悄悄跟随系统。现在有 12 处 `.foregroundStyle(.secondary)` 在用系统色 —— Phase 2 一起清掉。

---

## 附录 A：Token 清单（新增 30 个）

```
Color   tpSecondary  (改值 #7A6C50 → #6B5D43)
        tpSecondaryWeak  #7A6C50
        tpAccentText     #A8473A
        tpLineStrong     #C6B389
        tpLineControl    #8F8571
        tpCat(_:)  tpCatStrong(_:)  tpCatWash(_:)      ← 3 个函数，10 个分类

Font    tpDisplay tpTitle tpHeadline tpSubhead tpBody tpBodyStrong
        tpCallout tpCaption tpLabel tpMetric tpMeter tpRuler     ← 12

Space   hair x2 x3 x4 x6 x8 x10 x12 x16 x20 x24 x32             ← 12

Radius  x4 x8 x12 x16 x22                                        ← 5

Elev    e0 e1 e2 e3                                              ← 4

Motion  instant fast standard emphasis tracking                   ← 5
```

## 附录 B：三个必须立刻修的缺陷

按严重度：

1. **`clipBlock` 白字不达标（7/10 分类）** —— 填充改 `Color.tpCatWash(id)`、字色改 `Color.tpInk`、加 4pt `tpCat(id)` 左边条（§3.9）
2. **`trimHandle` 5pt 高、22pt 宽的可拖控件** —— 加 `taptionHitOutset(horizontal: 11, vertical: 19.5)`
3. **权限缺失显示成"기다리는 중"** —— `MapHomeView:8423` 的 `currentCoordinate == nil` 分支必须查权限，走 §4.3 而不是 §4.2
