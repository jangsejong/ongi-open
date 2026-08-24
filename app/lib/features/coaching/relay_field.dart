import 'package:flutter/material.dart';

import 'device_identity.dart';

/// 릴레이 주소 입력 — 어르신 설정(보호자 정하기)과 보호자 홈 양쪽에서 쓴다.
///
/// **두 역할 모두에 있어야 한다.** 주소 상수를 코드에서 없앤 뒤로 이 입력이 유일한
/// 입구인데, 보호자 기기는 보호자 홈에서 다른 화면으로 갈 수 없다 — 여기에 없으면
/// 그 기기는 주소를 넣을 방법이 없어 코칭이 영구 미연결이 된다.
///
/// 어르신 쪽에서 이 입력이 일반 설정이 아니라 **보호자 등록 화면** 아래에 있는 이유:
/// 그 화면은 "최초 등록을 가족이 대신 한다"가 설계 전제이고(50_ §3 사전 A), 서버 주소를
/// 아는 사람도 정확히 그 사람이다. 접힌 상태로 두어 어르신 눈에는 걸리지 않게 한다.
///
/// 저장하면 [DeviceIdentity]가 알리고 루트 게이트가 새 주소로 다시 붙으므로,
/// 이 위젯은 재접속을 스스로 챙기지 않는다.
class RelayField extends StatefulWidget {
  const RelayField({super.key, required this.identity, this.dense = false});

  final DeviceIdentity identity;

  /// 보호자 홈은 시니어 제약(22sp·60dp) 대상이 아니라 조금 조밀하게 그린다(ADR-20).
  final bool dense;

  @override
  State<RelayField> createState() => _RelayFieldState();
}

class _RelayFieldState extends State<RelayField> {
  late final TextEditingController _ctl =
      TextEditingController(text: widget.identity.relayUrl);

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final messenger = ScaffoldMessenger.of(context);
    final cleared = _ctl.text.trim().isEmpty;
    await widget.identity.setRelayUrl(_ctl.text);
    if (!mounted) return;
    setState(() {});
    messenger.showSnackBar(
      SnackBar(
        content: Text(cleared ? '연결 서버를 지웠어요.' : '연결 서버를 바꿨어요.'),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final url = widget.identity.relayUrl;
    return Theme(
      // 접힘 위젯의 기본 구분선을 없애 목록과 섞이지 않게 한다.
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        title: Text('연결 서버 설정', style: text.bodyMedium),
        subtitle: Text(
          url.isEmpty ? '아직 설정하지 않았어요' : url,
          style: text.bodySmall,
        ),
        children: [
          TextField(
            controller: _ctl,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: '릴레이 주소',
              hintText: 'wss://relay.example.com',
              helperText: '비워 두면 코칭 연결을 시도하지 않아요',
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: widget.dense ? 48 : 56,
            child: FilledButton(onPressed: _save, child: const Text('저장')),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
