"""Exercise listener selection without signalling real processes."""
import pathlib
import signal
from unittest.mock import Mock, patch

source = pathlib.Path(__file__).with_name('linux-server-tool.sh').read_text()
section = source.split('ssh_cleanup_orphan_listeners() {', 1)[1]
program = section.split("<<'PY'\n", 1)[1].split('\nPY', 1)[0]


class Proc:
    def __init__(self, value):
        self.value = str(value)

    def __truediv__(self, value):
        return Proc(self.value + '/' + str(value))

    def __fspath__(self):
        return self.value

    def read_bytes(self):
        if '/112/' in self.value:
            return b'sshd: root@pts/0'
        return b'sshd: /usr/sbin/sshd -D [listener] 0 of 10-100 startups'

    def read_text(self):
        group = '/other.service' if '/113/' in self.value else '/system.slice/ssh.service'
        return '0::' + group + '\n'


def executable(path):
    return '/usr/bin/python3' if '/114/' in path.value else '/usr/sbin/sshd'


signals = Mock()
with patch('pathlib.Path', Proc), \
        patch('sys.argv', ['test', '/system.slice/ssh.service']), \
        patch('subprocess.check_output', return_value=' '.join(f'pid={p}' for p in range(111, 115))), \
        patch('os.pidfd_open', side_effect=lambda pid: pid + 10000), \
        patch('os.readlink', side_effect=executable), \
        patch('os.close'), \
        patch('select.poll') as poll, \
        patch('signal.pidfd_send_signal', signals):
    poll.return_value.poll.return_value = [(10111, 1)]
    exec(compile(program, '<orphan-cleanup>', 'exec'), {})
signals.assert_called_once_with(10111, signal.SIGTERM)
print('PASS: target only SSH listener in stopped service cgroup; preserve login sessions, other units and other executables')
