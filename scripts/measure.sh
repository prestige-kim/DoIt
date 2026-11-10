#!/bin/zsh
# DoIt 장시간 사용 점검 (T-008): 지금 DoIt의 메모리·CPU를 1번 재서 한 줄로 보여 주고 기록 파일에 덧붙인다.
# 반복 측정은 하지 않는다. 시작 직후, 30분 뒤, 몇 시간 뒤처럼 필요할 때 직접 다시 실행한다.
#
# 사용법: scripts/measure.sh [메모]     예) scripts/measure.sh "시작 직후"  /  scripts/measure.sh "30분 뒤, 접힌 채"
# 기록 파일: build/logs/measure.log
#
# 각 값의 뜻
# - 메모리(footprint): 활동 모니터의 '메모리'와 같은 기준 (phys_footprint)
# - RSS: 실제로 올라와 있는 메모리 (참고용)
# - CPU(지금): 10초 동안 잰 평균 CPU % (top 두 번째 표본). 접힌 채 가만히 두면 0.5% 이하여야 한다 (PRD)
# - CPU 누적 시간: 실행 뒤 지금까지 쓴 CPU 시간. 두 번 잰 값의 차이 ÷ 그 사이 시간 = 그동안의 평균 CPU
set -euo pipefail
cd "$(dirname "$0")/.."

note="${1:-}"
# 가장 오래 실행 중인 DoIt (테스트가 잠깐 띄운 DoIt은 제외되도록)
pid=$(pgrep -o -x DoIt || true)
if [[ -z "$pid" ]]; then
  echo "DoIt이 실행 중이 아니에요."
  exit 1
fi

footprint_mb=$(footprint -p "$pid" 2>/dev/null | awk '/phys_footprint:/ {print $2, $3; exit}')
rss_mb=$(ps -o rss= -p "$pid" | awk '{printf "%.1f MB", $1/1024}')
elapsed=$(ps -o etime= -p "$pid" | tr -d ' ')
cputime=$(ps -o time= -p "$pid" | tr -d ' ')
# top: 10초 간격 표본 2개 중 두 번째가 그 10초 동안의 CPU %
cpu_now=$(top -l 2 -s 10 -pid "$pid" -stats cpu | tail -1 | tr -d ' ')

line="$(date '+%Y-%m-%d %H:%M:%S') | pid ${pid} | 실행 ${elapsed} | 메모리(footprint) ${footprint_mb:-?} | RSS ${rss_mb} | CPU(지금 10초) ${cpu_now}% | CPU 누적 ${cputime}${note:+ | ${note}}"
mkdir -p build/logs
echo "$line" | tee -a build/logs/measure.log
