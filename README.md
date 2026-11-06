# ARM Sim

A µVision-style IDE and Cortex-M simulator for macOS.

ARM Sim is for students and developers who use Keil µVision on Windows and want to work on a Mac. You can open a `.uvprojx` project, build it and debug it in a simulator. The layout follows the µVision layout, so moving between the two tools is easy.

It has been tested mainly on the LPC1768 / LandTiger projects of the Politecnico di Torino computer architecture course.

> ARM Sim is an independent, clean-room project. It is not affiliated with Arm or Keil. It does not contain Keil code, tools or artwork. Keil and µVision are trademarks of Arm Limited.

## Features

### Projects
- Open µVision `.uvprojx` projects directly, including multi-target projects. Changes are saved back only when you edit something.
- Read and write the `.uvoptx` debug options: breakpoints, Watch 1 and 2, Memory 1, "Run to main()" and the initialization file.
- Use CMSIS packs: Pack Installer, a device database read from `.pdsc`, the SVD System Viewer and the Configuration Wizard.

### Build
- C files are compiled with the Apple clang from the Xcode Command Line Tools, using flags equivalent to Arm Compiler 6.
- Keil armasm syntax is assembled with a native assembler. Its encodings match armasm on the course templates.
- The built-in linker creates an `.axf` file and an armlink-style `.map` file. Listings are written in the Keil `.lst` format.
- A small runtime is included: `__main`, `printf` through ITM, string functions, `malloc`, soft-float and `math.h`.

### Simulator
- Cortex-M0, M3 and M4 cores (Thumb and Thumb-2), with exceptions, NVIC and SysTick.
- On the M4: the FPv4-SP FPU and the DSP extension.
- LPC17xx peripherals: SC/PLL, GPIO, TIMER0-3, RIT, EINT, UART, ADC, DAC and CAN1/CAN2.
- LandTiger board: LEDs, buttons, joystick, potentiometer, speaker, TFT display and touch panel.

### Debugger
- Windows: Registers, Disassembly, Memory, Watch with typed DWARF variables, Call Stack + Locals, Command, Logic Analyzer, Code Coverage and peripheral windows.
- µVision debug scripts (`.ini`): `FUNC` and `SIGNAL` functions, `DEFINE BUTTON` (Toolbox window) and VTREGs such as `PORT2` and `AIN5`.
- "Start Debug Session with Keil Image" debugs an `.axf` built by µVision, without rebuilding it.

## Requirements

- macOS 14 or later.
- Xcode Command Line Tools, needed to compile C files: `xcode-select --install`. Xcode is not required.

## Install the release

1. Download `ARM-Sim-<version>-macOS.zip` from [Releases](../../releases).
2. Unzip it and move `ARM Sim.app` to `/Applications`.
3. The app is not notarized, so macOS blocks the first launch. To allow it, do one of these:
   - Right-click the app, select **Open**, then select **Open** again.
   - Run `xattr -dr com.apple.quarantine "/Applications/ARM Sim.app"`.

The release build is for Apple silicon (arm64). On an Intel Mac, build the app from source.

## Build from source

```sh
./scripts/make-app.sh          # creates build/ARM Sim.app
open "build/ARM Sim.app"
```

Other targets:

```sh
swift run -c release armsim-selftest   # self tests: assemble/compile snippets, run them, compare results
swift run armsim --help                 # command line simulator and assembler
```

## Command line tool

`armsim` runs an ELF, `.o` or `.bin` file in the simulator. It can also assemble Keil armasm sources:

```sh
armsim --cpu m4 program.axf
armsim --list out.lst --assemble startup.s startup.o
```

## Status

The main items still open are:
- PWM, I2C and SSP0.
- A 1:1 µVision interface.
- Cortex-M7 double precision.
- Real hardware debugging.

## License

ARM Sim is source-available under the [PolyForm Noncommercial License 1.0.0](LICENSE). You may use, study and change it for any noncommercial purpose, including personal study, teaching and research.

Commercial use, including selling or redistributing the app for a fee, needs a separate license from the author.
