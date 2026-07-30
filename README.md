# VPS Network Limiter

[简体中文](README.md) | [English](README.en.md)

一个用于 Linux VPS 的交互式双向网卡限速脚本。只需输入一个 Mbps 数字，脚本会把同一速率应用到上传和下载，并通过 systemd 在重启后自动恢复。

## 功能

- 只输入一个数字，单位固定为 Mbps
- 自动识别默认路由对应的公网网卡
- 使用 TBF 限制上传，使用 IFB + TBF 限制下载
- 自动创建并启用 systemd 开机服务
- 支持查看当前状态、修改速率和恢复不限速
- 严格校验输入与配置，不执行用户输入的命令内容
- 检测已有自定义 `tc`/入站规则，避免直接覆盖
- 新配置应用失败时自动清理或回滚原配置
- 更换默认网卡时清理旧网卡上由本脚本管理的规则

## 系统要求

- Linux VPS
- systemd
- Bash 4+
- root 权限
- `iproute2`、`kmod`
- 内核支持 TBF、IFB 和 `act_mirred`

Debian/Ubuntu 可安装依赖：

```bash
apt update && apt install -y iproute2 kmod
```

## 一键运行

```bash
bash <(curl -Ls https://limit.shuijiao.de)
```

也可以克隆仓库后运行：

```bash
git clone https://github.com/shui1iao/VPS-Network-Limiter.git
cd VPS-Network-Limiter
chmod +x vps-network-limiter.sh
sudo ./vps-network-limiter.sh
```

交互菜单：

```text
VPS 网卡限速
1. 设置或修改限速
2. 查看状态
3. 恢复不限速
0. 退出
```

设置时只需输入数字：

```text
请输入限速 Mbps：100
```

这会将上传和下载都限制为 `100 Mbps`。

也可以直接使用命令：

```bash
# 将上传和下载都限制为 100 Mbps
sudo ./vps-network-limiter.sh set 100

# 查看状态
sudo ./vps-network-limiter.sh status

# 恢复不限速并取消开机自动限速
sudo ./vps-network-limiter.sh restore
```

## Mbps 与 mbit

`Mbps` 就是 `Mbit/s`。Linux `tc` 使用 `mbit` 表示该单位，因此输入：

```text
100
```

会在内部转换为：

```text
100mbit
```

## 持久化文件

首次设置成功后，脚本会安装以下文件：

- 命令：`/usr/local/sbin/vps-network-limiter`
- 配置：`/etc/vps-network-limiter.conf`
- 服务：`/etc/systemd/system/vps-network-limiter.service`

执行 `restore` 会删除限速规则、配置和 systemd 服务，但保留 `/usr/local/sbin/vps-network-limiter`，方便以后重新启用。

## 注意事项

- 下载限速通过 IFB 对进入系统后的流量整形，不会改变商家后台显示的物理端口速率。
- 脚本限制的是整张默认公网网卡，SSH、代理、网站和其他服务会共同受限。
- 如果网卡已经存在脚本无法确认归属的自定义 `tc` 或入站规则，脚本会停止操作，避免覆盖现有配置。
- 设置非常低的速率可能明显影响 SSH 响应，请根据实际需求填写。

## 测试

```bash
bash -n vps-network-limiter.sh tests/run.sh
shellcheck -x vps-network-limiter.sh tests/run.sh
./tests/run.sh
```

测试覆盖输入校验、双向限速、IFB 重定向、开机持久化、恢复、冲突保护、配置回滚和网卡切换。

## License

[MIT](LICENSE)
