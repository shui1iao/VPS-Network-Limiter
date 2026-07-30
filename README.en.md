# VPS Network Limiter

[简体中文](README.md) | [English](README.en.md)

An interactive bidirectional bandwidth limiter for Linux VPS instances. Enter one value in Mbps, and the script applies the same limit to upload and download traffic. A systemd service restores the rules automatically after reboot.

## Features

- Accepts one numeric value with a fixed Mbps unit
- Detects the public interface from the default route
- Uses TBF for upload shaping and IFB + TBF for download shaping
- Installs and enables a systemd service automatically
- Supports status inspection, rate changes, and full restoration
- Strictly validates user input and saved configuration
- Refuses to overwrite unrecognized custom `tc` or ingress rules
- Cleans up or rolls back when a new configuration fails
- Removes managed rules from the old interface when the default interface changes

## Requirements

- Linux VPS
- systemd
- Bash 4+
- Root privileges
- `iproute2` and `kmod`
- Kernel support for TBF, IFB, and `act_mirred`

Install dependencies on Debian/Ubuntu:

```bash
apt update && apt install -y iproute2 kmod
```

## One-Line Usage

```bash
bash <(curl -Ls https://limit.shuijiao.de)
```

You can also clone the repository:

```bash
git clone https://github.com/shui1iao/VPS-Network-Limiter.git
cd VPS-Network-Limiter
chmod +x vps-network-limiter.sh
sudo ./vps-network-limiter.sh
```

Interactive menu:

```text
VPS 网卡限速
1. 设置或修改限速
2. 查看状态
3. 恢复不限速
0. 退出
```

Enter a single number when prompted:

```text
请输入限速 Mbps：100
```

This limits both upload and download traffic to `100 Mbps`.

Direct commands are also available:

```bash
# Limit upload and download to 100 Mbps
sudo ./vps-network-limiter.sh set 100

# Show current status
sudo ./vps-network-limiter.sh status

# Remove all managed limits and disable boot persistence
sudo ./vps-network-limiter.sh restore
```

## Mbps and mbit

`Mbps` means `Mbit/s`. Linux `tc` spells this unit as `mbit`, so this input:

```text
100
```

is converted internally to:

```text
100mbit
```

## Persistent Files

After the first successful setup, the script installs:

- Command: `/usr/local/sbin/vps-network-limiter`
- Configuration: `/etc/vps-network-limiter.conf`
- Service: `/etc/systemd/system/vps-network-limiter.service`

The `restore` command removes the shaping rules, configuration, and systemd unit. It keeps `/usr/local/sbin/vps-network-limiter` so the limiter can be enabled again later.

## Notes

- Download shaping uses IFB after traffic reaches the operating system. It does not change the physical port speed shown by the VPS provider.
- The limit applies to the entire default public interface, so SSH, proxies, websites, and other services share the configured bandwidth.
- If the interface already has custom `tc` or ingress rules that the script cannot identify as its own, it stops instead of overwriting them.
- Extremely low limits can make SSH noticeably less responsive.

## Testing

```bash
bash -n vps-network-limiter.sh tests/run.sh
shellcheck -x vps-network-limiter.sh tests/run.sh
./tests/run.sh
```

The tests cover input validation, bidirectional shaping, IFB redirection, boot persistence, restoration, conflict protection, rollback, and interface changes.

## License

[MIT](LICENSE)
