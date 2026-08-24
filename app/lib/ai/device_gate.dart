import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../core/config.dart';
import '../native/ongi_native.g.dart';

/// LLM 실행 등급(기획설계서 §4.3). off = 경량 모드(규칙 기반만).
enum LlmTier { off, cpu, gpu }

/// RAM 게이팅 결정 — 순수 함수(단위 테스트 대상).
/// crash 플래그는 백엔드 초기화 중 프로세스가 죽은 흔적(§4.3 GPU 안전장치).
LlmTier decideTier({
  required int ramMb,
  required bool lowRamDevice,
  required bool gpuCrashed,
  required bool cpuCrashed,
}) {
  if (ramMb < OngiConfig.lightModeMaxRamMb || lowRamDevice) return LlmTier.off;
  if (cpuCrashed) return LlmTier.off;
  if (ramMb < OngiConfig.cpuTierMaxRamMb) return LlmTier.cpu;
  return gpuCrashed ? LlmTier.cpu : LlmTier.gpu;
}

/// 기기 사양 + crash 플래그 파일 → 실행 등급 산출.
class DeviceGate {
  DeviceGate({DeviceStatsApi? statsApi})
      : _stats = statsApi ?? DeviceStatsApi();

  final DeviceStatsApi _stats;

  Future<File> crashFlagFile(LlmTier tier) async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/llm_crash_${tier.name}');
  }

  Future<LlmTier> resolveTier() async {
    try {
      int ramMb;
      bool lowRam;
      try {
        // 네이티브 ActivityManager가 1순위. device_info_plus 13.x의
        // isLowRamDevice는 이름과 달리 '그 순간의 메모리 압박'(MemoryInfo.lowMemory)
        // 을 반환해, 압박 중에 앱을 켜면 고사양 기기도 세션 내내 LLM off로
        // 오판된다(플러그인 소스 실측). am.isLowRamDevice는 기기 고정 속성.
        final mem = await _stats.getMemoryInfo();
        ramMb = mem.totalMemMb;
        lowRam = mem.lowRamDevice;
      } catch (_) {
        // 네이티브 실패 시 플러그인 값으로 폴백 — 단 lowRam 플래그는 위 이유로
        // 신뢰하지 않고 RAM 임계만으로 게이팅한다.
        final info = await DeviceInfoPlugin().androidInfo;
        ramMb = info.physicalRamSize;
        lowRam = false;
      }
      final gpuCrashed = await (await crashFlagFile(LlmTier.gpu)).exists();
      final cpuCrashed = await (await crashFlagFile(LlmTier.cpu)).exists();
      return decideTier(
        ramMb: ramMb,
        lowRamDevice: lowRam,
        gpuCrashed: gpuCrashed,
        cpuCrashed: cpuCrashed,
      );
    } catch (_) {
      // 사양 조회가 전부 실패하는 기기 — 여기서 던지면 _bootstrap이 끊겨
      // ModelManager.check()가 안 돌고 phase가 checking에 영구 고착된다.
      // LLM 없이도 앱은 동작해야 하므로 경량 모드로 폴백(§4.3).
      return LlmTier.off;
    }
  }

  /// 모델 재다운로드·검증 성공 시 호출 — 파일 손상으로 남은 플래그를 리셋해
  /// 경량 모드에 영구히 갇히는 것을 방지한다.
  Future<void> clearCrashFlags() async {
    for (final tier in [LlmTier.gpu, LlmTier.cpu]) {
      final file = await crashFlagFile(tier);
      if (await file.exists()) await file.delete();
    }
  }
}
