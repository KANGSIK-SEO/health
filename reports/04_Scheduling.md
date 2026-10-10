# [Analysis] (보너스) 로그 패턴 분석을 통한 스케줄링 알고리즘 추론

> 증거: [`evidence/deadlock_after_app.log`](../evidence/deadlock_after_app.log) (정상 동작 구간), [`evidence/deadlock_app.log`](../evidence/deadlock_app.log) (멀티스레드 구간)

## 1. 로그 관찰 개요
`agent-leak-app` 의 정상 실행 구간에서 여러 작업 단위(CpuWorker, MemoryWorker, Worker-Thread)가 남기는 타임스탬프 로그를 수집해, 런타임/OS가 작업을 교체하는 방식을 역추적했다.

## 2. 증거 자료
단일 작업이 끝나기 전에 다른 작업 로그가 **짧은 간격으로 번갈아** 끼어드는 현상이 관측됨 (`deadlock_after_app.log`):
```
21:36:34.x [CpuWorker]    Current Load: 5.00%
21:36:36.x [CpuWorker]    Peak reached (10.00%). Starting cooldown...
21:36:36.x [MemoryWorker] Current Heap: 100MB      ← CpuWorker 끝나기 전에 MemoryWorker 끼어듦
21:36:37.x [CpuWorker]    Current Load: 10.00%     ← 다시 CpuWorker 로 전환
21:36:40.x [MemoryWorker] Current Heap: 125MB      ← 다시 MemoryWorker
```
멀티스레드 구간(`deadlock_app.log`)에서도 Worker-Thread-1 과 Worker-Thread-2 가 거의 동시에 시작해 번갈아 진행하는 모습이 보인다.

## 3. 패턴 분석 및 결론
- **순차 처리(FCFS) 아님**: CpuWorker 가 자기 작업을 끝까지 마치기 전에 MemoryWorker 로그가 끼어들었다. 먼저 온 작업을 끝까지 처리하는 FCFS 였다면 이런 교차가 없어야 한다.
- **우선순위(Priority) 아님**: 특정 워커가 CPU 를 독점하거나 다른 워커를 굶기지(starvation) 않고, CpuWorker ↔ MemoryWorker 가 **대등하게 번갈아** 가며 진행한다.
- **최종 결론**: 각 작업이 **짧은 시간 할당량(time slice)만큼 실행된 뒤 다음 작업으로 교체**되는 **라운드 로빈(Round-Robin)** 방식으로 추론된다. (리눅스 CFS/타임슬라이스 기반 선점형 스케줄링, 또는 Python 런타임의 주기적 스레드 전환과 일치하는 패턴)

## 4. 장단점 및 적합 아키텍처
| | 내용 |
|---|---|
| **장점** | 모든 작업이 공평하게 CPU 를 나눠 받음 → 특정 작업의 독점·기아(starvation) 방지, 응답성 균일 |
| **단점** | 잦은 문맥 교환(context switch) 오버헤드, 작업별 중요도 반영 불가(긴급 작업도 똑같이 대기) |
| **적합** | **실시간 응답이 중요한 서비스**(웹 서버·대화형 챗봇 등) — 모든 요청이 고르게 빨리 반응해야 하는 경우 |
| **부적합** | 처리량이 최우선인 **배치 작업** — 이땐 문맥 교환을 줄이는 FCFS/배치 스케줄이 유리 |

> 주의: 본 추론은 **외부에서 관측한 로그 타임스탬프 패턴**에 근거한 것으로, 바이너리 내부 구현을 역공학하지 않았다(미션 제약 준수). 관측 사실(작업 교차·공평 분배)로부터의 논리적 추론이다.
