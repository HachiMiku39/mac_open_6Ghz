"""测试隔离副本，绝不执行交付脚本对系统首选项的修改操作。"""
from pathlib import Path
import os
import plistlib
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / 'wifi6ghz.command').read_text()
TEST_ROOT = Path(tempfile.mkdtemp(prefix='mac-open-6ghz-tests-'))
checks = 0


def check(condition, message):
    global checks
    assert condition, message
    checks += 1


class Fixture:
    def __init__(self, original=None, exists=True):
        self.path = Path(tempfile.mkdtemp(prefix='case-', dir=TEST_ROOT))
        self.domain = self.path / 'test-prefs'
        self.prefs = self.domain.with_suffix('.plist')
        self.state = self.path / 'backup'
        self.lock = self.path / 'lock'
        self.log = self.path / 'network.log'
        self.power = self.path / 'power'
        self.power.write_text('On')
        if exists:
            self.prefs.write_bytes(plistlib.dumps(original or {}, fmt=plistlib.FMT_XML))
        self.defaults = self.path / 'defaults'
        self.defaults.write_text(f'''#!{os.sys.executable}
from pathlib import Path
import plistlib
import sys
p = Path(sys.argv[2] + '.plist')
try:
    data = plistlib.loads(p.read_bytes()) if p.exists() else {{}}
    op = sys.argv[1]
    if op == 'read':
        if sys.argv[3] not in data: sys.exit(1)
        print(data[sys.argv[3]])
    elif op == 'export':
        if Path('{self.path / 'fail-export'}').exists(): sys.exit(1)
        raw = plistlib.dumps(data, fmt=plistlib.FMT_XML)
        if sys.argv[3] == '-': sys.stdout.buffer.write(raw)
        else: Path(sys.argv[3]).write_bytes(raw)
    elif op == 'write':
        if Path('{self.path / 'fail-write'}').exists(): sys.exit(1)
        assert sys.argv[4] == '-string'
        data[sys.argv[3]] = sys.argv[5]
        p.write_bytes(plistlib.dumps(data, fmt=plistlib.FMT_XML))
    elif op == 'delete':
        del data[sys.argv[3]]
        p.write_bytes(plistlib.dumps(data, fmt=plistlib.FMT_XML))
    else: sys.exit(9)
except Exception as error:
    print(error, file=sys.stderr)
    sys.exit(1)
''')
        self.profiler = self.path / 'profiler'
        self.report = self.path / 'report'
        self.report.write_text('''Wi-Fi:
  Interfaces:
    en7:
      Supported PHY Modes: 802.11 a/b/g/n/ac/ax
      Supported Channels: 1 (2GHz), 37 (6GHz)
      Current Network Information:
        PRIVATE-CURRENT-SSID:
          PHY Mode: 802.11ax
          Channel: 37 (6GHz, 160MHz)
          Country Code: US
          BSSID: PRIVATE-BSSID
      Other Local Wi-Fi Networks:
        PRIVATE-NEIGHBOR-SSID:
          Channel: 5 (6GHz, 160MHz)
          Country Code: US
''')
        self.profiler.write_text(f'#!/bin/bash\n/bin/cat "{self.report}"\n')
        self.network = self.path / 'networksetup'
        self.network.write_text(f'''#!/bin/bash
printf '%s\\n' "$*" >> "{self.log}"
case "$1" in
  -listallhardwareports)
    printf 'Hardware Port: Ethernet\\nDevice: en0\\n\\nHardware Port: Wi-Fi\\nDevice: en7\\nEthernet Address: PRIVATE-MAC\\n' ;;
  -getairportpower) printf 'Wi-Fi Power (%s): %s\\n' "$2" "$(/bin/cat '{self.power}')" ;;
  -setairportpower)
    if [ "$3" = off ]; then printf Off > '{self.power}'; else printf On > '{self.power}'; fi
    if [ -e '{self.path / 'fail-off'}' ] && [ "$3" = off ]; then exit 1; fi ;;
  *) exit 9 ;;
esac
''')
        self.sysctl = self.path / 'sysctl'
        self.chip = self.path / 'chip'
        self.chip.write_text('Apple M4 Pro')
        self.model = self.path / 'model'
        self.model.write_text('Mac16,7')
        self.sysctl.write_text(f'''#!/bin/bash
case "$2" in
  hw.model) /bin/cat '{self.model}' ;;
  machdep.cpu.brand_string) /bin/cat '{self.chip}' ;;
  *) exit 1 ;;
esac
''')
        for file in (self.profiler, self.network, self.sysctl, self.defaults):
            file.chmod(0o700)
        src = SOURCE.replace('PREFS_DOMAIN=/Library/Preferences/.GlobalPreferences',
                             f'PREFS_DOMAIN="{self.domain}"')
        src = src.replace('STATE_DIR=/var/db/macos-wifi6ghz-country', f'STATE_DIR="{self.state}"')
        src = src.replace('LOCK_DIR=/var/run/macos-wifi6ghz-country.lock', f'LOCK_DIR="{self.lock}"')
        src = src.replace('NETWORKSETUP=/usr/sbin/networksetup', f'NETWORKSETUP="{self.network}"')
        src = src.replace('DEFAULTS=/usr/bin/defaults', f'DEFAULTS="{self.defaults}"')
        src = src.replace('PROFILER=/usr/sbin/system_profiler', f'PROFILER="{self.profiler}"')
        src = src.replace('/usr/sbin/sysctl', str(self.sysctl))
        src = src.replace('[ "$EUID" -ne 0 ]', '[ 1 -eq 0 ]')
        src = src.replace('exec /usr/bin/sudo /bin/bash', "fail '测试中禁止执行管理员提权'; exec /bin/bash")
        src = src.replace('"$STATE_DIR")" = 0 ]', f'"$STATE_DIR")" = {os.getuid()} ]')
        src = src.replace('/bin/sleep 2', '/bin/sleep 0')
        check('/Library/Preferences/' not in src, '测试副本中仍包含系统首选项路径')
        check('/var/db/' not in src and '/var/run/' not in src, '测试副本中仍包含系统状态目录')
        self.script = self.path / 'script.command'
        self.script.write_text(src)

    def run(self, *args, ok=True):
        result = subprocess.run(['/bin/bash', str(self.script), *args], text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
        check((result.returncode == 0) == ok,
              f'操作返回了非预期退出状态 {args}: {result.returncode}\n{result.stdout}\n{result.stderr}')
        check(not self.lock.exists(), '运行锁未清理')
        return result.stdout + result.stderr

    def read(self):
        return plistlib.loads(self.prefs.read_bytes())

    def set(self, key, value):
        subprocess.run([str(self.defaults), 'write', str(self.domain), key, '-string', value],
                       check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


try:
    # 已有国家首选项、重复启用，以及恢复时保留其他首选项的后续修改。
    f = Fixture({'Country': 'CN', 'Unrelated': 'original'})
    f.run('enable', 'US', '--no-restart')
    check(f.read()['Country'] == 'US', '启用操作未写入国家首选项')
    check(plistlib.loads((f.state / 'original.plist').read_bytes())['Country'] == 'CN', '原值未备份')
    f.run('enable', 'JP', '--no-restart')
    check(plistlib.loads((f.state / 'original.plist').read_bytes())['Country'] == 'CN', '重复运行覆盖了首次备份')
    f.set('Unrelated', 'changed-later')
    f.run('restore', '--no-restart')
    check(f.read() == {'Country': 'CN', 'Unrelated': 'changed-later'}, '恢复操作覆盖了其他首选项')
    check(not f.state.exists() and list(f.path.glob('backup.restored.*')), '恢复后的备份未归档')
    f.run('restore', '--no-restart')
    check(f.read()['Country'] == 'CN', '重复恢复修改了状态')

    # 原键不存在、原文件不存在，以及精确保留特殊字符串。
    for original, exists in [({'Unrelated': 'keep'}, True), ({}, False),
                             ({'Country': ''}, True), ({'Country': 'CN\n\n'}, True)]:
        f = Fixture(original, exists=exists)
        f.run('enable', '--no-restart')
        f.run('restore', '--no-restart')
        check(f.read() == original, f'未恢复原值: {original!r}')

    # 在写入前拒绝非字符串的国家首选项。
    f = Fixture({'Country': 12, 'Unrelated': 'keep'})
    f.run('enable', '--no-restart', ok=False)
    check(f.read()['Country'] == 12 and not f.state.exists(), '错误地修改了不支持的数据类型')
    check(not Path(str(f.state) + '.pending').exists(), '失败后未清理临时备份')

    # 无效命令参数不得修改首选项或重启网络。
    f = Fixture({'Country': 'CN'})
    for args in [('enable', 'USA'), ('enable', 'us'), ('enable', 'US', 'JP'),
                 ('restore', 'US'), ('status', '--no-restart'), ('unknown',)]:
        f.run(*args, ok=False)
        check(f.read()['Country'] == 'CN' and not f.log.exists(), '无效参数触发了修改操作')

    # 不支持的硬件不得创建备份或修改首选项。
    f = Fixture({'Country': 'CN'})
    f.chip.write_text('Apple M1 Max')
    f.run('enable', '--no-restart', ok=False)
    check(f.read()['Country'] == 'CN' and not f.state.exists(), '未拦截不支持的 M1 硬件')
    f.chip.write_text('Apple M2')
    f.model.write_text('Mac14,15')
    f.run('enable', '--no-restart', ok=False)
    check(f.read()['Country'] == 'CN' and not f.state.exists(), '未拦截不支持的 M2 MacBook Air')

    # 无线接口识别、重启、保持原关闭状态和失败恢复。
    f = Fixture({'Country': 'CN'})
    f.run('enable')
    log = f.log.read_text()
    check('-setairportpower en7 off' in log and '-setairportpower en7 on' in log, '无线接口错误或未执行重启')
    check(f.power.read_text() == 'On', '无线网络未重新开启')
    f = Fixture({'Country': 'CN'})
    f.power.write_text('Off')
    f.run('enable')
    check('-setairportpower' not in f.log.read_text(), '改变了原来关闭的无线状态')
    f = Fixture({'Country': 'CN'})
    (f.path / 'fail-off').touch()
    f.run('enable', ok=False)
    check(f.power.read_text() == 'On' and f.state.exists(), '失败后未恢复无线网络或未保留备份')

    # 状态输出隐藏名称和地址，避免把邻居网络误判为当前连接。
    f = Fixture({'Country': 'US'})
    out = f.run('status')
    check('结果：检测到当前连接使用 6 GHz。' in out, '未正确识别当前 6 GHz 连接')
    check('PRIVATE-' not in out, '状态输出泄漏了网络名称或地址')
    f.report.write_text(f.report.read_text().replace('Channel: 37 (6GHz, 160MHz)', 'Channel: 36 (5GHz, 80MHz)'))
    out = f.run('status')
    check('结果：尚未检测到当前连接使用 6 GHz。' in out, '邻居网络造成了当前频段误判')

    # 不得应用损坏的备份或符号链接备份目录。
    f = Fixture({'Country': 'CN'})
    f.run('enable', '--no-restart')
    (f.state / 'original.plist').write_text('corrupt')
    f.run('restore', '--no-restart', ok=False)
    check(f.read()['Country'] == 'US', '使用了损坏的备份')
    f = Fixture({'Country': 'CN'})
    f.state.symlink_to(f.path, target_is_directory=True)
    f.run('enable', '--no-restart', ok=False)
    check(f.read()['Country'] == 'CN', '接受了符号链接备份目录')

    # 首选项读取或导出失败不得误判为原键不存在。
    f = Fixture({'Unrelated': 'keep'})
    f.run('enable', '--no-restart')
    (f.path / 'fail-export').touch()
    f.run('restore', '--no-restart', ok=False)
    check(f.read()['Country'] == 'US' and f.state.exists(), '导出失败被误判为恢复成功')
    f = Fixture({'Country': 'CN'})
    (f.path / 'fail-write').touch()
    f.run('enable', '--no-restart', ok=False)
    check(f.read()['Country'] == 'CN' and f.state.exists(), '写入失败后丢失了原值或备份')
    print(f'通过：{checks} 项断言；属性列表隔离，首选项命令、硬件和网络操作均为模拟。')
finally:
    shutil.rmtree(TEST_ROOT)
