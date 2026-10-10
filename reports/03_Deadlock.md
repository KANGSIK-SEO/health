# [Bug] Deadlock - 멀티스레드 순환 대기로 프로세스 무응답 (PID 생존·CPU 0%·로그 정지)

> 환경: Ubuntu 24.04.5 LTS (x86_64) / 실행계정 `kangsikseoul0852`(non-root) / `agent-leak-app`
> 재현 설정: `MULTI_THREAD_ENABLE=true` (MEMORY_LIMIT=512, CPU_MAX_OCCUPY=10)
> 증거 파일: [`evidence/deadlock_app.log`](../evidence/deadlock_app.log), [`evidence/deadlock_diagnosis.log`](../evidence/deadlock_diagnosis.log), [`evidence/deadlock_after_app.log`](../evidence/deadlock_after_app.log)

## 1. Description (현상 설명)
- **무엇이**: 실행 후 프로세스가 **종료되지 않고 PID가 유지**되나, CPU/메모리 변화가 없고 로그 출력이 완전히 멈춘 **무응답(hang)** 상태가 지속됨.
- **언제/조건**: `MULTI_THREAD_ENABLE=true` 로 동시성(멀티스레드) 모드일 때. 두 워커 스레드가 서로 다른 자원을 잡은 채 상대 자원을 요구하는 순간 교착.
- OOM/CPU 케이스와 달리 **자동 종료되지 않는다** — 이것이 데드락의 핵심 특징(로그가 "멈춤" = 이벤트의 부재).

## 2. Evidence & Logs (증거 자료)

**① 프로그램 로그 — 마지막 기록이 BLOCKED 에서 정지** (`deadlock_app.log`)
```
[Worker-Thread-1] LOCK ACQUIRED: [Shared_Memory_A]. (Holding...)
[Worker-Thread-2] LOCK ACQUIRED: [Socket_Pool_B]. (Holding...)
[Worker-Thread-1] Need resource [Socket_Pool_B] to finish job.
[Worker-Thread-1] WAITING for [Socket_Pool_B]... (Status: BLOCKED)
[Worker-Thread-2] Need resource [Shared_Memory_A] to write logs.
[Worker-Thread-2] WAITING for [Shared_Memory_A]... (Status: BLOCKED)
   ← 이후 로그 완전 정지
```

**② PID 존재 증거** (`ps -ef | grep agent-leak-app`)
```
kangsik+  5572  5329  0 21:36 ?  00:00:00 .../agent-leak-app   (메인)
kangsik+  5574  5572  0 21:36 ?  00:00:00 .../agent-leak-app   (워커, 스레드 보유)
STAT S   ELAPSED 00:15   %CPU 0.3   %MEM 0.0   ← 15초째 생존하나 거의 0%
```

**③ 스레드별 상태 — 워커 스레드 전부 `futex_wait_queue`** (`ps -L` / `/proc/<tid>/wchan`)
```
 PID    TID   STAT  WCHAN               %CPU
 5572   5572  S     do_wait             0.3   (메인: 워커 종료를 기다림)
 5574   5574  SNl   futex_wait_queue    0.2   (워커 메인)
 5574   5582  SNl   futex_wait_queue    0.0   ← Worker-Thread-1
 5574   5583  SNl   futex_wait_queue    0.0   ← Worker-Thread-2
```
→ 워커의 세 스레드가 모두 `futex_wait_queue`(커널이 뮤텍스 락을 기다리며 재운 상태), CPU 0%. **아무도 진행하지 못함 = 교착의 커널 레벨 증거.**

## 3. Root Cause Analysis (원인 분석)
- **순환 자원 대기(Circular Wait)**:
  - `Worker-Thread-1` : `Shared_Memory_A` 획득 → `Socket_Pool_B` 요구하며 대기
  - `Worker-Thread-2` : `Socket_Pool_B` 획득 → `Shared_Memory_A` 요구하며 대기
  - 서로 상대가 쥔 자원을 무한히 기다림 → 영원히 풀리지 않음.
- **교착상태 4대 조건 충족** (식사하는 철학자 문제와 동형):
  1. **상호 배제(Mutual Exclusion)** — 각 락(A, B)은 한 번에 한 스레드만 점유.
  2. **점유 대기(Hold and Wait)** — 자기 락을 쥔 채 상대 락을 기다림.
  3. **비선점(No Preemption)** — 쥔 락을 강제로 빼앗을 수 없음.
  4. **순환 대기(Circular Wait)** — T1→B(T2 보유), T2→A(T1 보유)의 사이클.
- **OS 관점**: 두 스레드가 `futex`(fast userspace mutex) 대기 큐에서 깨어나지 못하므로 스케줄러가 실행 큐에 올리지 않음 → CPU 0%, 상태 `S`(sleep). 프로세스는 살아있으나 일을 못 하는 "좀비성 hang".

## 4. Workaround & Verification (조치 및 검증)
- **임시 조치**: 동시성을 끄면 락 경쟁 자체가 사라진다.
  ```bash
  export MULTI_THREAD_ENABLE=false
  ./agent-leak-app
  ```
- **Before & After 검증**

  | 구분 | MULTI_THREAD_ENABLE | 결과 |
  |------|--------------------|------|
  | Before | true  | Worker-Thread-1/2 BLOCKED 교착 → 무응답(PID 생존·CPU 0%) |
  | After  | false | 동시성 비활성 → **정상 동작** (단일 흐름으로 CpuWorker·MemoryWorker 처리, 교착 없음) |

  After 로그 근거 (`deadlock_after_app.log`): 교착 없이 정상 진행
  ```
  [CpuWorker] Current Load: 5.00% → Peak reached (10.00%). Starting cooldown...
  [MemoryWorker] Current Heap: 100MB → 125MB
  (BLOCKED 없이 계속 동작, 프로세스 생존)
  ```
- **멈춘 프로세스 종료법**: 실행 터미널에서 `Ctrl + C`, 또는 `pkill -x agent-leak-app`.
- **근본 해결 제안(선택)**: 동시성을 유지해야 한다면 ① **락 획득 순서를 전역 통일**(항상 A→B 순서로만)하여 순환 대기 조건 제거, ② `try-lock + 타임아웃` 후 전체 롤백/재시도, ③ 두 자원을 하나의 락으로 묶기(lock hierarchy). 감시 측면에선 **PID 생존이 아닌 "진척 로그가 멈췄는지(liveness)"로 헬스체크**해야 데드락을 놓치지 않는다.
