import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma_litertlm/flutter_gemma_litertlm.dart';

import 'app.dart';
import 'core/config.dart';
import 'features/model/model_manager.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // flutter_gemma 코어는 엔진을 스스로 등록하지 않는다 — .litertlm 엔진 명시 등록 필수.
  FlutterGemma.initialize(
    inferenceEngines: const [LiteRtLmEngine()],
  );

  final deps = OngiDeps();
  runApp(OngiApp(deps: deps));

  // 런처 표시를 막지 않는 백그라운드 부트스트랩(§8 — 다운로드가 사용 시작을 막지 않는다):
  // RAM 게이팅 등급 산출 → 모델 설치 상태 복원. 결과는 ModelManager 리스너로 전파된다.
  unawaited(_bootstrap(deps));
}

Future<void> _bootstrap(OngiDeps deps) async {
  // 기기 인스턴스 키·역할 복원(ADR-21). 세션의 신뢰 앵커라 LLM보다 먼저 세운다.
  try {
    await deps.identity.load();
    deps.coaching.deviceKey = deps.identity.deviceKey;
    // 릴레이 주소는 전송 계층이 접속할 때 스스로 읽는다 — 여기서 구체 타입을
    // 알 필요가 없다(전송 계층을 갈아 끼워도 이 부트스트랩은 그대로다).
    unawaited(deps.guardians
        .pruneHistory(DateTime.now().millisecondsSinceEpoch)
        .catchError((_) => 0));
    final role = deps.identity.isGuardian
        ? OngiConfig.roleGuardian
        : OngiConfig.roleElder;
    if (deps.identity.isGuardian) {
      unawaited(deps.guardianMode
          .start(deviceKey: deps.identity.deviceKey)
          .catchError((_) {}));
    } else if (deps.identity.roleChosen) {
      unawaited(deps.signaling
          .connect(deviceKey: deps.identity.deviceKey, role: role)
          .catchError((_) {}));
    }
  } catch (_) {}

  // 보호자 모드는 2.6GB 모델을 받지 않는다(ADR-20).
  if (deps.identity.isGuardian) return;

  await deps.llm.init();
  await deps.model.check(deps.llm);
  if (deps.model.phase == ModelPhase.ready) {
    // 콜드 로드(수 초~수십 초)를 음성 명령 경로 밖에서 선행 —
    // 첫 LLM 라우팅이 타임아웃으로 빠지는 것을 방지(§4.2).
    unawaited(deps.llm.ensureReady());
  }
}
