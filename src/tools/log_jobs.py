import fileinput
import json
import colored

JOB_LIMIT = 5
JOB_CELL_WIDTH = 50
JOB_REPEAT_ID_REMIND_MIN = 5

# credit to @rene-d https://gist.github.com/rene-d
# credit to colored and other libs
ANSI_UNDERLINE = "\033[4m"
ANSI_RESET = "\033[0m"
RESERVED_KEYS = {'lvl', 'tid', 'file', 'jobId', 'jobFinish', 'msg', 'ts', 'topics'}

class Logs:
    def __init__(self):
        self.jobs = {}
        self.free = [True] * JOB_LIMIT
        self.job_last_indices = {}
        self.index = 0

    def generate_lines_for_job_log_line(self, line):
        '''
        generate one or more lines for a single line

        | a    | ...
        
        if args

        | a    | ...
        | args | ...

        if a is first

        | jobid (with underline) | ..
        | a                      | ..
    
        if a is not first, but has > JOB_REPEAT_ID_REMIND_MIN lines after the last index of a line for that job
        
        | (jobid (with underline)) | ..
        | a                        | ..

        | 
        if a is last

        | a
        | ----- | ...
        '''
        if len(line) == 0:
            return ''   
        try:
            log = json.loads(line)
        except json.decoder.JSONDecoderError:
            return '# json error'
        job_id = log.get('jobId', '')
        is_first = False
        if job_id not in self.jobs:
            is_first = True
            found_free = False
            for i, is_free in enumerate(self.free):
                if is_free:
                    self.jobs[job_id] = i
                    self.free[i] = False
                    found_free = True
                    break
            if not found_free:
                print('problem: no free, using first')
                self.jobs[job_id] = 0
            if job_id in self.job_last_indices:
                del self.job_last_indices[job_id]
                self

        start = '|'.ljust(JOB_CELL_WIDTH, ' ') * self.jobs[job_id] + '| '
        text = '{} {}'.format(log['msg'], log['file'])
        text_cell = text.ljust(JOB_CELL_WIDTH - 2, ' ')
        end = '|'.ljust(JOB_CELL_WIDTH, ' ') * (JOB_LIMIT - 1 - self.jobs[job_id])

        lines = []
    

        is_remind = not is_first and job_id in self.job_last_indices and self.index > self.job_last_indices[job_id] + JOB_REPEAT_ID_REMIND_MIN

        if is_first or is_remind:
            # credit to @rene-d and colored and other libs
            base_text = job_id if is_first else '({})'.format(job_id)
            base_cell_text = '{}{}{}'.format(ANSI_UNDERLINE, base_text, ANSI_RESET)
            ljust_arg = JOB_CELL_WIDTH + len(ANSI_UNDERLINE) + len(ANSI_RESET) - 2
            base_cell = base_cell_text.ljust(ljust_arg, ' ')
            base_line = start + base_cell + end
            lines.append(base_line)
        
        result = start + text_cell + end
        lines.append(result)
        
        args = []
        for key, arg in log.items():
            if key not in RESERVED_KEYS:
                args.append('{}={}'.format(key, (',\n' + start).join(str(arg).split(','))))
        
        if len(args) > 0:
            args_text = '  (' + (' '.join(args)) + ')'
            # if len(args_text) <= JOB_CELL_WIDTH - 2:
            args_text_cell = args_text.ljust(JOB_CELL_WIDTH - 2, ' ')
            args_line = start + args_text_cell + end

            lines.append(args_line)

        self.job_last_indices[job_id] = self.index
        self.index += 1
        if 'jobFinish' in log and log['jobFinish']:
            index = self.jobs[job_id]
            del self.jobs[job_id]
            self.free[index] = True
            finish_text = '-' * (JOB_CELL_WIDTH - 2)
            finish_line = start + finish_text + end
            lines.append(finish_line)
        return '\n'.join(lines)

logs = Logs()
for line in fileinput.input():
    print(logs.generate_lines_for_job_log_line(line.rstrip()))

