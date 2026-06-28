# 升级

CLICD 的安装脚本和 CLI 都围绕 GitHub Release 产物工作。升级前建议先确认当前版本、备份配置和数据库。

## 查看版本

Web 面板侧边栏底部会显示当前版本，也可以访问：

```bash
curl http://127.0.0.1:8999/api/version
```

返回示例：

```json
{
  "success": true,
  "data": {
    "version": "1.1.6"
  }
}
```

## 使用安装脚本升级

安装脚本默认使用最新 Release：

```bash
curl -fsSL https://raw.githubusercontent.com/MengMengCode/CLICD/main/install.sh | sudo sh
```

指定版本：

```bash
curl -fsSL https://raw.githubusercontent.com/MengMengCode/CLICD/main/install.sh | sudo CLICD_VERSION=v1.1.6 sh
```

## 升级前检查

- 确认 `/root/.clicd/` 或实际配置目录已备份。
- 确认系统服务没有正在执行关键任务。
- 如果正在下载镜像或恢复快照，建议等待任务完成后再升级。
- 升级后检查 `systemctl status clicd` 和 Web 面板版本号。
