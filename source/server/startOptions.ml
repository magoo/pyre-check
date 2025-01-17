(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Base

module Watchman = struct
  type t = {
    root: PyrePath.t;
    raw: Watchman.Raw.t;
  }
end

type t = {
  environment_controls: Analysis.EnvironmentControls.t;
  source_paths: Configuration.SourcePaths.t;
  socket_path: PyrePath.t;
  watchman: Watchman.t option;
  build_system_initializer: BuildSystem.Initializer.t;
  critical_files: CriticalFile.t list;
  saved_state_action: SavedStateAction.t option;
  skip_initial_type_check: bool;
}
