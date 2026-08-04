---
title: PHP
order: 104
---
## PHP

CodeTracer supports PHP 8.1 and newer.

The recorder for PHP is hosted in the
[codetracer-php-recorder](https://github.com/metacraft-labs/codetracer-php-recorder)
repo, but you do not install or invoke it yourself — `ct` finds it.

## How to record a PHP program

Use `ct record` to record and `ct replay` to open the result, or `ct run` to
do both in one step:

```bash
ct run hello.php
```

To pass arguments to your script, put them after the filename. They reach PHP
unchanged, including flags:

```bash
ct run script.php --verbose input.txt
```

## Recording a web application

PHP web applications are recorded as a running server rather than a
single script. That has its own guide:
[Live requests — PHP](/usage_guide/live-requests-php).

In short:

```bash
ct record --server --lang php -o ./trace -- php -S 127.0.0.1:8000 -t public/
```

Then, in another terminal, `ct replay -t ./trace` shows each HTTP request as
it arrives, and double-clicking one jumps to the code that served it. This
works with the built-in server and with php-fpm pools; frameworks such as
Laravel, Symfony and WordPress need no special setup.

## What you do not need to do

- You do not need to edit `php.ini` or pass `-d extension=…`. The CodeTracer
  extension is loaded for you.
- You do not need to install the recorder separately. If it is genuinely
  missing, `ct` tells you what is absent and how to install it, and exits
  with a failure rather than leaving an empty recording behind.
