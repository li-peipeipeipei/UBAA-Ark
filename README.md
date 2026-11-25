<div align="center">

<img src="docs/deploy/app-icon-512.png" width="112" alt="UBAA Ark 图标">

# UBAA Ark

**智慧北航 Remake 的 HarmonyOS 原生版：北航学生的一站式校园助手**

课表、作业、成绩、选课、预约、打卡和云打印，一个应用全部搞定。

[![最新版本](https://img.shields.io/github/v/release/li-peipeipeipei/UBAA-Ark?include_prereleases&label=%E7%89%88%E6%9C%AC&color=2f7cf6)](https://github.com/li-peipeipeipei/UBAA-Ark/releases)
[![下载量](https://img.shields.io/github/downloads/li-peipeipeipei/UBAA-Ark/total?label=%E4%B8%8B%E8%BD%BD&color=2fb67c)](https://github.com/li-peipeipeipei/UBAA-Ark/releases)
[![Stars](https://img.shields.io/github/stars/li-peipeipeipei/UBAA-Ark?style=flat&logo=github&label=Stars)](https://github.com/li-peipeipeipei/UBAA-Ark/stargazers)
[![许可证](https://img.shields.io/github/license/li-peipeipeipei/UBAA-Ark?label=%E8%AE%B8%E5%8F%AF%E8%AF%81)](LICENSE)

![ArkTS](https://img.shields.io/badge/ArkTS-6.1-blue.svg?style=flat&logo=typescript)
![ArkUI](https://img.shields.io/badge/ArkUI-HDS-purple.svg?style=flat)
![Platform](https://img.shields.io/badge/Platform-HarmonyOS%20NEXT-2fb67c.svg?style=flat)
![上游](https://img.shields.io/badge/Upstream-v2.x%20Rust%20%2B%20Flutter-orange.svg?style=flat)

[**下载安装与使用指南**](https://github.com/li-peipeipeipei/UBAA-Ark/releases) · [功能一览](#已实现功能) · [问题反馈](https://github.com/li-peipeipeipei/UBAA-Ark/issues)

</div>

---

**UBAA Ark** 是开源项目 [UBAA](https://github.com/BUAASubnet/UBAA) v2.x 的 HarmonyOS 原生客户端，
把课表、成绩、选课、预约、作业、打卡等校园服务放进一个应用。

> **非官方声明**：本项目由个人开发者基于开源项目 UBAA 独立开发与维护，**不是**北京航空航天大学
> 的官方应用，与学校及各校内系统的运营方无从属、代理或合作关系。应用内数据均由用户本人通过
> 统一身份认证登录后自行访问学校系统获得；客户端无自建服务端，不收集、不存储、不转发用户数据。
> 上游项目方已书面同意本版本发布，按 MIT 许可证要求保留原始版权声明（见 [LICENSE](LICENSE) 与
> 应用内「关于 → 开源许可」）。

## 入口

- 上游项目：[BUAASubnet/UBAA](https://github.com/BUAASubnet/UBAA)（v2.x · Rust 协议核心 + Flutter/Dart 界面，覆盖 Android / iOS / HarmonyOS / 桌面）
- 上游官网：<https://www.ubaa.top>
- 开发文档：[项目文档](docs/index.md)
- 问题反馈：[Issues](https://github.com/li-peipeipeipei/UBAA-Ark/issues)

## 已实现功能

| 模块 | 能力 |
| --- | --- |
| 登录 / 会话 | 统一身份认证（CAS）+ 图形验证码（本地 OCR 辅助识别）；校内直连 / WebVPN 双槽会话、按网络自动切换与静默重认证；「记住密码」加密落盘 |
| 课表 | 周网格、跟手翻周、同时段多课合并、教学周胶囊、本地缓存离线可看 |
| 考试 / 成绩 | 按学期查询，学分与绩点汇总 |
| 空闲教室 | 按教学楼与日期查询占用 |
| 云打印 | 待打印 / 扫描文档 / 打印点 / 使用记录 / 帮助五分区，拍照生成 PDF 上传 |
| 博雅课程 | 列表 / 详情 / 已选 / 统计，选课与退课 |
| SPOC | 作业列表、状态筛选与详情，站内网页提交 |
| 图书馆座位 | 楼馆 → 分区 → 座位 → 预约 / 取消 / 我的预约 |
| 课堂签到 | 今日课堂列表、一键签到与签到二维码（扫码签到） |
| 阳光打卡 | 学期打卡次数、一键自动填写与历史记录 |
| 财务 | 校园账户余额与收入明细 |
| iHome | 诉求列表、详情与处理进度 |
| 自动评教 | 待评课程一键完成 |
| 桌面卡片 | 下一节课 / 今日 / 本周课表、考试倒计时、成绩、空闲教室，按课表节次自动刷新 |
| 个人资料 / 设置 | 学籍信息、连接模式、备用图标切换、深色模式、缓存清理 |

## 与上游 2.0.3 的差距

上游 v2.x 在 Rust 协议核心之上由 Flutter/Dart 统一实现界面；本项目是 ArkTS 原生重写，
功能按上游协议逐项移植。以下为当前尚未对齐的部分（对照上游 2.0.3 的功能面）：

| 功能 | 状态 | 说明 |
| --- | --- | --- |
| 日程与待办 | 未实现 | 上游把课表、作业截止与自定义安排合在一条时间线，支持重复规则、完成标记与导出系统日历；本项目作业截止仍分散在各自模块 |
| 北航云盘 | 未实现 | 上游支持文件浏览 / 上传 / 下载 / 分享 / 回收站及跨设备日程同步；本项目无云盘入口 |
| 研讨室预约 | 未实现 | 上游已打通；本项目需先解决滑块验证码（图片解码 + 模板匹配 + AES-ECB） |
| 希冀作业 | 未接入 | 上游 2.x 已改版为 SPA，旧 HTML 解析失效；代码与路由保留但不挂入口 |
| 图书馆分区平面图 | 未实现 | 上游提供 29 张楼馆平面图；本项目为列表式选座 |
| 签到时间窗 | 有意不同步 | 上游将扫码（课前 10 分钟→下课）与直接签到（课前 5 分钟→上课后 30 分钟）拆成两套窗口；本项目维持单一窗口 |
| 产品改进统计 / 更新检查 / 公告 | 不接入 | 上游依赖自建应用服务；本项目服务端已下线，隐私政策明确不接入统计类 SDK |
| 桌面命令模式（`ubaa-cli`） | 不适用 | 上游桌面端专属，HarmonyOS 客户端不提供 |
| 业务会话旁车缓存、多进程会话仲裁 | 不适用 | 上游为 CLI + GUI 双进程架构；本项目单进程，无跨进程回填场景 |

详细协议对照与取舍理由见[上游 2.0.3 同步排查](docs/tech/upstream-2.0.3-sync.md)。

## UI 与体验

- 手机底部悬浮导航、平板横屏侧边导航，按窗口宽度断点自适应；「我的」等页面在大屏上分栏显示。
- 标题栏与底栏接入 HDS 沉浸光感，页面内容延伸到状态栏与导航条之下；原生支持深色模式。
- 一套设计令牌统一颜色、间距与字号，跟随系统字体与深浅色切换。
- 手机端锁竖屏、平板支持横竖屏；对接管式键盘、折叠屏与窗口尺寸变化做了避让。

细节与踩坑见 [UI 设计](docs/tech/ui-design.md) 与[平板 / 大屏适配](docs/tech/tablet-adaptation.md)。

## 开发文档

文档统一维护在仓库 `docs/` 中。

- 总览入口：[项目文档](docs/index.md)
- 功能说明：[功能总览](docs/features/index.md) / [登录与连接模式](docs/features/auth-and-connection.md)
- 技术文档：[架构总览](docs/tech/architecture.md) / [UI 设计](docs/tech/ui-design.md)
- 构建与排障：[构建与签名](docs/tech/build.md) / [排障指南](docs/tech/troubleshooting.md)

## 仓库概览

```text
UBAA-Ark/
├── AppScope/                 应用级配置与图标
├── entry/src/main/ets/
│   ├── common/               配置、路由、日期、缓存、沉浸式、断点
│   ├── model/                数据契约（对齐上游 DTO）
│   ├── network/              上游直连：CAS / 教务 / 博雅 / SPOC / 图书馆 / 云打印 …
│   ├── components/           通用组件、设计令牌、材质层、功能注册表
│   ├── entryability/         UIAbility 入口
│   ├── widget/               桌面卡片页面
│   └── pages/                页面，按业务域分组
│       ├── Index / MainPage / RouteBuilder   入口、外壳与全局路由表
│       ├── auth/             登录
│       ├── home/             主页、功能聚合
│       ├── mine/             我的、设置、个人资料、关于
│       ├── academic/         课表、成绩、考试、空闲教室
│       ├── bykc/             博雅课程（列表 / 详情 / 已选 / 统计）
│       ├── spoc/             SPOC 作业与站内提交
│       ├── campus/           云打印、校园网
│       ├── finance/          财务
│       ├── library/          图书馆座位
│       ├── activity/         课堂签到、阳光打卡
│       ├── evaluation/       自动评教、希冀作业（未挂入口）
│       ├── ihome/            iHome 诉求
│       └── scan/             扫码
├── docs/                     开发文档（features / tech / deploy / legal）
└── build-profile.example.json5
```

新增页面请落到对应业务域目录；跨域复用放 `components/`，上游数据契约放 `model/`，
请求与解析放 `network/` —— 页面里不写 URL、不解析 HTML。

## 构建

1. 复制 `build-profile.example.json5` 为 `build-profile.json5`（真实签名配置不入库）
2. DevEco Studio 打开仓库根目录，等 Hvigor 同步完成
3. `File > Project Structure > Signing Configs` 勾选自动签名
4. 连接 HarmonyOS 6.1.0(23) 及以上设备或模拟器，Run `entry`

`compatibleSdkVersion` 固定 `6.1.0(23)`（HDS 悬浮底栏与沉浸光感的最低版本），
**不要显式配置 `compileSdkVersion`**。更多说明见[构建与签名](docs/tech/build.md)。

## 声明

非官方客户端，与北京航空航天大学无隶属关系。数据来自校内系统，仅作学习与技术交流使用，
请遵守学校相关管理规定。代码以 [MIT](LICENSE) 协议开源，与上游 UBAA 一致。
