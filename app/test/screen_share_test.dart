// 화면 공유 시작 절차 — 순서와 재진입이 안전 속성인 지점이다.
//
// Android 14+는 "캡처 동의를 받은 뒤에야 mediaProjection FGS 허용"과 "FGS가 떠
// 있어야 MediaProjection 획득 가능"을 동시에 요구한다. 동의를 먼저 받지 않으면
// 두 요구가 서로를 막고, 그 실패는 플러그인 안쪽(ResultReceiver 콜백)에서 터져
// 앱이 통째로 죽는다 — Dart 쪽에서 잡을 수 없으므로 순서로만 막을 수 있다.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ongi/features/coaching/coaching_signaling.dart';
import 'package:ongi/features/coaching/screen_share.dart';
import 'package:ongi/native/ongi_native.g.dart';

class _SilentSignaling implements CoachingSignaling {
  final _controller = StreamController<SignalMessage>.broadcast();

  @override
  Stream<SignalMessage> get messages => _controller.stream;

  @override
  bool get connected => true;

  @override
  Future<void> connect({
    required String deviceKey,
    required String role,
  }) async {}

  @override
  Future<void> send(SignalMessage message) async {}

  @override
  Future<void> close() async {}
}

/// FGS 기동·중지를 기록하는 네이티브 대역. 호출 순서를 공유 목록에 남긴다.
class _FakeCoaching extends CoachingApi {
  _FakeCoaching(this.calls);

  final List<String> calls;
  bool serviceStarts = true;

  @override
  Future<bool> startShareService() async {
    calls.add('startShareService');
    return serviceStarts;
  }

  @override
  Future<void> stopShareService() async => calls.add('stopShareService');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<String> calls;
  late _FakeCoaching native;
  late ScreenShare share;
  var consent = true;

  setUp(() {
    calls = <String>[];
    consent = true;
    native = _FakeCoaching(calls);
    share = ScreenShare(
      signaling: _SilentSignaling(),
      native: native,
      // 기본값은 Helper.requestCapturePermission이지만 그 호출은 플랫폼 판정이
      // 내부에 있어 호스트 VM에서 바로 던진다 — 주입점으로 순서만 본다.
      requestConsent: () async {
        calls.add('requestConsent');
        return consent;
      },
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('FlutterWebRTC.Method'),
      (call) async {
        calls.add(call.method);
        // 캡처 획득까지 대역을 세우지 않는다 — 여기서 실패시켜도 검증 대상인
        // "동의·FGS 순서"와 실패 시 정리는 그대로 드러난다.
        throw PlatformException(code: 'unsupported');
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('FlutterWebRTC.Method'), null);
  });

  test('동의를 먼저 받고 그 다음에 FGS를 올린다', () async {
    await share.start('s1');

    final consentAt = calls.indexOf('requestConsent');
    final serviceAt = calls.indexOf('startShareService');
    expect(consentAt, isNonNegative, reason: '동의를 건너뛰면 안 된다');
    expect(serviceAt, isNonNegative);
    expect(consentAt, lessThan(serviceAt),
        reason: 'FGS가 먼저 뜨면 Android 14+에서 거부되고, 그 뒤 캡처 획득이 앱을 죽인다');
  });

  test('어르신이 동의를 취소하면 FGS를 올리지 않는다', () async {
    consent = false;
    final ok = await share.start('s1');

    expect(ok, isFalse);
    expect(calls, isNot(contains('startShareService')),
        reason: '동의 없이 서비스만 뜨면 상시 알림이 고아로 남는다');
  });

  test('캡처를 얻지 못하면 올려 둔 FGS를 내린다', () async {
    final ok = await share.start('s1');

    expect(ok, isFalse);
    expect(calls.last, 'stopShareService');
    expect(share.isSharing, isFalse);
  });

  test('시작 중 두 번째 탭은 캡처를 중복 시작하지 않는다', () async {
    // 큰 버튼 더블탭 — isSharing은 동의가 끝난 뒤에야 참이 되므로 그것만으로는
    // 두 번째 호출을 막지 못한다. 중복되면 한쪽의 실패 정리가 살아 있는 쪽의
    // FGS까지 내린다.
    final first = share.start('s1');
    final second = share.start('s1');
    final results = await Future.wait([first, second]);

    expect(results.where((ok) => ok).length, 0);
    expect(calls.where((c) => c == 'requestConsent').length, 1,
        reason: '동의 다이얼로그가 두 번 뜨면 안 된다');
    expect(calls.where((c) => c == 'startShareService').length, 1);
    expect(share.isStarting, isFalse, reason: '절차가 끝나면 잠금이 풀려야 한다');
  });
}
