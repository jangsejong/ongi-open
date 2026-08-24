import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 코칭 세션 신호 — 어르신 기기 ↔ 릴레이 서버 ↔ 보호자 기기.
///
/// 서버는 **전달만** 한다(§10). 세션 성립 판정과 신뢰 앵커 검증은 기기가 하며,
/// 서버가 위조 메시지를 보내도 [CoachingController]가 거부한다(ADR-21).
///
/// FCM 대신 자체 WebSocket을 쓰는 이유: 요청 전달과 WebRTC 시그널링을 한 채널로
/// 처리해 단순하고, 외부 서비스 의존이 없어 대회 규정(소스 전체 공개)에 유리하다.
/// 대가는 보호자 앱이 foreground service로 연결을 유지해야 하는 배터리 비용이다.
class SignalMessage {
  const SignalMessage(this.type, this.data);

  final String type;
  final Map<String, dynamic> data;

  String? get sessionId => data['sessionId'] as String?;

  factory SignalMessage.fromJson(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      return const SignalMessage('invalid', {});
    }
    final type = decoded['type'];
    return SignalMessage(type is String ? type : 'invalid', decoded);
  }

  String toJson() => jsonEncode({'type': type, ...data});
}

/// 시그널링 전송 계층 — 테스트에서 가짜로 대체할 수 있도록 인터페이스로 둔다.
abstract class CoachingSignaling {
  Stream<SignalMessage> get messages;

  /// 연결 상태 — 끊기면 진행 중 세션은 즉시 종료해야 한다(§7).
  bool get connected;

  Future<void> connect({required String deviceKey, required String role});
  Future<void> send(SignalMessage message);
  Future<void> close();
}

/// dart:io WebSocket 구현.
///
/// **전송은 자동 복구하되 세션은 되살리지 않는다.** 끊김이 감지되면 먼저
/// `disconnected`를 흘려 진행 중 세션을 끝내고(§11 잔존 접근 차단), 그 뒤에
/// 소켓만 지수 백오프로 다시 붙인다. 재연결이 없으면 서버가 잠깐 내려간 것만으로
/// 앱을 다시 켜기 전까지 코칭이 영구 불가가 된다.
class WebSocketSignaling implements CoachingSignaling {
  WebSocketSignaling(this._resolveBaseUrl);

  /// 접속할 때마다 주소를 **다시 묻는다**. 주소를 필드로 들고 있으면 호출부가
  /// `is WebSocketSignaling`으로 구체 타입을 알아야 값을 넣을 수 있어, 전송 계층을
  /// 갈아 끼울 때 부트스트랩까지 따라 고쳐야 한다. 주소 해석은 전송 계층의 일이다.
  /// 예: `ws://192.0.2.10:8800`. **비어 있으면 접속하지 않는다**(설정 전 기본 상태).
  final String Function() _resolveBaseUrl;

  WebSocket? _socket;
  final _controller = StreamController<SignalMessage>.broadcast();

  String? _deviceKey;
  String? _role;
  Timer? _retry;
  int _attempt = 0;

  /// 사용자가 명시적으로 닫았으면 다시 붙지 않는다.
  bool _closed = false;

  /// connect·close 때마다 올라가는 세대 번호.
  ///
  /// `_open()`은 await를 두 번 넘기 때문에, 그 사이에 close()나 재connect가
  /// 일어나면 뒤늦게 완료된 옛 시도가 새 소켓을 덮어쓰거나 이미 닫은 연결을
  /// 되살릴 수 있다. 소켓을 대입하기 직전에 세대를 대조해 그런 시도를 버린다.
  int _epoch = 0;

  /// 재연결 간격 상한.
  ///
  /// 길게 잡는 이유가 있다. 코칭은 v1.2 로드맵이고 릴레이 기본 주소는 시연망을
  /// 가리키므로, **대부분의 기기에서는 릴레이가 아예 없다.** 그런 기기에서도
  /// 재시도는 멈추지 않는데(서버가 늦게 뜨는 시연을 살리려면 멈추면 안 된다),
  /// 간격이 짧으면 그 영원한 재시도가 그대로 상시 배터리·네트워크 부하가 된다.
  /// 5분이면 시연 복구는 충분히 빠르고 유휴 비용은 무시할 수준이다.
  static const _maxBackoff = Duration(minutes: 5);

  /// 재연결 대기 시간 — 1,2,4,…초로 늘리다 [_maxBackoff]에서 멈춘다.
  ///
  /// 상한에 닿는 단계까지 열어 두지 않으면 선언한 상한이 영영 쓰이지 않는다.
  static Duration backoffFor(int attempt) {
    final seconds = 1 << (attempt.clamp(1, 10) - 1);
    final delay = Duration(seconds: seconds);
    return delay > _maxBackoff ? _maxBackoff : delay;
  }

  @override
  Stream<SignalMessage> get messages => _controller.stream;

  @override
  bool get connected => _socket?.readyState == WebSocket.open;

  @override
  Future<void> connect({
    required String deviceKey,
    required String role,
  }) async {
    _deviceKey = deviceKey;
    _role = role;
    _closed = false;
    _attempt = 0;
    _epoch++;
    try {
      await _open();
    } catch (_) {
      // 최초 연결 실패도 재시도 대상이다. 서버가 아직 안 떴거나 부팅 직후 네트워크가
      // 늦게 붙는 경우가 흔한데, 여기서 포기하면 백오프가 "한 번 열린 뒤 끊긴" 소켓만
      // 커버해 앱을 다시 켜기 전까지 코칭이 영구 불가가 된다.
      _scheduleRetry();
      rethrow;
    }
  }

  Future<void> _open() async {
    final epoch = _epoch;
    _retry?.cancel();
    await _dropSocket();
    final baseUrl = _resolveBaseUrl();
    // 주소가 없으면 붙을 곳이 없다 — 실패로 처리해 재시도를 걸면, 코칭을 쓰지 않는
    // 기기(대부분)가 영원히 헛도는 재시도 루프를 안고 산다. 조용히 쉰다.
    if (baseUrl.isEmpty) return;
    final uri = Uri.parse('$baseUrl/ws?role=$_role&key=$_deviceKey');
    final pending = WebSocket.connect(uri.toString());
    final WebSocket socket;
    try {
      socket = await pending.timeout(const Duration(seconds: 10));
    } on TimeoutException {
      // 늦게 성공한 소켓을 방치하면 서버 레지스트리에서 같은 키로 등록돼 정상
      // 연결을 밀어낸다 — 어르신이 조용히 무응답이 된다.
      unawaited(pending.then<void>((zombie) async {
        try {
          await zombie.close();
        } catch (_) {}
      }).catchError((Object _) {}));
      rethrow;
    }
    // 이 시도가 뜨는 사이 close()나 재connect가 있었으면 방금 얻은 소켓은 남의
    // 것이다 — 대입하면 닫은 연결이 되살아나거나 새 소켓을 덮어쓴다.
    if (_closed || epoch != _epoch) {
      unawaited(socket.close().catchError((Object _) => null));
      return;
    }
    _socket = socket;
    _attempt = 0;
    socket.listen(
      (event) {
        if (event is String) _controller.add(SignalMessage.fromJson(event));
      },
      onDone: () => _onDropped(socket),
      onError: (_) => _onDropped(socket),
      cancelOnError: true,
    );
  }

  /// 끊김 통지가 먼저다 — 진행 중 세션이 살아 있는 채로 재연결되면 안 된다.
  void _onDropped(WebSocket socket) {
    // 교체하며 우리가 닫은 옛 소켓의 종료 통지는 무시한다. 받아들이면 방금 붙은
    // 정상 연결에 대고 재연결을 다시 걸어 churn이 된다.
    if (!identical(_socket, socket)) return;
    _socket = null;
    _controller.add(const SignalMessage('disconnected', {}));
    _scheduleRetry();
  }

  void _scheduleRetry() {
    if (_closed || _deviceKey == null || _resolveBaseUrl().isEmpty) return;
    _attempt++;
    final delay = backoffFor(_attempt);
    _retry?.cancel();
    _retry = Timer(delay, () async {
      if (_closed) return;
      try {
        await _open();
      } catch (_) {
        _scheduleRetry();
      }
    });
  }

  @override
  Future<void> send(SignalMessage message) async {
    final socket = _socket;
    if (socket == null || socket.readyState != WebSocket.open) {
      throw StateError('signaling not connected');
    }
    socket.add(message.toJson());
  }

  @override
  Future<void> close() async {
    _closed = true;
    _epoch++;
    _retry?.cancel();
    _retry = null;
    await _dropSocket();
  }

  Future<void> _dropSocket() async {
    final socket = _socket;
    _socket = null;
    if (socket != null) {
      try {
        await socket.close();
      } catch (_) {}
    }
  }
}
