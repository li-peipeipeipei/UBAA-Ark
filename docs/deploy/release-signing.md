# 发布签名与打包（上架专用）

> 适用：提交华为应用市场（AppGallery Connect）。
> 调试签名（DevEco 自动签名）**不能**用于上架，必须换成发布证书 + 发布 Profile。

## 一、为什么必须换

| 项 | 调试证书 | 发布证书 |
| --- | --- | --- |
| 用途 | 真机调试安装（受限设备名单） | 应用市场分发（任意用户安装） |
| Profile 类型 | debug | release |
| 有效期 | 14 天 ~ 90 天 | 通常 1~3 年 |
| AGC 是否认可 | 否（上传即被拒） | 是 |

当前工程使用的调试证书在 `build-profile.json5` 的 `signingConfigs` 中配置，有效期至 2027-10-25，
但它是 **debug** 类型，`SignHap` 能过、`assembleApp` 上传会被 AGC 以「签名类型不符」拒绝。

## 二、申请发布证书（在 AGC 网页完成，命令行做不了）

1. **生成密钥与 CSR**
   DevEco Studio → 菜单 `Build` → `Generate Key and CSR`：
   - `Key Store File`：新建，例如 `D:\keys\ubaa-release.p12`（**务必自行备份，丢失无法重置**）
   - `Key Alias`：例如 `ubaa`
   - 密码：自行设定并记录
   - `CSR File`：输出 `ubaa-release.csr`

2. **上传 CSR 申请发布证书**
   AGC → `用户与访问` → `证书管理` → `新增证书`
   - 证书类型：**发布证书**
   - 上传刚生成的 `.csr`
   - 下载得到的 `.cer` 文件

3. **申请发布 Profile**
   AGC → `用户与访问` → `Profile` → `新增 Profile`
   - Profile 类型：**发布**
   - 选择上一步的发布证书
   - 绑定应用包名：`com.ubaa.app`（**必须与 `AppScope/app.json5` 的 bundleName 完全一致**）
   - 下载得到的 `.p7b` 文件

> ⚠️ 包名一旦上架不可更改。当前包名为 `com.ubaa.app`。
> 修改包名后，必须重新绑定 Profile，且本机已安装的旧包名应用会被视为另一个应用（需卸载重装）。

## 三、配置 build-profile.json5

`build-profile.json5` 已被 `.gitignore` 屏蔽（含口令）。在 `app.signingConfigs` 中**新增**一项，
保留原有 debug 项，用 `products[].signingConfig` 切换：

```json5
{
  "app": {
    "signingConfigs": [
      {
        "name": "default",          // 原有调试签名，保持不变
        "type": "HarmonyOS",
        "material": {
          "certpath": "C:/Users/<你>/.ohos/config/default_xxx.cer",
          "storePassword": "******",
          "keyAlias": "debugKey",
          "keyPassword": "******",
          "profile": "C:/Users/<你>/.ohos/config/default_xxx.p7b",
          "signAlg": "SHA256withECDSA",
          "storeFile": "C:/Users/<你>/.ohos/config/default_xxx.p12"
        }
      },
      {
        "name": "release",
        "type": "HarmonyOS",
        "material": {
          "certpath": "D:/keys/ubaa-release.cer",
          "storePassword": "<p12 口令>",
          "keyAlias": "ubaa",
          "keyPassword": "<密钥口令>",
          "profile": "D:/keys/ubaa-release.p7b",
          "signAlg": "SHA256withECDSA",
          "storeFile": "D:/keys/ubaa-release.p12"
        }
      }
    ],
    "products": [
      {
        "name": "default",
        "compatibleSdkVersion": "6.1.0(23)",
        "targetSdkVersion": "6.1.0(23)",
        "runtimeOS": "HarmonyOS",
        "signingConfig": "release",   // 上架时切到 release；平时调试改回 default
        "buildOption": { "strictMode": { "caseSensitiveCheck": true, "useNormalizedOHMUrl": true } }
      }
    ],
    "buildModeSet": [
      { "name": "debug" },
      { "name": "release" }
    ]
  }
}
```

> 更省事的做法：DevEco Studio → `File` → `Project Structure` → `Signing Configs`，
> 取消勾选 `Automatically generate signature`，手动填入上述文件与口令，IDE 会回写
> `build-profile.json5`，不必手改 JSON。

## 四、打包

> ⚠️ **最容易踩的坑：`assembleApp` 不显式传 `-p buildMode=release` 时默认按 debug 打包。**
>
> 判据：日志里出现 `:entry:default@CollectDebugSymbol` 就是 debug 构建；产物在
> `signingConfigs` 里取的是 `default` 那一项（DevEco 自动生成的调试证书）。
> 这样的 `.app` 上传 AGC 会以签名类型不符拒绝，且现象容易被误判成「构建成功就能上架」。

```powershell
$env:CODEBUDDY_SAFE_DELETE_ENABLED='0'
$env:DEVECO_SDK_HOME='C:\Program Files\Huawei\DevEco Studio\sdk'
Set-Location D:\0001\UBAA-HarmonyOS

# 打 App 包（上架用的就是这个，不是 .hap）
# --mode project 才是打 App 包；--mode module 只出 HAP
& 'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.bat' `
  --mode project -p product=default -p buildMode=release `
  assembleApp --no-daemon --no-incremental
```

产物：`build/outputs/default/UBAA-HarmonyOS-default-signed.app`
（工程级 `build/` 目录，**不在** `entry/build/` 下）

前置条件：`build-profile.json5` 里必须已有 `signingConfig: "release"` 且 `signingConfigs`
中存在名为 `release` 的发布签名项（见第三节）。只有 `default` 一项时，即使传了
`buildMode=release`，签名仍然来自 default → 仍是调试证书。

> 注意：本工程根目录没有 `hvigorw.bat`，必须用 DevEco 自带的那份
> （`tools\hvigor\bin\hvigorw.bat`）。直接 `.\hvigorw.bat` 会 `CommandNotFoundException`。

### 上传前自检

1. `AppScope/app.json5`：`bundleName = com.ubaa.app`、`versionCode` 相比上个版本已递增、`versionName` 已更新。
2. `build-profile.json5`：`signingConfig` 指向 `release`，`buildMode = release`。
3. 上架图标：`docs/deploy/app-icon-1024.png` 或 `app-icon-216.png`（正方形、直角、无透明通道、PNG），与包内 `AppScope/resources/base/media/app_icon.png` 图案一致。
4. 真机用 release 包完整走一遍登录 + 主要功能（审核人员会实际点）。
5. AGC → `软件包管理` → 上传 → 跑「合法性检测」，有告警逐条处理。

## 五、已知的本项目特有风险

| 项 | 现状 | 处理建议 |
| --- | --- | --- |
| `minAPIVersion` | 23（HarmonyOS 6.1.0） | 只有 6.1+ 设备可安装。上架后市场覆盖率低，审核会在兼容性检测里提示；发布信息中如实标注「需 HarmonyOS 6.1 及以上」 |
| 依赖 API 23 特性 | `HdsTabs.barFloatingStyle`、`systemMaterialEffect` | 降到 API 12 会导致编译失败，**不可降**，只能接受覆盖面 |
| `uiMaterial` 实为 API 26 | `SystemMaterial.ets` 多处告警「supported since SDK 26.0.0, current compatible SDK is 6.1.0(23)」 | 代码已有 `isApi26OrAbove()` 判据 + `try/catch` 兜底，API 23 设备降级为 `backdropBlur`，**运行期安全**。审核若问起，按此说明；不要为了消警告去改 `compatibleSdkVersion`（会连带 HdsTabs 一起失败） |
| 2in1 存在不可用 API | `ImmersiveUtil`(65/68/75/171)、`MainPage`(564)、`SpocPage`(711) 告警 `This API is unavailable to 2in1` | 上架时**建议先不勾选 2in1**，等这些位置做设备判断后再放开。`deviceTypes` 里虽声明了 2in1，但 AGC 分发设备是独立勾选项 |
| 混淆 | 未开启（构建 WARN） | 上架建议开 `buildOption.obfuscation`，但 ArkTS 有反射/动态属性场景，需先配 `obfuscation-rules.txt` 再验证；不确定就先不开，不影响审核通过 |
| 模块版本 | `entry/oh-package.json5` 用 `0.1.0` 会报 `does not comply with the SemVer` WARN | 已改 `1.0.0`，警告消失。该字段只影响 ohpm，不影响 hap 版本（hap 版本看 `app.json5` 的 `versionName`/`versionCode`） |
| 包名 | `com.ubaa.app` | 已避开 `.edu.buaa` 教育机构命名空间，也避开了华为保留字符（见下节） |
| 应用名 | `UBAA` | 已避开学校官方应用名「智慧北航 / i北航」 |
| 设备类型 | phone / tablet | 上架勾选这两项即可；2in1 先不勾（见上一行） |

### 包名规则备忘（踩过一次）

华为对 HarmonyOS 包名有硬性约束，其中最容易踩的是**保留字符不能作为独立段**：

- 保留字符：`oh`、`ohos`、`harmony`、`harmonyos`、`openharmony`、`system`
- 禁止形态（以 harmony 为例）：`harmony.huawei.com`、`com.harmony.huawei`、`com.huawei.harmony`
- 也就是说 `com.ubaa.harmony` 这种「最后一段放项目平台名」的命名是**违规**的
- 另外：至少三段、首段字母开头、非首段数字或字母开头、各段以数字或字母结尾、
  长度 7~128、不能有连续点号

当前包名 `com.ubaa.app` 满足全部约束。**包名设置后不可修改**，改一次等于换一个应用
（旧包在用户机上成为残留，需卸载重装；AGC 侧也要重新建应用、重新绑定 Profile）。

## 六、常见报错对照

| 报错 | 原因 | 处理 |
| --- | --- | --- |
| `11013002 / The certificate has expired!` | 证书过期 | 重新申请发布证书并更新 `build-profile.json5` |
| `The profile does not match the bundle name` | Profile 绑定的包名与 `bundleName` 不一致 | 回 AGC 重新创建绑定 `com.ubaa.app` 的 Profile |
| `SignHap` 失败、ArkTS 全过 | 多为证书/Profile 问题，不是代码问题 | 先看 `build.log` 里的 `SignHap` 段 |
| 打印 `BUILD SUCCESSFUL` 但产物时间没变 | 增量缓存被上次失败构建污染 | 加 `--no-incremental` 全量重编 |
| `CompileArkTS is up-to-date` 但代码明明改了 | 同上 | 同上；**不要删 `entry\build`**（会丢整份中间产物，重编更慢） |
