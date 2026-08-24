// ignore_for_file: avoid_print — CLI 평가 하네스(프로덕션 코드 아님)
// 임시 평가 하네스 — 규칙 분류 사각지대 측정 (git 미추적, 평가 후 삭제 가능)
// 실행: cd app && dart run tool/eval_category_rules.dart
// 주의: 패키지명은 사전 미등재 앱의 경우 일부 미검증(unverified.*)이며,
// 그 항목은 라벨 키워드 경로만 평가한다. 라벨은 실제 런처 표기 기준.
import 'dart:convert';
import 'dart:io';

import 'package:ongi/core/config.dart';
import 'package:ongi/features/apps/category_rules.dart';

class Case {
  const Case(this.pkg, this.label, this.expected);
  final String pkg;
  final String label;
  final LifeCategory expected;
}

const cases = [
  // ── 은행 (사전 미등재)
  Case('com.kbankwith.smartbank', '케이뱅크', LifeCategory.bank),
  Case('com.ibk.neobanking', 'i-ONE 뱅크', LifeCategory.bank),
  Case('unverified.imbank', 'iM뱅크', LifeCategory.bank),
  Case('unverified.bnk', 'BNK부산은행', LifeCategory.bank),
  Case('unverified.cu', '신협ON뱅크', LifeCategory.bank),
  // ── 카드·페이 (사전 미등재)
  Case('com.shinhancard.smartshinhan', '신한 SOL페이', LifeCategory.card),
  Case('com.hyundaicard.appcard', '현대카드', LifeCategory.card),
  Case('kr.co.samsungcard.mpocket', '삼성카드', LifeCategory.card),
  Case('com.kbcard.cxh.appcard', 'KB Pay', LifeCategory.card),
  Case('unverified.wooricard', '우리WON카드', LifeCategory.card),
  Case('unverified.nhpay', 'NH pay', LifeCategory.card),
  Case('unverified.monimo', '모니모', LifeCategory.card),
  Case('unverified.zeropay', '제로페이', LifeCategory.card),
  // ── 증권·보험
  Case('unverified.kiwoom', '영웅문S#', LifeCategory.invest),
  Case('unverified.samsunglife', '삼성생명', LifeCategory.invest),
  Case('unverified.hanwha', '한화손해보험', LifeCategory.invest),
  // ── 공공서비스
  Case('unverified.nhis', 'The건강보험', LifeCategory.publicService),
  Case('unverified.nps', '내곁에 국민연금', LifeCategory.publicService),
  Case('unverified.bokjiro', '복지로', LifeCategory.publicService),
  Case('kr.go.mobileid', '모바일 신분증', LifeCategory.publicService),
  Case('unverified.work24', '고용24', LifeCategory.publicService),
  // ── 의료·건강
  Case('unverified.ddocdoc', '똑닥', LifeCategory.health),
  Case('unverified.severance', '세브란스병원', LifeCategory.health),
  Case('unverified.pedometer', '만보기 - 걸음 측정', LifeCategory.health),
  // ── 교통
  Case('unverified.tmaptransit', 'TMAP 대중교통', LifeCategory.transport),
  Case('unverified.alddul', '알뜰교통카드', LifeCategory.transport),
  // ── 쇼핑·배달 (사전 미등재)
  Case('unverified.aliexpress', 'AliExpress', LifeCategory.shopping),
  Case('unverified.temu', 'Temu', LifeCategory.shopping),
  Case('unverified.kurly', '컬리', LifeCategory.shopping),
  Case('unverified.oliveyoung', '올리브영', LifeCategory.shopping),
  Case('unverified.daiso', '다이소몰', LifeCategory.shopping),
  Case('unverified.bunjang', '번개장터', LifeCategory.shopping),
  // ── 동영상·음악 (사전 미등재)
  Case('unverified.mbcradio', 'MBC 라디오', LifeCategory.media),
  Case('unverified.bugs', '벅스', LifeCategory.media),
  Case('unverified.kakaotv', '카카오TV', LifeCategory.media),
  // ── 인터넷·도구
  Case('com.android.vending', 'Play 스토어', LifeCategory.tools),
  Case('unverified.galaxystore', 'Galaxy 스토어', LifeCategory.tools),
  Case('unverified.onestore', '원스토어', LifeCategory.tools),
  Case('unverified.clock', '시계', LifeCategory.tools),
  Case('unverified.weather', '날씨', LifeCategory.tools),
  Case('unverified.tworld', 'T월드', LifeCategory.tools),
  Case('unverified.chrome', 'Chrome', LifeCategory.tools),
  Case('unverified.sinternet', '삼성 인터넷', LifeCategory.tools),
  // ── 기타로 남아야 정상인 앱들 (오분류 탐지 프로브)
  Case('unverified.cgv', 'CGV', LifeCategory.etc),
  Case('unverified.starbucks', '스타벅스', LifeCategory.etc),
  Case('unverified.recipe', '만개의레시피', LifeCategory.etc),
  // ── 게임
  Case('unverified.anipang', '애니팡 2', LifeCategory.game),
  Case('unverified.sudda', '피망 섯다', LifeCategory.game), // 무키워드 → LLM 판단
];

void main() {
  final rows = <Map<String, Object>>[];
  var correct = 0, wrong = 0, fallthrough = 0;
  final wrongList = <String>[];
  final fallthroughList = <Case>[];

  for (final c in cases) {
    final r = CategoryRules.classify(c.pkg, c.label);
    final ok = r.category == c.expected;
    rows.add({
      'label': c.label,
      'pkg': c.pkg,
      'expected': c.expected.name,
      'got': r.category.name,
      'matched': r.matched,
      'ok': ok,
    });
    if (!r.matched) {
      fallthrough++;
      fallthroughList.add(c);
      if (c.expected == LifeCategory.etc) correct++;
    } else if (ok) {
      correct++;
    } else {
      wrong++;
      wrongList.add(
          '${c.label} (${c.pkg}): expected=${c.expected.name} got=${r.category.name}');
    }
  }

  print('=== 규칙 계층 평가 (${cases.length}개, 사전 미등재 위주) ===');
  for (final r in rows) {
    final mark = r['ok'] == true ? 'OK ' : (r['matched'] == false ? '−→ ' : 'BAD');
    print('$mark ${r['label']}  →  ${r['got']}'
        '${r['matched'] == false ? ' (미매칭→LLM보정 대상)' : ''}'
        '  [기대: ${r['expected']}]');
  }
  print('---');
  print('정분류(기타 정상 포함): $correct / ${cases.length}');
  print('규칙 오분류: $wrong  ${wrongList.isEmpty ? '' : wrongList}');
  print('규칙 미매칭(→LLM 보정 후보): $fallthrough');

  // LLM 보정 시뮬레이션용 — category_refiner와 동일한 재료를 내보낸다.
  final out = {
    'categories': [
      for (final c in LifeCategory.values) {'name': c.name, 'label': c.label},
    ],
    'targets': [
      for (final c in fallthroughList)
        {'label': c.label, 'expected': c.expected.name},
    ],
  };
  final path = Platform.environment['EVAL_OUT'] ?? '/tmp/ongi_eval_targets.json';
  File(path).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(out));
  print('LLM 보정 대상 ${fallthroughList.length}건 → $path');
}
