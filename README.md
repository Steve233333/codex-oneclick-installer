# Codex 一键配置安装器

在另一台 Mac（只有原版 Codex / ChatGPT.app）上，双击一个文件即可自动生成与本机一致的 Codex DeepSeek 副本：`~/.codex-deepseek` 配置、models.json 模型清单、视觉代理（launchd 常驻）、`~/Applications/ChatGPT-Patched.app` 双开副本。

## 使用方法

1. 把 `codex-oneclick-setup.zip` 拷到新 Mac（AirDrop / U 盘均可），双击解压。
2. 如果提示“无法打开，因为无法验证开发者”，对 `codex-oneclick-setup.command` 右键 → 打开 一次，或先执行：

   ```bash
   xattr -dr com.apple.quarantine codex-oneclick-setup.command
   ```

3. 双击 `codex-oneclick-setup.command`，按提示依次输入（全部可选，但 Go 与 DeepSeek 至少填一个）：

   - OpenCode Go / Zen 订阅 Key：缺它 → 所有 `*-go` 模型不会安装。
   - DeepSeek 官方 API Key：缺它 → 官方 `deepseek-v4-flash/pro` 不会显示，默认模型自动改用 Go 模型。
   - 智谱 GLM 视觉 Key：缺它 → 文本对话正常，但发图片会失败；之后可补填。
   - 这台 Mac 的开机密码（或自定义密码）：仅用于创建本地签名钥匙串，保存于 `~/.codex/picker-patch/.keychain-pass`（权限 600）。

4. 等待自动完成（复制/补丁 app、生成配置、启动视觉代理约需 1–3 分钟），最后会弹窗汇总。

## 安装后会得到什么

| 文件/位置 | 作用 |
|---|---|
| `~/.codex-deepseek/` | 副本的 CODEX_HOME（config.toml / models.json / AGENTS.md / 会话隔离） |
| `~/Applications/ChatGPT-Patched.app` | 双开副本（与原版并存，DeepSeek 专用） |
| `~/.local/share/agent-vision-toolkit/` | 视觉代理源码（vision_proxy.py） |
| `~/.config/agent-vision-toolkit/env` | 视觉 + Zen/Go key（权限 600） |
| `~/Library/LaunchAgents/com.agent-vision-toolkit.proxy.plist` | 视觉代理开机自启（端口 19100） |
| `~/.codex/picker-patch/` | 副本补丁工程（patch.sh、证书、日志） |
| `~/Library/Logs/codex-oneclick-setup.log` | 安装日志 |

## 缺 key 的后果

- 只填 DeepSeek：没有 `*-go` 模型，直连 `https://api.deepseek.com/`，无看图。
- 只填 Go：没有官方 deepseek-v4-flash/pro，默认 `mimo-v2.5-go`，无看图（发图会失败，提示补 GLM key）。
- Go + DeepSeek：全部模型可用，默认 `deepseek-v4-flash`。
- Go/DeepSeek + GLM：以上基础上看图可用。
- 全部不填：安装器会拒绝继续。

## 更新 Key / 重新安装

直接再双击一次 `.command`：输入框留空时会自动沿用现有 key；输入新 key 则覆盖。旧的 `config.toml` / `models.json` / `AGENTS.md` 会先备份成 `*.bak.<时间戳>`。

补填 GLM key 后手动生效：

```bash
launchctl kickstart -k gui/$(id -u)/com.agent-vision-toolkit.proxy
```

## 说明与注意事项

- 安装器不会复用其他机器上的签名证书，新 Mac 会现场生成自签证书。
- 所有 key 只写入本机 600 权限文件，不联网上传、不进日志。
- 本安装包不含任何密钥；如需验证：

  ```bash
  rg -l 'sk-[A-Za-z0-9]{20,}' codex-oneclick-setup.command resources/ README.md
  ```

- 副本升级依赖官方 app 版本变化时由 `~/.codex/picker-patch/patch.sh --auto-update` 自动重建；若官方更新后副本启动失败，重新双击安装器即可。
- 新 Mac 首次启动副本可能被 macOS 提示“验证开发者”，属正常现象（自签应用），选择“打开”即可。
