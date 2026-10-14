下载命令：

```bash
git clone https://github.com/Riczzoe/ip-quality-monitor.git && cd ip-quality-monitor
```

之后请编辑 `monitor.conf` 填写 `TG_BOT_TOKEN`、`TG_CHAT_ID` 和 `VPS_NAME`，按需修改 `INTERVAL_DAYS`，保存并退出编辑器后继续安装。

```bash
sudo bash install.sh
```

安装完成后，立即执行一次检查（如果修改了 `INSTALL_DIR`，请替换为对应路径）：

```bash
sudo bash /opt/ip-quality-monitor/ip-quality-monitor.sh
```

