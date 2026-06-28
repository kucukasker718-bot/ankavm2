# 安全告警

CLICD 内置基于连接行为的轻量安全告警能力。它不保存完整正常连接日志，而是关注异常行为和高风险模式。

## 覆盖场景

- 端口扫描。
- 横向扫描。
- 爆破倾向。
- SMTP 滥用。
- UDP 反射风险。
- 挖矿、代理、VPN、Tor 等可疑端口。

## 接口

```http
GET /api/v1/security/alerts
POST /api/v1/security/check
GET /api/v1/security/logs?container={name}
GET /api/v1/security/summary
GET /api/v1/security/settings
PUT /api/v1/security/settings
```

## 自动关机

安全设置中可配置告警后的自动关机策略。开启前建议先观察一段时间，确认规则不会影响正常业务。

## 日志建议

安全告警适合做风险提示，不应替代专业防火墙、入侵检测或集中日志系统。对公网暴露服务时，仍建议结合安全组、防火墙、Fail2ban 等工具。
