# 故障排查

## 服务无法访问

检查服务状态：

```bash
systemctl status clicd
journalctl -u clicd -n 100 --no-pager
```

检查端口监听：

```bash
ss -lntp | grep 8999
```

如果使用反向代理，请同时检查代理日志和上游地址。

## 镜像下载失败

- 确认宿主机可以访问镜像源和 GitHub Release。
- 检查磁盘空间。
- 在任务队列里查看失败原因。
- 如下载卡住，可尝试取消任务后重新下载。

## 容器无法联网

- 检查宿主机 NAT 和转发规则。
- 检查容器 IP 是否分配成功。
- 检查防火墙是否拦截转发流量。
- IPv6 场景下确认上游已经把地址段路由到宿主机。

## WebSSH 或 WebVNC 连接失败

- 确认容器或虚拟机正在运行。
- WebSSH 需要容器内 SSH 服务可用。
- WebVNC 需要 KVM 控制台可访问。
- 票据有效期很短，过期后重新创建即可。

## API 返回未授权

- 确认 API Key 没有被禁用。
- 确认请求头使用 `X-API-Key` 或 `Authorization: Bearer`。
- 确认密钥权限范围覆盖目标接口。
- 不要把面板登录密码当作 API Key 使用。
