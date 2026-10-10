# [Bug] CPU - CPU 부하가 안전 임계치(≈50%) 초과, 과점유 방지 정책에 의한 종료

> 환경: Ubuntu 24.04.5 LTS (x86_64) / 실행계정 `kangsikseoul0852`(non-root) / `agent-leak-app`
> 재현 설정: `CPU_MAX_OCCUPY=95` (MEMORY_LIMIT=512, MULTI_THREAD_ENABLE=false)
> 증거 파일: [`evidence/cpu_before_app.log`](../evidence/cpu_before_app.log), [`evidence/cpu_load_resource.log`](../evidence/cpu_load_resource.log), [`evidence/cpu_after_app.log`](../evidence/cpu_after_app.log)

## 1. Description (현상 설명)
- **무엇이**: 실행 후 특정 프로세스(agent-leak-app)의 CPU 부하가 점진적으로 상승하다가 프로세스가 종료됨.
- **언제/조건**: `CPU_MAX_OCCUPY=95(%)` 로 실행 시, 기동 약 **20~30초** 후 부하가 **안전 임계치(약 50%)를 넘는 순간** `CPU Threshold Violated!` 와 함께 종료.
- 시스템 전체 부하가 아니라 **해당 프로세스 단독**의 과점유가 원인.

## 2. Evidence & Logs (증거 자료)

**① CPU 부하 상승 추이 — 종료까지** (`evidence/cpu_before_app.log`)
```
2026-10-10 21:35:16,316 [INFO]     [CpuWorker] Current Load: 11.61%
2026-10-10 21:35:22,549 [INFO]     [CpuWorker] Current Load: 22.77%
2026-10-10 21:35:28,781 [INFO]     [CpuWorker] Current Load: 33.21%
2026-10-10 21:35:31,898 [INFO]     [CpuWorker] Current Load: 42.31%
2026-10-10 21:35:35,013 [INFO]     [CpuWorker] Current Load: 51.42%
2026-10-10 21:35:35,114 [CRITICAL] [CpuWorker] CPU Threshold Violated! (51.42%).
```

**② 관제(top/ps) 출력 — OS 레벨 실제 CPU는 낮게 유지** (`evidence/cpu_load_resource.log`, 모든 agent-leak-app 프로세스 합산)
```
[21:47:30] agent-leak-app(합산) CPU:0.0% RSS:19MB
[21:47:45] agent-leak-app(합산) CPU:1.5% RSS:19MB
[21:48:03] agent-leak-app(합산) CPU:2.5% RSS:19MB
```
> **중요 관찰**: `top`/`ps` 로 측정한 **실제 OS CPU 점유율은 1~2%대에 머문다.** 반면 앱 로그의 `Current Load` 는 51%까지 오른다. 즉 이 앱의 CpuWorker 는 실제로 CPU 를 태우기보다 **내부 부하 지표(`Current Load`)를 시뮬레이션**하고, 과점유 방지 정책(Watchdog)은 **그 내부 지표**를 기준으로 종료 판단을 한다. 따라서 이 장애의 **직접 증거는 앱의 `Current Load` 로그**이며, `top` 은 "범인이 OS 레벨에서 CPU 를 독점한 게 아니라 앱 자체 정책이 발동했다"는 사실을 보여 준다(교차 검증).

## 3. Root Cause Analysis (원인 분석)
- **현상 분석**: `CpuWorker` 가 작업 부하를 점진적으로(11% → 51%) 끌어올림. 목표치는 `CPU_MAX_OCCUPY=95%`.
- **과점유 방지 정책 동작 원리**: 앱에는 **고정 안전 임계치(약 50%)**가 존재. 프로세스 부하가 이 선을 넘자(51.42%) 보호 정책이 `CPU Threshold Violated!` 를 내고 프로세스를 종료. 특정 프로세스의 CPU 독점이 시스템 전체 지연(다른 프로세스의 스케줄링 지연)을 유발하는 것을 막기 위한 **선제적 보호 조치**이며 오류가 아님.
- 즉 `CPU_MAX_OCCUPY` 를 안전 임계치(50%)보다 높게 둘수록 부하가 그 선을 넘겨 종료가 유발됨.

## 4. Workaround & Verification (조치 및 검증)
- **임시 조치**: `CPU_MAX_OCCUPY` 를 안전선 아래(`10%`)로 낮춰 과점유 자체가 발생하지 않게 함.
  ```bash
  export CPU_MAX_OCCUPY=10
  ./agent-leak-app
  ```
- **Before & After 검증**

  | 구분 | CPU_MAX_OCCUPY | 결과 |
  |------|---------------|------|
  | Before | 95% | 부하 51.42% 로 50% 돌파 → `CPU Threshold Violated!` 종료 (`cpu_before_app.log`) |
  | After  | 10% | 부하가 10% 상한에 묶여 임계치 미도달 → **생존 지속** (`cpu_after_app.log`) |

- **근본 해결 제안(선택)**: 상한을 낮추면 처리량이 희생됨. 근본적으로는 CpuWorker 작업을 분할/비동기화하거나 CPU 집약 로직을 최적화해 안전 임계치 내에서 처리량을 확보해야 함.
