import ARMCore
import Foundation

// Self test runner.
//  1. Assembly tests: hand-checked expected register/flag values.
//  2. Differential C tests: each program is compiled for Cortex-M (run in the simulator)
//     and for the host Mac (run natively); the two results must match.
// Only Apple clang is needed (it can assemble/compile for thumbv6m/v7m/v7em).

// MARK: - Shell helpers

let workDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("armsim-selftest-\(ProcessInfo.processInfo.processIdentifier)")
try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: workDir) }

struct ToolError: Error, CustomStringConvertible { let description: String }

@discardableResult
func run(_ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw ToolError(description: "\(arguments.first ?? "") failed:\n\(output)")
    }
    return output
}

struct Profile {
    let name: String
    let arch: Architecture
    let clangFlags: [String]
}

let profiles = [
    Profile(name: "M3", arch: .armv7m, clangFlags: ["--target=thumbv7m-none-eabi", "-mcpu=cortex-m3"]),
    Profile(name: "M0", arch: .armv6m, clangFlags: ["--target=thumbv6m-none-eabi", "-mcpu=cortex-m0"]),
    Profile(name: "M4", arch: .armv7em, clangFlags: ["--target=thumbv7em-none-eabi", "-mcpu=cortex-m4", "-mfloat-abi=soft"]),
]

func compile(_ source: String, ext: String, profile: Profile, extraFlags: [String] = []) throws -> [UInt8] {
    let name = UUID().uuidString
    let src = workDir.appendingPathComponent("\(name).\(ext)")
    let obj = workDir.appendingPathComponent("\(name).o")
    try source.write(to: src, atomically: true, encoding: .utf8)
    try run(["clang"] + profile.clangFlags + [
        "-mthumb", "-ffreestanding", "-fno-builtin", "-fno-common", "-fno-unwind-tables",
        "-fno-asynchronous-unwind-tables", "-fno-exceptions", "-w", "-c", src.path, "-o", obj.path,
    ] + extraFlags)
    return [UInt8](try Data(contentsOf: obj))
}

// MARK: - Assembly tests

struct AsmTest {
    let name: String
    let body: String
    /// Keys: r0...r12, lr, N Z C V Q, spDelta (SP after minus SP before).
    let expect: [String: UInt32]
    var thumb1Only = false
}

let asmTests: [AsmTest] = [
    AsmTest(name: "subs borrow / negative", body: """
        movs r0, #0
        subs r0, r0, #1
        """, expect: ["r0": 0xFFFF_FFFF, "N": 1, "Z": 0, "C": 0, "V": 0], thumb1Only: true),

    AsmTest(name: "adds signed overflow", body: """
        ldr r0, =0x7FFFFFFF
        adds r0, r0, #1
        """, expect: ["r0": 0x8000_0000, "N": 1, "Z": 0, "C": 0, "V": 1], thumb1Only: true),

    AsmTest(name: "adds carry out / zero", body: """
        ldr r1, =0xFFFFFFFF
        adds r1, #1
        """, expect: ["r1": 0, "N": 0, "Z": 1, "C": 1, "V": 0], thumb1Only: true),

    AsmTest(name: "immediate shifts and carry", body: """
        movs r0, #1
        lsls r1, r0, #31
        lsrs r2, r1, #31
        asrs r3, r1, #4
        movs r4, #3
        lsrs r5, r4, #1
        """, expect: ["r1": 0x8000_0000, "r2": 1, "r3": 0xF800_0000, "r5": 1, "C": 1], thumb1Only: true),

    AsmTest(name: "register shifts by >= 32", body: """
        ldr r0, =0x80000001
        movs r1, #32
        movs r2, r0
        lsls r2, r1
        movs r3, r0
        lsrs r3, r1
        movs r4, r0
        asrs r4, r1
        movs r5, #33
        movs r6, r0
        rors r6, r5
        """, expect: ["r2": 0, "r3": 0, "r4": 0xFFFF_FFFF, "r6": 0xC000_0000, "C": 1], thumb1Only: true),

    AsmTest(name: "loop sum 1..10", body: """
        movs r0, #0
        movs r1, #10
        1:  adds r0, r0, r1
        subs r1, #1
        bne 1b
        """, expect: ["r0": 55, "r1": 0, "Z": 1], thumb1Only: true),

    AsmTest(name: "loads, stores, push/pop", body: """
        ldr r0, =0x20010000
        ldr r1, =0xDEADBEEF
        str r1, [r0]
        ldrb r2, [r0, #1]
        ldrh r3, [r0, #2]
        movs r5, #3
        ldrsb r4, [r0, r5]
        push {r1, r2}
        pop {r6, r7}
        """, expect: ["r2": 0xBE, "r3": 0xDEAD, "r4": 0xFFFF_FFDE, "r6": 0xDEAD_BEEF, "r7": 0xBE, "spDelta": 0],
        thumb1Only: true),

    AsmTest(name: "bl / bx lr", body: """
        movs r0, #5
        bl 2f
        b 3f
        2:  adds r0, r0, #2
        bx lr
        3:  nop
        """, expect: ["r0": 7], thumb1Only: true),

    AsmTest(name: "stm/ldm, adc/sbc, mul, mvn", body: """
        ldr r0, =0x20010100
        movs r1, #1
        movs r2, #2
        movs r3, #3
        stmia r0!, {r1-r3}
        subs r0, #12
        ldmia r0!, {r4-r6}
        ldr r1, =0xFFFFFFFF
        movs r2, #1
        movs r3, #0
        adds r1, r1, r2
        adcs r3, r3, r3
        movs r7, #7
        muls r7, r6, r7
        mvns r2, r2
        """, expect: ["r0": 0x2001_010C, "r4": 1, "r5": 2, "r6": 3, "r1": 0, "r3": 1, "r7": 21, "r2": 0xFFFF_FFFE],
        thumb1Only: true),

    AsmTest(name: "IT blocks (no flag update inside)", body: """
        movs r0, #5
        cmp r0, #5
        ite eq
        moveq r1, #1
        movne r1, #2
        it ne
        movne r2, #7
        movs r4, #0
        cmp r4, #0
        it eq
        addeq r4, r4, #1
        """, expect: ["r1": 1, "r2": 0, "r4": 1, "Z": 1]),

    AsmTest(name: "MOVW/MOVT, bitfields, CLZ, RBIT, REV", body: """
        movw r0, #0x5678
        movt r0, #0x1234
        ubfx r1, r0, #4, #8
        sbfx r2, r0, #0, #4
        mov r3, #0
        bfi r3, r0, #8, #8
        clz r4, r3
        rbit r5, r0
        rev r6, r0
        add.w r7, r0, #0xFF00
        """, expect: ["r0": 0x1234_5678, "r1": 0x67, "r2": 0xFFFF_FFF8, "r3": 0x7800, "r4": 17,
                      "r5": 0x1E6A_2C48, "r6": 0x7856_3412, "r7": 0x1235_5578]),

    AsmTest(name: "long multiply / divide / MLS", body: """
        ldr r0, =100000
        ldr r1, =300000
        umull r2, r3, r0, r1
        ldr r4, =0xFFFFFFF9
        movs r5, #2
        sdiv r6, r4, r5
        udiv r7, r1, r0
        mls r8, r6, r5, r4
        smull r9, r10, r4, r1
        movs r11, #0
        udiv r12, r1, r11
        """, expect: ["r2": 0xFC23_AC00, "r3": 6, "r6": 0xFFFF_FFFD, "r7": 3, "r8": 0xFFFF_FFFF,
                      "r9": 0xFFDF_F4E0, "r10": 0xFFFF_FFFF, "r12": 0]),

    AsmTest(name: "TBB jump table", body: """
        movs r0, #2
        tbb [pc, r0]
        4:  .byte (10f - 4b) / 2, (11f - 4b) / 2, (12f - 4b) / 2
        .align 1
        10: movs r1, #10
        b 13f
        11: movs r1, #11
        b 13f
        12: movs r1, #12
        13: nop
        """, expect: ["r1": 12]),

    AsmTest(name: "CBZ/CBNZ, STMIA.W, LDRD", body: """
        ldr r0, =0x20010200
        movs r1, #1
        movs r2, #2
        movs r3, #3
        stmia r0!, {r1-r3}
        subs r0, #12
        ldrd r4, r5, [r0, #4]
        movs r6, #0
        cbz r6, 1f
        movs r6, #99
        1:  cbnz r1, 2f
        movs r6, #98
        2:  nop
        """, expect: ["r0": 0x2001_0200, "r4": 2, "r5": 3, "r6": 0]),

    AsmTest(name: "LDREX/STREX", body: """
        ldr r0, =0x20010300
        movs r1, #42
        ldrex r2, [r0]
        strex r3, r1, [r0]
        ldr r4, [r0]
        strex r5, r1, [r0]
        """, expect: ["r3": 0, "r4": 42, "r5": 1]),

    AsmTest(name: "MRS/MSR, CPSID/CPSIE", body: """
        cpsid i
        mrs r0, primask
        cpsie i
        mrs r1, primask
        movs r2, #0
        subs r2, #1
        mrs r3, apsr
        """, expect: ["r0": 1, "r1": 0, "r3": 0x8000_0000]),

    AsmTest(name: "SSAT/USAT set Q", body: """
        ldr r0, =1000
        ssat r1, #8, r0
        usat r2, #4, r0
        """, expect: ["r1": 127, "r2": 15, "Q": 1]),

    AsmTest(name: "pre/post-indexed LDR/STR.W, PUSH.W/POP.W", body: """
        ldr r0, =0x20010400
        ldr r1, =0x11111111
        ldr r2, =0x22222222
        str r1, [r0], #4
        str r2, [r0, #4]!
        ldr r3, [r0, #-8]!
        push.w {r1, r2, r8}
        pop.w {r4, r5, r9}
        """, expect: ["r0": 0x2001_0400, "r3": 0x1111_1111, "r4": 0x1111_1111, "r5": 0x2222_2222, "spDelta": 0]),

    AsmTest(name: "flag-setting Thumb-2 ops, TEQ, conditional B.W", body: """
        ldr r0, =0xF0000000
        lsls.w r1, r0, #1
        mov.w r2, #0
        it cs
        movcs r2, #1
        teq r0, r0
        bne.w 1f
        mov.w r3, #3
        1:  orn r4, r2, #0xFF
        rsb r5, r2, #10
        """, expect: ["r1": 0xE000_0000, "r2": 1, "r3": 3, "r4": 0xFFFF_FF01, "r5": 9, "Z": 1]),

    // ---- Exception model (vector table placed in RAM, VTOR pointed at it) ----

    AsmTest(name: "SVC enters handler and returns (EXC_RETURN 0xFFFFFFF9)", body: """
        ldr r0, =0xE000ED08
        ldr r1, =vectors
        str r1, [r0]
        movs r4, #0
        svc #5
        movs r5, #1
        mrs r7, ipsr
        bkpt #0
        .global svc_handler
        .thumb_func
    svc_handler:
        movs r4, #42
        mov r6, lr
        mrs r9, ipsr
        bx lr
        .balign 128
    vectors:
        .word 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        .word svc_handler
        .word 0, 0, 0, 0
    """, expect: ["r4": 42, "r5": 1, "r6": 0xFFFF_FFF9, "r9": 11, "r7": 0, "spDelta": 0], thumb1Only: true),

    AsmTest(name: "SysTick interrupt wakes WFI", body: """
        ldr r0, =0xE000ED08
        ldr r1, =vectors
        str r1, [r0]
        movs r7, #0
        ldr r0, =0xE000E010
        movs r1, #99
        str r1, [r0, #4]
        movs r1, #0
        str r1, [r0, #8]
        movs r1, #7
        str r1, [r0]
        wfi
        movs r6, r7
    1:  cmp r7, #3
        blt 1b
        movs r1, #0
        str r1, [r0]
        bkpt #0
        .global systick_handler
        .thumb_func
    systick_handler:
        adds r7, #1
        bx lr
        .balign 128
    vectors:
        .word 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        .word systick_handler
    """, expect: ["r7": 3, "r6": 1, "spDelta": 0], thumb1Only: true),

    AsmTest(name: "NVIC IRQ pending, masked by PRIMASK", body: """
        ldr r0, =0xE000ED08
        ldr r1, =vectors
        str r1, [r0]
        movs r4, #0
        cpsid i
        ldr r0, =0xE000E100
        movs r1, #1
        str r1, [r0]
        ldr r0, =0xE000E200
        str r1, [r0]
        nop
        nop
        movs r5, r4
        cpsie i
        nop
        bkpt #0
        .global irq0_handler
        .thumb_func
    irq0_handler:
        movs r4, #0x55
        bx lr
        .balign 128
    vectors:
        .word 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        .word irq0_handler
    """, expect: ["r4": 0x55, "r5": 0, "spDelta": 0], thumb1Only: true),

    AsmTest(name: "undefined instruction -> HardFault (FORCED), handler skips it", body: """
        ldr r0, =0xE000ED08
        ldr r1, =vectors
        str r1, [r0]
        movs r5, #0
        udf #0
        movs r5, #1
        bkpt #0
        .global hardfault_handler
        .thumb_func
    hardfault_handler:
        ldr r0, =0xE000ED28
        ldr r4, [r0]
        ldr r6, [r0, #4]
        ldr r1, [sp, #24]
        adds r1, #2
        str r1, [sp, #24]
        bx lr
        .ltorg
        .balign 128
    vectors:
        .word 0, 0, 0
        .word hardfault_handler
        .word 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    """, expect: ["r4": 0x0001_0000, "r6": 0x4000_0000, "r5": 1, "spDelta": 0]),

    AsmTest(name: "thread mode on PSP (EXC_RETURN 0xFFFFFFFD)", body: """
        ldr r0, =0xE000ED08
        ldr r1, =vectors
        str r1, [r0]
        ldr r0, =0x20020000
        msr psp, r0
        movs r0, #2
        msr control, r0
        isb
        svc #0
        mrs r5, control
        mrs r7, psp
        bkpt #0
        .global svc_handler
        .thumb_func
    svc_handler:
        mov r6, lr
        bx lr
        .balign 128
    vectors:
        .word 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        .word svc_handler
        .word 0, 0, 0, 0
    """, expect: ["r6": 0xFFFF_FFFD, "r5": 2, "r7": 0x2002_0000]),
]

func flagValue(_ cpu: CPU, _ key: String) -> UInt32? {
    switch key {
    case "N": return cpu.n ? 1 : 0
    case "Z": return cpu.z ? 1 : 0
    case "C": return cpu.c ? 1 : 0
    case "V": return cpu.v ? 1 : 0
    case "Q": return cpu.q ? 1 : 0
    case "lr": return cpu.r[14]
    case "ipsr": return cpu.ipsr
    default:
        if key.hasPrefix("r"), let i = Int(key.dropFirst()), i < 13 { return cpu.r[i] }
        return nil
    }
}

func runAsmTest(_ test: AsmTest, profile: Profile) throws -> String? {
    let source = """
        .syntax unified
        .thumb
        .text
        .global _start
        .thumb_func
    _start:
    \(test.body)
        bkpt #0
        .ltorg
    """
    let object = try compile(source, ext: "s", profile: profile)
    let sim = Simulator(arch: profile.arch)
    let image = try sim.loadELF(object)
    guard let start = image.symbol(named: "_start") else { return "no _start symbol" }
    try sim.prepareCall(address: start.address)
    let initialSP = sim.cpu.sp
    let reason = sim.cpu.run(maxInstructions: 100_000)
    guard case .bkpt(0, _) = reason else { return "stopped with \(reason)" }
    var problems: [String] = []
    for (key, expected) in test.expect.sorted(by: { $0.key < $1.key }) {
        let actual = key == "spDelta" ? sim.cpu.sp &- initialSP : flagValue(sim.cpu, key)
        guard let actual else { problems.append("unknown key \(key)"); continue }
        if actual != expected {
            problems.append(String(format: "%@ = 0x%08X, expected 0x%08X", key, actual, expected))
        }
    }
    return problems.isEmpty ? nil : problems.joined(separator: "; ")
}

// MARK: - Differential C tests

let cPrelude = """
typedef unsigned char u8; typedef signed char i8;
typedef unsigned short u16; typedef signed short i16;
typedef unsigned int u32; typedef signed int i32;
typedef unsigned long long u64; typedef signed long long i64;
#ifdef __arm__
void *memcpy(void *d, const void *s, unsigned n) { volatile u8 *dd = d; const u8 *ss = s; while (n--) *dd++ = *ss++; return d; }
void *memset(void *d, int c, unsigned n) { volatile u8 *dd = d; while (n--) *dd++ = (u8)c; return d; }
#endif

"""

struct CTest {
    let name: String
    let source: String
    /// Needs hardware divide or 64-bit multiply helpers (no runtime library on Cortex-M0).
    var needsThumb2 = false
}

let cTests: [CTest] = [
    CTest(name: "crc32", source: """
        static u8 buf[256];
        static u32 crc32(const u8 *p, u32 n) {
            u32 c = 0xFFFFFFFFu;
            for (u32 i = 0; i < n; i++) {
                c ^= p[i];
                for (int k = 0; k < 8; k++) c = (c >> 1) ^ (0xEDB88320u & (0u - (c & 1u)));
            }
            return ~c;
        }
        u32 test(void) {
            for (u32 i = 0; i < 256; i++) buf[i] = (u8)(i * 7u + 3u);
            return crc32(buf, 256);
        }
        """),

    CTest(name: "sieve", source: """
        static u8 composite[3000];
        u32 test(void) {
            u32 count = 0, sum = 0;
            for (u32 i = 2; i < 3000; i++) {
                if (!composite[i]) {
                    count++; sum += i;
                    for (u32 j = i * i; j < 3000; j += i) composite[j] = 1;
                }
            }
            return count * 100000u + (sum & 0xFFFFu);
        }
        """),

    CTest(name: "insertion sort", source: """
        static u32 a[200];
        u32 test(void) {
            u32 s = 12345;
            for (int i = 0; i < 200; i++) { s = s * 1103515245u + 12345u; a[i] = s >> 8; }
            for (int i = 1; i < 200; i++) {
                u32 k = a[i]; int j = i - 1;
                while (j >= 0 && a[j] > k) { a[j + 1] = a[j]; j--; }
                a[j + 1] = k;
            }
            u32 h = 0;
            for (int i = 0; i < 200; i++) h = h * 31u + a[i];
            return h;
        }
        """),

    CTest(name: "64-bit arithmetic", source: """
        u32 test(void) {
            u64 a = 1, b = 1;
            for (int i = 0; i < 80; i++) { u64 t = a + b; a = b; b = t; }
            u64 m = b * 0x9E3779B97F4A7C15ull;
            i64 neg = -(i64)(m >> 3);
            return (u32)(m ^ (m >> 32)) ^ (u32)(neg >> 40);
        }
        """, needsThumb2: true),

    CTest(name: "signed/unsigned division", source: """
        u32 test(void) {
            u32 h = 0;
            for (i32 a = -1000; a <= 1000; a += 37)
                for (i32 b = -50; b <= 50; b += 7)
                    h = h * 33u + (u32)(a / b) + (u32)(a % b) * 7u;
            for (u32 a = 1; a < 100000u; a = a * 3u + 1u) h ^= a / 13u + a % 17u;
            return h;
        }
        """, needsThumb2: true),

    CTest(name: "switch / jump table", source: """
        static u32 f(u32 x, u32 acc) {
            switch (x) {
            case 0: return acc + 11;
            case 1: return acc * 3;
            case 2: return acc ^ 0x55;
            case 3: return acc - 99;
            case 4: return acc << 2;
            case 5: return acc >> 1;
            case 6: return acc | 0x100;
            case 7: return acc & 0xFFF0;
            case 8: return ~acc;
            case 9: return acc + x * 5;
            default: return acc + x;
            }
        }
        u32 test(void) {
            u32 acc = 7;
            for (u32 i = 0; i < 500; i++) acc = f((acc + i) % 13, acc);
            return acc;
        }
        """, needsThumb2: true),

    CTest(name: "recursion and bitfields", source: """
        struct S { u32 a : 3, b : 7, c : 12, d : 10; };
        static struct S items[16];
        static u32 ack(u32 m, u32 n) {
            if (m == 0) return n + 1;
            if (n == 0) return ack(m - 1, 1);
            return ack(m - 1, ack(m, n - 1));
        }
        static u32 hanoi(u32 n, u32 from, u32 to, u32 via) {
            if (n == 0) return 0;
            return hanoi(n - 1, from, via, to) + 1 + hanoi(n - 1, via, to, from);
        }
        u32 test(void) {
            u32 h = ack(2, 3) * 100000u + hanoi(10, 1, 3, 2);
            for (u32 i = 0; i < 16; i++) {
                items[i].a = i; items[i].b = i * 9; items[i].c = i * 301; items[i].d = i * 77;
            }
            for (u32 i = 0; i < 16; i++) h = h * 17u + items[i].a + items[i].b + items[i].c + items[i].d;
            return h;
        }
        """),

    CTest(name: "bytes, halfwords, signed types", source: """
        static i8 sb[64]; static i16 sh[64]; static char text[32];
        u32 test(void) {
            u32 h = 0;
            for (int i = 0; i < 64; i++) { sb[i] = (i8)(i * 13 - 300); sh[i] = (i16)(i * 1234 - 40000); }
            for (int i = 0; i < 64; i++) h = h * 7u + (u32)(i32)sb[i] + (u32)(i32)sh[i];
            const char *src = "Hello, Cortex-M simulator!";
            int n = 0;
            while (src[n]) { text[n] = src[n]; n++; }
            for (int i = 0; i < n / 2; i++) { char t = text[i]; text[i] = text[n - 1 - i]; text[n - 1 - i] = t; }
            for (int i = 0; i < n; i++) h = (h << 5) - h + (u8)text[i];
            return h;
        }
        """),
]

var hostCache: [String: UInt32] = [:]

func hostResult(_ test: CTest) throws -> UInt32 {
    if let cached = hostCache[test.name] { return cached }
    let src = workDir.appendingPathComponent("host-\(UUID().uuidString).c")
    let exe = workDir.appendingPathComponent("host-\(UUID().uuidString)")
    try (cPrelude + test.source + "\n#include <stdio.h>\nint main(void) { printf(\"%u\", test()); return 0; }\n")
        .write(to: src, atomically: true, encoding: .utf8)
    try run(["clang", "-O1", "-w", src.path, "-o", exe.path])
    let output = try run([exe.path])
    guard let value = UInt32(output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        throw ToolError(description: "bad host output \(output)")
    }
    hostCache[test.name] = value
    return value
}

func runCTest(_ test: CTest, profile: Profile, optimization: String) throws -> String? {
    let expected = try hostResult(test)
    let object = try compile(cPrelude + test.source, ext: "c", profile: profile, extraFlags: [optimization])
    let sim = Simulator(arch: profile.arch)
    let image = try sim.loadELF(object)
    guard let function = image.symbol(named: "test") else { return "no test() symbol" }
    try sim.prepareCall(address: function.address)
    let reason = sim.cpu.run(maxInstructions: 200_000_000)
    guard sim.isReturnFromCall(reason) else { return "stopped with \(reason)" }
    let actual = sim.cpu.r[0]
    return actual == expected ? nil : "returned \(actual), host computed \(expected)"
}

// MARK: - Keil armasm syntax

let armasmProgram = """
; Keil-style startup + program (armasm syntax)
Stack_Size      EQU     0x00000200

                AREA    STACK, NOINIT, READWRITE, ALIGN=3
Stack_Mem       SPACE   Stack_Size
__initial_sp

                PRESERVE8
                THUMB

                AREA    RESET, DATA, READONLY
                EXPORT  __Vectors
__Vectors       DCD     __initial_sp              ; Top of Stack
                DCD     Reset_Handler             ; Reset Handler
                DCD     NMI_Handler
                DCD     HardFault_Handler
                DCD     0, 0, 0, 0, 0, 0, 0
                DCD     SVC_Handler               ; SVCall Handler
                DCD     0, 0, 0, 0

                IF      :LNOT::DEF:NO_CRP
                AREA    |.ARM.__at_0x02FC|, CODE, READONLY
CRP_Key         DCD     0xFFFFFFFF
                ENDIF

                AREA    |.text|, CODE, READONLY

Reset_Handler   PROC
                EXPORT  Reset_Handler             [WEAK]
                MOV     R4, #0
                LDR     R0, =values
                MOV     R1, #4
loop            LDR     R2, [R0], #4              ; sum the table
                ADD     R4, R4, R2
                SUBS    R1, R1, #1
                BNE     loop
                SVC     0x2A                      ; R5 <- SVC number
                LDR     R0, =text
                LDRB    R6, [R0, #1]              ; 'e'
                MOV     R7, #&FF                  ; armasm hex
                CMP     R4, #100
                MOVEQ   R8, #1                    ; implicit IT
                BKPT    0
InfLoop         B       InfLoop
                ENDP

NMI_Handler     PROC
                EXPORT  NMI_Handler               [WEAK]
                B       .
                ENDP
HardFault_Handler\\
                PROC
                EXPORT  HardFault_Handler         [WEAK]
                B       .
                ENDP
SVC_Handler     PROC
                EXPORT  SVC_Handler               [WEAK]
                STMFD   SP!, {R4, LR}
                MRS     R1, MSP
                LDR     R0, [R1, #(2*4+24)]       ; stacked PC (after our 2 pushed regs)
                LDRH    R0, [R0, #-2]             ; the SVC instruction
                AND     R5, R0, #0xFF
                LDMFD   SP!, {R4, LR}
                BX      LR
                ENDP

                ALIGN
values          DCD     10, 20, 30, 40
text            DCB     "Keil", 0
                ALIGN
                LTORG
                END
"""

/// Assembles armasm source either natively or through ArmasmTranslator + clang.
func armasmObject(_ source: String, native: Bool) throws -> [UInt8] {
    if native {
        let output = ArmasmAssembler.assemble(source: source, path: workDir.appendingPathComponent("test.s").path)
        if let error = output.diagnostics.first(where: \.isError) { throw ToolError(description: "line \(error.line): \(error.message)") }
        return output.object!
    }
    let translation = ArmasmTranslator.translate(source)
    if let error = translation.diagnostics.first(where: { $0.isError }) { throw ToolError(description: "line \(error.line): \(error.message)") }
    guard translation.text.components(separatedBy: "\n").count == source.components(separatedBy: "\n").count else {
        throw ToolError(description: "line count changed")
    }
    return try compile(translation.text, ext: "s", profile: profiles[0], extraFlags: ["-mimplicit-it=always"])
}

func runArmasmTest(native: Bool) throws -> String? {
    let object = try armasmObject(armasmProgram, native: native)
    let image = try Linker.link(objects: [(name: "startup.o", bytes: object)],
                                layout: LinkLayout(romBase: 0, romSize: 0x8_0000, ramBase: 0x1000_0000, ramSize: 0x8000))
    let memory = MemoryMap()
    memory.addROM(name: "IROM1", base: 0, size: 0x8_0000)
    memory.addRAM(name: "IRAM1", base: 0x1000_0000, size: 0x8000)
    let sim = Simulator(arch: .armv7m, memory: memory)
    try sim.load(image)
    try sim.reset(vectorTable: 0)
    guard sim.cpu.sp == 0x1000_0200 else { return String(format: "initial SP 0x%08X", sim.cpu.sp) }
    guard (try? memory.read(0x2FC, size: 4)) == 0xFFFF_FFFF else { return "CRP key not at 0x2FC" }
    let reason = sim.cpu.run(maxInstructions: 10_000)
    guard case .bkpt(0, _) = reason else { return "stopped with \\(reason)" }
    let r = sim.cpu.r
    let expected: [(Int, UInt32)] = [(4, 100), (5, 0x2A), (6, UInt32(UInt8(ascii: "e"))), (7, 0xFF), (8, 1)]
    for (i, value) in expected where r[i] != value {
        return String(format: "R%d = 0x%X, expected 0x%X", i, r[i], value)
    }
    return nil
}

// MARK: - LPC17xx peripherals (LandTiger)

let lpcProgram = """
                AREA    STACK, NOINIT, READWRITE, ALIGN=3
Stack_Mem       SPACE   0x400
__initial_sp
                THUMB
                AREA    RESET, DATA, READONLY
__Vectors       DCD     __initial_sp
                DCD     Reset_Handler
                SPACE   14*4                    ; exceptions 2..15
                DCD     0                       ; 16: WDT
                DCD     TIMER0_IRQHandler       ; 17: TIMER0 (IRQ1)
                SPACE   27*4                    ; 18..44
                DCD     RIT_IRQHandler          ; 45: RIT (IRQ29)

                AREA    |.text|, CODE, READONLY
Reset_Handler   PROC
                LDR     R0, =0x400FC000         ; LPC_SC
                MOV     R1, #0x20
                STR     R1, [R0, #0x1A0]        ; SCS: OSCEN
wait_osc        LDR     R1, [R0, #0x1A0]
                TST     R1, #0x40               ; OSCSTAT
                BEQ     wait_osc
                MOV     R1, #1
                STR     R1, [R0, #0x80]         ; PLL0CON: enable
wait_lock       LDR     R1, [R0, #0x88]
                TST     R1, #(1:SHL:26)         ; PLOCK0
                BEQ     wait_lock
                LDR     R0, =0x40004000         ; LPC_TIM0
                MOV     R1, #99
                STR     R1, [R0, #0x18]         ; MR0 = 99
                MOV     R1, #3
                STR     R1, [R0, #0x14]         ; MCR: MR0I | MR0R
                MOV     R1, #1
                STR     R1, [R0, #0x04]         ; TCR: enable
                LDR     R0, =0x400B0000         ; LPC_RIT
                LDR     R1, =1000
                STR     R1, [R0, #0x0]          ; RICOMPVAL
                MOV     R1, #0xA
                STR     R1, [R0, #0x8]          ; RICTRL: RITEN | RITENCLR
                LDR     R0, =0xE000E100         ; NVIC ISER0
                LDR     R1, =((1:SHL:1) :OR: (1:SHL:29))
                STR     R1, [R0]
                MOV     R4, #0
                MOV     R5, #0
loop            WFI
                CMP     R4, #10
                BLO     loop
                LDR     R0, =0x2009C040         ; LPC_GPIO2
                MOV     R1, #0xFF
                STR     R1, [R0, #0x00]         ; FIO2DIR: P2.0-7 output (LEDs)
                MOV     R1, #0x55
                STR     R1, [R0, #0x18]         ; FIO2SET
                LDR     R6, [R0, #0x14]         ; FIO2PIN
                AND     R6, R6, #0xFF
                BKPT    0
                ENDP

TIMER0_IRQHandler PROC
                LDR     R0, =0x40004000
                MOV     R1, #1
                STR     R1, [R0]                ; IR: clear MR0 flag
                ADD     R4, R4, #1
                BX      LR
                ENDP

RIT_IRQHandler  PROC
                LDR     R0, =0x400B0000
                LDR     R1, [R0, #8]
                ORR     R1, R1, #1
                STR     R1, [R0, #8]            ; clear RITINT
                ADD     R5, R5, #1
                BX      LR
                ENDP
                END
"""

func runLPCTest(native: Bool) throws -> String? {
    let object = try armasmObject(lpcProgram, native: native)
    let image = try Linker.link(objects: [(name: "lpc.o", bytes: object)],
                                layout: LinkLayout(romBase: 0, romSize: 0x8_0000, ramBase: 0x1000_0000, ramSize: 0x8000))
    let memory = MemoryMap()
    memory.addROM(name: "IROM1", base: 0, size: 0x8_0000)
    memory.addRAM(name: "IRAM1", base: 0x1000_0000, size: 0x8000)
    let sim = Simulator(arch: .armv7m, memory: memory)
    let lpc = LPC17xx.install(on: sim)
    memory.addMMIOFillingGaps(name: "APB/AHB", base: 0x4000_0000, size: 0x2000_0000, device: GenericPeripheralDevice())
    try sim.load(image)
    try sim.reset(vectorTable: 0)
    let reason = sim.cpu.run(maxInstructions: 100_000)
    guard case .bkpt(0, _) = reason else { return "stopped with \(reason)" }
    let r = sim.cpu.r
    if r[4] != 10 { return "TIMER0 interrupts: \(r[4]), expected 10" }
    if r[6] != 0x55 { return String(format: "FIO2PIN = 0x%02X, expected 0x55", r[6]) }
    if lpc.gpio.pins(2) & 0xFF != 0x55 { return "LED pins not driven" }
    // 10 timer periods of 100 TC counts at PCLK = CCLK/4 -> ~4000 cycles; RIT period 1001*4 cycles.
    let cycles = sim.cpu.cycles
    if cycles < 4000 || cycles > 4600 { return "unexpected cycle count \(cycles)" }
    if r[5] != UInt32(cycles / 4004) { return "RIT interrupts \(r[5]), expected \(cycles / 4004) after \(cycles) cycles" }
    return nil
}


// MARK: - Native armasm assembler: encoder vs clang

/// Unified-syntax instructions assembled by both clang and the native encoder (outside IT blocks).
let encoderCorpus: [String] = [
    // Where Keil and clang disagree Keil wins and the case lives in keilConfirmed (e.g. ADD #-48 -> SUBW).
    "movs r0, #3", "mov r0, #3", "mov r8, #1", "mov r1, #-1", "mov r2, #0xFF00FF00",
    "mvn r3, #0", "movw r4, #0x1234", "movt r4, #0xBEEF", "mov r0, #0x1234", "movs r0, r1", "mov r0, r1", "mov r8, r9",
    "mov sp, r0", "movs r8, r1", "mvns r1, r2", "mvn r1, r2", "mvn r1, r2, lsl #3",
    "adds r0, r1, r2", "add r0, r1, r2", "add r0, r0, r1", "add r0, r1", "add r8, r1", "adds r0, r0, #1", "adds r1, r0, #1",
    "adds r0, #200", "add r0, r0, #200", "add r0, r1, #4095", "add r0, r1, #0x10000", "adds r0, r1, #-4",
    "add sp, sp, #16", "add sp, #508", "sub sp, sp, #8", "add r0, sp, #8", "add r8, sp, #8", "add.w r0, r1, r2, lsl #2",
    "subs r0, r1, r2", "sub r0, r1, r2", "subs r0, #1", "sub r0, r0, #1", "subs r2, r3, #7", "sub r0, r1, #4000",
    "addw r0, r1, #1000", "subw r0, r1, #1000", "adc r0, r1, r2", "adcs r0, r0, r1", "adcs r0, r1", "sbcs r2, r2, r3", "sbc r0, r1, #5",
    "rsbs r0, r1, #0", "rsb r0, r1, #0", "rsb r0, r1, #10", "rsb r0, r1, r2, asr #3", "negs r0, r1",
    "ands r0, r1", "and r0, r0, r1", "and r0, r1, #0xFF", "and r0, r1, #0xFFFFFF00", "bics r0, r0, r1", "bic r0, #0xFF000000",
    "orrs r0, r1", "orr r0, r1, #1", "orr r0, r1, r2, ror #7", "orn r0, r1, #1", "orn r0, r1, r2", "eors r0, r1", "eor r0, r1, #0x80000000",
    "cmp r0, #0x10", "cmp r0, #300", "cmp r0, #-1", "cmp r0, r1", "cmp r8, r1", "cmp r0, r9", "cmp r0, r1, lsl #2",
    "cmn r0, #1", "cmn r0, r1", "tst r0, #0x40", "tst r0, r1", "teq r0, #1", "teq r0, r1",
    "lsls r0, r1, #2", "lsl r0, r1, #2", "lsrs r0, r1, #32", "lsr r0, #16", "asrs r0, r0, #1", "asr r0, r1, #31",
    "ror r0, r1, #4", "lsls r0, r1", "lsl r0, r0, r1", "lsl r0, r1, r2", "rors r1, r2", "rrx r0, r1", "rrxs r0, r1",
    "muls r0, r1, r0", "mul r0, r1, r2", "muls r1, r0", "mla r0, r1, r2, r3", "mls r0, r1, r2, r3",
    "umull r0, r1, r2, r3", "smull r0, r1, r2, r3", "umlal r0, r1, r2, r3", "smlal r0, r1, r2, r3", "sdiv r0, r1, r2", "udiv r0, r1, r2",
    "clz r0, r1", "rbit r0, r1", "rev r0, r1", "rev r8, r1", "rev16 r0, r1", "revsh r0, r1",
    "sxtb r0, r1", "sxth r0, r1", "uxtb r0, r1", "uxth r0, r1", "uxtb r8, r1", "uxtb r0, r1, ror #8",
    "bfc r0, #4, #8", "bfi r0, r1, #4, #8", "sbfx r0, r1, #3, #5", "ubfx r0, r1, #0, #16", "ssat r0, #8, r1", "usat r0, #8, r1, lsl #2",
    "ldr r0, [r1]", "ldr r0, [r1, #24]", "ldr r0, [r1, #124]", "ldr r0, [r1, #128]", "ldr r0, [r0, #-4]", "ldr r8, [r1]",
    "ldr r0, [sp, #8]", "ldr r0, [sp, #1020]", "ldr r0, [sp, #1024]", "ldr r0, [r1, #4]!", "ldr r0, [r1], #4", "ldr r0, [r1], #-4",
    "ldr r0, [r1, r2]", "ldr r0, [r1, r2, lsl #2]", "ldr r0, [r8, r2]", "ldr r0, [pc, #8]", "ldr.w r0, [r1]",
    "ldrb r0, [r1, #31]", "ldrb r0, [r1, #32]", "ldrb r0, [r1, r2]", "ldrh r0, [r1, #62]", "ldrh r0, [r1, #1]", "ldrsb r0, [r1]",
    "ldrsb r0, [r1, r2]", "ldrsh r0, [r1, #2]", "ldrsh r0, [r1, r2]", "str r0, [r1]", "str r0, [r1, #4]", "str r0, [sp, #4]",
    "str r0, [r1, #-8]", "str r0, [sp, #-4]!", "strb r0, [r1, #3]", "strh r0, [r1, #6]", "strb r0, [r1, r2]", "strh r0, [r1, r2, lsl #1]",
    "ldrd r0, r1, [r2]", "ldrd r0, r1, [r2, #8]", "ldrd r0, r1, [r2, #-8]!", "strd r0, r1, [r2], #16",
    "ldrex r0, [r1]", "ldrex r0, [r1, #4]", "strex r2, r0, [r1]", "ldrexb r0, [r1]", "strexh r2, r0, [r1]", "clrex",
    "ldrt r0, [r1, #4]", "strbt r0, [r1]",
    "push {r4, lr}", "push {r4-r11, lr}", "push {r8}", "pop {r4, pc}", "pop {r4-r11, pc}", "pop {r8}",
    // armasm (unlike clang) assembles STMDB/STMFD SP! {low regs, LR} as the 16-bit PUSH.
    "stmdb sp!, {r4-r11, lr}", "ldmia sp!, {r4-r11, lr}", "ldmia r0!, {r1, r2}", "ldmia r0, {r0, r1}",
    "stmia r0!, {r1, r2}", "ldm r0, {r1, r2}", "stmia r8!, {r1, r2}", "ldmdb r0, {r1, r2}", "stm r0, {r1, r2}",
    "bx lr", "blx r3", "tbb [r0, r1]", "tbh [r0, r1, lsl #1]",
    "nop", "nop.w", "wfi", "wfe", "sev", "yield", "bkpt #0", "bkpt #0xAB", "svc #0x10", "udf #1",
    "cpsie i", "cpsid i", "cpsie f", "dmb sy", "dsb", "isb", "dmb ish",
    "mrs r1, psp", "mrs r0, msp", "mrs r0, primask", "mrs r0, xpsr", "mrs r0, control", "msr control, r0", "msr psp, r1",
    "msr basepri, r0", "msr apsr_nzcvq, r0", "msr primask, r0",
]

/// Thumb-1 subset for Cortex-M0 (only 16-bit forms + BL/MRS/MSR/barriers).
let encoderCorpusM0: [String] = [
    "movs r0, #3", "mov r0, r1", "mov r8, r9", "adds r0, r1, r2", "adds r0, #200", "add r0, r8", "subs r0, #1",
    "add sp, #16", "sub sp, #8", "add r0, sp, #8", "ands r0, r1", "lsls r0, r1, #2", "lsrs r0, r1", "muls r1, r0",
    "ldr r0, [r1, #4]", "ldr r0, [sp, #8]", "ldrb r0, [r1, r2]", "ldrsh r0, [r1, r2]", "strh r0, [r1, #6]",
    "push {r4-r7, lr}", "pop {r4-r7, pc}", "ldmia r0!, {r1, r2}", "stmia r0!, {r1, r2}", "cmp r0, #10", "cmp r8, r0",
    "sxtb r0, r1", "rev r0, r1", "cpsid i", "mrs r0, primask", "msr primask, r0", "dmb", "dsb", "isb", "svc #1", "bkpt #3",
]

func clangBytes(_ lines: [String], profile: Profile) throws -> [[UInt8]] {
    var source = ".syntax unified\n.thumb\n.text\n"
    for (i, line) in lines.enumerated() { source += "L\(i):\n    \(line)\n" }
    source += "Lend:\n    nop\n"
    let object = try compile(source, ext: "s", profile: profile)
    let objectURL = workDir.appendingPathComponent("enc-\(profile.name).o")
    try Data(object).write(to: objectURL)
    let symbols = try run(["xcrun", "llvm-objdump", "-t", objectURL.path])
    var offsets: [Int: Int] = [:]
    var end = 0
    for line in symbols.split(separator: "\n") {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard let name = parts.last, let address = Int(parts.first ?? "", radix: 16) else { continue }
        if name == "Lend" { end = address }
        if name.hasPrefix("L"), let n = Int(name.dropFirst()) { offsets[n] = address }
    }
    let text = try run(["xcrun", "llvm-objdump", "-s", "--section=.text", objectURL.path])
    var bytes: [UInt8] = []
    for line in text.split(separator: "\n") where line.hasPrefix(" ") {
        let fields = line.split(separator: " ", omittingEmptySubsequences: true).dropFirst().prefix(4)
        for f in fields where f.count % 2 == 0 && f.allSatisfy(\.isHexDigit) {
            var k = f.startIndex
            while k < f.endIndex {
                let next = f.index(k, offsetBy: 2)
                bytes.append(UInt8(f[k..<next], radix: 16)!)
                k = next
            }
        }
    }
    return lines.indices.map { i in
        let start = offsets[i] ?? 0
        let stop = i + 1 < lines.count ? offsets[i + 1] ?? end : end
        return Array(bytes[start..<min(stop, bytes.count)])
    }
}

func runEncoderCorpus(_ lines: [String], profile: Profile) throws -> String? {
    let expected = try clangBytes(lines, profile: profile)
    var problems: [String] = []
    for (i, line) in lines.enumerated() {
        let hex = { (b: [UInt8]) in b.map { String(format: "%02x", $0) }.joined() }
        do {
            let ours = try ArmasmAssembler.assembleInstruction(line, arch: profile.arch)
            if ours != expected[i] { problems.append("'\(line)': ours \(hex(ours)), clang \(hex(expected[i]))") }
        } catch {
            problems.append("'\(line)': \(error)")
        }
    }
    return problems.isEmpty ? nil : "\(problems.count) mismatches:\n      " + problems.joined(separator: "\n      ")
}

/// Encodings taken from Keil armasm listings (public GitHub projects + PoliTo templates).
let keilConfirmed: [(line: String, bytes: String)] = [
    ("STMFD SP!, {R4, LR}", "B510"), ("STMFD SP!, {R0-R4, LR}", "B51F"), ("STMDB SP!, {R4, R5}", "B430"),
    ("STMFD SP!, {R4-R11, LR}", "E92D 4FF0"), ("PUSH {R12, LR}", "E92D 5000"), ("PUSH {R0, LR}", "B501"),
    ("STMFD r1!, {r4}", "F841 4D04"), ("STMFD r0!, {lr}", "F840 ED04"), ("LDMFD R0!, {LR}", "F850 EB04"),
    ("ADD R1, PC, #0", "A100"), ("ADD R1, R1, #-1", "F101 31FF"), ("add r4, r4, #-48", "F2A4 0430"),
    ("ADD R2, R0, #0xc3a", "F600 423A"), ("SUB R0, #1", "F1A0 0001"), ("ADD SP, SP, #4", "B001"),
    ("LDR R3, =0x121", "F240 1321"), ("LDR R2, =0xFFFF", "F64F 72FF"), ("LDR R0, =1017", "F240 30F9"),
    ("LDR R2, =500", "F44F 72FA"), ("LDR r5, =10", "F04F 050A"), ("LDR R1, =0x00FFFFFF", "F06F 417F"),
    ("LDR R3, =0xFFFFFFFF", "F04F 33FF"), ("LDR R3, =0x11111111", "F04F 3311"),
    ("MRS R0, PRIMASK", "F3EF 8010"), ("MSR PRIMASK, R0", "F380 8810"), ("CPSID I", "B672"),
    ("LDRD r4, r5, [r0]", "E9D0 4500"), ("STR R8, [sp, #8]", "F8CD 8008"), ("LSR R0, #16", "EA4F 4010"),
]

/// Implicit IT blocks exactly as Keil groups them (746.lst): a BL/BLX ends the block, blank lines don't.
let keilImplicitIT = (source: """
        AREA |.text|, CODE, READONLY
        IMPORT store
        STMFDEQ SP!, {R0-R12, LR}
        BLEQ    store
        LDMFDEQ SP!, {R0-R12, LR}
        SUBEQ   R3, R3, #1

        STREQ   R0, [SP, #4]
        SUBEQ   R9, R11, R3
        MOVEQ   R0, R9
        STMFDEQ SP!, {R0-R4, LR}
        BLXEQ   R12
        LDMFDEQ SP!, {R0-R4, LR}
        LDREQ   R0, [SP, #4]
        MOVEQ   R9, #1
        MOVEQ   R10, #0
        END
""", bytes: "BF04 E92D 5FFF F7FF FFFE BF01 E8BD 5FFF 1E5B 9001 EBAB 0903 BF02 4648 B51F 47E0 BF01 E8BD 401F 9801 F04F 0901 F04F 0A00")

func halfwords(_ bytes: [UInt8]) -> String {
    stride(from: 0, to: bytes.count - 1, by: 2).map { String(format: "%04X", UInt16(bytes[$0]) | UInt16(bytes[$0 + 1]) << 8) }
        .joined(separator: " ")
}

func runKeilConfirmed() throws -> String? {
    var problems: [String] = []
    for (line, expected) in keilConfirmed {
        do {
            let ours = halfwords(try ArmasmAssembler.assembleInstruction(line))
            if ours != expected { problems.append("'\(line)': ours \(ours), Keil \(expected)") }
        } catch { problems.append("'\(line)': \(error)") }
    }
    let output = ArmasmAssembler.assemble(source: keilImplicitIT.source, path: workDir.appendingPathComponent("it.s").path)
    if let e = output.diagnostics.first(where: \.isError) { problems.append("IT program: \(e.message)") }
    let code = output.listing.filter(\.isCode).flatMap(\.bytes)
    if halfwords(code) != keilImplicitIT.bytes { problems.append("implicit IT blocks:\n        ours \(halfwords(code))\n        Keil \(keilImplicitIT.bytes)") }
    return problems.isEmpty ? nil : problems.joined(separator: "\n      ")
}

/// Keil .lst listings in templates/ (not in git) must be reproduced line by line; only the
/// "Command Line" block and the "N symbols in table" total (Keil counts its built-in symbols) differ.
func runKeilListingTests() throws -> String? {
    let root = URL(fileURLWithPath: "templates")
    guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
    func normalized(_ text: String) -> [String] {
        var lines = text.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")
        if let start = lines.firstIndex(where: { $0.hasPrefix("Command Line:") }),
           let end = lines[start...].firstIndex(where: { $0.isEmpty }) {
            lines.removeSubrange(start..<end)
        }
        return lines.filter { !$0.hasSuffix("symbols in table") }
    }
    var checked = 0
    var problems: [String] = []
    for case let url as URL in walker where url.pathExtension == "lst" && url.deletingLastPathComponent().lastPathComponent == "Listings"
        && !url.path.contains("zipped") {
        let project = url.deletingLastPathComponent().deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent.lowercased()
        guard let files = FileManager.default.enumerator(at: project, includingPropertiesForKeys: nil),
              let source = (files.compactMap { $0 as? URL }).first(where: {
                  $0.pathExtension == "s" && $0.deletingPathExtension().lastPathComponent.lowercased() == stem
              }) else { continue }
        let relative = String(source.path.dropFirst(project.path.count + 1)).replacingOccurrences(of: "/", with: "\\")
        let output = ArmasmAssembler.assemble(fileAt: source.path,
                                              options: .init(listing: (displayPath: relative, commandLine: "")))
        guard let ours = output.listingText, let keil = try? String(contentsOf: url, encoding: .isoLatin1) else {
            problems.append("\(url.lastPathComponent): no listing"); continue
        }
        let a = normalized(ours), b = normalized(keil)
        checked += 1
        if let i = zip(a, b).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset ?? (a.count != b.count ? min(a.count, b.count) : nil) {
            problems.append("\(project.lastPathComponent)/\(url.lastPathComponent) line \(i + 1):\n        ours '\(i < a.count ? a[i] : "<end>")'\n        Keil '\(i < b.count ? b[i] : "<end>")'")
        }
    }
    if checked == 0 { return nil }
    return problems.isEmpty ? nil : problems.joined(separator: "\n      ")
}

/// Exercises the armasm features clang never sees: macros, WHILE, SETA, numeric labels, pools.
let armasmFeatureProgram = """
                GBLA    count
count           SETA    0
                MACRO
$lbl            ADDK    $reg, $value=1
$lbl            ADD     $reg, $reg, #$value
                MEND
                AREA    STACK, NOINIT, READWRITE, ALIGN=3
                SPACE   0x100
__initial_sp
                AREA    RESET, DATA, READONLY
                DCD     __initial_sp, Reset_Handler
                AREA    |.text|, CODE, READONLY
                THUMB
Reset_Handler   PROC
                MOV     R0, #0
                WHILE   count < 5
                ADDK    R0, count
count           SETA    count + 1
                WEND                            ; R0 = 0+1+2+3+4 = 10
                ADDK    R0                      ; default parameter: 11
                IF      count = 5 :LAND: {TRUE}
                MOV     R1, #(3 :SHL: 2) + 1    ; 13
                ELSE
                MOV     R1, #0
                ENDIF
                MOV     R2, #3
1               SUBS    R2, R2, #1
                BNE     %B1                     ; numeric local label
                LDR     R3, =0x12345678
                LDR     R4, =0x12345678         ; same pool entry
                CMP     R0, #11
                MOVEQ   R5, #1                  ; implicit IT
                MOVNE   R5, #2
                LDR     R6, =table
                LDR     R6, [R6, #4]
                ADR     R7, table
                LDR     R7, [R7, #(table_end - table - 4)]
                MOV32   R8, 0xCAFEF00D
                BL      helper
                BKPT    0
                ENDP
helper          PROC
                CBZ     R0, %F2
                MOV     R9, #0x77
2               BX      LR
                ENDP
                LTORG
                ALIGN   4
table           DCD     1, 2, 3, 0x42
table_end
                END
"""

func runArmasmFeatureTest() throws -> String? {
    let object = try armasmObject(armasmFeatureProgram, native: true)
    let image = try Linker.link(objects: [(name: "features.o", bytes: object)],
                                layout: LinkLayout(romBase: 0, romSize: 0x8_0000, ramBase: 0x1000_0000, ramSize: 0x8000))
    let memory = MemoryMap()
    memory.addROM(name: "IROM1", base: 0, size: 0x8_0000)
    memory.addRAM(name: "IRAM1", base: 0x1000_0000, size: 0x8000)
    let sim = Simulator(arch: .armv7m, memory: memory)
    try sim.load(image)
    try sim.reset(vectorTable: 0)
    let reason = sim.cpu.run(maxInstructions: 10_000)
    guard case .bkpt(0, _) = reason else { return "stopped with \(reason)" }
    let r = sim.cpu.r
    let expected: [(Int, UInt32)] = [(0, 11), (1, 13), (2, 0), (3, 0x1234_5678), (4, 0x1234_5678), (5, 1), (6, 2),
                                     (7, 0x42), (8, 0xCAFE_F00D), (9, 0x77)]
    for (i, value) in expected where r[i] != value {
        return String(format: "R%d = 0x%X, expected 0x%X", i, r[i], value)
    }
    return nil
}

/// The LandTiger course template (01_SVC) must link to the same bytes as Keil's own SVC.axf.
func runKeilTemplateTest(source: String = "templates/01_SVC/Source/template.s", axf: String = "templates/01_SVC/Objects/SVC.axf") throws -> String? {
    let output = ArmasmAssembler.assemble(fileAt: source)
    if let error = output.diagnostics.first(where: \.isError) { return "line \(error.line): \(error.message)" }
    let ours = try Linker.link(objects: [(name: "template.o", bytes: output.object!)],
                               layout: LinkLayout(romBase: 0, romSize: 0x8_0000, ramBase: 0x1000_0000, ramSize: 0x8000))
    let keil = try ELFLoader.parse([UInt8](try Data(contentsOf: URL(fileURLWithPath: axf))))
    func flat(_ image: ELFImage) -> [UInt32: UInt8] {
        var bytes: [UInt32: UInt8] = [:]
        for s in image.segments where !s.isZeroInitialized && s.address < 0x1000_0000 {
            for (k, b) in s.bytes.enumerated() { bytes[s.address + UInt32(k)] = b }
        }
        return bytes
    }
    let a = flat(ours), b = flat(keil)
    for address in b.keys.sorted() where (a[address] ?? 0) != b[address] {
        return String(format: "byte at 0x%X differs: 0x%02X, Keil 0x%02X", address, a[address] ?? 0, b[address]!)
    }
    for address in a.keys.sorted() where b[address] == nil && a[address] != 0 {
        return String(format: "extra byte at 0x%X", address)
    }
    return nil
}


// MARK: - Main

var passed = 0
var failed = 0

func report(_ label: String, _ body: () throws -> String?) {
    do {
        if let problem = try body() {
            failed += 1
            print("FAIL  \(label): \(problem)")
        } else {
            passed += 1
            print("ok    \(label)")
        }
    } catch {
        failed += 1
        print("FAIL  \(label): \(error)")
    }
}

print("== Assembly tests")
for test in asmTests {
    for profile in profiles where profile.arch != .armv6m || test.thumb1Only {
        report("[\(profile.name)] \(test.name)") { try runAsmTest(test, profile: profile) }
    }
}

print("\n== Keil armasm syntax")
report("[M3] armasm startup + SVC + tables (LPC1768 layout)") { try runArmasmTest(native: false) }

report("[M3] LPC17xx PLL lock, TIMER0 + RIT interrupts, WFI, GPIO (LandTiger)") { try runLPCTest(native: false) }

print("\n== Native armasm assembler")
report("[M3] encoder vs clang (\(encoderCorpus.count) instructions)") { try runEncoderCorpus(encoderCorpus, profile: profiles[0]) }
report("[M3] native: armasm startup + SVC + tables") { try runArmasmTest(native: true) }
report("[M3] native: LPC17xx timers, interrupts, GPIO") { try runLPCTest(native: true) }
report("[M3] native: \(keilConfirmed.count + 1) encodings confirmed by Keil listings") { try runKeilConfirmed() }
report("[M3] native: macros, WHILE, IF, local labels, literal pools, implicit IT") { try runArmasmFeatureTest() }
if FileManager.default.fileExists(atPath: "templates/01_SVC/Objects/SVC.axf") {
    report("[M3] native: 01_SVC template links byte-identical to Keil's SVC.axf") { try runKeilTemplateTest() }
}
if FileManager.default.fileExists(atPath: "templates") {
    report("[M3] native: Keil .lst listings of templates/ reproduced line by line") { try runKeilListingTests() }
}
// PoliTo course templates (templates/, not in git): assembly-only projects with a Keil-built .axf.
for (source, axf) in [("templates/00_ASM_template/Source/startup.s", "templates/00_ASM_template/Objects/ASM_template.axf")]
where FileManager.default.fileExists(atPath: axf) {
    report("[M3] native: \(source.split(separator: "/")[1]) links byte-identical to Keil") {
        try runKeilTemplateTest(source: source, axf: axf)
    }
}
report("[M0] encoder vs clang (\(encoderCorpusM0.count) instructions)") { try runEncoderCorpus(encoderCorpusM0, profile: profiles[1]) }

print("\n== Differential C tests (simulator vs native Mac)")
for test in cTests {
    for profile in profiles where profile.arch != .armv6m || !test.needsThumb2 {
        for optimization in ["-O0", "-O2", "-Os"] {
            report("[\(profile.name) \(optimization)] \(test.name)") {
                try runCTest(test, profile: profile, optimization: optimization)
            }
        }
    }
}

print("\n\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
