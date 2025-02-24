# python3 start_external_rr_gdb.py <rr-trace-path> <codetracer-trace-path> <name-process>*

import os
import sys

USAGE = '''
    python3 tools/start_external_rr_gdb.py <rr-trace-path> <codetracer-trace-path> <name-process>*
'''

def start_process(rr_trace_path, codetracer_trace_path, name):
    # update the codetracer trace path with pipe
    # eventually delete after run?
    app_caller_pid = int(os.environ.get('CODETRACER_APP_CALLER_PID', '-1'))
    pipe_path = os.path.join(codetracer_trace_path, 'rr_gdb_{}_{}.pipe'.format(app_caller_pid, name))
    os.system('rm -rf {}; mkfifo {}'.format(pipe_path, pipe_path))
    shell = 'libs/rr/bin/rr replay {} -i=mi < {} &'.format(rr_trace_path, pipe_path)
    print(shell)
    os.system(shell)
    os.system('sleep infinity > {} &'.format(pipe_path))
    # TODO: stop the rr and sleep process as well
    # track them or return pid-s?

def start():
    if len(sys.argv) < 3:
        print(USAGE)
        return
    rr_trace_path = sys.argv[1]
    codetracer_trace_path = sys.argv[2]
    process_names = sys.argv[3:]
    for name in process_names:
        start_process(rr_trace_path, codetracer_trace_path, name)

start()

# TODO
# service: if not started, start
# stop
# start a new one
# this way we can also kill them on exit?
# send stop-all <debugger_process_pid>
