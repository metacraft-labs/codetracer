    .section .rodata
message:
    .ascii "assembly fixture passed\n"
    .set message_len, . - message

    .section .text
    .globl main
main:
    push %rbp
    mov %rsp, %rbp
    mov $1, %edi
    lea message(%rip), %rsi
    mov $message_len, %edx
    call write@PLT
    xor %eax, %eax
    pop %rbp
    ret
