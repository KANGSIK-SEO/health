#!/usr/bin/env bash
# =====================================================================
# monitor.sh — 관제(모니터링) 스크립트
# 대상 프로세스(agent-leak-app)의 CPU/메모리/디스크를 주기적으로 기록한다.
# 사용법:  ./monitor.sh [프로세스이름] [주기(초)]
#   예)   ./monitor.sh agent-leak-app 5
# 로그는 화면과 $AGENT_LOG_DIR/monitor.log 양쪽에 남는다.
# =====================================================================
PROC="${1:-agent-leak-app}"
INTERVAL="${2:-5}"
LOGDIR="${AGENT_LOG_DIR:-.}"
mkdir -p "$LOGDIR" 2>/dev/null
LOG="$LOGDIR/monitor.log"

echo "[monitor] watching '$PROC' every ${INTERVAL}s -> $LOG"
echo "[monitor] Ctrl+C 로 종료"

while true; do
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  pid=$(pgrep -f "$PROC" | head -1)
  disk=$(df -h / | awk 'NR==2{print $4}')
  fw="active"
  if [ -n "$pid" ]; then
    # %cpu = 프로세스 CPU 점유율, %mem = 물리메모리 점유율
    read -r cpu mem rss <<< "$(ps -p "$pid" -o %cpu=,%mem=,rss=)"
    rss_mb=$(( ${rss:-0} / 1024 ))
    line="[$ts] PROCESS:$PROC PID:$pid CPU:${cpu}% MEM:${mem}% RSS:${rss_mb}MB DISK:${disk} FIREWALL:${fw}"
  else
    line="[$ts] PROCESS:$PROC STATE:DOWN (프로세스 없음 - 종료되었거나 미실행) DISK:${disk} FIREWALL:${fw}"
  fi
  echo "$line" | tee -a "$LOG"
  sleep "$INTERVAL"
done
