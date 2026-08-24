import '../../core/config.dart';

/// 규칙 기반 앱 분류(기획설계서 §4.2) — 사전(패키지명) 우선, 라벨 키워드 보조.
/// `matched=false`(기타 폴백)인 앱만 LLM 보정 대상이 된다.
/// 순수 Dart — 단위 테스트 대상.
class CategoryRules {
  CategoryRules._();

  /// 잘 알려진 국내·기본 앱 패키지 사전. 여기 걸리면 라벨과 무관하게 확정.
  /// 국내 서비스 앱은 Google Play 상세 페이지(og:title)로 패키지↔앱 대조
  /// 검증(2026-07-12) — 추측 등재 금지. 2026-07-13 추가분(플랫폼 기본앱)은
  /// AOSP·제조사 관용 패키지명 기준. '기타' 명시 매핑은 LLM 재분류 대상에서
  /// 빼기 위한 것.
  static const Map<String, LifeCategory> _exact = {
    // 전화·메시지
    'com.kakao.talk': LifeCategory.phone,
    'com.android.dialer': LifeCategory.phone,
    'com.samsung.android.dialer': LifeCategory.phone,
    'com.android.contacts': LifeCategory.phone,
    'com.google.android.contacts': LifeCategory.phone,
    'com.samsung.android.app.contacts': LifeCategory.phone,
    'com.samsung.android.messaging': LifeCategory.phone,
    'com.google.android.apps.messaging': LifeCategory.phone,
    'com.skt.prod.dialer': LifeCategory.phone, // 에이닷 전화(구 T전화)
    'com.ktcs.whowho': LifeCategory.phone, // 후후(스팸 차단)
    'gogolook.callgogolook2': LifeCategory.phone, // 후스콜
    'jp.naver.line.android': LifeCategory.phone, // 라인
    'org.telegram.messenger': LifeCategory.phone, // 텔레그램
    'com.google.android.gm': LifeCategory.phone, // Gmail(메일=메시지 칸)
    // 은행
    'viva.republica.toss': LifeCategory.bank, // 토스(송금·계좌 중심)
    'com.kakaobank.channel': LifeCategory.bank,
    'com.kbstar.kbbank': LifeCategory.bank,
    'com.wooribank.smart.npib': LifeCategory.bank,
    'nh.smart.banking': LifeCategory.bank,
    'com.shinhan.sbanking': LifeCategory.bank,
    'com.hanabank.oqf': LifeCategory.bank, // 하나원큐
    'com.smg.spbs': LifeCategory.bank, // MG더뱅킹(새마을금고)
    'com.epost.psf.sdsi': LifeCategory.bank, // 우체국뱅킹
    // 카드·페이
    'com.samsung.android.spay': LifeCategory.card, // 삼성월렛(삼성페이)
    'com.nhnent.payapp': LifeCategory.card, // 페이코
    'com.kakaopay.app': LifeCategory.card, // 카카오페이
    'com.naverfin.payapp': LifeCategory.card, // 네이버페이
    'kvp.jjy.MispAndroid320': LifeCategory.card, // 페이북/ISP(BC카드)
    'com.lcacApp': LifeCategory.card, // 디지로카(롯데카드)
    // 증권·보험
    'com.miraeasset.trade': LifeCategory.invest, // 미래에셋증권 M-STOCK
    'com.samsungpop.android.mpop': LifeCategory.invest, // 삼성증권 mPOP
    // 교통
    'net.daum.android.map': LifeCategory.transport, // 카카오맵
    'com.nhn.android.nmap': LifeCategory.transport, // 네이버지도
    'com.google.android.apps.maps': LifeCategory.transport, // 구글 지도
    'com.skt.tmap.ku': LifeCategory.transport, // 티맵
    'com.kakao.taxi': LifeCategory.transport, // 카카오T
    'com.korail.talk': LifeCategory.transport, // 코레일톡
    'kr.co.srail.newapp': LifeCategory.transport, // SRT
    'com.kscc.scxb.mbl': LifeCategory.transport, // 고속버스 티머니
    'kr.co.tmoney.tia': LifeCategory.transport, // 티머니GO
    'com.astroframe.seoulbus': LifeCategory.transport, // 카카오버스
    'net.orizinal.subway': LifeCategory.transport, // 카카오지하철
    'com.locnall.KimGiSa': LifeCategory.transport, // 카카오내비
    // 쇼핑·배달
    'com.coupang.mobile': LifeCategory.shopping,
    'com.coupang.mobile.eats': LifeCategory.shopping,
    'com.elevenst': LifeCategory.shopping,
    'com.ebay.kr.gmarket': LifeCategory.shopping,
    'com.ebay.kr.auction': LifeCategory.shopping,
    'com.wemakeprice': LifeCategory.shopping,
    'com.sampleapp': LifeCategory.shopping, // 배달의민족 실제 패키지명
    'gsshop.mobile.v2': LifeCategory.shopping, // GS SHOP
    'com.cjoshppingphone': LifeCategory.shopping, // CJ온스타일
    'com.hmallapp': LifeCategory.shopping, // 현대홈쇼핑
    'kr.co.emart.emartmall': LifeCategory.shopping, // 이마트몰
    'kr.co.ssg': LifeCategory.shopping, // SSG.COM
    'com.socialapps.homeplus': LifeCategory.shopping, // 홈플러스
    'com.homeplus.myhomeplus': LifeCategory.shopping, // 마이 홈플러스
    'com.lottemart.lmscp': LifeCategory.shopping, // 롯데마트GO
    'com.fineapp.yogiyo': LifeCategory.shopping, // 요기요
    'com.towneers.www': LifeCategory.shopping, // 당근
    // 공공서비스
    'kr.go.minwon.m': LifeCategory.publicService, // 정부24
    'kr.go.nts.android': LifeCategory.publicService, // 손택스
    'com.sktelecom.tauth': LifeCategory.publicService, // PASS by SKT
    'com.kt.ktauth': LifeCategory.publicService, // PASS by KT
    'com.lguplus.smartotp': LifeCategory.publicService, // PASS by U+
    // 사진·앨범
    'com.sec.android.gallery3d': LifeCategory.photo,
    'com.google.android.apps.photos': LifeCategory.photo,
    'com.sec.android.app.camera': LifeCategory.photo,
    'com.google.android.GoogleCamera': LifeCategory.photo,
    'com.nhn.android.ndrive': LifeCategory.photo, // 네이버 MYBOX
    'com.campmobile.snow': LifeCategory.photo, // 스노우
    'com.linecorp.b612.android': LifeCategory.photo, // B612
    'com.snowcorp.soda.android': LifeCategory.photo, // SODA
    'com.cyworld.camera': LifeCategory.photo, // 싸이메라
    // 의료·건강
    'com.sec.android.app.shealth': LifeCategory.health, // 삼성 헬스
    'kr.co.goodoc': LifeCategory.health, // 굿닥
    'com.cashwalk.cashwalk': LifeCategory.health, // 캐시워크(만보기)
    'com.swallaby.walkon': LifeCategory.health, // 워크온(걷기)
    // 동영상·음악
    'com.google.android.youtube': LifeCategory.media, // 유튜브
    'com.google.android.apps.youtube.music': LifeCategory.media,
    'com.netflix.mediaclient': LifeCategory.media, // 넷플릭스
    'net.cj.cjhv.gs.tving': LifeCategory.media, // 티빙
    'kr.co.captv.pooqV2': LifeCategory.media, // 웨이브
    'com.coupang.mobile.play': LifeCategory.media, // 쿠팡플레이
    'com.iloen.melon': LifeCategory.media, // 멜론
    'com.ktmusic.geniemusic': LifeCategory.media, // 지니뮤직
    'com.sec.android.app.music': LifeCategory.media, // 삼성뮤직
    'com.zhiliaoapp.musically': LifeCategory.media, // 틱톡(쇼트폼 동영상)
    'com.kakao.page': LifeCategory.media, // 카카오페이지(웹툰·웹소설)
    // SNS·커뮤니티
    'com.nhn.android.band': LifeCategory.sns, // 밴드
    'com.kakao.story': LifeCategory.sns, // 카카오스토리
    'com.instagram.android': LifeCategory.sns, // 인스타그램
    'com.facebook.katana': LifeCategory.sns, // 페이스북
    'com.nhn.android.navercafe': LifeCategory.sns, // 네이버 카페
    'com.nhn.android.blog': LifeCategory.sns, // 네이버 블로그
    // 인터넷·도구
    'com.nhn.android.search': LifeCategory.tools, // 네이버
    'net.daum.android.daum': LifeCategory.tools, // 다음
    'com.android.chrome': LifeCategory.tools, // Chrome
    'com.sec.android.app.sbrowser': LifeCategory.tools, // 삼성 인터넷
    'com.google.android.googlequicksearchbox': LifeCategory.tools, // Google
    'com.android.vending': LifeCategory.tools, // Play 스토어
    'com.sec.android.app.samsungapps': LifeCategory.tools, // Galaxy 스토어
    'com.sec.android.app.clockpackage': LifeCategory.tools, // 시계(삼성)
    'com.sec.android.app.popupcalculator': LifeCategory.tools, // 계산기(삼성)
    'com.samsung.android.calendar': LifeCategory.tools, // 캘린더(삼성)
    'com.google.android.calendar': LifeCategory.tools, // Google 캘린더
    'com.sec.android.daemonapp': LifeCategory.tools, // 날씨(삼성)
    'com.sktelecom.minit': LifeCategory.tools, // T월드
    // 게임
    'com.neowiz.games.newmatgo': LifeCategory.game, // 피망 뉴맞고
    // 기타(명시) — 분류가 어려운 대중 앱을 LLM 보정 배치에서 제외해
    // 20개 상한을 진짜 사각지대에 쓰게 한다.
    'com.godpeople.GPBIBLE': LifeCategory.etc, // 갓피플성경
  };

  /// 라벨 키워드 — 검사 순서가 정확도를 좌우한다(예: '건강보험'은 공공서비스가
  /// '건강'(의료)·'보험'(증권·보험)보다, '교통카드'는 교통이 '카드'보다 먼저
  /// 잡아야 한다). 항목 순서 변경 시 테스트로 검증할 것.
  static const List<(LifeCategory, List<String>)> _labelKeywords = [
    (LifeCategory.phone, ['전화', '연락처', '메시지', '문자', '메신저', '톡']),
    (LifeCategory.photo, ['카메라', '갤러리', '사진', '앨범', '포토']),
    (
      LifeCategory.transport,
      ['지도', '지하철', '버스', '기차', '택시', '내비', '교통', '주차', '철도', 'KTX'],
    ),
    (
      LifeCategory.publicService,
      ['정부', '민원', '세금', '국세', '복지', '연금', '건강보험', '경찰', '우체국', '도서관', '행정'],
    ),
    (LifeCategory.bank, ['은행', '뱅크', '뱅킹', '금융']),
    (LifeCategory.card, ['카드', '페이', '결제', '월렛', '머니']),
    (LifeCategory.invest, ['증권', '주식', '투자', '보험', '자산']),
    (
      LifeCategory.health,
      ['병원', '약국', '건강', '헬스', '의료', '걸음', '만보', '운동', '피트니스'],
    ),
    (
      LifeCategory.shopping,
      ['쇼핑', '마켓', '배달', '장보기', '중고', '홈쇼핑', '마트'],
    ),
    (
      LifeCategory.media,
      ['뮤직', '음악', '라디오', '방송', '웹툰', '만화', '영화', '드라마', 'TV'],
    ),
    (LifeCategory.sns, ['커뮤니티', '소셜', 'SNS']),
    (LifeCategory.game, ['게임', '맞고', '고스톱', '바둑', '장기', '퍼즐']),
    (
      LifeCategory.tools,
      ['계산기', '날씨', '시계', '알람', '달력', '캘린더', '일정', '메모', '스토어', '검색', '브라우저', '파일'],
    ),
  ];

  /// 분류 결과. matched=false면 규칙 사각지대(기타 폴백) — LLM 보정 후보.
  static ({LifeCategory category, bool matched}) classify(
    String packageName,
    String label,
  ) {
    final exact = _exact[packageName];
    if (exact != null) return (category: exact, matched: true);

    // 패키지명 패턴 — 대한민국 정부(.go.kr 계열)와 금융권 관용 접두어.
    if (packageName.startsWith('kr.go.') || packageName.contains('.go.kr')) {
      return (category: LifeCategory.publicService, matched: true);
    }
    if (packageName.contains('bank')) {
      return (category: LifeCategory.bank, matched: true);
    }
    if (packageName.contains('card') || packageName.contains('pay')) {
      return (category: LifeCategory.card, matched: true);
    }

    // 부분문자열 오탐 제거 — '스마트'가 '마트'(쇼핑)에, '페이스북'이 '페이'
    // (카드·페이)에 걸린다. 두 토큰을 벗겨낸 라벨로 키워드를 검사한다
    // ('스마트뱅킹'→'뱅킹'처럼 정상 키워드는 그대로 살아남는다).
    final stripped = label.replaceAll('스마트', '').replaceAll('페이스북', '');
    for (final (category, keywords) in _labelKeywords) {
      for (final keyword in keywords) {
        if (stripped.contains(keyword)) {
          return (category: category, matched: true);
        }
      }
    }
    return (category: LifeCategory.etc, matched: false);
  }
}
