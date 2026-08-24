"""온기 보호자 통화 코칭 릴레이 (docs/50_guardian_coaching.md §10).

서버는 **전달만** 한다. 세션 성립 판정도, 신뢰 앵커 검증도 기기가 하며,
이 프로세스는 어르신 데이터를 저장하지 않는다 — 메모리에 두는 것은 지금 붙어
있는 소켓의 기기 키뿐이고, 연결이 끊기면 사라진다.

의도적으로 하지 않는 것:
- 세션을 여는 것(ADR-17: 개시 권한은 어르신 기기에만 있다)
- 기기로 명령을 보내는 것(ADR-16: 쓰기 경로를 만들지 않는다)
- 화면 프레임 경유·저장(미디어는 P2P, 서버는 시그널링만)
"""

from __future__ import annotations

import asyncio
import json
import logging
import time
import uuid
from dataclasses import dataclass, field

from fastapi import FastAPI, Query, WebSocket, WebSocketDisconnect

log = logging.getLogger("ongi.relay")

app = FastAPI(title="온기 코칭 릴레이", version="0.1.0")

# 기기가 그대로 되던지는 시그널링 타입 — 이 목록에 없는 것은 버린다.
RELAY_TYPES = frozenset({"offer", "answer", "ice", "end", "accepted", "declined"})

# 페어링 응답은 상대 키가 아직 없는 상태에서 오가므로 별도로 다룬다.
PAIR_TYPES = frozenset({"pair_ok", "pair_no"})

# 페어링 자격 수명(초). 어르신 쪽이 60초에 스스로 포기하므로 그보다 조금 길게 —
# 그 사이 보호자가 재접속해도 수락이 살아 있고, 지나면 서버에서 사라진다.
PAIR_TTL = 90.0


def pairing_code(key: str) -> str:
    """앱이 보여주는 6자리 코드 — 통화 중 말로 불러 주는 것을 전제로 짧다."""
    return key[:6].upper()


def _mask(key: str) -> str:
    """로그용 축약 — 어느 기기인지 구분은 되되 키를 재구성할 수는 없게."""
    return f"{key[:4]}…({len(key)})" if key else "-"


@dataclass
class Peer:
    key: str
    role: str
    socket: WebSocket
    # 지금 이 피어가 대화 중인 상대 기기 키. 세션은 1:1만 허용한다.
    partner: str | None = None


@dataclass
class Registry:
    peers: dict[str, Peer] = field(default_factory=dict)
    lock: asyncio.Lock = field(default_factory=asyncio.Lock)

    # 보호자 키 → 그 보호자에게 등록 요청을 보낸 어르신 키.
    #
    # 응답(pair_ok/pair_no)은 요청을 실제로 받은 쪽만 보낼 수 있다 — 없으면 아무
    # 피어나 pair_ok를 쏴서 어르신의 신뢰 앵커를 자기 키로 오염시킬 수 있다(ADR-21).
    # **연결 객체가 아니라 키에 매단다.** 보호자가 확인 창을 띄운 채로 잠깐
    # 재접속하면(자동 재연결은 흔하다) 새 Peer에는 자격이 없어 수락이 조용히
    # 무시되기 때문이다. 1회용 보장은 응답 시 pop이 하고, 실효 수명은 어르신 쪽
    # 60초 타임아웃이 정한다.
    pending_pairs: dict[str, tuple[str, float]] = field(default_factory=dict)

    async def add(self, peer: Peer) -> Peer | None:
        """등록하고, 밀려난 옛 피어가 있으면 돌려준다.

        밀려난 소켓은 호출부가 닫아야 한다. 조용히 덮어쓰기만 하면, 늦게 도착한
        연결이 정상 연결을 레지스트리에서 밀어낸 뒤 스스로 정리되며 키를 통째로
        비우는 순서가 생긴다 — 소켓은 살아 있는데 아무도 찾을 수 없는 상태다.
        닫아 주면 밀려난 쪽이 끊김을 감지해 곧바로 다시 등록한다.
        """
        async with self.lock:
            old = self.peers.get(peer.key)
            self.peers[peer.key] = peer
            return old if old is not None and old is not peer else None

    async def drop(self, peer: Peer) -> Peer | None:
        """이 피어가 아직 등록된 당사자일 때만 지운다.

        키로만 지우면, 같은 키로 이미 재접속한 **새** 연결을 옛 핸들러가 뒤늦게
        정리하며 지워 버린다. 소켓은 열려 있는데 레지스트리에 없어 어르신이
        조용히 무응답이 되는 경로다(자동 재연결과 겹치면 흔하게 일어난다).
        """
        async with self.lock:
            if self.peers.get(peer.key) is not peer:
                return None
            return self.peers.pop(peer.key, None)

    def get(self, key: str) -> Peer | None:
        return self.peers.get(key)

    def by_code(self, code: str) -> Peer | None:
        """페어링 코드로 상대를 찾는다 — 등록(사전 A) 때만 쓰는 경로.

        후보가 둘이면 **아무도 돌려주지 않는다.** 코드는 키 앞 6자라 서로 다른 키가
        같은 코드로 풀릴 수 있는데, 그때 먼저 들어온 피어를 고르면 삽입 순서가
        신뢰 앵커의 주인을 정하게 된다(ADR-21). 잘못 이어 주느니 실패한다.
        """
        wanted = code.strip().upper()
        found = [
            peer for peer in self.peers.values() if pairing_code(peer.key) == wanted
        ]
        return found[0] if len(found) == 1 else None

    def code_conflict(self, key: str) -> bool:
        """이미 붙어 있는 **다른** 키가 같은 페어링 코드로 풀리는가.

        키는 클라이언트가 정하는 값이라 앞 6자를 남의 코드에 맞춰 접속할 수 있다.
        그러면 어르신이 입력한 코드가 공격자에게 풀리고, 기기 쪽 대조(코드 앞 6자)도
        같은 값이라 통과한다 — 앵커가 공격자 키로 굳는다. 겹치는 접속을 아예 받지
        않아 이 경로를 닫는다(같은 키의 재접속은 겹침이 아니다).
        """
        code = pairing_code(key)
        return any(
            other.key != key and pairing_code(other.key) == code
            for other in self.peers.values()
        )


registry = Registry()


async def _send(peer: Peer, payload: dict) -> None:
    try:
        await peer.socket.send_text(json.dumps(payload, ensure_ascii=False))
    except Exception:  # 상대가 이미 끊긴 경우 — 조용히 넘긴다.
        log.debug("send failed to %s", _mask(peer.key))


@app.get("/health")
async def health() -> dict:
    return {"ok": True, "peers": len(registry.peers)}


@app.websocket("/ws")
async def ws(
    socket: WebSocket,
    role: str = Query(default="elder"),
    key: str = Query(default=""),
) -> None:
    """기기 하나의 상시 연결.

    `key`는 등록 시 어르신·보호자가 교환한 앱 인스턴스 키다. 서버는 이 값으로
    라우팅만 하고 진위를 판정하지 않는다 — 위조된 수락은 어르신 기기의
    CoachingController가 걸러낸다(ADR-21). 서버를 신뢰하지 않는 설계다.
    """
    if not key:
        await socket.close(code=4000)
        return
    if registry.code_conflict(key):
        # 같은 코드로 풀리는 키가 이미 붙어 있다 — 어르신이 코드를 입력했을 때
        # 누가 진짜인지 서버도 기기도 가릴 수 없다. 이어 주지 않고 거절한다.
        await socket.close(code=4002)
        return

    await socket.accept()
    peer = Peer(key=key, role=role, socket=socket)
    displaced = await registry.add(peer)
    if displaced is not None:
        await displace(displaced)
    # 기기 키는 신뢰 앵커이자 사실상 bearer 자격증명이다 — 평문으로 남기지 않는다.
    log.info("connected key=%s role=%s", _mask(key), role)

    try:
        while True:
            raw = await socket.receive_text()
            try:
                message = json.loads(raw)
            except json.JSONDecodeError:
                continue
            if not isinstance(message, dict):
                continue
            await _handle(peer, message)
    except WebSocketDisconnect:
        pass
    finally:
        await cleanup(peer)


async def _release_session(peer: Peer) -> None:
    """이 피어가 물고 있던 세션을 끝낸다 — 상대에게 알리고 링크를 푼다."""
    partner = registry.get(peer.partner) if peer.partner else None
    peer.partner = None
    # 상대가 나를 상대로 알고 있을 때만 끊는다 — 이미 다른 세션으로 넘어간
    # 피어의 진행 중 통화를 옛 연결의 정리가 끊어 버리면 안 된다.
    if partner is not None and partner.partner == peer.key:
        partner.partner = None
        # 상대가 사라지면 세션은 재연결이 아니라 종료다 — 잔존 접근을 남기지
        # 않는다(§11). 기기 쪽에서 즉시 공유를 내린다.
        await _send(partner, {"type": "disconnected"})


def _prune_pending(now: float | None = None) -> None:
    """수명이 다한 페어링 자격만 지운다.

    **끊김만으로 지우면 안 된다.** 자격을 연결 객체가 아니라 키에 매단 이유가
    "확인 창을 띄운 채 잠깐 재접속해도 수락이 살아 있게" 하려는 것인데, 끊길 때
    지워 버리면 그 설계가 그대로 무효가 된다(자동 재연결은 흔하다).

    그렇다고 남겨 두지도 않는다 — 값이 기기 키라 "붙어 있는 소켓의 것만 두고
    사라진다"는 §10의 약속을 지켜야 한다. 그래서 만료로 처리한다. 어르신 쪽이
    60초에 스스로 포기하므로 그보다 조금 긴 수명이면 충분하다.
    """
    limit = now if now is not None else time.monotonic()
    for guardian_key, (_, expires) in list(registry.pending_pairs.items()):
        if expires <= limit:
            del registry.pending_pairs[guardian_key]


async def displace(old: Peer) -> None:
    """같은 키로 새 연결이 들어와 밀려난 소켓을 정리한다.

    **세션까지 끝내야 한다.** 소켓만 닫으면 상대(대개 어르신)는 종료 통지를 받지
    못한 채 캡처와 상시 알림을 계속 돌리고, 새 연결은 partner가 비어 있어 끊기
    버튼조차 그 상대에게 닿지 않는다. 밀려난 쪽의 링크도 남아 그 보호자가 다른
    어르신에게 영영 busy로 보인다. 클라이언트는 끊기면 세션을 접으므로(§7),
    이어 붙이지 않고 끝내는 쪽이 양쪽 상태와 맞다.
    """
    await _release_session(old)
    # 최신 등록이 이긴다는 것을 밀려난 쪽에도 알린다. 안 닫으면 그쪽은 자기가
    # 여전히 연결됐다고 믿은 채 아무 메시지도 받지 못한다.
    try:
        await old.socket.close(code=4001)
    except Exception:
        log.debug("close displaced failed key=%s", _mask(old.key))


async def cleanup(peer: Peer) -> None:
    """연결 하나가 끝났을 때의 정리 — 테스트가 직접 부를 수 있게 빼 둔다."""
    # 내가 아직 등록된 당사자였을 때만 세션까지 정리한다. 스테일 핸들러(같은
    # 키로 이미 재접속이 끝난 뒤 뒤늦게 죽는 옛 연결)가 여기를 통과하면, 방금
    # 성립한 **새** 세션의 링크를 지우고 상대에게만 끊김을 보낸다 — 어르신은
    # 통지를 못 받아 "보고 있어요"로 남는, 이 정리가 막으려던 바로 그 상태다.
    # (재접속으로 밀려난 경우는 displace가 이미 끝냈다.)
    dropped = await registry.drop(peer)
    if dropped is not None:
        await _release_session(peer)
        _prune_pending()
    log.info("disconnected key=%s", _mask(peer.key))


async def _handle(peer: Peer, message: dict) -> None:
    kind = message.get("type")

    if kind == "help_request":
        # 어르신이 지목한 보호자에게만 전달한다. 서버가 대상을 고르지 않는다.
        # 문자열로 좁히지 않으면 dict 같은 값이 그대로 dict 조회에 들어가 핸들러가
        # TypeError로 죽는다 — 잘못된 필드 하나가 진행 중 코칭을 끊는 경로다.
        target_key = str(message.get("toDeviceKey") or "")
        target = registry.get(target_key)
        if target is None:
            await _send(peer, {"type": "declined", "reason": "offline"})
            return
        # 세션은 1:1이다. 이미 다른 기기와 이어져 있으면 기존 연결을 덮어쓰지 않고
        # 거절한다. 덮어쓰면 진행 중 코칭의 시그널링이 새 요청자 쪽으로 새고,
        # 밀려난 어르신은 종료 통지를 받지 못해 화면 공유가 계속 나간다(§11).
        if target.partner not in (None, peer.key) or peer.partner not in (
            None,
            target_key,
        ):
            await _send(peer, {"type": "declined", "reason": "busy"})
            return
        session_id = uuid.uuid4().hex
        peer.partner = target_key
        target.partner = peer.key
        await _send(
            target,
            {
                "type": "help_request",
                "sessionId": session_id,
                "fromDeviceKey": peer.key,
            },
        )
        return

    if kind == "pair_request":
        # 사전 A(등록) — 어르신 폰에 보호자의 6자리 코드를 입력해 키를 교환한다.
        # 서버는 코드를 풀어 전달만 하고, 무엇을 등록할지는 기기가 정한다.
        target = registry.by_code(str(message.get("code", "")))
        if target is None:
            await _send(peer, {"type": "pair_no", "reason": "offline"})
            return
        # 응답할 자격을 이 시점에 기록한다 — 요청을 받은 쪽만 답할 수 있다.
        registry.pending_pairs[target.key] = (peer.key, time.monotonic() + PAIR_TTL)
        await _send(
            target,
            {
                "type": "pair_request",
                "fromDeviceKey": peer.key,
                "elderName": message.get("elderName", ""),
            },
        )
        return

    if kind in PAIR_TYPES:
        target_key = str(message.get("toDeviceKey", ""))
        # 그 어르신의 등록 요청을 실제로 받은 쪽만 응답으로 인정한다. 이 검사가
        # 없으면 어르신 키를 아는 아무 피어나 pair_ok를 쏴서, 서버가 확정해 넣는
        # guardianDeviceKey에 자기 키를 실어 신뢰 앵커를 가로챌 수 있다(ADR-21).
        entry = registry.pending_pairs.get(peer.key)
        if entry is None or entry[0] != target_key or entry[1] <= time.monotonic():
            return
        target = registry.get(target_key)
        if target is None:
            return
        registry.pending_pairs.pop(peer.key, None)
        forwarded = dict(message)
        # 등록될 키를 서버가 확정해 넣는다 — 보내는 쪽이 남의 키를 주장할 수 없다.
        forwarded["guardianDeviceKey"] = peer.key
        await _send(target, forwarded)
        return

    if kind in RELAY_TYPES:
        partner = registry.get(peer.partner) if peer.partner else None
        # 상대도 나를 상대로 알고 있을 때만 전달한다(cleanup과 같은 조건). 한쪽만
        # 남은 스테일 링크로 보내면, 그 상대가 이미 열어 둔 **다른** 세션에 end가
        # 꽂혀 무관한 통화가 끊긴다 — 밀려난 어르신은 통지도 못 받는다.
        if partner is None or partner.partner != peer.key:
            return
        # 보내는 쪽 키를 서버가 덮어써 스푸핑을 줄인다. 그래도 최종 검증은 기기가 한다.
        forwarded = dict(message)
        if kind == "accepted":
            forwarded["guardianDeviceKey"] = peer.key
        forwarded["fromDeviceKey"] = peer.key
        await _send(partner, forwarded)
        # 거절도 세션의 끝이다 — 링크를 남기면 무관한 상대의 접속 종료가 나중에
        # 다른 세션을 끊거나, 남은 링크 때문에 새 요청이 busy로 막힌다.
        if kind in ("end", "declined"):
            partner.partner = None
            peer.partner = None
