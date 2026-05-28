#!/bin/bash

TEST_NAME=$(basename $0)
PWD=$(realpath .)

cat >${PWD}/external/verilator/verilator <<EOF
#!/bin/bash

export VERILATOR_PYTHON3=\`which python3\`
export VERILATOR_AR=\`which ar\`
export VERILATOR_CXX=\`which g++\`
export VERILATOR_ROOT=${PWD}/external/verilator

args=()
while [[ \${#} -gt 0 ]]; do
  if [[ "\${1}" == "-j" ]]; then
    args+=("-j" "1")
    shift 2
  elif [[ "\${1}" =~ ^-j[0-9]+\$ ]]; then
    args+=("-j1")
    shift
  else
    args+=("\${1}")
    shift
  fi
done

${PWD}/external/verilator/verilator_bin \\
    "\${args[@]}"
EOF
chmod +x ${PWD}/external/verilator/verilator

export PATH=${PWD}/external/verilator:$PATH
export CHISEL_FIRTOOL_PATH=third_party/llvm-firtool
SCALATEST_BIN=$(find . -name ${TEST_NAME}_scalatest)
${SCALATEST_BIN}