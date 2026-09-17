#!/usr/bin/env bash
set -euo pipefail
[[ $# == 4 ]] || exit 2
begin=$1 end=$2 blockfile=$3 target=$4
in_block=0 printed=0
while IFS= read -r line || [[ -n $line ]]; do
  if [[ $line == "$begin" ]]; then
    in_block=1
    printf '%s\n' "$begin"
    if [[ $printed == 0 ]]; then
      while IFS= read -r body || [[ -n $body ]]; do printf '%s\n' "$body"; done <"$blockfile"
      printed=1
    fi
    printf '%s\n' "$end"
  elif [[ $line == "$end" ]]; then
    in_block=0
  elif [[ $in_block == 0 ]]; then
    printf '%s\n' "$line"
  fi
done <"$target"
