# 横向胶囊行：左右渐隐遮罩 + 默认位置

> 适用：博雅「已选条件」、图书馆座位、iHome、财务收入、SPOC 等**可横向滚动的筛选胶囊行**。
> 实现：`entry/src/main/ets/components/ChipsEdgeFade.ets`（共用组件）。

## 一、最终规格

| 项 | 值 | 位置 |
|---|---|---|
| 遮罩宽度 | **15vp**（自屏幕边缘向内） | `CHIP_FADE_WIDTH`（组件内导出） |
| 屏幕边缘不透明度 | **75%**（`#BF` + 页面底色 RGB） | `headColor()` |
| 距边缘 15vp | **0%**（同色 alpha=0） | `tailColor()` |
| 过渡 | `angle: 90` 线性；左侧 75%→0，右侧镜像 | `build()` 内两条 `Column` |
| 显示策略 | **恒定显示**，不随滚动位置变化 | — |

## 二、两个位置概念，别混

胶囊行有「两个边」，职责必须分开：

1. **默认缩进（16vp）** —— 由 `Row` 的 `padding: pagePadding` 提供，**写在滚动内容里**。
   - 静止时：首尾胶囊与下方卡片左右对齐；
   - 滑动时：这段留白跟着内容一起滚走，胶囊能真正贴到屏幕边缘。
2. **全出血（0 → 屏幕宽）** —— 由**父容器**保证：页面内容 Column **不能**有左右 `padding`，
   筛选卡 / 列表各自包一层带 `padding` 的 `Column`。
   - 只有这样，胶囊 `Scroll` 的盒子才是 `0..屏幕宽`，遮罩才落在真正的屏幕边缘上。

> 一句话：**留白放在滚动内容里，全出血交给父级结构。**

## 三、宿主接入方式（照抄即可）

```ts
Scroll() {
  Row() { /* 胶囊 … */ }
    .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding }) // 默认缩进在这里
}
.width('100%')
.scrollable(ScrollDirection.Horizontal)
.scrollBar(BarState.Off)
.edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
.align(Alignment.Start)
.clip(false)
.onAreaChange((_old: Area, now: Area) => {          // 遮罩高度必须实测
  const height: number = Number(now.height);
  if (height > 0 && Math.abs(height - this.chipsRowH) > 0.5) {
    this.chipsRowH = height;
  }
})
.overlay(this.chipsEdgeFade(), { align: Alignment.Center })
```

组件侧：`ChipsEdgeFade({ fadeHeight: this.chipsRowH })`。

## 四、五条硬约束（都踩过，改代码前先读）

### 1. 必须用 `overlay`，不能用外层 `Stack`

外面包一层 `Stack` 来叠遮罩，会**抢走横向 Pan** —— 实测胶囊行直接滑不动。
`overlay` 画在内容之上、**不参与布局**、也不吃手势。

### 2. 遮罩高度必须显式给

`overlay` 里写 `height('100%')` 会解析成**整页高**，渐隐条会把下方所有卡片的左右边缘一起压暗。
正确做法：宿主 `onAreaChange` 实测行高，通过 `@Prop fadeHeight` 传进来。

### 3. 颜色必须是「页面底色同 RGB、只降 alpha」

- 不透明端：`#BF` + `pageBackgroundArgbHex()`（75%）
- 透明端：`#00` + 同一颜色（0%）

**不能用 `Color.Transparent`**（`rgba(0,0,0,0)`）：浅色底上与遮罩色插值会渗出灰黑，形成脏带。
`pageBackgroundArgbHex()` 从 `app.color.page_background` 读真值（深色 `#000000` / 浅色 `#F1F3F5`），深浅主题自动跟随。

### 4. 不要靠「是否溢出」来决定显示隐藏

加了 `clip(true)` 之后，`Row` 的 `onAreaChange` 量到的是**被钳制后**的宽度，
`content > viewport` 这类判断不再可靠（实测 `content 336vp / viewport 344vp` 明明溢出却判为不溢出）。
两侧改为**恒开**——它本来就是「可继续滑动」的常驻视觉提示。

### 5. `overlay` 里的 `if` 条件不随状态重建

`overlay(this.builder())` 中的条件分支**只在首帧求值一次**，后续状态变化不会重建节点
（表现为「调了半天，遮罩一直没有」）。需要显隐时应让节点常驻、用 `.opacity()` 控制。

## 五、父级布局的反面案例（实测数据）

改之前先看这两条，能省掉几轮返工：

| 尝试 | 结果 |
|---|---|
| `Scroll` 上 `.margin({ left: -16, right: -16 })` 抵消父级 padding | **无效**，布局 dump 显示 `Scroll` 仍在 `56..1260` |
| `.width('calc(100% + 32vp)')` + `.offset({ x: -16 })` | `calc` 未生效，宽度仍等于 `100%`（`1204`），右端少 2×16vp |

唯一可靠的做法是**改结构**：父级不要左右 padding，留白下放到各子块。

正确的 dump 特征（可作为验收判据）：

```
胶囊 Scroll   (0, 598, 1316, 709)      ← 真·全屏宽
遮罩左条      (0, 598, 53, 710)        ← 从 x=0 起，53px = 15vp
遮罩右条      (1264, 598, 1316, 710)   ← 贴右边缘，15vp
```

## 六、调参索引

| 想改 | 改哪里 |
|---|---|
| 渐隐宽度 | `ChipsEdgeFade.ets` 的 `CHIP_FADE_WIDTH`（一处改动，五个页面同步生效） |
| 边缘不透明度 | `headColor()` 的 `'#BF'` 前缀（`BF`≈75%，`B3`≈70%，`99`≈60%） |
| 默认缩进 | 胶囊 `Row` 的 `padding`（当前 `AppSize.pagePadding`） |
| 行高测不准 | 检查宿主的 `onAreaChange` 是否挂在 `Scroll` 上、是否被 `clip(true)` 钳制 |

## 七、验收清单

- [ ] 静止时首个胶囊与下方卡片左边缘对齐
- [ ] 滑到最左 / 最右时，内容能进入 15vp 遮罩区并被柔化（不是硬切，也不是「多一条黑边」）
- [ ] 遮罩只压暗胶囊行，下方卡片左右边缘不受影响
- [ ] 横向滑动正常（无 Stack 包裹）
- [ ] 深色 / 浅色主题下过渡段都不泛灰
