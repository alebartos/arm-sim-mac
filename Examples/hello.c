// Build: clang --target=thumbv7m-none-eabi -mcpu=cortex-m3 -O2 -ffreestanding -fno-common -c Examples/hello.c -o hello.o
// Run:   swift run armsim hello.o

static int semihost(int op, const void *arg) {
    register int r0 __asm__("r0") = op;
    register const void *r1 __asm__("r1") = arg;
    __asm__ volatile("bkpt #0xAB" : "+r"(r0) : "r"(r1) : "memory");
    return r0;
}

static void puts_sh(const char *s) { semihost(0x04, s); }

static void put_uint(unsigned v) {
    char buf[12];
    int i = 11;
    buf[i] = 0;
    do { buf[--i] = (char)('0' + v % 10); v /= 10; } while (v);
    puts_sh(&buf[i]);
}

int main(void) {
    puts_sh("Hello from a simulated Cortex-M3!\n");
    unsigned a = 0, b = 1;
    for (int i = 0; i < 40; i++) { unsigned t = a + b; a = b; b = t; }
    puts_sh("fib(40) = ");
    put_uint(a);
    puts_sh("\n");
    return 0;
}
