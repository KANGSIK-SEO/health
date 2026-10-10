# health — 시스템 장애 분석 미션 (Linux & OS)

> **컴퓨터가 갑자기 느려지거나 멈췄을 때 원인 찾아 고치기**
> `agent-leak-app`(Python 기반 리눅스 바이너리)을 운영 환경에서 실행하며 발생하는
> 3대 시스템 장애(**Memory Leak/OOM · CPU Spike · Deadlock**)를 관제 데이터와 로그로
> 추론하고, GitHub Issue 형식 기술 리포트로 남긴 결과물.

## 📋 제출 리포트 (3건)
| # | 장애 | 리포트 | 한 줄 결론 |
|---|------|--------|-----------|
| 1 | **OOM Crash** | [reports/01_OOM.md](reports/01_OOM.md) | 메모리 누수 → MemoryGuard 자가 종료 |
| 2 | **CPU Latency** | [reports/02_CPU.md](reports/02_CPU.md) | CPU 부하 안전 임계치 초과 → 과점유 방지 종료 |
| 3 | **Deadlock** | [reports/03_Deadlock.md](reports/03_Deadlock.md) | 두 스레드 순환 대기 → 무응답(PID 생존) |

(선택) 보너스: [reports/04_Scheduling.md](reports/04_Scheduling.md) — 스케줄링 알고리즘 추론

## 🖥️ 실행 환경
- OS: Ubuntu 24.04.5 LTS (x86_64), macOS 위 Lima VM(Apple Virtualization)에서 격리 실행
- 실행 계정: `kangsikseoul0852` (uid 1267600599, **root 아님**)
- 바이너리: `agent-leak-app-x86`
- 관제: [`monitor.sh`](monitor.sh), `ps`, `top`, `pstree`, `ps -L`, `/proc/<tid>/wchan`

## ⚙️ 부트 조건 (모두 충족해야 기동)
| 항목 | 설정 |
|------|------|
| 실행 계정 | non-root |
| AGENT_HOME | `~/agent` |
| AGENT_PORT | 15034 (고정) |
| AGENT_UPLOAD_DIR | `$AGENT_HOME/upload_files` (존재) |
| AGENT_KEY_PATH | `$AGENT_HOME/api_keys` (존재) |
| AGENT_LOG_DIR | `$AGENT_HOME/logs` (쓰기 가능) |
| secret.key | `$AGENT_HOME/api_keys/secret.key` = `agent_api_key_test` |
| 네트워크 | `0.0.0.0:15034` 바인딩 |

## 🔁 재현 방법
```bash
cd "$AGENT_HOME"
source ~/.agent_env

# 1) OOM  — 메모리 심지를 짧게
export MEMORY_LIMIT=50  CPU_MAX_OCCUPY=100 MULTI_THREAD_ENABLE=false
./agent-leak-app

# 2) CPU  — 부하 상한을 안전선(50%) 위로
export MEMORY_LIMIT=512 CPU_MAX_OCCUPY=95  MULTI_THREAD_ENABLE=false
./agent-leak-app

# 3) Deadlock — 멀티스레드 ON (무응답 → Ctrl+C)
export MEMORY_LIMIT=512 CPU_MAX_OCCUPY=10  MULTI_THREAD_ENABLE=true
./agent-leak-app
```

## 🎛️ 장애 제어 변수 한눈에
| 장애 | 변수 | Before(장애) | After(생존) |
|------|------|-------------|-------------|
| OOM | `MEMORY_LIMIT` | 50 | 512 |
| CPU | `CPU_MAX_OCCUPY` | 95 | 10 |
| Deadlock | `MULTI_THREAD_ENABLE` | true | false |

## 📂 증거 자료
`evidence/` 폴더 — 각 케이스의 실제 실행 로그·관제 수치·시스템 도구 출력.
```
evidence/
  oom_before_app.log / oom_before_monitor.log / oom_after_app.log
  cpu_before_app.log / cpu_before_monitor.log / cpu_after_app.log
  deadlock_app.log   / deadlock_diagnosis.log / deadlock_after_app.log
```

## 🎯 학습 목표 달성 요약
- 메모리 누수가 힙을 선형 증가시켜 자가 종료에 이르는 과정을 로그·수치로 입증
- 특정 프로세스의 CPU 과점유가 안전 임계치를 넘겨 보호 종료되는 원리 설명
- 교착상태를 "PID 생존 + CPU 0% + 로그 정지 + futex 대기"로 시스템 도구로 진단
- 3건을 육하원칙 기반 GitHub Issue 리포트로 작성
