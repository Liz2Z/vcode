# 自动更新与发布

VCode 使用 Sparkle 2.10.0，更新清单与安装包均托管在 GitHub，没有 Sparkle 代理服务器。菜单提供手动检查与自动检查开关；默认启动后检查、每小时检查，不默认自动下载或强制重启。不发送匿名系统配置资料。

## 信任与密钥

应用固定包含 Ed25519 公钥，要求在解压前验证安装包，也要求验证更新清单签名；HTTPS 不是唯一的完整性保护。开发验收仅允许 localhost／127.0.0.1 的 HTTP 清单，正式清单使用固定 GitHub HTTPS 地址。清单、下载包或签名被替换时应拒绝安装，不能关闭签名验证来解决更新错误。

私钥只保存在本机 `${XDG_DATA_HOME:-~/.local/share}/vcode/signing/sparkle-ed25519.key` 和仓库 Actions Secret `SPARKLE_PRIVATE_KEY`。本机目录 0700，密钥文件 0600；不输出私钥，不把私钥写入命令行参数、构建产物、截图或 Git 历史。备份／迁移密钥必须使用安全渠道；丢失后不能随意生成新钥并期待旧安装自动接受。

用户允许 Sparkle 内部偏好、检查时间、跳过版本和框架缓存沿用其原生存储；VCode 的阅读会话、布局、历史与自身配置继续遵循 XDG。

## 构建与发布

Swift Package Manager 锁定依赖；打包时用 ditto 保留 Sparkle.framework 的符号链接、权限及辅助安装进程，并附带许可证。Sparkle 发布工具单独固定版本和 SHA-256，下载校验后使用。

CI 构建编号为 `1000.<run_number>.<run_attempt>`，高于接入更新前的手工编号，也支持同一运行重试。数字版本由 Sparkle 比较，不比较标签或提交哈希。非 main 分支只构建、测试和打包，不读取签名私钥、不发布更新。

main 测试和打包成功后，使用临时 0600 文件给 Sparkle 的 generate_appcast 传入私钥；退出时移除临时文件。工具根据包内 Info.plist 生成版本、系统与架构要求，签署安装包和清单，并再次验证清单。私钥缺失或签名失败会停止发布。

每次运行发布独立的 `preview-<run_number>-<run_attempt>` Release，更新包 URL 指向该不可变版本；只有版本包发布成功后才替换固定 `updates` Release 上的 appcast.xml。发布任务串行，比较已有清单版本，拒绝用旧构建回退更新入口。固定清单地址为 `https://github.com/Liz2Z/vcode/releases/download/updates/appcast.xml`，客户端无需 GitHub Token。清单签名后不得手工修改。

当前仍为 ad-hoc 签名且未公证。Sparkle 的 Ed25519 更新签名与 Apple Developer ID／公证是不同的机制；后续接入 Developer ID 时需同时保留更新密钥。

## 验证边界

本地必须覆盖真实检查、有新版、下载、安装重启、会话恢复、无新版、网络失败和签名拒绝；更新偏好与浅深主题也要实窗检查。云端发布完成后另核对公开清单、签名与版本包地址，不能把本地生成清单当作已发布。UI 需求在 tests/ui/README.md 中维护，执行结果单独记录。
