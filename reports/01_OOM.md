# [Bug] OOM - 메모리 누수로 힙이 임계치 도달, MemoryGuard 정책에 의한 자가 종료

> 환경: Ubuntu 24.04.5 LTS (x86_64) / 실행계정 `kangsikseoul0852`(non-root) / `agent-leak-app`
> 재현 설정: `MEMORY_LIMIT=50` (CPU_MAX_OCCUPY=100, MULTI_THREAD_ENABLE=false)
> 증거 파일: [`evidence/oom_before_app.log`](../evidence/oom_before_app.log), [`evidence/oom_mem_resource.log`](../evidence/oom_mem_resource.log), [`evidence/oom_after_app.log`](../evidence/oom_after_app.log)

## 1. Description (현상 설명)
- **무엇이**: 실행 후 물리 메모리(힙) 사용량이 시간에 따라 계속 증가하다가 프로세스가 예고 없이 종료됨.
- **언제/조건**: `MEMORY_LIMIT=50(MB)` 로 실행 시, 기동 약 **3~5초** 후 힙이 한계(50MB)에 도달하는 순간 자가 종료.
- 크래시가 아니라 애플리케이션 내부 **메모리 보호 정책(MemoryGuard)**에 의한 강제 종료로 반복 재현됨.

## 2. Evidence & Logs (증거 자료)

**① 관제(RSS 합산) 수치 — 실제 메모리 상승 확인** (`evidence/oom_mem_resource.log`, 모든 agent-leak-app 프로세스 RSS 합산)
```
[21:47:23] agent-leak-app(합산) CPU:1.0% RSS:44MB   ← 종료 직전 실제 RSS 44MB (한계 50MB 근접)
```
> CPU 케이스와 달리 **메모리는 OS 레벨에서도 실제로 증가**한다(RSS 44MB). OOM 은 "진짜" 자원 소모 장애임. (실행이 ~5초로 짧아 샘플이 1건)

가장 직접적인 상승 근거는 앱 로그의 Heap 수치가 선형 증가하는 것:
```
2026-10-10 21:34:38,024 [INFO]     [MemoryWorker] Current Heap: 25MB
2026-10-10 21:34:41,052 [INFO]     [MemoryWorker] Current Heap: 50MB   ← 한계 도달
```

**② 프로그램 실행 로그 — 종료 직전/직후 핵심 구간** (`evidence/oom_before_app.log`)
```
[6/6] ... MEMORY_LIMIT=50MB, CPU_MAX_OCCUPY=100%, MULTI_THREAD_ENABLE=False
2026-10-10 21:34:38,024 [INFO]     [MemoryWorker] Current Heap: 25MB
2026-10-10 21:34:41,052 [INFO]     [MemoryWorker] Current Heap: 50MB
2026-10-10 21:34:41,053 [CRITICAL] [MemoryGuard] Memory limit exceeded (50MB >= 50MB) / (Recommend Over 256MB)
2026-10-10 21:34:41,053 [CRITICAL] [MemoryGuard] Self-terminating process 5340 to prevent system instability.
```

## 3. Root Cause Analysis (원인 분석)
- **현상 분석**: `MemoryWorker`가 만든 데이터를 힙에서 해제하지 않고 계속 적재하는 **메모리 누수(Memory Leak)** 패턴. 힙이 25MB→50MB로 **선형 증가**(줄지 않음)함이 로그로 확인됨.
- **OS/시스템 동작**: 프로세스 메모리 사용량이 설정 임계치(`MEMORY_LIMIT`)에 도달하자, 앱 내부 **MemoryGuard**가 시스템 전체 불안정(커널 OOM Killer가 임의 프로세스를 죽이는 상황 등)을 예방하기 위해 **자기 자신을 선제적으로 종료**함.
- 참고: 리눅스 커널에도 전역 OOM Killer가 있으나(그 경우 `dmesg`에 `Out of memory: Killed process` 기록), 본 사례는 그보다 먼저 **앱 자체 가드**가 동작한 것. `[CRITICAL] [MemoryGuard]` 두 줄이 종료 주체·사유를 명확히 보여줌.

## 4. Workaround & Verification (조치 및 검증)
- **임시 조치**: `MEMORY_LIMIT` 을 `50` → `512(MB)` 로 상향해 가용 메모리 확보.
  ```bash
  export MEMORY_LIMIT=512
  ./agent-leak-app
  ```
- **Before & After 검증** (2회 실행 비교)

  | 구분 | MEMORY_LIMIT | 결과 |
  |------|-------------|------|
  | Before | 50MB | 기동 ~3~5초 후 `Self-terminating` 으로 종료 (`oom_before_app.log`) |
  | After  | 512MB | 같은 구간(5초)을 넘겨 **28초+ 생존, MemoryGuard 종료 없음** (`oom_after_app.log`) |

- **근본 해결 제안(선택)**: 임계치 상향은 임시방편. 소스에서 누적 데이터를 주기적으로 해제(`del`/`pop`/캐시 TTL)하도록 리팩토링해야 재발 방지. 감시 측면에선 RSS 증가 추세에 경보를 걸면 종료 전 선제 대응 가능.
