from site_scons.library.helpers import run_and_log
from rich import print
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, List, Sequence, Union
import shutil
import os
import math


class BinaryCompiler:

    # Addressability is in number of bytes.
    def __init__(self, env: dict, output_folder: str, input_file: str, addressability: int): 
        self.tty_output = env.get('RAW')
        self.gcc = env["TOOL_CONFIG"]["riscv"]["RISCV_GCC"]
        self.objdump = env["TOOL_CONFIG"]["riscv"]["RISCV_OBJDUMP"]
        self.objcopy = env["TOOL_CONFIG"]["riscv"]["RISCV_OBJCOPY"]
        self.env = env["ENV"]

        self.input_file = input_file
        self.output_folder = output_folder
        self.addressability = addressability
        self.output_elf = os.path.join(output_folder, "program.elf")
        self.output_dis = os.path.join(output_folder, "program.dis")
        self.output_hex = os.path.join(output_folder, "program.hex")

        self.linker_script = os.path.join(env["SIM_ROOT"], "bin", "link.ld")
        self.start_file = os.path.join(env["SIM_ROOT"], "bin", "startup.s") if Path(input_file).suffix.lower() not in [".s", ".asm"] else ""
        self.arch = env["SIM_CFG"].get("arch", "rv32i")
        self.abi = "ilp32"

        for file in [self.output_elf, self.output_dis, self.output_hex]:
            if os.path.isfile(file):
                os.remove(file)

    def generate_elf(self):
        if Path(self.input_file).suffix.lower() != ".elf":
            opt = "-Ofast -flto"
            warn = "-Wall -Wextra -Wno-unused"
            assembler_args = f"-mcmodel=medany -ffreestanding -nostartfiles -static -static-libgcc -lm -lgcc -lc -Wl,--no-relax -march={self.arch} -mabi={self.abi} {opt} {warn} -T {self.linker_script}"

            cmd = f"{self.gcc} {assembler_args} {self.start_file} {self.input_file} -o {self.output_elf}"
            print(f"[bold cyan][PROG] Compiling {self.input_file} with {cmd}[/bold cyan]")
            rc = run_and_log(
                cmd,
                log_path=os.path.join(self.output_folder, "bc_elf.log"),
                env=self.env,
                cwd=self.output_folder,
                simple_output=self.tty_output
            )

            if rc != 0:
                print(f"[bold red][PROG] ERROR:[/bold red] Failed to compile {self.input_file}: {os.path.join(self.output_folder, 'bc_elf.log')}")
                return 1
            else:
                print(f"[bold green][PROG] Successfully compiled {self.input_file}[/bold green]: {os.path.join(self.output_folder, 'bc_elf.log')}")
        else:
            shutil.copy2(self.input_file, self.output_elf)

        return 0

    def generate_dis(self):
        print(f"[bold cyan][PROG] Disassembling {self.input_file} to {self.output_dis}[/bold cyan]")
        cmd = f"{self.objdump} -D -Mnumeric {self.output_elf} > {self.output_dis}"

        rc = run_and_log(
            cmd,
            log_path=os.path.join(self.output_folder, "bc_dis.log"),
            env=self.env,
            cwd=self.output_folder,
            simple_output=self.tty_output
        )

        if rc != 0:
            print(f"[bold red][PROG] ERROR:[/bold red] Failed to disassemble {self.input_file}: {os.path.join(self.output_folder, 'bc_dis.log')}")
            return 1
        else:
            print(f"[bold green][PROG] Successfully disassembled {self.output_elf}[/bold green]: {os.path.join(self.output_folder, 'bc_dis.log')}")

        return 0

    def generate_hex(self):
        print(f"[bold cyan][PROG] Generating hex memory list to {self.output_hex}[/bold cyan]")

        a = int(self.addressability)
        if a <= 0 or (a & (a - 1)) != 0:
            print(f"[bold red][PROG] ERROR:[/bold red] addressability must be a power of two (bytes). Got {a}")
            return 1

        shift = int(math.log2(a))
        tmp_base = Path(self.output_folder) / "bc_section.tmp.bin"

        try:
            cp = subprocess.run(
                [self.objdump, "-h", self.output_elf],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
        except Exception as e:
            print(f"[bold red][PROG] ERROR:[/bold red] Failed to run objdump: {e}")
            return 1

        if cp.returncode != 0:
            print(f"[bold red][PROG] ERROR:[/bold red] objdump -h failed:\n{cp.stderr.strip()}")
            return 1

        sections = []
        for line in cp.stdout.splitlines():
            line = line.strip()
            if not line or not line[0].isdigit():
                continue
            parts = line.split()
            if len(parts) < 4:
                continue
            name = parts[1]
            size = int(parts[2], 16)
            vma = int(parts[3], 16)
            sections.append((name, size, vma))

        if not sections:
            print(f"[bold red][PROG] ERROR:[/bold red] No sections found in objdump output")
            return 1

        try:
            with open(self.output_hex, "w", encoding="utf-8") as out:
                for name, size, vma in sections:
                    end = vma + size
                    if (vma % a) or (size % a) or (end % a):
                        print(
                            f"[bold red][PROG] ERROR:[/bold red] "
                            f"Non-aligned section {name}: start=0x{vma:x} size=0x{size:x} end=0x{end:x} "
                            f"(needs alignment {a})"
                        )
                        return 1

                    tmp = tmp_base.with_name(f"{tmp_base.stem}.{name}{tmp_base.suffix}")
                    tmp.unlink(missing_ok=True)

                    cp2 = subprocess.run(
                        [self.objcopy, "-O", "binary", "-j", name, self.output_elf, str(tmp)],
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                        text=True,
                    )
                    if cp2.returncode != 0:
                        print(
                            f"[bold red][PROG] ERROR:[/bold red] objcopy failed for section {name}:\n"
                            f"{cp2.stderr.strip()}"
                        )
                        return 1

                    data = tmp.read_bytes() if tmp.exists() else b""
                    tmp.unlink(missing_ok=True)

                    if not data:
                        continue

                    out.write(f"@{(vma >> shift):08x}\n")

                    for i in range(0, len(data), a):
                        word = data[i : i + a]
                        if len(word) < a:
                            word += b"\x00" * (a - len(word))
                        out.write(word[::-1].hex() + "\n")

                    out.write("\n")

        except Exception as e:
            print(f"[bold red][PROG] ERROR:[/bold red] Failed to write hex file: {e}")
            return 1

        print(f"[bold green][PROG] Successfully generated hex[/bold green]: {self.output_hex}")
        return 0

    def generate(self):
        rc = self.generate_elf()
        if rc != 0:
            return 1
        
        rc = self.generate_dis()
        if rc != 0:
            return 1

        rc = self.generate_hex()
        
        return rc
