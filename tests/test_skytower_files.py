"""Tests for FileAccessHandler — file:write and file:delete events."""
import pytest
from unittest.mock import MagicMock, patch


def _make_handler(emitted: list):
    """FileAccessHandler with a mock sio that records emitted events."""
    from skytower_plugin.skytower_files import FileAccessHandler

    sio = MagicMock()
    sio.connected = True

    async def _fake_emit(event, data):
        emitted.append((event, data))

    handler = FileAccessHandler(sio)
    handler._emit = _fake_emit
    return handler


# ---------------------------------------------------------------------------
# file:write
# ---------------------------------------------------------------------------

class TestHandleWrite:
    @pytest.mark.asyncio
    async def test_write_creates_file(self, tmp_path):
        emitted = []
        handler = _make_handler(emitted)
        target = tmp_path / "test.md"

        with patch("skytower_plugin.skytower_files.is_write_denied", return_value=False):
            await handler.handle_write({
                "request_id": "r1",
                "path": str(target),
                "content": "# Hello\nworld",
            })

        assert target.read_text(encoding="utf-8") == "# Hello\nworld"
        assert emitted == [("file:write_result", {"request_id": "r1", "success": True})]

    @pytest.mark.asyncio
    async def test_write_creates_parent_dirs(self, tmp_path):
        emitted = []
        handler = _make_handler(emitted)
        target = tmp_path / "a" / "b" / "c.md"

        with patch("skytower_plugin.skytower_files.is_write_denied", return_value=False):
            await handler.handle_write({
                "request_id": "r2",
                "path": str(target),
                "content": "content",
            })

        assert target.exists()
        assert emitted[0] == ("file:write_result", {"request_id": "r2", "success": True})

    @pytest.mark.asyncio
    async def test_write_overwrites_existing_file(self, tmp_path):
        emitted = []
        handler = _make_handler(emitted)
        target = tmp_path / "existing.md"
        target.write_text("old content", encoding="utf-8")

        with patch("skytower_plugin.skytower_files.is_write_denied", return_value=False):
            await handler.handle_write({
                "request_id": "r3",
                "path": str(target),
                "content": "new content",
            })

        assert target.read_text(encoding="utf-8") == "new content"
        assert emitted[0][1]["success"] is True

    @pytest.mark.asyncio
    async def test_write_error_on_empty_path(self):
        emitted = []
        handler = _make_handler(emitted)

        await handler.handle_write({"request_id": "r4", "path": "", "content": "x"})

        assert emitted[0] == ("file:write_result", {"request_id": "r4", "error": "path is required"})

    @pytest.mark.asyncio
    async def test_write_error_when_denied(self, tmp_path):
        emitted = []
        handler = _make_handler(emitted)

        with patch("skytower_plugin.skytower_files.is_write_denied", return_value=True):
            await handler.handle_write({
                "request_id": "r5",
                "path": str(tmp_path / "denied.md"),
                "content": "x",
            })

        assert "error" in emitted[0][1]
        assert "denied" in emitted[0][1]["error"].lower()

    @pytest.mark.asyncio
    async def test_write_error_when_too_large(self, tmp_path):
        emitted = []
        handler = _make_handler(emitted)

        from skytower_plugin.skytower_files import _MAX_WRITE_CHARS
        huge = "x" * (_MAX_WRITE_CHARS + 1)

        with patch("skytower_plugin.skytower_files.is_write_denied", return_value=False):
            await handler.handle_write({
                "request_id": "r6",
                "path": str(tmp_path / "huge.md"),
                "content": huge,
            })

        assert "error" in emitted[0][1]
        assert "large" in emitted[0][1]["error"].lower()

    @pytest.mark.asyncio
    async def test_write_error_on_non_string_content(self, tmp_path):
        emitted = []
        handler = _make_handler(emitted)

        with patch("skytower_plugin.skytower_files.is_write_denied", return_value=False):
            await handler.handle_write({
                "request_id": "r7",
                "path": str(tmp_path / "x.md"),
                "content": 12345,
            })

        assert "error" in emitted[0][1]

    @pytest.mark.asyncio
    async def test_write_request_id_echoed(self, tmp_path):
        emitted = []
        handler = _make_handler(emitted)

        with patch("skytower_plugin.skytower_files.is_write_denied", return_value=False):
            await handler.handle_write({
                "request_id": "unique-id-xyz",
                "path": str(tmp_path / "f.md"),
                "content": "ok",
            })

        assert emitted[0][1]["request_id"] == "unique-id-xyz"


# ---------------------------------------------------------------------------
# file:delete (existing handler — smoke tests)
# ---------------------------------------------------------------------------

class TestHandleDelete:
    @pytest.mark.asyncio
    async def test_delete_removes_file(self, tmp_path):
        emitted = []
        handler = _make_handler(emitted)
        target = tmp_path / "del.md"
        target.write_text("bye")

        with patch("skytower_plugin.skytower_files.is_write_denied", return_value=False):
            await handler.handle_delete({"request_id": "d1", "path": str(target)})

        assert not target.exists()
        assert emitted[0] == ("file:delete_result", {"request_id": "d1", "ok": True})

    @pytest.mark.asyncio
    async def test_delete_error_on_missing_file(self, tmp_path):
        emitted = []
        handler = _make_handler(emitted)

        with patch("skytower_plugin.skytower_files.is_write_denied", return_value=False):
            await handler.handle_delete({
                "request_id": "d2",
                "path": str(tmp_path / "ghost.md"),
            })

        assert "error" in emitted[0][1]

    @pytest.mark.asyncio
    async def test_delete_error_on_empty_path(self):
        emitted = []
        handler = _make_handler(emitted)

        await handler.handle_delete({"request_id": "d3", "path": ""})

        assert emitted[0] == ("file:delete_result", {"request_id": "d3", "error": "path is required"})


# ---------------------------------------------------------------------------
# file:list — 기준 폴더 (skytower #137)
# ---------------------------------------------------------------------------

class TestHandleList:
    """공유 방은 relay 가 작업 폴더를 ``root`` 로 보낸다. Windows 에서 홈(``C:/Users/x``) 밖에 있는
    작업 폴더(``D:/work/x``)가 홈으로 되돌려지던 문제를 홈과 작업 폴더를 서로 다른 tmp 폴더로 두고 재현한다."""

    @staticmethod
    def _dirs(tmp_path):
        home = tmp_path / "home"
        project = tmp_path / "work" / "project0"
        (home / "Documents").mkdir(parents=True)
        (project / "docs").mkdir(parents=True)
        (project / "README.md").write_text("hi")
        return home.resolve(), project.resolve()

    async def _list(self, data, home):
        emitted = []
        handler = _make_handler(emitted)
        with patch("skytower_plugin.skytower_files._session_cwd", return_value=home):
            await handler.handle_list({"request_id": "l1", **data})
        assert len(emitted) == 1 and emitted[0][0] == "file:list_result"
        return emitted[0][1]

    @staticmethod
    def _names(result):
        return sorted(e["name"] for e in result["entries"])

    @pytest.mark.asyncio
    async def test_without_root_project_outside_home_is_clamped_to_home(self, tmp_path):
        """예전 동작(그리고 root 를 모르는 옛 relay): 세션 기본 폴더 밖은 그 폴더로 되돌린다."""
        home, project = self._dirs(tmp_path)
        result = await self._list({"path": str(project)}, home)
        assert result["path"] == str(home)
        assert self._names(result) == ["Documents"]

    @pytest.mark.asyncio
    async def test_root_opens_project_folder_outside_home(self, tmp_path):
        home, project = self._dirs(tmp_path)
        result = await self._list({"path": str(project), "root": str(project)}, home)
        assert result["path"] == str(project)
        assert result["root"] == str(project)
        assert self._names(result) == ["README.md", "docs"], "no '..' at the root"

    @pytest.mark.asyncio
    async def test_root_accepts_forward_slashes(self, tmp_path):
        """relay 는 설정에 적힌 표기 그대로(`D:/work/x`) 보낸다."""
        home, project = self._dirs(tmp_path)
        fwd = str(project).replace("\\", "/")
        result = await self._list({"path": fwd, "root": fwd}, home)
        assert result["path"] == str(project)

    @pytest.mark.asyncio
    async def test_subfolder_has_parent_entry_up_to_root(self, tmp_path):
        home, project = self._dirs(tmp_path)
        result = await self._list({"path": str(project / "docs"), "root": str(project)}, home)
        assert result["path"] == str(project / "docs")
        assert result["entries"][0] == {"name": "..", "path": str(project), "type": "dir"}

    @pytest.mark.asyncio
    async def test_path_outside_root_is_clamped_to_root_not_home(self, tmp_path):
        home, project = self._dirs(tmp_path)
        result = await self._list({"path": str(home), "root": str(project)}, home)
        assert result["path"] == str(project)
        assert "Documents" not in self._names(result)

    @pytest.mark.asyncio
    async def test_missing_path_falls_back_to_root(self, tmp_path):
        home, project = self._dirs(tmp_path)
        result = await self._list({"path": str(project / "ghost"), "root": str(project)}, home)
        assert result["path"] == str(project)

    @pytest.mark.asyncio
    async def test_missing_root_is_an_error_not_home(self, tmp_path):
        """작업 폴더가 이 PC 에 없으면 홈 목록을 보여 주지 않는다 — 공유 방 멤버에게 작업 폴더 밖이 보인다."""
        home, _ = self._dirs(tmp_path)
        ghost = tmp_path / "work" / "nope"
        result = await self._list({"path": str(ghost), "root": str(ghost)}, home)
        assert "entries" not in result
        assert str(ghost) in result["error"]

    @pytest.mark.asyncio
    async def test_blank_root_means_session_default(self, tmp_path):
        home, _ = self._dirs(tmp_path)
        result = await self._list({"path": "~/", "root": "  "}, home)
        assert result["path"] == str(home)
