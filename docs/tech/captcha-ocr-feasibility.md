# 验证码自动识别（M1）实测：精度与速度（2026-11-18）

> 目的：判断「WebVPN 登录时的 6 位验证码」能否在端侧自动识别，免去人工输入。
> 结论：**速度完全够用；精度无法用人工标注严谨度量，但有强旁证；真正验收只能用「登录是否通过」。**

## 1. 样本怎么来的（没有用任何凭据）

- 直连 `https://sso.buaa.edu.cn/login`：本机 2 次探测**均不下发** `config.captcha`。
- 经 WebVPN 网关 `https://d.buaa.edu.cn/https/<加密主机>/login`：**20/20 次都下发**
  `config.captcha = { type:'image', id:'…' }`。

这解释了两件事：

1. 校外（WebVPN）登录**必然要填验证码**，与「原版是否支持验证码」无关，是学校侧的强制；
2. 采集只需公开 GET，不提交任何凭据：
   `GET /login?r=<随机>` 取 `id` → `GET /captcha?captchaId=<id>&r=<随机>` 取图，
   同一个 Cookie 罐内完成。**`?r=` 必须加**，否则会被缓存命中、页面里没有验证码块。

样本：32 张真实验证码（`D:/0001/_ref/m1/shots` 20 张、`shots2` 12 张）。

## 2. 速度（PC，ONNX Runtime 1.32，CPU 4 线程）

| 指标 | 数值 |
|---|---|
| 模型加载（26.2 MB int8） | **156 ms** |
| 首帧推理 | 4.0 ms |
| 预处理（解码 + 补边 + 缩放 + 归一化） | median 1.0 ms / p90 3.3 ms |
| 纯推理 | **median 3.9 ms / p90 7.5 ms / max 24.6 ms** |

手机端（Kirin，arm64，MNN 或 ORT）经验倍率 3–8×，预估 **15–60 ms/张**，加载 0.3–1.5 s（可后台预热）。
相对一次登录往返（数百毫秒）可忽略。

## 3. 精度：三个可量化旁证

| 指标 | 结果 | 含义 |
|---|---|---|
| 输出格式合法率 | **32/32** 都是 6 位小写字母数字 | 解码管线（CTC 贪心 + 去重去 blank）正确；模型没有「乱码式」输出 |
| 逐字符置信度（softmax 最大值）均值 | **0.99**（仅 1 张出现 0.66 的低置信字符） | 模型自评很确定 |
| 前处理扰动稳定性（padding 3/5/8、中间缩放 ±1/±2 像素，5 种组合） | **29/32 = 90.6%** 结果完全不变 | 不是「勉强猜中」，对输入扰动不敏感 |

**为什么给不出「准确率 X%」**：验证码带强干扰（斜线、重叠、透视），人工判读本身不可靠。
我对 4 张做盲读，1 张与模型一致、3 张在我难以分辨的字符上分歧（位置 3/4 的 `m/n`、`d/n`、`7/x`）。
拿人工判读当真是错的参照系。

唯一可信的真值来源是**服务端是否放行**：验证码对 → 即使密码错也返回「用户名或密码错误。」+
新挑战；验证码错 → **同一句文案**（原版 2.0.2 文档已记录该陷阱）。因此本地无法用响应区分，
只能统计「自动填了几次才登进去」。

## 4. 已确认的技术约束（决定 M1 怎么做）

- 现有模型是 **ddddocr 的 `common.onnx`（8210 类）经 ORT 动态量化**得到：含
  `ConvInteger`/`DynamicQuantizeLinear`/`LSTM`，**MindSpore Lite 不支持**（官方算子表无这三类）。
- 因此 M1 走 **MNN**：官方 release 提供 `mnn_3.6.2_harmony_arm64_cpu.zip`（**2.0 MB**），
  仓库自带 `project/harmony/build_64.sh`；MNN 支持 Conv/LSTM/MatMul，可直接吃 ddddocr 的 fp32 模型。
- 转换输入要用 **ddddocr 原始 fp32 ONNX**，不要用这份 ORT 量化图（MNNConvert 不认
  `ConvInteger`/`DynamicQuantizeLinear`）。`kekxv/ddddocr-mnn` 已证明该转换可行（产物 51.6 MB）。

## 5. 建议的验收方式

1. 端侧接入后，按原版 2.0.2 的「**3 次预算 + 人工兜底**」：自动识别失败 3 次就弹输入框；
2. 记录「自动识别尝试次数 / 最终成功与否」，攒 20 次真实登录后算实际命中率；
3. 命中率 < 70%（三次联合 < 97%）就不值得保留，直接退回人工输入 + 换图重试。

## 6. M1 落地实现（2026-11-18）

已接进工程，编译与安装通过（HAP 62 MB），**真机验收未做**（设备锁屏，`aa start` 返回
「screen cannot be unlocked automatically」）。

| 组成 | 位置 | 说明 |
|---|---|---|
| 运行时 | `entry/libs/arm64-v8a/libMNN.so`（4.4 MB，打包后） | 官方 `mnn_3.6.2_harmony_arm64_cpu.zip`，仅 arm64-v8a |
| 头文件 | `entry/src/main/cpp/include/MNN/` | 取自 alibaba/MNN `include/MNN` |
| 模型 | `resources/rawfile/ocr.mnn`（52 MB） | `kekxv/ddddocr-mnn` 的 `ocr.captcha.sim.mnn` |
| 字符集 | `resources/rawfile/captcha_charset.txt`（8210 行） | 由该仓库 `words.h` 转换而来 |
| 原生封装 | `entry/src/main/cpp/mnn_captcha.cpp` | `init/recognize/release` 三个 NAPI |
| ArkTS | `network/CaptchaRecognizer.ets` | 首次把模型释放到沙箱 → `mnnInit` → 识别 |
| 登录接入 | `network/LocalAuthService.ets` | 预热时预识别 + 登录时最多 3 次自动尝试 |
| UI | `pages/auth/LoginPage.ets` | 挑战下发后自动预填输入框 |

🔴 **字符集必须配模型**：`words.h` 与 UBAA 仓库的 `charset.json` 都是 8210 项，但**顺序不同**
（前者第 2 项是「笤」，后者是「掀」）。混用会解出一串无关汉字。校验方法：识别
`fixtures/auth/captcha_synthetic.png` 应得到 `a2b3c4`。

⚠️ 已知代价：模型 52 MB 直接放 `rawfile`，HAP 从 4.8 MB 涨到 62 MB；后续可用
`MNNConvert --weightQuantBits=4` 压到 ~13 MB。

## 6.5 闪退复盘（2026-11-18，已修复）

现象：切到 WebVPN 登录模式必闪退。`cppcrash` + 逐段日志定位到**三处独立缺陷**，
且都是「照 PC 端 Python 脚本的假设写 C++」造成的。

| # | 缺陷 | 证据 | 修法 |
|---|---|---|---|
| 1 | 模型输入宽度是**动态**的（`1x1x64x0`），直接跑 = 空张量推理 → SIGSEGV | `probe()` 回传 `in:shape=1x1x64x0 create=ok(size=0)` | 计算目标宽度后 `resizeTensor` + `resizeSession` |
| 2 | 前处理口径不对：参考实现是 `[-1,1]` 归一化（`(v/255-0.5)/0.5`）、**不补边**、宽度按 `原宽×64/原高` 缩放 | `OcrCaptcha.hpp` 的 `mat2tensor` | 全部照抄 |
| 3 | 输出不是 8210 维 logits，而是 **int32 类别索引序列**（`1xT`），映射表是 `words.h` | `out=1x22,code=0,bits=32`，作者代码用 `output->host<int>()` | 按 int32 读，跳过 0、去连续重复，再查表 |
| 4 | 字符集文本被 Python 按 Windows 默认写成 **CRLF**，C++ 按 `\n` 切分后每个字都带 `\r` → 长度判定失败 | 文件里 8209 个 `\r`；解码串里每个字后面都是回车 | 以 `newline="\n"` 重写，并在 C++ 侧剥掉行尾 `\r` |

修复后端侧实测（真机 PLR-AL50）：

| 指标 | 数值 |
|---|---|
| 模型加载（52 MB，已释放到沙箱） | **122 ms** |
| 单张识别（含 ImageKit 解码 → 灰度 → 缩放 → 推理 → 解码） | **66–78 ms** |

## 7. 复现


```bash
# 样本与评测脚本
D:/0001/_ref/m1/{harvest.py,eval.py,eval2.py,stability.py,bench.py}
# 模型
D:/0001/_ref/mslite/common.onnx        # 26.2 MB int8
D:/0001/_ref/v202/UBAA-2.0.2/crates/ubaa_core/assets/captcha/{charset.json,common.onnx.gz}
```
