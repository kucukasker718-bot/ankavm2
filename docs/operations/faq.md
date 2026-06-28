# 常见问题

## 安装脚本默认安装哪个版本？

默认安装 GitHub Releases 的最新版本。脚本中默认值是 `CLICD_VERSION=latest`，会下载 `releases/latest` 下的 Linux AMD64 产物。

## 可以固定安装某个版本吗？

可以：

```bash
curl -fsSL https://raw.githubusercontent.com/MengMengCode/CLICD/main/install.sh | sudo CLICD_VERSION=v1.1.6 sh
```

## 子用户能看到全部容器吗？

不能。子用户只会看到管理员授权给他的容器。

## API Key 和登录密码一样吗？

不一样。API Key 在“API 集成”页面创建，用于程序化调用接口。登录密码用于 Web 面板登录。

## 到达流量限制后会怎样？

容器达到流量限制后会被自动关机，避免继续产生超额流量。管理员可以调整限制或重置流量。

## IPv6 分配后为什么公网不通？

IPv6 是否可达取决于宿主机和上游网络。需要确认宿主机拥有可路由 IPv6 地址段，并且路由、防火墙、邻居发现或代理配置正确。
