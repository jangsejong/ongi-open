import 'package:flutter_test/flutter_test.dart';
import 'package:ongi/core/config.dart';
import 'package:ongi/features/apps/category_rules.dart';

void main() {
  group('CategoryRules.classify', () {
    test('패키지 사전 — 대표 앱이 정확한 카테고리로 확정된다', () {
      final cases = {
        'com.kakao.talk': LifeCategory.phone,
        'viva.republica.toss': LifeCategory.bank,
        'com.kbstar.kbbank': LifeCategory.bank,
        'com.kakaopay.app': LifeCategory.card,
        'com.miraeasset.trade': LifeCategory.invest,
        'net.daum.android.map': LifeCategory.transport,
        'com.coupang.mobile': LifeCategory.shopping,
        'kr.go.minwon.m': LifeCategory.publicService,
        'com.sec.android.gallery3d': LifeCategory.photo,
        'com.sec.android.app.shealth': LifeCategory.health,
      };
      cases.forEach((packageName, expected) {
        final result = CategoryRules.classify(packageName, '아무라벨');
        expect(result.category, expected, reason: packageName);
        expect(result.matched, isTrue, reason: packageName);
      });
    });

    test('확장 사전(2026-07-12, Play 검증) — 신규 대표 앱 스팟 체크', () {
      final cases = {
        'com.skt.prod.dialer': LifeCategory.phone, // 에이닷 전화
        'kvp.jjy.MispAndroid320': LifeCategory.card, // 페이북/ISP
        'kr.co.tmoney.tia': LifeCategory.transport, // 티머니GO
        'com.astroframe.seoulbus': LifeCategory.transport, // 카카오버스
        'gsshop.mobile.v2': LifeCategory.shopping,
        'com.towneers.www': LifeCategory.shopping, // 당근
        'com.sktelecom.tauth': LifeCategory.publicService, // PASS
        'com.nhn.android.ndrive': LifeCategory.photo, // MYBOX
        'com.cashwalk.cashwalk': LifeCategory.health,
      };
      cases.forEach((packageName, expected) {
        final result = CategoryRules.classify(packageName, '아무라벨');
        expect(result.category, expected, reason: packageName);
        expect(result.matched, isTrue, reason: packageName);
      });
    });

    test('카테고리 개편(2026-07-13) — 동영상·음악, SNS, 인터넷·도구 사전 스팟 체크', () {
      final cases = {
        'com.google.android.youtube': LifeCategory.media,
        'com.iloen.melon': LifeCategory.media,
        'com.nhn.android.band': LifeCategory.sns,
        'com.instagram.android': LifeCategory.sns,
        'com.android.vending': LifeCategory.tools, // Play 스토어(구 쇼핑 오분류)
        'com.sec.android.app.samsungapps': LifeCategory.tools, // Galaxy 스토어
        'com.nhn.android.search': LifeCategory.tools, // 네이버
        'com.sec.android.app.clockpackage': LifeCategory.tools, // 시계
        'com.neowiz.games.newmatgo': LifeCategory.game, // 피망 뉴맞고
      };
      cases.forEach((packageName, expected) {
        final result = CategoryRules.classify(packageName, '아무라벨');
        expect(result.category, expected, reason: packageName);
        expect(result.matched, isTrue, reason: packageName);
      });
    });

    test('기타 명시 매핑 — matched=true라서 LLM 보정 배치에서 제외된다', () {
      final result =
          CategoryRules.classify('com.godpeople.GPBIBLE', '갓피플성경');
      expect(result.category, LifeCategory.etc);
      expect(result.matched, isTrue); // source=rule → unclassified() 미포함
    });

    test('패키지 패턴 — kr.go.=공공서비스, bank=은행, card·pay=카드·페이', () {
      expect(
        CategoryRules.classify('kr.go.unknown.newapp', '모름').category,
        LifeCategory.publicService,
      );
      expect(
        CategoryRules.classify('com.newbank.smart', '모름').category,
        LifeCategory.bank,
      );
      expect(
        CategoryRules.classify('com.somecard.app', '모름').category,
        LifeCategory.card,
      );
      expect(
        CategoryRules.classify('nh.smart.nhallonepay', 'NH pay').category,
        LifeCategory.card,
      );
    });

    test('라벨 키워드 — 사전에 없는 앱도 라벨로 분류된다', () {
      final cases = {
        '한사랑병원 예약': LifeCategory.health,
        '시내버스 도착알림': LifeCategory.transport,
        '동네마켓': LifeCategory.shopping,
        'iM뱅크': LifeCategory.bank,
        '우리WON카드': LifeCategory.card,
        '영웅문S# 주식': LifeCategory.invest,
        'MBC 라디오': LifeCategory.media,
        '원스토어': LifeCategory.tools,
      };
      cases.forEach((label, expected) {
        expect(
          CategoryRules.classify('com.x.unknown', label).category,
          expected,
          reason: label,
        );
      });
    });

    test('키워드 순서 — 복합어는 앞선 카테고리가 먼저 잡는다', () {
      // '건강보험'은 의료(건강)·증권(보험)이 아니라 공공서비스.
      expect(
        CategoryRules.classify('com.x.nhis', 'The건강보험').category,
        LifeCategory.publicService,
      );
      // '교통카드'는 카드·페이가 아니라 교통.
      expect(
        CategoryRules.classify('com.x.alddul', '알뜰교통카드').category,
        LifeCategory.transport,
      );
    });

    test('부분문자열 오탐 방지 — 스마트≠마트, 페이스북≠페이', () {
      // '스마트X'가 쇼핑('마트'), '페이스북 X'가 카드('페이')로 새지 않는다.
      expect(
        CategoryRules.classify('com.x.smartbill', '스마트청구서').matched,
        isFalse,
      );
      expect(
        CategoryRules.classify('com.x.fblite', '페이스북 라이트').matched,
        isFalse,
      );
      // 정상 키워드는 스트립 후에도 살아남는다(패키지 패턴 미적중 라벨 경로).
      expect(
        CategoryRules.classify('com.x.gjb', '광주은행 스마트뱅킹').category,
        LifeCategory.bank,
      );
    });

    test('규칙 사각지대 — matched=false로 기타 폴백(LLM 보정 후보)', () {
      final result = CategoryRules.classify('com.unknown.app', 'Zeta');
      expect(result.category, LifeCategory.etc);
      expect(result.matched, isFalse);
    });
  });
}
