// W1 스파이크 계측 화면 — 기획설계서 §11의 실기기 측정 항목을 버튼 한 번으로 수집한다.
// 스파이크 전용 코드(프로덕션 품질 아님). 측정 완료 후 features/spike는 제거 예정.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:path_provider/path_provider.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../../ai/device_gate.dart';
import '../../core/config.dart';
import '../../native/ongi_native.g.dart';

class SpikeScreen extends StatefulWidget {
  const SpikeScreen({super.key});

  @override
  State<SpikeScreen> createState() => _SpikeScreenState();
}

class _SpikeScreenState extends State<SpikeScreen> {
  final Map<String, dynamic> _results = {};
  final Map<String, String> _logs = {};
  final _speech = SpeechToText();
  final _tts = FlutterTts();
  final _appScan = AppScanApi();
  final _stats = DeviceStatsApi();

  void _log(String section, String line) {
    setState(() {
      _logs[section] = '${_logs[section] ?? ''}$line\n';
    });
  }

  void _clear(String section) => setState(() => _logs[section] = '');

  String _now() => DateTime.now().toIso8601String().substring(11, 23);

  // ── 1. 기기 정보 ─────────────────────────────────────────────
  Future<void> _runDeviceInfo() async {
    const s = '기기';
    _clear(s);
    final info = await DeviceInfoPlugin().androidInfo;
    // 판단 근거는 프로덕션 게이트와 같은 경로(네이티브 ActivityManager 1순위)로
    // 수집한다. 플러그인 isLowRamDevice는 이름과 달리 '그 순간의 메모리 압박'
    // (MemoryInfo.lowMemory)이라 참고용으로만 남긴다 — device_gate.dart 참조.
    final gate = DeviceGate(statsApi: _stats);
    Map<String, Object?> native;
    try {
      final mem = await _stats.getMemoryInfo();
      native = {
        'nativeTotalMemMb': mem.totalMemMb,
        'nativeAvailMemMb': mem.availMemMb,
        'appPssMb': mem.appPssMb,
        'isLowRamDevice': mem.lowRamDevice, // am.isLowRamDevice — 기기 고정 속성
      };
    } catch (e) {
      // 네이티브 실패 시 게이트는 RAM 임계만으로 판정한다 — 결과 해석도 동일하게.
      native = {'nativeError': '$e'};
    }
    // 앱이 실제로 택할 등급 + crash 플래그 잔존 여부 — #324(Mali 프리즈) 재현
    // 판정의 직접 증거. release 빌드에선 run-as로 파일을 볼 수 없어 여기 담는다.
    final tier = await gate.resolveTier();
    final data = {
      'model': '${info.manufacturer} ${info.model}',
      'sdkInt': info.version.sdkInt,
      'abis': info.supportedAbis,
      ...native,
      'tier': tier.name,
      'crashFlags': {
        'gpu': await (await gate.crashFlagFile(LlmTier.gpu)).exists(),
        'cpu': await (await gate.crashFlagFile(LlmTier.cpu)).exists(),
      },
      // 플러그인 원시값(교차검증 참고용 — 임계 조정 근거로 쓰지 않는다)
      'pluginPhysicalRamMb': info.physicalRamSize,
      'pluginAvailableRamMb': info.availableRamSize,
      'pluginLowMemoryNow': info.isLowRamDevice, // 순간 압박값(이름과 다름)
    };
    _results['device'] = data;
    data.forEach((k, v) => _log(s, '$k: $v'));
  }

  // ── 2. 앱 스캔 E2E (pigeon, QUERY_ALL_PACKAGES 없음) ─────────
  Future<void> _runAppScan() async {
    const s = '앱스캔';
    _clear(s);
    final sw = Stopwatch()..start();
    final apps = await _appScan.getInstalledApps();
    sw.stop();
    _results['appScan'] = {
      'count': apps.length,
      'elapsedMs': sw.elapsedMilliseconds,
      'sample': apps.take(8).map((a) => a.label).toList(),
    };
    _log(s, '조회 ${apps.length}개 / ${sw.elapsedMilliseconds}ms');
    _log(s, '샘플: ${apps.take(8).map((a) => a.label).join(', ')}');
  }

  // ── 3. STT 실측 ──────────────────────────────────────────────
  DateTime? _lastResultAt;
  DateTime? _listenStartAt;

  Future<void> _runSttInit() async {
    const s = 'STT';
    _clear(s);
    final ok = await _speech.initialize(
      onStatus: (st) {
        final now = DateTime.now();
        if (st == 'done' && _lastResultAt != null) {
          final cutoff = now.difference(_lastResultAt!).inMilliseconds;
          _log(s, '[${_now()}] status=$st (마지막 결과 후 ${cutoff}ms → 무음 컷오프)');
          (_results['stt'] as Map?)?['silenceCutoffMs'] = cutoff;
        } else {
          _log(s, '[${_now()}] status=$st');
        }
      },
      onError: (e) => _log(s, '[${_now()}] error=${e.errorMsg} permanent=${e.permanent}'),
    );
    final locales = ok ? await _speech.locales() : [];
    final hasKo = locales.any((l) => l.localeId.replaceAll('-', '_').startsWith('ko'));
    _results['stt'] = {'initialize': ok, 'koLocale': hasKo, 'localeCount': locales.length};
    _log(s, 'initialize=$ok, ko 로케일=$hasKo (전체 ${locales.length}개)');
  }

  Future<void> _runSttListen({required bool onDevice}) async {
    const s = 'STT';
    if (!_speech.isAvailable) {
      _log(s, '먼저 [초기화]를 실행하세요');
      return;
    }
    _lastResultAt = null;
    _listenStartAt = DateTime.now();
    _log(s, '--- listen(onDevice=$onDevice) 시작: 짧은 문장을 말하고 기다리세요 ---');
    await _speech.listen(
      onResult: (SpeechRecognitionResult r) {
        _lastResultAt = DateTime.now();
        final t = _lastResultAt!.difference(_listenStartAt!).inMilliseconds;
        _log(s, '[+${t}ms] ${r.finalResult ? "FINAL" : "partial"}: ${r.recognizedWords}');
        if (r.finalResult) {
          (_results['stt'] as Map?)?['lastFinal_onDevice_$onDevice'] = r.recognizedWords;
        }
      },
      listenOptions: SpeechListenOptions(
        listenFor: const Duration(seconds: 25),
        pauseFor: const Duration(seconds: 5),
        localeId: 'ko_KR',
        partialResults: true,
        onDevice: onDevice,
        cancelOnError: true,
      ),
    );
  }

  // ── 4. TTS 실측 ──────────────────────────────────────────────
  Future<void> _runTts() async {
    const s = 'TTS';
    _clear(s);
    final engines = await _tts.getEngines;
    final engine = await _tts.getDefaultEngine;
    _log(s, '엔진 목록: $engines');
    _log(s, '기본 엔진: $engine');
    final voices = await _tts.getVoices;
    final koVoices = (voices as List)
        .where((v) => v['locale'].toString().replaceAll('-', '_').startsWith('ko'))
        .toList();
    for (final v in koVoices.take(6)) {
      _log(s, 'ko 보이스: ${v['name']} (network_required=${v['network_required'] ?? '?'})');
    }
    _results['tts'] = {
      'engines': engines,
      'defaultEngine': engine,
      'koVoices': koVoices.take(6).map((v) => '${v['name']}').toList(),
    };
  }

  Future<void> _speakSample() async {
    await _tts.setLanguage('ko-KR');
    await _tts.setSpeechRate(0.7); // Android 표준=1.0, 고령자용 시작점
    await _tts.speak('안녕하세요. 온기가 도와드릴게요. 카카오톡을 열까요?');
  }

  // ── 5. 모델 다운로드 실측 (9분 타임아웃 검증) ─────────────────
  bool _downloading = false;

  Future<void> _runDownload() async {
    const s = '다운로드';
    _clear(s);
    if (_downloading) return;
    _downloading = true;
    final sw = Stopwatch()..start();
    var lastLogged = -5;
    _log(s, '시작: ${OngiConfig.modelUrl}');
    _log(s, '★ 9분(540초) 경과 후에도 진행되는지가 핵심 관찰 항목');
    try {
      await FlutterGemma.installModel(modelType: ModelType.gemma4)
          .fromNetwork(OngiConfig.modelUrl)
          .withProgress((p) {
        if (p >= lastLogged + 5) {
          lastLogged = p;
          final sec = sw.elapsed.inSeconds;
          final mbps = p > 0
              ? (OngiConfig.modelSizeBytes * p / 100 / 1024 / 1024) / (sec == 0 ? 1 : sec)
              : 0;
          _log(s, '[+${sec}s] $p%  (평균 ${mbps.toStringAsFixed(1)} MB/s)'
              '${sec > 540 ? '  ← 9분 초과 후 진행 중!' : ''}');
        }
      }).install();
      sw.stop();
      final file = await _modelFile();
      final size = file != null && file.existsSync() ? file.lengthSync() : -1;
      final ok = size == OngiConfig.modelSizeBytes;
      _results['download'] = {
        'totalSec': sw.elapsed.inSeconds,
        'over9min': sw.elapsed.inSeconds > 540,
        'fileSize': size,
        'sizeMatch': ok,
        'avgMBps': (OngiConfig.modelSizeBytes / 1024 / 1024) / sw.elapsed.inSeconds,
      };
      _log(s, '완료: ${sw.elapsed.inSeconds}초, 크기 검증 ${ok ? "일치" : "불일치($size)"}');
    } catch (e) {
      sw.stop();
      _results['download'] = {'error': '$e', 'failedAtSec': sw.elapsed.inSeconds};
      _log(s, '실패 [+${sw.elapsed.inSeconds}s]: $e');
      _log(s, '★ 540초 부근 실패면 9분 타임아웃 확정 (설계서 §4.3)');
    } finally {
      _downloading = false;
    }
  }

  Future<File?> _modelFile() async {
    final dir = await getApplicationDocumentsDirectory();
    final f = File('${dir.path}/${OngiConfig.modelFileName}');
    return f.existsSync() ? f : null;
  }

  Future<void> _runSha256() async {
    const s = '다운로드';
    final f = await _modelFile();
    if (f == null) {
      _log(s, '모델 파일 없음 — 먼저 다운로드');
      return;
    }
    _log(s, 'sha256 계산 중(1~2분)…');
    final sw = Stopwatch()..start();
    final digest = await sha256.bind(f.openRead()).first;
    sw.stop();
    final ok = digest.toString() == OngiConfig.modelSha256;
    _results['sha256'] = {'match': ok, 'sec': sw.elapsed.inSeconds};
    _log(s, 'sha256 ${ok ? "일치" : "불일치!"} (${sw.elapsed.inSeconds}초)');
  }

  // ── 6. 모델 로드 + 추론 벤치 ─────────────────────────────────
  Future<void> _runBench() async {
    const s = '벤치';
    _clear(s);
    final before = await _stats.getMemoryInfo();
    _log(s, '로드 전 PSS ${before.appPssMb}MB / 가용 ${before.availMemMb}MB');
    final swLoad = Stopwatch()..start();
    try {
      final model = await FlutterGemma.getActiveModel(maxTokens: 1024);
      swLoad.stop();
      _log(s, '모델 로드: ${swLoad.elapsedMilliseconds}ms');
      final chat = await model.createChat(maxOutputTokens: 96);
      await chat.addQueryChunk(Message.text(
        text: '다음 앱들을 생활 카테고리 하나씩으로 분류해줘: 전화, 카카오톡, 유튜브',
        isUser: true,
      ));
      final swGen = Stopwatch()..start();
      int tokens = 0;
      int? firstTokenMs;
      await for (final r in chat.generateChatResponseAsync()) {
        if (r is TextResponse) {
          tokens++;
          firstTokenMs ??= swGen.elapsedMilliseconds;
        }
      }
      swGen.stop();
      final after = await _stats.getMemoryInfo();
      final tps = tokens / (swGen.elapsedMilliseconds / 1000);
      _results['bench'] = {
        'loadMs': swLoad.elapsedMilliseconds,
        'firstTokenMs': firstTokenMs,
        'tokens': tokens,
        'tokensPerSec': double.parse(tps.toStringAsFixed(1)),
        'pssBeforeMb': before.appPssMb,
        'pssAfterMb': after.appPssMb,
      };
      _log(s, '첫 토큰 ${firstTokenMs}ms, $tokens tok / ${swGen.elapsedMilliseconds}ms '
          '= ${tps.toStringAsFixed(1)} tok/s');
      _log(s, '로드 후 PSS ${after.appPssMb}MB (Δ${after.appPssMb - before.appPssMb}MB)');
      await model.close();
    } catch (e) {
      swLoad.stop();
      _results['bench'] = {'error': '$e'};
      _log(s, '실패: $e');
    }
  }

  // ── 결과 내보내기 ────────────────────────────────────────────
  Future<void> _export() async {
    final json = const JsonEncoder.withIndent('  ').convert(_results);
    await Clipboard.setData(ClipboardData(text: json));
    final dir = await getApplicationDocumentsDirectory();
    final f = File('${dir.path}/spike_result.json');
    await f.writeAsString(json);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('클립보드 복사 + 저장: ${f.path}')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('W1 스파이크'),
        actions: [
          IconButton(onPressed: _export, icon: const Icon(Icons.copy), tooltip: '결과 JSON'),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _section('기기', [_btn('기기 정보', _runDeviceInfo)]),
          _section('앱스캔', [_btn('앱 스캔 E2E', _runAppScan)]),
          _section('STT', [
            _btn('① 초기화', _runSttInit),
            _btn('② 일반 인식', () => _runSttListen(onDevice: false)),
            _btn('③ 온디바이스 인식', () => _runSttListen(onDevice: true)),
          ]),
          _section('TTS', [
            _btn('엔진·보이스 조회', _runTts),
            _btn('샘플 발화(0.7)', _speakSample),
          ]),
          _section('다운로드', [
            _btn('모델 다운로드(2.6GB)', _runDownload),
            _btn('sha256 검증', _runSha256),
          ]),
          _section('벤치', [_btn('모델 로드+추론', _runBench)]),
        ],
      ),
    );
  }

  Widget _btn(String label, VoidCallback onTap) => Padding(
        padding: const EdgeInsets.only(right: 8),
        child: FilledButton.tonal(onPressed: onTap, child: Text(label)),
      );

  Widget _section(String name, List<Widget> buttons) => Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              Wrap(runSpacing: 8, children: buttons),
              if ((_logs[name] ?? '').isNotEmpty)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(top: 8),
                  padding: const EdgeInsets.all(8),
                  color: Colors.black87,
                  child: Text(
                    _logs[name]!,
                    style: const TextStyle(
                      color: Colors.greenAccent,
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
}
