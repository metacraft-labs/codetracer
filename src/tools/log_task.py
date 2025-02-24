import sys
import os.path
import subprocess
import re
from dataclasses import dataclass
from colored import fg, style  # noqa
from typing import List


@dataclass
class LogLine:
    log_file: str
    subsystem: str
    time: float
    level: str
    task_id: str
    location: str
    text: str

    def time_since(self, other: float) -> float:
        return self.time - other


def time_of(line: str) -> float:
    matches = re.match(r'.+ time=(\d+\.?\d*).*', line)
    # print('time_of ', line, matches)
    if matches and len(matches.groups()) > 0:
        return float(matches.groups()[0])
    else:
        return 0.0


def subsystem_for_log_file(log_file: str) -> str:
    if log_file.startswith('frontend'):
        return 'FRONTEND'
    elif log_file.startswith('index'):
        return 'INDEX'
    elif log_file.startswith('dispatcher'):
        return 'DISPATCHER'
    elif log_file.startswith('task_process'):
        return 'TASK_PROCESS'
    elif log_file.startswith('script'):
        return 'SCRIPTS'
    else:
        return 'UNKNOWN'


# def level_and_clean_content_for_line(line: str, subsystem: str) -> str:
#     if subsystem == 'FRONTEND':
#         if ':INFO:CONSOLE' in line:
#             level = 'INFO'
#         elif ':WARN:CONSOLE' in line:
#             level = 'WARN'
#         elif ':ERROR:CONSOLE' in line:
#             level = 'ERROR'
#         else:
#             level = 'DEBUG'  # default
#         # [..] "<content>", source: ..
#         clean_content = line[line.find('] "') + 3:]
#         return level, clean_content
#     else:
#         raw_level, _, clean_content = line.partition(' ')
#         if raw_level == 'DBG':
#             level = 'DEBUG'
#         elif raw_level == 'WRN':
#             level = 'WARN'
#         elif raw_level == 'ERR':
#             level = 'ERROR'
#         elif raw_level == 'INF':
#             level = 'INFO'
#         else:
#             level = 'DEBUG'  # default
#         return level, clean_content


COLORS_FOR_SUBSYSTEMS = {
    # weird, but `sorted(colored.colored('blue').paint.keys())`
    # shows all valid colors i think
    'FRONTEND': fg('yellow'),
    'INDEX': fg('pink_1'),
    'DISPATCHER': fg('green'),
    'TASK_PROCESS': fg('purple_1a'),
    'SCRIPTS': fg('cyan'),
    'UNKNOWN': fg('white')
}

RESET = style('RESET')


def run(pid: int, task_id: str):
    res = subprocess.run([
        'bash',
        '-c',
        f'grep {task_id} /tmp/codetracer/run-{pid}/*.log'],
        # 'grep',
        # task_id,
        # f'/tmp/codetracer/run-{pid}/*.log'],
        stdout=subprocess.PIPE)
    lines = res.stdout.decode('utf8').\
        split('\n')

    # for now using
    # codetracer_output or compatible format in logs:
    # <time:18> | <level:5> | <task-id:17> | <file:line:28> | <text>

    # log_file subsystem time level task_id location text
    lines_with_metadata: List[LogLine] = []
    for line in lines:
        log_path, _, raw_line = line.partition(':')
        log_file = os.path.basename(log_path)
        subsystem = subsystem_for_log_file(log_file)
        if subsystem == 'FRONTEND':
            real_log_line = raw_line[raw_line.find('] "') + 3:]
        else:
            real_log_line = raw_line
        tokens = [token.strip() for token in real_log_line.split('|', 4)]
        # print(tokens)
        # print(len(tokens))
        if len(tokens) != 5:
            continue
        time = float(tokens[0])
        level, task_id, location, text = tokens[1:]
        if len(text.strip()) > 0:
            lines_with_metadata.append(
                LogLine(
                    log_file, subsystem, time, level,
                    task_id, location, text))
    sorted_lines = sorted(
        lines_with_metadata,
        key=lambda a: a.time)

    last_subsystem = ''
    last_time = 0.0
    start = 0.0

    if len(sorted_lines) > 0:
        print('')
        print(f'time in beginning: {sorted_lines[0].time}')
        start = sorted_lines[0].time
    for log_line in sorted_lines:
        subsystem_color = COLORS_FOR_SUBSYSTEMS[log_line.subsystem]
        if log_line.subsystem != last_subsystem:
            print(subsystem_color)
            print('=================')
            print(log_line.subsystem)
            print('-----------------')
            print(RESET)
        # time_text = str(log_line.time).ljust(18)
        level_text = log_line.level.ljust(5)
        location_text = log_line.location.ljust(28)
        time_since_start = log_line.time_since(start)
        time_since_previous_in_ms = 1_000 * log_line.time_since(last_time)
        time_since_start_text = (f'{time_since_start:.6f}s').ljust(12)
        time_since_previous_text = (f'{time_since_previous_in_ms:.3f}ms').ljust(12)
        time_prelude = f'{time_since_start_text} | {time_since_previous_text} |'
        raw_prelude = f'{time_prelude} | {level_text} | {location_text} |'
        if log_line.level == 'WARN':
            eventual_level_color = fg('yellow')
        elif log_line.level == 'ERROR':
            eventual_level_color = fg('red')
        else:
            eventual_level_color = ''  # none: default

        output_line = f'{subsystem_color}{raw_prelude}{RESET}{eventual_level_color}{log_line.text}{RESET}'

        print(output_line)

        last_subsystem = log_line.subsystem
        last_time = log_line.time


pid = int(sys.argv[1])
task_id = sys.argv[2]


try:
    run(pid, task_id)
except Exception as e:
    print(RESET)
    raise e
