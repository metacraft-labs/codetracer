import sys, tokenize

with open(sys.argv[1], 'r') as f:
    tokens = tokenize.tokenize(f)

