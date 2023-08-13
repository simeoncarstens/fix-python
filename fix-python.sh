#!/usr/bin/env bash
set -e

# This script fix issues with Python binaries on NixOS
# Usage:
# fix-python --venv .venv --libs libs.nix

# Help
if [ "$1" = "--help" ]; then
  echo "Usage: fix-python --venv .venv --libs libs.nix"
  echo "--venv: path to Python virtual environment"
  echo "--libs: path to a Nix file which returns a list of derivations"
  echo "--gpu: enable GPU support"
  echo "--verbose: increase verbosity"
  exit 0
fi

# arguments
while [ $# -gt 0 ]; do
  case "$1" in
    --venv)
      shift
      VENV_PATH="$1"
      ;;
    --libs)
      shift
      LIBS_PATH="$1"
      ;;
    --gpu)
      enable_gpu="1"
      ;;
    --verbose)
      verbose="1"
      ;;
    *)
      echo "Unknown argument: $1"
      echo "Usage: fix-python --venv .venv --libs libs.nix"
      exit 1
      ;;
  esac
  shift
done

# check arguments
if [ -z "$VENV_PATH" ]; then
  echo "Missing argument: --venv"
  echo "Usage: fix-python --venv .venv --libs libs.nix"
  echo "or set VENV_PATH"
  exit 1
fi
if [ -z "$LIBS_PATH" ]; then
  echo "Missing argument: --libs"
  echo "Usage: fix-python --venv .venv --libs libs.nix"
  echo "or set LIBS_PATH"
  exit 1
fi

# load libs from Nix file
mkdir -p .nix/fix-python
nix build --impure --file "$LIBS_PATH" -o .nix/fix-python/result
nixos_python_nix_libs="$(nix eval --impure --expr "let pkgs = import (builtins.getFlake \"nixpkgs\") {}; in pkgs.lib.strings.makeLibraryPath (import $LIBS_PATH)" | sed 's/^"\(.*\)"$/\1/')"
if [ "$verbose" ]; then echo "nixos_python_nix_libs=$nixos_python_nix_libs"; fi
libs="$nixos_python_nix_libs"

# load libs from virtual environment
python_venv_libs=$(echo "$(find "$(realpath "$VENV_PATH")" -name '*.libs'):$(find "$(realpath "$VENV_PATH")" -name 'lib')" | tr '\n' ':')
if [ "$verbose" ]; then echo "nixos_python_venv_libs=$python_venv_libs"; fi
libs="$libs:$python_venv_libs"

# load libs from NixOS for GPU support if requested
if [ "$enable_gpu" ]; then
  nixos_gpu_libs="$(readlink /run/opengl-driver)/lib"
  if [ "$verbose" ]; then echo "nixos_gpu_libs=$nixos_gpu_libs"; fi
  libs="$libs:$nixos_gpu_libs"
fi

# put it all together
libs=$(echo "$libs" | sed 's/:\+/:/g' | sed 's/^://' | sed 's/:$//')
if [ "$verbose" ]; then echo "libs=$libs"; fi

# patch each binary file found in the virtual environment
# shellcheck disable=SC2156
binary_files=$(find "$(realpath "$VENV_PATH")" -type f -executable -exec sh -c "file -i '{}' | grep -qE 'x-(.*); charset=binary'" \; -print)
n_binary_files=$(wc -l <<< "$binary_files")
echo "Found $n_binary_files binary files"
cat <<< "$binary_files" \
  | while read -r file
    do
      echo "Patching file: $file"
      old_rpath="$(patchelf --print-rpath "$file" || true)"
      # prevent duplicates
      new_rpath="$(echo "$libs:$old_rpath"  | sed 's/:$//' | tr ':' '\n' | sort --unique | tr '\n' ':' | sed 's/^://' | sed 's/:$/\n/')"
      patchelf --set-rpath "$new_rpath" "$file" || true
      old_interpreter=$(patchelf --print-interpreter "$file" || true)
      if [ -n "$old_interpreter" ]; then
        interpreter_name="$(basename "$old_interpreter")"
        new_interpreter="$(echo "$new_rpath" | tr ':' '\n' | xargs -I {} find {} -name "$interpreter_name" | head -1)"
        patchelf --set-interpreter "$new_interpreter" "$file" || true
      fi 
      echo
    done

