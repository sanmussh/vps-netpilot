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
| 系统 DNS | 查看解析入口和可识别的上游，设置 1.1.1.1 首选、1.0.0.1 备选，并可独立恢复 |
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

只想单独开 BBR：选 `2. 开启 BBR / 设置默认 FQ`。

选项 `3/4` 已包含 BBR 设置，无需先选 `2`。不安装内核、不强制 BBR3。BBR 状态按系统默认 TCP 算法显示，实际队列独立显示名称（如 `ens17: mq + fq_codel`），不会覆盖已有的队列或限速规则。

多核 VPS 且看到单核 softirq 压力明显：再选 `5. 网卡多核分发 (RPS)`。

IPv6 出口绕路或不可用：再选 `1. 设置 IPv4 优先解析`。

怀疑 DNS 解析慢：选 `9. 系统 DNS 检测与设置`，先查看，再选择是否设置 `1.1.1.1` 首选、`1.0.0.1` 备选。此功能独立于选项 `3/4`，不会自动开启。

## 面板预览

```text
==================================================
         VPS NetPilot - TCP/UDP 调优面板
  github.com/sanmussh/vps-netpilot
                   快捷命令: t
==================================================
  1. 设置 IPv4 优先解析
  2. 开启 BBR / 设置默认 FQ
  3. 通用保守内核调优
  4. 中转增强调优
  5. 网卡多核分发 (RPS)
  6. 一键回退脚本配置
  7. 检查并强制同步更新脚本
  8. 彻底卸载面板脚本
  9. 系统 DNS 检测与设置
  0. 退出脚本
```

## 注意

- DNS 持久化使用 NetworkManager 全局配置或 systemd-resolved 配置。resolved 的 `/run/systemd/resolve/resolv.conf` 上游列表模式会备份原链接，再切换至本地 stub 入口 `127.0.0.53`，由其使用配置的 DNS 列表；回退会还原原链接。普通静态 `resolv.conf` 需确认没有其他程序接管，独立 DHCP、resolvconf、未知链接等暂不自动修改。不锁死文件、不重启网卡；加载或解析验证失败会尝试恢复，失败时保留快照，选项 `6/8` 也包含 DNS 回退。
- 首选/备选表示配置顺序，并非严格故障切换；systemd-resolved 可能在切换后继续使用备选。`1.1.1.1` 和 `1.0.0.1` 均为 Cloudflare DNS，不能保证解析更快；验证通过只表示配置读回与解析检查通过，不代表两个上游均单独测速成功。已应用旧 DNS 列表的机器，需先在 DNS 子菜单恢复，再应用新列表。
- `127.0.0.53` 是本地解析入口，不是真正上游。resolved 下专用域仍可走内网 DNS；NetworkManager 全局设置会覆盖连接级 DNS，内网/VPN 环境请慎用。
- 这个脚本更适合网络转发、代理、跨境链路和高延迟链路调优，不建议在独立数据库、复杂防火墙、Kubernetes 节点上无脑执行增强模式。
- `limits.d` 对交互登录通常有效；systemd 服务还需要在 unit 里设置 `LimitNOFILE=`。
- RPS/RFS 和 iptables MSS Clamp 默认不持久化，重启后需要重新执行对应选项，或自行写入 systemd/iptables-persistent。
- 参数逐项应用并读回验证，不支持或被拒绝的项不会写成有效配置；菜单会标出部分生效。其他 sysctl 文件仍可能在重启时覆盖同名设置。
- UDP 全局 `udp_mem` 保留内核计算值。旧版写过该参数的机器，更新并重新运行选项 `3/4` 可移除旧持久化项；缺少原值时，需要重启才能重新计算。
- 快照在 `/var/lib/tcp-opt`，记录各参数第一次被本脚本修改前的值。回退失败会保留快照，卸载也会停止；不会把清空配置等同于全部恢复。
- 旧版只记录四项原值，无法补回缺失的历史值。升级会明确提示；回退可恢复已知值，其余最多恢复到升级时的状态，并保留记录。旧版未标记的防火墙规则、RPS 和 `gai.conf.bak` 需人工核对。

## License

MIT
