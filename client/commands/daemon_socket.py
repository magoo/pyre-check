# Copyright (c) Meta Platforms, Inc. and affiliates.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

from __future__ import annotations

import hashlib

import tempfile
from pathlib import Path
from typing import Iterable


# Socket path logic ---

MD5_LENGTH = 32


def get_md5(identifier_string: str) -> str:
    identifier_bytes = identifier_string.encode("utf-8")
    return hashlib.md5(identifier_bytes).hexdigest()


def get_socket_path(
    socket_root: Path,
    project_identifier: str,
) -> Path:
    """
    Determine where the server socket file is located. We can't directly use
    `log_directory` because of the ~100 character length limit on Unix socket
    file paths.
    """
    project_hash = get_md5(project_identifier)
    return socket_root / f"pyre_server_{project_hash}.sock"


def get_default_socket_root() -> Path:
    # TODO(T77556312): It might be cleaner to turn the root dir into a
    # configuration option instead.
    return Path(tempfile.gettempdir())


def get_default_socket_path(
    project_identifier: str,
) -> Path:
    return get_socket_path(get_default_socket_root(), project_identifier)


def socket_file_glob_pattern() -> str:
    md5_hash_pattern = "[0-9a-f]" * MD5_LENGTH
    return f"pyre_server_{md5_hash_pattern}.sock"


def find_socket_files(socket_root: Path) -> Iterable[Path]:
    return socket_root.glob(socket_file_glob_pattern())
