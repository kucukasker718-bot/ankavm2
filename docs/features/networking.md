# 网络与路由

CLICD 提供 NAT4 端口映射、随机可用端口、公网 IPv4 分配、IPv6 状态检查和 IPv6 分配能力。创建容器时可以只分配 NAT、只分配公网 IPv4、只分配 IPv6，或按需混合使用。

## NAT4

NAT4 用于把宿主机端口转发到容器内部端口。典型用途：

- 转发 SSH。
- 暴露 Web 服务。
- 给子用户分配固定外部端口。

端口映射包含：

| 字段 | 说明 |
| --- | --- |
| 名称 | 用于识别用途，例如 `ssh`、`web`。 |
| 协议 | `tcp` 或 `udp`。 |
| 外部端口 | 宿主机对外监听端口。 |
| 内部端口 | 容器内部服务端口。 |

## IPv6

IPv6 分配要求宿主机本身拥有可路由 IPv6 地址段，并且系统路由、邻居发现或代理策略配置正确。

```http
GET /api/v1/ipv6/status
POST /api/v1/containers/{id}/ipv6
```

如果宿主机没有公网 IPv6 或上游没有正确路由，面板中分配出的地址也无法从公网访问。

## 公网 IPv4

公网 IPv4 分配会从主机检测到的可用公网 IPv4 中选择地址，或使用 API 指定的 `public_ipv4s`。创建容器时可使用：

| 字段 | 说明 |
| --- | --- |
| `assign_nat` | 是否启用 NAT 端口映射。 |
| `assign_ipv4` | 是否分配公网 IPv4。 |
| `ipv4_count` | 自动分配公网 IPv4 数量。 |
| `public_ipv4s` | 指定公网 IPv4 地址列表。 |
| `assign_ipv6` | 是否分配 IPv6。 |
| `ipv6_count` | 自动分配 IPv6 数量。 |
| `ipv6_addresses` | 指定 IPv6 地址列表。 |

公网地址池相关接口：

```http
GET /api/v1/routing
PUT /api/v1/routing
POST /api/v1/routing/ipv4-scan
```

## 路由状态

```http
GET /api/v1/routing
```

该接口用于查看 NAT、IPv6、端口容量等运行时状态。
