#!/usr/bin/env bash
#
# Copyright 2025-2026 the original author or authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

set -euo pipefail

# Run with the same JDK for both revisions. Each directory contains graph.jar and react.jar
# built from agentic-spring-ai-benchmark commit 8831f26d7812838eed78b5d0bca3093ef5dba049.
if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "Usage: $0 <benchmark-jar-directory> <result-directory> [full|checks]" >&2
  exit 2
fi

benchmark_jars="$1"
result_directory="$2"
mode="${3:-full}"
if [[ "${mode}" != full && "${mode}" != checks ]]; then
  echo "Mode must be full or checks" >&2
  exit 2
fi
for module in graph react; do
  if [[ ! -r "${benchmark_jars}/${module}.jar" ]]; then
    echo "Missing benchmark JAR: ${benchmark_jars}/${module}.jar" >&2
    exit 2
  fi
done
mkdir -p "${result_directory}"

run_benchmark() {
  local module="$1" name="$2" include="$3"
  shift 3
  java -jar "${benchmark_jars}/${module}.jar" "${include}" \
    -jvmArgs '-Xms512m -Xmx512m' -prof gc -foe true -rf json \
    -rff "${result_directory}/${name}.json" -o "${result_directory}/${name}.log" "$@"
}

full_options=(-wi 5 -i 8 -w 1s -r 1s -f 3)
if [[ "${mode}" == full ]]; then
  run_benchmark graph graph-width '.*StateWidthGraphBenchmark.invoke$' \
    -p nodeCount=20 -p stateKeys=1,50 "${full_options[@]}"
  run_benchmark react react-history '.*ReactHistoryBenchmark.call$' \
    -p historyPairs=0,25 "${full_options[@]}"
fi
run_benchmark react react-throughput '.*ReactThroughputBenchmark.threads8$' "${full_options[@]}"

# Short controls detect gross regressions; do not use them for precise latency claims.
control_options=(-wi 2 -i 3 -w 500ms -r 500ms -f 1)
run_benchmark graph sequential '.*SequentialGraphBenchmark.invoke$' -p nodeCount=10 "${control_options[@]}"
run_benchmark graph loop '.*ConditionalLoopGraphBenchmark.invoke$' -p iterations=100 "${control_options[@]}"
run_benchmark graph parallel '.*ParallelGraphBenchmark.invoke$' -p branches=8 "${control_options[@]}"
run_benchmark graph checkpoint '.*CheckpointGraphBenchmark.invokeWithMemorySaver$' "${control_options[@]}"
