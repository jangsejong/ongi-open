import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:path_provider/path_provider.dart';

import '../../ai/llm_runtime.dart';
import '../../core/config.dart';
import '../../core/db.dart';
import '../../native/ongi_native.g.dart';

/// 모델 수명주기 상태(기획설계서 §4.3·§8).
enum ModelPhase {
  /// 확인 중 — UI는 아무것도 띄우지 않는다.
  checking,

  /// 경량 모드 기기 — 다운로드 UI 자체를 노출하지 않는다(ADR-9).
  lightMode,

  /// 미설치 — 동의 화면 진입 가능.
  absent,

  downloading,
  verifying,
  ready,
  failed,
}

/// 실패 원인 — 화면에서 원인별 큰글씨 안내로 매핑(§8 [3]).
enum ModelFailure { storage, network, verify, unknown }

/// 모델 다운로드·검증·설치 상태 기계.
/// 완료 판정은 isModelInstalled를 믿지 않고 파일 크기 + sha256 대조(§4.3, #84).
class ModelManager extends ChangeNotifier {
  ModelManager({DeviceStatsApi? statsApi, OngiDatabase? db})
      : _stats = statsApi ?? DeviceStatsApi(),
        _db = db ?? OngiDatabase.instance;

  static const _verifiedKey = 'model_verified_sha256';

  final DeviceStatsApi _stats;
  final OngiDatabase _db;

  /// 알림 권한을 이 실행에서 이미 한 번 물었는가.
  ///
  /// Android는 두 번 거부당하면 앱에서 다시 물을 수 없다. 다운로드가 실패해
  /// 여러 번 재시도하면 그 기회를 여기서 다 써 버려, 정작 공유 중 상시 알림이
  /// 필요한 순간(보호자 등록 직후)에 남는 기회가 없다.
  bool _askedNotifications = false;

  ModelPhase phase = ModelPhase.checking;
  ModelFailure? failure;
  int progressPercent = 0;
  int elapsedSec = 0;
  Timer? _ticker;

  Future<String> _modelPath() async {
    final dir = await getApplicationDocumentsDirectory();
    return '${dir.path}/${OngiConfig.modelFileName}';
  }

  /// 앱 시작 시 1회 — 설치·검증 상태 복원.
  Future<void> check(LlmRuntime llm) async {
    if (!llm.available) {
      _set(ModelPhase.lightMode);
      return;
    }
    try {
      final file = File(await _modelPath());
      final verified = await _db.getSetting(_verifiedKey);
      if (await file.exists() &&
          await file.length() == OngiConfig.modelSizeBytes &&
          verified == OngiConfig.modelSha256) {
        if (!FlutterGemma.hasActiveModel()) {
          // 앱 데이터는 남고 flutter_gemma 등록만 사라진 경우(캐시 삭제 등) 재등록.
          await FlutterGemma.installModel(modelType: ModelType.gemma4)
              .fromFile(file.path)
              .install();
        }
        _set(ModelPhase.ready);
        return;
      }
      _set(ModelPhase.absent);
    } catch (_) {
      // 재등록·파일 확인이 던지면 phase가 checking에 영구 고착되고 아무 UI도
      // 안 뜬다 — 실패로 명시 전이해 '다시 시도' 복구 경로를 남긴다.
      failure = ModelFailure.unknown;
      _set(ModelPhase.failed);
    }
  }

  /// 다운로드 사전 체크(§4.3): 가용 저장공간 3.6GB. 결과는 화면에서 안내.
  /// 이전 실패로 남은 부분 파일은 이어받기/덮어쓰기로 재사용되는 공간이므로
  /// 필요량에서 뺀다 — 안 빼면 재시도가 매번 storage 실패로 반려된다.
  Future<bool> hasEnoughStorage() async {
    var required = OngiConfig.requiredFreeStorageBytes;
    try {
      final file = File(await _modelPath());
      if (await file.exists()) required -= await file.length();
    } catch (_) {}
    if (required <= 0) return true;
    return await _stats.getFreeStorageBytes() >= required;
  }

  Future<bool> isOnWifi() => _stats.isOnWifi();

  /// 다운로드 시작 — 진행률·경과시간을 notifyListeners로 중계.
  Future<void> download() async {
    if (phase == ModelPhase.downloading || phase == ModelPhase.verifying) {
      return;
    }
    if (!await hasEnoughStorage()) {
      failure = ModelFailure.storage;
      _set(ModelPhase.failed);
      return;
    }
    // foreground 다운로드 진행률 알림용(Android 13+). 거부해도 진행은 가능 —
    // 화면을 열어둔 채 받도록 안내(§4.3 background 폴백 리스크). 기회성 요청이라
    // **팝업이 뜰 수 있을 때만** 묻는다 — 불가 상태(영구 거부·구형 차단)의 대안이
    // 설정 딥링크뿐인데, 다운로드를 시작하려는 사용자를 설정 화면에 세우는 것은
    // 알림보다 큰 사고다. 그 대안은 정작 권한이 필요한 자리(보호자 등록 직후)의
    // "알림 켜기"가 맡는다.
    if (!_askedNotifications) {
      _askedNotifications = true;
      try {
        if (await _stats.canRequestPostNotifications()) {
          await _stats.requestPostNotifications();
        }
      } catch (_) {}
    }

    failure = null;
    progressPercent = 0;
    elapsedSec = 0;
    _set(ModelPhase.downloading);
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      elapsedSec++;
      notifyListeners();
    });

    try {
      await FlutterGemma.installModel(modelType: ModelType.gemma4)
          .fromNetwork(OngiConfig.modelUrl)
          .withProgress((p) {
        if (p != progressPercent) {
          progressPercent = p;
          notifyListeners();
        }
      }).install();
      _ticker?.cancel();
      await _verify(File(await _modelPath()));
    } catch (_) {
      _ticker?.cancel();
      failure = ModelFailure.network;
      _set(ModelPhase.failed);
    }
  }

  Future<void> _verify(File file) async {
    _set(ModelPhase.verifying);
    if (!await file.exists() ||
        await file.length() != OngiConfig.modelSizeBytes) {
      failure = ModelFailure.verify;
      _set(ModelPhase.failed);
      return;
    }
    // sha256(2.6GB, 1~2분) — 메인 isolate 밖에서 계산.
    final digest = await Isolate.run(() => _sha256OfFile(file.path));
    if (digest != OngiConfig.modelSha256) {
      failure = ModelFailure.verify;
      _set(ModelPhase.failed);
      return;
    }
    await _db.setSetting(_verifiedKey, digest);
    _set(ModelPhase.ready);
  }

  void _set(ModelPhase next) {
    phase = next;
    notifyListeners();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }
}

Future<String> _sha256OfFile(String path) async {
  final digest = await sha256.bind(File(path).openRead()).first;
  return digest.toString();
}
