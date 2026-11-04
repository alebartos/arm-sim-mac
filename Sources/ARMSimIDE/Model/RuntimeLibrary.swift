/// Tiny run-time support library linked into every program (all symbols weak).
/// Provides what clang emits calls to on Cortex-M without a C library:
/// memcpy/memset family and the AEABI division / 64-bit helpers needed on Cortex-M0.
enum RuntimeLibrary {
    static let source = #"""
    typedef unsigned int u32;
    typedef int i32;
    typedef unsigned long long u64;
    typedef long long i64;
    typedef unsigned char u8;

    #define WEAK __attribute__((weak))

    WEAK void *memcpy(void *d, const void *s, u32 n) {
        volatile u8 *dd = d; const u8 *ss = s;
        while (n--) *dd++ = *ss++;
        return d;
    }
    WEAK void *memmove(void *d, const void *s, u32 n) {
        volatile u8 *dd = d; const u8 *ss = s;
        if (dd < ss) { while (n--) *dd++ = *ss++; }
        else { dd += n; ss += n; while (n--) *--dd = *--ss; }
        return d;
    }
    WEAK void *memset(void *d, int c, u32 n) {
        volatile u8 *dd = d;
        while (n--) *dd++ = (u8)c;
        return d;
    }
    WEAK int memcmp(const void *a, const void *b, u32 n) {
        const u8 *x = a, *y = b;
        for (; n; n--, x++, y++) if (*x != *y) return *x - *y;
        return 0;
    }
    WEAK u32 strlen(const char *s) { const char *p = s; while (*p) p++; return (u32)(p - s); }

    WEAK void __aeabi_memcpy(void *d, const void *s, u32 n) { memcpy(d, s, n); }
    WEAK void __aeabi_memcpy4(void *d, const void *s, u32 n) { memcpy(d, s, n); }
    WEAK void __aeabi_memcpy8(void *d, const void *s, u32 n) { memcpy(d, s, n); }
    WEAK void __aeabi_memmove(void *d, const void *s, u32 n) { memmove(d, s, n); }
    WEAK void __aeabi_memmove4(void *d, const void *s, u32 n) { memmove(d, s, n); }
    WEAK void __aeabi_memmove8(void *d, const void *s, u32 n) { memmove(d, s, n); }
    WEAK void __aeabi_memset(void *d, u32 n, int c) { memset(d, c, n); }
    WEAK void __aeabi_memset4(void *d, u32 n, int c) { memset(d, c, n); }
    WEAK void __aeabi_memset8(void *d, u32 n, int c) { memset(d, c, n); }
    WEAK void __aeabi_memclr(void *d, u32 n) { memset(d, 0, n); }
    WEAK void __aeabi_memclr4(void *d, u32 n) { memset(d, 0, n); }
    WEAK void __aeabi_memclr8(void *d, u32 n) { memset(d, 0, n); }

    static u32 udiv32(u32 n, u32 d, u32 *rem) {
        u32 q = 0, r = 0;
        if (d == 0) { *rem = n; return 0; }
        for (int i = 31; i >= 0; i--) {
            r = (r << 1) | ((n >> i) & 1u);
            if (r >= d) { r -= d; q |= 1u << i; }
        }
        *rem = r;
        return q;
    }
    WEAK u32 __aeabi_uidiv(u32 n, u32 d) { u32 r; return udiv32(n, d, &r); }
    WEAK i32 __aeabi_idiv(i32 n, i32 d) {
        u32 r, q = udiv32(n < 0 ? 0u - (u32)n : (u32)n, d < 0 ? 0u - (u32)d : (u32)d, &r);
        return ((n < 0) != (d < 0)) ? -(i32)q : (i32)q;
    }
    /* quotient in r0, remainder in r1 (returned as a 64-bit value) */
    WEAK u64 __aeabi_uidivmod(u32 n, u32 d) {
        u32 r, q = udiv32(n, d, &r);
        return (u64)q | ((u64)r << 32);
    }
    WEAK u64 __aeabi_idivmod(i32 n, i32 d) {
        u32 r, q = udiv32(n < 0 ? 0u - (u32)n : (u32)n, d < 0 ? 0u - (u32)d : (u32)d, &r);
        i32 sq = ((n < 0) != (d < 0)) ? -(i32)q : (i32)q;
        i32 sr = n < 0 ? -(i32)r : (i32)r;
        return (u64)(u32)sq | ((u64)(u32)sr << 32);
    }

    u64 __armsim_udivmod64(u64 n, u64 d, u64 *rem) {
        u64 q = 0, r = 0;
        if (d == 0) { *rem = n; return 0; }
        for (int i = 63; i >= 0; i--) {
            u32 hi = (u32)(r >> 32), lo = (u32)r;
            hi = (hi << 1) | (lo >> 31);
            lo = (lo << 1) | (u32)((i >= 32 ? ((u32)(n >> 32) >> (i - 32)) : ((u32)n >> i)) & 1u);
            r = ((u64)hi << 32) | lo;
            if (r >= d) {
                r -= d;
                if (i >= 32) q |= (u64)(1u << (i - 32)) << 32; else q |= (u64)(1u << i);
            }
        }
        *rem = r;
        return q;
    }
    i64 __armsim_divmod64(i64 n, i64 d, i64 *rem) {
        u64 un = n < 0 ? 0ull - (u64)n : (u64)n, ud = d < 0 ? 0ull - (u64)d : (u64)d, r;
        u64 q = __armsim_udivmod64(un, ud, &r);
        *rem = n < 0 ? -(i64)r : (i64)r;
        return ((n < 0) != (d < 0)) ? -(i64)q : (i64)q;
    }

    /* quotient in r0:r1, remainder in r2:r3 */
    __attribute__((naked, weak)) void __aeabi_uldivmod(void) {
        __asm volatile(
            "push {r4, lr}\n"
            "sub sp, #16\n"
            "add r4, sp, #8\n"
            "str r4, [sp]\n"
            "bl __armsim_udivmod64\n"
            "ldr r2, [sp, #8]\n"
            "ldr r3, [sp, #12]\n"
            "add sp, #16\n"
            "pop {r4, pc}\n");
    }
    __attribute__((naked, weak)) void __aeabi_ldivmod(void) {
        __asm volatile(
            "push {r4, lr}\n"
            "sub sp, #16\n"
            "add r4, sp, #8\n"
            "str r4, [sp]\n"
            "bl __armsim_divmod64\n"
            "ldr r2, [sp, #8]\n"
            "ldr r3, [sp, #12]\n"
            "add sp, #16\n"
            "pop {r4, pc}\n");
    }

    static u64 mul32x32(u32 a, u32 b) {
        u32 al = a & 0xFFFF, ah = a >> 16, bl = b & 0xFFFF, bh = b >> 16;
        u32 ll = al * bl, lh = al * bh, hl = ah * bl, hh = ah * bh;
        u32 mid = (ll >> 16) + (lh & 0xFFFF) + (hl & 0xFFFF);
        u32 lo = (ll & 0xFFFF) | (mid << 16);
        u32 hi = hh + (lh >> 16) + (hl >> 16) + (mid >> 16);
        return ((u64)hi << 32) | lo;
    }
    WEAK u64 __aeabi_lmul(u64 a, u64 b) {
        u64 p = mul32x32((u32)a, (u32)b);
        u32 hi = (u32)(p >> 32) + (u32)a * (u32)(b >> 32) + (u32)(a >> 32) * (u32)b;
        return ((u64)hi << 32) | (u32)p;
    }
    WEAK u64 __aeabi_llsl(u64 v, int s) {
        u32 lo = (u32)v, hi = (u32)(v >> 32);
        if (s >= 32) { hi = lo << (s - 32); lo = 0; }
        else if (s > 0) { hi = (hi << s) | (lo >> (32 - s)); lo <<= s; }
        return ((u64)hi << 32) | lo;
    }
    WEAK u64 __aeabi_llsr(u64 v, int s) {
        u32 lo = (u32)v, hi = (u32)(v >> 32);
        if (s >= 32) { lo = hi >> (s - 32); hi = 0; }
        else if (s > 0) { lo = (lo >> s) | (hi << (32 - s)); hi >>= s; }
        return ((u64)hi << 32) | lo;
    }
    WEAK i64 __aeabi_lasr(i64 v, int s) {
        u32 lo = (u32)v; i32 hi = (i32)(v >> 32);
        if (s >= 32) { lo = (u32)(hi >> (s - 32)); hi = hi < 0 ? -1 : 0; }
        else if (s > 0) { lo = (lo >> s) | ((u32)hi << (32 - s)); hi >>= s; }
        return (i64)(((u64)(u32)hi << 32) | lo);
    }
    """#
}
