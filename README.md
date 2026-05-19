# HE IPv6 WireGuard + Phantun Toolkit

一组可公开复用的 Debian/Ubuntu Shell 脚本，用来搭建和维护：

- WireGuard + Phantun FakeTCP 中转隧道
- MK 侧 nftables 端口/端口范围转发
- WireGuard 回程 SNAT 修复
- 游戏优先 QoS 与整机出口限速

脚本不内置任何服务器密码、真实 IP、公钥、域名或节点信息。所有机器相关参数都通过菜单输入、环境变量或运行时提示提供。

## 一键入口

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/GHUNLIL/he-v6-80ms/main/start.sh)"
```

入口菜单支持上下键选择模块。每个子脚本也支持不带参数进入菜单。

## 单独运行

AWS 服务端：

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/GHUNLIL/he-v6-80ms/main/aws-wg-phantun-server.sh)"
```

MK 客户端：

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/GHUNLIL/he-v6-80ms/main/mkcloud-wg-phantun-client.sh)"
```

MK 端口/端口范围转发：

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/GHUNLIL/he-v6-80ms/main/mkcloud-nft-port-forward.sh)"
```

游戏优先 QoS：

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/GHUNLIL/he-v6-80ms/main/linux-game-qos.sh)"
```

SNAT 修复工具：

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/GHUNLIL/he-v6-80ms/main/mkcloud-fix-nft-wg-snat.sh)"
```

## 命令行模式

脚本保留命令行模式，方便自动化：

```bash
sudo bash aws-wg-phantun-server.sh install
sudo bash mkcloud-wg-phantun-client.sh install
sudo bash mkcloud-nft-port-forward.sh add 8080 4.4.4.1 8080 tcp+udp
sudo bash linux-game-qos.sh install
sudo bash mkcloud-fix-nft-wg-snat.sh repair
```

常用参数可以用环境变量覆盖，例如：

```bash
sudo env RATE=400mbit GAME_PORTS=8080 FAKETCP_PORTS=44445 bash linux-game-qos.sh install
```

## 推荐流程

1. 先在 MK 客户端脚本中生成客户端 WireGuard 公钥。
2. 在 AWS 服务端脚本中填入 MK 客户端公钥并完成服务端安装。
3. 回到 MK 客户端脚本，填入 AWS WireGuard 公钥和 AWS IPv6，完成客户端安装。
4. 用 MK 端口转发脚本把入口端口转发到 WireGuard 对端地址。
5. 用 QoS 脚本设置整机总带宽和游戏端口优先级。

如果游戏和下载共用同一个加密入口端口，Linux 无法区分加密包里的业务类型。建议游戏使用一个端口，下载或其他高流量业务使用另一个端口，再只把游戏端口加入 QoS 的 `GAME_PORTS`。
