# VPS NetPilot

VPS一键 TCP/UDP 网络调优面板。不追求“所有机器一键拉满”，而是把常见场景拆成两档：普通业务用保守调优，中转、代理节点、隧道节点再开启增强的转发优化。

## 做了什么

| 功能 | 说明 |
|---|---|
| IPv4 优先 | 适合 IPv6 路由质量差、解析后握手慢的机器 |
| BBR + FQ | 开启 BBR 拥塞控制和 FQ 队列 |
| 通用保守调优 | 调整连接队列、TCP/UDP 缓冲区、conntrack，不默认开启 IP 转发 |
| 中转增强调优 | 在通用调优基础上开启 IP 转发和 MSS Clamp |
| RPS/RFS | 多核 VPS 可尝试分散软中断压力 |
| 回退 | 清理脚本生成的配置，并尽量恢复首次运行前的关键网络参数 |

## 安装

```bash
bash <(curl -sL https://raw.githubusercontent.com/sanmussh/vps-netpilot/main/tcp.sh)
```

备用 CDN：

```bash
bash <(curl -sL https://cdn.jsdelivr.net/gh/sanmussh/vps-netpilot@main/tcp.sh)
```

手动安装：

```bash
wget -O /usr/local/bin/tcp.sh https://raw.githubusercontent.com/sanmussh/vps-netpilot/main/tcp.sh
chmod +x /usr/local/bin/tcp.sh
ln -sf /usr/local/bin/tcp.sh /usr/local/bin/t
t
```

## 怎么选

普通 Web、面板、轻量应用服务器：先选 `3. 通用保守内核调优`。

代理、VPN、WireGuard、隧道、中转节点：选 `4. 中转增强调优`。

只想单独开 BBR：选 `2. 开启 BBR + FQ`。

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
- 回退会尽量恢复首次运行前记录的拥塞算法、队列和转发状态，但不会替你还原其他手工改过的系统配置。

## 来源

项目思路参考了 [666shen/tcp-dashboard](https://github.com/666shen/tcp-dashboard)，重新修改了模式选择、回退逻辑，修复了一键调优遇到的bug，拆分了更保守的默认通用行为。

## License

MIT
