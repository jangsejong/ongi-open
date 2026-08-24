// 민감 화면 3단 정책의 순수 함수 검증(ADR-19). 미탐(금융 앱을 놓침)은 곧바로
// 금전 피해로 이어지므로, 규칙 사각지대에서도 default-deny가 걸리는지 함께 본다.
import 'package:flutter_test/flutter_test.dart';
import 'package:ongi/core/config.dart';
import 'package:ongi/features/apps/category_rules.dart';
import 'package:ongi/features/coaching/share_policy.dart';

SharePolicy _policy(String packageName, String label) {
  final classified = CategoryRules.classify(packageName, label);
  return sharePolicyFor(
    category: classified.category,
    packageName: packageName,
    label: label,
  );
}

void main() {
  group('전면 차단 — 송금·결제·증권 (재동의 경로 없음)', () {
    test('은행 앱', () {
      expect(_policy('com.kbstar.kbbank', 'KB국민은행'), SharePolicy.blocked);
      expect(_policy('viva.republica.toss', '토스'), SharePolicy.blocked);
      expect(_policy('com.kakaobank.channel', '카카오뱅크'), SharePolicy.blocked);
    });

    test('카드·페이 앱', () {
      expect(_policy('com.kakaopay.app', '카카오페이'), SharePolicy.blocked);
      expect(_policy('com.samsung.android.spay', '삼성월렛'), SharePolicy.blocked);
    });

    test('차단 정책에는 재동의 안내가 아니라 통화를 끊으라는 안내가 붙는다', () {
      expect(SharePolicy.blocked.guidance, contains('통화를 끊고'));
      expect(SharePolicy.reconsent.guidance, isNot(contains('통화를 끊고')));
    });
  });

  group('재동의 허용 — 인증·공공·의료 (본인인증 코칭이 목적)', () {
    test('PASS 3사는 재동의 대상이다 — 코칭 과업 #1이라 열려 있어야 한다', () {
      expect(_policy('com.sktelecom.tauth', 'PASS by SKT'), SharePolicy.reconsent);
      expect(_policy('com.kt.ktauth', 'PASS by KT'), SharePolicy.reconsent);
      expect(_policy('com.lguplus.smartotp', 'PASS by U+'), SharePolicy.reconsent);
    });

    test('정부24·병원', () {
      expect(_policy('kr.go.minwon.m', '정부24'), SharePolicy.reconsent);
      expect(_policy('kr.co.goodoc', '굿닥'), SharePolicy.reconsent);
    });
  });

  group('일반 화면은 공유된다 — 과도한 차단은 코칭을 무력화한다', () {
    test('메신저·사진·지도', () {
      expect(_policy('com.kakao.talk', '카카오톡'), SharePolicy.allowed);
      expect(_policy('com.sec.android.gallery3d', '갤러리'), SharePolicy.allowed);
      expect(_policy('com.nhn.android.nmap', '네이버지도'), SharePolicy.allowed);
    });
  });

  group('default-deny — 분류 사각지대의 금융 앱', () {
    test('카테고리가 기타여도 라벨에 금융 신호가 있으면 차단된다', () {
      expect(
        sharePolicyFor(
          category: LifeCategory.etc,
          packageName: 'com.example.unknown',
          label: '○○저축은행',
        ),
        SharePolicy.blocked,
      );
      expect(
        sharePolicyFor(
          category: LifeCategory.etc,
          packageName: 'com.example.unknown',
          label: '간편송금',
        ),
        SharePolicy.blocked,
      );
    });

    test('패키지명에 금융 신호가 있어도 차단된다', () {
      expect(
        sharePolicyFor(
          category: LifeCategory.tools,
          packageName: 'com.acme.mobilebank',
          label: '알 수 없는 앱',
        ),
        SharePolicy.blocked,
      );
    });

    test('금융 신호가 없는 도구 앱은 공유된다', () {
      expect(
        sharePolicyFor(
          category: LifeCategory.tools,
          packageName: 'com.acme.calculator',
          label: '계산기',
        ),
        SharePolicy.allowed,
      );
    });
  });
}
