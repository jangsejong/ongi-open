"""릴레이 라우팅 규칙의 회귀 테스트.

서버는 전달만 하지만, **누구에게** 전달하느냐가 곧 안전 속성이다. 여기서 고정하는
것은 셋이다: 페어링 응답 자격(ADR-21 앵커 오염 차단), 1:1 세션 불변식(진행 중
세션을 새 요청이 밀어내지 못한다), 그리고 재접속 시 등록이 지워지지 않는 것.

실행: `.venv/bin/pytest server/test_relay.py`
"""

from __future__ import annotations

import asyncio
import json
import sys
import time
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))

from main import (  # noqa: E402
    PAIR_TTL,
    Peer,
    Registry,
    _handle,
    _prune_pending,
    cleanup,
    displace,
    registry,
)


class FakeSocket:
    """send_text만 받아 두는 소켓 대역 — 네트워크 없이 라우팅만 본다."""

    def __init__(self) -> None:
        self.received: list[dict] = []
        self.closed: int | None = None

    async def send_text(self, raw: str) -> None:
        self.received.append(json.loads(raw))

    async def close(self, code: int = 1000) -> None:
        self.closed = code


def _peer(key: str, role: str = "elder") -> Peer:
    return Peer(key=key, role=role, socket=FakeSocket())


@pytest.fixture(autouse=True)
def _clean_registry():
    registry.peers.clear()
    registry.pending_pairs.clear()
    yield
    registry.peers.clear()
    registry.pending_pairs.clear()


async def _add(*peers: Peer) -> None:
    for peer in peers:
        await registry.add(peer)


def run(coro):
    return asyncio.run(coro)


# 보호자 키 앞 6자가 어르신이 입력하는 페어링 코드가 된다.
GUARDIAN_KEY = "gkey01abcdefghijklmnopqrst"
ELDER_KEY = "elder1abcdefghijklmnopqrst"
ATTACKER_KEY = "zzzz99abcdefghijklmnopqrst"


class TestPairingAuthority:
    """등록 요청을 받은 피어만 응답할 수 있다 — 앵커 오염 차단."""

    def test_pair_ok_from_uninvolved_peer_is_dropped(self):
        async def scenario():
            elder, attacker = _peer(ELDER_KEY), _peer(ATTACKER_KEY, "guardian")
            await _add(elder, attacker)
            # 어르신 키만 알면 되던 주입 — 요청을 받은 적이 없으니 버려져야 한다.
            await _handle(attacker, {"type": "pair_ok", "toDeviceKey": ELDER_KEY})
            return elder.socket.received

        assert run(scenario()) == []

    def test_pair_ok_from_the_asked_peer_is_forwarded(self):
        async def scenario():
            elder = _peer(ELDER_KEY)
            guardian = _peer(GUARDIAN_KEY, "guardian")
            await _add(elder, guardian)
            await _handle(elder, {"type": "pair_request", "code": "GKEY01"})
            await _handle(guardian, {"type": "pair_ok", "toDeviceKey": ELDER_KEY})
            return elder.socket.received

        received = run(scenario())
        assert [m["type"] for m in received] == ["pair_ok"]
        # 등록될 키는 서버가 확정해 넣는다 — 보내는 쪽이 남의 키를 주장할 수 없다.
        assert received[0]["guardianDeviceKey"] == GUARDIAN_KEY

    def test_pairing_authority_is_single_use(self):
        async def scenario():
            elder = _peer(ELDER_KEY)
            guardian = _peer(GUARDIAN_KEY, "guardian")
            await _add(elder, guardian)
            await _handle(elder, {"type": "pair_request", "code": "GKEY01"})
            await _handle(guardian, {"type": "pair_ok", "toDeviceKey": ELDER_KEY})
            await _handle(guardian, {"type": "pair_ok", "toDeviceKey": ELDER_KEY})
            return elder.socket.received

        assert len(run(scenario())) == 1


class TestOneToOneSession:
    """진행 중 세션을 새 요청이 밀어내지 못한다."""

    def test_second_elder_is_declined_not_swapped_in(self):
        async def scenario():
            a, b = _peer("elderA"), _peer("elderB")
            guardian = _peer(GUARDIAN_KEY, "guardian")
            await _add(a, b, guardian)
            await _handle(a, {"type": "help_request", "toDeviceKey": GUARDIAN_KEY})
            await _handle(b, {"type": "help_request", "toDeviceKey": GUARDIAN_KEY})
            return a, b, guardian

        a, b, guardian = run(scenario())
        assert guardian.partner == "elderA", "진행 중 상대가 바뀌면 안 된다"
        assert a.partner == GUARDIAN_KEY
        assert b.socket.received[-1]["type"] == "declined"
        # 밀려난 쪽이 없으므로 A는 계속 시그널링을 받는다.
        assert len(guardian.socket.received) == 1

    def test_declined_releases_the_link(self):
        async def scenario():
            elder = _peer(ELDER_KEY)
            guardian = _peer(GUARDIAN_KEY, "guardian")
            await _add(elder, guardian)
            await _handle(elder, {"type": "help_request", "toDeviceKey": GUARDIAN_KEY})
            await _handle(guardian, {"type": "declined", "sessionId": "s1"})
            return elder, guardian

        elder, guardian = run(scenario())
        assert elder.partner is None
        assert guardian.partner is None

    def test_end_releases_the_link(self):
        async def scenario():
            elder = _peer(ELDER_KEY)
            guardian = _peer(GUARDIAN_KEY, "guardian")
            await _add(elder, guardian)
            await _handle(elder, {"type": "help_request", "toDeviceKey": GUARDIAN_KEY})
            await _handle(guardian, {"type": "end", "sessionId": "s1"})
            return elder, guardian

        elder, guardian = run(scenario())
        assert elder.partner is None and guardian.partner is None

    def test_end_without_session_id_still_reaches_the_partner(self):
        """수락 전 취소 — 세션 ID가 없어도 보호자 벨이 멈춰야 한다."""

        async def scenario():
            elder = _peer(ELDER_KEY)
            guardian = _peer(GUARDIAN_KEY, "guardian")
            await _add(elder, guardian)
            await _handle(elder, {"type": "help_request", "toDeviceKey": GUARDIAN_KEY})
            await _handle(elder, {"type": "end", "reason": "elderEnded"})
            return guardian.socket.received

        assert [m["type"] for m in run(scenario())] == ["help_request", "end"]


class TestReconnect:
    """같은 키로 재접속해도 새 등록이 살아 있어야 한다."""

    def test_stale_handler_cleanup_keeps_the_new_registration(self):
        async def scenario():
            old = _peer(ELDER_KEY)
            new = _peer(ELDER_KEY)
            await _add(old)
            await _add(new)  # 자동 재연결
            await cleanup(old)  # 뒤늦게 정리되는 옛 핸들러
            return registry.get(ELDER_KEY)

        assert run(scenario()) is not None, "새 연결이 지워지면 조용히 무응답이 된다"

    def test_dropping_the_current_peer_still_works(self):
        async def scenario():
            peer = _peer(ELDER_KEY)
            await _add(peer)
            await registry.drop(peer)
            return registry.get(ELDER_KEY)

        assert run(scenario()) is None

    def test_add_reports_the_displaced_peer(self):
        """밀려난 소켓은 호출부가 닫아야 한다 — 안 닫으면 그쪽은 자기가 연결된 줄 안다."""

        async def scenario():
            old, new = _peer(ELDER_KEY), _peer(ELDER_KEY)
            first = await registry.add(old)
            second = await registry.add(new)
            return first, second, registry.get(ELDER_KEY)

        first, second, current = run(scenario())
        assert first is None, "처음 등록에는 밀려난 피어가 없다"
        assert second is not None and second.socket is not current.socket
        assert current is not None

    def test_stale_handler_does_not_tear_down_the_new_session(self):
        """옛 핸들러가 뒤늦게 죽어도 새로 성립한 세션을 끊으면 안 된다.

        순단 → 즉시 재접속 → 새 세션 성립 → 수십 초 뒤 옛 소켓의 종료가 발화하는
        순서다. 여기서 파트너 링크를 지우면 보호자만 끊기고 어르신은 통지를 받지
        못해 "보고 있어요"로 남는다 — 이 정리가 막으려던 바로 그 상태다.
        """

        async def scenario():
            old = _peer(ELDER_KEY)
            guardian = _peer(GUARDIAN_KEY, "guardian")
            await _add(old, guardian)
            await _handle(old, {"type": "help_request", "toDeviceKey": GUARDIAN_KEY})

            # 같은 키로 재접속해 새 세션을 세운다.
            new = _peer(ELDER_KEY)
            await registry.add(new)
            await _handle(new, {"type": "help_request", "toDeviceKey": GUARDIAN_KEY})

            # 옛 핸들러가 뒤늦게 정리된다(ws() finally가 부르는 바로 그 경로).
            await cleanup(old)
            return guardian, new

        guardian, new = run(scenario())
        assert guardian.partner == ELDER_KEY, "새 세션 링크가 살아 있어야 한다"
        assert new.partner == GUARDIAN_KEY
        assert [m["type"] for m in guardian.socket.received] == [
            "help_request",
            "help_request",
        ], "스테일 정리가 disconnected를 보내면 안 된다"


class TestDisplacedSession:
    """재접속으로 밀려난 연결은 세션까지 끝내야 한다.

    소켓만 닫으면 상대는 끊긴 줄 모른 채 캡처와 상시 알림을 계속 돌리고, 새
    연결에는 partner가 없어 끊기 버튼도 그 상대에게 닿지 않는다.
    """

    def test_partner_is_notified_when_a_peer_is_displaced(self):
        async def scenario():
            elder = _peer(ELDER_KEY)
            guardian = _peer(GUARDIAN_KEY, "guardian")
            await _add(elder, guardian)
            await _handle(elder, {"type": "help_request", "toDeviceKey": GUARDIAN_KEY})

            # 보호자가 순단 후 같은 키로 재접속 — ws()가 밟는 경로 그대로.
            reconnected = _peer(GUARDIAN_KEY, "guardian")
            old = await registry.add(reconnected)
            await displace(old)
            return elder

        elder = run(scenario())
        assert elder.socket.received[-1]["type"] == "disconnected"
        assert elder.partner is None, (
            "링크가 남으면 그 보호자가 계속 통화 중으로 보인다"
        )

    def test_displaced_link_does_not_keep_the_guardian_busy(self):
        """어르신 쪽 순단 한 번이 그 보호자를 다른 어르신에게 영구 busy로 만들면 안 된다."""

        async def scenario():
            elder, other = _peer(ELDER_KEY), _peer("elderB")
            guardian = _peer(GUARDIAN_KEY, "guardian")
            await _add(elder, other, guardian)
            await _handle(elder, {"type": "help_request", "toDeviceKey": GUARDIAN_KEY})

            reconnected = _peer(ELDER_KEY)
            await displace(await registry.add(reconnected))

            await _handle(other, {"type": "help_request", "toDeviceKey": GUARDIAN_KEY})
            return other, guardian

        other, guardian = run(scenario())
        assert other.socket.received == [], "busy 거절이 오면 안 된다"
        assert guardian.partner == "elderB"

    def test_stale_link_cannot_end_someone_elses_session(self):
        """한쪽만 남은 링크로 보낸 end가 남의 통화를 끊으면 안 된다."""

        async def scenario():
            stale, other = _peer(ELDER_KEY), _peer("elderB")
            guardian = _peer(GUARDIAN_KEY, "guardian")
            await _add(stale, other, guardian)
            # 스테일 상태를 직접 만든다 — 어르신만 옛 세션을 가리키고 있다.
            stale.partner = GUARDIAN_KEY
            await _handle(other, {"type": "help_request", "toDeviceKey": GUARDIAN_KEY})
            guardian.socket.received.clear()

            await _handle(stale, {"type": "end", "reason": "elderEnded"})
            return guardian, other

        guardian, other = run(scenario())
        assert guardian.socket.received == [], "무관한 세션으로 새면 안 된다"
        assert guardian.partner == "elderB" and other.partner == GUARDIAN_KEY


class TestPairingCodeCollision:
    """코드는 키 앞 6자다 — 겹치는 키로는 붙지 못하게 막는다."""

    def test_conflicting_prefix_is_refused(self):
        async def scenario():
            reg = Registry()
            await reg.add(_peer(GUARDIAN_KEY, "guardian"))
            forged = "gkey01zzzzzzzzzzzzzzzzzzzz"
            return (
                reg.code_conflict(forged),
                reg.code_conflict(GUARDIAN_KEY),
                reg.code_conflict(ELDER_KEY),
            )

        forged, same_key, unrelated = run(scenario())
        assert forged is True, "코드를 맞춘 키가 붙으면 앵커를 가로챌 수 있다"
        assert same_key is False, "같은 키의 재접속은 겹침이 아니다"
        assert unrelated is False

    def test_ambiguous_code_resolves_to_nobody(self):
        async def scenario():
            reg = Registry()
            await reg.add(_peer(GUARDIAN_KEY, "guardian"))
            # code_conflict를 우회해 들어온 경우까지 가정한다 — 순서로 승자를
            # 정하느니 아무도 돌려주지 않는다.
            await reg.add(_peer("gkey01zzzzzzzzzzzzzzzzzzzz", "guardian"))
            return reg.by_code("GKEY01")

        assert run(scenario()) is None


class TestSessionHygiene:
    """끊기면 사라진다 — 서버가 들고 있겠다고 한 것 이상을 남기지 않는다."""

    def test_pending_pairing_authority_survives_a_disconnect_then_expires(self):
        """끊김만으로 지우지 않는다 — 자동 재연결 중에도 수락이 살아 있어야 한다.

        대신 영구히 두지도 않는다. 수명이 지나면 서버에서 사라진다(§10 저장 0).
        """

        async def scenario():
            elder = _peer(ELDER_KEY)
            guardian = _peer(GUARDIAN_KEY, "guardian")
            await _add(elder, guardian)
            await _handle(elder, {"type": "pair_request", "code": "GKEY01"})
            # 보호자 소켓이 잠깐 끊긴다 — 재접속이면 수락이 살아 있어야 한다.
            await cleanup(guardian)
            alive = dict(registry.pending_pairs)
            # 수명이 지난 뒤의 정리.
            _prune_pending(now=time.monotonic() + PAIR_TTL + 1)
            return alive, dict(registry.pending_pairs)

        alive, expired = run(scenario())
        assert GUARDIAN_KEY in alive, "끊김만으로 지우면 재접속 후 수락이 버려진다"
        assert expired == {}, "수명이 지나면 남지 않는다"

    def test_reconnected_guardian_can_accept_after_a_disconnect(self):
        """끊김을 서버가 관측한 뒤 재접속해도 수락이 전달돼야 한다."""

        async def scenario():
            elder = _peer(ELDER_KEY)
            guardian = _peer(GUARDIAN_KEY, "guardian")
            await _add(elder, guardian)
            await _handle(elder, {"type": "pair_request", "code": "GKEY01"})
            await cleanup(guardian)  # 소켓이 끊긴 것을 서버가 본다
            reconnected = _peer(GUARDIAN_KEY, "guardian")
            await registry.add(reconnected)
            await _handle(reconnected, {"type": "pair_ok", "toDeviceKey": ELDER_KEY})
            return elder.socket.received

        received = run(scenario())
        assert [m["type"] for m in received] == ["pair_ok"]
        assert received[0]["guardianDeviceKey"] == GUARDIAN_KEY

    def test_requesting_elder_leaves_nothing_behind(self):
        async def scenario():
            elder = _peer(ELDER_KEY)
            guardian = _peer(GUARDIAN_KEY, "guardian")
            await _add(elder, guardian)
            await _handle(elder, {"type": "pair_request", "code": "GKEY01"})
            await cleanup(elder)
            _prune_pending(now=time.monotonic() + PAIR_TTL + 1)
            return dict(registry.pending_pairs)

        assert run(scenario()) == {}

    def test_non_string_target_does_not_kill_the_handler(self):
        """필드 하나가 잘못 와도 진행 중 연결이 끊기면 안 된다."""

        async def scenario():
            elder = _peer(ELDER_KEY)
            await _add(elder)
            await _handle(elder, {"type": "help_request", "toDeviceKey": {"a": 1}})
            return elder.socket.received

        assert [m["type"] for m in run(scenario())] == ["declined"]


class TestPairingAcrossReconnect:
    """페어링 자격은 연결이 아니라 키에 붙는다 — 확인 창 중 재접속은 흔하다."""

    def test_reconnected_guardian_can_still_accept(self):
        async def scenario():
            elder = _peer(ELDER_KEY)
            guardian = _peer(GUARDIAN_KEY, "guardian")
            await _add(elder, guardian)
            await _handle(elder, {"type": "pair_request", "code": "GKEY01"})

            # 보호자가 확인 창을 띄운 채 자동 재연결(새 Peer 객체).
            reconnected = _peer(GUARDIAN_KEY, "guardian")
            await registry.add(reconnected)
            await _handle(reconnected, {"type": "pair_ok", "toDeviceKey": ELDER_KEY})
            return elder.socket.received

        received = run(scenario())
        assert [m["type"] for m in received] == ["pair_ok"]
        assert received[0]["guardianDeviceKey"] == GUARDIAN_KEY


def test_registry_by_code_matches_key_prefix():
    async def scenario():
        reg = Registry()
        guardian = _peer(GUARDIAN_KEY, "guardian")
        await reg.add(guardian)
        return reg.by_code("gkey01"), reg.by_code("NOPE00")

    found, missing = run(scenario())
    assert found is guardian_key_holder(found)
    assert missing is None


def guardian_key_holder(peer):
    """가독성용 — by_code가 돌려준 피어가 그 키의 주인인지 확인한다."""
    assert peer is not None and peer.key == GUARDIAN_KEY
    return peer
