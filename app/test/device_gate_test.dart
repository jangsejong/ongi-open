import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ongi/ai/device_gate.dart';
import 'package:ongi/native/ongi_native.g.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// 네이티브 사양 조회까지 실패하는 기기 재현용.
class _ThrowingStats extends DeviceStatsApi {
  @override
  Future<MemInfo> getMemoryInfo() async => throw StateError('채널 실패');
}

/// 네이티브 사양 값 주입용.
class _FakeStats extends DeviceStatsApi {
  _FakeStats(this.mem);

  final MemInfo mem;

  @override
  Future<MemInfo> getMemoryInfo() async => mem;
}

/// crash 플래그 파일 경로를 임시 디렉터리로 돌리는 페이크.
class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  @override
  Future<String?> getApplicationSupportPath() async =>
      Directory.systemTemp.createTempSync('ongi_gate_test').path;
}

void main() {
  group('decideTier — RAM 게이팅(기획설계서 §4.3)', () {
    LlmTier tier(
      int ramMb, {
      bool lowRam = false,
      bool gpuCrashed = false,
      bool cpuCrashed = false,
    }) =>
        decideTier(
          ramMb: ramMb,
          lowRamDevice: lowRam,
          gpuCrashed: gpuCrashed,
          cpuCrashed: cpuCrashed,
        );

    test('4GB 미만 또는 low-ram 기기는 경량 모드', () {
      expect(tier(3072), LlmTier.off);
      expect(tier(8192, lowRam: true), LlmTier.off);
    });

    test('4~6GB는 CPU, 6GB 이상은 GPU 시도', () {
      expect(tier(4500), LlmTier.cpu);
      expect(tier(6144), LlmTier.gpu);
      expect(tier(8192), LlmTier.gpu);
    });

    test('crash 플래그 강등 — GPU crash는 CPU로, CPU crash는 경량 모드로', () {
      expect(tier(8192, gpuCrashed: true), LlmTier.cpu);
      expect(tier(4500, cpuCrashed: true), LlmTier.off);
      expect(tier(8192, gpuCrashed: true, cpuCrashed: true), LlmTier.off);
    });
  });

  test('resolveTier — 사양 조회가 전부 실패해도 던지지 않고 경량 모드 폴백', () async {
    // 1순위 네이티브 채널이 던지게 주입하고, 폴백 device_info도 테스트 환경엔
    // 플랫폼이 없어 던진다 — 예외가 전파되면 _bootstrap이 끊겨 phase가
    // checking에 고착되는 회귀 방지.
    TestWidgetsFlutterBinding.ensureInitialized();
    final gate = DeviceGate(statsApi: _ThrowingStats());
    expect(await gate.resolveTier(), LlmTier.off);
  });

  group('resolveTier — 네이티브 사양이 1순위(isLowRamDevice 오판 회귀)', () {
    // device_info_plus 13.x의 isLowRamDevice는 '그 순간의 메모리 압박' 플래그라
    // 세션 단위 LLM off 오판을 만들었다 — 네이티브 am.isLowRamDevice를 쓰는지 검증.
    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      PathProviderPlatform.instance = _FakePathProvider();
    });

    MemInfo mem({required int totalMemMb, required bool lowRamDevice}) =>
        MemInfo(
          totalMemMb: totalMemMb,
          availMemMb: totalMemMb ~/ 2,
          appPssMb: 100,
          lowRamDevice: lowRamDevice,
        );

    test('8GB + lowRamDevice=false → GPU (플러그인 없이 네이티브 값으로 판정)', () async {
      final gate = DeviceGate(
          statsApi: _FakeStats(mem(totalMemMb: 8192, lowRamDevice: false)));
      expect(await gate.resolveTier(), LlmTier.gpu);
    });

    test('네이티브 lowRamDevice=true → 경량 모드', () async {
      final gate = DeviceGate(
          statsApi: _FakeStats(mem(totalMemMb: 8192, lowRamDevice: true)));
      expect(await gate.resolveTier(), LlmTier.off);
    });
  });
}
