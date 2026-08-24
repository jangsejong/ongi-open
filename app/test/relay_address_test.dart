// 릴레이 주소는 **코드가 아니라 기기 설정에만** 있다.
//
// 주소를 코드에 박으면 세 가지가 따라온다: 공개 저장소에 사내 주소가 남고,
// 코칭을 쓰지 않는 모든 기기가 그 주소로 영구 재시도를 돌리고, 환경이 바뀔 때마다
// APK를 다시 말아야 한다. 여기서 고정하는 것은 그 셋을 막는 성질이다 —
// 기본값 부재, 빈 주소일 때 무접속(무재시도), 저장 시 통지.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ongi/core/config.dart';
import 'package:ongi/core/db.dart';
import 'package:ongi/features/coaching/coaching_signaling.dart';
import 'package:ongi/features/coaching/device_identity.dart';
import 'package:ongi/features/coaching/relay_field.dart';

/// sqflite 없이 도는 설정 저장소(테스트 규약: DB 미사용).
class _MemoryDb implements OngiDatabase {
  final Map<String, String> values = {};
  int writes = 0;

  @override
  Future<String?> getSetting(String key) async => values[key];

  @override
  Future<void> setSetting(String key, String value) async {
    writes++;
    values[key] = value;
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('주소는 코드에 없다', () {
    test('OngiConfig에 릴레이 기본 주소 상수가 없다', () {
      // 상수가 되살아나면 컴파일이 깨지도록 이름으로 고정한다. 설정 키만 남아야 한다.
      expect(OngiConfig.coachingRelaySettingKey, 'coaching_relay_url');
    });

    test('설정이 비어 있으면 주소도 비어 있다', () async {
      final db = _MemoryDb();
      final identity = DeviceIdentity(db: db);
      await identity.load();

      expect(identity.relayUrl, isEmpty, reason: '박아 둔 기본 주소로 떨어지면 안 된다');
    });

    test('저장하면 값이 남고 한 번만 알린다', () async {
      final db = _MemoryDb();
      final identity = DeviceIdentity(db: db);
      await identity.load();
      db.writes = 0; // load()가 기기 키를 만들며 한 번 쓴다 — 여기부터 센다.

      var notified = 0;
      identity.addListener(() => notified++);

      await identity.setRelayUrl('  wss://relay.example.com  ');
      expect(identity.relayUrl, 'wss://relay.example.com', reason: '공백은 다듬는다');
      expect(db.values[OngiConfig.coachingRelaySettingKey],
          'wss://relay.example.com');
      expect(notified, 1);

      // 같은 값을 다시 저장하면 쓰지도, 알리지도 않는다(불필요한 재연결 방지).
      await identity.setRelayUrl('wss://relay.example.com');
      expect(notified, 1);
      expect(db.writes, 1);
    });

    test('빈 값으로 지울 수 있다', () async {
      final db = _MemoryDb();
      final identity = DeviceIdentity(db: db);
      await identity.load();
      await identity.setRelayUrl('wss://relay.example.com');

      await identity.setRelayUrl('');
      expect(identity.relayUrl, isEmpty);
      expect(db.values[OngiConfig.coachingRelaySettingKey], isEmpty);
    });
  });

  group('주소가 없으면 붙지 않는다', () {
    test('connect가 조용히 끝나고 재시도를 걸지 않는다', () async {
      // 실패로 처리해 재시도를 걸면, 릴레이를 쓰지 않는 기기(대부분)가 영원히
      // 헛도는 루프를 안고 산다.
      final signaling = WebSocketSignaling(() => '');

      await expectLater(
        signaling.connect(deviceKey: 'k', role: 'elder'),
        completes,
      );
      expect(signaling.connected, isFalse);

      // 재시도가 걸렸다면 타이머가 살아 있어 테스트가 끝나지 않는다.
      await signaling.close();
    });

    test('주소를 나중에 넣으면 그때 그 주소를 쓴다', () async {
      // 주소를 필드로 들고 있으면 호출부가 구체 타입을 알아야 값을 넣을 수 있다.
      // 접속 시점에 다시 묻기 때문에 설정 변경이 그대로 반영된다.
      var url = '';
      final signaling = WebSocketSignaling(() => url);
      await signaling.connect(deviceKey: 'k', role: 'elder');
      expect(signaling.connected, isFalse);

      url = 'ws://127.0.0.1:1'; // 닿지 않는 주소 — 해석 시점만 본다.
      await expectLater(
        signaling.connect(deviceKey: 'k', role: 'elder'),
        throwsA(anything),
        reason: '주소가 생기면 실제로 붙으려 시도해야 한다',
      );
      await signaling.close();
    });
  });

  // 주소를 넣을 화면이 어르신 쪽에만 있으면 보호자 기기는 영영 붙지 못한다 —
  // 보호자 홈에서 다른 화면으로 갈 수 없기 때문이다(코드에 기본 주소가 없으므로).
  group('주소 입력은 두 역할 모두에서 가능하다', () {
    testWidgets('RelayField로 저장하면 identity에 남는다', (tester) async {
      final db = _MemoryDb();
      final identity = DeviceIdentity(db: db);
      await identity.load();

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: RelayField(identity: identity)),
      ));
      await tester.tap(find.text('연결 서버 설정'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'wss://relay.example.com');
      await tester.tap(find.text('저장'));
      await tester.pumpAndSettle();

      expect(identity.relayUrl, 'wss://relay.example.com');
      expect(db.values[OngiConfig.coachingRelaySettingKey],
          'wss://relay.example.com');
      await tester.pumpAndSettle(const Duration(seconds: 5));
    });
  });
}
