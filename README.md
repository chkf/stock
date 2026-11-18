# 股票研究台 · 用 GitHub 构建 iPhone IPA

这是中文 SwiftUI iPhone 工程。安装 v0.2 后，打开「文件 → 我的 iPhone → 股票研究台 → 研究工作区」。手机 agent 可编辑「设计」中的页面、布局、策略和研究功能，在 App 右上角「工作区」点「重新载入工作区」即可启用。五套策略独立展示；主策略画出 60 日与 200 日两道强势门槛。第一次打开会接续旧版的本地行情、账户与历史报告。安装包和公开仓库仅包含框架、默认工作区及回归样例。新系统权限和原生能力需要重新构建 IPA。

## 第一次构建

1. 在 GitHub 新建一个私有仓库，用 Windows 上的 GitHub Desktop 将它克隆到一个新目录。
2. 将股票研究台的 GitHub 源码包解压到该目录。打开目录能直接看到 Package.swift、StockResearch.xcodeproj、Sources 和 .github。GitHub 从仓库根目录下的 .github/workflows/ipa.yml 识别工作流。
3. 在 GitHub Desktop 提交到仓库的默认分支并点击 Push origin，首次推送也可能显示 Publish branch。打开 GitHub 仓库网页后应能看到解压出来的文件。
4. 打开 **Actions → 构建 iPhone IPA → Run workflow**。首次可选 **unsigned**，无需 Apple 签名材料。构建成功后，在这次运行底部的 **Artifacts** 点击 **StockResearch-unsigned.ipa** 下载。此包可用来验证编译或供后续签名，安装到 iPhone 需要有效签名。[GitHub 手动运行工作流](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow)

## 为自己的 iPhone 生成签名包

1. 使用 Apple Developer Program 中的分发证书，准备含该证书和对应私钥的 P12，以及 iOS Ad Hoc 描述文件。生成描述文件时选择相同的证书、应用标识和要安装的 iPhone。登记设备使用该机的 UDID。[Apple 描述文件说明](https://developer.apple.com/help/account/provisioning-profiles/create-an-ad-hoc-provisioning-profile/)
2. 打开仓库 **Settings → Secrets and variables → Actions → New repository secret**，按下表填写。证书和描述文件用 Base64 文本粘贴到对应的 Secret。工作流在一次性构建机上导入这些材料。[GitHub 签名说明](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications)

| Secret 名称 | 填入内容 |
|---|---|
| IOS_P12_BASE64 | P12 文件的 Base64 |
| IOS_P12_PASSWORD | 导出 P12 时设定的密码 |
| IOS_PROFILE_BASE64 | .mobileprovision 文件的 Base64 |

在 Windows PowerShell 里，将下方的示例路径换成自己的文件路径。逐行执行，每执行一行就将剪贴板内容粘贴到对应 Secret。

~~~powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes('C:\签名材料\distribution.p12')) | Set-Clipboard
[Convert]::ToBase64String([IO.File]::ReadAllBytes('C:\签名材料\adhoc.mobileprovision')) | Set-Clipboard
~~~

3. 使用明确的应用标识时，工作流会从描述文件读取 Team 和 Bundle ID。若使用通配符描述文件，可以在 **Variables** 新建 **IOS_BUNDLE_ID**，填写自己的完整应用标识。后续更新沿用同一个 Bundle ID 和签名团队，可继续访问原来的 App 私有数据。
4. 再次打开 **Actions → 构建 iPhone IPA → Run workflow**，选择 **ad-hoc**。下载 **StockResearch-ad-hoc.ipa**。流程会校验导出后的签名、内嵌描述文件、主程序和设备平台。这类 IPA 适用于描述文件中登记的 iPhone。[Apple 设备安装说明](https://help.apple.com/xcode/mac/current/en.lproj/dev7ccaf4d3c.html)

也可以在推送到 main 的提交说明中写入 [build ipa]，让这次提交自动生成未签名包。签名模式由用户在 Actions 页面主动启动。IPA 作为仓库运行产物保留 7 天。
