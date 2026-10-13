# mac_open_6Ghz

用于尝试开启 macOS 6 GHz Wi-Fi 的中文脚本，提供启用、状态检查和恢复原值功能。

它通过修改系统的 `Country` 首选项尝试改变地区判断。**首选项写入成功，不代表网卡采用了该监管域，也不保证所有 macOS 版本都能发现或连接 6 GHz 网络。**

## 快速使用

1. 确认 Mac 内置网卡和路由器支持 Wi-Fi 6E 或 Wi-Fi 7，路由器已开启 6 GHz。
2. 打开「系统设置 → 隐私与安全性 → 定位服务 → 系统服务 → 详细信息」，手动关闭「网络与无线」。不同系统版本的名称可能略有差异。
3. 下载仓库，进入文件所在目录，在终端运行：

   ```bash
   bash wifi6ghz.command enable US
   ```

脚本会要求管理员密码，输入时不会显示字符。默认会短暂关闭再打开当前已开启的 Wi-Fi，然后可在系统的 Wi-Fi 列表中查找你的 6 GHz AP。

也可以双击 `wifi6ghz.command`，通过中文菜单选择操作。如果双击提示没有执行权限，可在终端运行上述命令，或先执行：

```bash
chmod +x wifi6ghz.command
```

`US` 是原方法实测作者使用的配置；参数接受两个大写字母。应按照所在地许可的频段使用，不能把任意国家码视为通用解锁方案。

## 操作命令

| 操作 | 命令 |
| --- | --- |
| 尝试启用，默认使用 `US` | `bash wifi6ghz.command enable` |
| 指定国家码 | `bash wifi6ghz.command enable US` |
| 查看当前连接的频段与国家码 | `bash wifi6ghz.command status` |
| 恢复原来的 `Country` 值 | `bash wifi6ghz.command restore` |
| 查看帮助 | `bash wifi6ghz.command help` |

如果正在通过远程连接操作，可跳过 Wi-Fi 重启，稍后在本机手动关闭再打开 Wi-Fi：

```bash
bash wifi6ghz.command enable US --no-restart
bash wifi6ghz.command restore --no-restart
```

原来已经关闭的 Wi-Fi 会保持关闭。

## 如何验证

如果目标只是发现 AP，在系统设置的 Wi-Fi 列表中确认目标 SSID 出现即可。若同一 SSID 同时用于 2.4、5 和 6 GHz，**仅看到名称不能确认发现的是 6 GHz 频段**；应结合路由器设置或扫描工具的频段信息判断。

若要确认实际连接频段，先连接路由器，再运行：

```bash
bash wifi6ghz.command status
```

只有当前连接的 `Channel` 明确显示 `6GHz`，脚本才报告检测到 6 GHz 连接。输出中的 `Country=US`、`Country Code: US` 或 `802.11ax` 都不能单独证明已连接 6 GHz。

Apple 推荐路由器的 2.4、5 和 6 GHz 使用同一 SSID，以获得更好的兼容性。

## 备份与恢复

首次修改前，脚本保存原始首选项快照，并记录 `Country` 键原本是否存在：

```text
/var/db/macos-wifi6ghz-country
```

备份目录属于 `root`，权限为 `700`。重复启用会保留首次备份。

恢复时只处理 `Country`：原来有该键就写回原字符串，原来没有就删除新增的键。其他首选项在这期间发生的变化会保留。恢复成功后，备份目录会改名归档。

```bash
bash wifi6ghz.command restore
```

**定位开关需要手动恢复。** 运行恢复命令后，请在系统设置中重新开启「网络与无线」。

## 适用范围

- 运行脚本仅需 macOS 自带的 Bash 3.2 和系统工具，无需安装第三方依赖。
- 面向 Mac 内置 Wi-Fi。脚本会拒绝已知不支持 6 GHz 的 M1 系列，以及 M2 MacBook Air 和 13 英寸 M2 MacBook Pro。
- 其他机型仍需查 Apple 技术规格。`802.11ax` 同时用于 Wi-Fi 6 和 6E；当前支持信道列表没有 6 GHz，也可能是地区限制。
- 方法来自 2024 年的个人实测，不是 Apple 官方解锁接口。系统更新或地区判断机制变化后可能失效。
- 脚本修改 `/Library/Preferences/.GlobalPreferences` 的 `Country` 字符串；不修改无线驱动、SIP 或系统定位权限，不安装常驻任务。
- Apple 当前说明，中国大陆不提供 Wi-Fi 6E 或 Wi-Fi 7 的 6 GHz 频段功能。

## 已完成的验证

一次本机尝试使用了 M3 Max MacBook Pro 和 macOS 27.2 测试版。手动关闭「网络与无线」并执行脚本后，确认 `Country=US`、原值备份已建立，且目标 AP 出现在系统 Wi-Fi 列表中。

该记录仅覆盖 AP 名称可见性。观察过程没有单独隔离定位开关与 `Country` 修改的效果，**不能据此单独认定脚本修改国家首选项是成功发现 AP 的原因**。尚未验证实际 6 GHz 关联、连接速率或长期稳定性。

脚本通过了 Bash 3.2 语法检查和 127 项隔离测试断言。测试模拟了首选项读写、硬件信息和网络操作，并使用真实 `plutil` 处理临时属性列表，覆盖重复启用、原值恢复、原键不存在、异常字符串、损坏备份、参数校验和 Wi-Fi 重启失败恢复。

如已安装 Python 3，可在 macOS 上运行隔离测试：

```bash
python3 tests/test_wifi6ghz.py
```

测试只修改临时文件，不修改系统首选项，也不实际重启 Wi-Fi。

## 常见问题

**写入成功，但仍搜不到 AP？**

先确认路由器确实在广播 6 GHz、Mac 硬件支持 6E／7，以及「网络与无线」已关闭。首选项改变后仍可能受到无线驱动、实际监管域或当前系统版本的限制。脚本不能保证绕过这些判断。

**备份或锁目录已存在，脚本退出？**

已有完整备份会自动复用。如果是损坏备份、残留临时目录或异常退出留下的锁，脚本会停止并显示具体路径。请先确认没有其他脚本进程运行，再检查对应目录；不要删除你仍需要的原始备份。

**恢复时为什么不重新开启定位？**

系统定位权限由系统设置管理，脚本没有自动修改这一开关；开启和恢复都需要手动操作。

## 参考资料

- [原方法个人实测（2024 年 3 月 25 日）](https://prafiles.in/some-macos-hacks/)
- [Apple：在 Apple 设备上使用 Wi-Fi 6E 或 Wi-Fi 7 网络](https://support.apple.com/zh-cn/102285)
- [Apple：设备的 Wi-Fi 与以太网技术规格](https://support.apple.com/guide/deployment/wi-fi-ethernet-specifications-apple-devices-dep268652e6c/web)
- [Apple：Wi-Fi 路由器和接入点的推荐设置](https://support.apple.com/zh-cn/102766)
