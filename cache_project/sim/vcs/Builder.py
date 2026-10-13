import os
from abc import ABC, abstractmethod
from glob import glob
from pathlib import Path
from typing import Dict, List, Optional


class BaseVCSBuilder(ABC):
    def __init__(self, **kwargs):
        self.env = kwargs.get("env")
        self.rtl_sources = kwargs.get("rtl_sources")
        self.tb_sources = kwargs.get("tb_sources")
        self.sram_enabled = kwargs.get("sram_enabled")

    def get_include_dirs_flag(self, tb: Path) -> str:
        include_dirs = self.tb_sources.get("include_dirs", [])
        if include_dirs:
            return "+incdir+" + "+".join(include_dirs)
        return f"+incdir+{os.path.dirname(str(tb))}"

    def get_base_vcs_flags(self, incdir_flag: str) -> List[str]:
        return [
            "-licqueue",
            "-full64",
            "-lca",
            "-sverilog",
            "-timescale=1ps/1ps",
            "-debug_access+all",
            "-kdb",
            "-suppress=LCA_FEATURES_ENABLED",
            "-msg_config=messages.config",
            "-xprop=xprop.config",
            "-xprop=flowctrl",
            "-assert svaext",
            "+define+DW_SUPPRESS_WARN",
            incdir_flag,
        ]

    def get_base_sim_flags(self) -> List[str]:
        return [
            "-exitstatus",
            "-suppress=ASLR_DETECTED_INFO",
        ]

    def get_common_sim_plusargs(self) -> Dict[str, any]:
        return {
            "SIM_TIMEOUT": self.env["SIM_CFG"]["timeout"],
            "DUMP_FSDB": int(self.env.get("DUMP_FSDB", 0)),
            "CLOCK_PERIOD_PS": self.env["SIM_CFG"]["clock_period"],
        }

    def format_plusargs(self, plusargs: Dict[str, any]) -> str:
        return " ".join(f"+{key}={value}" for key, value in plusargs.items())

    @abstractmethod
    def get_source_files(self, tb: Path, output_dir: str) -> List[str]:
        pass

    @abstractmethod
    def get_additional_vcs_flags(self) -> List[str]:
        pass

    @abstractmethod
    def get_additional_plusargs(self, output_dir: str) -> Dict[str, any]:
        pass

    def build_vcs_elab_cmd(self, name: str, tb: Path, output_dir: str) -> str:
        incdir_flag = self.get_include_dirs_flag(tb)
        source_files = " ".join(self.get_source_files(tb, output_dir))

        if self.sram_enabled:
            sram_verilog = " ".join(os.path.abspath(f) for f in glob(os.path.join(self.env["BUILD_ROOT"], "sram/**/*.v"), recursive=True))
            source_files += " " + sram_verilog

        vcs_flags = self.get_base_vcs_flags(incdir_flag)
        vcs_flags.extend(self.get_additional_vcs_flags())
        vcs_flags_str = " ".join(vcs_flags)

        return (
            f"vcs {source_files} {vcs_flags_str} "
            f'+define+TB_FILE=\\"{os.path.basename(str(tb))}\\" '
            f"-top tb_wrapper -o {name}"
        )

    def build_vcs_sim_cmd(self, name: str, output_dir: str) -> str:
        vcs_flags = " ".join(self.get_base_sim_flags())

        plusargs = self.get_common_sim_plusargs()
        plusargs.update(self.get_additional_plusargs(output_dir))
        plusargs_str = self.format_plusargs(plusargs)

        return f"./{name} {vcs_flags} {plusargs_str}"


class GenericBuilder(BaseVCSBuilder):
    def get_source_files(self, tb: Path, output_dir: str) -> List[str]:
        return [
            *map(str, self.rtl_sources),
            *map(str, self.tb_sources["sources"]),
            os.path.join(self.env["SIM_ROOT"], "vcs", "tb_wrapper.sv"),
        ]

    def get_additional_vcs_flags(self) -> List[str]:
        self.env["ENV"]["WAIVED_MISC_IPS"] = ""
        return []

    def get_additional_plusargs(self, output_dir: str) -> Dict[str, any]:
        return {}


class CPUBuilder(BaseVCSBuilder):
    def get_source_files(self, tb: Path, output_dir: str) -> List[str]:
        return [
            *map(str, self.rtl_sources),
            *map(str, self.tb_sources["sources"]),
            os.path.join(output_dir, "rvfimon.v"),
            self.env["TOOL_CONFIG"]["shared_libs"]["SPIKE_SO"],
            os.path.join(self.env["SIM_ROOT"], "vcs", "tb_wrapper.sv"),
        ]

    def get_additional_vcs_flags(self) -> List[str]:
        self.env["ENV"]["WAIVED_MISC_IPS"] = ""
        return [
            "-LDFLAGS -Wl,-rpath,/software/gcc-12.3.0/lib64",
            "-LDFLAGS -L/software/gcc-12.3.0/lib64",
        ]

    def get_additional_plusargs(self, output_dir: str) -> Dict[str, any]:
        return {
            "PROGRAM_ELF": os.path.join(output_dir, "program.elf"),
            "COMMIT_LOG_FREQUENCY": self.env["SIM_CFG"]["commit_log_frequency"],
            "PROGRAM_HEX": os.path.join(output_dir, "program.hex"),
        }

    def build_vcs_elab_cmd(self, name: str, tb: Path, output_dir: str) -> str:
        incdir_flag = self.get_include_dirs_flag(tb)
        source_files = " ".join(self.get_source_files(tb, output_dir))

        vcs_flags = self.get_base_vcs_flags(incdir_flag)
        vcs_flags.extend(self.get_additional_vcs_flags())
        vcs_flags_str = " ".join(vcs_flags)

        self.env["ENV"]["WAIVED_MISC_IPS"] = os.path.join(output_dir, "rvfimon.v")

        return (
            f"vcs {source_files} {vcs_flags_str} "
            f'+define+TB_FILE=\\"{os.path.basename(str(tb))}\\" '
            f'+define+RVFI_REFERENCE_FILE=\\"{os.path.join(output_dir, "rvfi_reference.sv")}\\" '
            f"-top tb_wrapper -o {name}"
        )


BUILDER_REGISTRY = {
    "generic": GenericBuilder,
    "cpu": CPUBuilder,
}


def get_builder(builder_type: str, **kwargs) -> BaseVCSBuilder:
    if builder_type not in BUILDER_REGISTRY:
        available = ", ".join(BUILDER_REGISTRY.keys())
        raise ValueError(
            f"Unknown builder type '{builder_type}'. "
            f"Available builders: {available}"
        )

    builder_class = BUILDER_REGISTRY[builder_type]
    return builder_class(**kwargs)
