# VPS NetPilot

VPS一键 TCP/UDP 网络调优面板。不追求“所有机器一键拉满”，而是把常见场景拆成两档：普通业务用保守调优，中转、代理节点、隧道节点再开启增强的转发优化。

## 做了什么

| 功能 | 说明 |
|---|---|
| IPv4 优先 | 适合 IPv6 路由质量差、解析后握手慢的机器 |
| BBR + FQ | 设置系统已有的 BBR 和默认 FQ，并检查实际出口队列 |
| 通用保守调优 | 调整连接队列、TCP/UDP 缓冲区、conntrack，不默认开启 IP 转发 |
| 中转增强调优 | 在通用调优基础上开启 IP 转发和 MSS Clamp |
| RPS/RFS | 多核 VPS 可尝试分散软中断压力 |
| 回退 | 按修改前快照恢复参数、配置和 RPS，只删除脚本标记的 MSS 规则 |

## 安装

```bash
bash <(curl -fsSL --connect-timeout 10 --max-time 90 https://raw.githubusercontent.com/sanmussh/vps-netpilot/main/tcp.sh)
```

备用 CDN：

```bash
bash <(curl -fsSL --connect-timeout 10 --max-time 90 https://cdn.jsdelivr.net/gh/sanmussh/vps-netpilot@main/tcp.sh)
```

手动安装：

```bash
tmp=$(mktemp)
if curl -fsSL --connect-timeout 10 --max-time 90 https://raw.githubusercontent.com/sanmussh/vps-netpilot/main/tcp.sh -o "$tmp" && bash -n "$tmp"; then
    install -m 755 "$tmp" /usr/local/bin/tcp.sh && ln -sf /usr/local/bin/tcp.sh /usr/local/bin/t
fi
rm -f "$tmp"
```

## 怎么选

普通 Web、面板、轻量应用服务器：先选 `3. 通用保守内核调优`。

需要内核 IP 转发的 NAT、路由、VPN 节点：选 `4. 中转增强调优`。仅由 Xray 等应用接收并重新建立连接的代理，通常先选 `3`。

只想单独开 BBR：选 `2. 开启 BBR + FQ`。

选项 `3/4` 已包含 BBR 设置，无需先选 `2`。不安装内核、不强制 BBR3。实际出口未全部验证为 FQ 时会显示“部分启用”，不会覆盖已有的队列或限速规则。

多核 VPS 且看到单核 softirq 压力明显：再选 `5. 网卡多核分发 (RPS)`。

IPv6 出口绕路或不可用：再选 `1. 设置 IPv4 优先解析`。

## 面板预览

```text
==================================================
         VPS NetPilot - TCP/UDP 调优面板
  github.com/sanmussh/vps-netpilot
                   快捷命令: t
==================================================
  1. 设置 IPv4 优先解析
  2. 开启 BBR + FQ
  3. 通用保守内核调优
  4. 中转增强调优
  5. 网卡多核分发 (RPS)
  6. 一键回退脚本配置
  7. 检查并强制同步更新脚本
  8. 彻底卸载面板脚本
  0. 退出脚本
```

## 注意

- 这个脚本更适合网络转发、代理、跨境链路和高延迟链路调优，不建议在独立数据库、复杂防火墙、Kubernetes 节点上无脑执行增强模式。
- `limits.d` 对交互登录通常有效；systemd 服务还需要在 unit 里设置 `LimitNOFILE=`。
- RPS/RFS 和 iptables MSS Clamp 默认不持久化，重启后需要重新执行对应选项，或自行写入 systemd/iptables-persistent。
- 参数逐项应用并读回验证，不支持或被拒绝的项不会写成有效配置；菜单会标出部分生效。其他 sysctl 文件仍可能在重启时覆盖同名设置。
- UDP 全局 `udp_mem` 保留内核计算值。旧版写过该参数的机器，更新并重新运行选项 `3/4` 可移除旧持久化项；缺少原值时，需要重启才能重新计算。
- 快照在 `/var/lib/tcp-opt`，记录各参数第一次被本脚本修改前的值。回退失败会保留快照，卸载也会停止；不会把清空配置等同于全部恢复。
- 旧版只记录四项原值，无法补回缺失的历史值。升级会明确提示；回退可恢复已知值，其余最多恢复到升级时的状态，并保留记录。旧版未标记的防火墙规则、RPS 和 `gai.conf.bak` 需人工核对。

## License

MIT
