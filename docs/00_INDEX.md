# 온기(ONGI) 문서 인덱스

| 문서 | 내용 |
|---|---|
| [../README.md](../README.md) | 개요·저장소 구조·릴레이 실행/테스트·**릴레이 접속 정책(주소를 넣은 기기만 붙는다 — v0.0.25에서 해소)**·제출 전 체크리스트·Changelog |
| [../app/README.md](../app/README.md) | 앱 빌드·실행 정본 (pigeon·analyze/test·release APK) |
| [10_product_design.md](10_product_design.md) | **기획설계서** — 투트랙 전략·플랫폼 매트릭스·아키텍처·정책·리스크·마일스톤·ADR |
| [20_w1_spike.md](20_w1_spike.md) | W1 스파이크 실기기 측정 가이드 (계측 APK 사용법 + 결과 기록란) |
| [40_senior_uiux_design.md](40_senior_uiux_design.md) | **시니어 UI/UX 기획·설계 초안** — 설계 원칙 10 + 화면별 점검·백로그 |
| [41_web_launcher_ux_checklist.md](41_web_launcher_ux_checklist.md) | **[보류]** 어르신 사용성 체크리스트 (폐기된 웹 런처안 P0/P1/P2 24건) — 옛 `pjt/ongi2`에서 이관. 접근성 수치·롱프레스 금지 등 일부는 Android에도 유효 |
| [50_guardian_coaching.md](50_guardian_coaching.md) | **보호자 통화 코칭 기획·설계 (v1.2)** — 어르신 1탭 개시 · 통화 + 보기 전용 화면 공유 · 민감 화면 3단 정책 · 쓰기 경로 0 원칙 · Play/법률 근거. **코드는 구현돼 있으나 대회 출품 범위 밖**(§14에 미결·실기기 검증 항목) |
| [../server/](../server/) | 코칭 시그널링 릴레이(FastAPI WebSocket) — 전달만 하고 저장 0. 라우팅·세션 불변식 회귀 테스트 `server/test_relay.py` |
| [../ONGI_PROJECT_BRIEF.MD](../ONGI_PROJECT_BRIEF.MD) | 프로젝트 브리프 (개발 목적·소개·기대효과) |

> 대회 결과보고서(원고·HWP/DOCX)와 운영규정 PDF는 제출용 산출물·제3자 저작물이라 이 저장소에는 포함하지 않는다.

## 대회 핵심 일정·요건

- 제출: ~2026-08-27(목) 18:00, osscontest.kr — 보고서(HWP/HWPX 또는 DOC/DOCX) + PDF 변환본, 총 2개 파일
- 보고서 5페이지 이내(붙임 제한 없음), 맑은고딕 10pt, 용지 여백 변경 금지
- 소스코드 GitHub 공개 + OSI 라이선스(MIT), AI 모델은 오픈웨이트 이상 + 로컬 구동
