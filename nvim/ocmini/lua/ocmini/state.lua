-- Shared mutable state.
--
-- `windows` is part of the surface experiments/floatbench_opencode.lua reads, so
-- `output_win` / `input_win` / `position` must keep their names.

local M = {}

---@class OcminiWindows
---@field output_win integer|nil Transcript float.
---@field input_win integer|nil Prompt float.
---@field position "float"|"split" Remembered layout so a hidden session reopens correctly.

---@type OcminiWindows
M.windows = {
  output_win = nil,
  input_win = nil,
  position = "float",
}

---@class OcminiState
---@field session table|nil Current session (the unwrapped Session.Info).
---@field session_id string|nil
---@field title string|nil
---@field streaming boolean Is the assistant currently producing output?
---@field stream_job integer|nil Event-stream job id.
---@field pending_permission table|nil The open permission request, if any.
---@field busy boolean A request is in flight.
---@field last_error string|nil

M.session = nil
M.session_id = nil
M.title = nil
M.streaming = false
M.stream_job = nil
M.pending_permission = nil
M.busy = false
M.last_error = nil

---Incremental render bookkeeping, keyed by the streaming part id.
---@type table<string, table>
M.parts = {}

---Has the panel been opened at least once this session?
M.opened = false

function M.reset_session()
  M.session = nil
  M.session_id = nil
  M.title = nil
  M.streaming = false
  M.pending_permission = nil
  M.parts = {}
end

return M
