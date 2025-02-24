# copied and then adapted from tools/log_jobs.py 

# log_index <debugger-core-log-path> <python-json-log-path>

import sys
import json
# import colored
from typing import List, Dict, Tuple, Any

# credit to @rene-d https://gist.github.com/rene-d
# credit to colored and other libs
ANSI_UNDERLINE = "\033[4m"
ANSI_RESET = "\033[0m"
RESERVED_KEYS = {'lvl', 'tid', 'file', 'jobId', 'jobFinish', 'msg', 'ts', 'topics', 'kind', 'process'}

NO_INDEX: int = -1

class Log:
    level: str
    timestamp: int
    msg: str
    file: str
    process: str
    args: Dict[str, Any]
    kind: str
    kind_index: int
    kind_instance: str
    component: str

    def __init__(self, level: str, timestamp: int,
                       msg: str, file: str,
                       process: str, args: Dict[str, Any],
                       kind: str, component: str) -> None:
        self.level = level
        self.timestamp = timestamp
        self.msg = msg
        self.file = file
        self.process = process
        self.args = args
        self.kind = kind
        self.kind_index = NO_INDEX
        self.kind_instance = 'none'
        self.component = component

def to_log(line: str, component: str) -> Log:
    parsed = json.loads(line)
    args = {}
    for name, field in parsed.items():
        if name not in RESERVED_KEYS:
            args[name] = field
    return Log(
        level=parsed['lvl'],
        timestamp=int(float(parsed['ts']) * 1_000),
        msg=parsed['msg'],
        file=parsed['file'],
        process=parsed.get('process', 'unknown'),
        args=args,
        kind=parsed.get('kind', 'unknown'),
        component=component)

def process_kind(log: Log, kind_indices: Dict[str, int], python_kinds_and_indices: Dict[str, Tuple[str, int]]):
    if log.component == 'core':
        if log.msg == 'start-new-action':
            if log.kind not in kind_indices:
                kind_indices[log.kind] = 0
            else:
                kind_indices[log.kind] += 1
        else:
            if log.kind not in kind_indices:
                # print('WARN: no kind index (no start-new-action) for ', log.kind, ' ignoring it')
                return

        log.kind_index = kind_indices[log.kind]
        log.kind_instance = '{}-{}'.format(log.kind, log.kind_index)
        # print(log.msg)
        
        # starts a python command call, so we update the kind instance data
        # for its process
        print(log.msg)
        if log.msg == 'write raw' and 'raw' in log.args and \
                log.args['raw'].startswith('codetracer-') and \
                log.process != 'unknown':
            python_kinds_and_indices[log.process] = (log.kind, log.kind_index)
    elif log.component == 'python':
        # print(log.__dict__, python_kinds_and_indices)
        if log.process != 'unknown' and log.process in python_kinds_and_indices:
            log.kind, log.kind_index = python_kinds_and_indices[log.process]
            log.kind_instance = '{}-{}'.format(log.kind, log.kind_index)

def index(core_lines: List[str], python_lines: List[str]):
    logs = \
      [to_log(line, 'core') for line in core_lines if line != ''] + \
      [to_log(line, 'python') for line in python_lines if line != '']

    sorted_logs = sorted(logs, key=lambda log: log.timestamp)
    kind_indices: Dict[str, int] = {}
    python_kinds_and_indices: Dict[str, Tuple[str, int]] = {}
    for log in sorted_logs:
        process_kind(log, kind_indices, python_kinds_and_indices)
    # print([(log.msg, ' ', log.kind_instance) for log in sorted_logs])
    for i, log in enumerate(sorted_logs):
        lines = log.msg.split('\n')
        for field, arg in log.args.items():
            lines.append('  {}={}'.format(field, arg))
        if len(lines) == 0:
            continue
        for line in lines[:-1]:
            print('{}{}'.format(line.ljust(150), log.kind_instance.ljust(20)))
        print('{}{}{}{}'.format(lines[-1].ljust(80), log.file.ljust(50), log.process.ljust(20), log.kind_instance.ljust(20)))
        if i < len(sorted_logs) - 1 and \
                sorted_logs[i + 1].component != log.component and \
                sorted_logs[i + 1].kind_instance == log.kind_instance:
            print('{}{}'.format(' ' * 150, log.kind_instance.ljust(20)))
            print('=> {}:'.format(
                sorted_logs[i + 1].component).ljust(150), end='')
            print(log.kind_instance.ljust(20))
            print('{}{}'.format(' ' * 150, log.kind_instance.ljust(20)))

if len(sys.argv) < 3:
    print('log_index <debugger-core-log-path> <python-json-log-path>')
else:
    debugger_core_log_path = sys.argv[1]
    python_json_log_path = sys.argv[2]
    with open(debugger_core_log_path, 'r') as file:
        raw = file.read()
        debugger_core_log_lines = raw.split('\n')
    with open(python_json_log_path, 'r') as file:
        raw = file.read()
        python_json_log_lines = raw.split('\n')
    
    index(debugger_core_log_lines, python_json_log_lines)
