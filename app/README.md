# 온기 Flutter 앱

프로젝트 개요·저장소 구조·Changelog는 [루트 README](../README.md),
제품·아키텍처 기준은 [기획설계서](../docs/10_product_design.md) 참조. 앱 빌드·실행 정본은 이 파일이다.

```bash
# 사전 준비: Flutter 3.44+ · JDK 17 · Android SDK 36
flutter pub get
dart run pigeon --input pigeons/ongi_native.dart   # 네이티브 브리지 수정 시
flutter analyze && flutter test
flutter build apk --release --target-platform android-arm64
```

보호자 코칭용 릴레이 서버는 앱 밖에 있다 — [`../server/`](../server/) 참조.
