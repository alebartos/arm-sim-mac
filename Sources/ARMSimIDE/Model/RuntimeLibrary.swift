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

    /* ---- Soft floating point (AEABI run-time helpers), IEEE 754 round-to-nearest-even.
       Doubles travel as u64 in r0:r1 like the soft-float ABI. A finite value is handled unpacked as
       sign, exponent e and significand m with its leading 1 at bit 62: value = m * 2^(e - 62).
       Float operations go through double: exact for +, -, *, / since 53 >= 2 * 24 + 2. ---- */
    #define D_NAN 0x7FF8000000000000ull
    #define D_INF 0x7FF0000000000000ull
    #define D_FRAC 0x000FFFFFFFFFFFFFull
    enum { K_ZERO, K_FINITE, K_INF, K_NAN };
    static int clz64(u64 v) {   /* v != 0; no CLZ instruction on Cortex-M0 */
        int n = 0;
        if (!(v >> 32)) { n += 32; v <<= 32; }
        if (!(v >> 48)) { n += 16; v <<= 16; }
        if (!(v >> 56)) { n += 8; v <<= 8; }
        if (!(v >> 60)) { n += 4; v <<= 4; }
        if (!(v >> 62)) { n += 2; v <<= 2; }
        if (!(v >> 63)) { n += 1; }
        return n;
    }
    static u64 shift_sticky(u64 m, int n) {
        if (n <= 0) return m;
        if (n >= 63) return m != 0;
        return (m >> n) | ((m & ((1ull << n) - 1)) != 0);
    }
    static int d_unpack(u64 a, u32 *s, int *e, u64 *m) {
        int be = (int)((a >> 52) & 0x7FF);
        u64 f = a & D_FRAC;
        *s = (u32)(a >> 63);
        if (be == 0x7FF) return f ? K_NAN : K_INF;
        if (be == 0) { if (!f) return K_ZERO; *e = -1022; *m = f; }
        else { *e = be - 1023; *m = f | (1ull << 52); }
        int n = clz64(*m) - 1;
        *m <<= n; *e -= n - 10;
        return K_FINITE;
    }
    static u64 d_pack(u32 s, int e, u64 m) {
        u64 sign = (u64)s << 63;
        if (!m) return sign;
        int be = e + 1023;
        if (be <= 0) { m = shift_sticky(m, 1 - be); be = 0; }
        u32 rb = (u32)(m & 0x3FF);
        m >>= 10;
        if (rb > 0x200 || (rb == 0x200 && (m & 1))) m++;
        if (be == 0) return sign | m;
        if (m >> 53) { m >>= 1; be++; }
        if (be >= 0x7FF) return sign | D_INF;
        return sign | ((u64)be << 52) | (m & D_FRAC);
    }
    static u32 f_pack(u32 s, int e, u64 m) {
        u32 sign = s << 31;
        if (!m) return sign;
        int be = e + 127;
        if (be <= 0) { m = shift_sticky(m, 1 - be); be = 0; }
        u64 rb = m & ((1ull << 39) - 1), half = 1ull << 38;
        m >>= 39;
        if (rb > half || (rb == half && (m & 1))) m++;
        if (be == 0) return sign | (u32)m;
        if (m >> 24) { m >>= 1; be++; }
        if (be >= 0xFF) return sign | 0x7F800000u;
        return sign | ((u32)be << 23) | ((u32)m & 0x7FFFFFu);
    }
    /* Unsigned 64-bit integer -> normalized (e, m). */
    static int from_u64(u64 v, u64 *m) {
        if (v >> 63) { *m = (v >> 1) | (v & 1); return 63; }
        int n = clz64(v) - 1;
        *m = v << n;
        return 62 - n;
    }
    static u64 d_add(u64 a, u64 b) {
        u32 sa, sb; int ea, eb; u64 ma, mb;
        int ka = d_unpack(a, &sa, &ea, &ma), kb = d_unpack(b, &sb, &eb, &mb);
        if (ka == K_NAN || kb == K_NAN) return D_NAN;
        if (ka == K_INF) return (kb == K_INF && sa != sb) ? D_NAN : a;
        if (kb == K_INF) return b;
        if (ka == K_ZERO) return kb == K_ZERO ? ((u64)(sa & sb) << 63) : b;
        if (kb == K_ZERO) return a;
        if (ea < eb || (ea == eb && ma < mb)) {
            u32 ts = sa; sa = sb; sb = ts; int te = ea; ea = eb; eb = te; u64 tm = ma; ma = mb; mb = tm;
        }
        ma >>= 1;
        mb = shift_sticky(mb >> 1, ea - eb);
        u64 m = sa == sb ? ma + mb : ma - mb;
        if (!m) return 0;
        int n = clz64(m) - 1;
        return d_pack(sa, ea + 1 - n, m << n);
    }
    WEAK u64 __aeabi_dadd(u64 a, u64 b) { return d_add(a, b); }
    WEAK u64 __aeabi_dsub(u64 a, u64 b) { return d_add(a, b ^ (1ull << 63)); }
    WEAK u64 __aeabi_drsub(u64 a, u64 b) { return d_add(b, a ^ (1ull << 63)); }
    WEAK u64 __aeabi_dmul(u64 a, u64 b) {
        u32 sa, sb; int ea, eb; u64 ma, mb;
        int ka = d_unpack(a, &sa, &ea, &ma), kb = d_unpack(b, &sb, &eb, &mb);
        u32 s = sa ^ sb;
        if (ka == K_NAN || kb == K_NAN) return D_NAN;
        if (ka == K_INF || kb == K_INF) return (ka == K_ZERO || kb == K_ZERO) ? D_NAN : ((u64)s << 63) | D_INF;
        if (ka == K_ZERO || kb == K_ZERO) return (u64)s << 63;
        ma >>= 10; mb >>= 10;                     /* 53-bit significands */
        u32 al = (u32)ma, ah = (u32)(ma >> 32), bl = (u32)mb, bh = (u32)(mb >> 32);
        u64 lo = mul32x32(al, bl);
        u64 mid = mul32x32(ah, bl) + mul32x32(al, bh);
        u64 hi = mul32x32(ah, bh);
        u64 lo2 = lo + (mid << 32);
        hi += (mid >> 32) + (lo2 < lo);
        u64 m = (hi << 21) | (lo2 >> 43) | ((lo2 & ((1ull << 43) - 1)) != 0);
        int e = ea + eb + 1;
        if (!(m >> 62)) { m <<= 1; e--; }
        return d_pack(s, e, m);
    }
    WEAK u64 __aeabi_ddiv(u64 a, u64 b) {
        u32 sa, sb; int ea, eb; u64 ma, mb;
        int ka = d_unpack(a, &sa, &ea, &ma), kb = d_unpack(b, &sb, &eb, &mb);
        u32 s = sa ^ sb;
        if (ka == K_NAN || kb == K_NAN) return D_NAN;
        if (ka == K_INF) return kb == K_INF ? D_NAN : ((u64)s << 63) | D_INF;
        if (kb == K_INF) return (u64)s << 63;
        if (kb == K_ZERO) return ka == K_ZERO ? D_NAN : ((u64)s << 63) | D_INF;
        if (ka == K_ZERO) return (u64)s << 63;
        ma >>= 10; mb >>= 10;
        int e = ea - eb;
        if (ma < mb) { ma <<= 1; e--; }
        u64 q = 0, rem = ma;
        for (int i = 0; i < 63; i++) {
            q <<= 1;
            if (rem >= mb) { rem -= mb; q |= 1; }
            rem <<= 1;
        }
        return d_pack(s, e, q | (rem != 0));
    }
    WEAK u64 __aeabi_drdiv(u64 a, u64 b) { return __aeabi_ddiv(b, a); }
    /* -1 less, 0 equal, 1 greater, 2 unordered */
    static int d_cmp(u64 a, u64 b) {
        if (((a >> 52) & 0x7FF) == 0x7FF && (a & D_FRAC)) return 2;
        if (((b >> 52) & 0x7FF) == 0x7FF && (b & D_FRAC)) return 2;
        if (((a | b) << 1) == 0) return 0;
        u32 sa = (u32)(a >> 63), sb = (u32)(b >> 63);
        if (sa != sb) return sa ? -1 : 1;
        if (a == b) return 0;
        return ((a < b) ^ sa) ? -1 : 1;
    }
    WEAK int __aeabi_dcmpeq(u64 a, u64 b) { return d_cmp(a, b) == 0; }
    WEAK int __aeabi_dcmplt(u64 a, u64 b) { return d_cmp(a, b) == -1; }
    WEAK int __aeabi_dcmple(u64 a, u64 b) { int c = d_cmp(a, b); return c == -1 || c == 0; }
    WEAK int __aeabi_dcmpge(u64 a, u64 b) { int c = d_cmp(a, b); return c == 1 || c == 0; }
    WEAK int __aeabi_dcmpgt(u64 a, u64 b) { return d_cmp(a, b) == 1; }
    WEAK int __aeabi_dcmpun(u64 a, u64 b) { return d_cmp(a, b) == 2; }
    WEAK u64 __aeabi_ui2d(u32 v) { u64 m; if (!v) return 0; int e = from_u64(v, &m); return d_pack(0, e, m); }
    WEAK u64 __aeabi_i2d(i32 v) {
        u64 m; if (!v) return 0;
        int e = from_u64(v < 0 ? 0ull - (u64)(i64)v : (u64)v, &m);
        return d_pack(v < 0, e, m);
    }
    WEAK u64 __aeabi_ul2d(u64 v) { u64 m; if (!v) return 0; int e = from_u64(v, &m); return d_pack(0, e, m); }
    WEAK u64 __aeabi_l2d(i64 v) {
        u64 m; if (!v) return 0;
        int e = from_u64(v < 0 ? 0ull - (u64)v : (u64)v, &m);
        return d_pack(v < 0, e, m);
    }
    /* Truncating conversions, saturating like VCVT; NaN -> 0. */
    static u64 d_to_u64(u64 a, int bits, int *negative, int *overflow) {
        u32 s; int e; u64 m;
        int k = d_unpack(a, &s, &e, &m);
        *negative = (int)s; *overflow = 0;
        if (k == K_NAN) { *negative = 0; return 0; }
        if (k == K_INF) { *overflow = 1; return 0; }
        if (k == K_ZERO || e < 0) return 0;
        if (e >= bits) { *overflow = 1; return 0; }
        return e >= 62 ? m << (e - 62) : m >> (62 - e);
    }
    WEAK i32 __aeabi_d2iz(u64 a) {
        int neg, ovf; u64 v = d_to_u64(a, 32, &neg, &ovf);
        if (ovf || v > 0x7FFFFFFFull + (u64)neg) return neg ? (i32)0x80000000 : 0x7FFFFFFF;
        return neg ? (i32)(0u - (u32)v) : (i32)v;
    }
    WEAK u32 __aeabi_d2uiz(u64 a) {
        int neg, ovf; u64 v = d_to_u64(a, 32, &neg, &ovf);
        if (neg) return 0;
        return ovf ? 0xFFFFFFFFu : (u32)v;
    }
    WEAK i64 __aeabi_d2lz(u64 a) {
        int neg, ovf; u64 v = d_to_u64(a, 64, &neg, &ovf);
        if (ovf || v > 0x7FFFFFFFFFFFFFFFull + (u64)neg) return neg ? (i64)0x8000000000000000ull : 0x7FFFFFFFFFFFFFFFll;
        return neg ? (i64)(0ull - v) : (i64)v;
    }
    WEAK u64 __aeabi_d2ulz(u64 a) {
        int neg, ovf; u64 v = d_to_u64(a, 64, &neg, &ovf);
        if (neg) return 0;
        return ovf ? ~0ull : v;
    }
    WEAK u64 __aeabi_f2d(u32 f) {
        u32 s = f >> 31; int be = (int)((f >> 23) & 0xFF); u32 frac = f & 0x7FFFFFu;
        if (be == 0xFF) return frac ? D_NAN : ((u64)s << 63) | D_INF;
        if (be == 0 && !frac) return (u64)s << 63;
        u64 m; int e;
        if (be == 0) { e = -126; m = frac; } else { e = be - 127; m = frac | (1u << 23); }
        int n = clz64(m) - 1;
        return d_pack(s, e - (n - 39), m << n);
    }
    WEAK u32 __aeabi_d2f(u64 a) {
        u32 s; int e; u64 m;
        switch (d_unpack(a, &s, &e, &m)) {
        case K_NAN: return 0x7FC00000u;
        case K_INF: return (s << 31) | 0x7F800000u;
        case K_ZERO: return s << 31;
        default: return f_pack(s, e, m);
        }
    }
    WEAK u32 __aeabi_fadd(u32 a, u32 b) { return __aeabi_d2f(d_add(__aeabi_f2d(a), __aeabi_f2d(b))); }
    WEAK u32 __aeabi_fsub(u32 a, u32 b) { return __aeabi_fadd(a, b ^ 0x80000000u); }
    WEAK u32 __aeabi_frsub(u32 a, u32 b) { return __aeabi_fadd(b, a ^ 0x80000000u); }
    WEAK u32 __aeabi_fmul(u32 a, u32 b) { return __aeabi_d2f(__aeabi_dmul(__aeabi_f2d(a), __aeabi_f2d(b))); }
    WEAK u32 __aeabi_fdiv(u32 a, u32 b) { return __aeabi_d2f(__aeabi_ddiv(__aeabi_f2d(a), __aeabi_f2d(b))); }
    WEAK u32 __aeabi_frdiv(u32 a, u32 b) { return __aeabi_fdiv(b, a); }
    WEAK int __aeabi_fcmpeq(u32 a, u32 b) { return __aeabi_dcmpeq(__aeabi_f2d(a), __aeabi_f2d(b)); }
    WEAK int __aeabi_fcmplt(u32 a, u32 b) { return __aeabi_dcmplt(__aeabi_f2d(a), __aeabi_f2d(b)); }
    WEAK int __aeabi_fcmple(u32 a, u32 b) { return __aeabi_dcmple(__aeabi_f2d(a), __aeabi_f2d(b)); }
    WEAK int __aeabi_fcmpge(u32 a, u32 b) { return __aeabi_dcmpge(__aeabi_f2d(a), __aeabi_f2d(b)); }
    WEAK int __aeabi_fcmpgt(u32 a, u32 b) { return __aeabi_dcmpgt(__aeabi_f2d(a), __aeabi_f2d(b)); }
    WEAK int __aeabi_fcmpun(u32 a, u32 b) { return __aeabi_dcmpun(__aeabi_f2d(a), __aeabi_f2d(b)); }
    WEAK u32 __aeabi_ui2f(u32 v) { u64 m; if (!v) return 0; int e = from_u64(v, &m); return f_pack(0, e, m); }
    WEAK u32 __aeabi_i2f(i32 v) {
        u64 m; if (!v) return 0;
        int e = from_u64(v < 0 ? 0ull - (u64)(i64)v : (u64)v, &m);
        return f_pack(v < 0, e, m);
    }
    WEAK u32 __aeabi_ul2f(u64 v) { u64 m; if (!v) return 0; int e = from_u64(v, &m); return f_pack(0, e, m); }
    WEAK u32 __aeabi_l2f(i64 v) {
        u64 m; if (!v) return 0;
        int e = from_u64(v < 0 ? 0ull - (u64)v : (u64)v, &m);
        return f_pack(v < 0, e, m);
    }
    WEAK i32 __aeabi_f2iz(u32 f) { return __aeabi_d2iz(__aeabi_f2d(f)); }
    WEAK u32 __aeabi_f2uiz(u32 f) { return __aeabi_d2uiz(__aeabi_f2d(f)); }
    WEAK i64 __aeabi_f2lz(u32 f) { return __aeabi_d2lz(__aeabi_f2d(f)); }
    WEAK u64 __aeabi_f2ulz(u32 f) { return __aeabi_d2ulz(__aeabi_f2d(f)); }

    /* ---- Keil start-up support: __main (called by Keil startup_*.s after SystemInit) ----
       Like the Arm C library: copy RW data, zero ZI data, then call main(). Written without any
       stack use because the stack itself lives in the ZI area being cleared. */
    WEAK int __use_two_region_memory;
    WEAK int __use_no_semihosting;
    extern int main(void) __attribute__((weak));
    WEAK void exit(int code) { (void)code; for (;;) { __asm volatile("wfi"); } }
    WEAK void abort(void) { exit(1); }
    __attribute__((noreturn)) void __armsim_rt_entry(void) { exit(main ? main() : 0); for (;;) {} }
    __attribute__((naked, weak)) void __main(void) {
        __asm volatile(
            "ldr r0, =_sidata\n"
            "ldr r1, =_sdata\n"
            "ldr r2, =_edata\n"
            "cmp r0, r1\n"
            "beq 2f\n"
            "1: cmp r1, r2\n"
            "bhs 2f\n"
            "ldrb r3, [r0]\n"
            "strb r3, [r1]\n"
            "adds r0, #1\n"
            "adds r1, #1\n"
            "b 1b\n"
            "2: ldr r1, =_sbss\n"
            "ldr r2, =_ebss\n"
            "movs r3, #0\n"
            "3: cmp r1, r2\n"
            "bhs 4f\n"
            "strb r3, [r1]\n"
            "adds r1, #1\n"
            "b 3b\n"
            "4: ldr r0, =__armsim_rt_entry\n"
            "bx r0\n"
            ".ltorg\n");
    }
    __attribute__((naked, weak)) void __scatterload(void) { __asm volatile("b __main\n"); }

    /* ---- string.h ---- */
    WEAK char *strcpy(char *d, const char *s) { char *r = d; while ((*d++ = *s++)) {} return r; }
    WEAK char *strncpy(char *d, const char *s, u32 n) {
        char *r = d;
        for (; n && *s; n--) *d++ = *s++;
        for (; n; n--) *d++ = 0;
        return r;
    }
    WEAK char *strcat(char *d, const char *s) { strcpy(d + strlen(d), s); return d; }
    WEAK char *strncat(char *d, const char *s, u32 n) {
        char *p = d + strlen(d);
        while (n-- && *s) *p++ = *s++;
        *p = 0;
        return d;
    }
    WEAK int strcmp(const char *a, const char *b) {
        while (*a && *a == *b) { a++; b++; }
        return (u8)*a - (u8)*b;
    }
    WEAK int strncmp(const char *a, const char *b, u32 n) {
        for (; n; n--, a++, b++) { if (*a != *b || !*a) return (u8)*a - (u8)*b; }
        return 0;
    }
    WEAK char *strchr(const char *s, int c) {
        for (;; s++) { if (*s == (char)c) return (char *)s; if (!*s) return 0; }
    }
    WEAK char *strrchr(const char *s, int c) {
        const char *r = 0;
        for (;; s++) { if (*s == (char)c) r = s; if (!*s) return (char *)r; }
    }
    WEAK char *strstr(const char *h, const char *n) {
        u32 k = strlen(n);
        if (!k) return (char *)h;
        for (; *h; h++) if (!strncmp(h, n, k)) return (char *)h;
        return 0;
    }
    WEAK void *memchr(const void *s, int c, u32 n) {
        const u8 *p = s;
        for (; n; n--, p++) if (*p == (u8)c) return (void *)p;
        return 0;
    }

    /* ---- ctype.h / stdlib.h ---- */
    WEAK int isdigit(int c) { return c >= '0' && c <= '9'; }
    WEAK int isspace(int c) { return c == ' ' || (c >= '\t' && c <= '\r'); }
    WEAK int isalpha(int c) { return (c | 32) >= 'a' && (c | 32) <= 'z'; }
    WEAK int isalnum(int c) { return isalpha(c) || isdigit(c); }
    WEAK int isxdigit(int c) { return isdigit(c) || ((c | 32) >= 'a' && (c | 32) <= 'f'); }
    WEAK int isupper(int c) { return c >= 'A' && c <= 'Z'; }
    WEAK int islower(int c) { return c >= 'a' && c <= 'z'; }
    WEAK int isprint(int c) { return c >= 32 && c < 127; }
    WEAK int toupper(int c) { return islower(c) ? c - 32 : c; }
    WEAK int tolower(int c) { return isupper(c) ? c + 32 : c; }
    WEAK int abs(int v) { return v < 0 ? -v : v; }
    WEAK long labs(long v) { return v < 0 ? -v : v; }
    WEAK long strtol(const char *s, char **end, int base) {
        while (isspace(*s)) s++;
        int neg = 0;
        if (*s == '-' || *s == '+') neg = *s++ == '-';
        if ((base == 0 || base == 16) && s[0] == '0' && (s[1] | 32) == 'x') { s += 2; base = 16; }
        else if (base == 0 && s[0] == '0') base = 8;
        else if (base == 0) base = 10;
        long v = 0;
        for (;; s++) {
            int d = isdigit(*s) ? *s - '0' : isalpha(*s) ? (*s | 32) - 'a' + 10 : 99;
            if (d >= base) break;
            v = v * base + d;
        }
        if (end) *end = (char *)s;
        return neg ? -v : v;
    }
    WEAK unsigned long strtoul(const char *s, char **end, int base) { return (unsigned long)strtol(s, end, base); }
    WEAK int atoi(const char *s) { return (int)strtol(s, 0, 10); }

    /* math.h subset. With the FPU (hard-float build) sqrtf is one VSQRT. */
    WEAK float fabsf(float x) { union { float f; u32 u; } v = { x }; v.u &= 0x7FFFFFFFu; return v.f; }
    WEAK double fabs(double x) { union { double d; u64 u; } v = { x }; v.u &= 0x7FFFFFFFFFFFFFFFull; return v.d; }
    WEAK double sqrt(double x) {
        if (!(x > 0.0)) return x == 0.0 ? x : (x - x) / (x - x); /* -0, NaN */
        union { double d; u64 u; } v = { x };
        if ((v.u >> 52) == 0x7FF) return x;                         /* inf */
        double r = x > 1.0 ? x : 1.0;
        for (int i = 0; i < 64; i++) {                              /* Newton, monotone from above */
            double next = 0.5 * (r + x / r);
            if (next >= r) break;
            r = next;
        }
        return r;
    }
    WEAK float sqrtf(float x) {
    #if defined(__ARM_FP) && (__ARM_FP & 4)
        float r;
        __asm__("vsqrt.f32 %0, %1" : "=t"(r) : "t"(x));
        return r;
    #else
        return (float)sqrt((double)x);
    #endif
    }
    WEAK long atol(const char *s) { return strtol(s, 0, 10); }
    static u32 rand_state = 1;
    WEAK void srand(unsigned int seed) { rand_state = seed; }
    WEAK int rand(void) { rand_state = rand_state * 1103515245u + 12345u; return (int)((rand_state >> 16) & 0x7FFF); }

    /* malloc: first-fit free list over the Keil HEAP area (__heap_base/__heap_limit with MicroLIB,
       Heap_Mem from the startup file otherwise) or the RAM after the ZI data. */
    extern char __heap_base[] __attribute__((weak));
    extern char __heap_limit[] __attribute__((weak));
    extern char _ebss[], _estack[];
    typedef struct block { u32 size; struct block *next; } block;
    static block *free_list;
    static char *heap_cursor, *heap_end;
    WEAK void *malloc(u32 n) {
        if (!heap_cursor) {
            heap_cursor = __heap_base ? __heap_base : _ebss;
            heap_end = __heap_limit ? __heap_limit : _estack - 0x400;
            heap_cursor = (char *)(((u32)heap_cursor + 7) & ~7u);
        }
        n = (n + 7) & ~7u;
        for (block **p = &free_list; *p; p = &(*p)->next) {
            if ((*p)->size >= n) { block *b = *p; *p = b->next; return b + 1; }
        }
        if (heap_cursor + sizeof(block) + n > heap_end) return 0;
        block *b = (block *)heap_cursor;
        b->size = n;
        heap_cursor += sizeof(block) + n;
        return b + 1;
    }
    WEAK void free(void *p) {
        if (!p) return;
        block *b = (block *)p - 1;
        b->next = free_list;
        free_list = b;
    }
    WEAK void *calloc(u32 count, u32 size) {
        void *p = malloc(count * size);
        if (p) memset(p, 0, count * size);
        return p;
    }
    WEAK void *realloc(void *p, u32 n) {
        if (!p) return malloc(n);
        block *b = (block *)p - 1;
        if (b->size >= n) return p;
        void *q = malloc(n);
        if (q) { memcpy(q, p, b->size); free(p); }
        return q;
    }

    /* ---- stdio.h: printf family. fputc writes to ITM port 0 (Debug (printf) Viewer) unless the
       program retargets it, as in Keil. ---- */
    typedef struct __FILE { int handle; } FILE;
    WEAK FILE __stdout = { 1 }, __stderr = { 2 }, __stdin = { 0 };
    WEAK FILE *stdout = &__stdout, *stderr = &__stderr, *stdin = &__stdin;
    WEAK int fputc(int c, FILE *f) {
        (void)f;
        volatile u32 *port0 = (volatile u32 *)0xE0000000u;
        u32 tcr = *(volatile u32 *)0xE0000E80u, ter = *(volatile u32 *)0xE0000E00u;
        if ((tcr & 1u) && (ter & 1u)) {
            while (*port0 == 0) {}
            *(volatile u8 *)port0 = (u8)c;
        }
        return c;
    }
    WEAK int fgetc(FILE *f) { (void)f; return -1; }
    WEAK int putchar(int c) { return fputc(c, stdout); }
    WEAK int fputs(const char *s, FILE *f) { while (*s) fputc(*s++, f); return 0; }
    WEAK int puts(const char *s) { fputs(s, stdout); fputc('\n', stdout); return 0; }
    WEAK int getchar(void) { return fgetc(stdin); }
    WEAK int fflush(FILE *f) { (void)f; return 0; }

    typedef __builtin_va_list va_list;
    typedef struct { char *buf; u32 size, len; FILE *file; } sink;
    static void emit(sink *s, char c) {
        if (s->file) fputc(c, s->file);
        else if (s->len + 1 < s->size) s->buf[s->len] = c;
        s->len++;
    }
    static int format(sink *s, const char *f, va_list ap) {
        for (; *f; f++) {
            if (*f != '%') { emit(s, *f); continue; }
            f++;
            int left = 0, zero = 0, plus = 0, space = 0, alt = 0, width = 0, prec = -1, lng = 0;
            for (;; f++) {
                if (*f == '-') left = 1; else if (*f == '0') zero = 1; else if (*f == '+') plus = 1;
                else if (*f == ' ') space = 1; else if (*f == '#') alt = 1; else break;
            }
            if (*f == '*') { width = __builtin_va_arg(ap, int); if (width < 0) { left = 1; width = -width; } f++; }
            else while (isdigit(*f)) width = width * 10 + (*f++ - '0');
            if (*f == '.') {
                f++; prec = 0;
                if (*f == '*') { prec = __builtin_va_arg(ap, int); f++; }
                else while (isdigit(*f)) prec = prec * 10 + (*f++ - '0');
            }
            while (*f == 'l' || *f == 'h' || *f == 'z' || *f == 't' || *f == 'j') { if (*f == 'l') lng++; f++; }
            char tmp[40], *body = tmp;
            int n = 0, neg = 0;
            const char *prefix = "";
            switch (*f) {
            case 'c': tmp[0] = (char)__builtin_va_arg(ap, int); n = 1; break;
            case 's': {
                body = __builtin_va_arg(ap, char *);
                if (!body) body = "(null)";
                while (body[n] && (prec < 0 || n < prec)) n++;
                break;
            }
            case 'd': case 'i': case 'u': case 'x': case 'X': case 'o': case 'p': {
                u64 v;
                int base = *f == 'o' ? 8 : (*f == 'x' || *f == 'X' || *f == 'p') ? 16 : 10;
                if (*f == 'p') { v = (u32)__builtin_va_arg(ap, void *); prefix = "0x"; }
                else if (*f == 'd' || *f == 'i') {
                    i64 sv = lng >= 2 ? __builtin_va_arg(ap, i64) : __builtin_va_arg(ap, i32);
                    if (sv < 0) { neg = 1; v = 0ull - (u64)sv; } else v = (u64)sv;
                } else v = lng >= 2 ? __builtin_va_arg(ap, u64) : __builtin_va_arg(ap, u32);
                const char *digits = *f == 'X' ? "0123456789ABCDEF" : "0123456789abcdef";
                char *e = tmp + sizeof tmp;
                body = e;
                do { u64 r; v = __armsim_udivmod64(v, base, &r); *--body = digits[r]; } while (v);
                n = (int)(e - body);
                while (prec > n && body > tmp) { *--body = '0'; n++; }
                if (alt && base == 16 && *f != 'p') prefix = *f == 'X' ? "0X" : "0x";
                if (neg) prefix = "-"; else if (plus && base == 10) prefix = "+"; else if (space && base == 10) prefix = " ";
                break;
            }
            case 'f': case 'F': case 'g': case 'G': case 'e': case 'E': {
                /* fixed notation for all of them, up to 9 decimals */
                u64 d = __builtin_va_arg(ap, u64);
                if (prec < 0) prec = 6;
                if (prec > 9) prec = 9;
                if (d >> 63) { neg = 1; d ^= 1ull << 63; }
                char *e = tmp + sizeof tmp;
                body = e;
                if (((d >> 52) & 0x7FF) == 0x7FF) {
                    body = (d & D_FRAC) ? "nan" : "inf"; n = 3;
                } else {
                    u64 scale = 1;
                    for (int i = 0; i < prec; i++) scale *= 10;
                    u64 scaled = __aeabi_d2ulz(d_add(__aeabi_dmul(d, __aeabi_ul2d(scale)), 0x3FE0000000000000ull));
                    u64 ip = scaled / scale, fp = scaled % scale;
                    for (int i = 0; i < prec; i++) { *--body = (char)('0' + fp % 10); fp /= 10; }
                    if (prec || alt) *--body = '.';
                    do { *--body = (char)('0' + ip % 10); ip /= 10; } while (ip && body > tmp);
                    n = (int)(e - body);
                }
                if (neg) prefix = "-"; else if (plus) prefix = "+"; else if (space) prefix = " ";
                break;
            }
            case '%': tmp[0] = '%'; n = 1; break;
            case 0: f--; continue;
            default: tmp[0] = '%'; tmp[1] = *f; n = 2; break;
            }
            int plen = (int)strlen(prefix), pad = width - n - plen;
            if (!left && !zero) for (; pad > 0; pad--) emit(s, ' ');
            for (int i = 0; i < plen; i++) emit(s, prefix[i]);
            if (!left && zero) for (; pad > 0; pad--) emit(s, '0');
            for (int i = 0; i < n; i++) emit(s, body[i]);
            for (; pad > 0; pad--) emit(s, ' ');
        }
        return (int)s->len;
    }
    WEAK int vsnprintf(char *b, u32 n, const char *f, va_list ap) {
        sink s = { b, n, 0, 0 };
        int r = format(&s, f, ap);
        if (n) b[s.len < n ? s.len : n - 1] = 0;
        return r;
    }
    WEAK int vsprintf(char *b, const char *f, va_list ap) { return vsnprintf(b, 0x7FFFFFFF, f, ap); }
    WEAK int vfprintf(FILE *file, const char *f, va_list ap) { sink s = { 0, 0, 0, file }; return format(&s, f, ap); }
    WEAK int vprintf(const char *f, va_list ap) { return vfprintf(stdout, f, ap); }
    WEAK int snprintf(char *b, u32 n, const char *f, ...) {
        va_list ap; __builtin_va_start(ap, f); int r = vsnprintf(b, n, f, ap); __builtin_va_end(ap); return r;
    }
    WEAK int sprintf(char *b, const char *f, ...) {
        va_list ap; __builtin_va_start(ap, f); int r = vsprintf(b, f, ap); __builtin_va_end(ap); return r;
    }
    WEAK int fprintf(FILE *file, const char *f, ...) {
        va_list ap; __builtin_va_start(ap, f); int r = vfprintf(file, f, ap); __builtin_va_end(ap); return r;
    }
    WEAK int printf(const char *f, ...) {
        va_list ap; __builtin_va_start(ap, f); int r = vprintf(f, ap); __builtin_va_end(ap); return r;
    }
    """#

    /// Minimal C library headers (the compiler's own stdint.h/stddef.h/stdarg.h/stdbool.h/limits.h are used
    /// as they are). Prototypes match the functions above.
    static let headers: [String: String] = [
        "stdio.h": """
        #ifndef __ARMSIM_STDIO_H
        #define __ARMSIM_STDIO_H
        #include <stddef.h>
        #include <stdarg.h>
        #ifdef __cplusplus
        extern "C" {
        #endif
        typedef struct __FILE FILE;
        extern FILE *stdout, *stderr, *stdin;
        #define EOF (-1)
        int printf(const char *, ...);
        int fprintf(FILE *, const char *, ...);
        int sprintf(char *, const char *, ...);
        int snprintf(char *, size_t, const char *, ...);
        int vprintf(const char *, va_list);
        int vfprintf(FILE *, const char *, va_list);
        int vsprintf(char *, const char *, va_list);
        int vsnprintf(char *, size_t, const char *, va_list);
        int fputc(int, FILE *);
        int fgetc(FILE *);
        int putchar(int);
        int getchar(void);
        int fputs(const char *, FILE *);
        int puts(const char *);
        int fflush(FILE *);
        #define putc(c, f) fputc(c, f)
        #define getc(f) fgetc(f)
        #ifdef __cplusplus
        }
        #endif
        #endif

        """,
        "string.h": """
        #ifndef __ARMSIM_STRING_H
        #define __ARMSIM_STRING_H
        #include <stddef.h>
        #ifdef __cplusplus
        extern "C" {
        #endif
        void *memcpy(void *, const void *, size_t);
        void *memmove(void *, const void *, size_t);
        void *memset(void *, int, size_t);
        int memcmp(const void *, const void *, size_t);
        void *memchr(const void *, int, size_t);
        size_t strlen(const char *);
        char *strcpy(char *, const char *);
        char *strncpy(char *, const char *, size_t);
        char *strcat(char *, const char *);
        char *strncat(char *, const char *, size_t);
        int strcmp(const char *, const char *);
        int strncmp(const char *, const char *, size_t);
        char *strchr(const char *, int);
        char *strrchr(const char *, int);
        char *strstr(const char *, const char *);
        #ifdef __cplusplus
        }
        #endif
        #endif

        """,
        "stdlib.h": """
        #ifndef __ARMSIM_STDLIB_H
        #define __ARMSIM_STDLIB_H
        #include <stddef.h>
        #ifdef __cplusplus
        extern "C" {
        #endif
        #define EXIT_SUCCESS 0
        #define EXIT_FAILURE 1
        #define RAND_MAX 0x7FFF
        void *malloc(size_t);
        void *calloc(size_t, size_t);
        void *realloc(void *, size_t);
        void free(void *);
        int abs(int);
        long labs(long);
        int atoi(const char *);
        long atol(const char *);
        long strtol(const char *, char **, int);
        unsigned long strtoul(const char *, char **, int);
        int rand(void);
        void srand(unsigned int);
        void exit(int) __attribute__((noreturn));
        void abort(void) __attribute__((noreturn));
        #ifdef __cplusplus
        }
        #endif
        #endif

        """,
        "ctype.h": """
        #ifndef __ARMSIM_CTYPE_H
        #define __ARMSIM_CTYPE_H
        int isdigit(int); int isspace(int); int isalpha(int); int isalnum(int); int isxdigit(int);
        int isupper(int); int islower(int); int isprint(int); int toupper(int); int tolower(int);
        #endif

        """,
        "math.h": """
        #ifndef __ARMSIM_MATH_H
        #define __ARMSIM_MATH_H
        float sqrtf(float);
        double sqrt(double);
        float fabsf(float);
        double fabs(double);
        #define HUGE_VALF __builtin_huge_valf()
        #define HUGE_VAL __builtin_huge_val()
        #define INFINITY __builtin_inff()
        #define NAN __builtin_nanf("")
        #define M_PI 3.14159265358979323846
        #define isnan(x) __builtin_isnan(x)
        #define isinf(x) __builtin_isinf(x)
        #endif

        """,
        "assert.h": """
        #ifndef __ARMSIM_ASSERT_H
        #define __ARMSIM_ASSERT_H
        #include <stdlib.h>
        #ifdef NDEBUG
        #define assert(e) ((void)0)
        #else
        #define assert(e) ((e) ? (void)0 : abort())
        #endif
        #endif

        """,
    ]
}
