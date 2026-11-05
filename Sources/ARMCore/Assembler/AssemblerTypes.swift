// Shared contract between the native armasm front-end (Armasm*.swift) and the
// Thumb/Thumb-2 instruction encoder (ThumbEncoder.swift).

/// Value of an operand expression.
public enum AsmValue: Equatable, Sendable {
    /// Absolute constant.
    case constant(Int64)
    /// Address of `symbol` + `addend` (label in any section, or external symbol).
    case symbol(String, addend: Int64)
}

/// What still has to be filled into an encoded instruction once addresses are known.
/// Same-section targets are patched by the front-end with `ThumbEncoder.patch`; anything
/// else becomes an ELF relocation (`ThumbEncoder.relocationType`).
public enum AsmFixupKind: Equatable, Sendable {
    case thumbCall          // BL                       R_ARM_THM_CALL (10)
    case thumbJump24        // B.W                      R_ARM_THM_JUMP24 (30)
    case thumbJump19        // B<c>.W                   R_ARM_THM_JUMP19 (51)
    case thumbJump11        // B (16-bit)               R_ARM_THM_JUMP11 (102)
    case thumbJump8         // B<c> (16-bit)            R_ARM_THM_JUMP8 (103)
    case thumbCBZ           // CBZ/CBNZ                 must resolve locally (no ELF reloc)
    case thumbLoadLiteral8  // LDR Rt,[PC,#imm8*4]      must resolve locally (literal pools)
    case thumbLoadLiteral12 // LDR.W Rt,[PC,#+/-imm12]  R_ARM_THM_PC12 (54)
    case thumbADR8          // ADR Rd,label (16-bit)    must resolve locally
    case thumbADR12         // ADR.W / ADDW/SUBW Rd,PC  R_ARM_THM_ALU_PREL_11_0 (53)
    case movwAbs            // MOVW Rd,#:lower16:x      R_ARM_THM_MOVW_ABS_NC (47)
    case movtAbs            // MOVT Rd,#:upper16:x      R_ARM_THM_MOVT_ABS (48)
    case abs32              // data word                R_ARM_ABS32 (2)
}

public struct AsmFixup: Equatable, Sendable {
    /// Byte offset of the fixed-up field inside `AsmEncoded.bytes`.
    public var offset: Int
    public var kind: AsmFixupKind
    public var target: AsmValue

    public init(offset: Int, kind: AsmFixupKind, target: AsmValue) {
        self.offset = offset
        self.kind = kind
        self.target = target
    }
}

public struct AsmEncoded: Equatable, Sendable {
    /// Little-endian instruction bytes (2 or 4 per instruction; an implicit IT may be prepended).
    public var bytes: [UInt8]
    public var fixups: [AsmFixup]

    public init(bytes: [UInt8], fixups: [AsmFixup] = []) {
        self.bytes = bytes
        self.fixups = fixups
    }
}

public struct AsmError: Error, Equatable, CustomStringConvertible, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}
