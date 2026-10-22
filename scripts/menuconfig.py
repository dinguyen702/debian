#!/usr/bin/env python3
"""Minimal Kconfig front end for the Agilex 5 Debian SD image builder."""

from __future__ import annotations

import argparse
import os
import re
import shutil
import sys
from dataclasses import dataclass, field


@dataclass
class Symbol:
    name: str
    type: str
    prompt: str = ""
    default: str = ""
    depends: str | None = None
    help: str = ""


@dataclass
class Menu:
    title: str
    items: list[Symbol] = field(default_factory=list)


@dataclass
class Tree:
    title: str = ""
    menus: list[Menu] = field(default_factory=list)
    symbols: list[Symbol] = field(default_factory=list)


def parse_kconfig(path: str) -> Tree:
    tree = Tree()
    current: Menu | None = None
    symbol: Symbol | None = None
    in_help = False
    help_lines: list[str] = []

    def finish_symbol() -> None:
        nonlocal symbol, in_help, help_lines
        if symbol is None:
            return
        if help_lines:
            symbol.help = "\n".join(help_lines).strip()
        if current is not None:
            current.items.append(symbol)
        tree.symbols.append(symbol)
        symbol = None
        in_help = False
        help_lines = []

    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.rstrip("\n")
            stripped = line.strip()

            if in_help:
                if stripped == "":
                    help_lines.append("")
                    continue
                indent = len(line) - len(line.lstrip(" \t"))
                if indent >= 1 and not stripped.startswith(
                    ("config ", "menu ", "endmenu", "mainmenu ")
                ):
                    help_lines.append(stripped)
                    continue
                finish_symbol()

            if stripped == "" or stripped.startswith("#"):
                continue
            if stripped.startswith("mainmenu "):
                tree.title = stripped.split('"')[1]
                continue
            if stripped.startswith("menu "):
                finish_symbol()
                current = Menu(title=stripped.split('"')[1])
                tree.menus.append(current)
                continue
            if stripped == "endmenu":
                finish_symbol()
                current = None
                continue
            if stripped.startswith("config "):
                finish_symbol()
                symbol = Symbol(name=stripped.split()[1], type="")
                continue
            if symbol is None:
                continue
            if stripped.startswith("string "):
                symbol.type = "string"
                if '"' in stripped:
                    symbol.prompt = stripped.split('"')[1]
            elif stripped.startswith("bool "):
                symbol.type = "bool"
                if '"' in stripped:
                    symbol.prompt = stripped.split('"')[1]
            elif stripped.startswith("default "):
                rest = stripped[len("default ") :].strip()
                if rest.startswith('"'):
                    symbol.default = rest.split('"')[1]
                else:
                    symbol.default = rest.split()[0]
            elif stripped.startswith("depends on "):
                symbol.depends = stripped[len("depends on ") :].strip()
            elif stripped == "help":
                in_help = True
                help_lines = []

    finish_symbol()
    return tree


def load_config(path: str) -> dict[str, str]:
    values: dict[str, str] = {}
    if not os.path.exists(path):
        return values
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            not_set = re.match(r"# CONFIG_([A-Za-z0-9_]+) is not set", line)
            if not_set:
                values[not_set.group(1)] = "n"
                continue
            if not line.startswith("CONFIG_"):
                continue
            key, _, val = line.partition("=")
            key = key[len("CONFIG_") :]
            if val.startswith('"') and val.endswith('"'):
                val = val[1:-1]
            values[key] = val
    return values


def defaults(tree: Tree) -> dict[str, str]:
    return {
        symbol.name: ("n" if symbol.type == "bool" and not symbol.default else symbol.default)
        for symbol in tree.symbols
    }


def enabled(symbol: Symbol, values: dict[str, str]) -> bool:
    if not symbol.depends:
        return True
    return values.get(symbol.depends, "n") == "y"


def write_config(path: str, tree: Tree, values: dict[str, str]) -> None:
    if os.path.exists(path):
        shutil.copy2(path, path + ".old")
    lines = [f"# {tree.title}", "#"]
    for menu in tree.menus:
        lines.append(f"#")
        lines.append(f"# {menu.title}")
        lines.append(f"#")
        for symbol in menu.items:
            if not enabled(symbol, values):
                lines.append(f"# CONFIG_{symbol.name} is not set")
                continue
            val = values.get(symbol.name, symbol.default)
            if symbol.type == "bool":
                if val == "y":
                    lines.append(f"CONFIG_{symbol.name}=y")
                else:
                    lines.append(f"# CONFIG_{symbol.name} is not set")
            else:
                lines.append(f'CONFIG_{symbol.name}="{val}"')
    with open(path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")


def show_help(symbol: Symbol) -> None:
    print()
    print(symbol.prompt or symbol.name)
    if symbol.help:
        print(symbol.help)
    else:
        print("(no help text)")
    print()
    input("Press Enter to continue ")


def edit_symbol(symbol: Symbol, values: dict[str, str]) -> None:
    current = values.get(symbol.name, symbol.default)
    print()
    print(f"{symbol.prompt} [{current}]")
    if symbol.help:
        print(symbol.help)
    if symbol.type == "bool":
        raw = input("Enable? [y/n] ").strip().lower()
        if raw in ("y", "n"):
            values[symbol.name] = raw
        elif raw == "":
            pass
        else:
            print("enter y or n")
    else:
        raw = input("New value (empty keeps current): ")
        if raw != "":
            values[symbol.name] = raw


def prompt_menu(menu: Menu, values: dict[str, str]) -> None:
    while True:
        visible = [symbol for symbol in menu.items if enabled(symbol, values)]
        print()
        print(f"=== {menu.title} ===")
        for i, symbol in enumerate(visible, 1):
            val = values.get(symbol.name, symbol.default)
            shown = val if symbol.type == "string" else val
            print(f"  {i}. {symbol.prompt} ({shown})")
        print("  ?. help for an entry")
        print("  q. back")
        choice = input("Choice: ").strip().lower()
        if choice in ("q", ""):
            return
        if choice == "?":
            which = input("Help for entry number: ").strip()
            if which.isdigit() and 1 <= int(which) <= len(visible):
                show_help(visible[int(which) - 1])
            continue
        if choice.isdigit() and 1 <= int(choice) <= len(visible):
            edit_symbol(visible[int(choice) - 1], values)


def menuconfig(tree: Tree, values: dict[str, str], config_path: str) -> int:
    while True:
        print()
        print(f"=== {tree.title} ===")
        for i, menu in enumerate(tree.menus, 1):
            print(f"  {i}. {menu.title} --->")
        print("  s. save")
        print("  q. quit without saving")
        choice = input("Choice: ").strip().lower()
        if choice == "q":
            return 0
        if choice == "s":
            write_config(config_path, tree, values)
            print(f"wrote {config_path}")
            return 0
        if choice.isdigit() and 1 <= int(choice) <= len(tree.menus):
            prompt_menu(tree.menus[int(choice) - 1], values)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kconfig", default="Kconfig")
    parser.add_argument("--config", default=".config")
    parser.add_argument(
        "--olddefconfig",
        action="store_true",
        help="write missing symbols from defaults without prompting",
    )
    args = parser.parse_args()

    tree = parse_kconfig(args.kconfig)
    values = defaults(tree)
    values.update(load_config(args.config))

    if args.olddefconfig:
        write_config(args.config, tree, values)
        print(f"wrote {args.config}")
        return 0

    if not sys.stdin.isatty():
        print("menuconfig needs a terminal; use make defconfig or make olddefconfig", file=sys.stderr)
        return 1

    return menuconfig(tree, values, args.config)


if __name__ == "__main__":
    sys.exit(main())
