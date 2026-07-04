#ifndef CODETRACER_WASM_ERRNO_H_
#define CODETRACER_WASM_ERRNO_H_

#define EPERM 1
#define ENOENT 2
#define EIO 5
#define EBADF 9
#define EINVAL 22
#define ENOSYS 38

extern int errno;

#endif // CODETRACER_WASM_ERRNO_H_
